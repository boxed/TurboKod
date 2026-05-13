"""Canvas: a 2D grid of `Cell` plus drawing primitives.

The Canvas is the only place that mutates pixel state; all widgets paint into
a Canvas, and the Terminal driver flushes a Canvas to the screen. Two canvases
(front and back) let the driver compute a minimal diff each frame — the same
"swap buffers" trick TurboVision's `TDisplayBuffer` uses, but here it's a
simple List-of-Cells rather than a packed 16-bit attribute buffer.
"""

from std.collections import List

from .cell import Cell, blank_cell
from .colors import Attr, BLACK, DARK_GRAY, default_attr
from .geometry import Point, Rect


# Number of cells a tab byte expands to. ``put_text`` aligns each tab
# to the next multiple of this width. Four matches the prevailing
# convention in the editor's grammars and mirrors what most code
# editors render by default. Exported so other layers (Painter's
# left-clip walker, the editor's column model) advance their own
# cell counters in lock-step with what ``put_text`` actually emits.
comptime TAB_WIDTH: Int = 4


fn _control_picture_glyph(b: Int) -> String:
    """UTF-8 'Control Pictures' glyph for an ASCII control byte.

    Maps 0x00..0x1F to U+2400..U+241F (␀..␟) and 0x7F to U+2421 (␡).
    Used by ``put_text`` so a stray control byte (most commonly ``\r``
    from a CRLF file that slipped through) becomes a visible cell
    instead of being emitted raw to the terminal — a raw ``\r`` would
    reset the cursor to column 0 mid-row and corrupt the entire paint.
    """
    var cp: Int
    if b == 0x7F:
        cp = 0x2421
    else:
        cp = 0x2400 + b
    # UTF-8 three-byte form for U+2400..U+24FF: 1110xxxx 10xxxxxx 10xxxxxx.
    # ``chr()`` encodes each value as the UTF-8 of *that codepoint*, so
    # the obvious ``chr(b1) + chr(b2) + chr(b3)`` doubles the byte count
    # for values >= 0x80. Build the bytes directly instead.
    var buf = List[UInt8]()
    buf.append(UInt8(0xE0 | (cp >> 12)))
    buf.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
    buf.append(UInt8(0x80 | (cp & 0x3F)))
    return String(StringSlice(ptr=buf.unsafe_ptr(), length=len(buf)))


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
        Tab bytes (``0x09``) are expanded to spaces here — emitting the
        raw ``\\t`` byte to the terminal would let the terminal advance
        the cursor by however many columns *it* chose, breaking every
        downstream cell-position calculation (clip rects, gutter
        offsets, highlight overlays). Each tab fills until the next
        multiple of ``TAB_WIDTH`` cells, so on-screen indentation
        matches the source while every advancing cell remains a
        deterministic 1-cell-1-glyph write.
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
            if b == 0x09:    # TAB → fill spaces to next tab stop
                var stop = x + TAB_WIDTH - (x % TAB_WIDTH)
                if stop > limit: stop = limit
                while x < stop:
                    if x >= 0:
                        self.cells[self._index(x, y)] = Cell(
                            String(" "), attr, 1,
                        )
                    x += 1
                    advanced += 1
                i += 1
                continue
            var glyph: String
            var seq_len: Int
            if b < 0x80:
                # ASCII control bytes (0x00..0x1F minus 0x09 tab, which
                # the loop's earlier tab branch already handled; 0x0A
                # never reaches here because callers split on newlines
                # before painting) and 0x7F DEL are substituted with
                # their Unicode 'Control Pictures' glyphs so the raw
                # byte never reaches the terminal — a stray ``\r``
                # would otherwise drag the cursor to column 0 mid-row.
                if b < 0x20 or b == 0x7F:
                    glyph = _control_picture_glyph(b)
                else:
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

    fn darken_rect(mut self, rect: Rect):
        """Recolor every cell inside ``rect`` to a "shadow" attr,
        preserving each glyph and width.

        Compositor primitive for drop shadows under floating widgets
        (dialogs, popups). The shadow region is whatever was already
        painted underneath — we don't overwrite the glyph, just dim
        it. The fixed shadow attr is ``DARK_GRAY`` (color 8 / "bright
        black") on ``BLACK``: any visible glyph beneath the shadow
        reads as faintly visible dim text, and a blank cell renders
        as a black square — the classic Turbo Vision look.
        """
        var shadow = Attr(DARK_GRAY, BLACK)
        var clipped = rect.intersect(Rect(0, 0, self.width, self.height))
        for y in range(clipped.a.y, clipped.b.y):
            for x in range(clipped.a.x, clipped.b.x):
                var idx = self._index(x, y)
                var current = self.cells[idx]
                self.cells[idx] = Cell(current.glyph, shadow, current.width)

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

    fn put_wrapped_text(
        mut self, rect: Rect, text: String, attr: Attr,
    ) -> Int:
        """Paint ``text`` inside ``rect``, soft-wrapping at spaces.

        Companion to ``put_text``: same codepoint-aligned layout, but
        the caller hands in a rectangle and the canvas does the line
        wrapping. Words longer than the rect width hard-break.
        Returns the number of rows actually painted (0 when ``rect``
        has no interior, no taller than ``rect.height()``).

        This is the framework's "stay inside your dialog" primitive —
        any popup that has variable-length text content (confirm
        prompts, hover tips, info notices) should pipe it through this
        so the text never bleeds across the workspace.
        """
        var inner = rect.intersect(Rect(0, 0, self.width, self.height))
        if inner.width() <= 0 or inner.height() <= 0:
            return 0
        var lines = wrap_to_width(text, inner.width())
        var rows = len(lines)
        if rows > inner.height():
            rows = inner.height()
        for i in range(rows):
            _ = self.put_text(
                Point(inner.a.x, inner.a.y + i),
                lines[i], attr, inner.b.x,
            )
        return rows


