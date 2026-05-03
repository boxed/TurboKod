"""Terminal driver: raw mode, ANSI output, escape-sequence input parsing.

Pure Mojo: no Python interop, no ncurses. The OS-level work (termios, ioctl,
poll, read) is delegated to ``posix.mojo`` which wraps libc through
``external_call``. Stdout writes go through ``std.io.file_descriptor``.

Cell diffing and the escape-sequence → Event parser are pure Mojo and don't
touch the OS at all, so they're easy to unit-test (see ``tests/test_basic.mojo``).
"""

from std.collections.list import List
from std.collections.optional import Optional
from std.ffi import external_call
from std.io.file_descriptor import FileDescriptor

from .canvas import Canvas
from .cell import Cell, blank_cell
from .colors import Attr, attr_to_sgr, default_attr
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE, EVENT_NONE, EVENT_OPEN_PATH,
    EVENT_RESIZE, EVENT_QUIT,
    KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT,
    KEY_HOME, KEY_END, KEY_PAGEUP, KEY_PAGEDOWN, KEY_INSERT, KEY_DELETE,
    KEY_F1, KEY_F2, KEY_F3, KEY_F4, KEY_F5, KEY_F6,
    KEY_F7, KEY_F8, KEY_F9, KEY_F10, KEY_F11, KEY_F12,
    KEY_ENTER, KEY_TAB, KEY_BACKSPACE, KEY_ESC,
    MOD_NONE, MOD_SHIFT, MOD_ALT, MOD_CTRL, MOD_META,
    MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT,
    MOUSE_WHEEL_UP, MOUSE_WHEEL_DOWN,
)
from .geometry import Point
from .posix import (
    STDIN_FD, STDOUT_FD, TCSANOW, TERMIOS_SIZE,
    alloc_zero_buffer, append_string_bytes, cfmakeraw, get_window_size,
    getenv_value, poll_stdin, query_size_via_cursor, read_into, set_nonblocking,
    tcflush, tcgetattr, tciflush_value, tcsetattr, write_buffer, write_string,
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
# Mouse:
#   1002 = button-event tracking — motion while a button is held (drag).
#   1003 = any-event tracking    — motion with no button held (hover).
# The native host treats these as independent flags, so we enable both:
# 1002 alone misses hover-to-switch in the menu bar, 1003 alone drops drag
# events while click-and-holding. 1006 selects SGR-encoded reports.
comptime SEQ_MOUSE_ON  = String("\x1b[?1002h\x1b[?1003h\x1b[?1006h")
comptime SEQ_MOUSE_OFF = String("\x1b[?1006l\x1b[?1003l\x1b[?1002l")
# Force xterm-style modifier reporting on cursor & function keys, so shift /
# ctrl with the arrows arrive as `ESC[1;<mod><letter>` even in terminals
# (iTerm2!) that otherwise strip the modifiers.
comptime SEQ_MODIFY_KEYS_ON  = String("\x1b[>1;2m\x1b[>2;2m\x1b[>4;2m")
comptime SEQ_MODIFY_KEYS_OFF = String("\x1b[>1m\x1b[>2m\x1b[>4m")
# Mouse-pointer shape is signalled by piggy-backing on OSC 2 (window
# title). The native turbokod host recognises titles starting with
# ``__mvc_cursor:`` as a private cursor-shape command and routes them
# to the platform cursor instead of the title bar; generic terminals
# either ignore the prefix or briefly flash it as a title — the trade-
# off is worth not having to fork ``alacritty_terminal`` to dispatch a
# new OSC. The shape names map to ``winit::CursorIcon`` variants.
comptime POINTER_SHAPE_PREFIX = String("\x1b]2;__mvc_cursor:")
comptime POINTER_SHAPE_SUFFIX = String("\x07")


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
    var _queue_head: Int            # avoid List.pop(0)'s O(n) shift + churn
    var _pending: List[UInt8]       # trailing bytes of a partial escape sequence
    var _read_buf: List[UInt8]      # persistent read buffer for poll_event
    var width: Int
    var height: Int
    # Optional trace fd shared with ``LspProcess.trace_fd`` — host wires
    # them up so terminal-side events appear in the same log as
    # protocol-side events. ``-1`` disables.
    var trace_fd: Int32
    # Last mouse-pointer shape we asked the host to display. Used to
    # dedupe ``set_pointer_shape`` so we don't spam the OSC sequence
    # on every mouse-motion event.
    var _last_pointer_shape: String

    fn __init__(out self) raises:
        self._orig_termios = alloc_zero_buffer(TERMIOS_SIZE)
        self._started = False
        self._queue = List[Event]()
        self._queue_head = 0
        self._pending = List[UInt8]()
        self._read_buf = alloc_zero_buffer(1024)
        var size = get_window_size()
        self.width = size[0]
        self.height = size[1]
        self._front = Canvas(self.width, self.height)
        self.trace_fd = -1
        self._last_pointer_shape = String("")

    fn _trace(self, var line: String):
        """Write ``line`` to ``trace_fd`` if open. No newline added —
        callers include their own. Same shape as
        ``LspProcess.trace`` so a single log file makes sense."""
        if self.trace_fd < 0:
            return
        var bytes = line.as_bytes()
        if len(bytes) == 0:
            return
        var f = FileDescriptor(Int(self.trace_fd))
        f.write_bytes(bytes)


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
        write_string(STDOUT_FD, SEQ_MODIFY_KEYS_ON)
        write_string(STDOUT_FD, SEQ_CLEAR_SCREEN)
        write_string(STDOUT_FD, SEQ_CURSOR_HOME)
        self._started = True

    fn _query_size_via_cursor(mut self) -> Tuple[Int, Int]:
        return query_size_via_cursor(STDIN_FD, STDOUT_FD)

    fn set_pointer_shape(mut self, shape: String) raises:
        """Ask the host to display ``shape`` as the mouse-pointer icon.

        Only emitted when the bundled native app is detected (it sets
        ``TURBOKOD_HOST=1`` in the PTY env). Generic terminals would
        otherwise interpret the OSC as a window-title set and briefly
        flash ``__mvc_cursor:...`` in their title bar, which is worse
        UX than just leaving the cursor alone. Supported shapes match
        the winit ``CursorIcon`` taxonomy: ``"default"``, ``"text"``,
        ``"pointer"``. Repeat calls with the same shape are no-ops."""
        if not self._started:
            return
        if shape == self._last_pointer_shape:
            return
        if getenv_value(String("TURBOKOD_HOST")) != String("1"):
            return
        self._last_pointer_shape = shape
        write_string(
            STDOUT_FD,
            POINTER_SHAPE_PREFIX + shape + POINTER_SHAPE_SUFFIX,
        )

    fn stop(mut self) raises:
        if not self._started:
            return
        write_string(STDOUT_FD, SEQ_MODIFY_KEYS_OFF)
        write_string(STDOUT_FD, SEQ_MOUSE_OFF)
        write_string(STDOUT_FD, SEQ_RESET)
        write_string(STDOUT_FD, SEQ_CURSOR_SHOW)
        write_string(STDOUT_FD, SEQ_ALT_SCREEN_OFF)
        # Drain any in-flight bytes the terminal emitted while it was still
        # processing SEQ_MOUSE_OFF — without this, fast scroll-wheel events
        # mid-shutdown get echoed verbatim once tcsetattr re-enables ECHO.
        # Cap iterations so a user holding the mouse wheel can't stall exit.
        var scratch = alloc_zero_buffer(256)
        var iterations = 0
        while iterations < 50 and poll_stdin(STDIN_FD, Int32(10)):
            var n = read_into(STDIN_FD, scratch, 256)
            if n <= 0:
                break
            iterations += 1
        _ = tcflush(STDIN_FD, tciflush_value())
        _ = tcsetattr(STDIN_FD, TCSANOW, self._orig_termios)
        self._started = False

    fn refresh_size(mut self) raises -> Bool:
        """Re-query terminal dimensions; return True if they changed.

        Two paths land us here:

        1. The native wrapper pushes ``CSI 8 ; rows ; cols t`` after each
           window resize — that goes through ``poll_event``'s parser, not
           this method, but it's instant.
        2. On real terminals (Terminal.app, iTerm2) there's no push, so
           we fall back to polling the cursor position. ``ioctl(TIOCGWINSZ)``
           doesn't work via Mojo's ``external_call`` on macOS arm64
           (variadic ABI mismatch — the third arg lands in a register but
           ``ioctl`` reads varargs from the stack), hence the cursor-query
           dance instead of a cheap syscall.

        We poll every call (no throttle) but skip whenever there are
        already events queued or bytes ready on stdin — a previous ~1 Hz
        throttle was protecting against a race that the input-pending
        guard already covers, so removing the counter just makes drag
        resize feel instant in real terminals.
        """
        if self._queue_head < len(self._queue):
            return False
        if poll_stdin(STDIN_FD, Int32(0)):
            return False
        var size = query_size_via_cursor(STDIN_FD, STDOUT_FD)
        if size[0] <= 0 or size[1] <= 0:
            return False
        if size[0] == self.width and size[1] == self.height:
            return False
        self.width = size[0]
        self.height = size[1]
        return True

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

        Partial escape sequences split across reads are saved in ``_pending``
        and prepended to the next read, so a wheel-event burst chopped at a
        read boundary doesn't get misread as a KEY_ESC keypress. If pending
        bytes survive a follow-up read with no progress (the user actually
        pressed Escape), the leading ESC is flushed as KEY_ESC.
        """
        self._trace(String("    poll_event:enter\n"))
        if self._queue_head < len(self._queue):
            self._trace(String("    poll_event:queue-hit\n"))
            return self._pop_queue()
        self._trace(String("    poll_event:before-poll_stdin\n"))
        var has_input = poll_stdin(STDIN_FD, Int32(timeout_ms))
        self._trace(
            String("    poll_event:after-poll_stdin has=")
            + (String("True") if has_input else String("False")) + String("\n"),
        )
        if not has_input:
            if len(self._pending) > 0:
                self._flush_pending_as_esc()
                if self._queue_head < len(self._queue):
                    return self._pop_queue()
            return None
        self._trace(String("    poll_event:before-read_into\n"))
        var n = read_into(STDIN_FD, self._read_buf, 1024)
        self._trace(
            String("    poll_event:after-read_into n=") + String(n) + String("\n"),
        )
        if n <= 0:
            if len(self._pending) > 0:
                self._flush_pending_as_esc()
                if self._queue_head < len(self._queue):
                    return self._pop_queue()
            return None
        # Snapshot the freshly-read bytes before any further work, as
        # space-separated decimal byte values (ESC=27, '[' = 91, etc.).
        var dump = String("    poll_event:read_bytes ")
        for i in range(n):
            dump += String(Int(self._read_buf[i]))
            dump += String(" ")
        dump += String("\n")
        self._trace(dump)
        var combined = List[UInt8]()
        for i in range(len(self._pending)):
            combined.append(self._pending[i])
        for i in range(n):
            combined.append(self._read_buf[i])
        self._pending = List[UInt8]()
        var total = len(combined)
        self._trace(
            String("    poll_event:combined ") + String(total) + String("B\n"),
        )
        var bytes = StringSlice(
            ptr=combined.unsafe_ptr(), length=total
        ).as_bytes()
        var pos = 0
        var iters = 0
        while pos < total:
            iters += 1
            self._trace(
                String("    poll_event:parse iter=") + String(iters)
                + String(" pos=") + String(pos) + String("\n"),
            )
            var slice = String(StringSlice(unsafe_from_utf8=bytes[pos:]))
            var parsed = parse_input(slice)
            var consumed = parsed[1]
            self._trace(
                String("    poll_event:parsed consumed=") + String(consumed)
                + String(" kind=") + String(Int(parsed[0].kind))
                + String("\n"),
            )
            if consumed <= 0:
                for i in range(pos, total):
                    self._pending.append(combined[i])
                break
            if parsed[0].kind != EVENT_NONE:
                if parsed[0].kind == EVENT_RESIZE:
                    # The resize sequence the wrapper pushes carries the new
                    # ``(cols, rows)`` in ``pos``; fold it into our cached
                    # dimensions so callers reading ``self.width/height``
                    # immediately after see the new size, and the front
                    # canvas is re-sized in ``present()`` next paint.
                    self.width = parsed[0].pos.x
                    self.height = parsed[0].pos.y
                self._queue.append(parsed[0])
            pos += consumed
        if len(self._pending) > 64:
            self._pending = List[UInt8]()
        if self._queue_head >= len(self._queue):
            self._trace(String("    poll_event:exit None\n"))
            return None
        self._trace(String("    poll_event:exit pop_queue\n"))
        return self._pop_queue()

    fn _pop_queue(mut self) -> Event:
        var ev = self._queue[self._queue_head]
        self._queue_head += 1
        if self._queue_head >= len(self._queue):
            # Drained — reset rather than letting the list grow forever.
            self._queue = List[Event]()
            self._queue_head = 0
        return ev

    fn _flush_pending_as_esc(mut self):
        """Emit a KEY_ESC for the pending leading byte (must be ESC) and clear.

        Pending only ever holds the start of a partial escape sequence, which
        always begins with 0x1B. After the follow-up read times out, that ESC
        is the user's real Escape keypress; any trailing bytes are discarded
        (in practice there are none — real ESC keypresses are a single byte).
        """
        if len(self._pending) > 0 and self._pending[0] == 0x1B:
            self._queue.append(Event.key_event(KEY_ESC))
        self._pending = List[UInt8]()


# --- Input parser -----------------------------------------------------------


fn parse_input(data: String) -> Tuple[Event, Int]:
    """Parse one Event from the start of ``data``.

    Returns ``(event, bytes_consumed)``. When multiple events are buffered in a
    single read (common during drag, where SGR mouse reports arrive in bursts),
    the caller advances ``data`` by ``bytes_consumed`` and parses again.

    Partial-sequence convention: returning ``(EVENT_NONE, 0)`` signals the
    caller that the buffer ends mid-sequence and the trailing bytes should
    be saved and prepended to the next read. This is what keeps a scroll-
    wheel burst that gets split at a read boundary from being misread as a
    KEY_ESC keypress (and quitting any quit-on-Esc app). Real ESC keypress
    detection is a Terminal.poll_event responsibility — it disambiguates
    via a short follow-up timeout.
    """
    if len(data) == 0:
        return (Event(), 0)
    var bytes = data.as_bytes()
    var b0 = bytes[0]

    # Bare ESC, or ESC + something — could be Alt-modified key or a CSI/SS3.
    if b0 == 0x1B:
        if len(data) == 1:
            # Could be a real ESC keypress, or the first byte of an escape
            # sequence whose tail hasn't arrived yet. Defer to caller.
            return (Event(), 0)
        var b1 = bytes[1]
        if b1 == 0x5B:  # '['
            return _parse_csi(data)
        if b1 == 0x5D:  # ']' — OSC
            return _parse_osc(data)
        if b1 == 0x4F:  # 'O' — SS3, used by some terminals for F1..F4
            if len(data) < 3:
                # Partial SS3: tail not yet read.
                return (Event(), 0)
            var b2 = bytes[2]
            if b2 == 0x50: return (Event.key_event(KEY_F1), 3)
            if b2 == 0x51: return (Event.key_event(KEY_F2), 3)
            if b2 == 0x52: return (Event.key_event(KEY_F3), 3)
            if b2 == 0x53: return (Event.key_event(KEY_F4), 3)
            # Unknown SS3 final byte — drop the prefix without emitting ESC.
            return (Event(), 3)
        # ESC + printable → Alt-modified literal key. Macros that the
        # readline conventions (``ESC f`` forward-word, ``ESC b``
        # backward-word) used to consume here are now passed through as
        # plain ``Alt+f`` / ``Alt+b`` events so the menu-bar mnemonic
        # routing in Desktop can see them. Word-jump still works via
        # ``Ctrl+arrow`` and (on terminals that report modifiers for
        # arrows) ``Alt+arrow``.
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


fn _csi_mods_from(mod_num: Int) -> UInt8:
    """Decode the xterm modifier-parameter (1 + shift|alt<<1|ctrl<<2|meta<<3).

    Bit 8 (meta) is the macOS Cmd key. xterm's standard mod values stop at
    ctrl (bit 4 → up to 8), so the host wrapper for the native window has
    to opt in to emitting the meta bit; terminals that don't won't reach
    this branch and behave exactly as before.
    """
    var raw = mod_num - 1
    if raw < 0:
        raw = 0
    var mods: UInt8 = MOD_NONE
    if (raw & 1) != 0: mods = mods | MOD_SHIFT
    if (raw & 2) != 0: mods = mods | MOD_ALT
    if (raw & 4) != 0: mods = mods | MOD_CTRL
    if (raw & 8) != 0: mods = mods | MOD_META
    return mods


fn _normalize_ctrl_letter(cp: Int, mods: UInt8) -> Tuple[UInt32, UInt8]:
    """Fold ``Ctrl+letter`` (no shift) onto its control-character form.

    Terminals supporting modifyOtherKeys=2 deliver ``Ctrl+Q`` as
    ``(key=ord('q'), mods=MOD_CTRL)``, while terminals without that mode
    send the bare control byte ``(0x11, MOD_NONE)``. Downstream code
    (hotkeys, the editor's clipboard handlers) standardizes on the bare
    control-byte form, so we collapse the modified form into it. The
    ``Ctrl+Shift+letter`` case is left intact so it remains distinguishable.

    ``Cmd+...`` (``MOD_META``) is collapsed onto ``Ctrl+...`` first — the
    framework guarantees the two are indistinguishable downstream, so a
    hotkey table written against ``Ctrl+S`` fires for Cmd+S, and one
    written against ``Ctrl+Shift+F`` fires for Cmd+Shift+F. After the
    fold, the same control-byte rule above applies to the bare-Ctrl case.
    """
    var folded = mods
    if (folded & MOD_META) != 0:
        # XOR clears the META bit (we just checked it's set), then OR sets CTRL.
        folded = (folded ^ MOD_META) | MOD_CTRL
    if folded != MOD_CTRL:
        return (UInt32(cp), folded)
    if cp < 0x40 or cp > 0x7E:
        return (UInt32(cp), folded)
    var letter = cp
    if letter >= 0x60:
        letter = letter - 0x20  # to upper
    if letter < 0x40 or letter > 0x5F:
        return (UInt32(cp), folded)
    return (UInt32(letter - 0x40), MOD_NONE)


fn _parse_csi(data: String) -> Tuple[Event, Int]:
    """Parse a complete CSI sequence and return whatever event it represents.

    The parser scans to the CSI **final byte** (any byte in ``0x40..0x7E``)
    before deciding what the sequence means, then consumes the entire span
    from ``ESC`` to the final byte. This is what keeps unrecognized
    sequences from leaking trailing bytes into the focused editor — even
    sequences we don't care about are fully eaten.

    Recognized forms:

    * ``CSI A/B/C/D/H/F``                   — bare arrow / Home / End
    * ``CSI <num>~``                        — F-keys, PageUp/Down, Insert/Delete
    * ``CSI <num> ; <mod> <letter>``        — arrows / nav with modifiers
    * ``CSI 27 ; <mod> ; <cp> ~``           — xterm modifyOtherKeys=2
    * ``CSI <cp> ; <mod> u``                — kitty kbd protocol

    For the last two, ``Ctrl+letter (no shift)`` is normalized onto the
    control-character form so existing consumers (hotkey table, editor
    clipboard handlers) keep working unchanged.
    """
    var bytes = data.as_bytes()
    if len(bytes) < 3:
        # Just ``ESC [`` so far — tail not yet read. Defer to caller.
        return (Event(), 0)

    # SGR mouse: CSI < B ; X ; Y M|m — keep the dedicated parser; its tight
    # buffering rules are exactly what high-rate scroll bursts need.
    if bytes[2] == 0x3C:  # '<'
        return _parse_sgr_mouse(data)

    # Find the final byte. ECMA-48 says it's a single byte in 0x40..0x7E
    # following any number of parameter (0x30..0x3F) and intermediate
    # (0x20..0x2F) bytes.
    var end = 2
    while end < len(bytes):
        var b = bytes[end]
        if b >= 0x40 and b <= 0x7E:
            break
        end += 1
    if end >= len(bytes):
        # Final byte hasn't arrived yet — partial read. Defer.
        return (Event(), 0)

    var final = bytes[end]
    var consumed = end + 1

    # No-parameter finals: bare cursor / nav keys.
    if end == 2:
        if final == 0x41: return (Event.key_event(KEY_UP), consumed)
        if final == 0x42: return (Event.key_event(KEY_DOWN), consumed)
        if final == 0x43: return (Event.key_event(KEY_RIGHT), consumed)
        if final == 0x44: return (Event.key_event(KEY_LEFT), consumed)
        if final == 0x48: return (Event.key_event(KEY_HOME), consumed)
        if final == 0x46: return (Event.key_event(KEY_END), consumed)
        return (Event(), consumed)

    # Parse parameters as ``;``-separated decimal numbers. Anything else in
    # the parameter span (intermediates, private markers we don't speak)
    # means we drop the sequence — but we drop it whole, never piecemeal.
    var params = List[Int]()
    var i = 2
    var cur = 0
    var has_digit = False
    while i < end:
        var b = bytes[i]
        if b >= 0x30 and b <= 0x39:
            cur = cur * 10 + Int(b) - 0x30
            has_digit = True
        elif b == 0x3B:  # ';'
            params.append(cur)
            cur = 0
            has_digit = False
        else:
            return (Event(), consumed)
        i += 1
    if has_digit:
        params.append(cur)

    if final == 0x7E:
        if len(params) == 1:
            var num1 = params[0]
            if num1 == 1:  return (Event.key_event(KEY_HOME), consumed)
            if num1 == 2:  return (Event.key_event(KEY_INSERT), consumed)
            if num1 == 3:  return (Event.key_event(KEY_DELETE), consumed)
            if num1 == 4:  return (Event.key_event(KEY_END), consumed)
            if num1 == 5:  return (Event.key_event(KEY_PAGEUP), consumed)
            if num1 == 6:  return (Event.key_event(KEY_PAGEDOWN), consumed)
            if num1 == 11: return (Event.key_event(KEY_F1), consumed)
            if num1 == 12: return (Event.key_event(KEY_F2), consumed)
            if num1 == 13: return (Event.key_event(KEY_F3), consumed)
            if num1 == 14: return (Event.key_event(KEY_F4), consumed)
            if num1 == 15: return (Event.key_event(KEY_F5), consumed)
            if num1 == 17: return (Event.key_event(KEY_F6), consumed)
            if num1 == 18: return (Event.key_event(KEY_F7), consumed)
            if num1 == 19: return (Event.key_event(KEY_F8), consumed)
            if num1 == 20: return (Event.key_event(KEY_F9), consumed)
            if num1 == 21: return (Event.key_event(KEY_F10), consumed)
            if num1 == 23: return (Event.key_event(KEY_F11), consumed)
            if num1 == 24: return (Event.key_event(KEY_F12), consumed)
            return (Event(), consumed)
        if len(params) == 3 and params[0] == 27:
            # modifyOtherKeys=2: CSI 27 ; <mod> ; <codepoint> ~
            var mods = _csi_mods_from(params[1])
            var nk = _normalize_ctrl_letter(params[2], mods)
            return (Event.key_event(nk[0], nk[1]), consumed)
        return (Event(), consumed)

    if len(params) == 2:
        var num1 = params[0]
        var mods = _csi_mods_from(params[1])
        if final == 0x41: return (Event.key_event(KEY_UP, mods), consumed)
        if final == 0x42: return (Event.key_event(KEY_DOWN, mods), consumed)
        if final == 0x43: return (Event.key_event(KEY_RIGHT, mods), consumed)
        if final == 0x44: return (Event.key_event(KEY_LEFT, mods), consumed)
        if final == 0x48: return (Event.key_event(KEY_HOME, mods), consumed)
        if final == 0x46: return (Event.key_event(KEY_END, mods), consumed)
        if final == 0x75:  # 'u' — kitty kbd protocol
            var nk = _normalize_ctrl_letter(num1, mods)
            return (Event.key_event(nk[0], nk[1]), consumed)
        return (Event(), consumed)

    if len(params) == 1 and final == 0x75:
        # Kitty kbd protocol with no explicit modifier (single param).
        var nk = _normalize_ctrl_letter(params[0], MOD_NONE)
        return (Event.key_event(nk[0], nk[1]), consumed)

    if len(params) == 3 and final == 0x74 and params[0] == 8:
        # ``CSI 8 ; <rows> ; <cols> t`` — xterm window-size report. The
        # standard says the *terminal emulator* sends this in response to
        # ``CSI 18 t``; the native wrapper pushes it unsolicited on every
        # window resize so we get a synchronous size-change notification
        # instead of waiting for the cursor-query polling loop. Either
        # source is fine to consume.
        return (Event.resize_event(params[2], params[1]), consumed)

    return (Event(), consumed)


fn _parse_sgr_mouse(data: String) -> Tuple[Event, Int]:
    """Parse `CSI < B ; X ; Y (M|m)`. Press/drag = M, release = m.

    If the buffer ends mid-sequence (read split a mouse report in two) we
    return ``(EVENT_NONE, 0)`` so the caller saves the trailing bytes as
    pending and prepends them to the next read. Returning KEY_ESC instead
    would make every quit-on-Esc app randomly exit during fast scrolling.
    """
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
                # Malformed (terminator before three numbers) — drop silently.
                return (Event(), i + 1)
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
                elif bn == 2: button = MOUSE_BUTTON_RIGHT
                else:         button = MOUSE_BUTTON_NONE  # 1003 hover
            return (
                Event.mouse_event(Point(x, y), button, pressed, motion, mods),
                i + 1,
            )
        else:
            # Unrecognized byte mid-sequence — drop silently.
            return (Event(), i + 1)
    # Ran off the end — partial sequence (split read). Defer to caller.
    return (Event(), 0)


fn _parse_osc(data: String) -> Tuple[Event, Int]:
    """Parse a complete OSC sequence: ``ESC ] Ps ; Pt ST``.

    The terminator ST is either ``BEL`` (0x07) or ``ESC \\`` (0x1b 0x5c).
    Most OSC sequences (window title, palette query, …) are sent terminal
    → host; we don't normally see them inbound. The native turbokod
    wrapper, however, uses a private ``OSC 2 ; __mvc_open:<path> BEL``
    channel to forward command-line args from a second invocation, so the
    inbound parser has to recognise it and emit an ``EVENT_OPEN_PATH``.
    Any other OSC is consumed silently — without this branch the bytes
    would leak as an ``Alt+]`` keypress through the generic ESC handler.

    Partial-sequence convention matches ``_parse_csi``: returning
    ``(EVENT_NONE, 0)`` defers to the caller for buffer reassembly.
    """
    var bytes = data.as_bytes()
    var n = len(bytes)
    if n < 2:
        return (Event(), 0)
    # Scan from index 2 for BEL or ESC \\ (the two ECMA-48 string
    # terminators OSC accepts).
    var i = 2
    var term_len = 0
    while i < n:
        var b = bytes[i]
        if b == 0x07:                        # BEL
            term_len = 1
            break
        if b == 0x1B and i + 1 < n and bytes[i + 1] == 0x5C:  # ESC \\
            term_len = 2
            break
        i += 1
    if term_len == 0:
        # Either we hit a bare ESC at the end (could be the start of ST,
        # tail not yet read) or no terminator yet — defer.
        return (Event(), 0)
    var consumed = i + term_len
    var body_start = 2
    var body_end = i
    # Recognise ``Ps;__mvc_open:<path>``. ``Ps`` is decimal digits ended
    # by ``;``; we don't actually care which OSC code the host picked
    # (we tolerate 2 / 0 / 9 / private codes equally), only that the
    # text after the first ``;`` starts with the magic prefix.
    var sep = body_start
    while sep < body_end and bytes[sep] != 0x3B:  # ';'
        sep += 1
    if sep >= body_end:
        return (Event(), consumed)
    var pt_start = sep + 1
    # Quick prefix match against ``__mvc_open:`` without allocating a
    # String for the whole body.
    var prefix = String("__mvc_open:").as_bytes()
    if body_end - pt_start < len(prefix):
        return (Event(), consumed)
    var k = 0
    while k < len(prefix):
        if bytes[pt_start + k] != prefix[k]:
            return (Event(), consumed)
        k += 1
    var path_start = pt_start + len(prefix)
    # The native wrapper carries an optional ``\x1f<line>`` suffix to
    # request a jump-to-line on open (translation target for the
    # ``turbokod://open?...&line=N`` URL scheme). Split on the first
    # 0x1F (Unit Separator, never present in a real path); a missing
    # suffix means "open at the file's first line".
    var us = path_start
    while us < body_end and bytes[us] != 0x1F:
        us += 1
    var path = String(StringSlice(unsafe_from_utf8=bytes[path_start:us]))
    var line: Int = 0
    if us < body_end:
        var p = us + 1
        var n = 0
        var saw = False
        while p < body_end:
            var c = Int(bytes[p])
            if c < 0x30 or c > 0x39:
                break
            n = n * 10 + (c - 0x30)
            saw = True
            p += 1
        if saw:
            line = n
    return (Event.open_path_event(path^, line), consumed)


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
