"""Selection, soft-wrap, and a reusable read-only text-log view.

The Editor builds its own paint/event loop on top of ``Selection`` +
``wrap_lines`` because it has many concerns (gutters, syntax, undo,
…). Read-only views are uniform enough to share the *whole* surface
— that's what ``TextLog`` packages: an appended ``List[String]``, a
selection model with mouse-drag, soft-wrap layout caching, scroll +
autoscroll, paint, and copy. The DebugPane composes a ``TextLog`` for
its Output panel and only adds domain-specific overlays (Python
traceback links) on top.

Exported types:

* ``Selection`` — anchor + cursor in **byte coordinates** within their
  logical line. Byte coords (not codepoints) match the editor's column
  model: every multi-byte codepoint stays at a fixed boundary, and
  ``extracted_text`` can byte-slice without re-walking UTF-8.
* ``VisualLine`` — one painted screen row of the soft-wrap layout, with
  parallel byte and codepoint offsets so callers can map screen
  position ↔ byte column without re-decoding the line.
* ``wrap_lines`` — the single soft-wrap primitive. Editor passes
  ``indent_size = effective_indent_size`` and ``word_aware = True``;
  read-only consumers default to indent 0 / hard-break.
* ``TextLog`` — the composed view. Owns appended text + selection +
  scroll + paint + mouse drag + copy. Caller layers its own overlays
  by reading ``last_visible_rows()`` after ``paint`` returns.
"""

from std.collections.list import List

from .canvas import Canvas
from .painter import Painter
from .cell import Cell
from .clipboard import clipboard_copy
from .colors import Attr, BLACK, CYAN, ColorRun, parse_sgr
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_DOWN, KEY_END, KEY_HOME, KEY_PAGEDOWN, KEY_PAGEUP, KEY_UP,
    MOUSE_BUTTON_LEFT, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .geometry import Point, Rect
from .string_utils import (
    byte_slice, char_width, codepoint_at, is_word_codepoint,
    leading_indent_bytes, utf8_codepoint_size,
)


@fieldwise_init
struct VisualLine(ImplicitlyCopyable, Movable):
    """One painted row of a soft-wrapped text view.

    ``byte_start`` / ``byte_end`` are the half-open range inside
    ``lines[line_idx]`` to slice for this row. ``cell_start`` /
    ``cell_count`` are the codepoint offsets the segment occupies on
    screen (after the optional ``indent_cells`` lead-in for
    continuation rows).

    A logical line that fits within the content width produces exactly
    one ``VisualLine`` with ``indent_cells = 0``. Wrapped lines emit one
    row per segment; every continuation has ``indent_cells`` equal to
    the line's leading whitespace plus one indent step (so wrapped
    code stays visually aligned under its parent's indent).
    """
    var line_idx: Int      # index into the source ``List[String]``
    var byte_start: Int    # inclusive byte offset within the line
    var byte_end: Int      # exclusive
    var cell_start: Int    # codepoint offset of this segment
    var cell_count: Int    # codepoints painted on this row
    var indent_cells: Int  # hanging-indent cells before the text starts


def _string_spans(line: String) -> List[Tuple[Int, Int]]:
    """Byte ranges ``[start, end)`` of *closed* quoted string literals in
    ``line`` (``'`` / ``"`` / `` ` `` delimiters, backslash escapes the next
    byte). Used by the word-aware wrap to treat a quoted string as a single
    token — so ``'foo'`` is never broken into ``'`` + ``foo'``.

    Only quotes that find a matching closer become spans; an unterminated
    quote (e.g. the apostrophe in ``don't``) is left alone so prose still
    wraps normally.
    """
    var bytes = line.as_bytes()
    var n = len(bytes)
    var spans = List[Tuple[Int, Int]]()
    var i = 0
    while i < n:
        var ch = Int(bytes[i])
        if ch == 0x27 or ch == 0x22 or ch == 0x60:  # ' " `
            var j = i + 1
            var closed = False
            while j < n:
                var cj = Int(bytes[j])
                if cj == 0x5C:  # backslash escapes the next byte
                    j += 2
                    continue
                if cj == ch:
                    closed = True
                    j += 1
                    break
                j += 1
            if closed:
                spans.append((i, j))
                i = j
                continue
        i += 1
    return spans^


def _splits_string(spans: List[Tuple[Int, Int]], p: Int) -> Bool:
    """True when a break at byte ``p`` (left ends before ``p``) would land
    *strictly inside* one of ``spans`` — i.e. ``s < p < t``. Breaking right
    before the opening quote (``p == s``) or after the closer (``p == t``)
    keeps the literal whole and is allowed."""
    for span in spans:
        if span[0] < p and p < span[1]:
            return True
    return False


def _slice_runs(runs: List[ColorRun], lo: Int, hi: Int) -> List[ColorRun]:
    """Return the ``runs`` overlapping the half-open byte window ``[lo, hi)``,
    clamped to the window and rebased so offsets are relative to ``lo``. Used
    to split a whole-chunk run list into per-line run lists when ``append``
    breaks the chunk on newlines."""
    var out = List[ColorRun]()
    for r in runs:
        var s = r.start
        var e = r.end
        if e <= lo or s >= hi:
            continue
        if s < lo:
            s = lo
        if e > hi:
            e = hi
        out.append(ColorRun(s - lo, e - lo, r.attr))
    return out^


