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

Two modes, one implementation. ``ListBox()`` is single-select: the
caret row (``selected``) *is* the selection and modifiers are ignored.
``ListBox(multi=True)`` is a Windows extended-selection list box — the
single-select behavior is exactly what that reduces to with no
modifiers and no mask:

* Click selects only that row and sets the anchor; Ctrl/Cmd-click
  toggles it (and re-anchors); Shift-click selects anchor..row;
  Ctrl+Shift-click adds anchor..row to what was already selected.
  Pressing and dragging selects anchor..row live and auto-scrolls past
  the edges.
* Up / Down / PageUp / PageDown / Home / End select only the new caret
  row; with Shift they select anchor..caret; with Ctrl/Cmd they move
  the caret alone and leave the selection; Ctrl+Shift adds the range.
* Space selects only the caret row, Ctrl+Space toggles it, Shift+Space
  selects anchor..caret. Ctrl/Cmd+A selects everything.
* The caret row is marked ``►`` in the left gutter and the Shift-range
  anchor ``◆`` (while focused), so what a Shift-click or Shift-arrow
  will extend from is always visible.
* The wheel scrolls three rows and never touches the selection.

Mouse: ``handle_mouse_press`` consumes wheel scrolls inside ``bounds``
and left-press to select; ``handle_mouse_drag`` takes the drag motion
and the release that follows a press. Other events are not the
widget's business — pass them through. Keyboard navigation is
``handle_nav_key`` and only fires when the caller passes the key
through (so the host can gate on focus first).

