"""Per-window tab strip rendered above the status bar.

One tab per open window in display order; the focused window's tab is
reverse-video so it stands out at a glance. A left-button click on a
tab returns its window index so the host can promote that window to
the top of the z-order.

When the tabs don't fit, the strip scrolls: the focused tab is scrolled
into view whenever focus moves (or the tab list or the width changes),
the wheel (either axis) scrolls it by hand, and the margin cells at
either end turn into ``◄`` / ``►`` arrows that step a tab at a time.
"""

from std.collections.list import List

from .canvas import Canvas
from .painter import Painter
from .colors import Attr, BLACK, BLUE, GREEN, LIGHT_GRAY, LIGHT_GREEN, WHITE
from .events import (
    Event, EVENT_MOUSE, MOUSE_BUTTON_LEFT, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .geometry import Point, Rect
from .string_utils import display_columns


# A tab-bar mouse event that hit no tab but was the bar's own (an arrow,
# a wheel turn): the caller swallows it.
comptime TAB_BAR_CONSUMED = -2

# Columns a wheel notch scrolls.
comptime _WHEEL_COLS = 3


@fieldwise_init
struct TabBarItem(ImplicitlyCopyable, Movable):
    """One painted tab. ``window_idx`` is the caller-supplied index
    routed back through ``hit_test`` on click — typically the window
    manager's array index, but we don't care what it represents.
    ``dirty`` recolors the foreground to flag uncommitted changes —
    matches the ``*`` marker convention used on window borders."""
    var label: String
    var window_idx: Int
    var dirty: Bool


@fieldwise_init
struct _TabHit(ImplicitlyCopyable, Movable):
    var a_x: Int
    var b_x: Int
    var window_idx: Int


struct TabBar(Movable):
    var _hits: List[_TabHit]    # captured by ``paint`` for ``hit_test``
    # Columns of the tab row scrolled off the left.
    var scroll: Int
    # Content start / width of each tab, and the visible width, from the
    # last paint: what the arrows and the wheel scroll over.
    var _offsets: List[Int]
    var _widths: List[Int]
    var _avail: Int
    var _max_scroll: Int
    # What the last paint revealed for (focus, tab count, width); a
    # change scrolls the focused tab into view again. Between changes the user's scroll stands.
    var _last_active: Int
    var _last_count: Int
    var _last_avail: Int

    def __init__(out self):
        self._hits = List[_TabHit]()
        self.scroll = 0
        self._offsets = List[Int]()
        self._widths = List[Int]()
        self._avail = 0
        self._max_scroll = 0
        self._last_active = -1
        self._last_count = -1
        self._last_avail = -1

    def paint(
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
        var painter = Painter(rect)
        painter.fill(canvas, rect, String(" "), bg)
        # The row between the one-cell margins, which hold the arrows.
        var left = rect.a.x + 1
        var right = rect.b.x - 1
        var avail = right - left
        if avail <= 0:
            return
        # Lay the tabs out in content columns (one cell apart).
        var labels = List[String]()
        self._offsets = List[Int]()
        self._widths = List[Int]()
        var total = 0
        var active_pos = -1
        for i in range(len(items)):
            var label = String(" ") + items[i].label + String(" ")
            var w = display_columns(label)
            if i > 0:
                total += 1
            self._offsets.append(total)
            self._widths.append(w)
            total += w
            labels.append(label^)
            if items[i].window_idx == active_idx:
                active_pos = i
        self._avail = avail
        self._max_scroll = total - avail if total > avail else 0
        if active_idx != self._last_active \
                or len(items) != self._last_count \
                or avail != self._last_avail:
            self._last_active = active_idx
            self._last_count = len(items)
            self._last_avail = avail
            if active_pos >= 0:
                self._reveal(active_pos)
        self._clamp()
        var row = Painter(Rect(left, y, right, y + 1))
        for i in range(len(items)):
            var x = left + self._offsets[i] - self.scroll
            var end = x + self._widths[i]
            if end <= left:
                continue
            if x >= right:
                break
            var attr: Attr
            if items[i].window_idx == active_idx:
                attr = active_attr
                if items[i].dirty:
                    attr = attr.with_bg(GREEN)
            else:
                attr = bg
                if items[i].dirty:
                    attr = attr.with_bg(LIGHT_GREEN)
            _ = row.put_text(canvas, Point(x, y), labels[i], attr)
            # Record only the cells the tab actually painted.
            self._hits.append(_TabHit(
                max(x, left), min(end, right), items[i].window_idx,
            ))
        if self.scroll > 0:
            _ = painter.put_text(canvas, Point(rect.a.x, y), String("◄"), bg)
        if self.scroll < self._max_scroll:
            _ = painter.put_text(canvas, Point(right, y), String("►"), bg)

    def _reveal(mut self, pos: Int):
        """Scroll the least that brings tab ``pos`` wholly into view (its
        start, when it's wider than the bar)."""
        var a = self._offsets[pos]
        var b = a + self._widths[pos]
        if a < self.scroll or b - a > self._avail:
            self.scroll = a
        elif b > self.scroll + self._avail:
            self.scroll = b - self._avail
        self._clamp()

    def _clamp(mut self):
        if self.scroll > self._max_scroll:
            self.scroll = self._max_scroll
        if self.scroll < 0:
            self.scroll = 0

    def scroll_by(mut self, cols: Int) -> Bool:
        """Scroll ``cols`` columns (negative: left). True when it moved."""
        var before = self.scroll
        self.scroll += cols
        self._clamp()
        return self.scroll != before

    def _step(mut self, forward: Bool):
        """An arrow click: bring the next tab cut off on that side wholly
        into view."""
        var n = len(self._offsets)
        if forward:
            for i in range(n):
                if self._offsets[i] + self._widths[i] > self.scroll + self._avail:
                    self._reveal(i)
                    return
        else:
            var i = n - 1
            while i >= 0:
                if self._offsets[i] < self.scroll:
                    self._reveal(i)
                    return
                i -= 1

    def hit_test(self, pos: Point, rect: Rect) -> Int:
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

    def handle_mouse(mut self, event: Event, rect: Rect) -> Int:
        """Match-on-press click routing. Returns the clicked window
        index, ``TAB_BAR_CONSUMED`` for the bar's own scrolling (an
        arrow, a wheel turn over it), or -1 when the event missed."""
        if event.kind != EVENT_MOUSE:
            return -1
        if rect.width() <= 0 or rect.height() <= 0 or not rect.contains(event.pos):
            return -1
        if event.button == MOUSE_WHEEL_UP or event.button == MOUSE_WHEEL_DOWN:
            if event.pressed:
                _ = self.scroll_by(
                    -_WHEEL_COLS if event.button == MOUSE_WHEEL_UP else _WHEEL_COLS,
                )
            return TAB_BAR_CONSUMED
        if event.button != MOUSE_BUTTON_LEFT or not event.pressed:
            return -1
        if event.motion:
            return -1
        if event.pos.x == rect.a.x and self.scroll > 0:
            self._step(False)
            return TAB_BAR_CONSUMED
        if event.pos.x == rect.b.x - 1 and self.scroll < self._max_scroll:
            self._step(True)
            return TAB_BAR_CONSUMED
        return self.hit_test(event.pos, rect)