def _wrap_one_line_into(
    mut out: List[VisualLine],
    line_idx: Int,
    line: String,
    seg_lo: Int,
    seg_hi: Int,
    content_w: Int,
    first_indent: Int,
    cont_indent: Int,
    cell_offset_base: Int,
    word_aware: Bool,
    max_rows: Int,
) -> Int:
    """Word-aware wrap of the byte range ``[seg_lo, seg_hi)`` of ``line``,
    appending one ``VisualLine`` per painted row to ``out``. Returns the
    next ``cell_start`` so callers can chain sub-ranges of the same line.

    The first emitted row uses ``first_indent`` hanging-indent cells, each
    continuation uses ``cont_indent``. Both ``wrap_lines`` (whole line,
    ``first_indent = 0``) and ``smart_wrap_lines`` (per delimiter-bounded
    item) share this so the delicate codepoint-walk / word-break / cell
    accounting lives in exactly one place. An empty range emits a single
    zero-width row so it still occupies a screen line. Multibyte glyphs are
    never split. ``max_rows`` (when ``>= 0``) caps total rows in ``out``.
    """
    var bytes = line.as_bytes()
    var lo = seg_lo
    if lo < 0:
        lo = 0
    var hi = seg_hi
    if hi > len(bytes):
        hi = len(bytes)
    var cell_offset = cell_offset_base
    if hi <= lo:
        out.append(VisualLine(line_idx, lo, lo, cell_offset, 0, first_indent))
        return cell_offset
    # Quoted-string spans so the word-aware break never splits a literal
    # (``'foo'`` stays whole instead of breaking into ``'`` + ``foo'``).
    var spans = _string_spans(line) if word_aware else List[Tuple[Int, Int]]()
    var c = lo
    var first = True
    while c < hi:
        if max_rows >= 0 and len(out) >= max_rows:
            break
        var indent_cells = first_indent if first else cont_indent
        var seg_w = content_w - indent_cells
        if seg_w < 1:
            seg_w = 1
        # Hard upper bound: at most ``seg_w`` cells from ``c``, walking
        # codepoints so a multi-byte glyph is never split. Emoji take two
        # cells; a glyph that would overflow ends the segment (but a
        # single over-wide glyph on an empty segment is still taken so we
        # make progress on a 1-cell-wide pane).
        var cells = 0
        var e_hard = c
        while e_hard < hi:
            var info = codepoint_at(line, e_hard)
            var cw = char_width(info[0])
            if cells + cw > seg_w and e_hard > c:
                break
            e_hard += info[1]
            cells += cw
            if cells >= seg_w:
                break
        if e_hard > hi:
            e_hard = hi
        var e = e_hard
        # Word-aware wrap: walk back to the last non-word ASCII boundary
        # inside ``[c, e_hard)``. Skipped when the caller hard-breaks.
        if word_aware and e_hard < hi:
            var p = e_hard
            while p > c + 1:
                var pb = Int(bytes[p - 1])
                if (
                    pb < 0x80
                    and not is_word_codepoint(pb)
                    and not _splits_string(spans, p)
                ):
                    e = p
                    break
                p -= 1
        # Codepoint count for this segment — needed for ``cell_count`` in
        # word-aware mode where we walked back past the cells we counted.
        var seg_cells: Int
        if e == e_hard:
            seg_cells = cells
        else:
            seg_cells = 0
            var k = c
            while k < e:
                var info = codepoint_at(line, k)
                seg_cells += char_width(info[0])
                k += info[1]
        out.append(VisualLine(
            line_idx, c, e, cell_offset, seg_cells, indent_cells,
        ))
        cell_offset += seg_cells
        c = e
        first = False
    return cell_offset


def wrap_lines(
    lines: List[String],
    content_w: Int,
    indent_size: Int = 0,
    word_aware: Bool = False,
    start_line: Int = 0,
    max_rows: Int = -1,
) -> List[VisualLine]:
    """Soft-wrap a slice of ``lines`` to ``content_w`` cells per row.

    Parameters that turn the simple variant into the editor variant:

    * ``indent_size`` — when > 0, every continuation row of a wrapped
      line is indented by ``leading_whitespace_cells + indent_size``
      cells. Capped to ``content_w - 1`` so there's always at least one
      cell of text room.
    * ``word_aware`` — when True, a wrap point that lands mid-word
      walks back to the last ASCII non-word byte inside the segment.
      Only ASCII non-word bytes count (multi-byte bytes would land
      mid-codepoint); a single very long unbroken word falls through
      to the hard break.
    * ``start_line`` / ``max_rows`` — crop the output to lines starting
      at ``start_line`` and at most ``max_rows`` rows total. The DebugPane
      passes ``-1`` for "every visual row" (it doesn't crop until paint
      time); the Editor passes ``content_h`` for "exactly the painted
      window" so soft-wrap doesn't allocate rows it won't draw.

    Empty lines still produce one zero-width visual row so they occupy
    a screen line. Multibyte glyphs are never split.
    """
    var out = List[VisualLine]()
    if content_w < 1:
        return out^
    var br = start_line
    if br < 0:
        br = 0
    var n_lines = len(lines)
    while br < n_lines:
        if max_rows >= 0 and len(out) >= max_rows:
            break
        var line = lines[br]
        var line_n = len(line.as_bytes())
        if line_n == 0:
            out.append(VisualLine(br, 0, 0, 0, 0, 0))
            br += 1
            continue
        var cont_indent = 0
        if indent_size > 0:
            cont_indent = leading_indent_bytes(line) + indent_size
            if cont_indent > content_w - 1:
                cont_indent = content_w - 1
            if cont_indent < 0:
                cont_indent = 0
        _ = _wrap_one_line_into(
            out, br, line, 0, line_n, content_w,
            0, cont_indent, 0, word_aware, max_rows,
        )
        br += 1
    return out^


