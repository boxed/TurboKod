"""Reusable scrollbar primitive.

Anything that paints scrollable content into a fixed rect can drop a
``VScrollbar`` (vertical) or ``HScrollbar`` (horizontal) into its paint
path and get the same look + behavior as the editor windows: ▲▼ end
arrows, █ thumb, ░ rail, click-on-arrow / click-on-rail / drag-thumb
hit-testing, and "centered jump" when the user clicks above or below
the thumb.

The struct is value-typed and cheap — caller constructs one each
paint with the current ``total`` / ``visible`` / ``scroll`` numbers,
calls ``paint`` once, and reuses the same value for hit-testing on
the next mouse event. No persistent state lives in the scrollbar
itself; the owning view stores ``scroll`` (and a drag-offset, when
the user is dragging the thumb).

Hit codes returned by ``hit``:

* ``0`` — none (click is off the scrollbar entirely).
* ``1`` — leading arrow (▲ for V, ◄ for H). Caller scrolls by -1.
* ``2`` — page-up zone (above the thumb). Caller calls
  ``track_jump(rel)`` to center the target row in view.
* ``3`` — on thumb. Caller starts a drag using the returned ``rel``
  as the drag-anchor offset, and on each motion event calls
  ``drag_to(mouse_pos, drag_offset)`` to compute the new ``scroll``.
* ``4`` — page-down zone (below the thumb). Same as ``2`` but below.
* ``5`` — trailing arrow (▼ for V, ► for H). Caller scrolls by +1.

Geometry conventions: ``top``/``bottom`` (V) and ``left``/``right``
(H) are *inclusive* — the arrow glyphs sit on those exact cells and
the track fills the cells in between.
"""

from .canvas import Canvas
from .cell import Cell
from .colors import Attr
from .geometry import Point
from .painter import Painter


@fieldwise_init
struct ScrollbarMetrics(ImplicitlyCopyable, Movable):
    """Geometry of a scrollbar at a given (total, visible, scroll).

    ``present=False`` means the bar is hidden — content fits, or the
    physical bar is too short to draw arrows + at least one track
    cell. Callers should early-out without painting or hit-testing
    when this is False.
    """
    var present: Bool
    var track_size: Int
    """Number of track cells between the arrows (exclusive)."""
    var knob_off: Int
    """Track-relative offset of the thumb's leading cell."""
    var knob_size: Int
    """Number of cells the thumb occupies."""
    var max_scroll: Int
    """Maximum value of ``scroll`` (i.e. ``total - visible``)."""


fn _metrics(
    bar_size: Int, total: Int, visible: Int, scroll: Int,
) -> ScrollbarMetrics:
    """Pure-math scrollbar geometry.

    ``bar_size`` is the physical size of the bar (arrows + track).
    Returns ``present=False`` unless ``bar_size >= 3`` AND content
    overflows the view.
    """
    if bar_size < 3:
        return ScrollbarMetrics(False, 0, 0, 0, 0)
    var v = visible
    if v < 1:
        v = 1
    if total <= v:
        return ScrollbarMetrics(False, 0, 0, 0, 0)
    var track_size = bar_size - 2
    var max_scroll = total - v
    var knob_size = (track_size * v) // total
    if knob_size < 1:
        knob_size = 1
    if knob_size > track_size:
        knob_size = track_size
    var denom = track_size - knob_size
    var knob_off = 0
    if denom > 0 and max_scroll > 0:
        var s = scroll
        if s < 0:
            s = 0
        if s > max_scroll:
            s = max_scroll
        knob_off = (s * denom) // max_scroll
    if knob_off < 0:
        knob_off = 0
    if knob_off > denom:
        knob_off = denom
    return ScrollbarMetrics(True, track_size, knob_off, knob_size, max_scroll)


fn _hit_axis(
    pos: Int, axis_start: Int, axis_end: Int, m: ScrollbarMetrics,
) -> Tuple[Int, Int]:
    """Map a 1D position along the scrollbar axis to ``(part, rel)``.
    See module docstring for ``part`` codes."""
    if not m.present:
        return (0, 0)
    if pos < axis_start or pos > axis_end:
        return (0, 0)
    if pos == axis_start:
        return (1, 0)
    if pos == axis_end:
        return (5, 0)
    var rel = pos - (axis_start + 1)
    if rel < 0 or rel >= m.track_size:
        return (0, 0)
    if rel < m.knob_off:
        return (2, rel)
    if rel >= m.knob_off + m.knob_size:
        return (4, rel)
    return (3, rel - m.knob_off)


