"""Native-window hello: proves the Mojo-driven frontend end to end.

Unlike ``examples/hello.mojo`` (which runs in a terminal via ``Terminal``),
this opens a real macOS window through ``NativeFrontend`` — no TTY, no
escape sequences. Run with::

    ./run_native.sh examples/hello_native.mojo

Type anything (including Cmd+key / Ctrl+key chords) and the window shows
the key + modifiers it received as a *direct* event — demonstrating that
hotkeys arrive as plain values, not parsed escape sequences. ESC or Q
quits; closing the window quits too.
"""

from turbokod.native_window import NativeFrontend
from turbokod.canvas import Canvas
from turbokod.colors import Attr, BLACK, BLUE, CYAN, WHITE, YELLOW, LIGHT_GREEN
from turbokod.events import (
    Event, EVENT_KEY, EVENT_QUIT, EVENT_MOUSE,
    KEY_ESC, MOD_SHIFT, MOD_ALT, MOD_CTRL, MOD_META,
)
from turbokod.geometry import Point


def _mods_desc(mods: UInt8) -> String:
    var s = String("")
    if (mods & MOD_META) != 0:  s += String("Cmd+")
    if (mods & MOD_CTRL) != 0:  s += String("Ctrl+")
    if (mods & MOD_ALT) != 0:   s += String("Alt+")
    if (mods & MOD_SHIFT) != 0: s += String("Shift+")
    return s


def _key_desc(e: Event) -> String:
    var k = Int(e.key)
    var name: String
    if k == Int(KEY_ESC):
        name = String("Esc")
    elif k >= 0x20 and k < 0x7F:
        name = chr(k)
    else:
        name = String("0x") + hex(k)
    return _mods_desc(e.mods) + name


def main() raises:
    var fe = NativeFrontend()
    fe.start()
    fe.set_title("TurboKod — native hello")

    var bg = Attr(WHITE, BLUE)
    var last_event = String("(press a key)")
    var running = True
    while running:
        var back = Canvas(fe.width, fe.height)
        back.clear(bg)
        _ = back.put_text(Point(2, 1),
            String("Hello from a native macOS window!"), Attr(YELLOW, BLUE))
        _ = back.put_text(Point(2, 3),
            String("No terminal. No escape sequences."), Attr(CYAN, BLUE))
        _ = back.put_text(Point(2, 4),
            String("Keys (even Cmd+…) arrive as direct events:"),
            Attr(WHITE, BLUE))
        _ = back.put_text(Point(4, 6),
            String("last event:  ") + last_event, Attr(LIGHT_GREEN, BLACK))
        _ = back.put_text(Point(2, 8),
            String("Press ESC or Q to quit."), Attr(WHITE, BLUE))
        fe.present(back)

        var ev = fe.poll_event(50)
        if ev:
            var e = ev.value()
            if e.kind == EVENT_QUIT:
                running = False
            elif e.kind == EVENT_KEY:
                last_event = _key_desc(e)
                if Int(e.key) == Int(KEY_ESC) or Int(e.key) == ord("q"):
                    running = False
            elif e.kind == EVENT_MOUSE:
                last_event = String("mouse @ ") + String(e.pos.x) \
                    + String(",") + String(e.pos.y)
    fe.stop()
