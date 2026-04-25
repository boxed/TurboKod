"""Mojovision hello-world: a centered greeting in a window. Press q or ESC to quit.

Run with::

    mojo run -I src examples/hello.mojo
"""

from mojovision import (
    Application, Attr, Frame, Label, Point, Rect,
    BLUE, BLACK, CYAN, WHITE, YELLOW,
    EVENT_KEY, KEY_ESC,
    centered,
)
from mojovision.view import Drawable, Fill


fn main() raises:
    var app = Application()
    app.start()
    try:
        var bg = Fill(String("░"), Attr(CYAN, BLACK))
        var frame = Frame(String("Mojovision"), Attr(WHITE, BLUE), True)
        var greeting = Label(String("Hello from Mojo!"), Attr(YELLOW, BLUE))
        var hint = Label(String("press q or ESC to quit"), Attr(WHITE, BLUE))

        while app.running:
            app.clear()
            bg.paint(app.back, app.screen())
            var box = centered(app.screen(), 40, 7)
            frame.paint(app.back, box)
            greeting.paint(app.back, Rect(box.a.x + 1, box.a.y + 2, box.b.x - 1, box.a.y + 3))
            hint.paint(app.back, Rect(box.a.x + 1, box.a.y + 4, box.b.x - 1, box.a.y + 5))
            app.present()

            var maybe_ev = app.next_event(100)
            if maybe_ev:
                var ev = maybe_ev.value()
                if ev.kind == EVENT_KEY:
                    if ev.key == KEY_ESC or ev.is_char(UInt32(ord("q"))):
                        app.quit()
    finally:
        app.stop()
