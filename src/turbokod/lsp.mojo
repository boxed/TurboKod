"""Phase-2 LSP client: spawn a server, frame JSON-RPC, expose a poll loop.

This module is layered:

* ``LspProcess`` owns the subprocess pipes and the JSON-RPC wire framing.
  It knows nothing about LSP messages — just ``Content-Length: N\\r\\n\\r\\n``
  framed payloads.
* ``LspClient`` builds on top: autoincrementing ids, request/notification
  serializers, and a ``poll`` that classifies each incoming framed payload
  into a tagged ``LspIncoming``.

``lsp_dispatch.LspManager`` drives these per language server.
"""

from std.collections.list import List
from std.collections.optional import Optional

from std.io.file_descriptor import RawFileDescriptor
from std.ffi import c_int
from std.ffi import external_call

from .json import (
    json_array, json_bool, json_int, json_null, json_object,
    json_str, JsonObjectWriter, JsonValue, parse_json, take_json,
)
from .case_fold import fold_byte
from .string_utils import hex_digit_value, utf8_prefix
from .posix import (
    DRAIN_OPEN, POSIX_SPAWN_FILE_ACTIONS_SIZE, SIGKILL, SIGTERM,
    alloc_zero_buffer, append_string_bytes, chdir_path, close_fd, drain_fd,
    drain_fd_string, getcwd_path, getenv_value, kill_pid, monotonic_ms,
    poll_readable, posix_spawn_file_actions_addclose,
    posix_spawn_file_actions_adddup2, posix_spawn_file_actions_destroy,
    posix_spawn_file_actions_init, posix_spawnp_call, read_append, reap_child,
    set_nonblocking, stdio_pipes, poll_exit, track_child, untrack_child,
    waitpid_blocking, write_buffer,
)


# --- argv / envp marshalling ---------------------------------------------


@fieldwise_init
struct ArgvBuffer(Movable):
    """Contiguous NUL-terminated string blob + the corresponding ``char**``
    pointer array that ``posix_spawnp`` expects. Both are kept alive for
    the lifetime of the spawn call by holding them on this struct."""
    var blob: List[UInt8]
    var pointers: List[UInt8]


def _build_envp_from_parent() -> ArgvBuffer:
    """Build an envp by reading specific variables from the parent.

    These are the ones ``mojo-lsp-server`` cares about (some directly —
    ``MODULAR_HOME`` to locate ``std`` — others as collateral so paths,
    locale, and home cache directories work). We don't forward *every*
    parent var because a NULL-terminated envp inherited via posix_spawn
    requires a real pointer (Mojo's ``external_call`` doesn't model that
    cleanly), so an explicit allowlist is the simpler reliable path.
    """
    var names = List[String]()
    names.append(String("PATH"))
    names.append(String("HOME"))
    names.append(String("USER"))
    names.append(String("SHELL"))
    names.append(String("TMPDIR"))
    names.append(String("LANG"))
    names.append(String("LC_ALL"))
    names.append(String("LC_CTYPE"))
    names.append(String("TERM"))
    names.append(String("MODULAR_HOME"))
    names.append(String("MAX_PATH"))
    names.append(String("MOJO_PYTHON"))
    names.append(String("CONDA_PREFIX"))
    names.append(String("CONDA_DEFAULT_ENV"))
    names.append(String("CONDA_PYTHON_EXE"))
    names.append(String("VIRTUAL_ENV"))
    names.append(String("PIXI_PROJECT_ROOT"))
    names.append(String("PIXI_PROJECT_NAME"))
    names.append(String("PIXI_PROJECT_MANIFEST"))
    names.append(String("LD_LIBRARY_PATH"))
    names.append(String("DYLD_LIBRARY_PATH"))
    names.append(String("DYLD_FALLBACK_LIBRARY_PATH"))
    # Python-flavored vars: debugpy + pyright both consult these to
    # find their own packages. Without PYTHONPATH a system ``python``
    # invoked as ``python -m debugpy.adapter`` may locate ``python`` but
    # not ``debugpy`` and silently stall on import resolution.
    names.append(String("PYTHONPATH"))
    names.append(String("PYTHONUSERBASE"))
    names.append(String("PYTHONUNBUFFERED"))
    # NB: we deliberately do NOT forward PYTHONHOME. Our process may have it
    # set to the pixi/Mojo python; forwarding it overrides the *child*'s own
    # stdlib root, so a self-contained LSP (uv/pyenv tool with its own python
    # — ty, ruff, iommi_lsp, …) would load our stdlib instead of its own and
    # fail with e.g. ``ModuleNotFoundError: No module named '_socket'``.
    # PYTHONHOME redirects sys.prefix; the child must keep its own.
    var pairs = List[String]()
    for i in range(len(names)):
        var v = getenv_value(names[i])
        if len(v.as_bytes()) > 0:
            pairs.append(names[i] + String("=") + v)
    # Force unbuffered Python I/O for any spawned child. Without this,
    # ``python -m debugpy.adapter`` (and other Python-based servers)
    # default to *full* stdout buffering when stdout is a pipe — they
    # write a response, it sits in their internal buffer until the
    # buffer fills or they explicitly flush, and our ``poll`` sees
    # nothing. The handshake then hangs at INITIALIZING with no error.
    # Setting PYTHONUNBUFFERED=1 makes Python flush on every write.
    pairs.append(String("PYTHONUNBUFFERED=1"))
    return build_argv_buffer(pairs)


def build_argv_buffer(args: List[String]) -> ArgvBuffer:
    var blob = List[UInt8]()
    var offsets = List[Int]()
    for i in range(len(args)):
        offsets.append(len(blob))
        var b = args[i].as_bytes()
        for k in range(len(b)):
            blob.append(b[k])
        blob.append(0)
    # ``pointers`` is a packed array of ``char *`` (8 bytes each), with a
    # NULL terminator at the end. We resolve offsets to absolute pointers
    # via blob.unsafe_ptr() + offset.
    var nptrs = len(args) + 1
    var pointers = alloc_zero_buffer(nptrs * 8)
    var pp = pointers.unsafe_ptr().unsafe_bitcast[Int]()
    for i in range(len(args)):
        pp[unsafe_offset=i] = Int(blob.unsafe_ptr()) + offsets[i]
    pp[unsafe_offset=len(args)] = 0
    return ArgvBuffer(blob^, pointers^)


# --- capture_command ------------------------------------------------------


@fieldwise_init
struct CaptureResult(Movable):
    """Output of a synchronous child run. ``status`` is the raw waitpid
    value; the exit code is ``(status >> 8) & 0xFF`` on POSIX. ``stderr``
    is captured separately so callers that care about distinguishing
    progress text from the actual result (``git push`` is the canonical
    example — pushes the result summary to stderr) can see it."""
    var stdout: String
    var stderr: String
    var status: Int32