def smart_wrap_lines(
    lines: List[String],
    content_w: Int,
    indent_size: Int,
    line_comment: String = String(""),
    start_line: Int = 0,
    max_rows: Int = -1,
    comma_threshold: Int = -1,
) -> List[VisualLine]:
    """Smart-wrap a slice of ``lines``: a logical line that overflows
    ``content_w`` *and* has bracketed, comma-separated call structure is
    rendered one-item-per-line, e.g.::

        main_image = models.ImageField(
            upload_to='page/images/',
            default='x.png',
            null=True,
            blank=True)

    The break is **visual only** — the buffer keeps the single physical
    line. A line that already fits emits one ``VisualLine`` (no break,
    even with structure). A line with no breakable structure — no
    top-level bracket, no depth-1 comma, or still inside a string at
    end-of-line — falls back to word-aware soft wrap (``_wrap_one_line_into``
    with the same hanging-indent rule as ``wrap_lines``).

    ``line_comment`` (e.g. ``"#"`` / ``"//"`` from
    ``line_comment_for_extension``) stops the structural scan at a trailing
    comment so brackets/commas inside it aren't mistaken for structure.

    ``comma_threshold`` adds a second break trigger independent of width: a
    line with *more than* ``comma_threshold`` top-level (depth-1) commas in
    its outermost bracket group is broken one-item-per-line even when it
    fits ``content_w``. ``-1`` (the default) disables this — only width
    triggers a break, the original behavior. ``0`` breaks any bracketed call
    that has a comma; ``2`` breaks calls with 3+ arguments; and so on.

    Byte coverage invariant (required by the editor's caret/selection
    code): a line's segments are byte-contiguous and cover it whole. We
    enforce it by emitting ``[cuts[i], cuts[i+1])`` from a sorted cut list
    ``[0, head_open+1, item_starts…, n]`` — the whitespace after a comma
    rides the *end* of the previous segment so item lines render flush
    with no leading space and no dropped bytes.
    """
    var out = List[VisualLine]()
    if content_w < 1:
        return out^
    var br = start_line
    if br < 0:
        br = 0
    var n_lines = len(lines)
    var lc_bytes = line_comment.as_bytes()
    var lc_n = len(lc_bytes)
    while br < n_lines:
        if max_rows >= 0 and len(out) >= max_rows:
            break
        var line = lines[br]
        var bytes = line.as_bytes()
        var line_n = len(bytes)
        if line_n == 0:
            out.append(VisualLine(br, 0, 0, 0, 0, 0))
            br += 1
            continue
        # Display width in cells: emoji count two, everything else one
        # (no East-Asian fullwidth modeling).
        var cols = 0
        var kk = 0
        while kk < line_n:
            var info = codepoint_at(line, kk)
            cols += char_width(info[0])
            kk += info[1]
        var overflow = cols > content_w
        # Fast path: line fits and the comma trigger is off — emit one row
        # without scanning. When the trigger is on (>= 0) we must scan even a
        # fitting line to count its commas.
        if not overflow and comma_threshold < 0:
            out.append(VisualLine(br, 0, line_n, 0, cols, 0))
            br += 1
            continue
        # Scan once for the outermost bracket group's structure.
        var head_open = -1
        var close_idx = -1
        var item_starts = List[Int]()
        var comma_count = 0
        var depth = 0
        var in_str = False
        var quote = 0
        var i = 0
        while i < line_n:
            var b = Int(bytes[i])
            if in_str:
                if b == 0x5C:  # backslash escape — skip the next byte
                    i += 2
                    continue
                if b == quote:
                    in_str = False
                i += 1
                continue
            # Line comment outside strings stops structural scanning.
            if lc_n > 0 and i + lc_n <= line_n:
                var matched = True
                var m = 0
                while m < lc_n:
                    if Int(bytes[i + m]) != Int(lc_bytes[m]):
                        matched = False
                        break
                    m += 1
                if matched:
                    break
            if b == 0x22 or b == 0x27:  # " or '
                in_str = True
                quote = b
                i += 1
                continue
            if b == 0x28 or b == 0x5B or b == 0x7B:  # ( [ {
                if depth == 0 and head_open < 0:
                    head_open = i
                depth += 1
            elif b == 0x29 or b == 0x5D or b == 0x7D:  # ) ] }
                depth -= 1
                if depth == 0 and head_open >= 0 and close_idx < 0:
                    close_idx = i
            elif b == 0x2C and depth == 1 and head_open >= 0:  # ,
                comma_count += 1
                # Item boundary = first non-whitespace byte after the comma.
                var j = i + 1
                while j < line_n and (
                    Int(bytes[j]) == 0x20 or Int(bytes[j]) == 0x09
                ):
                    j += 1
                if j < line_n:
                    item_starts.append(j)
            i += 1
        # Drop item boundaries at/after the close (e.g. a trailing comma
        # ``foo(a, b,)``) so we don't open an empty item line.
        if close_idx >= 0:
            var filtered = List[Int]()
            for z in range(len(item_starts)):
                if item_starts[z] < close_idx:
                    filtered.append(item_starts[z])
            item_starts = filtered^
        var item_indent = leading_indent_bytes(line) + indent_size
        if item_indent > content_w - 1:
            item_indent = content_w - 1
        if item_indent < 0:
            item_indent = 0
        var breakable = (
            head_open >= 0 and len(item_starts) >= 1 and not in_str
        )
        # A fitting line only breaks when the comma trigger fires; an
        # overflowing line always wants to break (the original behavior).
        var comma_trigger = (
            comma_threshold >= 0 and comma_count > comma_threshold
        )
        if not breakable or not (overflow or comma_trigger):
            if overflow:
                # No usable structure — degrade to word-aware soft wrap.
                _ = _wrap_one_line_into(
                    out, br, line, 0, line_n, content_w,
                    0, item_indent, 0, True, max_rows,
                )
            else:
                # Fits and isn't being force-broken — emit one row as-is.
                out.append(VisualLine(br, 0, line_n, 0, cols, 0))
            br += 1
            continue
        # Cut list: head ends after the opener; each item begins at its
        # first non-ws byte; the final segment runs to end-of-line so the
        # close bracket + any trailing tail ride the last item's row.
        var cuts = List[Int]()
        cuts.append(0)
        cuts.append(head_open + 1)
        for z in range(len(item_starts)):
            cuts.append(item_starts[z])
        cuts.append(line_n)
        var cell_offset = 0
        var seg = 0
        while seg + 1 < len(cuts):
            if max_rows >= 0 and len(out) >= max_rows:
                break
            var lo = cuts[seg]
            var hi = cuts[seg + 1]
            if hi <= lo:
                seg += 1
                continue
            # Head's first row sits at the original column (indent 0);
            # everything else (and any continuation of an over-wide item
            # or head) hangs at ``item_indent``.
            var first_ind = 0 if seg == 0 else item_indent
            cell_offset = _wrap_one_line_into(
                out, br, line, lo, hi, content_w,
                first_ind, item_indent, cell_offset, True, max_rows,
            )
            seg += 1
        br += 1
    return out^


