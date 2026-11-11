"""A resizable split: two areas side by side or stacked, with a divider the
user drags.

Like ``ScrollBarArea``, a view owns one ``SplitArea`` per split and drives
it from its paint and mouse paths:

* ``layout(area, side_by_side)`` cuts ``area`` into the two halves and a
  one-cell divider between them (a column when side by side, a row when
  stacked), at ``fraction`` of the way across, clamped so each half keeps
  its minimum;
* ``paint(canvas)`` draws the divider — highlighted while it's dragged;
* ``handle_mouse(event)`` before the view's own mouse code: a press on the
  divider starts a drag that takes every event up to the release, moving
  the divider with the pointer; a double click puts it back at
  ``default_fraction``;
* ``pointer_shape(pos)`` answers the host's cursor question
  (``Desktop.pointer_shape_at``): ``ew-resize`` / ``ns-resize`` over the
  divider and for the whole of a drag, empty elsewhere. Every frontend
  already turns those into its cursor (``NSCursor`` in the Swift host, the
  pointer OSC in the terminal), so a split gets the right cursor in every
  look for free.
* ``take_changed()`` is True once after a drag (or reset) moved the
  divider, so the owner can remember ``fraction``.

The divider paints through the palette slots (``PANE_FG`` / ``PANE_BG``,
``BORDER_FOCUS`` while dragged) like the rest of a tool pane, so a theme
retints it. In a look whose host draws framework chrome
(``Canvas.host_widgets``) it's a ``HostItem`` instead, which the host draws
its own way — a hairline in the macOS-style look, a bevelled Platinum bar
with a grip in the Mac OS 9 look — over cells that still take the mouse, so
the drag and the cursor stay the core's. Coordinates are whatever the caller paints in: a view drawing
into a sub-grid passes grid positions to both ``layout`` and
``handle_mouse``.
"""

from .canvas import Canvas, HOST_SPLIT, HostItem, SCALE_ONE
from .cell import Cell
from .colors import Attr, BORDER_FOCUS, PANE_BG, PANE_FG
from .events import Event, EVENT_MOUSE, MOUSE_BUTTON_LEFT
from .geometry import Point, Rect


comptime SPLIT_SCALE = 1000
"""``fraction`` is in thousandths of the split area."""