def _spawn_piped(
    argv: List[String], cwd: String,
) raises -> Tuple[Int32, Int32, Int32, Int32]:
    """``posix_spawnp`` ``argv`` with three pipes wired onto its stdin /
    stdout / stderr, returning ``(pid, stdin_w, stdout_r, stderr_r)`` — the
    parent-side ends. The child-side ends are closed in the parent right
    after the spawn so EOF propagates when either side hangs up, and the
    child is registered for SIGTERM-on-exit.

    ``cwd`` (when non-empty) is the working directory the child starts in.
    ``posix_spawn`` doesn't take a cwd argument portably, so we save the
    parent's cwd, ``chdir`` to ``cwd`` across the spawn, then restore.

    Raises if argv is empty or the spawn fails; nothing leaks either way."""
    if len(argv) == 0:
        raise Error("argv must not be empty")
    # Parent's view: ``stdin_w`` writes to child stdin, ``stdout_r``
    # reads child stdout, ``stderr_r`` reads child stderr.
    var pipes = stdio_pipes()
    var stdin_r = pipes[0]
    var stdin_w = pipes[1]
    var stdout_r = pipes[2]
    var stdout_w = pipes[3]
    var stderr_r = pipes[4]
    var stderr_w = pipes[5]

    var fa = alloc_zero_buffer(POSIX_SPAWN_FILE_ACTIONS_SIZE)
    var rc_init = posix_spawn_file_actions_init(fa)
    if Int(rc_init) != 0:
        _close_pipes(stdin_r, stdin_w, stdout_r, stdout_w, stderr_r, stderr_w)
        raise Error("posix_spawn_file_actions_init failed")
    # Child side: dup pipe ends onto stdin/stdout/stderr, then close
    # the parent ends in the child.
    _ = posix_spawn_file_actions_adddup2(fa, stdin_r,  Int32(0))
    _ = posix_spawn_file_actions_adddup2(fa, stdout_w, Int32(1))
    _ = posix_spawn_file_actions_adddup2(fa, stderr_w, Int32(2))
    _ = posix_spawn_file_actions_addclose(fa, stdin_w)
    _ = posix_spawn_file_actions_addclose(fa, stdout_r)
    _ = posix_spawn_file_actions_addclose(fa, stderr_r)
    _ = posix_spawn_file_actions_addclose(fa, stdin_r)
    _ = posix_spawn_file_actions_addclose(fa, stdout_w)
    _ = posix_spawn_file_actions_addclose(fa, stderr_w)

    var argv_buf = build_argv_buffer(argv)
    # Forward the parent's environ. Critical for ``mojo-lsp-server``,
    # which uses ``MODULAR_HOME`` (and friends) to locate its own
    # ``std`` package; with an empty env it falls back to ``/opt/modular``,
    # fails to read it, and rejects every document with "unable to
    # locate module 'std'" — turning every definition request into ``[]``.
    var envp_buf = _build_envp_from_parent()
    # Save parent cwd, chdir into ``cwd`` for the spawn, restore after.
    # ``posix_spawn`` doesn't take a cwd portably; the child inherits
    # whatever directory the parent is in at fork time, then exec'd.
    # We restore unconditionally (even on spawn failure) so a failed
    # LSP launch doesn't leave the editor in the project's directory.
    var saved_cwd = String("")
    var did_chdir = False
    if len(cwd.as_bytes()) > 0:
        saved_cwd = getcwd_path()
        if Int(chdir_path(cwd)) == 0:
            did_chdir = True
    var pid: Int32
    try:
        pid = posix_spawnp_call(
            argv_buf.pointers, envp_buf.pointers, fa, argv[0],
        )
    except:
        if did_chdir and len(saved_cwd.as_bytes()) > 0:
            _ = chdir_path(saved_cwd)
        _ = posix_spawn_file_actions_destroy(fa)
        _close_pipes(stdin_r, stdin_w, stdout_r, stdout_w, stderr_r, stderr_w)
        raise Error("posix_spawnp failed")
    if did_chdir and len(saved_cwd.as_bytes()) > 0:
        _ = chdir_path(saved_cwd)
    _ = posix_spawn_file_actions_destroy(fa)
    # Register the child so it gets SIGTERM if the parent dies on
    # SIGHUP / SIGTERM / clean exit — see the Rust shim's child registry.
    track_child(pid)
    # Close the child sides in the parent — the kernel keeps the pipe
    # alive as long as either end is open, so leaving them open here
    # would prevent EOF when the child closes its descriptor.
    _ = close_fd(stdin_r)
    _ = close_fd(stdout_w)
    _ = close_fd(stderr_w)
    return (pid, stdin_w, stdout_r, stderr_r)


def capture_command(
    argv: List[String], stdin_text: String = String(""),
) raises -> CaptureResult:
    """Run ``argv`` to completion and return its stdout, stderr and raw
    wait status.

    The child inherits an allowlisted
    parent environment (see ``_build_envp_from_parent``). Reads are
    blocking and the call returns only after the child exits, so this
    is unsuitable for long-running servers — use ``LspProcess`` for
    those — but ideal for one-shot tools like ``rg`` or ``git``.

    Raises if argv is empty or posix_spawnp fails. A non-zero
    exit_status is **not** an error: command-line tools commonly use
    exit 1 to mean "no results" (e.g., grep / rg with no matches), and
    callers want to distinguish that from a spawn failure.
    """
    var spawned = _spawn_piped(argv, String(""))
    var pid = spawned[0]
    var stdin_w = spawned[1]
    var stdout_r = spawned[2]
    var stderr_r = spawned[3]

    # Send stdin (if any), then close to signal EOF — without this many
    # tools that read stdin (e.g. ``rg`` reading from stdin) would hang.
    # ``write_buffer`` is non-raising, so no teardown guard is needed here;
    # if that ever changes, note that everything from the spawn down owns
    # three descriptors plus an unreaped child.
    if len(stdin_text.as_bytes()) > 0:
        var sb = List[UInt8]()
        append_string_bytes(sb, stdin_text)
        write_buffer(stdin_w, sb)
    _ = close_fd(stdin_w)

    # Drain stdout + stderr to EOF together. Capturing stderr lets git
    # callers surface useful failure messages, and draining the two in
    # lockstep is what keeps a child that fills one pipe while we wait on
    # the other from deadlocking us both.
    var drained = _drain_both_to_eof(stdout_r, stderr_r)
    _ = close_fd(stdout_r)
    _ = close_fd(stderr_r)
    var out = drained[0]
    var err = drained[1]

    var status = waitpid_blocking(pid)
    untrack_child(pid)
    return CaptureResult(out^, err^, status)


def _close_pipes(a: Int32, b: Int32, c: Int32, d: Int32, e: Int32, f: Int32):
    """Close a failed spawn's three pipes, both ends each."""
    for fd in [a, b, c, d, e, f]:
        _ = close_fd(fd)


