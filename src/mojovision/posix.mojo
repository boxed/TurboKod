"""Thin libc bindings for the syscalls the terminal driver needs.

Pure Mojo via ``external_call`` — no Python interop, no ncurses. We bind only
what the rest of the package uses: termios (raw mode), ioctl (window size),
poll (timeout-aware input wait), read (stdin bytes). Stdout writes go through
``std.io.file_descriptor.FileDescriptor`` because Mojo reserves the bare
``write`` external_call symbol for its own use.

Where C functions take an opaque struct pointer (termios, winsize, pollfd) we
allocate a ``List[UInt8]`` of conservative size and pass its raw pointer at the
call site, never through a wrapper-function arg type. Mojo's ``UnsafePointer``
needs an explicit origin parameter when used in a function signature; inlining
the ``external_call`` avoids that whole song and dance.
"""

from std.collections.list import List
from std.ffi import external_call
from std.io.file_descriptor import FileDescriptor
from std.memory.span import Span
from std.sys.info import CompilationTarget


# --- Constants --------------------------------------------------------------

comptime STDIN_FD: Int32 = 0
comptime STDOUT_FD: Int32 = 1
comptime STDERR_FD: Int32 = 2

comptime TCSANOW: Int32 = 0
comptime TCSADRAIN: Int32 = 1

comptime O_RDWR: Int32 = 2

# Signals — POSIX defines SIGTERM=15 and SIGKILL=9 across platforms.
comptime SIGTERM: Int32 = 15
comptime SIGKILL: Int32 = 9
# ``waitpid`` flag: don't block.
comptime WNOHANG: Int32 = 1

# Sizes for opaque ``posix_spawn`` data — Darwin uses ~72B, Linux glibc
# slightly more. 256B is a comfortable upper bound for both.
comptime POSIX_SPAWN_FILE_ACTIONS_SIZE: Int = 256
comptime POSIX_SPAWN_ATTR_SIZE: Int = 256


fn o_nonblock_value() -> Int32:
    """``O_NONBLOCK`` differs by platform: Darwin 0x0004, Linux 0x800."""
    comptime if CompilationTarget.is_macos():
        return 0x0004
    else:
        return 0x800


fn fcntl_setfl_value() -> Int32:
    """``F_SETFL`` is 4 everywhere we target."""
    return 4


fn tciflush_value() -> Int32:
    """Platform-specific value for ``TCIFLUSH`` (discard input queue).

    Linux defines TCIFLUSH=0; the BSDs (incl. Darwin) define TCIFLUSH=1.
    """
    comptime if CompilationTarget.is_macos():
        return 1
    else:
        return 0

# `struct termios` is at most ~72 bytes on the platforms we target; round up.
comptime TERMIOS_SIZE: Int = 128

# `struct winsize` = { unsigned short ws_row, ws_col, ws_xpixel, ws_ypixel; } = 8B.
comptime WINSIZE_SIZE: Int = 8

# ``struct timespec { time_t tv_sec; long tv_nsec; }`` — 16 bytes on every
# 64-bit platform we target.
comptime TIMESPEC_SIZE: Int = 16


fn clock_monotonic_id() -> Int32:
    """``CLOCK_MONOTONIC`` differs across platforms — Linux defines it
    as 1, Darwin as 6. Hardcoding the Linux value made every call to
    ``clock_gettime`` fail on macOS (returning 0 here, which broke
    every UI debounce that depended on the clock)."""
    comptime if CompilationTarget.is_macos():
        return 6
    else:
        return 1

# `struct pollfd` = { int fd; short events; short revents; } = 8B.
comptime POLLFD_SIZE: Int = 8
comptime POLLIN: Int16 = 0x0001


fn tiocgwinsz() -> UInt:
    """Platform-specific ioctl request number for getting window size."""
    comptime if CompilationTarget.is_macos():
        return 0x40087468
    else:
        return 0x5413


fn alloc_zero_buffer(n: Int) -> List[UInt8]:
    var buf = List[UInt8]()
    for _ in range(n):
        buf.append(0)
    return buf^


# --- Termios ----------------------------------------------------------------


fn tcgetattr(fd: Int32, mut termios_buf: List[UInt8]) -> Int32:
    return external_call["tcgetattr", Int32](fd, termios_buf.unsafe_ptr())


