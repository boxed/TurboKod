"""Standard scrollable, selectable list widget.

The framework's reusable list control: a vertically scrolling list of
text rows with a moveable selection. Replaces the hand-rolled
``_paint_list`` / ``_list_scroll`` / ``_last_scroll_sel`` triple that
had been duplicated across the settings, targets, and language
dialogs — each copy with the same bug potential (paint outside the
list rect when an item is too long).

The widget guarantees, by construction, that it never paints outside
its ``bounds`` rect:

* ``paint`` builds its own ``Painter(bounds)`` instead of using a
  caller-supplied painter that might be clipped to something wider.
  A row whose text overflows is truncated at the right edge.
* All row fills and text writes go through that painter; ``set`` /
  ``put_text`` / ``fill`` reject anything outside.

That's the property the host repo relies on: a control's ``bounds`` is
authoritative, full stop. Callers don't need to remember to pre-clip
input, and no overlong item, label, or status indicator can leak into
the surrounding dialog chrome.

Item ownership stays with the host dialog — the host already needs the
``List[String]`` for save/cancel logic and per-row side effects when
selection changes. ``paint`` borrows it; the widget just tracks
selection and scroll.

Coloring is fixed to the toolkit's standard list palette:

* Body: ``body_attr`` (the host picks; usually ``Attr(BLACK, CYAN)``
  inside a light-gray dialog so the list visibly separates from the
  surrounding panel).
* Selected, focused: ``Attr(WHITE, BLUE)`` — same as a focused button.
* Selected, unfocused: ``Attr(BLACK, GREEN)`` — same dimmed-selection
  used by the rest of the framework when an off-focus list still needs
  to show which entry the form on the right is editing.

Mouse: ``handle_mouse_press`` consumes wheel scrolls inside ``bounds``
and left-press to select. Motion / release / non-press wheel events
are not the widget's business — pass them through. Keyboard navigation
(Up / Down / PageUp / PageDown / Home / End) is provided by
``handle_nav_key`` and only fires when the caller passes the key
through (so the host can gate on focus first).
"""

from std.collections.list import List

from .canvas import Canvas
from .cell import Cell
from .colors import Attr, BLACK, BLUE, GREEN, WHITE
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_DOWN, KEY_END, KEY_HOME, KEY_PAGEDOWN, KEY_PAGEUP, KEY_UP,
    MOUSE_BUTTON_LEFT, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .geometry import Point, Rect
from .painter import Painter