def _drain_both_to_eof(out_fd: Int32, err_fd: Int32) -> Tuple[String, String]:
    """Read two pipes to EOF, whichever has data first. Reading one to EOF
    before starting the other deadlocks as soon as the child writes more
    than a pipe buffer (~64 KB) to the second: it blocks on the full pipe
    and never closes the first. Bytes accumulate in buffers and each
    String is built once (``out = out + chunk`` was O(n^2) on the many-MB
    ``rg`` / git output this drains)."""
    var bufs = [List[UInt8](), List[UInt8]()]
    var fds = [out_fd, err_fd]
    var open = [True, True]
    while open[0] or open[1]:
        var progressed = False
        for i in range(2):
            if not open[i]:
                continue
            var r = drain_fd(fds[i], bufs[i], 1 << 20)
            if r[1] != DRAIN_OPEN:
                open[i] = False
            progressed = progressed or r[0] > 0 or not open[i]
        if not progressed:
            # Nothing ready: block briefly on whichever is still open.
            _ = poll_readable(fds[0] if open[0] else fds[1], Int32(20))
    return (
        String(StringSpan(unsafe_from_utf8=Span(bufs[0]))),
        String(StringSpan(unsafe_from_utf8=Span(bufs[1]))),
    )


# --- LspProcess -----------------------------------------------------------


comptime _BUF_CAP_GUARD: Int = 16 * 1024 * 1024
"""Bytes-on-the-floor protection: if the read buffer ever grows past this
without yielding a complete message, we treat the server as misbehaving
and reset. 16 MB is far above any plausible LSP payload."""


