"""Native macOS window frontend — a drop-in alternative to ``Terminal``.

Where ``terminal.mojo`` talks to a TTY (raw mode, ANSI out, escape-sequence
parsing), this talks to real macOS windows through the ``turbokod-render``
Rust staticlib (winit + softbuffer + the glyph atlas lifted from the
``app/`` wrapper). The contract is the one ``Terminal`` satisfies, so the
Desktop and every widget paint into a ``Canvas`` and consume ``Event``s
exactly as before.

There are **no escape sequences**: a Cmd+S keypress arrives from the OS as a
native key event and becomes ``Event.key_event(ord('s'), MOD_META)``
directly — no PTY, no terminal emulator.

Two layers:

* ``NativeApp`` + ``NativeWindow`` — the real model. One event loop, **N
  windows**; events are tagged with the window they target.
* ``NativeFrontend`` — a single-window convenience that mirrors
  ``Terminal``'s surface (``start``/``stop``/``present``/``poll_event``/
  ``refresh_size``/``width``/``height``), implemented as an app with one
  window. Existing single-window examples use this.

FFI is via ``external_call`` to the ``tk_app_*`` / ``tk_window_*`` C ABI (see
``app/turbokod-render/src/lib.rs``). The app handle is an opaque pointer held
as an ``Int`` (pointer and 64-bit int share a register across the ABI).
"""

from std.ffi import external_call
from std.collections.list import List
from std.collections.optional import Optional

from .canvas import Canvas
from .events import (
    Event,
    EVENT_KEY, EVENT_MOUSE, EVENT_RESIZE, EVENT_QUIT,
    EVENT_FOCUS_IN, EVENT_FOCUS_OUT, EVENT_MOD_KEY,
    KEY_ENTER, KEY_TAB, KEY_BACKSPACE, KEY_ESC,
    KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT,
    KEY_HOME, KEY_END, KEY_PAGEUP, KEY_PAGEDOWN, KEY_INSERT, KEY_DELETE,
    KEY_F1, KEY_F2, KEY_F3, KEY_F4, KEY_F5, KEY_F6,
    KEY_F7, KEY_F8, KEY_F9, KEY_F10, KEY_F11, KEY_F12,
    MOD_CTRL, MOD_META,
)
from .geometry import Point
from .string_utils import codepoint_at


# --- Wire constants (mirror app/turbokod-render/src/lib.rs) -----------------

comptime _EV_WORDS = 8
comptime _MAX_EVENTS = 128

comptime _EV_KEY       = UInt32(1)
comptime _EV_MOUSE     = UInt32(2)
comptime _EV_RESIZE    = UInt32(3)
comptime _EV_CLOSE     = UInt32(4)
comptime _EV_FOCUS_IN  = UInt32(7)
comptime _EV_FOCUS_OUT = UInt32(8)
comptime _EV_MOD_KEY   = UInt32(9)

comptime _NK_ENTER     = UInt32(1)
comptime _NK_TAB       = UInt32(2)
comptime _NK_BACKSPACE = UInt32(3)
comptime _NK_ESC       = UInt32(4)
comptime _NK_UP        = UInt32(10)
comptime _NK_DOWN      = UInt32(11)
comptime _NK_LEFT      = UInt32(12)
comptime _NK_RIGHT     = UInt32(13)
comptime _NK_HOME      = UInt32(14)
comptime _NK_END       = UInt32(15)
comptime _NK_PAGEUP    = UInt32(16)
comptime _NK_PAGEDOWN  = UInt32(17)
comptime _NK_INSERT    = UInt32(18)
comptime _NK_DELETE    = UInt32(19)
comptime _NK_F1        = UInt32(30)  # F1..F12 == 30..41

comptime _MF_PRESSED = UInt32(1)
comptime _MF_MOTION  = UInt32(2)


