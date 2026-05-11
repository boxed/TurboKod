"""Views: composable units that paint themselves and react to events.

The C++ TurboVision design uses deep single-inheritance: TView → TGroup →
TWindow → TDialog. Mojo structs don't have inheritance, so we lean on
*composition*: a small `Drawable` trait that anything paintable implements,
and concrete widget structs that hold state. A real "view hierarchy" with
parent/child dispatch is a TODO — for now this layer is enough to compose
windowed UIs out of plain functions and small structs.

This file is intentionally bare. The `widgets` module (or just direct calls
into Canvas) gives you immediate-mode drawing if you don't want to build
state-bearing widget structs.
"""

from .canvas import Canvas
from .painter import Painter
from .colors import Attr, default_attr, WHITE, BLUE, BLACK, LIGHT_GRAY
from .events import Event
from .geometry import Point, Rect


trait Drawable:
    """Anything that can paint itself into a Canvas at a given rect."""
    fn paint(self, mut canvas: Canvas, bounds: Rect): ...


trait EventHandler:
    """Anything that can react to an event. Returns True if handled."""
    fn handle(mut self, event: Event) -> Bool: ...


# --- Concrete widgets -------------------------------------------------------


struct Label(Copyable, Movable, Drawable):
    var text: String
    var attr: Attr

    fn __init__(out self, var text: String):
        self.text = text^
        self.attr = default_attr()

    fn __init__(out self, var text: String, attr: Attr):
        self.text = text^
        self.attr = attr

    fn paint(self, mut canvas: Canvas, bounds: Rect):
        if bounds.is_empty():
            return
        # Center horizontally, top-align vertically.
        var text_len = len(self.text.as_bytes())
        var x = bounds.a.x + (bounds.width() - text_len) // 2
        if x < bounds.a.x:
            x = bounds.a.x
        var painter = Painter(bounds)
        _ = painter.put_text(canvas, Point(x, bounds.a.y), self.text, self.attr)


struct Frame(Copyable, Movable, Drawable):
    """A bordered window with an optional title in the top edge."""
    var title: String
    var attr: Attr
    var double_line: Bool

    fn __init__(out self, var title: String):
        self.title = title^
        self.attr = Attr(WHITE, BLUE)
        self.double_line = False

    fn __init__(out self, var title: String, attr: Attr, double_line: Bool = False):
        self.title = title^
        self.attr = attr
        self.double_line = double_line

    fn paint(self, mut canvas: Canvas, bounds: Rect):
        if bounds.width() < 2 or bounds.height() < 2:
            return
        var painter = Painter(bounds)
        # Fill interior with the frame's background color so contents inherit it.
        var interior = Rect(bounds.a.x + 1, bounds.a.y + 1, bounds.b.x - 1, bounds.b.y - 1)
        if not interior.is_empty():
            painter.fill(canvas, interior, String(" "), self.attr)
        painter.draw_box(canvas, bounds, self.attr, self.double_line)
        if len(self.title) > 0 and bounds.width() >= len(self.title.as_bytes()) + 4:
            var label = String(" ") + self.title + String(" ")
            var label_len = len(label.as_bytes())
            var x = bounds.a.x + (bounds.width() - label_len) // 2
            _ = painter.put_text(canvas, Point(x, bounds.a.y), label, self.attr)


struct Fill(Copyable, Movable, Drawable):
    """Solid fill — useful as a background panel."""
    var glyph: String
    var attr: Attr

    fn __init__(out self):
        self.glyph = String(" ")
        self.attr = Attr(LIGHT_GRAY, BLACK)

    fn __init__(out self, var glyph: String, attr: Attr):
        self.glyph = glyph^
        self.attr = attr

    fn paint(self, mut canvas: Canvas, bounds: Rect):
        var painter = Painter(bounds)
        painter.fill(canvas, bounds, self.glyph, self.attr)


# --- Layout helpers ---------------------------------------------------------


fn centered(outer: Rect, width: Int, height: Int) -> Rect:
    """Return the rectangle of ``width × height`` centered inside ``outer``."""
    var x = outer.a.x + (outer.width() - width) // 2
    var y = outer.a.y + (outer.height() - height) // 2
    return Rect(x, y, x + width, y + height)


struct RowCursor(Copyable, Movable):
    """Vertical layout cursor that automatically inserts a blank row
    between consecutive control placements.

    Dialogs that hand-code Y offsets routinely end up gluing controls
    together — the next placement is `y + height`, with no breathing
    room — and the bug surfaces as a labelled field sitting directly on
    top of the list below it. ``RowCursor`` makes the gap the default:
    every ``place()`` after the first reserves ``gap`` rows of vertical
    whitespace *before* the new control's start. Callers get correct
    spacing by writing the obvious thing.

    Use ``place(height)`` for normal controls (label + field row, list,
    button row). Use ``place_tight(height)`` for a follow-on that's part
    of the same logical unit as the previous placement (e.g. a block
    label glued to the list it heads). Use ``skip(rows)`` for explicit
    extra whitespace beyond the automatic gap.

    ```
    var c = RowCursor(rect.a.y + 1)
    var lang_y = c.place()              # rect.a.y + 1
    var ft_y   = c.place()              # rect.a.y + 3 — one row gap
    var lbl_y  = c.place()              # rect.a.y + 5
    var list_y = c.place_tight(5)       # rect.a.y + 6 — no gap from label
    ```
    """
    var y: Int
    var gap: Int
    var _first: Bool

    fn __init__(out self, start_y: Int, gap: Int = 1):
        self.y = start_y
        self.gap = gap
        self._first = True

    fn place(mut self, height: Int = 1) -> Int:
        if not self._first:
            self.y = self.y + self.gap
        self._first = False
        var start = self.y
        self.y = self.y + height
        return start

    fn place_tight(mut self, height: Int = 1) -> Int:
        self._first = False
        var start = self.y
        self.y = self.y + height
        return start

    fn skip(mut self, rows: Int):
        self.y = self.y + rows
