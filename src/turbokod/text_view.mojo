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
from .cell import Cell
from .clipboard import clipboard_copy
from .colors import Attr, BLACK, CYAN
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_DOWN, KEY_END, KEY_HOME, KEY_PAGEDOWN, KEY_PAGEUP, KEY_UP,
    MOUSE_BUTTON_LEFT, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .geometry import Point, Rect
from .string_utils import (
    is_word_codepoint, leading_indent_bytes, utf8_codepoint_size,
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


fn wrap_lines(
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
        var bytes = line.as_bytes()
        var line_n = len(bytes)
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
        var c = 0
        var first = True
        var cell_offset = 0
        while c < line_n:
            if max_rows >= 0 and len(out) >= max_rows:
                break
            var indent_cells = 0 if first else cont_indent
            var seg_w = content_w - indent_cells
            if seg_w < 1:
                seg_w = 1
            # Hard upper bound: at most ``seg_w`` cells from ``c``,
            # walking codepoints so a multi-byte glyph is never split.
            var cells = 0
            var e_hard = c
            while e_hard < line_n and cells < seg_w:
                e_hard += utf8_codepoint_size(Int(bytes[e_hard]))
                cells += 1
            if e_hard > line_n:
                e_hard = line_n
            var e = e_hard
            # Word-aware wrap: walk back to the last non-word ASCII
            # boundary inside ``[c, e_hard)``. Skipped entirely when the
            # caller didn't ask for it (the output panel hard-breaks).
            if word_aware and e_hard < line_n:
                var p = e_hard
                while p > c + 1:
                    var pb = Int(bytes[p - 1])
                    if pb < 0x80 and not is_word_codepoint(pb):
                        e = p
                        break
                    p -= 1
            # Codepoint count for this segment — needed for ``cell_count``
            # in word-aware mode where we walked back past the cells we
            # already counted.
            var seg_cells: Int
            if e == e_hard:
                seg_cells = cells
            else:
                seg_cells = 0
                var k = c
                while k < e:
                    seg_cells += 1
                    k += utf8_codepoint_size(Int(bytes[k]))
            out.append(VisualLine(
                br, c, e, cell_offset, seg_cells, indent_cells,
            ))
            cell_offset += seg_cells
            c = e
            first = False
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
    fn empty() -> Self:
        return Selection(False, False, 0, 0, 0, 0)

    fn is_empty(self) -> Bool:
        """True iff there is no selection to copy. Endpoints meeting at
        the same byte counts as empty (no glyphs in between)."""
        if not self.active:
            return True
        return self.anchor_line == self.cursor_line \
            and self.anchor_col == self.cursor_col

    fn normalized(self) -> Tuple[Int, Int, Int, Int]:
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

    fn extracted_text(self, lines: List[String]) -> String:
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
            return _byte_slice(lines[s_line], s_col, e_col)
        var first_line = lines[s_line]
        var first_n = len(first_line.as_bytes())
        var out = _byte_slice(first_line, s_col, first_n)
        for li in range(s_line + 1, e_line):
            if li < 0 or li >= len(lines):
                continue
            out = out + String("\n") + lines[li]
        if 0 <= e_line and e_line < len(lines):
            out = out + String("\n") + _byte_slice(lines[e_line], 0, e_col)
        return out^


# --- paint helpers (shared by Editor and TextLog) -------------------------


fn paint_text_segments(
    mut canvas: Canvas,
    view: Rect,
    lines: List[String],
    layout: List[VisualLine],
    first: Int,
    visible: Int,
    line_attrs: List[Attr],
    default_attr: Attr,
):
    """Paint the text content of every visible visual row.

    For row ``k``, slices ``lines[layout[first+k].line_idx]`` from
    ``byte_start`` to ``byte_end`` and ``put_text``s it at
    ``view.a.x + layout[k].indent_cells`` on row ``view.a.y + k``.
    The row's ``Attr`` comes from ``line_attrs[line_idx]`` if that
    index is in range, else ``default_attr``. ``view.b.x`` clips
    text that extends past the right margin.

    Used by both ``TextLog.paint`` and the Editor's paint loop —
    everything else (syntax overlay, gutters, cursors) is layered on
    top by the caller after this returns.
    """
    if visible <= 0:
        return
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
        var seg = String("")
        if vrow.byte_start < n and vrow.byte_end > vrow.byte_start:
            var hi = vrow.byte_end
            if hi > n:
                hi = n
            seg = String(StringSlice(
                ptr=bytes.unsafe_ptr() + vrow.byte_start,
                length=hi - vrow.byte_start,
            ))
        _ = canvas.put_text(
            Point(view.a.x + vrow.indent_cells, view.a.y + k),
            seg, attr, view.b.x,
        )


fn paint_selection_overlay(
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
                canvas.set_attr(x, line_y, sel_attr)
        if extend_past_eol and is_last_seg \
                and vrow.line_idx < e_line:
            # The selection continues onto a later line — show the
            # trailing newline as a one-cell marker. ``canvas.set``
            # rather than ``set_attr`` because the byte was past EOL
            # and ``put_text`` left a space (or nothing) there.
            var marker_cell = _row_cell_offset(vrow, line, line_n)
            var x_marker = view.a.x + vrow.indent_cells + marker_cell
            if x_marker < view.b.x:
                canvas.set(
                    x_marker, line_y, Cell(String(" "), sel_attr, 1),
                )


# --- text log: append-only, soft-wrapped, selectable, scrollable ----------


struct TextLog(ImplicitlyCopyable, Movable):
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

    fn __init__(out self, default_attr: Attr, max_lines: Int = 500):
        self.lines = List[String]()
        self.line_attrs = List[Attr]()
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

    fn __copyinit__(out self, copy: Self):
        self.lines = copy.lines.copy()
        self.line_attrs = copy.line_attrs.copy()
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

    # --- mutation -------------------------------------------------------

    fn append(mut self, var text: String, attr: Optional[Attr] = None):
        """Append ``text``, splitting on ``\\n``. Each split line gets
        its own ``Attr`` — when ``attr`` is None we fall back to
        ``default_attr``. Trims the front when ``max_lines`` is hit."""
        var resolved = self.default_attr
        if attr:
            resolved = attr.value()
        var b = text.as_bytes()
        var start = 0
        for i in range(len(b)):
            if b[i] == 0x0A:  # '\n'
                self._push_line(
                    String(StringSlice(
                        ptr=b.unsafe_ptr() + start, length=i - start,
                    )),
                    resolved,
                )
                start = i + 1
        if start < len(b):
            self._push_line(
                String(StringSlice(
                    ptr=b.unsafe_ptr() + start, length=len(b) - start,
                )),
                resolved,
            )

    fn clear(mut self):
        """Drop all lines and any selection. Scroll resets to top."""
        self.lines = List[String]()
        self.line_attrs = List[Attr]()
        self.selection = Selection.empty()
        self.scroll = 0
        self.autoscroll = True

    fn _push_line(mut self, var line: String, attr: Attr):
        self.lines.append(line^)
        self.line_attrs.append(attr)
        if len(self.lines) > self.max_lines:
            var drop = len(self.lines) - self.max_lines
            var trimmed = List[String]()
            var tattrs = List[Attr]()
            for k in range(drop, len(self.lines)):
                trimmed.append(self.lines[k])
                tattrs.append(self.line_attrs[k])
            self.lines = trimmed^
            self.line_attrs = tattrs^
            if self.scroll > self.max_lines:
                self.scroll = self.max_lines - 1
            if self.selection.active:
                self.selection.anchor_line -= drop
                self.selection.cursor_line -= drop
                if self.selection.anchor_line < 0 \
                        or self.selection.cursor_line < 0:
                    self.selection = Selection.empty()

    # --- query ----------------------------------------------------------

    fn has_selection(self) -> Bool:
        return self.selection.active

    fn selected_text(self) -> String:
        return self.selection.extracted_text(self.lines)

    fn copy_to_clipboard(self) -> Bool:
        var text = self.selected_text()
        if len(text.as_bytes()) == 0:
            return False
        clipboard_copy(text)
        return True

    # --- paint ----------------------------------------------------------

    fn paint(mut self, mut canvas: Canvas, view: Rect):
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
        self.last_visual = wrap_lines(self.lines, content_w)
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
        paint_text_segments(
            canvas, view, self.lines, self.last_visual,
            first, visible, self.line_attrs, self.default_attr,
        )
        paint_selection_overlay(
            canvas, view, self.lines, self.last_visual,
            first, visible, self.selection, Attr(BLACK, CYAN),
        )

    # --- input ----------------------------------------------------------

    fn position_at(self, pos: Point) -> Tuple[Int, Int]:
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
        var cell_in_seg = pos.x - self.last_x0
        if cell_in_seg < 0:
            cell_in_seg = 0
        if cell_in_seg > vrow.cell_count:
            cell_in_seg = vrow.cell_count
        var line = self.lines[vrow.line_idx]
        var bytes = line.as_bytes()
        var b = vrow.byte_start
        for _ in range(cell_in_seg):
            if b >= vrow.byte_end:
                break
            b += utf8_codepoint_size(Int(bytes[b]))
        if b > vrow.byte_end:
            b = vrow.byte_end
        return (vrow.line_idx, b)

    fn handle_mouse(mut self, event: Event) -> Bool:
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

    fn handle_key(mut self, event: Event) -> Bool:
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

    fn scroll_by(mut self, delta: Int):
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


# --- internal helpers -----------------------------------------------------


fn _row_cell_offset(
    vrow: VisualLine, line: String, target_byte: Int,
) -> Int:
    """Cells from the row's painted left edge to byte ``target_byte``.
    ``target_byte`` should fall in ``[vrow.byte_start, vrow.byte_end]``;
    callers above clamp via the per-row byte intersection so we just
    walk codepoints inside the segment until we reach the target."""
    if target_byte <= vrow.byte_start:
        return 0
    var bytes = line.as_bytes()
    var b = vrow.byte_start
    var cells = 0
    while b < target_byte and b < vrow.byte_end:
        cells += 1
        b += utf8_codepoint_size(Int(bytes[b]))
    return cells


fn _byte_slice(s: String, start: Int, end: Int) -> String:
    """Byte-range substring (no UTF-8 decoding). Tolerates out-of-range
    bounds. Mirrors editor.mojo's ``_slice`` so we can drop the local
    copy in either consumer if it ever becomes single-source."""
    var bytes = s.as_bytes()
    var s_start = start
    var s_end = end
    if s_start < 0:
        s_start = 0
    if s_end > len(bytes):
        s_end = len(bytes)
    if s_start >= s_end:
        return String("")
    return String(StringSlice(unsafe_from_utf8=bytes[s_start:s_end]))
