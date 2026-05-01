"""Inline dropdown / picker with a menu-style popup.

A single-row selector that fits where a text input would. When
collapsed it shows the current value with a ``▼`` indicator on the
right edge — the affordance that tells the user "this is a picker,
click me." Activating it (click, Enter, or Down) opens a popup list
of every option below the strip, painted in the same style as the
menu-bar dropdowns: light-gray body, green-highlighted row for the
candidate selection. Click an option (or Enter on a highlighted
row) to commit; Esc / click-outside cancels back to the original
value.

The widget owns its option list and the currently committed index.
For dialog use, the surrounding model (e.g. a ``RunTarget.debug_language``
string) stays canonical: callers ``set_value`` from the model before
each paint and read ``value()`` back after each event. Unknown
values are preserved — ``set_value`` with a string that isn't in
the option list appends it as a synthetic entry, so a config loaded
from disk never silently snaps to a different choice.

Painting is two-phase to support proper z-ordering: ``paint`` draws
the collapsed strip, ``paint_popup`` draws the popup list. The
host is responsible for calling ``paint_popup`` *after* every other
dialog widget so the popup overlays them — same pattern as
``MenuBar`` painting its bar before its dropdown.
"""

from std.collections.list import List

from .canvas import Canvas
from .cell import Cell
from .colors import Attr, BLACK, GREEN, LIGHT_GRAY, WHITE
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_DOWN, KEY_ENTER, KEY_ESC, KEY_PAGEDOWN, KEY_PAGEUP, KEY_UP,
    MOUSE_BUTTON_LEFT, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .geometry import Point, Rect


# Hit-test result codes for ``Dropdown.handle_mouse``.
comptime DROPDOWN_HIT_NONE     = -1
comptime DROPDOWN_HIT_BODY     = 1
"""Click landed on the collapsed strip — caller treats this as both
'set focus' and 'toggle open'."""
comptime DROPDOWN_HIT_POPUP    = 2
"""Click landed inside the open popup (selection or scroll); the
caller doesn't usually need to do anything beyond consuming the
event since the dropdown already updated its state."""
comptime DROPDOWN_HIT_OUTSIDE  = 3
"""Click landed outside the strip *and* outside the popup while
open. The dropdown closes itself; the caller should also stop
treating the event as having landed on the dropdown widget."""


# How many options a popup will show before scrolling.
comptime _MAX_POPUP_ROWS = 8


