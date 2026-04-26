"""Canvas: a 2D grid of `Cell` plus drawing primitives.

The Canvas is the only place that mutates pixel state; all widgets paint into
a Canvas, and the Terminal driver flushes a Canvas to the screen. Two canvases
(front and back) let the driver compute a minimal diff each frame — the same
"swap buffers" trick TurboVision's `TDisplayBuffer` uses, but here it's a
simple List-of-Cells rather than a packed 16-bit attribute buffer.
"""

from std.collections import List

from .cell import Cell, blank_cell
from .colors import Attr, default_attr
from .geometry import Point, Rect


@fieldwise_init
struct Canvas(Copyable, Movable):
    var width: Int
    var height: Int
    var cells: List[Cell]  # row-major, length == width * height

    fn __init__(out self, width: Int, height: Int):
        self.width = width
        self.height = height
        self.cells = List[Cell]()
        var n = width * height
        for _ in range(n):
            self.cells.append(blank_cell())

    fn resize(mut self, width: Int, height: Int):
        self.width = width
        self.height = height
        self.cells = List[Cell]()
        var n = width * height
        for _ in range(n):
            self.cells.append(blank_cell())

    fn _index(self, x: Int, y: Int) -> Int:
        return y * self.width + x

    fn in_bounds(self, x: Int, y: Int) -> Bool:
        return 0 <= x and x < self.width and 0 <= y and y < self.height

    fn get(self, x: Int, y: Int) -> Cell:
        if not self.in_bounds(x, y):
            return blank_cell()
        return self.cells[self._index(x, y)]

    fn set(mut self, x: Int, y: Int, var cell: Cell):
        if self.in_bounds(x, y):
            self.cells[self._index(x, y)] = cell^

    fn clear(mut self, attr: Attr = default_attr()):
        var blank = Cell(String(" "), attr, 1)
        for i in range(len(self.cells)):
            self.cells[i] = blank

    fn fill(mut self, rect: Rect, glyph: String, attr: Attr):
        var cell = Cell(glyph, attr)
        var w = cell.width
        if w < 1:
            w = 1
        var clipped = rect.intersect(Rect(0, 0, self.width, self.height))
        for y in range(clipped.a.y, clipped.b.y):
            var x = clipped.a.x
            while x < clipped.b.x:
                self.cells[self._index(x, y)] = cell
                x += w

    fn put_text(mut self, p: Point, text: String, attr: Attr, max_x: Int = -1) -> Int:
        """Paint ``text`` starting at ``p`` (no wrapping). Returns columns advanced.

        If ``max_x`` is non-negative, painting stops at column ``max_x`` (exclusive)
        — letting callers like ``Window`` clip text to their own bounds without
        building a temporary truncated string.

        ASCII-only at present. Multi-byte UTF-8 glyphs in ``text`` will paint as
        replacement characters; properly handling them requires a real
        grapheme-cluster iterator that respects East-Asian widths. To draw
        non-ASCII glyphs today, build ``Cell`` values directly with the desired
        UTF-8 string and call ``set()`` (which is what ``draw_box`` does).
        """
        var x = p.x
        var y = p.y
        var advanced = 0
        if y < 0 or y >= self.height:
            return 0
        var limit = self.width
        if max_x >= 0 and max_x < limit:
            limit = max_x
        var bytes = text.as_bytes()
        var i = 0
        while i < len(bytes):
            var b = Int(bytes[i])
            var glyph: String
            if b < 0x80:
                glyph = chr(b)
            else:
                # Skip past the rest of this UTF-8 sequence and substitute '?'.
                glyph = String("?")
                if (b & 0xF8) == 0xF0:
                    i += 3
                elif (b & 0xF0) == 0xE0:
                    i += 2
                elif (b & 0xE0) == 0xC0:
                    i += 1
            i += 1
            if x >= limit:
                break
            if x >= 0:
                self.cells[self._index(x, y)] = Cell(glyph, attr, 1)
            x += 1
            advanced += 1
        return advanced

    fn draw_box(mut self, rect: Rect, attr: Attr, double_line: Bool = False):
        if rect.width() < 2 or rect.height() < 2:
            return
        var tl: String
        var tr: String
        var bl: String
        var br: String
        var hz: String
        var vt: String
        if double_line:
            tl = String("╔"); tr = String("╗"); bl = String("╚"); br = String("╝")
            hz = String("═"); vt = String("║")
        else:
            tl = String("┌"); tr = String("┐"); bl = String("└"); br = String("┘")
            hz = String("─"); vt = String("│")
        var x0 = rect.a.x
        var y0 = rect.a.y
        var x1 = rect.b.x - 1
        var y1 = rect.b.y - 1
        for x in range(x0 + 1, x1):
            self.set(x, y0, Cell(hz, attr, 1))
            self.set(x, y1, Cell(hz, attr, 1))
        for y in range(y0 + 1, y1):
            self.set(x0, y, Cell(vt, attr, 1))
            self.set(x1, y, Cell(vt, attr, 1))
        self.set(x0, y0, Cell(tl, attr, 1))
        self.set(x1, y0, Cell(tr, attr, 1))
        self.set(x0, y1, Cell(bl, attr, 1))
        self.set(x1, y1, Cell(br, attr, 1))

    fn draw_hline(mut self, p: Point, length: Int, glyph: String, attr: Attr):
        var cell = Cell(glyph, attr, 1)
        for i in range(length):
            self.set(p.x + i, p.y, cell)

    fn draw_vline(mut self, p: Point, length: Int, glyph: String, attr: Attr):
        var cell = Cell(glyph, attr, 1)
        for i in range(length):
            self.set(p.x, p.y + i, cell)
