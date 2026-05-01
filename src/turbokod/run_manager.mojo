"""Background subprocess runner for project targets.

This is the "Run" half of the run/debug pair triggered from the status
bar tabs (Cmd+R). One in-flight session at a time: starting a new run
while another is alive terminates the old one first.

The child is spawned argv-style (``program`` + ``args``, no shell
interpolation) so the same configuration drives both run and debug —
``RunTarget.program`` / ``args`` is what we pass here, and what the
DAP launch path passes to the adapter. Shell features (pipes,
redirects, glob expansion) aren't supported; users that need them
write a wrapper script and point the target at it.

Output (stdout + stderr) is captured incrementally and pushed into the
shared ``DebugPane`` so the user sees it live, just like a debug
session's ``output`` events. Tagging is deliberately the same as DAP's
output categories (``PANE_OUT_STDOUT`` / ``PANE_OUT_STDERR``) so the
pane renderer doesn't need to know whether the source was a debugger
or a plain run — the visual idiom is identical.

Why not reuse ``InstallRunner``: install runs are one-shot, modeled
around a popup with a spinner and an end-of-run dialog. Run targets
are a per-frame stream into a docked pane, can be terminated mid-run,
and are restarted on every Cmd+R. The shapes diverge enough that
sharing would add branches everywhere.
"""

from std.collections.list import List
from std.collections.optional import Optional

from .lsp import LspProcess
from .posix import (
    SIGTERM, alloc_zero_buffer, close_fd, kill_pid, monotonic_ms,
    poll_stdin, read_into, waitpid_nohang,
)


struct RunSession(Movable):
    """One running child plus its captured pipes.

    Lifecycle: NOT_STARTED → RUNNING → TERMINATED. ``start`` flips into
    RUNNING; ``tick`` drains output and reaps the child on exit;
    ``terminate`` SIGTERMs the child (idempotent on a dead session).

    Owned single-slot by ``Desktop`` so the rest of the codebase can
    treat "is something running for this target?" as a simple
    ``has_session && session.target_name == name`` check.
    """
    var active: Bool
    var target_name: String
    var command: String
    """Pretty-printed argv for the pane log — ``"<program> <arg1> …"``.
    Not parsed by anything; pure diagnostic surface."""
    var process: LspProcess
    var exited: Bool
    var exit_code: Int
    var started_ms: Int

    fn __init__(out self):
        self.active = False
        self.target_name = String("")
        self.command = String("")
        self.process = LspProcess()
        self.exited = False
        self.exit_code = 0
        self.started_ms = 0

    fn is_active(self) -> Bool:
        return self.active and not self.exited

    fn matches(self, name: String) -> Bool:
        return self.active and self.target_name == name

    fn start(
        mut self, var target_name: String, program: String,
        args: List[String], cwd: String,
    ) raises:
        """Spawn ``program`` with ``args`` (argv-style, no shell).
        Raises if a run is already in flight — caller should
        ``terminate`` first.

        ``cwd`` is honored by routing the spawn through ``sh -c 'cd
        <cwd> && exec <program> <args…>'`` since ``LspProcess.spawn``
        doesn't expose ``chdir``. ``exec`` replaces the shell with
        the real program so the spawn keeps the kernel's view of
        argv[0] aligned with the user's binary, and signals
        (SIGTERM from ``terminate``) reach the right process.
        """
        if self.active and not self.exited:
            raise Error("run session already active")
        var pretty = program
        for k in range(len(args)):
            pretty = pretty + String(" ") + args[k]
        # Build the ``sh -c`` line the same way every time so the
        # diagnostic ``command`` field always matches what the
        # kernel actually ran.
        var script = String("exec ") + _shell_quote(program)
        for k in range(len(args)):
            script = script + String(" ") + _shell_quote(args[k])
        if len(cwd.as_bytes()) > 0:
            script = String("cd ") + _shell_quote(cwd) \
                + String(" && ") + script
        var argv = List[String]()
        argv.append(String("sh"))
        argv.append(String("-c"))
        argv.append(script)
        self.process = LspProcess.spawn(argv)
        self.target_name = target_name^
        self.command = pretty^
        self.exited = False
        self.exit_code = 0
        self.started_ms = monotonic_ms()
        self.active = True

    fn terminate(mut self):
        """SIGTERM the child if still alive, then close our pipe ends.
        Idempotent — fine to call after the child has already exited."""
        if not self.active:
            return
        if not self.exited and self.process.pid > 0 and self.process.alive:
            _ = kill_pid(self.process.pid, SIGTERM)
            # Give the kernel a single tick to deliver the signal +
            # let waitpid reap. We don't loop / sleep here — callers
            # poll ``tick`` next frame to harvest the exit code.
            var pair = waitpid_nohang(self.process.pid)
            if Int(pair[0]) == Int(self.process.pid):
                self.exited = True
                self.exit_code = (Int(pair[1]) >> 8) & 0xFF
                self.process.alive = False
        self._close_pipes()
        self.active = False

    fn _close_pipes(mut self):
        if self.process.stdin_fd >= 0:
            _ = close_fd(self.process.stdin_fd)
            self.process.stdin_fd = -1
        if self.process.stdout_fd >= 0:
            _ = close_fd(self.process.stdout_fd)
            self.process.stdout_fd = -1
        if self.process.stderr_fd >= 0:
            _ = close_fd(self.process.stderr_fd)
            self.process.stderr_fd = -1