struct SplitArea(Copyable, Movable):
    var fraction: Int
    """How far across the divider sits, in thousandths: the first half's
    share of the area."""
    var default_fraction: Int
    """Where a double click on the divider puts it back."""
    var min_first: Int
    var min_second: Int
    """Cells each half keeps, however far the divider is dragged."""
    var side_by_side: Bool
    """Last layout's orientation: halves left / right (divider a column)
    or top / bottom (divider a row)."""
    var _area: Rect
    """Last layout's area; ``Rect.empty`` when nothing was laid out."""
    var _div: Int
    """Last layout's divider column (side by side) or row (stacked)."""
    var dragging: Bool
    var _grab: Int
    """Pointer's offset from the divider when the drag started, so the
    divider doesn't jump to the pointer."""
    var _changed: Bool

    def __init__(
        out self, fraction: Int = 500, min_first: Int = 1,
        min_second: Int = 1,
    ):
        self.fraction = fraction
        self.default_fraction = fraction
        self.min_first = min_first
        self.min_second = min_second
        self.side_by_side = True
        self._area = Rect.empty()
        self._div = 0
        self.dragging = False
        self._grab = 0
        self._changed = False

    def layout(mut self, area: Rect, side_by_side: Bool) -> Tuple[Rect, Rect]:
        """The two halves of ``area`` (left / top first). Too small an area
        for a divider gives it all to the first half."""
        self.side_by_side = side_by_side
        self._area = area
        var span = area.width() if side_by_side else area.height()
        var lo = area.a.x if side_by_side else area.a.y
        if span < 3:
            self._area = Rect.empty()
            return (area, Rect.empty())
        var first = self._first_size(span)
        self._div = lo + first
        if side_by_side:
            return (
                Rect(area.a.x, area.a.y, self._div, area.b.y),
                Rect(self._div + 1, area.a.y, area.b.x, area.b.y),
            )
        return (
            Rect(area.a.x, area.a.y, area.b.x, self._div),
            Rect(area.a.x, self._div + 1, area.b.x, area.b.y),
        )

    def _first_size(self, span: Int) -> Int:
        """Cells of the first half for an area ``span`` cells across (the
        divider takes one)."""
        var avail = span - 1
        var first = (avail * self.fraction + SPLIT_SCALE // 2) // SPLIT_SCALE
        # Minimums give way, the second's first, when the area is too
        # small for both.
        first = min(first, avail - min(self.min_second, avail - 1))
        first = max(first, min(self.min_first, avail - 1))
        return max(1, min(first, avail - 1))

    def hide(mut self):
        """Not on screen this frame: nothing to hit."""
        self._area = Rect.empty()
        self.dragging = False

    def divider_rect(self) -> Rect:
        if self._area.is_empty():
            return Rect.empty()
        if self.side_by_side:
            return Rect(self._div, self._area.a.y, self._div + 1, self._area.b.y)
        return Rect(self._area.a.x, self._div, self._area.b.x, self._div + 1)

    def on_divider(self, pos: Point) -> Bool:
        return self.divider_rect().contains(pos)

    def paint(self, mut canvas: Canvas):
        """The divider in cells, or — when the host draws chrome
        (``canvas.host_widgets``: the macOS-style and Mac OS 9 looks) — a
        ``HOST_SPLIT`` item over blank cells, which still take the mouse."""
        var r = self.divider_rect()
        if r.is_empty():
            return
        if canvas.host_widgets:
            var blank = Attr(PANE_FG, PANE_BG)
            for y in range(r.a.y, r.b.y):
                for x in range(r.a.x, r.b.x):
                    canvas.set(x, y, Cell(String(" "), blank))
            canvas.add_host_item(HostItem(
                HOST_SPLIT,
                (r.a.x - canvas.origin.x) * SCALE_ONE,
                (r.a.y - canvas.origin.y) * SCALE_ONE,
                r.width() * SCALE_ONE, r.height() * SCALE_ONE,
                self.side_by_side, self.dragging, 0, 0, blank, 0,
            ))
            return
        var attr = Attr(BORDER_FOCUS if self.dragging else PANE_FG, PANE_BG)
        var glyph = String("│") if self.side_by_side else String("─")
        for y in range(r.a.y, r.b.y):
            for x in range(r.a.x, r.b.x):
                canvas.set(x, y, Cell(glyph, attr))

    def pointer_shape(self, pos: Point) -> String:
        if self.dragging or self.on_divider(pos):
            return String("ew-resize") if self.side_by_side \
                else String("ns-resize")
        return String("")

    def take_changed(mut self) -> Bool:
        var c = self._changed
        self._changed = False
        return c

    def handle_mouse(mut self, event: Event) -> Bool:
        """True when ``event`` was the divider's: a press on it, a double
        click, or any event of a drag."""
        if event.kind != EVENT_MOUSE:
            return False
        if self.dragging:
            if event.motion:
                self._drag_to(event.pos)
            elif not event.pressed:
                self.dragging = False
                self._changed = True
            return True
        if event.button != MOUSE_BUTTON_LEFT or not event.pressed \
                or event.motion or not self.on_divider(event.pos):
            return False
        if event.click_count >= 2:
            if self.fraction != self.default_fraction:
                self.fraction = self.default_fraction
                self._changed = True
            return True
        self.dragging = True
        var at = event.pos.x if self.side_by_side else event.pos.y
        self._grab = at - self._div
        return True

    def _drag_to(mut self, pos: Point):
        var lo = self._area.a.x if self.side_by_side else self._area.a.y
        var span = self._area.width() if self.side_by_side \
            else self._area.height()
        if span < 3:
            return
        var at = (pos.x if self.side_by_side else pos.y) - self._grab
        var first = at - lo
        var avail = span - 1
        first = max(min(self.min_first, avail - 1), min(first, avail - min(self.min_second, avail - 1)))
        self.fraction = max(1, min(
            SPLIT_SCALE - 1, (first * SPLIT_SCALE + avail // 2) // avail,
        ))
        self._div = lo + self._first_size(span)
