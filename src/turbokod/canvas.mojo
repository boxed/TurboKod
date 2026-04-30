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

        If ``max_x`` is non-negative, painting stops at column ``max_x``
        (exclusive) — letting callers like ``Window`` clip text to their
        own bounds without building a truncated string.

        Codepoint-aligned: each codepoint occupies one cell carrying the
        full UTF-8 byte sequence as its glyph string. Callers that hold
        byte indices (the editor's overlay paths) need
        ``utf8_byte_to_cell`` to translate. East-Asian width is *not*
        modeled — every glyph advances by one cell — so wide characters
        will overlap their right neighbour.
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
        var n = len(bytes)
        var i = 0
        while i < n and x < limit:
            var b = Int(bytes[i])
            var glyph: String
            var seq_len: Int
            if b < 0x80:
                glyph = chr(b)
                seq_len = 1
            elif (b & 0xE0) == 0xC0 and i + 2 <= n:
                glyph = String(StringSlice(unsafe_from_utf8=bytes[i:i+2]))
                seq_len = 2
            elif (b & 0xF0) == 0xE0 and i + 3 <= n:
                glyph = String(StringSlice(unsafe_from_utf8=bytes[i:i+3]))
                seq_len = 3
            elif (b & 0xF8) == 0xF0 and i + 4 <= n:
                glyph = String(StringSlice(unsafe_from_utf8=bytes[i:i+4]))
                seq_len = 4
            else:
                # Stray continuation or truncated tail — show ``?``
                # rather than losing the column to silence.
                glyph = String("?")
                seq_len = 1
            if x >= 0:
                self.cells[self._index(x, y)] = Cell(glyph, attr, 1)
            x += 1
            advanced += 1
            i += seq_len
        return advanced

    fn set_attr(mut self, x: Int, y: Int, attr: Attr):
        """Change the attribute at ``(x, y)`` without touching the glyph.

        Lets overlay passes (highlight, selection, cursor) recolor cells
        without re-deriving glyphs from byte arrays — which would
        otherwise force every overlay path to repeat the UTF-8 decoding
        ``put_text`` already did.
        """
        if x < 0 or x >= self.width or y < 0 or y >= self.height:
            return
        var idx = self._index(x, y)
        var current = self.cells[idx]
        self.cells[idx] = Cell(current.glyph, attr, current.width)

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


fn utf8_byte_to_cell(text: String) -> List[Int]:
    """Map every byte index in ``text`` to the cell column its codepoint
    occupies under ``Canvas.put_text``'s codepoint-aligned layout.

    Length equals ``len(text.as_bytes())`` so callers can index by raw
    byte position (the editor's column model). All bytes belonging to
    one multi-byte UTF-8 sequence map to the same cell. Use
    ``utf8_codepoint_count(text)`` to find the cell *just past* the
    last codepoint — useful when a cursor or selection sits at EOL.
    """
    var bytes = text.as_bytes()
    var n = len(bytes)
    var result = List[Int]()
    var cell = 0
    var i = 0
    while i < n:
        var b = Int(bytes[i])
        var seq_len: Int
        if b < 0x80:
            seq_len = 1
        elif (b & 0xE0) == 0xC0:
            seq_len = 2
        elif (b & 0xF0) == 0xE0:
            seq_len = 3
        elif (b & 0xF8) == 0xF0:
            seq_len = 4
        else:
            seq_len = 1
        if i + seq_len > n:
            seq_len = n - i
        for _ in range(seq_len):
            result.append(cell)
        cell += 1
        i += seq_len
    return result^


fn utf8_codepoint_count(text: String) -> Int:
    """Number of codepoints in ``text``. Equals the cell count
    ``Canvas.put_text(text)`` produces."""
    var bytes = text.as_bytes()
    var n = len(bytes)
    var count = 0
    var i = 0
    while i < n:
        var b = Int(bytes[i])
        var seq_len: Int
        if b < 0x80:
            seq_len = 1
        elif (b & 0xE0) == 0xC0:
            seq_len = 2
        elif (b & 0xF0) == 0xE0:
            seq_len = 3
        elif (b & 0xF8) == 0xF0:
            seq_len = 4
        else:
            seq_len = 1
        if i + seq_len > n:
            seq_len = n - i
        count += 1
        i += seq_len
    return count