struct RunOutput(ImplicitlyCopyable, Movable):
    """One drain-pass result, surfaced to the host so the pane can
    append the bytes with the right category."""
    var stdout: String
    var stderr: String

    fn __init__(out self):
        self.stdout = String("")
        self.stderr = String("")

    fn __copyinit__(out self, copy: Self):
        self.stdout = copy.stdout
        self.stderr = copy.stderr

    fn empty(self) -> Bool:
        return len(self.stdout.as_bytes()) == 0 \
            and len(self.stderr.as_bytes()) == 0


fn drain_run_output(mut session: RunSession) -> RunOutput:
    """Pull whatever's on the child's pipes right now without
    blocking. Both pipes were set non-blocking by ``LspProcess.spawn``
    so each loop is bounded by the per-call 64 KB cap."""
    var out = RunOutput()
    if not session.is_active():
        return out^
    out.stdout = _drain_fd(session.process.stdout_fd)
    out.stderr = _drain_fd(session.process.stderr_fd)
    return out^


fn poll_run_exit(mut session: RunSession) -> Bool:
    """Returns True the first tick on which the child has exited.
    Subsequent calls return False (it's already exited; nothing new).

    Latches ``session.exited`` + ``session.exit_code`` so callers can
    surface the exit code in the pane / status bar.
    """
    if not session.active or session.exited:
        return False
    if not session.process.alive or session.process.pid <= 0:
        session.exited = True
        return True
    var pair = waitpid_nohang(session.process.pid)
    if Int(pair[0]) != Int(session.process.pid):
        return False
    session.exited = True
    session.exit_code = (Int(pair[1]) >> 8) & 0xFF
    session.process.alive = False
    return True


fn _drain_fd(fd: Int32) -> String:
    if fd < 0:
        return String("")
    var out = String("")
    var scratch = alloc_zero_buffer(4096)
    var total = 0
    while poll_stdin(fd, Int32(0)) and total < 65536:
        var n = read_into(fd, scratch, 4096)
        if n <= 0:
            break
        out = out + String(StringSlice(
            ptr=scratch.unsafe_ptr(), length=n,
        ))
        total += n
    return out^


fn _shell_quote(s: String) -> String:
    """Single-quote ``s`` for safe substitution into ``sh -c``.
    Embedded single quotes are escaped via ``'\\''`` (close-quote,
    literal-quote, re-open-quote) — the standard POSIX idiom."""
    var b = s.as_bytes()
    var out = String("'")
    for i in range(len(b)):
        var c = Int(b[i])
        if c == 0x27:    # '
            out = out + String("'\\''")
        else:
            out = out + chr(c)
    out = out + String("'")
    return out^
