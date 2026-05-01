"""Inline dropdown / cycler widget.

A single-row selector that fits where a text input would: arrow
glyphs hug the left and right edges, the current value sits in the
middle, and the user advances through choices with Left / Right (or
by clicking the arrow cells). Same shape as a TurboVision
``TRadioButtons`` collapsed into one line — works in any dialog row
without claiming vertical space.

The widget owns its option list and selected index. Callers project
state in via ``set_value`` and read it back via ``value`` after each
event, so the source of truth in the surrounding model (e.g. a
``RunTarget.debug_language`` string) stays canonical and the dropdown
is just a transient view.

Unknown values are preserved: ``set_value`` with a string that isn't
in the option list appends it as a synthetic entry, so a config
loaded from disk never silently snaps to a different choice just
because we don't recognize the value.
"""

from std.collections.list import List

from .canvas import Canvas
from .cell import Cell
from .colors import Attr
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_LEFT, KEY_RIGHT, MOUSE_BUTTON_LEFT,
)
from .geometry import Point, Rect


# Hit-test result codes for ``Dropdown.hit_test``.
comptime DROPDOWN_HIT_NONE  = -1
comptime DROPDOWN_HIT_LEFT  = 0
"""Click landed on the left-arrow cell — caller should cycle backward."""
comptime DROPDOWN_HIT_BODY  = 1
"""Click landed on the value text — caller typically just sets focus."""
comptime DROPDOWN_HIT_RIGHT = 2
"""Click landed on the right-arrow cell — caller should cycle forward."""


struct Dropdown(ImplicitlyCopyable, Movable):
    """One inline dropdown.

    ``options`` is the full set of selectable values, in cycle order.
    ``index`` is the currently selected slot. The widget keeps both
    in sync on every mutation; constructing a fresh ``Dropdown`` per
    paint is cheap and is the recommended pattern when the source of
    truth is a string elsewhere in the model.
    """
    var options: List[String]
    var index: Int

    fn __init__(out self, var options: List[String], index: Int = 0):
        self.options = options^
        self.index = index
        self._clip_index()

    fn __copyinit__(out self, copy: Self):
        self.options = copy.options.copy()
        self.index = copy.index

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
        """Currently selected string, or empty when the option list
        is empty. Empty is also a legitimate selection when it appears
        in ``options`` — callers distinguish via ``index``."""
        if self.index < 0 or self.index >= len(self.options):
            return String("")
        return self.options[self.index]

    fn set_value(mut self, value: String):
        """Move the cursor to ``value``. If the value isn't in the
        option list and is non-empty, append it so it's preserved
        through paints (a config loaded from disk shouldn't snap to
        a different choice just because we don't recognize the
        value). Empty input maps to the first option."""
        for i in range(len(self.options)):
            if self.options[i] == value:
                self.index = i
                return
        if len(value.as_bytes()) == 0:
            if len(self.options) > 0:
                self.index = 0
            return
        self.options.append(value)
        self.index = len(self.options) - 1

    fn cycle(mut self, delta: Int):
        """Advance the selection by ``delta`` slots, wrapping at the
        ends. ``delta = 1`` is "next", ``-1`` is "prev"; larger jumps
        work but aren't currently used by any caller."""
        var n = len(self.options)
        if n == 0:
            return
        var d = delta % n
        var i = self.index + d
        # Single-step wrap; ``%`` on negative ints in Mojo follows the
        # sign of the dividend, so normalize manually.
        if i < 0:
            i = i + n
        elif i >= n:
            i = i - n
        self.index = i

    # --- painting ---------------------------------------------------

    fn paint(
        self, mut canvas: Canvas, rect: Rect, focused: Bool,
        focused_attr: Attr, blurred_attr: Attr,
        empty_label: String = String("(none)"),
    ):
        """Render the dropdown into ``rect`` (which must be exactly
        one row tall — multi-row dropdowns aren't a thing here).

        ``focused_attr`` / ``blurred_attr`` let the caller match the
        surrounding dialog's focus colours. ``empty_label`` is the
        placeholder shown when the selected value is the empty string
        — useful when empty has a domain meaning ("disabled", "auto",
        "none") and a literal blank cell would look like a paint bug.
        """
        var fill_attr = focused_attr if focused else blurred_attr
        canvas.fill(rect, String(" "), fill_attr)
        # Arrow markers always visible — that's the affordance that
        # tells the user this is a cycler, not a label.
        canvas.set(rect.a.x, rect.a.y, Cell(String("<"), fill_attr, 1))
        canvas.set(rect.b.x - 1, rect.a.y, Cell(String(">"), fill_attr, 1))
        var v = self.value()
        var display = v if len(v.as_bytes()) > 0 else empty_label
        # Two-cell gutter after the arrow keeps the value text from
        # touching the bracket — same idiom as ShadowButton's padding.
        _ = canvas.put_text(
            Point(rect.a.x + 2, rect.a.y), display, fill_attr, rect.b.x - 1,
        )

    # --- input ------------------------------------------------------

    fn handle_key(mut self, event: Event) -> Bool:
        """Return True if ``event`` was a key the dropdown consumed.
        Currently Left / Right cycle; the caller is expected to gate
        this on focus before invoking."""
        if event.kind != EVENT_KEY:
            return False
        var k = event.key
        if k == KEY_LEFT:
            self.cycle(-1)
            return True
        if k == KEY_RIGHT:
            self.cycle(1)
            return True
        return False

    fn hit_test(self, rect: Rect, pos: Point) -> Int:
        """Decide which part of the dropdown ``pos`` lands on:
        ``DROPDOWN_HIT_LEFT`` / ``_BODY`` / ``_RIGHT``, or
        ``_NONE`` when the click missed entirely. The caller decides
        what to do with each (typically: arrow → cycle, body → focus)."""
        if not rect.contains(pos):
            return DROPDOWN_HIT_NONE
        if pos.x == rect.a.x:
            return DROPDOWN_HIT_LEFT
        if pos.x == rect.b.x - 1:
            return DROPDOWN_HIT_RIGHT
        return DROPDOWN_HIT_BODY

    fn handle_mouse(mut self, rect: Rect, event: Event) -> Int:
        """Treat ``event`` as a candidate click on the dropdown.

        Returns the same hit code as ``hit_test`` (so the caller can
        decide whether to also update focus), and applies the cycle
        side-effect for arrow hits. Body clicks and misses leave the
        selection unchanged. Drag-motion and release events are
        always misses — only fresh left-button presses act."""
        if event.kind != EVENT_MOUSE:
            return DROPDOWN_HIT_NONE
        if event.button != MOUSE_BUTTON_LEFT or not event.pressed \
                or event.motion:
            return DROPDOWN_HIT_NONE
        var hit = self.hit_test(rect, event.pos)
        if hit == DROPDOWN_HIT_LEFT:
            self.cycle(-1)
        elif hit == DROPDOWN_HIT_RIGHT:
            self.cycle(1)
        return hit