def _named_to_key(named: UInt32, cp: UInt32) -> UInt32:
    if named == UInt32(0):
        return cp
    if named == _NK_ENTER:     return KEY_ENTER
    if named == _NK_TAB:       return KEY_TAB
    if named == _NK_BACKSPACE: return KEY_BACKSPACE
    if named == _NK_ESC:       return KEY_ESC
    if named == _NK_UP:        return KEY_UP
    if named == _NK_DOWN:      return KEY_DOWN
    if named == _NK_LEFT:      return KEY_LEFT
    if named == _NK_RIGHT:     return KEY_RIGHT
    if named == _NK_HOME:      return KEY_HOME
    if named == _NK_END:       return KEY_END
    if named == _NK_PAGEUP:    return KEY_PAGEUP
    if named == _NK_PAGEDOWN:  return KEY_PAGEDOWN
    if named == _NK_INSERT:    return KEY_INSERT
    if named == _NK_DELETE:    return KEY_DELETE
    if named >= _NK_F1 and named <= _NK_F1 + UInt32(11):
        var fkeys = List[UInt32]()
        fkeys.append(KEY_F1); fkeys.append(KEY_F2); fkeys.append(KEY_F3)
        fkeys.append(KEY_F4); fkeys.append(KEY_F5); fkeys.append(KEY_F6)
        fkeys.append(KEY_F7); fkeys.append(KEY_F8); fkeys.append(KEY_F9)
        fkeys.append(KEY_F10); fkeys.append(KEY_F11); fkeys.append(KEY_F12)
        return fkeys[Int(named - _NK_F1)]
    return cp


def _decode(buf: List[UInt32], base: Int) -> Tuple[UInt32, Event]:
    """Decode one 8-word wire event into ``(window_id, Event)``."""
    var kind = buf[base]
    var win  = buf[base + 1]
    var p0   = buf[base + 2]
    var p1   = buf[base + 3]
    var p2   = buf[base + 4]
    var p3   = buf[base + 5]
    var p4   = buf[base + 6]
    if kind == _EV_KEY:
        var key = _named_to_key(p0, p1)
        var mods = UInt8(Int(p2))
        # Canonicalize Ctrl/Cmd + letter to lowercase (matches the terminal
        # path's _normalize_ctrl_letter so hotkey tables match regardless of
        # frontend).
        if (mods & MOD_CTRL) != 0 or (mods & MOD_META) != 0:
            if key >= UInt32(0x41) and key <= UInt32(0x5A):
                key = key + UInt32(0x20)
        return (win, Event.key_event(key, mods))
    elif kind == _EV_MOUSE:
        var pressed = (p3 & _MF_PRESSED) != 0
        var motion = (p3 & _MF_MOTION) != 0
        return (win, Event.mouse_event(
            Point(Int(p0), Int(p1)), UInt8(Int(p2)), pressed, motion, UInt8(Int(p4)),
        ))
    elif kind == _EV_RESIZE:
        return (win, Event.resize_event(Int(p0), Int(p1)))
    elif kind == _EV_CLOSE:
        return (win, Event.quit_event())
    elif kind == _EV_FOCUS_IN:
        return (win, Event.focus_event(True))
    elif kind == _EV_FOCUS_OUT:
        return (win, Event.focus_event(False))
    elif kind == _EV_MOD_KEY:
        return (win, Event.mod_key_event(p0, p1 != UInt32(0)))
    return (win, Event())


def _shape_id(shape: String) -> UInt32:
    """Map Desktop.pointer_shape_at's vocabulary to the cursor ABI id."""
    if shape == String("text"):
        return UInt32(1)
    if shape == String("pointer"):
        return UInt32(2)
    return UInt32(0)


def _pack_canvas(back: Canvas, mut cell_buf: List[UInt32]):
    """Pack ``back`` into ``cell_buf`` (3 u32 per cell), growing as needed."""
    var n = back.width * back.height
    var need = n * 3
    while len(cell_buf) < need:
        cell_buf.append(UInt32(0))
    for i in range(n):
        var cell = back.cells[i]
        var cp = codepoint_at(cell.glyph, 0)[0]
        if cp <= 0:
            cp = 0x20
        var attr = cell.attr
        var w1 = UInt32(Int(attr.fg)) \
            | (UInt32(Int(attr.bg)) << 8) \
            | (UInt32(Int(attr.style)) << 16)
        var w2: UInt32
        if attr.underline_color < 0:
            w2 = UInt32(0xFFFFFFFF)
        else:
            w2 = UInt32(Int(attr.underline_color))
        cell_buf[i * 3] = UInt32(cp)
        cell_buf[i * 3 + 1] = w1
        cell_buf[i * 3 + 2] = w2


