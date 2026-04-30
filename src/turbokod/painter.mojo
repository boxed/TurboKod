"""Clip-aware drawing wrapper for ``Canvas``.

Every widget in the toolkit takes a ``mut Canvas`` and a ``Rect``
describing its area. Without help, each one has to remember to pass
``max_x`` to ``put_text``, intersect rects before ``fill``, and
range-check before ``set`` — and forgetting any of those leaks pixels
into the next widget's space. ``Painter`` packages a clip rect with
clip-correct versions of those primitives so widgets can ignore the
boundary entirely: writes outside the clip are silently dropped, text
that runs past the right edge stops there, and a multi-byte glyph
straddling the boundary doesn't corrupt the cell on the far side.

Pass ``Painter(rect)`` alongside the canvas to widget paint methods.
For nested layouts (frame → interior → row) chain ``sub(inner_rect)`` —
the result clips to the intersection, so a sub-painter can never
escape its parent.

The struct is value-typed and cheap to copy (just a ``Rect``); the
canvas reference flows through method args rather than being captured,
which keeps Painter free of lifetime annotations.
"""

from .canvas import Canvas
from .cell import Cell
from .colors import Attr
from .geometry import Point, Rect


fn _codepoint_size(b: Int) -> Int:
    """Byte length of the UTF-8 codepoint that begins with lead byte ``b``.
    Returns 1 for invalid leads so a stray continuation byte never traps
    a forward walk."""
    if b < 0x80:
        return 1
    if (b & 0xE0) == 0xC0:
        return 2
    if (b & 0xF0) == 0xE0:
        return 3
    if (b & 0xF8) == 0xF0:
        return 4
    return 1


struct Painter(Copyable, Movable):
    """A clip rect bound to a Canvas. All drawing is intersected with
    the clip; widgets pass a Painter and forget about boundaries."""
    var clip: Rect

    fn __init__(out self, clip: Rect):
        self.clip = clip

    fn put_text(
        self,
        mut canvas: Canvas,
        p: Point,
        text: String,
        attr: Attr,
    ) -> Int:
        """Paint ``text`` at ``p``, clipped to ``self.clip`` on all four
        sides. Returns the number of cells advanced inside the clip
        (zero when the row is outside the clip vertically).

        Codepoint-aligned: when the start point is left of the clip,
        leading codepoints are skipped one cell at a time so the
        remaining glyphs land at the correct visual columns. The right
        edge is delegated to ``Canvas.put_text``'s ``max_x`` arg, which
        already stops mid-string without splitting a UTF-8 sequence.
        """
        if p.y < self.clip.a.y or p.y >= self.clip.b.y:
            return 0
        if p.x >= self.clip.b.x:
            return 0
        var bytes = text.as_bytes()
        var n = len(bytes)
        var i = 0
        var x = p.x
        while x < self.clip.a.x and i < n:
            i += _codepoint_size(Int(bytes[i]))
            x += 1
        if i >= n:
            return 0
        if i == 0:
            return canvas.put_text(p, text, attr, self.clip.b.x)
        var sub = String(StringSlice(unsafe_from_utf8=bytes[i:]))
        return canvas.put_text(Point(x, p.y), sub, attr, self.clip.b.x)

    fn fill(
        self,
        mut canvas: Canvas,
        rect: Rect,
        glyph: String,
        attr: Attr,
    ):
        """Fill the intersection of ``rect`` and ``self.clip``. A rect
        entirely outside the clip is a no-op."""
        var c = rect.intersect(self.clip)
        if c.is_empty():
            return
        canvas.fill(c, glyph, attr)

    fn set(
        self,
        mut canvas: Canvas,
        x: Int, y: Int,
        var cell: Cell,
    ):
        if x < self.clip.a.x or x >= self.clip.b.x \
                or y < self.clip.a.y or y >= self.clip.b.y:
            return
        canvas.set(x, y, cell^)

    fn set_attr(
        self, mut canvas: Canvas, x: Int, y: Int, attr: Attr,
    ):
        if x < self.clip.a.x or x >= self.clip.b.x \
                or y < self.clip.a.y or y >= self.clip.b.y:
            return
        canvas.set_attr(x, y, attr)

    fn draw_box(
        self,
        mut canvas: Canvas,
        rect: Rect,
        attr: Attr,
        double_line: Bool = False,
    ):
        """Draw a box around ``rect``; sides crossing the clip are
        partially drawn, sides fully outside are skipped."""
        if rect.width() < 2 or rect.height() < 2:
            return
        var tl: String
        var tr: String
        var bl: String
        var br: String
        var hz: String
        var vt: String
        if double_line:
            tl = String("╔"); tr = String("╗")
            bl = String("╚"); br = String("╝")
            hz = String("═"); vt = String("║")
        else:
            tl = String("┌"); tr = String("┐")
            bl = String("└"); br = String("┘")
            hz = String("─"); vt = String("│")
        var x0 = rect.a.x
        var y0 = rect.a.y
        var x1 = rect.b.x - 1
        var y1 = rect.b.y - 1
        for x in range(x0 + 1, x1):
            self.set(canvas, x, y0, Cell(hz, attr, 1))
            self.set(canvas, x, y1, Cell(hz, attr, 1))
        for y in range(y0 + 1, y1):
            self.set(canvas, x0, y, Cell(vt, attr, 1))
            self.set(canvas, x1, y, Cell(vt, attr, 1))
        self.set(canvas, x0, y0, Cell(tl, attr, 1))
        self.set(canvas, x1, y0, Cell(tr, attr, 1))
        self.set(canvas, x0, y1, Cell(bl, attr, 1))
        self.set(canvas, x1, y1, Cell(br, attr, 1))

    fn sub(self, rect: Rect) -> Self:
        """A Painter restricted to the intersection of ``rect`` and the
        current clip. Useful when a parent passes a wider painter and
        the child wants to constrain itself to a sub-area."""
        return Self(rect.intersect(self.clip))