@fieldwise_init
struct Selection(ImplicitlyCopyable, Movable):
    """Anchor + cursor selection in (line, byte_col) coordinates.

    Used by both the Editor (where anchor/cursor track the caret
    directly) and read-only views like the DebugPane output panel
    (where ``dragging`` flips on left-press and motion extends the
    cursor). Endpoints can be in either order; ``normalized()``
    returns them sorted in document order.

    Coordinates are byte offsets matching the Editor's column model.
    A read-only view whose hit-test produces *cell* offsets converts
    via the ``VisualLine`` it landed on (``byte_start +
    bytes_for_cells_before(seg, n)``) before storing into a
    ``Selection``.
    """
    var active: Bool
    var dragging: Bool
    var anchor_line: Int
    var anchor_col: Int
    var cursor_line: Int
    var cursor_col: Int

    @staticmethod
    def empty() -> Self:
        return Selection(False, False, 0, 0, 0, 0)

    def is_empty(self) -> Bool:
        """True iff there is no selection to copy. Endpoints meeting at
        the same byte counts as empty (no glyphs in between)."""
        if not self.active:
            return True
        return self.anchor_line == self.cursor_line \
            and self.anchor_col == self.cursor_col

    def normalized(self) -> Tuple[Int, Int, Int, Int]:
        """``(s_line, s_col, e_line, e_col)`` sorted in document order."""
        if self.anchor_line < self.cursor_line \
                or (self.anchor_line == self.cursor_line
                    and self.anchor_col <= self.cursor_col):
            return (
                self.anchor_line, self.anchor_col,
                self.cursor_line, self.cursor_col,
            )
        return (
            self.cursor_line, self.cursor_col,
            self.anchor_line, self.anchor_col,
        )

    def extracted_text(self, lines: List[String]) -> String:
        """Substring of ``lines`` covered by this selection, joining
        logical-line boundaries with ``\\n``. Byte-slices, so the
        ``col`` offsets must be byte offsets into ``lines[i]``.
        Returns empty when the selection is empty or out of range."""
        if self.is_empty():
            return String("")
        var r = self.normalized()
        var s_line = r[0]; var s_col = r[1]
        var e_line = r[2]; var e_col = r[3]
        if s_line == e_line:
            return byte_slice(lines[s_line], s_col, e_col)
        var first_line = lines[s_line]
        var first_n = len(first_line.as_bytes())
        var out = byte_slice(first_line, s_col, first_n)
        for li in range(s_line + 1, e_line):
            if li < 0 or li >= len(lines):
                continue
            out = out + String("\n") + lines[li]
        if 0 <= e_line and e_line < len(lines):
            out = out + String("\n") + byte_slice(lines[e_line], 0, e_col)
        return out^


# --- paint helpers (shared by Editor and TextLog) -------------------------


def _cells_for_bytes(line: String, lo: Int, hi: Int) -> Int:
    """Display columns spanned by ``line``'s bytes ``[lo, hi)`` — walks
    codepoints summing ``char_width`` so wide glyphs (emoji) count as two.
    Used to find a color run's starting cell within a painted row."""
    var bytes = line.as_bytes()
    var n = len(bytes)
    var i = lo
    var cells = 0
    while i < hi and i < n:
        var dec = codepoint_at(line, i)
        cells += char_width(dec[0])
        i += dec[1]
    return cells


def paint_text_segments(
    mut canvas: Canvas,
    view: Rect,
    lines: List[String],
    layout: List[VisualLine],
    first: Int,
    visible: Int,
    line_attrs: List[Attr],
    default_attr: Attr,
    line_runs: List[List[ColorRun]],
):
    """Paint the text content of every visible visual row.

    For row ``k``, slices ``lines[layout[first+k].line_idx]`` from
    ``byte_start`` to ``byte_end`` and ``put_text``s it at
    ``view.a.x + layout[k].indent_cells`` on row ``view.a.y + k``.
    The row's base ``Attr`` comes from ``line_attrs[line_idx]`` if that
    index is in range, else ``default_attr``. ``view.b.x`` clips
    text that extends past the right margin.

    ``line_runs`` (parallel to ``lines``) overlays sub-line color: after
    the base row is drawn, each run intersecting the row is re-``put_text``
    on top with its own ``Attr`` — gaps keep the base color. Pass an empty
    list for a plain single-color view.
    """
    if visible <= 0:
        return
    var painter = Painter(view)
    for k in range(visible):
        var vidx = first + k
        if vidx < 0 or vidx >= len(layout):
            continue
        var vrow = layout[vidx]
        if vrow.line_idx < 0 or vrow.line_idx >= len(lines):
            continue
        var attr = default_attr
        if vrow.line_idx < len(line_attrs):
            attr = line_attrs[vrow.line_idx]
        var line = lines[vrow.line_idx]
        var bytes = line.as_bytes()
        var n = len(bytes)
        var lo = vrow.byte_start
        var hi = vrow.byte_end
        if hi > n:
            hi = n
        var seg = String("")
        if lo < n and hi > lo:
            seg = String(StringSlice(
                ptr=bytes.unsafe_ptr() + lo,
                length=hi - lo,
            ))
        _ = painter.put_text(
            canvas,
            Point(view.a.x + vrow.indent_cells, view.a.y + k),
            seg, attr,
        )
        # Overlay SGR color runs falling on this row, on top of the base.
        if vrow.line_idx < len(line_runs) and lo < hi:
            var lr = line_runs[vrow.line_idx].copy()
            for ri in range(len(lr)):
                var rs = lr[ri].start
                var rce = lr[ri].end
                if rce <= lo or rs >= hi:
                    continue
                if rs < lo:
                    rs = lo
                if rce > hi:
                    rce = hi
                var cellx = vrow.indent_cells + _cells_for_bytes(line, lo, rs)
                var sub = String(StringSlice(
                    ptr=bytes.unsafe_ptr() + rs,
                    length=rce - rs,
                ))
                _ = painter.put_text(
                    canvas,
                    Point(view.a.x + cellx, view.a.y + k),
                    sub, lr[ri].attr,
                )