fn tcsetattr(fd: Int32, action: Int32, mut termios_buf: List[UInt8]) -> Int32:
    return external_call["tcsetattr", Int32](fd, action, termios_buf.unsafe_ptr())


fn cfmakeraw(mut termios_buf: List[UInt8]):
    _ = external_call["cfmakeraw", Int32](termios_buf.unsafe_ptr())


fn tcflush(fd: Int32, queue_selector: Int32) -> Int32:
    """Discard the queued input/output bytes on ``fd``.

    Use ``tciflush_value()`` for input-queue flush. Used at shutdown to
    drop in-flight mouse reports that arrived after we disabled mouse
    tracking but before we restore canonical mode + ECHO — without this
    they get echoed verbatim by the line discipline as ``^[[<…M``.
    """
    return external_call["tcflush", Int32](fd, queue_selector)


# --- Monotonic clock --------------------------------------------------------


fn monotonic_ms() -> Int:
    """Milliseconds from a monotonic source (``CLOCK_MONOTONIC``).

    The absolute value is unspecified — it's only meaningful as a
    difference between two readings — but the reading never goes
    backwards, which is what UI debouncing relies on. Returns ``0`` if
    the syscall fails (a clean fallback: callers comparing two readings
    just see "no time has passed" and behave as if firing immediately).
    """
    var ts = alloc_zero_buffer(TIMESPEC_SIZE)
    var rc = external_call["clock_gettime", Int32](
        clock_monotonic_id(), ts.unsafe_ptr(),
    )
    if Int(rc) != 0:
        return 0
    var sec = Int(ts.unsafe_ptr().bitcast[Int64]()[0])
    var nsec = Int(ts.unsafe_ptr().bitcast[Int64]()[1])
    return sec * 1000 + nsec // 1_000_000


# --- I/O multiplexing -------------------------------------------------------


fn poll_stdin(fd: Int32, timeout_ms: Int32) -> Bool:
    """Return True if ``fd`` has data ready within ``timeout_ms``.

    We poll exactly one fd asking for POLLIN, so ``n > 0`` from poll already
    means "POLLIN is set on our fd" — we don't need to re-read revents (which
    would risk a use-after-free if Mojo drops ``pfd`` between the syscall and
    the read).
    """
    var pfd = alloc_zero_buffer(POLLFD_SIZE)
    # Layout: int fd (4B), short events (2B), short revents (2B).
    pfd.unsafe_ptr().bitcast[Int32]()[0] = fd
    pfd.unsafe_ptr().bitcast[Int16]()[2] = POLLIN
    pfd.unsafe_ptr().bitcast[Int16]()[3] = Int16(0)
    var n = external_call["poll", Int32](pfd.unsafe_ptr(), UInt(1), timeout_ms)
    return Int(n) > 0


# --- Reading raw bytes ------------------------------------------------------


fn read_into(fd: Int32, mut buf: List[UInt8], count: Int) -> Int:
    return external_call["read", Int](fd, buf.unsafe_ptr(), count)


# --- Window size ------------------------------------------------------------


fn query_winsize(fd: Int32) -> Tuple[Int, Int]:
    """``(cols, rows)`` for ``fd``, or ``(0, 0)`` if not a TTY.

    Note: ``ioctl(2)`` is variadic in C and Mojo's ``external_call`` doesn't
    model variadic ABI. On most Unixes this still works because the libc
    ``ioctl`` shim normalizes the calling convention before tail-calling the
    syscall stub, but if you see this returning ``(0, 0)`` for a real TTY
    that's the suspect.
    """
    if fd < 0:
        return (0, 0)
    var ws = alloc_zero_buffer(WINSIZE_SIZE)
    var rc = external_call["ioctl", Int32](fd, tiocgwinsz(), ws.unsafe_ptr())
    if Int(rc) != 0:
        return (0, 0)
    var p = ws.unsafe_ptr().bitcast[UInt16]()
    var rows = Int(p[0])
    var cols = Int(p[1])
    return (cols, rows)


