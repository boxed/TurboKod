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

from .lsp import LspProcess
from .posix import drain_fd_string, exit_code_from_status, poll_exit
from .string_utils import shell_command, shell_single_quote


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

    def __init__(out self):
        self.active = False
        self.target_name = String("")
        self.command = String("")
        self.process = LspProcess()
        self.exited = False
        self.exit_code = 0

    def is_active(self) -> Bool:
        return self.active and not self.exited

    def matches(self, name: String) -> Bool:
        return self.active and self.target_name == name

    def start(
        mut self, var target_name: String, program: String,
        args: List[String], cwd: String,
        cols: Int = 0, rows: Int = 0,
        env: List[String] = List[String](),
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

        ``cols``/``rows`` (when > 0) are exported as ``COLUMNS``/
        ``LINES`` so the child sizes its output to the pane. The child
        runs on a pipe, not a pty, so it can't ask the kernel for a
        window size — tools like pytest fall back to 80×24 unless these
        env vars are set. Exported *before* the ``cd``/``exec`` so the
        replaced program inherits them.

        ``env`` holds the target's extra ``KEY=VALUE`` entries; each is
        ``export``-ed the same way, quoted whole, so values with spaces
        survive. They come after ``COLUMNS``/``LINES`` so a target can
        override those too.
        """
        if self.active and not self.exited:
            raise Error("run session already active")
        var pretty = run_display_line(program, args, env)
        # Build the ``sh -c`` line the same way every time so the
        # diagnostic ``command`` field always matches what the
        # kernel actually ran.
        var script = String("exec ") + shell_command(program, args)
        if len(cwd.as_bytes()) > 0:
            script = String("cd ") + shell_single_quote(cwd) \
                + String(" && ") + script
        for k in range(len(env)):
            script = String("export ") + shell_single_quote(env[k]) \
                + String("; ") + script
        if cols > 0 and rows > 0:
            script = String("export COLUMNS=") + String(cols) \
                + String(" LINES=") + String(rows) + String("; ") + script
        var argv = List[String]()
        argv.append(String("sh"))
        argv.append(String("-c"))
        argv.append(script)
        self.process = LspProcess.spawn(argv)
        self.target_name = target_name^
        self.command = pretty^
        self.exited = False
        self.exit_code = 0
        self.active = True

    def terminate(mut self):
        """SIGTERM the child if still alive (SIGKILL if it ignores that),
        reap it, then close our pipe ends. Idempotent — fine to call after
        the child has already exited.

        Reaps here rather than leaving it to the next ``tick``: on the
        shutdown path there is no next frame, and the child was left as a
        zombie. ``LspProcess.terminate_with_status`` is bounded, so the
        Stop button stays responsive."""
        if not self.active:
            return
        var was_running = not self.exited
        var reaped = self.process.terminate_with_status()
        if was_running and reaped[0]:
            self.exited = True
            self.exit_code = exit_code_from_status(Int(reaped[1]))
        self.active = False


struct RunOutput(ImplicitlyCopyable, Movable):
    """One drain-pass result, surfaced to the host so the pane can
    append the bytes with the right category."""
    var stdout: String
    var stderr: String

    def __init__(out self):
        self.stdout = String("")
        self.stderr = String("")

    def empty(self) -> Bool:
        return len(self.stdout.as_bytes()) == 0 \
            and len(self.stderr.as_bytes()) == 0


def drain_run_output(mut session: RunSession) -> RunOutput:
    """Pull whatever's on the child's pipes right now without
    blocking. Both pipes were set non-blocking by ``LspProcess.spawn``
    so each loop is bounded by the per-call 64 KB cap."""
    var out = RunOutput()
    # Drain while the session's pipes are open — note this is ``active``,
    # not ``is_active()``: a child that has *exited* but not yet been
    # ``terminate``d can still have its final ``printf`` payload sitting
    # in the pipe buffer, and that tail is exactly what we want to
    # capture. ``drain_fd_string`` no-ops on a closed (-1) fd.
    if not session.active:
        return out^
    out.stdout = drain_fd_string(session.process.stdout_fd)
    out.stderr = drain_fd_string(session.process.stderr_fd)
    return out^


def run_display_line(
    program: String, args: List[String], env: List[String],
) -> String:
    """What a run looks like on the pane's ``$`` line: its extra
    ``KEY=VALUE`` entries, the resolved program, its arguments."""
    var out = String("")
    for e in env:
        out += e + String(" ")
    out += program
    for a in args:
        out += String(" ") + a
    return out^


def poll_run_exit(mut session: RunSession) -> Bool:
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
    var status = poll_exit(session.process.pid)
    if not status:
        return False
    session.exited = True
    session.exit_code = exit_code_from_status(Int(status.value()))
    session.process.alive = False
    return True