fn paint_drop_shadow(mut canvas: Canvas, rect: Rect):
    """Paint a Turbo Vision–style drop shadow under ``rect``.

    The shadow is two cells wide on the right and one cell tall
    along the bottom, offset so the diagonal "lifted" effect lands
    in the same direction as the per-button shadows
    (``paint_shadow_button``): right strip starts one row below the
    top edge, bottom strip starts two cells right of the left edge.

    This is a *compositing* operation, not an overpaint: the shadow
    cells keep whatever glyph was already underneath the dialog and
    only get their colours swapped to dim-on-black via
    ``Canvas.darken_rect``. Callers therefore must invoke this
    after the workspace and any other widgets the dialog is meant
    to "float above" have been painted, and before drawing the
    dialog body itself (drawing order inside the dialog's own
    rect doesn't matter — the shadow strips never overlap it).
    """
    if rect.is_empty():
        return
    # Right-side strip: 2 cells wide starting one row below the top.
    canvas.darken_rect(Rect(rect.b.x, rect.a.y + 1, rect.b.x + 2, rect.b.y))
    # Bottom strip: 1 row tall, shifted right by 2 so the corner
    # below-and-right of the dialog gets the full 2×1 + 1×2 hook.
    canvas.darken_rect(Rect(rect.a.x + 2, rect.b.y, rect.b.x + 2, rect.b.y + 1))


fn popup_size_for_text(
    text: String, max_w: Int, max_h: Int,
) -> Tuple[Int, Int]:
    """Compute the (width, height) a popup needs to host ``text``.

    The popup hosts a soft-wrapped paragraph: width is capped at
    ``max_w`` so the box never spills past the host view, and height
    grows with however many wrapped lines the text needs (capped at
    ``max_h``). Returned dimensions include the 1-cell border on all
    four sides plus a 1-cell horizontal padding inside the border —
    callers can lay out the box at these dimensions and trust that
    ``paint_drop_shadow`` + ``draw_box`` + ``put_wrapped_text`` inside
    the same rect will land within those bounds.

    Returns ``(0, 0)`` when the available space is too small to host
    any text (``< 5`` cells of width or ``< 3`` cells of height —
    border + one inner row + border).
    """
    if max_w < 5 or max_h < 3:
        return (0, 0)
    var ideal_inner = utf8_codepoint_count(text)
    var inner_w: Int
    if ideal_inner + 4 <= max_w:
        inner_w = ideal_inner
        if inner_w < 1:
            inner_w = 1
    else:
        inner_w = max_w - 4
    var lines = wrap_to_width(text, inner_w)
    var n = len(lines)
    if n < 1:
        n = 1
    var h = n + 2
    if h > max_h:
        h = max_h
    return (inner_w + 4, h)


