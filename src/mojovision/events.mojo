"""Input events: keys, mouse, resize, quit.

The Borland design splits "what kind of event" between four orthogonal `evXxx`
flags and a union — workable in C++, awkward in Mojo. We use a single tagged
discriminant (`kind`) on a plain struct, with the per-kind payload fields zeroed
when not in use. This is a few bytes wasted per event for a much friendlier API.
"""

from .geometry import Point


# --- Event kinds -------------------------------------------------------------

comptime EVENT_NONE   = UInt8(0)
comptime EVENT_KEY    = UInt8(1)
comptime EVENT_MOUSE  = UInt8(2)
comptime EVENT_RESIZE = UInt8(3)
comptime EVENT_QUIT   = UInt8(4)
comptime EVENT_PASTE  = UInt8(5)


# --- Modifiers (bitmask) -----------------------------------------------------

comptime MOD_NONE  = UInt8(0)
comptime MOD_SHIFT = UInt8(1 << 0)
comptime MOD_ALT   = UInt8(1 << 1)
comptime MOD_CTRL  = UInt8(1 << 2)


# --- Special key codes -------------------------------------------------------
#
# Printable keys are represented by their Unicode codepoint (UInt32).
# Special keys use values in the Unicode private-use area (0xE000..0xE0FF) so
# they cannot collide with valid characters.

comptime KEY_NONE      = UInt32(0)
comptime KEY_ENTER     = UInt32(0xE001)
comptime KEY_TAB       = UInt32(0xE002)
comptime KEY_BACKSPACE = UInt32(0xE003)
comptime KEY_ESC       = UInt32(0xE004)
comptime KEY_SPACE     = UInt32(0x0020)

comptime KEY_UP        = UInt32(0xE010)
comptime KEY_DOWN      = UInt32(0xE011)
comptime KEY_LEFT      = UInt32(0xE012)
comptime KEY_RIGHT     = UInt32(0xE013)
comptime KEY_HOME      = UInt32(0xE014)
comptime KEY_END       = UInt32(0xE015)
comptime KEY_PAGEUP    = UInt32(0xE016)
comptime KEY_PAGEDOWN  = UInt32(0xE017)
comptime KEY_INSERT    = UInt32(0xE018)
comptime KEY_DELETE    = UInt32(0xE019)

comptime KEY_F1        = UInt32(0xE020)
comptime KEY_F2        = UInt32(0xE021)
comptime KEY_F3        = UInt32(0xE022)
comptime KEY_F4        = UInt32(0xE023)
comptime KEY_F5        = UInt32(0xE024)
comptime KEY_F6        = UInt32(0xE025)
comptime KEY_F7        = UInt32(0xE026)
comptime KEY_F8        = UInt32(0xE027)
comptime KEY_F9        = UInt32(0xE028)
comptime KEY_F10       = UInt32(0xE029)
comptime KEY_F11       = UInt32(0xE02A)
comptime KEY_F12       = UInt32(0xE02B)


# --- Mouse buttons -----------------------------------------------------------

comptime MOUSE_BUTTON_NONE   = UInt8(0)
comptime MOUSE_BUTTON_LEFT   = UInt8(1)
comptime MOUSE_BUTTON_MIDDLE = UInt8(2)
comptime MOUSE_BUTTON_RIGHT  = UInt8(3)
comptime MOUSE_WHEEL_UP      = UInt8(4)
comptime MOUSE_WHEEL_DOWN    = UInt8(5)


@fieldwise_init
struct Event(ImplicitlyCopyable, Movable):
    var kind: UInt8

    # Key payload
    var key: UInt32
    var mods: UInt8

    # Mouse payload
    var pos: Point
    var button: UInt8
    var pressed: Bool   # True for press / drag-motion, False for release
    var motion: Bool    # True if this event came from drag motion (not initial press)

    # Resize payload (also stored in pos: width=x, height=y)

    # Paste payload
    var text: String

    fn __init__(out self):
        self.kind = EVENT_NONE
        self.key = KEY_NONE
        self.mods = MOD_NONE
        self.pos = Point(0, 0)
        self.button = MOUSE_BUTTON_NONE
        self.pressed = False
        self.motion = False
        self.text = String("")

    @staticmethod
    fn key_event(key: UInt32, mods: UInt8 = MOD_NONE) -> Event:
        var e = Event()
        e.kind = EVENT_KEY
        e.key = key
        e.mods = mods
        return e

    @staticmethod
    fn mouse_event(
        pos: Point,
        button: UInt8,
        pressed: Bool = True,
        motion: Bool = False,
        mods: UInt8 = MOD_NONE,
    ) -> Event:
        var e = Event()
        e.kind = EVENT_MOUSE
        e.pos = pos
        e.button = button
        e.pressed = pressed
        e.motion = motion
        e.mods = mods
        return e

    @staticmethod
    fn resize_event(width: Int, height: Int) -> Event:
        var e = Event()
        e.kind = EVENT_RESIZE
        e.pos = Point(width, height)
        return e

    @staticmethod
    fn quit_event() -> Event:
        var e = Event()
        e.kind = EVENT_QUIT
        return e

    @staticmethod
    fn paste_event(var text: String) -> Event:
        var e = Event()
        e.kind = EVENT_PASTE
        e.text = text^
        return e

    fn is_key(self, key: UInt32) -> Bool:
        return self.kind == EVENT_KEY and self.key == key

    fn is_char(self, c: UInt32) -> Bool:
        return self.kind == EVENT_KEY and self.key == c
