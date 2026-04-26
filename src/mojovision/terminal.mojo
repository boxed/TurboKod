"""Terminal driver: raw mode, ANSI output, escape-sequence input parsing.

Pure Mojo: no Python interop, no ncurses. The OS-level work (termios, ioctl,
poll, read) is delegated to ``posix.mojo`` which wraps libc through
``external_call``. Stdout writes go through ``std.io.file_descriptor``.

Cell diffing and the escape-sequence → Event parser are pure Mojo and don't
touch the OS at all, so they're easy to unit-test (see ``tests/test_basic.mojo``).
"""

from std.collections.list import List
from std.collections.optional import Optional

from .canvas import Canvas
from .cell import Cell, blank_cell
from .colors import Attr, attr_to_sgr, default_attr
from .events import (
    Event, EVENT_KEY, EVENT_RESIZE, EVENT_QUIT,
    KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT,
    KEY_HOME, KEY_END, KEY_PAGEUP, KEY_PAGEDOWN, KEY_INSERT, KEY_DELETE,
    KEY_F1, KEY_F2, KEY_F3, KEY_F4, KEY_F5, KEY_F6,
    KEY_F7, KEY_F8, KEY_F9, KEY_F10, KEY_F11, KEY_F12,
    KEY_ENTER, KEY_TAB, KEY_BACKSPACE, KEY_ESC,
    MOD_NONE, MOD_SHIFT, MOD_ALT, MOD_CTRL,
    MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT,
    MOUSE_WHEEL_UP, MOUSE_WHEEL_DOWN,
)
from .geometry import Point
from .posix import (
    STDIN_FD, STDOUT_FD, TCSANOW, TERMIOS_SIZE,
    alloc_zero_buffer, append_string_bytes, cfmakeraw, get_window_size,
    poll_stdin, query_size_via_cursor, read_into, tcgetattr, tcsetattr,
    write_buffer, write_string,
)


# --- ANSI sequences ---------------------------------------------------------

comptime ESC = String("\x1b")
comptime CSI = String("\x1b[")

comptime SEQ_ALT_SCREEN_ON  = String("\x1b[?1049h")
comptime SEQ_ALT_SCREEN_OFF = String("\x1b[?1049l")
comptime SEQ_CURSOR_HIDE    = String("\x1b[?25l")
comptime SEQ_CURSOR_SHOW    = String("\x1b[?25h")
comptime SEQ_RESET          = String("\x1b[0m")
comptime SEQ_CLEAR_SCREEN   = String("\x1b[2J")
comptime SEQ_CURSOR_HOME    = String("\x1b[H")
# Mouse: 1002 = button-event tracking (motion only when held); 1006 = SGR encoding.
comptime SEQ_MOUSE_ON  = String("\x1b[?1002h\x1b[?1006h")
comptime SEQ_MOUSE_OFF = String("\x1b[?1006l\x1b[?1002l")


fn move_cursor(x: Int, y: Int) -> String:
    """1-based row;col cursor positioning."""
    return CSI + String(y + 1) + String(";") + String(x + 1) + String("H")


# --- Terminal driver --------------------------------------------------------