fn wrap_to_width(text: String, width: Int) -> List[String]:
    """Soft-wrap ``text`` to lines of at most ``width`` codepoint cells.

    Breaks at the last space inside the budget; words longer than
    ``width`` hard-break at exactly ``width`` cells. Hard line breaks
    at ``\\n`` always end the current line, so multi-line input (LSP
    diagnostics, formatted help text) is preserved structurally —
    a ``\\n`` doesn't leak into a wrapped line as a non-printable cell
    that the canvas writer would emit verbatim. ``\\r`` and ``\\t`` are
    folded to spaces so they participate in soft-break placement
    instead of producing stray cells. Empty input returns an empty
    list.

    The framework primitive that lets popups and dialogs honour the
    "don't paint outside your area" rule: a dialog can either size
    itself to fit the wrapped output, or hand the wrapped lines to
    ``Canvas.put_wrapped_text`` to render inside a bounded rect.
    """
    var lines = List[String]()
    if width < 1:
        return lines^
    var bytes = text.as_bytes()
    var n = len(bytes)
    if n == 0:
        return lines^
    # Decode UTF-8 into per-codepoint glyphs so we can measure line
    # width in cells, not bytes (multi-byte sequences would otherwise
    # blow up the budget on the first non-ASCII character). Newlines
    # are kept as their own marker codepoint; other ASCII whitespace
    # (\r, \t) is folded to a regular space so wrap-break logic and
    # the canvas writer both treat it as plain whitespace.
    var cps = List[String]()
    var i = 0
    while i < n:
        var b = Int(bytes[i])
        if b == 0x0A:
            cps.append(String("\n"))
            i += 1
            continue
        if b == 0x0D or b == 0x09:
            cps.append(String(" "))
            i += 1
            continue
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
        cps.append(String(StringSlice(unsafe_from_utf8=bytes[i:i+seq_len])))
        i += seq_len
    var nc = len(cps)
    var pos = 0
    while pos < nc:
        # Collapse leading spaces on every line after the first — a
        # wrap boundary already implies the break, so leaving the
        # space behind would push the next line one cell to the right.
        if pos > 0:
            while pos < nc and cps[pos] == String(" "):
                pos += 1
            if pos >= nc:
                break
        # Walk forward up to ``width`` cells; remember the last space
        # we passed so we can fall back to a soft break. A ``\n``
        # ends the line immediately even when more budget is left.
        var end = pos
        var last_space = -1
        var hard_break = False
        while end < nc and end - pos < width:
            if cps[end] == String("\n"):
                hard_break = True
                break
            if cps[end] == String(" "):
                last_space = end
            end += 1
        if hard_break:
            var line = String("")
            for j in range(pos, end):
                line = line + cps[j]
            lines.append(line)
            pos = end + 1   # skip the \n itself
            continue
        if end >= nc:
            var tail = String("")
            for j in range(pos, nc):
                tail = tail + cps[j]
            lines.append(tail)
            pos = nc
            continue
        var break_at: Int
        if last_space > pos:
            break_at = last_space
        else:
            # No space inside the budget — hard-break at ``width``.
            break_at = pos + width
        var line = String("")
        for j in range(pos, break_at):
            line = line + cps[j]
        lines.append(line)
        if break_at < nc and cps[break_at] == String(" "):
            pos = break_at + 1
        else:
            pos = break_at
    return lines^


fn utf8_byte_to_cell(text: String) -> List[Int]:
    """Map every byte index in ``text`` to the cell column its codepoint
    occupies under ``Canvas.put_text``'s codepoint-aligned layout.

    Length equals ``len(text.as_bytes())`` so callers can index by raw
    byte position (the editor's column model). All bytes belonging to
    one multi-byte UTF-8 sequence map to the same cell. Use
    ``utf8_codepoint_count(text)`` to find the cell *just past* the
    last codepoint — useful when a cursor or selection sits at EOL.
    Tab bytes (``0x09``) expand to ``TAB_WIDTH``-aligned spaces in
    ``put_text``, so they advance the cell counter by however many
    cells are needed to reach the next tab stop. The byte itself maps
    to the *first* of those expanded cells, matching where a click on
    the tab byte would visually land.
    """
    var bytes = text.as_bytes()
    var n = len(bytes)
    var result = List[Int]()
    var cell = 0
    var i = 0
    while i < n:
        var b = Int(bytes[i])
        if b == 0x09:
            result.append(cell)
            cell += TAB_WIDTH - (cell % TAB_WIDTH)
            i += 1
            continue
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
    """Number of cells ``Canvas.put_text(text)`` would produce.

    Counts each codepoint as one cell *except* tabs, which expand to
    however many cells the next ``TAB_WIDTH`` boundary requires.
    Callers ranging from selection clamp logic to cursor placement
    rely on this matching ``put_text`` exactly — keep them in sync.
    """
    var bytes = text.as_bytes()
    var n = len(bytes)
    var count = 0
    var i = 0
    while i < n:
        var b = Int(bytes[i])
        if b == 0x09:
            count += TAB_WIDTH - (count % TAB_WIDTH)
            i += 1
            continue
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