def paint_selection_overlay(
    mut canvas: Canvas,
    view: Rect,
    lines: List[String],
    layout: List[VisualLine],
    first: Int,
    visible: Int,
    selection: Selection,
    sel_attr: Attr,
    extend_past_eol: Bool = False,
):
    """Recolor cells covered by ``selection`` in every visible row.

    Walks the ``[first, first + visible)`` window, intersects the
    selection's byte range with each row's ``[byte_start, byte_end)``,
    and converts the overlap to cell columns via ``VisualLine``'s
    parallel offsets. No-op when the selection isn't active. Editor
    code that paints several selections (one per caret) calls this
    once per caret.

    ``extend_past_eol`` (Editor opt-in): on intermediate rows whose
    selection range collapses to zero (an empty line in the middle of
    a multi-line selection, or a selection whose end byte sits one
    past EOL), paint one extra trailing cell with a space glyph + the
    selection attr so the user can see those rows are part of the
    selection. Read-only views (``TextLog``) leave this off — the
    byte-strict intersect is what matches their copy semantics.
    """
    if not selection.active:
        return
    if visible <= 0:
        return
    var painter = Painter(view)
    var r = selection.normalized()
    var s_line = r[0]; var s_byte = r[1]
    var e_line = r[2]; var e_byte = r[3]
    for k in range(visible):
        var vidx = first + k
        if vidx < 0 or vidx >= len(layout):
            continue
        var vrow = layout[vidx]
        if vrow.line_idx < s_line or vrow.line_idx > e_line:
            continue
        if vrow.line_idx < 0 or vrow.line_idx >= len(lines):
            continue
        var line = lines[vrow.line_idx]
        var line_n = len(line.as_bytes())
        var lo_byte = vrow.byte_start
        var hi_byte = vrow.byte_end
        if vrow.line_idx == s_line and s_byte > lo_byte:
            lo_byte = s_byte
        if vrow.line_idx == e_line and e_byte < hi_byte:
            hi_byte = e_byte
        # Last visual segment of this buffer row in the painted
        # layout? Only the trailing segment gets the past-EOL marker.
        var is_last_seg = (vidx + 1 >= len(layout)) or (
            layout[vidx + 1].line_idx != vrow.line_idx
        )
        var line_y = view.a.y + k
        if hi_byte > lo_byte:
            var lo_cell = _row_cell_offset(vrow, line, lo_byte)
            var hi_cell = _row_cell_offset(vrow, line, hi_byte)
            var x0 = view.a.x + vrow.indent_cells + lo_cell
            var x1 = view.a.x + vrow.indent_cells + hi_cell
            if x1 > view.b.x:
                x1 = view.b.x
            for x in range(x0, x1):
                painter.set_attr(canvas, x, line_y, sel_attr)
        if extend_past_eol and is_last_seg \
                and vrow.line_idx < e_line:
            # The selection continues onto a later line — show the
            # trailing newline as a one-cell marker. ``set`` rather
            # than ``set_attr`` because the byte was past EOL and
            # ``put_text`` left a space (or nothing) there.
            var marker_cell = _row_cell_offset(vrow, line, line_n)
            var x_marker = view.a.x + vrow.indent_cells + marker_cell
            if x_marker < view.b.x:
                painter.set(
                    canvas, x_marker, line_y,
                    Cell(String(" "), sel_attr, 1),
                )


# --- text log: append-only, soft-wrapped, selectable, scrollable ----------