struct Terminal:
    """Owns the OS-level terminal state.

    Call ``start()`` before using and ``stop()`` (in a ``finally`` block) when
    done. Mojo's context-manager protocol details have shifted across versions
    enough that an explicit start/stop pair is the most portable shape.
    """

    var _orig_termios: List[UInt8]
    var _started: Bool
    var _front: Canvas
    var _queue: List[Event]
    var _resize_poll_counter: Int
    var width: Int
    var height: Int

    fn __init__(out self) raises:
        self._orig_termios = alloc_zero_buffer(TERMIOS_SIZE)
        self._started = False
        self._queue = List[Event]()
        self._resize_poll_counter = 0
        var size = get_window_size()
        self.width = size[0]
        self.height = size[1]
        self._front = Canvas(self.width, self.height)

    fn start(mut self) raises:
        if self._started:
            return
        # Save current termios so stop() can restore it, then enter raw mode.
        if tcgetattr(STDIN_FD, self._orig_termios) != 0:
            raise Error("tcgetattr failed — stdin is not a TTY")
        var raw = alloc_zero_buffer(TERMIOS_SIZE)
        for i in range(TERMIOS_SIZE):
            raw[i] = self._orig_termios[i]
        cfmakeraw(raw)
        if tcsetattr(STDIN_FD, TCSANOW, raw) != 0:
            raise Error("tcsetattr failed")
        write_string(STDOUT_FD, SEQ_ALT_SCREEN_ON)
        write_string(STDOUT_FD, SEQ_CURSOR_HIDE)
        # Ask the terminal directly for its size *before* turning on mouse
        # reporting — the response (CSI <row>;<col> R) is easier to parse
        # when no other input can interleave.
        var measured = self._query_size_via_cursor()
        if measured[0] > 0 and measured[1] > 0:
            self.width = measured[0]
            self.height = measured[1]
            self._front.resize(self.width, self.height)
        write_string(STDOUT_FD, SEQ_MOUSE_ON)
        write_string(STDOUT_FD, SEQ_CLEAR_SCREEN)
        write_string(STDOUT_FD, SEQ_CURSOR_HOME)
        self._started = True

    fn _query_size_via_cursor(mut self) -> Tuple[Int, Int]:
        return query_size_via_cursor(STDIN_FD, STDOUT_FD)

    fn stop(mut self) raises:
        if not self._started:
            return
        write_string(STDOUT_FD, SEQ_MOUSE_OFF)
        write_string(STDOUT_FD, SEQ_RESET)
        write_string(STDOUT_FD, SEQ_CURSOR_SHOW)
        write_string(STDOUT_FD, SEQ_ALT_SCREEN_OFF)
        _ = tcsetattr(STDIN_FD, TCSANOW, self._orig_termios)
        self._started = False

    fn refresh_size(mut self) raises -> Bool:
        """Re-query terminal dimensions; return True if they changed.

        ``ioctl(TIOCGWINSZ)`` doesn't work via Mojo's ``external_call`` on
        macOS arm64 (variadic ABI mismatch), so we fall back to the cursor
        position query. To avoid racing with user input we:

        - throttle to ~1 Hz (every 20 calls at the default 50 ms cadence);
        - skip when the event queue still has buffered input;
        - skip when stdin already has bytes ready to read.

        Stray bytes that nevertheless mix in with the cursor response are
        discarded inside ``query_size_via_cursor`` — losing a key here is
        much better than the heap corruption an earlier requeue path caused.
        """
        self._resize_poll_counter += 1
        if self._resize_poll_counter < 20:
            return False
        if len(self._queue) > 0:
            return False
        if poll_stdin(STDIN_FD, Int32(0)):
            return False
        self._resize_poll_counter = 0
        var size = query_size_via_cursor(STDIN_FD, STDOUT_FD, Int32(50))
        if size[0] > 0 and (size[0] != self.width or size[1] != self.height):
            self.width = size[0]
            self.height = size[1]
            return True
        return False

    fn present(mut self, back: Canvas) raises:
        """Diff the back canvas against our front, write only what changed.

        Output is accumulated into a ``List[UInt8]`` and flushed in a single
        ``write()`` syscall. Building one big ``String`` via ``+=`` would be
        catastrophic on a full-screen canvas (12000+ cells of incremental
        concatenation), and on real terminals dragged to ~200×60 it crashed
        the allocator within seconds.
        """
        if back.width != self._front.width or back.height != self._front.height:
            self._front.resize(back.width, back.height)
            write_string(STDOUT_FD, SEQ_CLEAR_SCREEN)
        var buf = List[UInt8]()
        var last_attr = default_attr()
        var last_attr_valid = False
        var cursor_known_x = -1
        var cursor_known_y = -1
        for y in range(back.height):
            for x in range(back.width):
                var nc = back.get(x, y)
                var oc = self._front.get(x, y)
                if nc == oc:
                    continue
                if cursor_known_x != x or cursor_known_y != y:
                    append_string_bytes(buf, move_cursor(x, y))
                if (not last_attr_valid) or last_attr != nc.attr:
                    append_string_bytes(buf, CSI)
                    append_string_bytes(buf, attr_to_sgr(nc.attr))
                    buf.append(0x6D)  # 'm'
                    last_attr = nc.attr
                    last_attr_valid = True
                append_string_bytes(buf, nc.glyph)
                cursor_known_x = x + 1
                cursor_known_y = y
                self._front.set(x, y, nc)
        write_buffer(STDOUT_FD, buf)

    fn poll_event(mut self, timeout_ms: Int = 50) raises -> Optional[Event]:
        """Return the next buffered event, or block up to ``timeout_ms`` reading more.

        Each ``read()`` burst (e.g. several SGR mouse reports during a drag) is
        parsed into individual events and queued; subsequent calls drain the
        queue without blocking.
        """
        if len(self._queue) > 0:
            return self._queue.pop(0)
        if not poll_stdin(STDIN_FD, Int32(timeout_ms)):
            return None
        var buf = alloc_zero_buffer(1024)
        var n = read_into(STDIN_FD, buf, 1024)
        if n <= 0:
            return None
        var bytes = StringSlice(ptr=buf.unsafe_ptr(), length=n).as_bytes()
        var pos = 0
        while pos < n:
            var slice = String(StringSlice(unsafe_from_utf8=bytes[pos:]))
            var parsed = parse_input(slice)
            self._queue.append(parsed[0])
            var consumed = parsed[1]
            if consumed <= 0:
                break
            pos += consumed
        if len(self._queue) == 0:
            return None
        return self._queue.pop(0)