struct LspProcess(Copyable, Movable):
    """A spawned child plus its stdin/stdout/stderr pipes and a
    Content-Length-aware read framer.

    Honest copying would duplicate child PID + pipe FD ownership, which
    would leak / double-close. We only declare ``Copyable`` so the
    containing structs (``LspClient``/``DapClient``/``LspManager``) can
    in turn satisfy ``Copyable`` — Mojo 1.0 requires every field of a
    ``Copyable`` struct to itself be ``Copyable``. The ``__copyinit__``
    here produces a fresh inert sentinel (``pid == -1``, ``alive ==
    False``) rather than aliasing OS resources; consumers grow these
    via ``^`` transfer so the branch should not actually fire."""
    var pid: Int32
    var stdin_fd: Int32
    var stdout_fd: Int32
    var stderr_fd: Int32
    var alive: Bool
    var _read_buffer: List[UInt8]
    # Bytes of ``_read_buffer`` / ``_pending_write`` already consumed. The
    # buffers are compacted only once the dead prefix outgrows the live
    # tail (``_dead_prefix_too_big``): dropping the prefix per message made
    # a burst of N small messages (diagnostics at startup) cost O(N x
    # buffer), and a large write on a 64 KB pipe copy its tail per write.
    var _read_head: Int
    # Outbound queue. ``write_message`` frames a payload onto here and
    # then best-effort drains via a non-blocking ``write(2)``; whatever
    # the kernel didn't accept stays queued for ``pump_writes`` to
    # flush on subsequent ticks. The whole point is that the UI thread
    # never blocks on a stuck server: if the child stops reading its
    # stdin, our writes pile up here (capped) instead of stalling the
    # editor inside a syscall.
    var _pending_write: List[UInt8]
    var _write_head: Int
    var _write_overflowed: Bool
    # Optional trace log. When ``trace_fd >= 0`` every wire-level event
    # (writes, reads, message extractions) is appended to that fd as a
    # single line. The whole point of streaming the log is so that a
    # hung session still leaves a complete-up-to-the-hang trail on
    # disk — no need for the host loop to be alive to flush. We
    # ``write()`` directly via ``RawFileDescriptor`` (no userspace
    # buffering) so each call is durable on return.
    #
    # Set it through ``own_trace_fd`` / ``borrow_trace_fd`` rather than
    # by assignment: ``terminate`` closes the fd, and the debugpyAttach
    # path deliberately points a *second* process at the parent session's
    # log, so the two need to disagree about who does the closing.
    var trace_fd: Int32
    var _trace_fd_owned: Bool

    def __init__(out self):
        self.pid = -1
        self.stdin_fd = -1
        self.stdout_fd = -1
        self.stderr_fd = -1
        self.alive = False
        self._read_buffer = List[UInt8]()
        self._read_head = 0
        self._pending_write = List[UInt8]()
        self._write_head = 0
        self._write_overflowed = False
        self.trace_fd = -1
        self._trace_fd_owned = False

    def __copyinit__(mut self, copy: Self):
        # A copy is a fresh instance, exactly what ``__init__`` builds:
        # one list of field defaults, not two to keep in step.
        self = Self()

    def own_trace_fd(mut self, fd: Int32):
        """Attach a trace log this process is responsible for closing.

        Callers ``creat`` the log right after spawning; without a matching
        close in ``terminate`` every restarted LSP / DAP session leaked one
        descriptor for the life of the process."""
        self.trace_fd = fd
        self._trace_fd_owned = fd >= 0

    def borrow_trace_fd(mut self, fd: Int32):
        """Write into someone else's trace log without owning it.

        Used for debugpy's subprocess sessions, which share the parent
        session's log — the parent closes it, and a second close here
        would target a descriptor number the process may since have
        reused."""
        self.trace_fd = fd
        self._trace_fd_owned = False

    @staticmethod
    def spawn(argv: List[String], cwd: String = String("")) raises -> Self:
        """Run ``argv`` with three pipes wired onto stdin/stdout/stderr.

        Returns a process with the parent-side ends owned by ``self``;
        the child-side ends are closed in the parent immediately after
        spawn so EOF propagates correctly when one side hangs up.

        ``cwd`` (when non-empty) is the working directory the child
        starts in. ``posix_spawn`` doesn't take a cwd argument
        portably, so we save the parent's cwd, ``chdir`` to ``cwd``
        across the spawn, then restore. Pyright (and other LSPs) use
        the child's cwd as a fallback workspace root for module
        resolution when ``workspaceFolders`` is missing or ambiguous.
        """
        var spawned = _spawn_piped(argv, cwd)
        var proc = LspProcess()
        proc.pid = spawned[0]
        proc.stdin_fd = spawned[1]
        proc.stdout_fd = spawned[2]
        proc.stderr_fd = spawned[3]
        proc.alive = True
        # Reading the stdout/stderr pipes non-blocking lets ``poll_message``
        # drain whatever's available in one shot without risking a hang.
        # ``stdin_fd`` is also non-blocking — writes are framed onto
        # ``_pending_write`` and flushed via ``_try_flush_writes`` /
        # ``pump_writes``. A stuck server can never block the UI thread
        # inside ``write(2)``; bytes pile up in the queue (capped) and
        # drain on subsequent ticks.
        _ = set_nonblocking(proc.stdin_fd)
        _ = set_nonblocking(proc.stdout_fd)
        _ = set_nonblocking(proc.stderr_fd)
        return proc^

    def trace(self, var line: String):
        """Append ``line`` (plus a newline) to the trace fd, if open.

        Uses the raw ``write`` syscall — no userspace buffering — so
        each call is durable on return. Errors are swallowed; this is
        diagnostics, never load-bearing for correctness."""
        if self.trace_fd < 0:
            return
        var stamped = String("[") + String(monotonic_ms()) + String("] ") \
            + line + String("\n")
        var bytes = stamped.as_bytes()
        if len(bytes) == 0:
            return
        var f = RawFileDescriptor(c_int(self.trace_fd))
        f.write_bytes(bytes)

    def write_message(mut self, payload: String) raises:
        """``write_payload`` for a payload already in a ``String``."""
        self.write_payload(payload.as_bytes())

    def write_payload(mut self, payload: Span[UInt8, _]) raises:
        """Frame ``payload`` with ``Content-Length: N\\r\\n\\r\\n`` and
        queue it for non-blocking delivery to the child's stdin.

        Never blocks on a stuck server: the framed bytes are appended
        to ``_pending_write`` and we then best-effort drain via
        ``_try_flush_writes``. Anything the kernel didn't accept stays
        queued; ``pump_writes`` (called from the manager's tick)
        continues the drain on subsequent frames. Past the overflow
        cap we drop the queue and latch ``_write_overflowed`` so the
        manager can mark the server failed.
        """
        var n = len(payload)
        if self.trace_fd >= 0:
            # Truncate huge payloads in the trace — full breakpoint
            # lists, big stack traces etc. can run to several KB and
            # the log is meant to be human-readable.
            var text = String(StringSpan(unsafe_from_utf8=payload))
            self.trace(
                String("> ") + String(n) + String("B ") + _trace_preview(text)
            )
        if _dead_prefix_too_big(self._write_head, len(self._pending_write)):
            self._pending_write = _drop_prefix(
                self._pending_write^, self._write_head,
            )
            self._write_head = 0
        append_string_bytes(self._pending_write, "Content-Length: ")
        append_string_bytes(self._pending_write, String(n))
        append_string_bytes(self._pending_write, "\r\n\r\n")
        self._pending_write.extend(payload)
        var queued = len(self._pending_write) - self._write_head
        if queued > _BUF_CAP_GUARD:
            if self.trace_fd >= 0:
                self.trace(
                    String("> overflow: pending_write=")
                    + String(queued)
                    + String("B exceeded cap; dropping queue"),
                )
            self._clear_writes()
            self._write_overflowed = True
            return
        self._try_flush_writes()

    def _try_flush_writes(mut self):
        """Drain ``_pending_write`` via non-blocking ``write(2)`` until
        either the queue is empty or the kernel returns < 0 (EAGAIN /
        EPIPE / etc.). The remaining bytes stay queued for the next
        call. No-op when the fd is gone."""
        if self.stdin_fd < 0:
            return
        while self._write_head < len(self._pending_write):
            var rc = external_call["tk_write_nb", Int](
                self.stdin_fd,
                self._pending_write.unsafe_ptr().unsafe_offset(
                    self._write_head,
                ),
                UInt(len(self._pending_write) - self._write_head),
            )
            if rc == 0:
                # Kernel would block (EAGAIN / EWOULDBLOCK) — try
                # again next tick. Leave the queue intact.
                return
            if rc < 0:
                # Real I/O failure (EPIPE etc.). ``try_reap`` /
                # crash detection in the manager covers the truly
                # dead-server case; here we just drop the queue so
                # we don't spin trying to write to a broken pipe.
                self._clear_writes()
                return
            self._write_head += Int(rc)
        self._clear_writes()

    def _clear_writes(mut self):
        # ``clear`` keeps the capacity, so the next message reuses it —
        # unless an overflow / huge payload grew it past the guard.
        if self._pending_write.capacity() > _BUF_CAP_GUARD:
            self._pending_write = List[UInt8]()
        else:
            self._pending_write.clear()
        self._write_head = 0

    def pump_writes(mut self):
        """Continue draining any queued outbound bytes.

        Called every manager tick so a backlog left after the
        in-line drain in ``write_message`` (because the pipe was
        momentarily full) still flushes within a frame or two of
        the server catching up.
        """
        if self._write_head >= len(self._pending_write):
            return
        self._try_flush_writes()

    def write_overflowed(self) -> Bool:
        """True if the outbound queue overflowed since the last reset.
        ``LspManager.tick`` uses this to latch FAILED instead of
        letting silent message loss accumulate.
        """
        return self._write_overflowed

    def poll_message(mut self, timeout_ms: Int32) -> Optional[String]:
        """Try to return one complete framed payload.

        ``timeout_ms`` is the budget for waiting on stdout when the buffer
        is empty — only spent on the first read of the call. Subsequent
        reads in the same call are non-blocking: we keep draining as long
        as the kernel has bytes ready, so a large response that spans
        multiple ``read(2)`` calls lands in one ``poll_message`` instead
        of getting smeared across several 50 ms editor ticks. None return
        means no full message is framed yet — call again later.

        Scratch buffer is 64 KB to match the typical pipe-buffer size on
        macOS / Linux — a single ``read(2)`` drains a fully-buffered
        pipe in one shot, instead of needing 16 syscalls.
        """
        # Drain anything already in the buffer first.
        var prefab = self._extract_one_message()
        if prefab:
            if self.trace_fd >= 0:
                # Own the message first: taking ``as_bytes()`` off one
                # ``value()`` call and then calling ``value()`` again for
                # the preview invalidates that first interior reference.
                var msg = prefab.value()
                self.trace(
                    String("< ") + String(len(msg.as_bytes())) + String("B ")
                    + _trace_preview(msg),
                )
            return prefab
        var first = True
        while True:
            var poll_budget: Int32
            if first:
                poll_budget = timeout_ms
                first = False
            else:
                poll_budget = Int32(0)
            if not poll_readable(self.stdout_fd, poll_budget):
                return Optional[String]()
            # Straight into the buffer's spare capacity: no scratch to
            # zero and copy out of.
            var n = read_append(self.stdout_fd, self._read_buffer, 65536)
            if n <= 0:
                if self.trace_fd >= 0 and n == 0:
                    self.trace(String("< EOF on stdout"))
                return Optional[String]()
            if self.trace_fd >= 0:
                self.trace(
                    String("< raw ") + String(n) + String("B (buffer now ")
                    + String(len(self._read_buffer) - self._read_head)
                    + String("B)"),
                )
            if len(self._read_buffer) - self._read_head > _BUF_CAP_GUARD:
                self._read_buffer = List[UInt8]()
                self._read_head = 0
                return Optional[String]()
            var extracted = self._extract_one_message()
            if extracted:
                if self.trace_fd >= 0:
                    # Own the message first — see the matching comment in
                    # the pre-drained branch above.
                    var msg = extracted.value()
                    self.trace(
                        String("< extracted ") + String(len(msg.as_bytes()))
                        + String("B ") + _trace_preview(msg),
                    )
                return extracted
            # No complete message yet — keep draining while bytes are
            # available. ``poll_readable(0)`` on the next iteration exits
            # the loop when the pipe is empty.

    def _extract_one_message(mut self) -> Optional[String]:
        """Scan ``_read_buffer`` for a complete framed payload; if one is
        present, slice it out, advance past it, and return it."""
        var hdr_end = _find_double_crlf(self._read_buffer, self._read_head)
        if hdr_end < 0:
            return Optional[String]()
        var content_length = _parse_content_length(
            self._read_buffer, self._read_head, hdr_end,
        )
        if content_length < 0:
            # Malformed header block — drop the framed prefix so we don't
            # spin forever; the next bytes are probably garbage anyway.
            self._consume_read(hdr_end + 4)
            return Optional[String]()
        var body_start = hdr_end + 4
        if len(self._read_buffer) - body_start < content_length:
            return Optional[String]()
        var body = String(StringSpan(unsafe_from_utf8=Span(unsafe_ptr=self._read_buffer.unsafe_ptr().unsafe_offset(body_start), length=content_length)))
        self._consume_read(body_start + content_length)
        return Optional[String](body^)

    def _consume_read(mut self, upto: Int):
        """Mark ``_read_buffer[:upto]`` consumed, compacting when the dead
        prefix outgrows the live tail (or freeing a drained buffer)."""
        self._read_head = upto
        if self._read_head >= len(self._read_buffer):
            self._read_buffer = List[UInt8]()
            self._read_head = 0
        elif _dead_prefix_too_big(self._read_head, len(self._read_buffer)):
            self._read_buffer = _drop_prefix(
                self._read_buffer^, self._read_head,
            )
            self._read_head = 0

    def drain_stderr(mut self) -> String:
        """Drain whatever's available on the server's stderr.
        Non-blocking; loops until ``poll`` says no more data so a
        chatty adapter (debugpy logs many lines per second) can't
        fill the pipe and deadlock on a blocking write. Capped at
        64 KB per call to bound the cost of a single tick.

        Without the loop we'd read at most 4 KB per frame; debugpy's
        startup banner alone is ~1 KB, so a frame-aligned drain
        could fall behind on slow paint cycles and the adapter's
        write-end would back up against the pipe buffer (~64 KB on
        macOS). Once that backs up, the adapter's main thread blocks
        on ``write(stderr, …)`` and never reaches the code that
        replies to our ``initialize`` — appearing as a total hang.
        """
        return drain_fd_string(self.stderr_fd)

    def terminate(mut self):
        """``terminate_with_status`` for callers with no use for the exit
        status."""
        _ = self.terminate_with_status()

    def terminate_with_status(mut self) -> Tuple[Bool, Int32]:
        """Send SIGTERM and reap the child, then close the I/O fds.
        Returns ``reap_child``'s ``(reaped, status)``. Idempotent. Safe to
        call on a socket-mode process (``pid == -1``) — the kill/reap
        steps are skipped, the fd close still runs.

        This runs on the UI thread (a window's LSP teardown, a DAP
        restart, the run pane's Stop), so the reap is bounded: a child
        that ignores SIGTERM gets SIGKILL after ``reap_child``'s budget,
        and one that outlives that too is left tracked for the shim's
        exit reaper — never a ``waitpid_blocking`` that hangs the editor.

        Socket mode shares one fd between ``stdin_fd`` and ``stdout_fd``,
        so we close it exactly once even though both fields name it.
        """
        var reaped = (False, Int32(0))
        if self.alive and self.pid > 0:
            _ = kill_pid(self.pid, SIGTERM)
            reaped = reap_child(self.pid)
            if not reaped[0]:
                _ = kill_pid(self.pid, SIGKILL)
                reaped = reap_child(self.pid)
            if reaped[0]:
                untrack_child(self.pid)
        self.alive = False
        var dup_io = self.stdin_fd >= 0 and self.stdin_fd == self.stdout_fd
        if self.stdin_fd >= 0:
            _ = close_fd(self.stdin_fd)
            self.stdin_fd = -1
        if self.stdout_fd >= 0 and not dup_io:
            _ = close_fd(self.stdout_fd)
        self.stdout_fd = -1
        if self.stderr_fd >= 0:
            _ = close_fd(self.stderr_fd)
            self.stderr_fd = -1
        # The trace log too, when it's ours (see ``own_trace_fd``). A
        # borrowed one belongs to the parent session and is left alone.
        if self.trace_fd >= 0 and self._trace_fd_owned:
            _ = close_fd(self.trace_fd)
        self.trace_fd = -1
        self._trace_fd_owned = False
        # Drop any queued outbound bytes — they'd be writing to a
        # closed fd next time around.
        self._clear_writes()
        self._write_overflowed = False
        return reaped

    @staticmethod
    def from_socket(fd: Int32) -> Self:
        """Wrap a connected TCP socket fd in an ``LspProcess`` so the
        same Content-Length-aware framer can ferry DAP messages over it.

        debugpy's subprocess-attach flow gives us a host/port to connect
        to; once the socket is open it speaks the same DAP framing as
        the parent's stdio session, so the entire ``DapClient`` /
        ``DapManager`` machinery works against it unchanged.

        ``pid = -1`` is the socket-mode sentinel — ``terminate``,
        ``try_reap`` and ``drain_stderr`` all key off it to skip
        process-only operations. ``stderr_fd`` stays ``-1``: a TCP peer
        has no separate stderr channel.
        """
        var p = LspProcess()
        p.pid = -1
        p.stdin_fd = fd
        p.stdout_fd = fd
        p.stderr_fd = -1
        p.alive = True
        _ = set_nonblocking(fd)
        return p^

    def try_reap(mut self) -> Bool:
        """Non-blocking ``waitpid``. Returns True if the child exited.
        Use after ``shutdown``+``exit`` to see if the server cleaned up
        on its own before resorting to ``terminate``.

        Socket-mode (``pid == -1``) has no child to wait on — return
        False as long as ``alive`` is set, so a TCP-attached subprocess
        session isn't mistakenly latched to FAILED on the first tick.
        """
        if not self.alive:
            return True
        if self.pid <= 0:
            return False
        if poll_exit(self.pid):
            self.alive = False
            return True
        return False


