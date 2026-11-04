"""One region of a view drawn in an area's own cells.

An area whose font has a size of its own (Settings ▸ Terminal / Debugger
font ▸ Size) lays out a grid of that font's cells in each region of a view
that paints in it: a ``Canvas`` of those cells, placed on the frame with
``Canvas.place_sub_grid``. A ``GridFrame`` is that region's bookkeeping.

The grid's coordinates are anchored at the region's top-left: grid cell
``(c, r)`` is ``(rect.a.x + c, rect.a.y + r)``. So a view paints the grid
canvas (whose ``origin`` is the corner) exactly as it would paint the
screen, keeps hit-testing what it painted in those coordinates, and maps a
mouse event into them with ``map``. At the screen's cell size the grid is
the region itself and ``map`` changes nothing.
"""

from .canvas import Canvas, SCALE_ONE
from .colors import Attr
from .events import Event
from .geometry import Point, Rect


@fieldwise_init
struct GridFrame(Copyable, ImplicitlyCopyable, Movable):
    var slot: UInt8
    var rect: Rect
    """The region, in screen cells."""
    var grid: Rect
    """The grid's cells in its own coordinates (anchored at ``rect.a``);
    the same as ``rect`` at the screen's cell size."""
    var scale_x: Int
    var scale_y: Int
    """The grid's cell in thousandths of a screen cell."""

    @staticmethod
    def empty(slot: UInt8) -> GridFrame:
        return GridFrame(slot, Rect.empty(), Rect.empty(), SCALE_ONE, SCALE_ONE)

    def begin(mut self, canvas: Canvas, rect: Rect, bg: Attr) -> Canvas:
        """Lay out the grid for ``rect`` and return its canvas, in this
        frame's font slot and cleared to ``bg``; hand it to ``end``."""
        var dims = canvas.sub_grid_size(self.slot, rect)
        var sc = canvas.scale_of(self.slot)
        self.rect = rect
        self.grid = Rect(rect.a.x, rect.a.y, rect.a.x + dims[0], rect.a.y + dims[1])
        self.scale_x = sc[0]
        self.scale_y = sc[1]
        var g = Canvas(dims[0], dims[1])
        g.origin = rect.a
        g.font = self.slot
        g.clear(bg)
        return g^

    def end(self, mut canvas: Canvas, var grid: Canvas):
        canvas.place_sub_grid(self.slot, self.rect, grid^)

    def contains(self, event: Event) -> Bool:
        """Whether ``event`` (in screen cells) is over the region."""
        return self.rect.contains(event.pos)

    def map(self, event: Event) -> Event:
        """``event`` with ``pos`` in the grid's coordinates, from its fine
        position; unchanged at the screen's cell size."""
        if self.scale_x == SCALE_ONE and self.scale_y == SCALE_ONE:
            return event
        if self.rect.is_empty():
            return event
        var f = event.fine_pos()
        var e = event
        e.pos = Point(
            self.rect.a.x + floor_div(f.x - self.rect.a.x * 1000, self.scale_x),
            self.rect.a.y + floor_div(f.y - self.rect.a.y * 1000, self.scale_y),
        )
        return e


def floor_div(a: Int, b: Int) -> Int:
    """``a / b`` rounded down, for ``b > 0`` (a drag past the region's
    top-left gives a negative ``a``)."""
    var d = max(1, b)
    if a >= 0:
        return a // d
    return -((-a + d - 1) // d)
