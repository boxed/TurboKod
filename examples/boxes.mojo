"""A second demo: drag a window with the mouse, or move it with the arrow keys.

Press q or ESC to quit.

Run with::

    mojo run -I src examples/boxes.mojo
"""

from turbokod import (
    Application, Attr, Frame, Label, Point, Rect,
    BLACK, BLUE, CYAN, GREEN, MAGENTA, WHITE, YELLOW,
    EVENT_KEY, EVENT_MOUSE, EVENT_RESIZE,
    KEY_DOWN, KEY_ESC, KEY_LEFT, KEY_RIGHT, KEY_UP,
    MOUSE_BUTTON_LEFT,
)
from turbokod.view import Fill


fn main() raises:
    var app = Application()
    app.start()
    try:
        var pos = Point(10, 5)
        var w = 20
        var h = 5
        var dragging = False
        var drag_dx = 0
        var drag_dy = 0
        var bg = Fill(String("·"), Attr(CYAN, BLACK))
        var box = Frame(String("drag me"), Attr(YELLOW, MAGENTA), False)

        while app.running:
            app.clear()
            bg.paint(app.back, app.screen())
            var screen = app.screen()
            var hint_text = String("size ") + String(screen.b.x) + String("×") + String(screen.b.y) + String(" • drag with mouse • arrows move • q quits")
            var hint = Label(hint_text, Attr(WHITE, BLACK))
            hint.paint(app.back, Rect(0, screen.b.y - 1, screen.b.x, screen.b.y))
            var rect = Rect(pos.x, pos.y, pos.x + w, pos.y + h)
            box.paint(app.back, rect)
            app.present()

            var maybe_ev = app.next_event(50)
            if maybe_ev:
                var ev = maybe_ev.value()
                if ev.kind == EVENT_KEY:
                    if ev.key == KEY_ESC or ev.is_char(UInt32(ord("q"))):
                        app.quit()
                    elif ev.key == KEY_LEFT and pos.x > 0:
                        pos = Point(pos.x - 1, pos.y)
                    elif ev.key == KEY_RIGHT and pos.x + w < screen.b.x:
                        pos = Point(pos.x + 1, pos.y)
                    elif ev.key == KEY_UP and pos.y > 0:
                        pos = Point(pos.x, pos.y - 1)
                    elif ev.key == KEY_DOWN and pos.y + h < screen.b.y - 1:
                        pos = Point(pos.x, pos.y + 1)
                elif ev.kind == EVENT_MOUSE and ev.button == MOUSE_BUTTON_LEFT:
                    if ev.pressed and not ev.motion:
                        # Initial press: only start dragging if it lands on the box.
                        if rect.contains(ev.pos):
                            dragging = True
                            drag_dx = ev.pos.x - pos.x
                            drag_dy = ev.pos.y - pos.y
                    elif ev.pressed and dragging:
                        # Drag motion — keep the grabbed point under the cursor.
                        var nx = ev.pos.x - drag_dx
                        var ny = ev.pos.y - drag_dy
                        if nx < 0: nx = 0
                        if ny < 0: ny = 0
                        if nx + w > screen.b.x: nx = screen.b.x - w
                        if ny + h > screen.b.y - 1: ny = screen.b.y - 1 - h
                        pos = Point(nx, ny)
                    else:
                        dragging = False
    finally:
        app.stop()