struct TextLog(Copyable, Movable):
    """A read-only text view with soft-wrap, mouse-drag selection,
    scroll, and clipboard copy. Composed by views like the DebugPane
    output panel — caller appends lines, calls ``paint`` and forwards
    mouse / keyboard events; everything else (wrap layout, selection
    state, autoscroll, copy) lives here.

    Each line carries an ``Attr`` (parallel ``line_attrs``) so the
    caller can color stderr lines red without subclassing or hooking
    a per-line callback. ``default_attr`` applies when the caller
    doesn't supply one.

    Layout-cache fields (``last_*``) are stamped on every ``paint`` so
    callers that need to overlay other things (clickable spans, hover
    state) can iterate ``last_visible_rows()`` without re-running the
    wrap math.
    """
    var lines: List[String]
    var line_attrs: List[Attr]
    """Parallel to ``lines`` — caller-provided per-line color (e.g.
    stderr red, console gray). When ``len(line_attrs) <= i`` we fall
    back to ``default_attr`` for line ``i``."""
    var line_runs: List[List[ColorRun]]
    """Parallel to ``lines`` — sub-line color spans decoded from ANSI SGR
    escapes in the appended text (``parse_sgr``). The line's ``line_attrs``
    entry is the base color; these runs override it over byte ranges
    (offsets into the *clean*, escape-free ``lines[i]``). Empty list ⇒ a
    plain single-color line. This is what makes ``pytest --color=yes``
    output render colored instead of as raw escape bytes."""
    var default_attr: Attr
    var max_lines: Int
    """Backlog cap. Trims from the front when exceeded; selection line
    indices follow the trim and degrade to "no selection" when an
    endpoint falls into the dropped prefix."""

    var selection: Selection
    var scroll: Int
    """Visual-row index of the bottom visible row when ``autoscroll``
    is False. Wheel ticks move this in visual-row units; soft-wrap
    boundaries are honored automatically."""
    var autoscroll: Bool

    # Layout cache, stamped by the last ``paint`` call.
    var last_visual: List[VisualLine]
    var last_y0: Int
    var last_x0: Int
    var last_x_max: Int
    var last_first_visual: Int
    var last_visible_count: Int
    var _open: Bool
    """True iff the last line was written by a ``streaming`` append that
    didn't end in ``\\n`` — i.e. it's an unterminated line still being
    built up byte-by-byte. The next streaming append continues it
    instead of starting a fresh row. This is what keeps pytest's
    one-dot-per-test progress (each dot arrives as its own read chunk,
    with no newline between dots) on a single line. Discrete
    (non-streaming) appends — the IDE's own ``$ …`` console banners —
    always start and close their own row and reset this to False."""
    var _layout_w: Int
    """Content width (cells) the cached ``last_visual`` was built for.
    -1 sentinel means "invalid, recompute" — set on every mutation
    (``append``, ``_push_line``, ``clear``). When ``paint`` sees
    ``_layout_w == content_w`` it reuses ``last_visual`` instead of
    re-running ``wrap_lines`` over the full backlog. Without this the
    maximized DebugPane re-wrapped its full 500-line stderr backlog
    every frame at ~210 cols and paint cost ~200 ms, which kept the
    main loop from ever hitting its idle-blocking ``poll_stdin``
    timeout — CPU pegged at 100 % until the pane was un-maximized."""

    def __init__(out self, default_attr: Attr, max_lines: Int = 500):
        self.lines = List[String]()
        self.line_attrs = List[Attr]()
        self.line_runs = List[List[ColorRun]]()
        self.default_attr = default_attr
        self.max_lines = max_lines
        self.selection = Selection.empty()
        self.scroll = 0
        self.autoscroll = True
        self.last_visual = List[VisualLine]()
        self.last_y0 = 0
        self.last_x0 = 0
        self.last_x_max = 0
        self.last_first_visual = 0
        self.last_visible_count = 0
        self._open = False
        self._layout_w = -1

    def __copyinit__(mut self, copy: Self):
        self.lines = copy.lines.copy()
        self.line_attrs = copy.line_attrs.copy()
        self.line_runs = copy.line_runs.copy()
        self.default_attr = copy.default_attr
        self.max_lines = copy.max_lines
        self.selection = copy.selection
        self.scroll = copy.scroll
        self.autoscroll = copy.autoscroll
        self.last_visual = copy.last_visual.copy()
        self.last_y0 = copy.last_y0
        self.last_x0 = copy.last_x0
        self.last_x_max = copy.last_x_max
        self.last_first_visual = copy.last_first_visual
        self.last_visible_count = copy.last_visible_count
        self._open = copy._open
        self._layout_w = copy._layout_w

    # --- mutation -------------------------------------------------------

    def append(
        mut self, var text: String, attr: Optional[Attr] = None,
        streaming: Bool = False,
    ):
        """Append ``text``, splitting on ``\\n``. Each split line gets
        its own ``Attr`` — when ``attr`` is None we fall back to
        ``default_attr``. Trims the front when ``max_lines`` is hit.

        ``streaming`` controls how a chunk that *doesn't* end in ``\\n``
        is treated. Discrete callers (the default — IDE console banners
        like ``$ …``) push that trailing text as its own row. Streaming
        callers (raw child stdout/stderr) leave the line "open" so the
        next streaming append continues it. The latter is what keeps
        pytest's progress dots — which arrive as separate read chunks
        with no newline between them — on one line instead of one dot
        per row. See ``_open``."""
        var resolved = self.default_attr
        if attr:
            resolved = attr.value()
        # Decode ANSI SGR over the *whole* chunk first so color state can
        # flow across embedded newlines, then split the escape-free text
        # into rows and hand each row only the runs that fall on it. The
        # base for resets / default-fg is the resolved per-stream attr, so
        # a ``\\x1b[0m`` returns to (say) the stderr red rather than gray.
        var parsed = parse_sgr(text, resolved)
        var clean = parsed[0]
        var runs = parsed[1].copy()
        var b = clean.as_bytes()
        if len(b) == 0:
            # An all-escape chunk (e.g. a lone ``\\x1b[2K``) cleans to
            # nothing — append no row and leave the open-line state alone.
            return
        # The first emitted segment continues the previous open line
        # only when both that line and this append are streaming.
        var continue_open = streaming and self._open and len(self.lines) > 0
        var first = True
        var start = 0
        for i in range(len(b)):
            if b[i] == 0x0A:  # '\n'
                var seg = String(StringSlice(
                    ptr=b.unsafe_ptr() + start, length=i - start,
                ))
                var seg_runs = _slice_runs(runs, start, i)
                if first and continue_open:
                    self._extend_last(seg^, seg_runs^)
                else:
                    self._push_line(seg^, resolved, seg_runs^)
                first = False
                start = i + 1
        if start < len(b):
            var seg = String(StringSlice(
                ptr=b.unsafe_ptr() + start, length=len(b) - start,
            ))
            var seg_runs = _slice_runs(runs, start, len(b))
            if first and continue_open:
                self._extend_last(seg^, seg_runs^)
            else:
                self._push_line(seg^, resolved, seg_runs^)
        # Line stays "open" only for a streaming chunk that didn't end
        # on a newline; anything else closes the current row so a later
        # streaming append starts fresh rather than gluing onto it.
        self._open = streaming and b[len(b) - 1] != 0x0A

    def _extend_last(mut self, var seg: String, var runs: List[ColorRun]):
        """Glue ``seg`` onto the last (open) line in place, keeping the
        incremental layout cache valid by re-wrapping just that one
        logical line — never the full backlog. ``runs`` are segment-relative
        color spans; they're rebased onto the existing clean length so they
        line up with the glued-on text."""
        var idx = len(self.lines) - 1
        var base_len = len(self.lines[idx].as_bytes())
        for r in runs:
            self.line_runs[idx].append(
                ColorRun(r.start + base_len, r.end + base_len, r.attr)
            )
        self.lines[idx] = self.lines[idx] + seg^
        if self._layout_w >= 0:
            # Drop the mutated line's stale visual rows, then re-append
            # its freshly-wrapped rows. Rows are grouped by ``line_idx``
            # and this line is last, so its rows are a trailing run.
            while len(self.last_visual) > 0 and \
                    self.last_visual[len(self.last_visual) - 1].line_idx \
                    == idx:
                _ = self.last_visual.pop()
            var new_rows = wrap_lines(
                self.lines, self._layout_w, start_line=idx,
            )
            for k in range(len(new_rows)):
                self.last_visual.append(new_rows[k])

    def clear(mut self):
        """Drop all lines and any selection. Scroll resets to top."""
        self.lines = List[String]()
        self.line_attrs = List[Attr]()
        self.line_runs = List[List[ColorRun]]()
        self.selection = Selection.empty()
        self.scroll = 0
        self.autoscroll = True
        self.last_visual = List[VisualLine]()
        self._open = False
        self._layout_w = -1

    def _push_line(mut self, var line: String, attr: Attr,
                   var runs: List[ColorRun]):
        self.lines.append(line^)
        self.line_attrs.append(attr)
        self.line_runs.append(runs^)
        # Incremental cache update: wrap just the newly-appended line
        # and tack its rows onto ``last_visual``. Full re-wraps happen
        # only when the width changes (handled in ``paint``). Without
        # this, a streaming source like Django's stderr would invalidate
        # the cache on every line and force ``paint`` to re-wrap the
        # entire backlog every frame — ~200 ms per frame on a maximized
        # pane, enough to keep the main loop's idle blocking from ever
        # firing.
        if self._layout_w >= 0:
            var new_rows = wrap_lines(
                self.lines, self._layout_w,
                start_line=len(self.lines) - 1,
            )
            for k in range(len(new_rows)):
                self.last_visual.append(new_rows[k])
        if len(self.lines) > self.max_lines:
            var drop = len(self.lines) - self.max_lines
            var trimmed = List[String]()
            var tattrs = List[Attr]()
            var truns = List[List[ColorRun]]()
            for k in range(drop, len(self.lines)):
                trimmed.append(self.lines[k])
                tattrs.append(self.line_attrs[k])
                truns.append(self.line_runs[k].copy())
            self.lines = trimmed^
            self.line_attrs = tattrs^
            self.line_runs = truns^
            # Trim the layout cache symmetrically: drop visual rows for
            # the dropped logical lines, renumber the survivors. Track
            # how many visual rows were dropped so a manually-scrolled
            # log keeps pointing at the same content (autoscroll users
            # don't notice — paint recomputes ``first`` from
            # ``len(last_visual)`` every frame).
            if self._layout_w >= 0:
                var trimmed_layout = List[VisualLine]()
                var dropped_rows = 0
                for k in range(len(self.last_visual)):
                    var vr = self.last_visual[k]
                    if vr.line_idx < drop:
                        dropped_rows += 1
                        continue
                    trimmed_layout.append(VisualLine(
                        vr.line_idx - drop,
                        vr.byte_start, vr.byte_end,
                        vr.cell_start, vr.cell_count,
                        vr.indent_cells,
                    ))
                self.last_visual = trimmed_layout^
                if not self.autoscroll:
                    self.scroll -= dropped_rows
                    if self.scroll < 0:
                        self.scroll = 0
            if self.scroll > self.max_lines:
                self.scroll = self.max_lines - 1
            if self.selection.active:
                self.selection.anchor_line -= drop
                self.selection.cursor_line -= drop
                if self.selection.anchor_line < 0 \
                        or self.selection.cursor_line < 0:
                    self.selection = Selection.empty()

    # --- query ----------------------------------------------------------

    def has_selection(self) -> Bool:
        return self.selection.active

    def selected_text(self) -> String:
        return self.selection.extracted_text(self.lines)

    def copy_to_clipboard(self) -> Bool:
        var text = self.selected_text()
        if len(text.as_bytes()) == 0:
            return False
        clipboard_copy(text)
        return True

    # --- paint ----------------------------------------------------------

    def paint(mut self, mut canvas: Canvas, view: Rect):
        """Paint soft-wrapped text + selection overlay into ``view``.

        The actual per-row painting is delegated to ``paint_text_segments``
        and ``paint_selection_overlay`` — the same primitives the Editor
        calls. ``TextLog`` only owns the wrap layout cache and the
        scroll/autoscroll math; the visible-row drawing code is single-
        sourced.
        """
        if view.is_empty():
            return
        self.last_y0 = view.a.y
        self.last_x0 = view.a.x
        self.last_x_max = view.b.x
        var content_w = view.b.x - view.a.x
        if content_w < 1:
            content_w = 1
        if self._layout_w != content_w:
            self.last_visual = wrap_lines(self.lines, content_w)
            self._layout_w = content_w
        var visible = view.b.y - view.a.y
        if visible < 0:
            visible = 0
        self.last_visible_count = visible
        var first = self.scroll - visible + 1
        if self.autoscroll:
            first = len(self.last_visual) - visible
        if first < 0:
            first = 0
        self.last_first_visual = first
        # Keep ``self.scroll`` (= last visible row) in sync with the
        # actual painted ``first``. Without this, autoscroll lets
        # ``self.scroll`` go stale while new lines arrive, and the
        # next ``scroll_by`` from the user jumps relative to that
        # stale value — wheel-up by 1 from the bottom would warp the
        # view far above the last seen rows instead of just nudging
        # one row up.
        if visible > 0:
            self.scroll = first + visible - 1
        else:
            self.scroll = first
        paint_text_segments(
            canvas, view, self.lines, self.last_visual,
            first, visible, self.line_attrs, self.default_attr,
            self.line_runs,
        )
        paint_selection_overlay(
            canvas, view, self.lines, self.last_visual,
            first, visible, self.selection, Attr(BLACK, CYAN),
        )

    # --- input ----------------------------------------------------------

    def position_at(self, pos: Point) -> Tuple[Int, Int]:
        """Map a screen point to ``(line_idx, byte_col)`` using the
        layout the last ``paint`` stamped. Out-of-range clicks clamp
        to the nearest visible row."""
        if len(self.last_visual) == 0 or len(self.lines) == 0:
            return (0, 0)
        var screen_offset = pos.y - self.last_y0
        if screen_offset < 0:
            screen_offset = 0
        var vidx = self.last_first_visual + screen_offset
        if vidx >= len(self.last_visual):
            vidx = len(self.last_visual) - 1
        if vidx < 0:
            vidx = 0
        var vrow = self.last_visual[vidx]
        var cell_in_seg = pos.x - self.last_x0 - vrow.indent_cells
        if cell_in_seg < 0:
            cell_in_seg = 0
        if cell_in_seg > vrow.cell_count:
            cell_in_seg = vrow.cell_count
        var line = self.lines[vrow.line_idx]
        var b = vrow.byte_start
        var consumed = 0
        while consumed < cell_in_seg and b < vrow.byte_end:
            var info = codepoint_at(line, b)
            var cw = char_width(info[0])
            # A click on the right half of a wide glyph snaps to its start.
            if consumed + cw > cell_in_seg:
                break
            consumed += cw
            b += info[1]
        if b > vrow.byte_end:
            b = vrow.byte_end
        return (vrow.line_idx, b)

    def handle_mouse(mut self, event: Event) -> Bool:
        """Consume mouse events that belong to this view: wheel for
        scroll, left-press to start a drag, motion to extend, release
        to commit. Returns True if the event was handled.

        Caller decides which events to forward — typically every event
        whose ``pos`` falls in the painted rect, plus every event of
        any kind while ``selection.dragging`` is True (so a drag that
        wandered off the rect still extends)."""
        if event.kind != EVENT_MOUSE:
            return False
        if event.button == MOUSE_WHEEL_UP or event.button == MOUSE_WHEEL_DOWN:
            if event.pressed:
                var delta = -3 if event.button == MOUSE_WHEEL_UP else 3
                self.scroll_by(delta)
            return True
        if event.button == MOUSE_BUTTON_LEFT and not event.pressed:
            self.selection.dragging = False
            return True
        if event.button != MOUSE_BUTTON_LEFT or not event.pressed:
            return False
        if event.motion:
            if self.selection.dragging:
                # Clamp y so a drag past the bottom edge selects
                # through the last visible row instead of wrapping.
                var clamp_y = event.pos.y
                if clamp_y < self.last_y0:
                    clamp_y = self.last_y0
                var pos = self.position_at(Point(event.pos.x, clamp_y))
                self.selection.cursor_line = pos[0]
                self.selection.cursor_col = pos[1]
                if self.selection.cursor_line != self.selection.anchor_line \
                        or self.selection.cursor_col != self.selection.anchor_col:
                    self.selection.active = True
                return True
            return False
        # Fresh left-press: anchor + start drag, clear any prior
        # selection. The active flag stays False until motion fires —
        # that way a plain click without a drag clears the selection
        # without producing a zero-width new one.
        var pos = self.position_at(event.pos)
        self.selection = Selection(
            False, True, pos[0], pos[1], pos[0], pos[1],
        )
        return True

    def handle_key(mut self, event: Event) -> Bool:
        """Scroll keys: PageUp/PageDown move by 8 visual rows,
        Home/End jump to the top / re-engage autoscroll."""
        if event.kind != EVENT_KEY:
            return False
        if event.key == KEY_PAGEUP:
            self.scroll_by(-8)
            return True
        if event.key == KEY_PAGEDOWN:
            self.scroll_by(8)
            return True
        if event.key == KEY_HOME:
            self.scroll = 0
            self.autoscroll = (len(self.last_visual) <= 1)
            return True
        if event.key == KEY_END:
            self.autoscroll = True
            return True
        return False

    def scroll_by(mut self, delta: Int):
        """Move scroll by ``delta`` visual rows (positive = down).
        Manual scrolls disengage autoscroll until the user reaches
        the bottom row again."""
        var ns = self.scroll + delta
        if ns < 0:
            ns = 0
        var max_s = len(self.last_visual) - 1
        if max_s < 0:
            max_s = 0
        if ns > max_s:
            ns = max_s
        self.autoscroll = (ns >= max_s)
        self.scroll = ns

    def scroll_to_top_row(mut self, top: Int):
        """Set the first visible row to ``top``. Disengages autoscroll
        unless ``top`` would still leave the last visual row visible
        (in which case autoscroll re-engages so new output keeps
        sliding into view).

        ``self.scroll`` is the index of the *last* visible row; this
        helper exists so callers driving the scrollbar can think in
        terms of "top of view" without juggling that detail.
        """
        var visible = self.last_visible_count
        if visible < 1:
            visible = 1
        var max_s = len(self.last_visual) - 1
        if max_s < 0:
            max_s = 0
        var ns = top + visible - 1
        if ns < 0:
            ns = 0
        if ns > max_s:
            ns = max_s
        self.autoscroll = (ns >= max_s)
        self.scroll = ns


# --- internal helpers -----------------------------------------------------


def _row_cell_offset(
    vrow: VisualLine, line: String, target_byte: Int,
) -> Int:
    """Cells from the row's painted left edge to byte ``target_byte``.
    ``target_byte`` should fall in ``[vrow.byte_start, vrow.byte_end]``;
    callers above clamp via the per-row byte intersection so we just
    walk codepoints inside the segment until we reach the target."""
    if target_byte <= vrow.byte_start:
        return 0
    var b = vrow.byte_start
    var cells = 0
    while b < target_byte and b < vrow.byte_end:
        var info = codepoint_at(line, b)
        cells += char_width(info[0])
        b += info[1]
    return cells


