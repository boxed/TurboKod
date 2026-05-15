"""Spawn a child under a controlling pseudo-terminal.

The terminal pane uses this instead of plain pipes because programs
that need a real TTY (``claude``, ``vim``, ``less``, ``htop``, …)
either refuse to run or silently switch into non-interactive modes
when given a pipe. A pty satisfies their ``isatty(3)`` check and lets
them emit cursor-positioning escapes that a vt100-ish emulator on the
parent side can interpret into the on-screen grid.

The pty itself is a single bidirectional fd on the parent side — the
``master``. Writes go to the child's stdin; reads come from the
child's stdout *and* stderr (the kernel merges them on the slave
side, same as a real terminal does). The actual work of opening the
pty, forking with ``setsid`` + ``TIOCSCTTY``, and ``execvp`` is in
``process_shim.c`` — see ``tk_pty_spawn`` for why we don't use
``posix_spawn`` here.
"""

from std.collections.list import List
from std.ffi import external_call

from .lsp import ArgvBuffer, _build_argv_buffer
from .posix import close_fd, kill_pid, SIGTERM, untrack_child, waitpid_nohang


struct PtyProcess(Copyable, Movable):
    """A spawned pty child plus the parent-side master fd.

    Bidirectional: read from ``master_fd`` to get the child's combined
    stdout+stderr; write to it to send keystrokes. ``alive`` is the
    same one-shot flag pattern as ``LspProcess`` — set to False once
    we observe the child has exited (via ``waitpid_nohang``) so the
    drain loop stops trying.

    ``Copyable`` is declared so the containing ``TerminalPane`` can
    satisfy ``Copyable`` itself; the manual ``__copyinit__`` produces a
    fresh inert sentinel rather than aliasing the pid + master fd. Live
    panes should never hit this branch — they grow via ``^`` transfer."""
    var pid: Int32
    var master_fd: Int32
    var alive: Bool

    def __init__(out self):
        self.pid = -1
        self.master_fd = -1
        self.alive = False

    def __copyinit__(mut self, copy: Self):
        self.pid = -1
        self.master_fd = -1
        self.alive = False

    @staticmethod
    def spawn(
        argv: List[String],
        cwd: String = String(""),
        cols: Int = 80,
        rows: Int = 24,
        term: String = String("xterm-256color"),
    ) raises -> Self:
        """Run ``argv`` with stdin/stdout/stderr wired to a fresh pty.

        ``cwd`` (when non-empty) is chdir'd into in the child before
        exec. ``cols`` × ``rows`` is the initial window size — programs
        compute their layout off it on first paint, so passing the
        actual pane size here saves a SIGWINCH redraw cycle. ``term``
        sets ``TERM`` in the child; ``xterm-256color`` is the standard
        baseline that gives us 256 colors + most modern escape
        sequences without requiring a custom terminfo entry.
        """
        if len(argv) == 0:
            raise Error("argv must not be empty")
        # Build the C argv array (NUL-terminated blob + pointer table).
        # Same idiom as ``LspProcess.spawn`` so the lifetime semantics
        # are identical: keep ``argv_buf`` alive until after the
        # external_call returns.
        var argv_buf = _build_argv_buffer(argv)
        # Out-params for the shim. We pass two distinct buffers — one
        # for the pid, one for the master fd — rather than a single
        # 8-byte buffer with two pointers into it because Mojo's borrow
        # checker treats aliased pointers into the same backing storage
        # as a write conflict in the ``external_call`` argument list.
        var pid_buf = List[UInt8]()
        for _ in range(4):
            pid_buf.append(0)
        var fd_buf = List[UInt8]()
        for _ in range(4):
            fd_buf.append(0)
        # NUL-terminate the C string args.
        var c_file = argv[0] + String("\0")
        var c_cwd = cwd + String("\0")
        var c_term = term + String("\0")
        var rc = external_call["tk_pty_spawn", Int32](
            c_file.unsafe_ptr(),
            argv_buf.pointers.unsafe_ptr(),
            c_cwd.unsafe_ptr(),
            Int32(cols),
            Int32(rows),
            c_term.unsafe_ptr(),
            pid_buf.unsafe_ptr(),       # *pid_out
            fd_buf.unsafe_ptr(),        # *master_fd_out
        )
        if Int(rc) != 0:
            raise Error("tk_pty_spawn failed")
        var pid_ptr    = pid_buf.unsafe_ptr().bitcast[Int32]()
        var master_ptr = fd_buf.unsafe_ptr().bitcast[Int32]()
        var proc = PtyProcess()
        proc.pid       = pid_ptr[0]
        proc.master_fd = master_ptr[0]
        proc.alive     = True
        return proc^

    def set_winsize(self, cols: Int, rows: Int) -> Int:
        """Re-send window size to the kernel. The child gets a
        SIGWINCH and (if it handles it) repaints at the new size.
        Returns 0 on success, -1 on failure."""
        if self.master_fd < 0:
            return -1
        return Int(external_call["tk_pty_set_winsize", Int32](
            self.master_fd, Int32(cols), Int32(rows),
        ))

    def write_bytes(self, ptr: UnsafePointer[UInt8, _], n: Int) -> Int:
        """Best-effort non-blocking write to the master. Returns the
        byte count actually written (may be < ``n``). ``tk_write_nb``
        returns 0 on EAGAIN, which we surface to the caller — the
        emulator's input path is keystroke-sized so a partial write
        is essentially never seen in practice, but we want truthful
        return values for any caller that wants to back off."""
        if self.master_fd < 0 or n <= 0:
            return 0
        var rc = external_call["tk_write_nb", Int](
            self.master_fd, ptr, UInt(n),
        )
        if rc < 0:
            return -1
        return Int(rc)

    def terminate(mut self):
        """SIGTERM the child and close the master fd. Safe to call
        more than once; subsequent calls are no-ops. The kill +
        waitpid + untrack sequence mirrors what
        ``TerminalPane._terminate_shell`` did for the pipe child."""
        if not self.alive:
            return
        if self.pid > 0:
            _ = kill_pid(self.pid, SIGTERM)
            var _pair = waitpid_nohang(self.pid)
            untrack_child(self.pid)
        self.alive = False
        if self.master_fd >= 0:
            _ = close_fd(self.master_fd)
            self.master_fd = -1
