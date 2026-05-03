"""Per-window tab strip rendered above the status bar.

One tab per open window in display order; the focused window's tab is
reverse-video so it stands out at a glance. A left-button click on a
tab returns its window index so the host can promote that window to
the top of the z-order. The strip clips to the screen width — tabs
that don't fit are silently dropped on the right.
"""

from std.collections.list import List

from .canvas import Canvas
from .colors import Attr, BLACK, BLUE, LIGHT_GRAY, WHITE
from .events import Event, EVENT_MOUSE, MOUSE_BUTTON_LEFT
from .geometry import Point, Rect


@fieldwise_init
struct TabBarItem(ImplicitlyCopyable, Movable):
    """One painted tab. ``window_idx`` is the caller-supplied index
    routed back through ``hit_test`` on click — typically the window
    manager's array index, but we don't care what it represents."""
    var label: String
    var window_idx: Int


@fieldwise_init
struct _TabHit(ImplicitlyCopyable, Movable):
    var a_x: Int
    var b_x: Int
    var window_idx: Int


struct TabBar(Movable):
    var _hits: List[_TabHit]    # captured by ``paint`` for ``hit_test``

    fn __init__(out self):
        self._hits = List[_TabHit]()

    fn paint(
        mut self,
        mut canvas: Canvas,
        rect: Rect,
        items: List[TabBarItem],
        active_idx: Int,
    ):
        """Paint ``items`` across ``rect`` (typically a single row).
        ``active_idx`` is the window index of the focused tab (or -1
        for none). Pass an empty rect to paint nothing — the host
        decides when the bar is visible."""
        self._hits = List[_TabHit]()
        if rect.width() <= 0 or rect.height() <= 0:
            return
        var bg = Attr(BLACK, LIGHT_GRAY)
        var active_attr = Attr(WHITE, BLUE)
        var y = rect.a.y
        canvas.fill(rect, String(" "), bg)
        var x = rect.a.x + 1
        var max_x = rect.b.x - 1
        for i in range(len(items)):
            if x >= max_x:
                break
            var label = String(" ") + items[i].label + String(" ")
            var w = len(label.as_bytes())
            var attr: Attr
            if items[i].window_idx == active_idx:
                attr = active_attr
            else:
                attr = bg
            _ = canvas.put_text(Point(x, y), label, attr, max_x)
            # Cap the recorded hit-rect at ``max_x`` so a tab that
            # was clipped on the right doesn't claim cells it didn't
            # actually paint.
            var end = x + w
            if end > max_x:
                end = max_x
            self._hits.append(_TabHit(x, end, items[i].window_idx))
            x = end + 1

    fn hit_test(self, pos: Point, rect: Rect) -> Int:
        """Return the window index at ``pos``, or -1 if no tab was hit."""
        if rect.width() <= 0 or rect.height() <= 0:
            return -1
        if pos.y < rect.a.y or pos.y >= rect.b.y:
            return -1
        for i in range(len(self._hits)):
            var h = self._hits[i]
            if h.a_x <= pos.x and pos.x < h.b_x:
                return h.window_idx
        return -1

    fn handle_mouse(self, event: Event, rect: Rect) -> Int:
        """Match-on-press click routing. Returns the clicked window
        index or -1 when the event missed every tab."""
        if event.kind != EVENT_MOUSE:
            return -1
        if event.button != MOUSE_BUTTON_LEFT or not event.pressed:
            return -1
        if event.motion:
            return -1
        return self.hit_test(event.pos, rect)
