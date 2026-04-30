"""Mouse probe: dump raw stdin bytes while mouse reporting is on.

No alt-screen, no event parsing — every byte the terminal sends is printed
as ``HH`` (hex) plus a visible ASCII rendering. Use this to see whether a
given gesture (cmd+click, alt+click, shift+click, etc.) actually reaches
the application, and what modifier bits the terminal encodes.

Quit with ``q``.

Run with::

    ./run.sh examples/mouse_probe.mojo
"""

from turbokod.posix import (
    STDIN_FD, STDOUT_FD, TCSANOW, TERMIOS_SIZE,
    alloc_zero_buffer, cfmakeraw, poll_stdin, read_into,
    tcgetattr, tcsetattr, write_string,
)


comptime SEQ_MOUSE_ON  = String("\x1b[?1002h\x1b[?1006h")
comptime SEQ_MOUSE_OFF = String("\x1b[?1006l\x1b[?1002l")
# Also try focus-in / any-event motion / extended modifiers, for diagnostics.
comptime SEQ_ANY_EVENT_ON  = String("\x1b[?1003h")
comptime SEQ_ANY_EVENT_OFF = String("\x1b[?1003l")


fn _hex_nibble(n: Int) -> String:
    if n < 10:
        return String(chr(0x30 + n))
    return String(chr(0x61 + (n - 10)))


fn _hex_byte(b: UInt8) -> String:
    var v = Int(b)
    return _hex_nibble(v >> 4) + _hex_nibble(v & 0xF)


fn _printable(b: UInt8) -> String:
    var v = Int(b)
    if v == 0x1B: return String("ESC")
    if v == 0x0D: return String("\\r")
    if v == 0x0A: return String("\\n")
    if v == 0x09: return String("\\t")
    if v < 0x20:  return String("^") + String(chr(0x40 + v))
    if v == 0x7F: return String("DEL")
    if v < 0x7F:  return String(chr(v))
    return String(".")


fn _decode_sgr_mouse(buf: List[UInt8], start: Int, end: Int) -> String:
    """If ``buf[start..end]`` looks like CSI < B ; X ; Y M|m, decode it."""
    if end - start < 6: return String("")
    if buf[start] != 0x1B or buf[start + 1] != 0x5B or buf[start + 2] != 0x3C:
        return String("")
    var nums = List[Int]()
    var cur = 0
    var i = start + 3
    var has = False
    var final: UInt8 = 0
    while i < end:
        var b = buf[i]
        if b >= 0x30 and b <= 0x39:
            cur = cur * 10 + Int(b) - 0x30
            has = True
        elif b == 0x3B:
            nums.append(cur); cur = 0; has = False
        elif b == 0x4D or b == 0x6D:
            if has: nums.append(cur)
            final = b
            break
        else:
            return String("")
        i += 1
    if final == 0 or len(nums) < 3: return String("")
    var raw = nums[0]
    var x = nums[1]
    var y = nums[2]
    var pressed = (final == 0x4D)
    var btn_text: String
    if (raw & 64) != 0:
        if (raw & 1) != 0: btn_text = String("WheelDown")
        else:              btn_text = String("WheelUp")
    elif (raw & 32) != 0:
        btn_text = String("Motion(")
        var bn = raw & 3
        if bn == 0:   btn_text = btn_text + String("Left)")
        elif bn == 1: btn_text = btn_text + String("Middle)")
        elif bn == 2: btn_text = btn_text + String("Right)")
        else:         btn_text = btn_text + String("None)")
    else:
        var bn = raw & 3
        if bn == 0:   btn_text = String("Left")
        elif bn == 1: btn_text = String("Middle")
        else:         btn_text = String("Right")
    var mods = String("")
    if (raw & 4)  != 0: mods = mods + String("+Shift")
    if (raw & 8)  != 0: mods = mods + String("+Alt")
    if (raw & 16) != 0: mods = mods + String("+Ctrl")
    var press_text: String
    if pressed: press_text = String("press")
    else:       press_text = String("release")
    return (
        String("    -> ") + btn_text + mods + String(" ") + press_text
        + String(" at (") + String(x) + String(",") + String(y) + String(")")
        + String(" raw=") + String(raw) + String("\r\n")
    )


fn _emit_burst(buf: List[UInt8], n: Int):
    """Write one human-readable line per read() burst."""
    var hex_part = String("")
    var asc_part = String("")
    for i in range(n):
        if i > 0:
            hex_part = hex_part + String(" ")
            asc_part = asc_part + String(" ")
        hex_part = hex_part + _hex_byte(buf[i])
        asc_part = asc_part + _printable(buf[i])
    write_string(STDOUT_FD, String("[") + String(n) + String("B] ") + hex_part
                            + String("  | ") + asc_part + String("\r\n"))
    # Try to also decode the burst as an SGR mouse report.
    var decoded = _decode_sgr_mouse(buf, 0, n)
    if len(decoded.as_bytes()) > 0:
        write_string(STDOUT_FD, decoded)


fn main() raises:
    write_string(STDOUT_FD, String(
        "Mouse probe — click / drag / scroll in this window. Press 'q' to quit.\r\n"
        "Modifiers reported by the terminal: Shift, Alt(Meta), Ctrl.\r\n"
        "Cmd is *not* part of the SGR mouse protocol; if it shows up at all,\r\n"
        "iTerm2 must be configured to translate it into a key/escape sequence.\r\n"
        "\r\n"
    ))

    var orig = alloc_zero_buffer(TERMIOS_SIZE)
    if tcgetattr(STDIN_FD, orig) != 0:
        write_string(STDOUT_FD, String("tcgetattr failed; not a TTY?\r\n"))
        return
    var raw = alloc_zero_buffer(TERMIOS_SIZE)
    for i in range(TERMIOS_SIZE):
        raw[i] = orig[i]
    cfmakeraw(raw)
    if tcsetattr(STDIN_FD, TCSANOW, raw) != 0:
        write_string(STDOUT_FD, String("tcsetattr failed\r\n"))
        return

    write_string(STDOUT_FD, SEQ_MOUSE_ON)
    write_string(STDOUT_FD, SEQ_ANY_EVENT_ON)

    var buf = alloc_zero_buffer(256)
    var quit = False
    try:
        while not quit:
            if not poll_stdin(STDIN_FD, Int32(200)):
                continue
            var n = read_into(STDIN_FD, buf, 256)
            if n <= 0:
                continue
            _emit_burst(buf, n)
            for i in range(n):
                if buf[i] == UInt8(ord("q")):
                    quit = True
                    break
                # Ctrl-C also quits, just in case.
                if buf[i] == UInt8(0x03):
                    quit = True
                    break
    finally:
        write_string(STDOUT_FD, SEQ_ANY_EVENT_OFF)
        write_string(STDOUT_FD, SEQ_MOUSE_OFF)
        _ = tcsetattr(STDIN_FD, TCSANOW, orig)
        write_string(STDOUT_FD, String("\r\nbye.\r\n"))