# --- Multi-window model -----------------------------------------------------

struct WinEvent(ImplicitlyCopyable, Movable):
    """An ``Event`` plus the window id it targets."""
    var win: UInt32
    var ev: Event

    def __init__(out self, win: UInt32, var ev: Event):
        self.win = win
        self.ev = ev^


struct NativeWindow(Copyable, Movable):
    """A single window within a ``NativeApp``. Holds the app handle plus this
    window's id; ``present`` / ``capture_bmp`` / etc. dispatch by id."""

    var _app: Int
    var id: UInt32
    var width: Int
    var height: Int
    var _cell_buf: List[UInt32]

    def __init__(out self, app: Int, id: UInt32):
        self._app = app
        self.id = id
        self.width = 80
        self.height = 25
        self._cell_buf = List[UInt32]()
        self.sync_size()

    def sync_size(mut self):
        var cols = List[UInt32]()
        cols.append(UInt32(0))
        var rows = List[UInt32]()
        rows.append(UInt32(0))
        _ = external_call["tk_window_size", Int32](
            self._app, self.id, cols.unsafe_ptr(), rows.unsafe_ptr(),
        )
        if Int(cols[0]) > 0 and Int(rows[0]) > 0:
            self.width = Int(cols[0])
            self.height = Int(rows[0])

    def present(mut self, back: Canvas):
        _pack_canvas(back, self._cell_buf)
        _ = external_call["tk_window_present", Int32](
            self._app, self.id, self._cell_buf.unsafe_ptr(),
            UInt32(back.width * back.height * 3),
            UInt32(back.width), UInt32(back.height),
        )

    def set_title(mut self, title: String):
        var b = title.as_bytes()
        _ = external_call["tk_window_set_title", Int32](
            self._app, self.id, b.unsafe_ptr(), UInt32(len(b)),
        )

    def set_cursor(mut self, shape: String):
        _ = external_call["tk_window_set_cursor", Int32](
            self._app, self.id, _shape_id(shape),
        )

    def capture_bmp(mut self, path: String) -> Bool:
        var b = path.as_bytes()
        var rc = external_call["tk_window_capture_bmp", Int32](
            self._app, self.id, b.unsafe_ptr(), UInt32(len(b)),
        )
        return rc == 0

    def close(mut self):
        _ = external_call["tk_window_close", Int32](self._app, self.id)


struct NativeApp:
    """Owns the native event loop. Open windows with ``open_window``; drive
    the loop with ``pump`` and drain ``(window_id, Event)`` pairs with
    ``next_event``."""

    var _handle: Int
    var _started: Bool
    var _ev_buf: List[UInt32]
    var _queue: List[WinEvent]
    var _queue_head: Int

    def __init__(out self):
        self._handle = 0
        self._started = False
        self._ev_buf = List[UInt32]()
        for _ in range(_MAX_EVENTS * _EV_WORDS):
            self._ev_buf.append(UInt32(0))
        self._queue = List[WinEvent]()
        self._queue_head = 0

    def start(mut self):
        if self._started:
            return
        self._handle = external_call["tk_app_create", Int]()
        self._started = True

    def stop(mut self):
        if not self._started:
            return
        _ = external_call["tk_app_destroy", Int32](self._handle)
        self._started = False

    def open_window(mut self) -> NativeWindow:
        var id = external_call["tk_app_open_window", UInt32](self._handle)
        return NativeWindow(self._handle, id)

    def window_count(mut self) -> Int:
        return Int(external_call["tk_app_window_count", UInt32](self._handle))

    def pump(mut self, timeout_ms: Int):
        """Advance the loop and queue every pending event."""
        var count = external_call["tk_app_pump", UInt32](
            self._handle, UInt32(timeout_ms), self._ev_buf.unsafe_ptr(),
            UInt32(_MAX_EVENTS),
        )
        for i in range(Int(count)):
            var decoded = _decode(self._ev_buf, i * _EV_WORDS)
            self._queue.append(WinEvent(decoded[0], decoded[1]))

    def next_event(mut self) -> Optional[WinEvent]:
        if self._queue_head < len(self._queue):
            var we = self._queue[self._queue_head]
            self._queue_head += 1
            if self._queue_head >= len(self._queue):
                self._queue = List[WinEvent]()
                self._queue_head = 0
            return we
        return None