# --- framer helpers (top-level for testability) ---------------------------


def _dead_prefix_too_big(head: Int, length: Int) -> Bool:
    """Whether a consumed prefix of ``head`` bytes is worth compacting
    away: past 64 KB and more than the live tail, so compaction is
    amortized O(1) per byte."""
    return head > 65536 and head * 2 > length


def _find_double_crlf(buf: List[UInt8], start: Int = 0) -> Int:
    """Return the index of the first ``\\r\\n\\r\\n`` in ``buf`` at or
    after ``start``, or -1."""
    if len(buf) - start < 4:
        return -1
    for i in range(start, len(buf) - 3):
        if buf[i] == 0x0D and buf[i + 1] == 0x0A \
                and buf[i + 2] == 0x0D and buf[i + 3] == 0x0A:
            return i
    return -1


def _parse_content_length(buf: List[UInt8], start: Int, hdr_end: Int) -> Int:
    """Find ``Content-Length: N`` in the header block ``buf[start:hdr_end]``
    (case-insensitive on the field name) and return ``N``. Returns -1 if
    not found / malformed."""
    var name = String("content-length")
    var nb = name.as_bytes()
    var i = start
    while i + len(nb) <= hdr_end:
        # Match the header name case-insensitively against the prefix
        # starting at position ``i``.
        var ok = True
        for k in range(len(nb)):
            if fold_byte(buf[i + k]) != nb[k]:
                ok = False
                break
        if ok:
            var p = i + len(nb)
            # Skip optional ``: `` and any whitespace.
            if p < hdr_end and buf[p] == 0x3A:
                p += 1
            while p < hdr_end and (buf[p] == 0x20 or buf[p] == 0x09):
                p += 1
            var n = 0
            var saw_digit = False
            while p < hdr_end and Int(buf[p]) >= 0x30 and Int(buf[p]) <= 0x39:
                n = n * 10 + Int(buf[p]) - 0x30
                saw_digit = True
                p += 1
            if saw_digit:
                return n
            return -1
        # Skip to the next line (header lines are separated by ``\r\n``).
        while i < hdr_end and buf[i] != 0x0A:
            i += 1
        i += 1
    return -1