# --- Input parser -----------------------------------------------------------


fn parse_input(data: String) -> Tuple[Event, Int]:
    """Parse one Event from the start of ``data``.

    Returns ``(event, bytes_consumed)``. When multiple events are buffered in a
    single read (common during drag, where SGR mouse reports arrive in bursts),
    the caller advances ``data`` by ``bytes_consumed`` and parses again.
    """
    if len(data) == 0:
        return (Event(), 0)
    var bytes = data.as_bytes()
    var b0 = bytes[0]

    # Bare ESC, or ESC + something — could be Alt-modified key or a CSI/SS3.
    if b0 == 0x1B:
        if len(data) == 1:
            return (Event.key_event(KEY_ESC), 1)
        var b1 = bytes[1]
        if b1 == 0x5B:  # '['
            return _parse_csi(data)
        if b1 == 0x4F:  # 'O' — SS3, used by some terminals for F1..F4
            if len(data) >= 3:
                var b2 = bytes[2]
                if b2 == 0x50: return (Event.key_event(KEY_F1), 3)
                if b2 == 0x51: return (Event.key_event(KEY_F2), 3)
                if b2 == 0x52: return (Event.key_event(KEY_F3), 3)
                if b2 == 0x53: return (Event.key_event(KEY_F4), 3)
            return (Event.key_event(KEY_ESC), 2)
        # ESC + printable → Alt-modified
        return (Event.key_event(UInt32(Int(b1)), MOD_ALT), 2)

    if b0 == 0x0D or b0 == 0x0A:
        return (Event.key_event(KEY_ENTER), 1)
    if b0 == 0x09:
        return (Event.key_event(KEY_TAB), 1)
    if b0 == 0x7F or b0 == 0x08:
        return (Event.key_event(KEY_BACKSPACE), 1)

    # Printable ASCII or start of a UTF-8 sequence — return the codepoint.
    var cp_len = _utf8_seq_len(b0)
    if cp_len > len(bytes):
        cp_len = len(bytes)
    return (Event.key_event(_decode_first_codepoint(data)), cp_len)


fn _parse_csi(data: String) -> Tuple[Event, Int]:
    """Handle the small CSI vocabulary we recognize."""
    var bytes = data.as_bytes()
    if len(bytes) < 3:
        return (Event.key_event(KEY_ESC), 1)

    # SGR mouse: CSI < B ; X ; Y M|m  — emitted by xterm-style 1006 mode.
    if bytes[2] == 0x3C:  # '<'
        return _parse_sgr_mouse(data)

    var b2 = bytes[2]
    if b2 == 0x41: return (Event.key_event(KEY_UP), 3)
    if b2 == 0x42: return (Event.key_event(KEY_DOWN), 3)
    if b2 == 0x43: return (Event.key_event(KEY_RIGHT), 3)
    if b2 == 0x44: return (Event.key_event(KEY_LEFT), 3)
    if b2 == 0x48: return (Event.key_event(KEY_HOME), 3)
    if b2 == 0x46: return (Event.key_event(KEY_END), 3)
    # CSI <number>~ forms: ESC[5~ ESC[6~ ESC[2~ ESC[3~ ESC[15~ ...
    if b2 >= 0x30 and b2 <= 0x39:
        var i = 2
        var num = 0
        while i < len(bytes) and bytes[i] >= 0x30 and bytes[i] <= 0x39:
            num = num * 10 + Int(bytes[i]) - 0x30
            i += 1
        if i < len(bytes) and bytes[i] == 0x7E:  # '~'
            var consumed = i + 1
            if num == 1: return (Event.key_event(KEY_HOME), consumed)
            if num == 2: return (Event.key_event(KEY_INSERT), consumed)
            if num == 3: return (Event.key_event(KEY_DELETE), consumed)
            if num == 4: return (Event.key_event(KEY_END), consumed)
            if num == 5: return (Event.key_event(KEY_PAGEUP), consumed)
            if num == 6: return (Event.key_event(KEY_PAGEDOWN), consumed)
            if num == 11: return (Event.key_event(KEY_F1), consumed)
            if num == 12: return (Event.key_event(KEY_F2), consumed)
            if num == 13: return (Event.key_event(KEY_F3), consumed)
            if num == 14: return (Event.key_event(KEY_F4), consumed)
            if num == 15: return (Event.key_event(KEY_F5), consumed)
            if num == 17: return (Event.key_event(KEY_F6), consumed)
            if num == 18: return (Event.key_event(KEY_F7), consumed)
            if num == 19: return (Event.key_event(KEY_F8), consumed)
            if num == 20: return (Event.key_event(KEY_F9), consumed)
            if num == 21: return (Event.key_event(KEY_F10), consumed)
            if num == 23: return (Event.key_event(KEY_F11), consumed)
            if num == 24: return (Event.key_event(KEY_F12), consumed)
    return (Event.key_event(KEY_ESC), 3)


