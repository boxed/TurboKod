"""Popup menu that opens when the user clicks the gutter run-icon next
to a detected test. Offers two actions — run the single test, or run it
under the debugger.

Modeled on ``GitGutterMenu`` so the look and event protocol match: the
host (Desktop) opens it in response to ``Editor.consume_test_run_request``
and routes keyboard / mouse events to it before any other widget. Carries
the pytest ``node_id`` from the click straight through to the host on
resolve, so the host doesn't re-derive which test was clicked.
"""

from std.collections.list import List

from .canvas import Canvas
from .painter import Painter
from .cell import Cell
from .colors import (
    Attr, BLACK, GREEN, LIGHT_GRAY,
)
from .events import (
    Event, EVENT_KEY,
    KEY_DOWN, KEY_ENTER, KEY_ESC, KEY_UP,
    MENU_HIT_NONE,
)
from .geometry import Point, Rect
from .string_utils import display_columns
from .anchored_menu import (
    anchored_menu_mouse, anchored_menu_rect, paint_anchored_chrome,
)


# ``TestGutterMenu.handle_mouse`` returns the shared ``MENU_HIT_*`` codes
# (``events.mojo``).


# Action codes returned to the host on resolve.
comptime TEST_ACTION_NONE  = 0
comptime TEST_ACTION_RUN   = 1
comptime TEST_ACTION_DEBUG = 2


comptime _LABEL_RUN = String("Run test")
comptime _LABEL_DEBUG = String("Debug test")


struct TestGutterMenu(Movable):
    """Modal-ish popup menu anchored to a test gutter run-icon click."""

    var active: Bool
    var submitted: Bool
    var action: Int
    var node_id: String
    """pytest node id of the clicked test, captured at open and handed
    back to the host on resolve so it can spawn exactly that test."""

    var anchor_x: Int
    var anchor_y: Int
    var selected: Int
    var tracking: Bool
    """True between a captured left-press inside the menu and its
    matching release. Like a button, the action only fires on release;
    a release without a prior tracked press is a non-event."""

    def __init__(out self):
        self.active = False
        self.submitted = False
        self.action = TEST_ACTION_NONE
        self.node_id = String("")
        self.anchor_x = 0
        self.anchor_y = 0
        self.selected = 0
        self.tracking = False

    def open(mut self, var node_id: String, anchor: Point):
        self.node_id = node_id^
        self.anchor_x = anchor.x
        self.anchor_y = anchor.y
        self.active = True
        self.submitted = False
        self.action = TEST_ACTION_NONE
        self.selected = 0
        self.tracking = False

    def close(mut self):
        self.active = False
        self.submitted = False
        self.action = TEST_ACTION_NONE
        self.node_id = String("")
        self.tracking = False

    def _row_count(self) -> Int:
        return 2

    def _row_y(self, rect: Rect, idx: Int) -> Int:
        """Y of action row ``idx`` — adjacent rows below the box top, no
        inter-row gap (a menu, not a form)."""
        return rect.a.y + 1 + idx

    def _resolve(mut self, action: Int):
        self.action = action
        self.submitted = True

    def _rect(self, container_bounds: Rect) -> Rect:
        var w_run = display_columns(_LABEL_RUN)
        var w_dbg = display_columns(_LABEL_DEBUG)
        var label_w = w_run if w_run > w_dbg else w_dbg
        return anchored_menu_rect(
            self.anchor_x, self.anchor_y,
            label_w + 4, self._row_count() + 2, container_bounds, False,
        )

    def paint(self, mut canvas: Canvas, container_bounds: Rect):
        if not self.active:
            return
        var rect = self._rect(container_bounds)
        var attr = Attr(BLACK, LIGHT_GRAY)
        var sel_attr = Attr(BLACK, GREEN)
        paint_anchored_chrome(canvas, rect, attr)
        var painter = Painter(rect)
        for idx in range(self._row_count()):
            var y0 = self._row_y(rect, idx)
            var is_sel = (self.selected == idx)
            var row_attr = sel_attr if is_sel else attr
            if is_sel:
                painter.fill(
                    canvas, Rect(rect.a.x + 1, y0, rect.b.x - 1, y0 + 1),
                    String(" "), row_attr,
                )
            var label = _LABEL_RUN if idx == 0 else _LABEL_DEBUG
            _ = painter.put_text(
                canvas, Point(rect.a.x + 2, y0), label, row_attr,
            )

    def _action_for_row(self, row: Int) -> Int:
        return TEST_ACTION_RUN if row == 0 else TEST_ACTION_DEBUG

    def handle_key(mut self, event: Event) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_KEY:
            return True
        var k = event.key
        if k == KEY_ESC:
            self._resolve(TEST_ACTION_NONE)
            return True
        if k == KEY_UP:
            if self.selected > 0:
                self.selected -= 1
            return True
        if k == KEY_DOWN:
            if self.selected < self._row_count() - 1:
                self.selected += 1
            return True
        if k == KEY_ENTER:
            self._resolve(self._action_for_row(self.selected))
            return True
        return True

    def handle_mouse(mut self, event: Event, container_bounds: Rect) -> Int:
        """Button-like press / release model (see ``anchored_menu_mouse``):
        press inside arms tracking, release inside fires the row action."""
        if not self.active:
            return MENU_HIT_NONE
        var rect = self._rect(container_bounds)
        var r = anchored_menu_mouse(
            event, rect, self._row_y(rect, 0), self._row_count(),
            self.selected, self.tracking,
        )
        if r.cancel:
            self._resolve(TEST_ACTION_NONE)
        elif r.fired_row >= 0:
            self._resolve(self._action_for_row(r.fired_row))
        return r.hit