def _drop_prefix(var buf: List[UInt8], n: Int) -> List[UInt8]:
    """Shrink ``buf`` by removing the first ``n`` bytes."""
    if n <= 0:
        return buf^
    if n >= len(buf):
        return List[UInt8]()
    var out = List[UInt8]()
    out.extend(Span(buf)[n:len(buf)])
    return out^


# --- LspClient ------------------------------------------------------------


comptime LSP_RESPONSE     = UInt8(0)
comptime LSP_NOTIFICATION = UInt8(1)
comptime LSP_REQUEST      = UInt8(2)


@fieldwise_init
struct LspIncoming(Copyable, Movable):
    """A classified message from the server.

    * ``kind == LSP_RESPONSE``:     ``id`` is set; one of ``result``/``error``.
    * ``kind == LSP_NOTIFICATION``: ``method`` + ``params`` are set.
    * ``kind == LSP_REQUEST``:      ``id`` + ``method`` + ``params`` are set.

    ``id`` is the raw JSON value. JSON-RPC allows ``integer | string``
    and esbonio uses UUIDs for its ``workspace/configuration`` server
    requests; our own outgoing requests stringify their counter
    (``"1"``, ``"2"``, …) so every correlation site is a plain string
    compare regardless of who issued the id.
    """
    var kind: UInt8
    var id: Optional[JsonValue]
    var method: Optional[String]
    var params: Optional[JsonValue]
    var result: Optional[JsonValue]
    var error: Optional[JsonValue]


struct LspClient(Copyable, Movable):
    """Adds JSON-RPC envelope handling on top of ``LspProcess``.

    ``Copyable`` is declared so containing structs (``LspManager``) can
    satisfy ``Copyable`` themselves; the manual ``__copyinit__`` produces
    a fresh inert sentinel rather than aliasing the underlying process /
    fd ownership — see ``LspProcess.__copyinit__`` for the same pattern.
    Live managers should never hit this branch because they're grown via
    ``^`` transfer."""
    var process: LspProcess
    var _next_id: Int

    def __init__(out self, var process: LspProcess):
        self.process = process^
        self._next_id = 1

    def __copyinit__(mut self, copy: Self):
        self.process = LspProcess()
        self._next_id = 1

    @staticmethod
    def spawn(argv: List[String], cwd: String = String("")) raises -> Self:
        var p = LspProcess.spawn(argv, cwd)
        return LspClient(p^)

    def send_request(
        mut self, method: String, params: JsonValue,
    ) raises -> String:
        """Send a JSON-RPC request and return the issued id (a stringified
        monotonic counter) so callers can correlate with the eventual
        response. Stringifying means every id comparison in this codebase
        is a string compare — server-initiated requests use a UUID
        string (esbonio's ``workspace/configuration``), and rather than
        special-case integer-vs-string at every callsite we just put
        everything on the same footing."""
        var id = String(self._next_id)
        self._next_id += 1
        var w = _rpc_writer()
        w.put_str("id", id)
        w.put_str("method", method)
        w.put_value("params", params)
        self.process.write_payload(w^.finish())
        return id

    def send_notification(
        mut self, method: String, params: JsonValue,
    ) raises:
        var w = _rpc_writer()
        w.put_str("method", method)
        w.put_value("params", params)
        self.process.write_payload(w^.finish())

    def send_response(
        mut self, id: JsonValue, result: JsonValue,
    ) raises:
        """Reply to a server-issued request. The id is echoed verbatim:
        JSON-RPC requires the response id to byte-match the request id,
        so an integer-typed request id is NOT the same as the same
        digits in a string. Required for servers that gate work on a
        client-side probe (taplo blocks all ``publishDiagnostics``
        until ``workspace/configuration`` is answered; esbonio
        similarly stalls)."""
        var w = _rpc_writer()
        w.put_value("id", id)
        w.put_value("result", result)
        self.process.write_payload(w^.finish())

    def send_error(
        mut self, id: JsonValue, code: Int, message: String,
    ) raises:
        """Reply to a server-issued request with a JSON-RPC error
        envelope. Use ``-32601`` (MethodNotFound) for requests we don't
        recognize so the server stops waiting and falls back rather
        than blocking on our (absent) response."""
        var w = _rpc_writer()
        w.put_value("id", id)
        w.key("error")
        var err = JsonObjectWriter(64)
        err.put_int("code", code)
        err.put_str("message", message)
        w.buf.extend(Span(err^.finish()))
        self.process.write_payload(w^.finish())

    def poll(mut self, timeout_ms: Int32) raises -> Optional[LspIncoming]:
        var maybe = self.process.poll_message(timeout_ms)
        if not maybe:
            return Optional[LspIncoming]()
        var v = parse_json(maybe.value())
        return Optional[LspIncoming](classify_message(v^))

    def terminate(mut self):
        self.process.terminate()


