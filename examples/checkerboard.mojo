"""Checkerboard test pattern: every other cell is a solid block.

Useful for debugging cell alignment in the host renderer — gaps between rows or
columns are immediately visible because the filled cells should tile seamlessly.

Press q or ESC to quit.

Run with::

    mojo run -I src examples/checkerboard.mojo
"""

from turbokod import (
    Application, Attr, Point,
    BLACK, WHITE,
    EVENT_KEY, KEY_ESC,
)
from turbokod.cell import Cell


fn main() raises:
    var app = Application()
    app.start()
    try:
        var on = Cell(String("█"), Attr(WHITE, BLACK))
        var off = Cell(String(" "), Attr(WHITE, BLACK))

        while app.running:
            app.clear()
            var screen = app.screen()
            for y in range(screen.a.y, screen.b.y):
                for x in range(screen.a.x, screen.b.x):
                    if (x + y) % 2 == 0:
                        app.back.set(x, y, on)
                    else:
                        app.back.set(x, y, off)
            app.present()

            var maybe_ev = app.next_event(100)
            if maybe_ev:
                var ev = maybe_ev.value()
                if ev.kind == EVENT_KEY:
                    if ev.key == KEY_ESC or ev.is_char(UInt32(ord("q"))):
                        app.quit()
    finally:
        app.stop()