# --- Single-window convenience (mirrors Terminal) ---------------------------

struct NativeFrontend:
    """One window, with ``Terminal``'s method surface. Implemented as a
    ``NativeApp`` with a single window."""

    var _handle: Int
    var _win: UInt32
    var _started: Bool
    var width: Int
    var height: Int
    var _cell_buf: List[UInt32]
    var _ev_buf: List[UInt32]
    var _queue: List[Event]
    var _queue_head: Int
    var _last_shape: String

    def __init__(out self):
        self._handle = 0
        self._win = UInt32(0)
        self._started = False
        self.width = 80
        self.height = 25
        self._cell_buf = List[UInt32]()
        self._ev_buf = List[UInt32]()
        for _ in range(_MAX_EVENTS * _EV_WORDS):
            self._ev_buf.append(UInt32(0))
        self._queue = List[Event]()
        self._queue_head = 0
        self._last_shape = String("")

    def start(mut self):
        if self._started:
            return
        self._handle = external_call["tk_app_create", Int]()
        self._win = external_call["tk_app_open_window", UInt32](self._handle)
        self._started = True
        self._sync_size()

    def stop(mut self):
        if not self._started:
            return
        _ = external_call["tk_app_destroy", Int32](self._handle)
        self._started = False

    def _sync_size(mut self):
        var cols = List[UInt32]()
        cols.append(UInt32(0))
        var rows = List[UInt32]()
        rows.append(UInt32(0))
        _ = external_call["tk_window_size", Int32](
            self._handle, self._win, cols.unsafe_ptr(), rows.unsafe_ptr(),
        )
        if Int(cols[0]) > 0 and Int(rows[0]) > 0:
            self.width = Int(cols[0])
            self.height = Int(rows[0])

    def refresh_size(mut self) -> Bool:
        """Native resize arrives as an ``EVENT_RESIZE`` through the pump, so
        there's no polling fallback (unlike ``Terminal`` on a TTY)."""
        return False

    def capture_bmp(mut self, path: String) -> Bool:
        if not self._started:
            return False
        var b = path.as_bytes()
        var rc = external_call["tk_window_capture_bmp", Int32](
            self._handle, self._win, b.unsafe_ptr(), UInt32(len(b)),
        )
        return rc == 0

    def set_pointer_shape(mut self, shape: String):
        """Map the Desktop's text/pointer/default hint to a native cursor.
        Deduped so we don't re-set the same icon every mouse-move."""
        if not self._started or shape == self._last_shape:
            return
        self._last_shape = shape
        _ = external_call["tk_window_set_cursor", Int32](
            self._handle, self._win, _shape_id(shape),
        )

    def set_title(mut self, title: String):
        if not self._started:
            return
        var b = title.as_bytes()
        _ = external_call["tk_window_set_title", Int32](
            self._handle, self._win, b.unsafe_ptr(), UInt32(len(b)),
        )

    def present(mut self, back: Canvas) raises:
        _pack_canvas(back, self._cell_buf)
        _ = external_call["tk_window_present", Int32](
            self._handle, self._win, self._cell_buf.unsafe_ptr(),
            UInt32(back.width * back.height * 3),
            UInt32(back.width), UInt32(back.height),
        )

    def poll_event(mut self, timeout_ms: Int = 50) raises -> Optional[Event]:
        if self._queue_head < len(self._queue):
            return self._pop_queue()
        var count = external_call["tk_app_pump", UInt32](
            self._handle, UInt32(timeout_ms), self._ev_buf.unsafe_ptr(),
            UInt32(_MAX_EVENTS),
        )
        for i in range(Int(count)):
            var decoded = _decode(self._ev_buf, i * _EV_WORDS)
            var ev = decoded[1]
            if ev.kind == EVENT_RESIZE:
                self.width = ev.pos.x
                self.height = ev.pos.y
            self._queue.append(ev)
        if self._queue_head < len(self._queue):
            return self._pop_queue()
        return None

    def _pop_queue(mut self) -> Event:
        var ev = self._queue[self._queue_head]
        self._queue_head += 1
        if self._queue_head >= len(self._queue):
            self._queue = List[Event]()
            self._queue_head = 0
        return ev