struct ListBox(Copyable, Movable):
    """Scrollable, selectable list. State is just selection and scroll
    offset — the items themselves stay on the host dialog and are
    passed in on each paint."""
    var selected: Int
    """Index of the currently-selected row, or ``-1`` for no
    selection (e.g. when the list is empty)."""
    var _scroll: Int
    var _last_scroll_sel: Int
    """Last ``selected`` value snapped into view by paint. Snap-to-
    selection only fires when this differs from ``selected`` — so the
    wheel can move the viewport without the next paint snapping it
    back to the selected row."""

    fn __init__(out self):
        self.selected = -1
        self._scroll = 0
        self._last_scroll_sel = -2

    fn reset(mut self):
        """Forget selection and scroll state; call when the host
        clears its items list (open / close, replace-all)."""
        self.selected = -1
        self._scroll = 0
        self._last_scroll_sel = -2

    fn set_selected(mut self, idx: Int):
        self.selected = idx

    fn move_selection(mut self, delta: Int, item_count: Int) -> Bool:
        """Bump selection by ``delta`` rows, clamping to
        ``[0, item_count)``. Returns True iff selection moved."""
        if item_count == 0:
            return False
        var s = self.selected + delta
        if s < 0:
            s = 0
        if s >= item_count:
            s = item_count - 1
        if s == self.selected:
            return False
        self.selected = s
        return True

    fn paint(
        mut self,
        mut canvas: Canvas,
        bounds: Rect,
        items: List[String],
        focused: Bool,
        body_attr: Attr,
    ):
        """Paint the list. ``items[i]`` is rendered with a one-cell
        left indent on row ``bounds.a.y + (i - scroll)``; the selected
        row fills the full width of ``bounds`` first so the highlight
        reaches the right edge.

        All drawing goes through a ``Painter(bounds)`` constructed
        here. Items whose text would extend past the right edge are
        truncated — they cannot reach the surrounding container.
        """
        var painter = Painter(bounds)
        painter.fill(canvas, bounds, String(" "), body_attr)
        var visible = bounds.height()
        if visible <= 0:
            return
        if self.selected >= 0 and self.selected != self._last_scroll_sel:
            if self.selected < self._scroll:
                self._scroll = self.selected
            elif self.selected >= self._scroll + visible:
                self._scroll = self.selected - visible + 1
        self._last_scroll_sel = self.selected
        if self._scroll < 0:
            self._scroll = 0
        var max_scroll = len(items) - visible
        if max_scroll < 0:
            max_scroll = 0
        if self._scroll > max_scroll:
            self._scroll = max_scroll
        for r in range(visible):
            var idx = self._scroll + r
            if idx >= len(items):
                break
            var attr = body_attr
            if idx == self.selected:
                attr = (
                    Attr(WHITE, BLUE) if focused else Attr(BLACK, GREEN)
                )
                painter.fill(
                    canvas,
                    Rect(
                        bounds.a.x, bounds.a.y + r,
                        bounds.b.x, bounds.a.y + r + 1,
                    ),
                    String(" "), attr,
                )
            _ = painter.put_text(
                canvas, Point(bounds.a.x + 1, bounds.a.y + r),
                items[idx], attr,
            )

    fn paint_empty_hint(
        self,
        mut canvas: Canvas,
        bounds: Rect,
        hint: String,
        attr: Attr,
    ):
        """Paint a single-line hint inside ``bounds`` for use when the
        host has no items to show. Goes through the bounds-clipped
        painter for the same overflow guarantee as ``paint``."""
        var painter = Painter(bounds)
        _ = painter.put_text(
            canvas, Point(bounds.a.x + 1, bounds.a.y), hint, attr,
        )

    fn handle_mouse_press(
        mut self, event: Event, bounds: Rect, item_count: Int,
    ) -> Bool:
        """Consume mouse presses that target the list. Wheel scrolls
        when the cursor is over ``bounds``; left-press inside picks
        the row under the cursor. Returns True iff consumed."""
        if event.kind != EVENT_MOUSE:
            return False
        if event.button == MOUSE_WHEEL_UP:
            if bounds.contains(event.pos):
                self._scroll -= 1
                if self._scroll < 0:
                    self._scroll = 0
                return True
            return False
        if event.button == MOUSE_WHEEL_DOWN:
            if bounds.contains(event.pos):
                var max_scroll = item_count - bounds.height()
                if max_scroll < 0:
                    max_scroll = 0
                self._scroll += 1
                if self._scroll > max_scroll:
                    self._scroll = max_scroll
                return True
            return False
        if event.button != MOUSE_BUTTON_LEFT or not event.pressed \
                or event.motion:
            return False
        if not bounds.contains(event.pos):
            return False
        var idx = self._scroll + (event.pos.y - bounds.a.y)
        if 0 <= idx and idx < item_count:
            self.selected = idx
        return True

    fn handle_nav_key(
        mut self, event: Event, item_count: Int,
    ) -> Bool:
        """Handle Up / Down / PageUp / PageDown / Home / End on the
        list. Returns True iff the key was a navigation key (consumed)
        regardless of whether selection actually moved (e.g. Down at
        the last item still consumes the key).

        The host should call this only when the list has focus."""
        if event.kind != EVENT_KEY:
            return False
        var k = event.key
        if k == KEY_UP:
            _ = self.move_selection(-1, item_count)
            return True
        if k == KEY_DOWN:
            _ = self.move_selection(1, item_count)
            return True
        if k == KEY_PAGEUP:
            _ = self.move_selection(-10, item_count)
            return True
        if k == KEY_PAGEDOWN:
            _ = self.move_selection(10, item_count)
            return True
        if k == KEY_HOME:
            if item_count > 0:
                self.selected = 0
            return True
        if k == KEY_END:
            if item_count > 0:
                self.selected = item_count - 1
            return True
        return False
