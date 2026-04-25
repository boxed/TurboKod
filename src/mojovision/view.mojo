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
        _ = canvas.put_text(Point(x, bounds.a.y), self.text, self.attr)


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
        # Fill interior with the frame's background color so contents inherit it.
        var interior = Rect(bounds.a.x + 1, bounds.a.y + 1, bounds.b.x - 1, bounds.b.y - 1)
        if not interior.is_empty():
            canvas.fill(interior, String(" "), self.attr)
        canvas.draw_box(bounds, self.attr, self.double_line)
        if len(self.title) > 0 and bounds.width() >= len(self.title.as_bytes()) + 4:
            var label = String(" ") + self.title + String(" ")
            var label_len = len(label.as_bytes())
            var x = bounds.a.x + (bounds.width() - label_len) // 2
            _ = canvas.put_text(Point(x, bounds.a.y), label, self.attr)


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
        canvas.fill(bounds, self.glyph, self.attr)


# --- Layout helpers ---------------------------------------------------------


fn centered(outer: Rect, width: Int, height: Int) -> Rect:
    """Return the rectangle of ``width × height`` centered inside ``outer``."""
    var x = outer.a.x + (outer.width() - width) // 2
    var y = outer.a.y + (outer.height() - height) // 2
    return Rect(x, y, x + width, y + height)
