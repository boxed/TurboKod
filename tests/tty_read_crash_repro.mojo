"""Minimal reproducer for a Mojo TTY-read crash.

Run interactively (NOT via redirection):

    pixi run mojo run tests/tty_read_crash_repro.mojo

What it does:

1. Puts ``stdin`` into raw mode.
2. Enters a tight loop of ``poll`` + ``read(2)`` on STDIN, plus a
   parallel stream of ``read(2)`` calls on a self-built pipe (mimics
   what turbokod's LSP/DAP framers do — those reads work fine).
3. Press a few keys. Type some text, scroll the wheel, click around.
4. Eventually the process segfaults inside ``read(0, ptr, n)``.

The same ``external_call["read", Int]`` shape that segfaults on STDIN
works for the pipe FD throughout. The crash is consistent and
reproducible after a few hundred frames of activity.

Filed as a Mojo bug — see the comment in
``src/turbokod/terminal.mojo`` for the workaround status.
"""

from std.collections.list import List
from std.ffi import external_call

from turbokod.posix import (
    STDIN_FD, TCSANOW, TERMIOS_SIZE,
    alloc_zero_buffer, cfmakeraw, pipe_pair, poll_stdin,
    tcgetattr, tcsetattr, write_buffer,
)


fn main() raises:
    var orig = alloc_zero_buffer(TERMIOS_SIZE)
    if tcgetattr(STDIN_FD, orig) != 0:
        print("not a tty?")
        return
    var raw = alloc_zero_buffer(TERMIOS_SIZE)
    for i in range(TERMIOS_SIZE):
        raw[i] = orig[i]
    cfmakeraw(raw)
    _ = tcsetattr(STDIN_FD, TCSANOW, raw)
    print("raw mode on; press any keys, Ctrl+C to exit")

    # Self-built pipe to compare against. Reads here never crash.
    var pp = pipe_pair()
    var pipe_r = pp[0]
    var pipe_w = pp[1]

    var stdin_buf = alloc_zero_buffer(1024)
    var pipe_buf = alloc_zero_buffer(1024)
    var iter = 0
    try:
        while iter < 10000:
            iter += 1
            # Pipe round-trip: write a byte, read it back. Should
            # always succeed.
            var src = alloc_zero_buffer(1)
            src[0] = UInt8(iter & 0xFF)
            write_buffer(pipe_w, src)
            var pn = external_call["read", Int](
                pipe_r, pipe_buf.unsafe_ptr(), 1024,
            )
            # Stdin: poll then read.
            if poll_stdin(STDIN_FD, Int32(50)):
                var sn = external_call["read", Int](
                    STDIN_FD, stdin_buf.unsafe_ptr(), 1024,
                )
                # If we get here, print the count and what we read.
                # Use stderr so it doesn't interleave with raw input.
                print("iter=", iter, " stdin_n=", sn, " pipe_n=", pn)
                # Detect Ctrl+C (raw mode = literal 0x03).
                if sn > 0 and stdin_buf[0] == 0x03:
                    break
    finally:
        _ = tcsetattr(STDIN_FD, TCSANOW, orig)
