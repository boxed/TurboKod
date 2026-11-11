"""Canvas: a 2D grid of `Cell` plus drawing primitives.

The Canvas is the only place that mutates pixel state; all widgets paint into
a Canvas, and the Terminal driver flushes a Canvas to the screen. Two canvases
(front and back) let the driver compute a minimal diff each frame — the same
"swap buffers" trick TurboVision's `TDisplayBuffer` uses, but here it's a
simple List-of-Cells rather than a packed 16-bit attribute buffer.
"""

from std.collections import List

from .cell import Cell, FONT_SLOTS, FONT_UI, blank_cell
from .colors import Attr, DARK_GRAY, PANE_BG, default_attr
from .geometry import Point, Rect
from .string_utils import char_width, codepoint_at, utf8_codepoint_size, TAB_WIDTH


# ``TAB_WIDTH`` (the number of cells a tab byte expands to) lives in
# ``string_utils`` so the byte↔cell converters there share the exact same
# value ``put_text`` aligns to. Re-exported here because the rest of the
# tree (Painter's left-clip walker, ``kwarg_conceal``) imports it from
# ``.canvas`` — the layer that owns ``put_text``.


def _control_picture_glyph(b: Int) -> String:
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
    return chr(cp)


comptime SCALE_ONE = 1000
"""An area cell the size of the canvas's own: ``Canvas.area_scale`` in
thousandths."""

comptime MAX_SUB_GRIDS = 63
"""How many sub-grids a frame can carry: ``Cell.sub`` travels in 6 bits."""


def grid_dims(rect: Rect, scale_x: Int, scale_y: Int) -> Tuple[Int, Int]:
    """How many cells ``scale_x`` x ``scale_y`` thousandths of a screen
    cell fit in ``rect``."""
    if scale_x == SCALE_ONE and scale_y == SCALE_ONE:
        return (max(0, rect.width()), max(0, rect.height()))
    var cols = max(0, rect.width()) * SCALE_ONE // max(1, scale_x)
    var rows = max(0, rect.height()) * SCALE_ONE // max(1, scale_y)
    return (cols, rows)


@fieldwise_init
struct SubGrid(Copyable, Movable):
    """A pane's content laid out in cells of another size, shown through
    ``rect`` of the canvas it was placed on (``Canvas.place_sub_grid``).
    The host draws ``cols`` x ``rows`` cells of the area's own size from
    ``rect``'s top-left corner; ``cells`` is row-major like
    ``Canvas.cells``."""

    var slot: UInt8
    var rect: Rect
    var cols: Int
    var rows: Int
    var cells: List[Cell]


comptime HOST_SPLIT = UInt8(1)
"""A ``HostItem`` that is a ``SplitArea``'s divider."""
comptime HOST_SURFACE_MAIN = 0
comptime HOST_SURFACE_PANELS = 1
comptime HOST_SURFACE_SETTINGS = 2
comptime HOST_SURFACE_DIALOG = 3
comptime HOST_SURFACE_GIT = 4
comptime HOST_SURFACES = 5
"""The host's surfaces, each with its frame's ``HostItem``s
(``Desktop.host_items``): the project window, the floating-panels window,
the Settings window, the dialog window and the git window."""

comptime HOST_VSCROLL = UInt8(2)
comptime HOST_HSCROLL = UInt8(3)
"""``HostItem``s that are a ``VScrollbar`` / ``HScrollbar`` (and so every
``ScrollBarArea``): the bar's whole length, arrow cells included."""
comptime HOST_TEST_HEADER = UInt8(4)
comptime HOST_TEST_LIST = UInt8(5)
comptime HOST_TEST_DETAIL = UInt8(6)
"""The test results view's three regions — its progress / status rows, the
test list and the selected test's detail — which the host draws as native
views of its look, filled from ``tk_desktop_test_results``. ``tag`` names
the pane (``TestResultsView.host_tag``)."""


@fieldwise_init
struct HostItem(Copyable, Movable):
    """A piece of framework chrome the host draws over the frame in its own
    look (``Canvas.host_widgets``), instead of the cells. The cells under
    it are left blank and still take the mouse — the host's view only
    draws — so behavior is the core's in every look.

    ``x`` / ``y`` / ``w`` / ``h`` are in thousandths of the canvas's cells
    (a sub-grid's cells needn't be the screen's); ``place_sub_grid``
    converts a sub-grid's items to its parent's."""

    var kind: UInt8
    var x: Int
    var y: Int
    var w: Int
    var h: Int
    var side_by_side: Bool
    """For ``HOST_SPLIT``: the halves are left / right (the divider a
    column), else top / bottom."""
    var active: Bool
    """Being dragged."""
    var knob_a: Int
    var knob_b: Int
    """For a scroll bar: the thumb's span along the bar (``y`` for a
    vertical one, ``x`` for a horizontal one), in the same thousandths as
    ``x`` / ``y`` — exactly where the core hit-tests it."""
    var attr: Attr
    """The colors the core would have drawn it in: the host picks a
    contrasting ink from the background."""
    var tag: Int
    """Which instance an item belongs to, where the host needs to ask the
    core about it (the test results views); 0 otherwise."""