struct Dropdown(ImplicitlyCopyable, Movable):
    """One inline picker.

    ``options`` is the full set of selectable values, in display
    order. ``index`` is the currently committed slot. ``is_open``
    flips on activation, painting the popup; ``highlight`` is the
    candidate row inside the popup (committed only on Enter / click).
    """
    var options: List[String]
    var index: Int
    var is_open: Bool
    var highlight: Int
    var _scroll: Int

    fn __init__(out self, var options: List[String], index: Int = 0):
        self.options = options^
        self.index = index
        self.is_open = False
        self.highlight = 0
        self._scroll = 0
        self._clip_index()

    fn __copyinit__(out self, copy: Self):
        self.options = copy.options.copy()
        self.index = copy.index
        self.is_open = copy.is_open
        self.highlight = copy.highlight
        self._scroll = copy._scroll

    fn _clip_index(mut self):
        var n = len(self.options)
        if n == 0:
            self.index = -1
            return
        if self.index < 0:
            self.index = 0
        elif self.index >= n:
            self.index = n - 1

    fn value(self) -> String:
        """Currently committed string, or empty when the option list
        is empty. Empty is also a legitimate selection when it
        appears in ``options`` — callers distinguish via ``index``."""
        if self.index < 0 or self.index >= len(self.options):
            return String("")
        return self.options[self.index]

    fn set_value(mut self, value: String):
        """Move the cursor to ``value``. If the value isn't in the
        option list and is non-empty, append it so it's preserved
        through paints (a config loaded from disk shouldn't snap to
        a different choice just because we don't recognize the
        value). Empty input maps to the first option.

        ``is_open`` / ``highlight`` are reset because the value being
        re-seeded from outside almost always means the surrounding
        context (e.g. selected target) changed; carrying over a
        stale popup state would surprise the user."""
        for i in range(len(self.options)):
            if self.options[i] == value:
                self.index = i
                self.is_open = False
                self.highlight = i
                return
        if len(value.as_bytes()) == 0:
            if len(self.options) > 0:
                self.index = 0
            self.is_open = False
            self.highlight = 0
            return
        self.options.append(value)
        self.index = len(self.options) - 1
        self.is_open = False
        self.highlight = self.index

    fn open(mut self):
        if len(self.options) == 0:
            return
        self.is_open = True
        # Start the highlight on the committed value so Enter without
        # any movement is a no-op (rather than picking option 0).
        self.highlight = self.index if self.index >= 0 else 0
        self._scroll_to_highlight()

    fn close(mut self):
        self.is_open = False

    fn toggle(mut self):
        if self.is_open:
            self.close()
        else:
            self.open()

    # --- popup geometry -----------------------------------------------

    fn popup_rect(self, anchor: Rect, screen: Rect) -> Rect:
        """Where the popup will render relative to the collapsed
        strip. Sits directly below the strip when there's room;
        flips above when not. Width matches the strip but is widened
        to fit the longest option label. Height is capped at
        ``_MAX_POPUP_ROWS`` rows of options + 2 for the border."""
        var n_visible = len(self.options)
        if n_visible > _MAX_POPUP_ROWS:
            n_visible = _MAX_POPUP_ROWS
        var height = n_visible + 2
        # Width: max of the strip width and the longest label + 4
        # (1 left pad + label + 1 right pad + 2 borders).
        var width = anchor.width()
        for i in range(len(self.options)):
            var w = len(self.options[i].as_bytes()) + 4
            if w > width:
                width = w
        var x = anchor.a.x
        if x + width > screen.b.x:
            x = screen.b.x - width
            if x < 0:
                x = 0
        # Prefer below; flip above if it'd run off the bottom.
        var y = anchor.b.y
        if y + height > screen.b.y:
            y = anchor.a.y - height
            if y < 0:
                y = 0
        return Rect(x, y, x + width, y + height)

    fn _scroll_to_highlight(mut self):
        if self.highlight < self._scroll:
            self._scroll = self.highlight
            return
        if self.highlight >= self._scroll + _MAX_POPUP_ROWS:
            self._scroll = self.highlight - _MAX_POPUP_ROWS + 1
        if self._scroll < 0:
            self._scroll = 0

    # --- painting -----------------------------------------------------

    fn paint(
        self, mut canvas: Canvas, rect: Rect, focused: Bool,
        focused_attr: Attr, blurred_attr: Attr,
        empty_label: String = String("(none)"),
    ):
        """Render the collapsed strip into ``rect`` (one row tall).

        ``focused_attr`` / ``blurred_attr`` let the caller match the
        surrounding dialog's focus colours. ``empty_label`` is the
        placeholder shown when the selected value is the empty string
        — useful when empty has a domain meaning ("disabled", "auto",
        "none") and a literal blank cell would look like a paint bug.
        """
        var fill_attr = focused_attr if focused else blurred_attr
        canvas.fill(rect, String(" "), fill_attr)
        var v = self.value()
        var display = v if len(v.as_bytes()) > 0 else empty_label
        # 1-cell left padding so the value text doesn't touch the
        # left edge — same idiom as the input strips.
        _ = canvas.put_text(
            Point(rect.a.x + 1, rect.a.y), display, fill_attr,
            rect.b.x - 1,
        )
        # Caret glyph on the right edge: ``▼`` when closed, ``▲``
        # when open, hugging the right cell. Reads the same as the
        # menu bar's open-menu indicator.
        var caret = String("▲") if self.is_open else String("▼")
        canvas.set(rect.b.x - 1, rect.a.y, Cell(caret, fill_attr, 1))

    fn paint_popup(self, mut canvas: Canvas, anchor: Rect, screen: Rect):
        """Render the popup list. Caller invokes this last (after the
        rest of the dialog) so the popup overlays whatever's
        underneath. No-op when the dropdown is collapsed."""
        if not self.is_open or len(self.options) == 0:
            return
        var rect = self.popup_rect(anchor, screen)
        var attr = Attr(BLACK, LIGHT_GRAY)
        var sel_attr = Attr(BLACK, GREEN)
        canvas.fill(rect, String(" "), attr)
        canvas.draw_box(rect, attr, False)
        var visible = rect.height() - 2
        for r in range(visible):
            var idx = self._scroll + r
            if idx >= len(self.options):
                break
            var y = rect.a.y + 1 + r
            var label = self.options[idx]
            if len(label.as_bytes()) == 0:
                label = String("(none)")
            var is_hl = (idx == self.highlight)
            var row_attr = sel_attr if is_hl else attr
            if is_hl:
                # Fill the row so the green band reaches the inner
                # right edge of the popup, not just under the label.
                canvas.fill(
                    Rect(rect.a.x + 1, y, rect.b.x - 1, y + 1),
                    String(" "), row_attr,
                )
            # Mark the committed value with a leading ``•`` so the
            # user can tell "what I'm browsing" from "what's actually
            # picked" while moving the highlight around.
            var marker = String("• ") if idx == self.index \
                else String("  ")
            _ = canvas.put_text(
                Point(rect.a.x + 1, y), marker + label, row_attr,
                rect.b.x - 1,
            )

    # --- input --------------------------------------------------------

    fn handle_key(mut self, event: Event) -> Bool:
        """Return True if ``event`` was a key the dropdown consumed.
        Caller is expected to gate this on focus before invoking."""
        if event.kind != EVENT_KEY:
            return False
        var k = event.key
        if not self.is_open:
            # Closed: Down / Enter open the popup. Up has no inverse
            # action so we leave it for the dialog's focus walk.
            if k == KEY_DOWN or k == KEY_ENTER:
                self.open()
                return True
            return False
        # Open:
        if k == KEY_ESC:
            self.close()
            return True
        if k == KEY_ENTER:
            self.index = self.highlight
            self.close()
            return True
        if k == KEY_UP:
            self._step(-1)
            return True
        if k == KEY_DOWN:
            self._step(1)
            return True
        if k == KEY_PAGEUP:
            self._step(-_MAX_POPUP_ROWS)
            return True
        if k == KEY_PAGEDOWN:
            self._step(_MAX_POPUP_ROWS)
            return True
        # Swallow other keys while open — the popup is modal-ish and
        # a keystroke that types into the underlying input would be
        # surprising.
        return True

    fn _step(mut self, delta: Int):
        var n = len(self.options)
        if n == 0:
            return
        var i = self.highlight + delta
        if i < 0:
            i = 0
        elif i >= n:
            i = n - 1
        self.highlight = i
        self._scroll_to_highlight()

    fn handle_mouse(
        mut self, anchor: Rect, screen: Rect, event: Event,
    ) -> Int:
        """Treat ``event`` as a candidate click on the dropdown.

        Returns one of the ``DROPDOWN_HIT_*`` codes:
        * ``BODY`` — click on the collapsed strip; the dropdown has
          been toggled. Caller should also set focus to this widget.
        * ``POPUP`` — click landed inside the open popup. The
          dropdown handled the click (selection commit, scroll, etc.).
        * ``OUTSIDE`` — click landed outside both anchor and popup
          while open. The dropdown auto-closed; the caller should
          treat the event as falling through to its own dispatch.
        * ``NONE`` — neither the strip nor the popup were touched
          and the dropdown didn't change state.
        Drag-motion and release events return ``NONE``.
        """
        if event.kind != EVENT_MOUSE:
            return DROPDOWN_HIT_NONE
        # Wheel inside an open popup scrolls the highlight.
        if self.is_open:
            var pr = self.popup_rect(anchor, screen)
            if event.button == MOUSE_WHEEL_UP and pr.contains(event.pos):
                self._step(-1)
                return DROPDOWN_HIT_POPUP
            if event.button == MOUSE_WHEEL_DOWN and pr.contains(event.pos):
                self._step(1)
                return DROPDOWN_HIT_POPUP
        if event.button != MOUSE_BUTTON_LEFT or not event.pressed \
                or event.motion:
            return DROPDOWN_HIT_NONE
        if anchor.contains(event.pos):
            self.toggle()
            return DROPDOWN_HIT_BODY
        if self.is_open:
            var pr = self.popup_rect(anchor, screen)
            if pr.contains(event.pos):
                # Pick the option under the cursor and commit.
                var row = event.pos.y - (pr.a.y + 1)
                var idx = self._scroll + row
                if 0 <= idx and idx < len(self.options):
                    self.highlight = idx
                    self.index = idx
                    self.close()
                return DROPDOWN_HIT_POPUP
            # Click landed elsewhere with the popup open: close and
            # let the caller route the event to whatever it really
            # belongs to.
            self.close()
            return DROPDOWN_HIT_OUTSIDE
        return DROPDOWN_HIT_NONE