fn get_window_size() -> Tuple[Int, Int]:
    """Find ``(cols, rows)`` by querying any TTY-attached file descriptor.

    Tries stdout, stderr, stdin, then opens ``/dev/tty`` directly. This matters
    because launchers like ``pixi run`` may pipe stdin even when stdout is the
    real terminal — falling back silently to (80, 24) would prevent us from
    ever noticing the real size or a subsequent resize.
    """
    var size = query_winsize(STDOUT_FD)
    if size[0] > 0 and size[1] > 0:
        return size
    size = query_winsize(STDERR_FD)
    if size[0] > 0 and size[1] > 0:
        return size
    size = query_winsize(STDIN_FD)
    if size[0] > 0 and size[1] > 0:
        return size
    var tty_path = String("/dev/tty\0")
    var tty_fd = external_call["open", Int32](tty_path.unsafe_ptr(), O_RDWR)
    if tty_fd >= 0:
        size = query_winsize(tty_fd)
        _ = external_call["close", Int32](tty_fd)
        if size[0] > 0 and size[1] > 0:
            return size
    return (80, 24)


fn append_string_bytes(mut buf: List[UInt8], s: String):
    """Copy the raw UTF-8 bytes of ``s`` onto the end of ``buf``."""
    var src = s.as_bytes()
    for i in range(len(src)):
        buf.append(src[i])


fn write_buffer(fd: Int32, mut buf: List[UInt8]):
    """Write ``buf`` (a byte accumulator) to ``fd`` in one syscall."""
    if len(buf) == 0:
        return
    var f = FileDescriptor(Int(fd))
    f.write_bytes(Span(buf))


# --- Output -----------------------------------------------------------------


fn write_string(fd: Int32, s: String):
    """Write ``s`` to ``fd`` via ``FileDescriptor.write_string``."""
    var f = FileDescriptor(Int(fd))
    f.write_string(StringSlice(s))


# --- Path resolution --------------------------------------------------------


# --- Subprocess plumbing ---------------------------------------------------
# Used by ``lsp.mojo`` to spawn an LSP server with three pipes hooked onto
# its stdin/stdout/stderr. Everything here is non-variadic and reachable
# through ``external_call``; we deliberately avoid ``fork()`` because Mojo
# runtime state in the child between fork and execve is undefined.


fn pipe_pair() raises -> Tuple[Int32, Int32]:
    """``pipe(int[2])`` → ``(read_fd, write_fd)``. Raises on failure."""
    var fds = alloc_zero_buffer(8)   # int[2] = 8 bytes
    var rc = external_call["pipe", Int32](fds.unsafe_ptr())
    if Int(rc) != 0:
        raise Error("pipe() failed")
    var p = fds.unsafe_ptr().bitcast[Int32]()
    return (p[0], p[1])


fn close_fd(fd: Int32) -> Int32:
    """Wrap ``close(2)`` so callers don't have to write external_call inline."""
    return external_call["close", Int32](fd)


fn set_nonblocking(fd: Int32) -> Bool:
    """Make ``fd`` non-blocking via ``fcntl(F_SETFL, O_NONBLOCK)``.

    The third arg of ``fcntl`` is technically variadic in C, but the
    register-passing convention for a single scalar is identical to a
    fixed-arity declaration on x86_64 SysV / ARM64 AAPCS. Returns True
    on success.
    """
    var rc = external_call["fcntl", Int32](
        fd, fcntl_setfl_value(), o_nonblock_value(),
    )
    return Int(rc) == 0


fn waitpid_blocking(pid: Int32) -> Int32:
    """Wait for ``pid`` and return the raw status int. Blocks. Use
    ``waitpid_nohang`` for a non-blocking poll."""
    var status = alloc_zero_buffer(4)
    _ = external_call["waitpid", Int32](pid, status.unsafe_ptr(), Int32(0))
    return status.unsafe_ptr().bitcast[Int32]()[0]


fn waitpid_nohang(pid: Int32) -> Tuple[Int32, Int32]:
    """``waitpid(pid, &status, WNOHANG)``. Returns ``(rc, status)`` —
    rc is 0 if the child hasn't exited, ``pid`` if it has, ``-1`` on error.
    """
    var status = alloc_zero_buffer(4)
    var rc = external_call["waitpid", Int32](pid, status.unsafe_ptr(), WNOHANG)
    return (rc, status.unsafe_ptr().bitcast[Int32]()[0])