def _rpc_writer() -> JsonObjectWriter:
    """A JSON-RPC envelope under construction, ``"jsonrpc":"2.0"`` in.
    Members are spliced as text — putting ``params`` into an envelope
    object deep-copied the tree (a didChange's whole document included)
    on every send."""
    var w = JsonObjectWriter()
    w.put_str("jsonrpc", "2.0")
    return w^


def classify_message(var v: JsonValue) -> LspIncoming:
    """Examine a parsed JSON-RPC envelope and tag it as response /
    notification / request. Top-level utility for tests + clients.
    Takes the envelope so its fields move out rather than being copied."""
    var id_opt = Optional[JsonValue]()
    var method_opt = Optional[String]()
    var params_opt = Optional[JsonValue]()
    var result_opt = Optional[JsonValue]()
    var error_opt = Optional[JsonValue]()
    if v.is_object():
        # Each field moves straight out of the envelope's member: a whole
        # completion or diagnostics payload must not be cloned per message.
        for i in range(len(v.obj_v)):
            ref m = v.obj_v[i]
            if m.key == String("id"):
                id_opt = Optional[JsonValue](take_json(m.value))
            elif m.key == String("method"):
                if m.value.is_string():
                    method_opt = Optional[String](m.value.as_str())
            elif m.key == String("params"):
                params_opt = Optional[JsonValue](take_json(m.value))
            elif m.key == String("result"):
                result_opt = Optional[JsonValue](take_json(m.value))
            elif m.key == String("error"):
                error_opt = Optional[JsonValue](take_json(m.value))
    var kind: UInt8
    if Bool(method_opt) and Bool(id_opt):
        kind = LSP_REQUEST
    elif Bool(method_opt):
        kind = LSP_NOTIFICATION
    else:
        kind = LSP_RESPONSE
    return LspIncoming(
        kind, id_opt^, method_opt, params_opt^, result_opt^, error_opt^,
    )


# --- High-level helpers used by tests + Phase 3 wiring --------------------


def lsp_initialize_params(
    root_uri: String, workspace_name: String,
) -> JsonValue:
    """Build the ``initialize`` payload.

    Sends both ``rootUri`` (deprecated but still respected) and
    ``workspaceFolders`` — pyright keys its workspace/``pyproject.toml``
    discovery off the latter, and falls back to the process CWD when
    neither is present, which makes ``from <pkg> import …`` fail to
    resolve any project-local module.
    """
    var params = json_object()
    # ``processId`` is informational; ``null`` is allowed.
    params.put(String("processId"), json_int(0))
    var has_root = len(root_uri.as_bytes()) > 0
    params.put(String("rootUri"),
        json_str(root_uri) if has_root else json_null(),
    )
    var folders = json_array()
    if has_root:
        var folder = json_object()
        folder.put(String("uri"), json_str(root_uri))
        folder.put(String("name"), json_str(workspace_name))
        folders.append(folder)
    params.put(String("workspaceFolders"),
        folders^ if has_root else json_null(),
    )
    var capabilities = json_object()
    var workspace_caps = json_object()
    workspace_caps.put(String("workspaceFolders"), json_bool(True))
    # Advertise workspace/symbol so the host's Find Symbol picker can
    # ask the server for all workspace symbols matching a name. Some
    # servers (e.g. pyright) treat the request as off when the client
    # never declared it.
    var symbol_caps = json_object()
    symbol_caps.put(String("dynamicRegistration"), json_bool(False))
    workspace_caps.put(String("symbol"), symbol_caps)
    # Advertise workspace/configuration so servers know they can ask
    # us for per-section settings. The ``tick`` request handler replies
    # with ``null`` per item (= "use server defaults"). Servers like
    # taplo block all publishDiagnostics until this probe is answered,
    # so omitting the responder makes TOML buffers appear to analyze
    # forever.
    workspace_caps.put(String("configuration"), json_bool(True))
    # Advertise workspace/didChangeWatchedFiles with dynamicRegistration so
    # servers know they can register file watchers and expect on-disk
    # change events from us: one per save (``notify_watched_changed``)
    # and a batch for every file a HEAD move rewrote — branch switch,
    # reset, pull (``Desktop._on_git_head_observed``). rust-analyzer keys
    # re-indexing of non-open files — Cargo.toml, generated modules — off
    # this, and *stops watching on its own* once we offer it, so a change
    # we don't relay is one it never sees.
    var watched_caps = json_object()
    watched_caps.put(String("dynamicRegistration"), json_bool(True))
    workspace_caps.put(String("didChangeWatchedFiles"), watched_caps)
    # Advertise workspace/didChangeConfiguration so servers accept our
    # "settings changed, please re-read" kick (sent when the user changes
    # settings — see ``notify_configuration_changed``).
    var didchange_cfg_caps = json_object()
    didchange_cfg_caps.put(String("dynamicRegistration"), json_bool(True))
    workspace_caps.put(
        String("didChangeConfiguration"), didchange_cfg_caps,
    )
    # Advertise workspace/didCreateFiles so servers that fix up imports /
    # index on file creation know we'll notify them (sent on Save As of a
    # new file — see ``notify_did_create_files``).
    var file_ops_caps = json_object()
    file_ops_caps.put(String("dynamicRegistration"), json_bool(False))
    file_ops_caps.put(String("didCreate"), json_bool(True))
    file_ops_caps.put(String("didRename"), json_bool(True))
    file_ops_caps.put(String("didDelete"), json_bool(True))
    workspace_caps.put(String("fileOperations"), file_ops_caps)
    # Advertise the ``documentChanges`` form of WorkspaceEdit. rust-analyzer
    # and gopls *prefer* it, and per spec a server may only use the form the
    # client claimed — so without this their renames and quickfix edits
    # arrive in the ``changes`` map form at best, and at worst (a server that
    # sends documentChanges regardless) were silently dropped.
    #
    # ``resourceOperations`` is deliberately NOT advertised: that is the
    # separate opt-in for ``CreateFile`` / ``RenameFile`` / ``DeleteFile``
    # inside a WorkspaceEdit, which we cannot apply. Withholding it means a
    # compliant server never sends one, and ``_parse_workspace_edit`` refuses
    # the whole edit rather than half-applying it if one shows up anyway.
    var ws_edit_caps = json_object()
    ws_edit_caps.put(String("documentChanges"), json_bool(True))
    ws_edit_caps.put(String("normalizesLineEndings"), json_bool(False))
    workspace_caps.put(String("workspaceEdit"), ws_edit_caps)
    capabilities.put(String("workspace"), workspace_caps)
    # Advertise UTF-8 position encoding (LSP 3.17 ``general.positionEncodings``).
    # The editor reasons in byte offsets; with UTF-8 negotiated, LSP
    # ``character`` offsets ARE byte offsets, so positions map straight through
    # on lines containing multibyte characters (otherwise the server would use
    # UTF-16 code-unit offsets and definitions/hover/completion would land at
    # the wrong column). ``utf-16`` is listed as the spec-mandated fallback.
    var general_caps = json_object()
    var encodings = json_array()
    encodings.append(json_str(String("utf-8")))
    encodings.append(json_str(String("utf-16")))
    general_caps.put(String("positionEncodings"), encodings)
    capabilities.put(String("general"), general_caps)
    # Advertise textDocument/completion so servers know to honor our
    # requests. ``snippetSupport: False`` keeps responses to plain-text
    # inserts — the editor doesn't render snippet placeholders, so a
    # snippet body would otherwise land in the buffer with literal
    # ``${1:foo}`` markers.
    var text_doc_caps = json_object()
    # Advertise willSave + willSaveWaitUntil so servers know they can ask
    # to react before a write (willSave) or inject edits before it
    # (willSaveWaitUntil — organize imports, final newline). Gated server
    # side off textDocumentSync.{willSave,willSaveWaitUntil}.
    var sync_caps = json_object()
    sync_caps.put(String("dynamicRegistration"), json_bool(False))
    sync_caps.put(String("willSave"), json_bool(True))
    sync_caps.put(String("willSaveWaitUntil"), json_bool(True))
    text_doc_caps.put(String("synchronization"), sync_caps)
    var completion_caps = json_object()
    var completion_item_caps = json_object()
    completion_item_caps.put(String("snippetSupport"), json_bool(False))
    completion_caps.put(String("completionItem"), completion_item_caps)
    text_doc_caps.put(String("completion"), completion_caps)
    # Advertise codeAction with ``codeActionLiteralSupport``. Without this,
    # servers like ty / pyright return only opaque ``Command`` entries
    # (or nothing) — we need the literal ``CodeAction`` form so we can
    # apply the carried ``WorkspaceEdit`` locally without a follow-up
    # ``workspace/executeCommand`` round-trip we don't model yet. The
    # valueSet is the set of kinds we render; ``""`` lets a server send
    # an unkinded action.
    var code_action_caps = json_object()
    var code_action_literal = json_object()
    var code_action_kind = json_object()
    var code_action_kinds = json_array()
    code_action_kinds.append(json_str(String("")))
    code_action_kinds.append(json_str(String("quickfix")))
    code_action_kind.put(String("valueSet"), code_action_kinds)
    code_action_literal.put(String("codeActionKind"), code_action_kind)
    code_action_caps.put(
        String("codeActionLiteralSupport"), code_action_literal,
    )
    code_action_caps.put(String("isPreferredSupport"), json_bool(True))
    # Declare that we can resolve an action's ``edit`` on demand, and that we
    # round-trip its opaque ``data`` field. Together these tell a server it
    # may return actions carrying only a title + data and defer the edit to
    # ``codeAction/resolve`` — which rust-analyzer does by default whether or
    # not the client asks, so the honest thing is to say we handle it (see
    # ``_start_code_action_resolves``). ``resolveSupport.properties`` lists
    # exactly what we'll fetch: the edit, nothing else.
    code_action_caps.put(String("dataSupport"), json_bool(True))
    var code_action_resolve = json_object()
    var code_action_resolve_props = json_array()
    code_action_resolve_props.append(json_str(String("edit")))
    code_action_resolve.put(
        String("properties"), code_action_resolve_props,
    )
    code_action_caps.put(String("resolveSupport"), code_action_resolve)
    text_doc_caps.put(String("codeAction"), code_action_caps)
    # Advertise textDocument/diagnostic (the LSP 3.17 pull model). Servers
    # that prefer pull (or only support it) won't push ``publishDiagnostics``
    # unless the client declares this; we then request a report per document
    # via ``request_pull_diagnostics``. ``relatedDocumentSupport: false`` —
    # we apply only the report's own ``items``, not related-document sets.
    var diagnostic_caps = json_object()
    diagnostic_caps.put(String("dynamicRegistration"), json_bool(True))
    diagnostic_caps.put(String("relatedDocumentSupport"), json_bool(False))
    text_doc_caps.put(String("diagnostic"), diagnostic_caps)
    # NB: we deliberately do NOT advertise ``textDocument/semanticTokens``.
    # LSP semantic highlighting (the server-computed recolor overlay on top
    # of the local TextMate pass) was removed: on a large file it costs the
    # server ~250 ms to compute full-file tokens on open and ~50 ms again
    # after every settled edit (ty has no token-delta support), for a
    # refinement we don't want. Not advertising the capability means servers
    # skip the work entirely. See docs/performance.md
    # "Removed feature: LSP semantic highlighting".
    capabilities.put(String("textDocument"), text_doc_caps)
    params.put(String("capabilities"), capabilities)
    return params^


