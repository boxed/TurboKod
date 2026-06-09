"""Popup menu that opens when the user right-clicks plain identifier
text in the editor's text area (i.e. not a diagnostic squiggle and not a
breakpoint gutter dot).

It offers the symbol actions that otherwise live behind Cmd+click or a
keybinding: rename, the go-to family (definition / type definition /
implementation / declaration), and find references. The host (Desktop)
decides *which* rows to show — it builds the label/action lists at open
time, filtered by what the language server actually advertises, so a
server without an ``implementationProvider`` simply doesn't get that row.

Modeled on ``DiagnosticMenu`` so the look and the press/release event
protocol match exactly. Unlike the diagnostic menu its rows are dynamic,
supplied per-open rather than hardcoded.
"""

from std.collections.list import List

from .canvas import Canvas
from .painter import Painter
from .colors import Attr, BLACK, GREEN, LIGHT_GRAY
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_DOWN, KEY_ENTER, KEY_ESC, KEY_UP,
    MENU_HIT_INSIDE, MENU_HIT_NONE, MENU_HIT_OUTSIDE,
    MOUSE_BUTTON_LEFT,
)
from .geometry import Point, Rect
from .string_utils import display_columns
from .view import RowCursor
from .anchored_menu import anchored_menu_rect, paint_anchored_chrome


def _row_y(rect: Rect) -> Int:
    var cursor = RowCursor(rect.a.y + 1)
    return cursor.place()


comptime CTX_MENU_ACTION_NONE            = 0
comptime CTX_MENU_ACTION_RENAME          = 1
comptime CTX_MENU_ACTION_DEFINITION      = 2
comptime CTX_MENU_ACTION_REFERENCES      = 3
comptime CTX_MENU_ACTION_TYPE_DEFINITION = 4
comptime CTX_MENU_ACTION_IMPLEMENTATION  = 5
comptime CTX_MENU_ACTION_DECLARATION     = 6
comptime CTX_MENU_ACTION_CALLERS         = 7
comptime CTX_MENU_ACTION_SUPERTYPES      = 8
comptime CTX_MENU_ACTION_CALLEES         = 9
comptime CTX_MENU_ACTION_SUBTYPES        = 10
comptime CTX_MENU_ACTION_MONIKER         = 11
comptime CTX_MENU_ACTION_COLOR_PRESENTATION = 12
comptime CTX_MENU_ACTION_INLINE_COMPLETION = 13
comptime CTX_MENU_ACTION_LINKED_EDIT = 14
comptime CTX_MENU_ACTION_TOGGLE_FOLD = 15


struct EditorContextMenu(Movable):
    """Modal-ish popup of symbol actions anchored at a right-click. Rows
    are supplied per-open by the host."""

    var active: Bool
    var submitted: Bool
    var action: Int
    var anchor_x: Int
    var anchor_y: Int
    var selected: Int
    var tracking: Bool
    """True between a captured left-press inside the menu and its matching
    release — the action only fires on release, and a release without a
    prior tracked press is ignored so the right-click that opened the
    menu can't auto-trigger a row."""

    var labels: List[String]
    var actions: List[Int]

    def __init__(out self):
        self.active = False
        self.submitted = False
        self.action = CTX_MENU_ACTION_NONE
        self.anchor_x = 0
        self.anchor_y = 0
        self.selected = 0
        self.tracking = False
        self.labels = List[String]()
        self.actions = List[Int]()

    def open(
        mut self, anchor: Point,
        var labels: List[String], var actions: List[Int],
    ):
        self.anchor_x = anchor.x
        self.anchor_y = anchor.y
        self.active = True
        self.submitted = False
        self.action = CTX_MENU_ACTION_NONE
        self.selected = 0
        self.tracking = False
        self.labels = labels^
        self.actions = actions^

    def close(mut self):
        self.active = False
        self.submitted = False
        self.action = CTX_MENU_ACTION_NONE
        self.tracking = False
        self.labels = List[String]()
        self.actions = List[Int]()

    def _row_count(self) -> Int:
        return len(self.labels)

    def _step(mut self, delta: Int):
        var n = self._row_count()
        if n == 0:
            return
        var i = self.selected + delta
        if i < 0:
            i = n - 1
        elif i >= n:
            i = 0
        self.selected = i

    def _resolve(mut self, action: Int):
        self.action = action
        self.submitted = True

    def _resolve_selected(mut self):
        var row = self.selected
        if row < 0 or row >= self._row_count():
            return
        self._resolve(self.actions[row])

    def _label_width(self) -> Int:
        var w = 0
        for i in range(len(self.labels)):
            var lw = display_columns(self.labels[i])
            if lw > w:
                w = lw
        return w

    def _rect(self, container_bounds: Rect) -> Rect:
        return anchored_menu_rect(
            self.anchor_x, self.anchor_y,
            self._label_width() + 4, self._row_count() + 2,
            container_bounds, False,
        )

    def paint(self, mut canvas: Canvas, container_bounds: Rect):
        if not self.active or self._row_count() == 0:
            return
        var rect = self._rect(container_bounds)
        var attr = Attr(BLACK, LIGHT_GRAY)
        var sel_attr = Attr(BLACK, GREEN)
        paint_anchored_chrome(canvas, rect, attr)
        var painter = Painter(rect)
        var y0 = _row_y(rect)
        for row in range(self._row_count()):
            var y = y0 + row
            var is_sel = (self.selected == row)
            var row_attr = sel_attr if is_sel else attr
            if is_sel:
                painter.fill(
                    canvas, Rect(rect.a.x + 1, y, rect.b.x - 1, y + 1),
                    String(" "), row_attr,
                )
            _ = painter.put_text(
                canvas, Point(rect.a.x + 2, y), self.labels[row], row_attr,
            )

    def handle_key(mut self, event: Event) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_KEY:
            return True
        var k = event.key
        if k == KEY_ESC:
            self._resolve(CTX_MENU_ACTION_NONE)
            return True
        if k == KEY_UP:
            self._step(-1)
            return True
        if k == KEY_DOWN:
            self._step(1)
            return True
        if k == KEY_ENTER:
            self._resolve_selected()
            return True
        return True

    def handle_mouse(mut self, event: Event, container_bounds: Rect) -> Int:
        """Button-like press / release model, identical to
        ``DiagnosticMenu``: press inside arms tracking, the action fires
        only when the matching release lands inside, press outside
        dismisses, and a release with no prior tracked press is a
        non-event (so the opening right-click's release can't fire a
        row)."""
        if not self.active:
            return MENU_HIT_NONE
        if event.kind != EVENT_MOUSE:
            return MENU_HIT_NONE
        if event.button != MOUSE_BUTTON_LEFT or event.motion:
            return MENU_HIT_NONE
        var rect = self._rect(container_bounds)
        var inside = rect.contains(event.pos)
        if event.pressed:
            if not inside:
                self._resolve(CTX_MENU_ACTION_NONE)
                return MENU_HIT_OUTSIDE
            var row = event.pos.y - _row_y(rect)
            if row < 0 or row >= self._row_count():
                return MENU_HIT_INSIDE
            self.selected = row
            self.tracking = True
            return MENU_HIT_INSIDE
        # Release.
        if not self.tracking:
            return MENU_HIT_NONE
        self.tracking = False
        if not inside:
            self._resolve(CTX_MENU_ACTION_NONE)
            return MENU_HIT_OUTSIDE
        var row = event.pos.y - _row_y(rect)
        if row < 0 or row >= self._row_count():
            return MENU_HIT_INSIDE
        self.selected = row
        self._resolve_selected()
        return MENU_HIT_INSIDE
