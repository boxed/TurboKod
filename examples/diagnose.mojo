"""Diagnostic: print everything we know about querying terminal size.

No alt screen — output stays in your scrollback for sharing. Briefly enters
raw mode to test the cursor-position query path.

Run with::

    pixi run diagnose
"""

from std.ffi import external_call

from mojovision.posix import (
    O_RDWR, STDERR_FD, STDIN_FD, STDOUT_FD, TCSANOW, TERMIOS_SIZE,
    alloc_zero_buffer, cfmakeraw, get_window_size, query_size_via_cursor,
    query_winsize, tcgetattr, tcsetattr, tiocgwinsz,
)


fn _isatty(fd: Int32) -> Bool:
    return external_call["isatty", Int32](fd) == Int32(1)


fn _report_ioctl(label: String, fd: Int32):
    var size = query_winsize(fd)
    print(label, "(fd =", fd, ", isatty =", _isatty(fd), "):",
          size[0], "x", size[1])


fn main() raises:
    print("--- mojovision terminal size diagnostics ---")
    print("TIOCGWINSZ =", hex(tiocgwinsz()))
    print()
    print("ioctl(TIOCGWINSZ) per fd:")
    _report_ioctl(String("  stdout"), STDOUT_FD)
    _report_ioctl(String("  stderr"), STDERR_FD)
    _report_ioctl(String("  stdin "), STDIN_FD)

    var path = String("/dev/tty\0")
    var tty_fd = external_call["open", Int32](path.unsafe_ptr(), O_RDWR)
    if tty_fd >= 0:
        _report_ioctl(String("  /dev/tty"), tty_fd)
        _ = external_call["close", Int32](tty_fd)
    else:
        print("  /dev/tty open failed:", Int(tty_fd))

    var via_ioctl = get_window_size()
    print("get_window_size() ->", via_ioctl[0], "x", via_ioctl[1])

    print()
    print("Cursor-query path (CSI 6 n) — briefly entering raw mode...")
    if not _isatty(STDIN_FD):
        print("  stdin is not a TTY; skipping (would block forever)")
        return

    var orig = alloc_zero_buffer(TERMIOS_SIZE)
    if tcgetattr(STDIN_FD, orig) != 0:
        print("  tcgetattr failed; skipping")
        return
    var raw = alloc_zero_buffer(TERMIOS_SIZE)
    for i in range(TERMIOS_SIZE):
        raw[i] = orig[i]
    cfmakeraw(raw)
    if tcsetattr(STDIN_FD, TCSANOW, raw) != 0:
        print("  tcsetattr failed; skipping")
        return

    var via_cursor = query_size_via_cursor(STDIN_FD, STDOUT_FD, Int32(1000))
    _ = tcsetattr(STDIN_FD, TCSANOW, orig)
    # Manually emit a CR/LF since raw mode strips them.
    print()
    print("query_size_via_cursor ->", via_cursor[0], "x", via_cursor[1])