@fieldwise_init
struct Canvas(Copyable, Movable):
    var width: Int
    var height: Int
    var cells: List[Cell]  # row-major, length == width * height
    var font: UInt8
    """Font slot stamped on every cell written (``FONT_*`` in ``cell``);
    a view switches it around the content it paints in another slot and
    restores it after."""
    var area_scale: List[Int]
    """Each font slot's cell size in thousandths of this canvas's cell:
    ``[w0, h0, w1, h1, …]``, indexed by slot. ``SCALE_ONE`` everywhere
    unless the host gave an area a font size of its own (the native app;
    the terminal frontends never do)."""
    var sub_grids: List[SubGrid]
    """Content laid out at another cell size, for the host to draw over
    this canvas (``place_sub_grid``)."""
    var origin: Point
    """The coordinates of the top-left cell: (0, 0) for a frame. A
    sub-grid's canvas (``GridFrame.begin``) starts at its rect's corner,
    so a view paints it in the coordinates it would paint the screen in."""
    var host_widgets: Bool
    """The host draws framework chrome (``HostItem``) in its own look —
    the macOS-style and Mac OS 9 looks. A view whose chrome supports it
    adds an item instead of painting glyphs. A canvas painted to be placed
    in this one (a sub-grid) takes the flag from it."""
    var host_items: List[HostItem]
    """This frame's host-drawn chrome, for the host to fetch."""
    var scroll_bar_cells: Int
    """How many cells thick a framework scroll bar is: 2 in the Mac OS 9
    look (a Platinum bar is 16 points, two of its 8-point cells), 1
    everywhere else. Views that keep content out of the bar's way reserve
    this many columns."""

    def __init__(out self, width: Int, height: Int):
        self.width = width
        self.height = height
        self.font = FONT_UI
        self.cells = List[Cell]()
        var n = width * height
        for _ in range(n):
            self.cells.append(blank_cell())
        self.area_scale = List[Int]()
        for _ in range(2 * FONT_SLOTS):
            self.area_scale.append(SCALE_ONE)
        self.sub_grids = List[SubGrid]()
        self.origin = Point(0, 0)
        self.host_widgets = False
        self.host_items = List[HostItem]()
        self.scroll_bar_cells = 1

    def inherit_chrome(mut self, parent: Canvas):
        """Take ``parent``'s framework-chrome settings, for a canvas painted
        to be placed in it (a sub-grid)."""
        self.host_widgets = parent.host_widgets
        self.scroll_bar_cells = parent.scroll_bar_cells

    def add_host_item(mut self, var item: HostItem):
        self.host_items.append(item^)

    def scale_of(self, slot: UInt8) -> Tuple[Int, Int]:
        """Area ``slot``'s cell size, in thousandths of this canvas's."""
        var i = 2 * Int(slot)
        if i < 0 or i + 1 >= len(self.area_scale):
            return (SCALE_ONE, SCALE_ONE)
        return (self.area_scale[i], self.area_scale[i + 1])

    def sub_grid_size(self, slot: UInt8, rect: Rect) -> Tuple[Int, Int]:
        """How many of area ``slot``'s cells fit in ``rect``: its own
        size, unless the area has a cell size of its own."""
        var sc = self.scale_of(slot)
        return grid_dims(rect, sc[0], sc[1])

    def place_sub_grid(mut self, slot: UInt8, rect: Rect, var grid: Canvas):
        """Show ``grid`` (painted at ``sub_grid_size(slot, rect)``) in
        ``rect``. At this canvas's own cell size it's copied in, so a
        frontend without area sizes never sees a sub-grid. Otherwise it's
        kept for the host, and ``rect``'s cells are marked as showing it
        until something paints over them."""
        var sc = self.scale_of(slot)
        # The grid's host chrome, from its cells into this canvas's.
        for i in range(len(grid.host_items)):
            var it = grid.host_items[i].copy()
            it.x = rect.a.x * SCALE_ONE + it.x * sc[0] // SCALE_ONE
            it.y = rect.a.y * SCALE_ONE + it.y * sc[1] // SCALE_ONE
            it.w = it.w * sc[0] // SCALE_ONE
            it.h = it.h * sc[1] // SCALE_ONE
            if it.kind == HOST_HSCROLL:
                it.knob_a = rect.a.x * SCALE_ONE + it.knob_a * sc[0] // SCALE_ONE
                it.knob_b = rect.a.x * SCALE_ONE + it.knob_b * sc[0] // SCALE_ONE
            else:
                it.knob_a = rect.a.y * SCALE_ONE + it.knob_a * sc[1] // SCALE_ONE
                it.knob_b = rect.a.y * SCALE_ONE + it.knob_b * sc[1] // SCALE_ONE
            self.host_items.append(it^)
        if (sc[0] == SCALE_ONE and sc[1] == SCALE_ONE) \
                or len(self.sub_grids) >= MAX_SUB_GRIDS:
            var clip = rect.intersect(self.bounds())
            for y in range(clip.a.y, clip.b.y):
                var gy = y - rect.a.y
                if gy >= grid.height:
                    break
                for x in range(clip.a.x, clip.b.x):
                    var gx = x - rect.a.x
                    if gx >= grid.width:
                        break
                    self.cells[self._index(x, y)] = grid.cells[gy * grid.width + gx]
            return
        var cells = List[Cell]()
        swap(cells, grid.cells)
        self.sub_grids.append(SubGrid(
            slot, rect, grid.width, grid.height, cells^,
        ))
        var tag = UInt8(len(self.sub_grids))
        var clip = rect.intersect(self.bounds())
        for y in range(clip.a.y, clip.b.y):
            for x in range(clip.a.x, clip.b.x):
                self.cells[self._index(x, y)].sub = tag

    def resize(mut self, width: Int, height: Int):
        self.width = width
        self.height = height
        self.cells = List[Cell]()
        var n = width * height
        for _ in range(n):
            self.cells.append(blank_cell())
        self.sub_grids = List[SubGrid]()
        self.host_items = List[HostItem]()

    def _index(self, x: Int, y: Int) -> Int:
        return (y - self.origin.y) * self.width + (x - self.origin.x)

    def bounds(self) -> Rect:
        """The cells this canvas holds, in its own coordinates."""
        return Rect(
            self.origin.x, self.origin.y,
            self.origin.x + self.width, self.origin.y + self.height,
        )

    def in_bounds(self, x: Int, y: Int) -> Bool:
        return self.origin.x <= x and x < self.origin.x + self.width \
            and self.origin.y <= y and y < self.origin.y + self.height

    def get(self, x: Int, y: Int) -> Cell:
        if not self.in_bounds(x, y):
            return blank_cell()
        return self.cells[self._index(x, y)]

    def set(mut self, x: Int, y: Int, var cell: Cell):
        if self.in_bounds(x, y):
            cell.font = self.font
            cell.sub = 0
            self.cells[self._index(x, y)] = cell^

    def clear(mut self, attr: Attr = default_attr()):
        var blank = Cell(String(" "), attr, 1, self.font)
        for i in range(len(self.cells)):
            self.cells[i] = blank
        self.sub_grids = List[SubGrid]()

    def fill(mut self, rect: Rect, glyph: String, attr: Attr):
        var cell = Cell(glyph, attr)
        cell.font = self.font
        var w = cell.width
        if w < 1:
            w = 1
        var clipped = rect.intersect(self.bounds())
        for y in range(clipped.a.y, clipped.b.y):
            var x = clipped.a.x
            while x < clipped.b.x:
                if w == 2 and x + 1 >= clipped.b.x:
                    break  # wide glyph won't fit before the right edge
                self.cells[self._index(x, y)] = cell
                if w == 2:
                    # Empty continuation cell over the glyph's right half, so
                    # a leftover normal cell can't render a spurious glyph
                    # (mirrors put_text).
                    self.cells[self._index(x + 1, y)] = Cell(
                        String(""), attr, 0, self.font,
                    )
                x += w

    def put_text(mut self, p: Point, text: String, attr: Attr, max_x: Int = -1,
                 tab_base: Int = 0) -> Int:
        """Paint ``text`` starting at ``p`` (no wrapping). Returns columns advanced.

        If ``max_x`` is non-negative, painting stops at column ``max_x``
        (exclusive) — letting callers like ``Window`` clip text to their
        own bounds without building a truncated string.

        ``tab_base`` is the screen column that tab stops are measured from:
        a tab advances to the next ``TAB_WIDTH`` boundary *relative to*
        ``tab_base``. It defaults to 0 (physical screen column), but text
        that doesn't start at the screen's left edge — editor content sits
        right of the line-number gutter — must pass the column where the
        text begins, or a leading tab expands by however many cells happen
        to remain to the next absolute stop (e.g. 2 instead of 4) while the
        cursor's column model (``utf8_byte_to_cell``, which counts from the
        line start) says 4. ``Painter.put_text`` passes the paint origin so
        every editor / tool-pane paint is tab-aligned to its own left edge.

        Codepoint-aligned: each codepoint occupies one cell carrying the
        full UTF-8 byte sequence as its glyph string. Callers that hold
        byte indices (the editor's overlay paths) need
        ``utf8_byte_to_cell`` to translate. Wide codepoints — emoji, CJK
        (``char_width`` == 2) — occupy two cells: the glyph cell carries
        ``width=2`` and is followed by an empty ``width=0`` continuation
        cell so the frontends know to skip the right half. A wide glyph
        that would straddle the right limit isn't painted (we stop) rather
        than spilling a half-glyph past the edge.
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
        if y < self.origin.y or y >= self.origin.y + self.height:
            return 0
        var left = self.origin.x
        var limit = left + self.width
        if max_x >= 0 and max_x < limit:
            limit = max_x
        var bytes = text.as_bytes()
        var n = len(bytes)
        var i = 0
        while i < n and x < limit:
            var b = Int(bytes[i])
            if b == 0x09:    # TAB → fill spaces to next tab stop
                var stop = x + TAB_WIDTH - ((x - tab_base) % TAB_WIDTH)
                if stop > limit: stop = limit
                while x < stop:
                    if x >= left:
                        self.cells[self._index(x, y)] = Cell(
                            String(" "), attr, 1, self.font,
                        )
                    x += 1
                    advanced += 1
                i += 1
                continue
            var glyph: String
            var seq_len = utf8_codepoint_size(b)
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
            elif seq_len > 1 and i + seq_len <= n:
                glyph = String(StringSpan(unsafe_from_utf8=bytes[i:i+seq_len]))
            else:
                # Stray continuation or truncated tail — show ``?``
                # rather than losing the column to silence.
                glyph = String("?")
                seq_len = 1
            var w = char_width(codepoint_at(text, i)[0])
            if w == 2:
                # A wide glyph needs two cells. If the second would fall
                # past the limit, stop instead of painting a half glyph
                # that the frontend can't complete.
                if x + 2 > limit:
                    break
                # Only write the continuation cell when the glyph's lead
                # cell was written. If the lead is clipped off the left edge
                # (``x < 0``, reachable via negative-x overlay/scroll paths),
                # writing just the empty continuation at column 0 would leave
                # an orphaned blank where the glyph's right half belongs —
                # skip the whole glyph instead.
                if x >= left:
                    self.cells[self._index(x, y)] = Cell(glyph, attr, 2, self.font)
                    self.cells[self._index(x + 1, y)] = Cell(
                        String(""), attr, 0, self.font,
                    )
                x += 2
                advanced += 2
            else:
                if x >= left:
                    self.cells[self._index(x, y)] = Cell(glyph, attr, 1, self.font)
                x += 1
                advanced += 1
            i += seq_len
        return advanced

    def set_attr(mut self, x: Int, y: Int, attr: Attr):
        """Change the attribute at ``(x, y)`` without touching the glyph.

        Lets overlay passes (highlight, selection, cursor) recolor cells
        without re-deriving glyphs from byte arrays — which would
        otherwise force every overlay path to repeat the UTF-8 decoding
        ``put_text`` already did.
        """
        if not self.in_bounds(x, y):
            return
        var idx = self._index(x, y)
        var current = self.cells[idx]
        self.cells[idx] = Cell(current.glyph, attr, current.width, current.font)

    def darken_rect(mut self, rect: Rect):
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
        var shadow = Attr(DARK_GRAY, PANE_BG)
        var clipped = rect.intersect(self.bounds())
        for y in range(clipped.a.y, clipped.b.y):
            for x in range(clipped.a.x, clipped.b.x):
                var idx = self._index(x, y)
                var current = self.cells[idx]
                self.cells[idx] = Cell(current.glyph, shadow, current.width, current.font)

    def draw_box(mut self, rect: Rect, attr: Attr, double_line: Bool = False):
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



    def put_wrapped_text(
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
        var inner = rect.intersect(self.bounds())
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


def paint_drop_shadow(mut canvas: Canvas, rect: Rect):
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


def popup_size_for_text(
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


def wrap_to_width(text: String, width: Int) -> List[String]:
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
        var seq_len = utf8_codepoint_size(b)
        if i + seq_len > n:
            seq_len = n - i
        cps.append(String(StringSpan(unsafe_from_utf8=bytes[i:i+seq_len])))
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
        # Emoji count two cells, so track the running cell total rather
        # than the codepoint count — a glyph wider than the remaining
        # budget ends the segment (but a single over-wide glyph on an
        # empty segment is still placed so we always make progress).
        var end = pos
        var cells_used = 0
        var last_space = -1
        var hard_break = False
        while end < nc:
            if cps[end] == String("\n"):
                hard_break = True
                break
            var cw = char_width(codepoint_at(cps[end], 0)[0])
            if cells_used + cw > width and end > pos:
                break
            if cps[end] == String(" "):
                last_space = end
            cells_used += cw
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
            # No space inside the budget — hard-break at the cell budget
            # boundary (``end``, the first glyph that didn't fit).
            break_at = end
        var line = String("")
        for j in range(pos, break_at):
            line = line + cps[j]
        lines.append(line)
        if break_at < nc and cps[break_at] == String(" "):
            pos = break_at + 1
        else:
            pos = break_at
    return lines^


struct RunCells(Copyable, Movable):
    """Byte→cell map for one *painted run* of text — the bytes a pane
    actually put on screen, starting at column ``origin``.

    A pane that paints a line and then overlays attributes on byte
    ranges of it (syntax colors, the match highlight, a drag selection)
    needs to turn a byte offset into a screen column. Doing that as
    ``origin + (b - byte_start)`` assumes one byte is one cell, which
    holds only for ASCII: an ``ö`` is two bytes and one cell, so every
    such pane painted it as two cells — ``??`` — and mapped every
    following byte one column too far right.

    Build it from the visible substring (not the whole line) so tab
    stops are measured from the run's own left edge, matching what
    ``Painter.put_text`` does with ``tab_base``."""
    var cells: List[Int]      # relative byte -> relative cell
    var total: Int            # cell just past the last codepoint
    var origin: Int           # screen column the run was painted at
    var byte_start: Int       # absolute byte the run starts at

    def __init__(out self, run: String, origin: Int, byte_start: Int):
        self.cells = utf8_byte_to_cell(run)
        self.total = utf8_codepoint_count(run)
        self.origin = origin
        self.byte_start = byte_start

    def cell_of(self, abs_byte: Int) -> Int:
        """Cell column, relative to the run's start, of ``abs_byte``.
        Clamped to the run: before it is 0, at or past its end is
        ``total`` (the column just past the last glyph). All bytes of one
        codepoint share a cell, so a byte in the middle of a sequence
        resolves to that codepoint's column."""
        var r = abs_byte - self.byte_start
        if r <= 0:
            return 0
        if r >= len(self.cells):
            return self.total
        return self.cells[r]

    def col_of(self, abs_byte: Int) -> Int:
        """Screen column of ``abs_byte``."""
        return self.origin + self.cell_of(abs_byte)

    def byte_at_cell(self, cell: Int) -> Int:
        """Absolute byte offset of the first codepoint at or past
        relative column ``cell`` — the inverse of ``cell_of``, used to
        slide a run left to a target column and to resolve a click.
        Returns the run's end byte when ``cell`` is past the last
        glyph."""
        if cell <= 0:
            return self.byte_start
        for r in range(len(self.cells)):
            if self.cells[r] >= cell:
                return self.byte_start + r
        return self.byte_start + len(self.cells)


def utf8_byte_to_cell(text: String) -> List[Int]:
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
        if b < 0x80:  # ASCII is one cell: skip decoding (long lines)
            result.append(cell)
            cell += 1
            i += 1
            continue
        var seq_len = utf8_codepoint_size(b)
        if i + seq_len > n:
            seq_len = n - i
        for _ in range(seq_len):
            result.append(cell)
        cell += char_width(codepoint_at(text, i)[0])
        i += seq_len
    return result^


def utf8_codepoint_count(text: String) -> Int:
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
        if b < 0x80:  # ASCII is one cell: skip decoding (long lines)
            count += 1
            i += 1
            continue
        var seq_len = utf8_codepoint_size(b)
        if i + seq_len > n:
            seq_len = n - i
        count += char_width(codepoint_at(text, i)[0])
        i += seq_len
    return count