fn kill_pid(pid: Int32, sig: Int32) -> Int32:
    """``kill(pid, sig)`` — signal-delivery only, doesn't reap. Caller is
    responsible for the subsequent ``waitpid``."""
    return external_call["kill", Int32](pid, sig)


# ``posix_spawn`` family. The opaque ``file_actions`` and ``attr`` buffers
# are sized via the ``*_SIZE`` constants above; the actual struct layouts
# are platform-private. We never inspect them — only pass pointers to the
# libc helpers.


fn posix_spawn_file_actions_init(mut buf: List[UInt8]) -> Int32:
    return external_call["posix_spawn_file_actions_init", Int32](
        buf.unsafe_ptr(),
    )


fn posix_spawn_file_actions_destroy(mut buf: List[UInt8]) -> Int32:
    return external_call["posix_spawn_file_actions_destroy", Int32](
        buf.unsafe_ptr(),
    )


fn posix_spawn_file_actions_addclose(mut buf: List[UInt8], fd: Int32) -> Int32:
    return external_call["posix_spawn_file_actions_addclose", Int32](
        buf.unsafe_ptr(), fd,
    )


fn posix_spawn_file_actions_adddup2(
    mut buf: List[UInt8], old_fd: Int32, new_fd: Int32,
) -> Int32:
    return external_call["posix_spawn_file_actions_adddup2", Int32](
        buf.unsafe_ptr(), old_fd, new_fd,
    )


fn posix_spawnattr_init(mut buf: List[UInt8]) -> Int32:
    return external_call["posix_spawnattr_init", Int32](buf.unsafe_ptr())


fn posix_spawnattr_destroy(mut buf: List[UInt8]) -> Int32:
    return external_call["posix_spawnattr_destroy", Int32](buf.unsafe_ptr())


fn posix_spawnp_call(
    mut argv_buf: List[UInt8],
    mut envp_buf: List[UInt8],
    mut file_actions: List[UInt8],
    program: String,
) raises -> Int32:
    """Wraps ``posix_spawnp(&pid, file, file_actions, &attr, argv, envp)``.

    ``argv_buf`` / ``envp_buf`` already hold the contiguous NULL-terminated
    pointer arrays. We always pass a properly-initialized (default) attr
    buffer rather than NULL — Mojo's external_call doesn't have a clean
    way to pass NULL for the 4th argument, and a default-init attr has
    the same effect on every platform we target.
    Returns the child PID. Raises on spawn failure.
    """
    var pid_buf = alloc_zero_buffer(4)
    var c_program = program + String("\0")
    var attr = alloc_zero_buffer(POSIX_SPAWN_ATTR_SIZE)
    if Int(posix_spawnattr_init(attr)) != 0:
        raise Error("posix_spawnattr_init failed")
    var rc = external_call["posix_spawnp", Int32](
        pid_buf.unsafe_ptr(),
        c_program.unsafe_ptr(),
        file_actions.unsafe_ptr(),
        attr.unsafe_ptr(),
        argv_buf.unsafe_ptr(),
        envp_buf.unsafe_ptr(),
    )
    _ = posix_spawnattr_destroy(attr)
    if Int(rc) != 0:
        raise Error("posix_spawnp failed")
    return pid_buf.unsafe_ptr().bitcast[Int32]()[0]


fn getenv_value(name: String) -> String:
    """Read ``name`` from the parent's environment, or "" when unset.

    Mojo's ``external_call`` can't easily return a typed C pointer, so we
    receive ``getenv`` 's char* as a raw address (``Int``), measure its
    length with ``strlen``, and copy the bytes through ``memcpy`` into a
    Mojo-owned buffer.
    """
    var c_name = name + String("\0")
    var addr = external_call["getenv", Int](c_name.unsafe_ptr())
    if addr == 0:
        return String("")
    var n = external_call["strlen", Int](addr)
    if n <= 0:
        return String("")
    var out = alloc_zero_buffer(n)
    _ = external_call["memcpy", Int](out.unsafe_ptr(), addr, n)
    return String(StringSlice(ptr=out.unsafe_ptr(), length=n))