Selection is by row *index*. A host whose rows move (re-sorting) must
re-apply the selection with ``set_selection`` after the move.
"""

from std.collections.list import List

from .canvas import Canvas
from .colors import Attr, BLACK, BLUE, GREEN, WHITE
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_DOWN, KEY_END, KEY_HOME, KEY_PAGEDOWN, KEY_PAGEUP, KEY_UP,
    KEY_SPACE, MOD_CTRL, MOD_META, MOD_NONE, MOD_SHIFT,
    MOUSE_BUTTON_LEFT, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .geometry import Point, Rect
from .painter import Painter
from .picker_input import scroll_to_reveal
from .scrollbar import ScrollBarArea


def clamp_list_scroll(
    scroll: Int, selected: Int, last_snap: Int, visible: Int, count: Int,
) -> Int:
    """A list's scroll offset for this paint. Snaps the selection into
    view only when it changed since the last paint (``last_snap``) — so
    the wheel can move the viewport without the next paint yanking it
    back — then clamps to ``[0, count - visible]``."""
    var s = scroll
    if selected >= 0 and selected != last_snap:
        s = scroll_to_reveal(s, selected, visible)
    return max(0, min(s, max(count - visible, 0)))


def paint_list_rows(
    mut canvas: Canvas, painter: Painter, bounds: Rect, first: Int,
    rows: List[String], selected: Int, focused: Bool, body_attr: Attr,
    indent: Int = 1,
):
    """Paint ``rows`` — the labels of items ``first``, ``first + 1``, … —
    one per line from the top of ``bounds``. The ``selected`` item's line
    is filled edge to edge: white-on-blue while the list has focus,
    black-on-green otherwise. The caller fills the body."""
    var marks = List[Bool]()
    for r in range(len(rows)):
        marks.append(first + r == selected)
    paint_list_rows_marked(
        canvas, painter, bounds, rows, marks, -1, -1, focused,
        body_attr, indent,
    )


def paint_list_rows_marked(
    mut canvas: Canvas, painter: Painter, bounds: Rect, rows: List[String],
    marks: List[Bool], caret_row: Int, anchor_row: Int, focused: Bool,
    body_attr: Attr, indent: Int = 1,
):
    """Like ``paint_list_rows`` for a multi-selection: ``marks[r]`` says
    whether visible row ``r`` is selected, and ``caret_row`` (visible-row
    index, or negative for none) gets a ``►`` in the left gutter while
    the list has focus — the stand-in for Windows' dotted focus rect.
    ``anchor_row`` (same convention) gets a ``◆`` there, so the fixed end
    of a Shift range is visible; the caret's ``►`` wins when they share
    a row."""
    for r in range(min(len(rows), bounds.height())):
        var y = bounds.a.y + r
        var attr = body_attr
        if marks[r]:
            attr = Attr(WHITE, BLUE) if focused else Attr(BLACK, GREEN)
            painter.fill(
                canvas, Rect(bounds.a.x, y, bounds.b.x, y + 1), String(" "),
                attr,
            )
        if focused and r == caret_row:
            _ = painter.put_text(
                canvas, Point(bounds.a.x, y), String("►"), attr,
            )
        elif focused and r == anchor_row:
            _ = painter.put_text(
                canvas, Point(bounds.a.x, y), String("◆"), attr,
            )
        _ = painter.put_text(
            canvas, Point(bounds.a.x + indent, y), rows[r], attr,
        )


comptime _KEY_A = UInt32(0x61)
comptime _KEY_A_UPPER = UInt32(0x41)
comptime _WHEEL_ROWS = 3
comptime _DEFAULT_PAGE = 10


struct ListBox(Copyable, Movable):
    """Scrollable, selectable list. State is the caret, the selection
    and the scroll offset — the items themselves stay on the host
    dialog and are passed in on each paint."""
    var selected: Int
    """The caret row: ``-1`` for none (e.g. when the list is empty). In
    single-select mode this is the whole selection."""
    var multi: Bool
    """True for the Windows extended-selection behavior (see the module
    docstring); False for plain single-select."""
    var _anchor: Int
    """Fixed end of a Shift range."""
    var _mask: List[Bool]
    """``_mask[i]``: row ``i`` is selected. Multi mode only, lazily sized
    to the host's item count."""
    var _base: List[Bool]
    """The selection as it stood when the anchor was last set. A Ctrl+
    Shift range is ``_base`` plus anchor..caret, so shrinking the range
    gives back only the rows the range itself added."""
    var _anchor_on: Bool
    """Whether the anchor row was left selected by the click / toggle
    that set it. A Ctrl+Shift range takes this state: Ctrl-click a row
    *off* inside a selected block, Ctrl+Shift-click further on, and the
    range is deselected rather than selected (Win32 behavior)."""
    var _scroll: Int
    var _last_scroll_sel: Int
    """Last ``selected`` value snapped into view by paint. Snap-to-
    selection only fires when this differs from ``selected`` — so the
    wheel can move the viewport without the next paint snapping it
    back to the selected row."""
    var _dragging: Bool
    var _drag_keeps_base: Bool
    var _count: Int
    """Item count at the last ``prepare``: whether the bar is drawn."""
    var _bar: ScrollBarArea

    def __init__(out self, multi: Bool = False):
        self.selected = -1
        self.multi = multi
        self._anchor = -1
        self._mask = List[Bool]()
        self._base = List[Bool]()
        self._anchor_on = True
        self._scroll = 0
        self._last_scroll_sel = -2
        self._dragging = False
        self._drag_keeps_base = False
        self._count = 0
        self._bar = ScrollBarArea()

    def reset(mut self):
        """Forget selection and scroll state; call when the host
        clears its items list (open / close, replace-all)."""
        self.selected = -1
        self._anchor = -1
        self._mask = List[Bool]()
        self._base = List[Bool]()
        self._anchor_on = True
        self._scroll = 0
        self._last_scroll_sel = -2
        self._dragging = False
        self._bar.hide()

    # --- selection state --------------------------------------------------

    def _fit(mut self, n: Int):
        while len(self._mask) < n:
            self._mask.append(False)
        while len(self._mask) > n:
            _ = self._mask.pop()
        while len(self._base) < n:
            self._base.append(False)
        while len(self._base) > n:
            _ = self._base.pop()

    def is_selected(self, i: Int) -> Bool:
        if not self.multi:
            return i >= 0 and i == self.selected
        return 0 <= i and i < len(self._mask) and self._mask[i]

    def selected_count(self) -> Int:
        if not self.multi:
            return 1 if self.selected >= 0 else 0
        var n = 0
        for i in range(len(self._mask)):
            if self._mask[i]:
                n += 1
        return n

    def selected_indices(self) -> List[Int]:
        """Selected rows, ascending."""
        var out = List[Int]()
        if not self.multi:
            if self.selected >= 0:
                out.append(self.selected)
            return out^
        for i in range(len(self._mask)):
            if self._mask[i]:
                out.append(i)
        return out^

    def anchor(self) -> Int:
        """Fixed end of the current Shift range, or ``-1``."""
        return self._anchor

    def set_selected(mut self, idx: Int):
        """Select only ``idx`` (caret and anchor too). ``-1`` clears."""
        self.selected = idx
        self._anchor = idx
        self._anchor_on = True
        for i in range(len(self._mask)):
            self._mask[i] = False
            self._base[i] = False
        if self.multi and 0 <= idx:
            self._fit(max(len(self._mask), idx + 1))
            self._mask[idx] = True

    def set_selection(
        mut self, rows: List[Int], caret: Int, anchor: Int, item_count: Int,
    ):
        """Replace the selection wholesale — what a host does after its
        rows moved. Out-of-range rows are dropped."""
        self.selected = caret
        self._anchor = anchor
        self._mask = List[Bool]()
        self._base = List[Bool]()
        self._fit(item_count)
        for k in range(len(rows)):
            if 0 <= rows[k] and rows[k] < item_count:
                self._mask[rows[k]] = True
        for i in range(item_count):
            self._base[i] = self._mask[i]
        self._anchor_on = 0 <= anchor and anchor < item_count \
            and self._mask[anchor]

    def clear_selection(mut self):
        for i in range(len(self._mask)):
            self._mask[i] = False
            self._base[i] = False

    def select_all(mut self, item_count: Int):
        if not self.multi:
            return
        self._fit(item_count)
        for i in range(item_count):
            self._mask[i] = True
            self._base[i] = True
        if self._anchor < 0 or self._anchor >= item_count:
            self._anchor = 0 if item_count > 0 else -1
        self._anchor_on = True
        if self.selected < 0 and item_count > 0:
            self.selected = 0

    def _collapse_to(mut self, i: Int, n: Int):
        """Select only row ``i``; it becomes caret and anchor."""
        self.selected = i
        self._anchor = i
        self._anchor_on = True
        if not self.multi:
            return
        self._fit(n)
        for k in range(n):
            self._mask[k] = False
            self._base[k] = False
        if 0 <= i and i < n:
            self._mask[i] = True

    def _toggle(mut self, i: Int, n: Int):
        self.selected = i
        self._anchor = i
        self._fit(n)
        if 0 <= i and i < n:
            self._mask[i] = not self._mask[i]
            self._anchor_on = self._mask[i]
        for k in range(n):
            self._base[k] = self._mask[k]

    def _extend_to(mut self, i: Int, n: Int, keep_base: Bool):
        """Select anchor..``i``. With ``keep_base`` the rows selected when
        the anchor was set stay as they were, and the range takes the
        anchor's state — selecting, or deselecting if the anchor was
        toggled off."""
        if self._anchor < 0 or self._anchor >= n:
            if 0 <= self.selected and self.selected < n:
                self._anchor = self.selected
            else:
                self._anchor = i
        self.selected = i
        self._fit(n)
        var lo = min(self._anchor, i)
        var hi = max(self._anchor, i)
        var range_on = self._anchor_on or not keep_base
        for k in range(n):
            if lo <= k and k <= hi:
                self._mask[k] = range_on
            else:
                self._mask[k] = keep_base and self._base[k]

    def _go(mut self, target: Int, mods: UInt8, n: Int):
        """Move the caret to ``target`` the way an arrow key does: only
        the caret with Ctrl/Cmd, a range with Shift, else collapse."""
        var t = max(0, min(target, n - 1))
        if not self.multi:
            self.selected = t
            return
        var shift = (mods & MOD_SHIFT) != 0
        var ctrl = (mods & (MOD_CTRL | MOD_META)) != 0
        if shift:
            self._extend_to(t, n, ctrl)
        elif ctrl:
            self.selected = t
        else:
            self._collapse_to(t, n)

    def move_selection(mut self, delta: Int, item_count: Int) -> Bool:
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
        self._go(s, MOD_NONE, item_count)
        return True

    # --- scroll -----------------------------------------------------------

    def scroll(self) -> Int:
        """The first visible row as of the last paint or scroll."""
        return self._scroll

    def scroll_to(mut self, row: Int):
        """Put ``row`` at the top of the view (clamped at the next paint),
        without the next paint snapping back to the selection."""
        self._scroll = max(row, 0)
        self._last_scroll_sel = self.selected

    def scrolling(self) -> Bool:
        """A scroll-bar thumb drag is in progress: every mouse event is
        the list's until the release."""
        return self._bar.dragging

    # --- paint ------------------------------------------------------------

    def prepare(mut self, bounds: Rect, item_count: Int) -> Int:
        """Settle the scroll offset for this paint and return it — the
        first visible row. A host with many or costly rows calls this,
        builds labels for just ``bounds.height()`` rows from there, and
        hands them to ``paint_rows``."""
        var visible = bounds.height()
        self._count = item_count
        if visible <= 0:
            return 0
        self._scroll = clamp_list_scroll(
            self._scroll, self.selected, self._last_scroll_sel, visible,
            item_count,
        )
        self._last_scroll_sel = self.selected
        return self._scroll

    def paint_rows(
        mut self,
        mut canvas: Canvas,
        bounds: Rect,
        rows: List[String],
        focused: Bool,
        body_attr: Attr,
    ):
        """Paint the labels of rows ``scroll``, ``scroll + 1``, … (what
        ``prepare`` returned as first). All drawing is clipped to
        ``bounds``. When the items don't fit, a scroll bar takes the
        right column and the rows the rest."""
        var painter = Painter(bounds)
        painter.fill(canvas, bounds, String(" "), body_attr)
        if bounds.height() <= 0:
            self._bar.hide()
            return
        var rows_rect = bounds
        if ScrollBarArea.overflows(bounds, self._count):
            rows_rect = Rect(bounds.a.x, bounds.a.y, bounds.b.x - 1, bounds.b.y)
        var marks = List[Bool]()
        for r in range(len(rows)):
            marks.append(self.is_selected(self._scroll + r))
        var caret_row = -1
        var anchor_row = -1
        if self.multi:
            if self.selected >= 0:
                caret_row = self.selected - self._scroll
            if self._anchor >= 0:
                anchor_row = self._anchor - self._scroll
        paint_list_rows_marked(
            canvas, Painter(rows_rect), rows_rect, rows, marks, caret_row,
            anchor_row, focused, body_attr,
        )
        self._bar.paint(canvas, bounds, self._count, self._scroll, body_attr)

    def paint(
        mut self,
        mut canvas: Canvas,
        bounds: Rect,
        items: List[String],
        focused: Bool,
        body_attr: Attr,
    ):
        """Paint the list. ``items[i]`` is rendered with a one-cell
        left indent on row ``bounds.a.y + (i - scroll)``; selected rows
        fill the full width of ``bounds`` first so the highlight
        reaches the right edge.

        All drawing goes through a ``Painter(bounds)`` constructed
        here. Items whose text would extend past the right edge are
        truncated — they cannot reach the surrounding container.
        """
        var visible = bounds.height()
        var first = self.prepare(bounds, len(items))
        var rows = List[String]()
        for idx in range(first, min(first + max(visible, 0), len(items))):
            rows.append(items[idx])
        self.paint_rows(canvas, bounds, rows, focused, body_attr)

    def paint_empty_hint(
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

    # --- mouse ------------------------------------------------------------

    def handle_mouse_press(
        mut self, event: Event, bounds: Rect, item_count: Int,
    ) -> Bool:
        """Consume mouse presses that target the list. Wheel scrolls
        when the cursor is over ``bounds``; left-press inside picks
        the row under the cursor, or works the scroll bar. Returns True
        iff consumed."""
        if event.kind != EVENT_MOUSE:
            return False
        var s = self._bar.handle_mouse(event)
        if s >= 0:
            self._scroll = s
            return True
        if event.button == MOUSE_WHEEL_UP:
            if bounds.contains(event.pos):
                self._scroll = max(self._scroll - _WHEEL_ROWS, 0)
                return True
            return False
        if event.button == MOUSE_WHEEL_DOWN:
            if bounds.contains(event.pos):
                var max_scroll = max(item_count - bounds.height(), 0)
                self._scroll = min(self._scroll + _WHEEL_ROWS, max_scroll)
                return True
            return False
        if event.button != MOUSE_BUTTON_LEFT or not event.pressed \
                or event.motion:
            return False
        if not bounds.contains(event.pos):
            return False
        var idx = self._scroll + (event.pos.y - bounds.a.y)
        if idx < 0 or idx >= item_count:
            return True
        if not self.multi:
            self.selected = idx
            self._dragging = True
            return True
        var shift = (event.mods & MOD_SHIFT) != 0
        var ctrl = (event.mods & (MOD_CTRL | MOD_META)) != 0
        self._dragging = shift or not ctrl
        self._drag_keeps_base = shift and ctrl
        if shift:
            self._extend_to(idx, item_count, ctrl)
        elif ctrl:
            self._toggle(idx, item_count)
        else:
            self._collapse_to(idx, item_count)
        return True

    def handle_mouse_drag(
        mut self, event: Event, bounds: Rect, item_count: Int,
    ) -> Bool:
        """Follow a press-and-drag started by ``handle_mouse_press``:
        the selection tracks the row under the pointer (anchor..row in
        multi mode), and dragging above or below ``bounds`` scrolls a
        row per event. The release ends the drag (and a scroll-bar
        thumb drag the same way). Returns True iff the event belonged to
        a drag in progress."""
        if self._bar.dragging:
            var s = self._bar.handle_mouse(event)
            if s >= 0:
                self._scroll = s
            return True
        if event.kind != EVENT_MOUSE or event.button != MOUSE_BUTTON_LEFT \
                or not self._dragging:
            return False
        if not event.pressed:
            self._dragging = False
            return True
        if not event.motion:
            return False  # a fresh press: ``handle_mouse_press``'s
        if item_count <= 0:
            return True
        var visible = bounds.height()
        var max_scroll = max(item_count - visible, 0)
        var idx: Int
        if event.pos.y < bounds.a.y:
            self._scroll = max(self._scroll - 1, 0)
            idx = self._scroll
        elif event.pos.y >= bounds.b.y:
            self._scroll = min(self._scroll + 1, max_scroll)
            idx = self._scroll + visible - 1
        else:
            idx = self._scroll + (event.pos.y - bounds.a.y)
        idx = max(0, min(idx, item_count - 1))
        if self.multi:
            self._extend_to(idx, item_count, self._drag_keeps_base)
        else:
            self.selected = idx
        return True

    # --- keyboard ---------------------------------------------------------

    def handle_nav_key(
        mut self, event: Event, item_count: Int, page: Int = _DEFAULT_PAGE,
    ) -> Bool:
        """Handle Up / Down / PageUp / PageDown / Home / End on the
        list — and, in multi mode, Space and Ctrl/Cmd+A. Returns True
        iff the key was one of those (consumed) regardless of whether
        selection actually moved (e.g. Down at the last item still
        consumes the key).

        The host should call this only when the list has focus."""
        if event.kind != EVENT_KEY:
            return False
        var k = event.key
        var n = item_count
        var mods = event.mods
        if k == KEY_UP:
            if n > 0:
                self._go(max(self.selected, 1) - 1, mods, n)
            return True
        if k == KEY_DOWN:
            if n > 0:
                self._go(self.selected + 1, mods, n)
            return True
        if k == KEY_PAGEUP:
            if n > 0:
                self._go(max(self.selected, 0) - max(page, 1), mods, n)
            return True
        if k == KEY_PAGEDOWN:
            if n > 0:
                self._go(self.selected + max(page, 1), mods, n)
            return True
        if k == KEY_HOME:
            if n > 0:
                self._go(0, mods, n)
            return True
        if k == KEY_END:
            if n > 0:
                self._go(n - 1, mods, n)
            return True
        if not self.multi:
            return False
        if k == KEY_SPACE:
            if 0 <= self.selected and self.selected < n:
                if (mods & (MOD_CTRL | MOD_META)) != 0:
                    self._toggle(self.selected, n)
                elif (mods & MOD_SHIFT) != 0:
                    self._extend_to(self.selected, n, False)
                else:
                    self._collapse_to(self.selected, n)
            return True
        if (k == _KEY_A or k == _KEY_A_UPPER) \
                and (mods & (MOD_CTRL | MOD_META)) != 0:
            self.select_all(n)
            return True
        return False