fn _parse_sgr_mouse(data: String) -> Tuple[Event, Int]:
    """Parse `CSI < B ; X ; Y (M|m)`. Press/drag = M, release = m."""
    var bytes = data.as_bytes()
    var i = 3  # past `ESC [ <`
    var nums = List[Int]()
    var cur = 0
    var has_digit = False
    while i < len(bytes):
        var b = bytes[i]
        if b >= 0x30 and b <= 0x39:
            cur = cur * 10 + Int(b) - 0x30
            has_digit = True
            i += 1
        elif b == 0x3B:  # ';'
            nums.append(cur)
            cur = 0
            has_digit = False
            i += 1
        elif b == 0x4D or b == 0x6D:  # 'M' (press/drag) or 'm' (release)
            if has_digit:
                nums.append(cur)
            if len(nums) < 3:
                return (Event.key_event(KEY_ESC), i + 1)
            var raw = nums[0]
            var x = nums[1] - 1
            var y = nums[2] - 1
            var pressed = (b == 0x4D)
            var motion = (raw & 32) != 0
            var mods: UInt8 = MOD_NONE
            if (raw & 4) != 0:  mods = mods | MOD_SHIFT
            if (raw & 8) != 0:  mods = mods | MOD_ALT
            if (raw & 16) != 0: mods = mods | MOD_CTRL
            var button: UInt8
            if (raw & 64) != 0:
                if (raw & 1) != 0:
                    button = MOUSE_WHEEL_DOWN
                else:
                    button = MOUSE_WHEEL_UP
            else:
                var bn = raw & 3
                if bn == 0:   button = MOUSE_BUTTON_LEFT
                elif bn == 1: button = MOUSE_BUTTON_MIDDLE
                else:         button = MOUSE_BUTTON_RIGHT
            return (
                Event.mouse_event(Point(x, y), button, pressed, motion, mods),
                i + 1,
            )
        else:
            # Unrecognized byte — abort.
            return (Event.key_event(KEY_ESC), i + 1)
    # Ran off the end — incomplete sequence; consume what we have.
    return (Event.key_event(KEY_ESC), len(bytes))


fn _utf8_seq_len(b: UInt8) -> Int:
    var ib = Int(b)
    if ib < 0x80:        return 1
    if (ib & 0xF8) == 0xF0: return 4
    if (ib & 0xF0) == 0xE0: return 3
    if (ib & 0xE0) == 0xC0: return 2
    return 1


fn _decode_first_codepoint(data: String) -> UInt32:
    """Decode one UTF-8 codepoint from the start of ``data``."""
    var bytes = data.as_bytes()
    if len(bytes) == 0:
        return UInt32(0)
    var b0 = Int(bytes[0])
    if b0 < 0x80:
        return UInt32(b0)
    if (b0 & 0xE0) == 0xC0 and len(bytes) >= 2:
        return UInt32(((b0 & 0x1F) << 6) | (Int(bytes[1]) & 0x3F))
    if (b0 & 0xF0) == 0xE0 and len(bytes) >= 3:
        return UInt32(((b0 & 0x0F) << 12) | ((Int(bytes[1]) & 0x3F) << 6) | (Int(bytes[2]) & 0x3F))
    if (b0 & 0xF8) == 0xF0 and len(bytes) >= 4:
        return UInt32(((b0 & 0x07) << 18) | ((Int(bytes[1]) & 0x3F) << 12)
                      | ((Int(bytes[2]) & 0x3F) << 6) | (Int(bytes[3]) & 0x3F))
    return UInt32(b0)