fn _drag_to_axis(
    pos: Int, axis_start: Int, drag_offset: Int, m: ScrollbarMetrics,
) -> Int:
    """New ``scroll`` value when the user drags the thumb so its
    leading cell sits at ``pos - drag_offset``."""
    if not m.present:
        return 0
    var denom = m.track_size - m.knob_size
    if m.max_scroll == 0 or denom <= 0:
        return 0
    var track_start = axis_start + 1
    var target = pos - track_start - drag_offset
    if target < 0:
        target = 0
    if target > denom:
        target = denom
    var ns = (target * m.max_scroll + denom // 2) // denom
    if ns < 0:
        ns = 0
    if ns > m.max_scroll:
        ns = m.max_scroll
    return ns


fn _track_jump_axis(
    track_pos: Int, visible: Int, m: ScrollbarMetrics,
) -> Int:
    """New ``scroll`` value for a click in the page-up/page-down zone
    that centers the target row inside the visible area."""
    if not m.present:
        return 0
    var v = visible
    if v < 1:
        v = 1
    var total = m.max_scroll + v
    var rel = track_pos
    if rel < 0:
        rel = 0
    if rel >= m.track_size:
        rel = m.track_size - 1
    var target_row = (rel * total) // m.track_size
    var ns = target_row - (v // 2)
    if ns < 0:
        ns = 0
    if ns > m.max_scroll:
        ns = m.max_scroll
    return ns


@fieldwise_init
struct VScrollbar(ImplicitlyCopyable, Movable):
    """Vertical scrollbar at column ``x`` from row ``top`` to ``bottom``
    (both inclusive). ``total`` is the total number of scrollable rows,
    ``visible`` is the number of rows visible in the view at once, and
    ``scroll`` is the index of the first visible row.
    """
    var x: Int
    var top: Int
    var bottom: Int
    var total: Int
    var visible: Int
    var scroll: Int

    fn metrics(self) -> ScrollbarMetrics:
        return _metrics(
            self.bottom - self.top + 1, self.total, self.visible, self.scroll,
        )

    fn paint(self, mut canvas: Canvas, painter: Painter, attr: Attr):
        var m = self.metrics()
        if not m.present:
            return
        painter.set(canvas, self.x, self.top, Cell(String("▲"), attr, 1))
        painter.set(canvas, self.x, self.bottom, Cell(String("▼"), attr, 1))
        var track_y0 = self.top + 1
        for i in range(m.track_size):
            var ch: String
            if m.knob_off <= i and i < m.knob_off + m.knob_size:
                ch = String("█")
            else:
                ch = String("░")
            painter.set(canvas, self.x, track_y0 + i, Cell(ch, attr, 1))

    fn hit(self, p: Point) -> Tuple[Int, Int]:
        if p.x != self.x:
            return (0, 0)
        return _hit_axis(p.y, self.top, self.bottom, self.metrics())

    fn drag_to(self, mouse_y: Int, drag_offset: Int) -> Int:
        return _drag_to_axis(mouse_y, self.top, drag_offset, self.metrics())

    fn track_jump(self, track_pos: Int) -> Int:
        return _track_jump_axis(track_pos, self.visible, self.metrics())


@fieldwise_init
struct HScrollbar(ImplicitlyCopyable, Movable):
    """Horizontal scrollbar at row ``y`` from column ``left`` to
    ``right`` (both inclusive). Same axis convention as ``VScrollbar``,
    rotated 90°."""
    var y: Int
    var left: Int
    var right: Int
    var total: Int
    var visible: Int
    var scroll: Int

    fn metrics(self) -> ScrollbarMetrics:
        return _metrics(
            self.right - self.left + 1, self.total, self.visible, self.scroll,
        )

    fn paint(self, mut canvas: Canvas, painter: Painter, attr: Attr):
        var m = self.metrics()
        if not m.present:
            return
        painter.set(canvas, self.left, self.y, Cell(String("◄"), attr, 1))
        painter.set(canvas, self.right, self.y, Cell(String("►"), attr, 1))
        var track_x0 = self.left + 1
        for i in range(m.track_size):
            var ch: String
            if m.knob_off <= i and i < m.knob_off + m.knob_size:
                ch = String("█")
            else:
                ch = String("░")
            painter.set(canvas, track_x0 + i, self.y, Cell(ch, attr, 1))

    fn hit(self, p: Point) -> Tuple[Int, Int]:
        if p.y != self.y:
            return (0, 0)
        return _hit_axis(p.x, self.left, self.right, self.metrics())

    fn drag_to(self, mouse_x: Int, drag_offset: Int) -> Int:
        return _drag_to_axis(mouse_x, self.left, drag_offset, self.metrics())

    fn track_jump(self, track_pos: Int) -> Int:
        return _track_jump_axis(track_pos, self.visible, self.metrics())
