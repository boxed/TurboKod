"""Two independent native macOS windows from one Mojo program.

Demonstrates the multi-window core: a single ``NativeApp`` event loop driving
two ``NativeWindow``s. Each window has its own size, its own Canvas, and its
own state (a keypress counter + last key); events are routed to the right
window by id. Typing in one window only affects that window. ``q`` (or the
window's close button) closes *that* window; the program exits when both are
closed. Run with::

    ./run_native.sh examples/multi_window.mojo

After 12 frames it also writes /tmp/mw1.bmp and /tmp/mw2.bmp so the two
windows can be verified without Screen Recording permission.
"""

from turbokod.native_window import NativeApp, NativeWindow
from turbokod.canvas import Canvas
from turbokod.colors import Attr, BLACK, BLUE, RED, WHITE, YELLOW, LIGHT_GREEN
from turbokod.events import (
    Event, EVENT_KEY, EVENT_QUIT, EVENT_MOUSE,
    KEY_ESC, MOD_SHIFT, MOD_ALT, MOD_CTRL, MOD_META,
)
from turbokod.geometry import Point


def _key_desc(e: Event) -> String:
    var s = String("")
    if (e.mods & MOD_META) != 0:  s += String("Cmd+")
    if (e.mods & MOD_CTRL) != 0:  s += String("Ctrl+")
    if (e.mods & MOD_ALT) != 0:   s += String("Alt+")
    if (e.mods & MOD_SHIFT) != 0: s += String("Shift+")
    var k = Int(e.key)
    if k == Int(KEY_ESC):
        return s + String("Esc")
    if k >= 0x20 and k < 0x7F:
        return s + chr(k)
    return s + String("0x") + hex(k)


def _paint(mut win: NativeWindow, title: String, bar: UInt8, count: Int, last: String) raises:
    win.sync_size()
    var bg = Attr(WHITE, bar)
    var c = Canvas(win.width, win.height)
    c.clear(bg)
    _ = c.put_text(Point(2, 1), title, Attr(YELLOW, bar))
    _ = c.put_text(Point(2, 3),
        String("keys pressed here: ") + String(count), Attr(LIGHT_GREEN, BLACK))
    _ = c.put_text(Point(2, 4),
        String("last key: ") + last, Attr(LIGHT_GREEN, BLACK))
    _ = c.put_text(Point(2, 6),
        String("Type here — only THIS window's counter moves."), bg)
    _ = c.put_text(Point(2, 7),
        String("Press q (or the close button) to close this window."), bg)
    win.present(c)


def main() raises:
    var app = NativeApp()
    app.start()

    var w1 = app.open_window()
    w1.set_title(String("TurboKod — window 1"))
    var w2 = app.open_window()
    w2.set_title(String("TurboKod — window 2"))

    var count1 = 0
    var count2 = 0
    var last1 = String("-")
    var last2 = String("-")
    var open1 = True
    var open2 = True
    var frame = 0
    var captured = False

    while open1 or open2:
        frame += 1
        if open1:
            _paint(w1, String("WINDOW 1"), BLUE, count1, last1)
        if open2:
            _paint(w2, String("WINDOW 2"), RED, count2, last2)

        app.pump(50)
        var maybe = app.next_event()
        while maybe:
            var we = maybe.value()
            var e = we.ev
            var is_w1 = we.win == w1.id
            var is_w2 = we.win == w2.id
            if e.kind == EVENT_QUIT:
                # OS close button for this window.
                if is_w1 and open1:
                    w1.close(); open1 = False
                elif is_w2 and open2:
                    w2.close(); open2 = False
            elif e.kind == EVENT_KEY:
                var quit_this = Int(e.key) == Int(KEY_ESC) or Int(e.key) == ord("q")
                if is_w1:
                    count1 += 1
                    last1 = _key_desc(e)
                    if quit_this and open1:
                        w1.close(); open1 = False
                elif is_w2:
                    count2 += 1
                    last2 = _key_desc(e)
                    if quit_this and open2:
                        w2.close(); open2 = False
            elif e.kind == EVENT_MOUSE:
                if is_w1:
                    last1 = String("mouse ") + String(e.pos.x) + String(",") + String(e.pos.y)
                elif is_w2:
                    last2 = String("mouse ") + String(e.pos.x) + String(",") + String(e.pos.y)
            maybe = app.next_event()

        if frame == 12 and not captured:
            captured = True
            if open1:
                _ = w1.capture_bmp(String("/tmp/mw1.bmp"))
            if open2:
                _ = w2.capture_bmp(String("/tmp/mw2.bmp"))
            print("captured both windows; window_count =", app.window_count())

    app.stop()
    print("both windows closed; exiting")