fn which(name: String) -> String:
    """Locate ``name`` on ``$PATH`` and return its absolute path, or "".

    Walks ``PATH`` left-to-right, joins each entry with ``name``, and
    checks for an executable file via ``access(F_OK)`` + ``stat``. We
    don't shell out to ``which``: that would be a circular dependency
    when we're trying to discover whether a binary exists at all.
    """
    if len(name.as_bytes()) == 0:
        return String("")
    # If the name already contains a slash, it's a path — accept verbatim.
    var nb = name.as_bytes()
    for i in range(len(nb)):
        if nb[i] == 0x2F:
            return name
    var path_var = getenv_value(String("PATH"))
    var pb = path_var.as_bytes()
    var start = 0
    var i = 0
    while i <= len(pb):
        if i == len(pb) or pb[i] == 0x3A:
            if i > start:
                var entry = String(StringSlice(unsafe_from_utf8=pb[start:i]))
                var candidate = entry + String("/") + name
                var c_path = candidate + String("\0")
                # F_OK = 0 — just check existence; let posix_spawnp fail
                # later if it's not actually executable. Most binaries
                # users care about (rg, pyright, pylsp) are flagged +x.
                var rc = external_call["access", Int32](
                    c_path.unsafe_ptr(), Int32(0),
                )
                if Int(rc) == 0:
                    return candidate
            start = i + 1
        i += 1
    return String("")


fn realpath(path: String) -> String:
    """Return the canonical absolute form of ``path``, or empty on error.

    Uses ``realpath(3)`` with a 4096-byte resolved-path buffer (PATH_MAX is
    1024 on Darwin and 4096 on Linux; we pick the larger to be safe). The
    libc function returns NULL when the path doesn't exist or can't be
    resolved; we return ``""`` so the caller can fall back to the input.
    """
    var c_path = path + String("\0")
    var resolved = alloc_zero_buffer(4096)
    # Return type as Int: 0 means NULL, anything else means the buffer was
    # filled with a NUL-terminated absolute path.
    var rc = external_call["realpath", Int](
        c_path.unsafe_ptr(), resolved.unsafe_ptr()
    )
    if rc == 0:
        return String("")
    var n = 0
    while n < 4096 and resolved[n] != 0:
        n += 1
    return String(StringSlice(ptr=resolved.unsafe_ptr(), length=n))


# --- Cursor-position size query ---------------------------------------------


fn query_size_via_cursor(fd_in: Int32, fd_out: Int32, timeout_ms: Int32 = 500) -> Tuple[Int, Int]:
    """Send ``DECSC`` ``CSI 9999;9999 H`` ``CSI 6 n`` ``DECRC`` and parse the reply.

    The DEC Save/Restore Cursor pair (``ESC 7`` / ``ESC 8``) brackets the
    movement so the caller's cursor position is preserved — without that,
    the first call from a non-alt-screen context would overwrite whatever
    text the terminal already had at row 1.

    Caller must already have ``fd_in`` in raw, no-echo mode (otherwise the
    response will be processed by the line discipline and we won't see it).
    Returns ``(0, 0)`` if the terminal doesn't reply within ``timeout_ms``.
    """
    write_string(fd_out, String("\x1b7\x1b[9999;9999H\x1b[6n"))
    if not poll_stdin(fd_in, timeout_ms):
        write_string(fd_out, String("\x1b8"))
        return (0, 0)
    var buf = alloc_zero_buffer(64)
    var n = external_call["read", Int](fd_in, buf.unsafe_ptr(), Int(64))
    write_string(fd_out, String("\x1b8"))
    if n <= 0:
        return (0, 0)
    # Find the `R` terminator and walk back through `<digits>;<digits>`.
    var end = -1
    for i in range(n):
        if buf[i] == 0x52:  # 'R'
            end = i
            break
    if end < 4:
        return (0, 0)
    var i = end - 1
    var col = 0
    var place = 1
    while i >= 0 and buf[i] >= 0x30 and buf[i] <= 0x39:
        col += (Int(buf[i]) - 0x30) * place
        place *= 10
        i -= 1
    if i < 0 or buf[i] != 0x3B:  # ';'
        return (0, 0)
    i -= 1
    var row = 0
    place = 1
    while i >= 0 and buf[i] >= 0x30 and buf[i] <= 0x39:
        row += (Int(buf[i]) - 0x30) * place
        place *= 10
        i -= 1
    if col <= 0 or row <= 0:
        return (0, 0)
    return (col, row)