def _trace_preview(msg: String) -> String:
    """``msg`` capped for the human-readable wire trace (full breakpoint
    lists, big stack traces etc. run to several KB)."""
    if len(msg.as_bytes()) <= 400:
        return msg
    return utf8_prefix(msg, 400) + String("…")


def file_uri_to_path(uri: String) -> String:
    """Strip the ``file://`` scheme and percent-decode ``%XX`` escapes
    (spec-compliant servers encode spaces / non-ASCII in path bytes; an
    undecoded ``%20`` wouldn't match a ``_docs`` entry or open on
    disk). A malformed ``%`` is left as a literal byte."""
    if not uri.startswith("file://"):
        return uri
    var ub = uri.as_bytes()
    var out = List[UInt8]()
    var i = 7    # past ``file://``
    while i < len(ub):
        if ub[i] == 0x25 and i + 2 < len(ub):   # '%XX'
            var hi = hex_digit_value(Int(ub[i + 1]))
            var lo = hex_digit_value(Int(ub[i + 2]))
            if hi >= 0 and lo >= 0:
                out.append(UInt8((hi << 4) | lo))
                i += 3
                continue
        out.append(ub[i])
        i += 1
    return String(StringSpan(unsafe_from_utf8=Span(unsafe_ptr=out.unsafe_ptr(), length=len(out))))


def json_rpc_id(v: JsonValue) -> String:
    """Canonicalize a JSON-RPC id (``integer | string``) to a String so
    callers can compare against ``_inflight_*_id`` (always String).

    Our own outgoing requests already stringify their ids in
    ``LspClient.send_request``, so any response paired with a request
    we issued comes back as a string the server echoed verbatim. But a
    server free to interpret-and-rewrite would still be spec-compliant
    re-emitting the same digits as a JSON integer — so we accept both
    shapes. Returns ``""`` for ids of any other JSON type (null,
    object, array — none are legal, but better to skip than crash).
    """
    if v.is_string():
        return v.as_str()
    if v.is_int():
        return String(v.as_int())
    return String("")
