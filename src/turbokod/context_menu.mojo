"""Popup menu that opens when the user right-clicks plain identifier
text in the editor's text area (i.e. not a diagnostic squiggle and not a
breakpoint gutter dot).

It offers the symbol actions that otherwise live behind Cmd+click or a
keybinding: rename, the go-to family (definition / type definition /
implementation / declaration), and find references. The host (Desktop)
decides *which* rows to show — it builds the label/action lists at open
time, filtered by what the language server actually advertises, so a
server without an ``implementationProvider`` simply doesn't get that row.

The same popup serves right-clicks in the gutter, with a fixed row set
(Toggle Blame / Copy Location / Toggle Bookmark / Toggle Breakpoint).

Rows come in groups: a ``CTX_MENU_SEPARATOR`` action draws a divider
between them, and ``open`` drops the ones that would lead, trail or
double up, so a host can append a separator per group without checking
whether the group before it turned out empty.

Modeled on ``DiagnosticMenu`` so the look and the press/release event
protocol match exactly. Unlike the diagnostic menu its rows are dynamic,
supplied per-open rather than hardcoded.
"""

from std.collections.list import List

from .canvas import Canvas
from .painter import Painter
from .colors import Attr, BLACK, GREEN, LIGHT_GRAY
from .events import (
    Event, EVENT_KEY, KEY_DOWN, KEY_ENTER, KEY_ESC, KEY_UP, MENU_HIT_NONE,
)
from .geometry import Point, Rect
from .string_utils import display_columns
from .anchored_menu import (
    NativeMenuItem, anchored_menu_mouse, anchored_menu_rect, menu_row_y, menu_step_wrap,
    paint_anchored_chrome,
)


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
comptime CTX_MENU_ACTION_COLOR_PICKER = 16
# Gutter menu rows (right-click in the line-number / gutter strip).
comptime CTX_MENU_ACTION_TOGGLE_BLAME = 17
comptime CTX_MENU_ACTION_COPY_LOCATION = 18
comptime CTX_MENU_ACTION_TOGGLE_BOOKMARK = 19
comptime CTX_MENU_ACTION_TOGGLE_BREAKPOINT = 20
comptime CTX_MENU_ACTION_EDIT_BREAKPOINT = 21
comptime CTX_MENU_ACTION_SEND_TO_CLAUDE = 22
comptime CTX_MENU_SEPARATOR = -1
"""Not an action: the row is a divider between groups."""


def ctx_menu_separator(mut labels: List[String], mut actions: List[Int]):
    """Append a group divider to a row set being built for ``open``."""
    labels.append(String(""))
    actions.append(CTX_MENU_SEPARATOR)


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
        self.tracking = False
        self.labels = List[String]()
        self.actions = List[Int]()
        for i in range(len(labels)):
            if actions[i] == CTX_MENU_SEPARATOR and (
                len(self.actions) == 0
                or self.actions[len(self.actions) - 1] == CTX_MENU_SEPARATOR
            ):
                continue
            self.labels.append(labels[i])
            self.actions.append(actions[i])
        var n = len(self.actions)
        if n > 0 and self.actions[n - 1] == CTX_MENU_SEPARATOR:
            _ = self.labels.pop()
            _ = self.actions.pop()
        self.selected = 0

    def close(mut self):
        self.active = False
        self.submitted = False
        self.action = CTX_MENU_ACTION_NONE
        self.tracking = False
        self.labels = List[String]()
        self.actions = List[Int]()

    def _row_count(self) -> Int:
        return len(self.labels)

    def native_items(self) -> List[NativeMenuItem]:
        var out = List[NativeMenuItem]()
        for i in range(len(self.labels)):
            if self._is_separator(i):
                out.append(NativeMenuItem.separator())
            else:
                out.append(
                    NativeMenuItem(self.labels[i], self.actions[i], True),
                )
        return out^

    def choose(mut self, action: Int):
        """Answer the menu from the native host (0 = dismissed)."""
        self._resolve(action)

    def _is_separator(self, row: Int) -> Bool:
        return self.actions[row] == CTX_MENU_SEPARATOR

    def _step(mut self, delta: Int):
        # ``open`` never leaves two separators in a row, so one more
        # step always lands on an action.
        self.selected = menu_step_wrap(self.selected, delta, self._row_count())
        if self._row_count() > 0 and self._is_separator(self.selected):
            self.selected = menu_step_wrap(
                self.selected, delta, self._row_count(),
            )

    def _resolve(mut self, action: Int):
        self.action = action
        self.submitted = True

    def _resolve_selected(mut self):
        var row = self.selected
        if row < 0 or row >= self._row_count() or self._is_separator(row):
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
        var y0 = menu_row_y(rect)
        for row in range(self._row_count()):
            var y = y0 + row
            if self._is_separator(row):
                for x in range(rect.a.x + 1, rect.b.x - 1):
                    _ = painter.put_text(canvas, Point(x, y), String("─"), attr)
                continue
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
        var rect = self._rect(container_bounds)
        var before = self.selected
        var r = anchored_menu_mouse(
            event, rect, menu_row_y(rect), self._row_count(),
            self.selected, self.tracking,
        )
        if self._row_count() > 0 and self._is_separator(self.selected):
            self.selected = before
        if r.cancel:
            self._resolve(CTX_MENU_ACTION_NONE)
        elif r.fired_row >= 0 and not self._is_separator(r.fired_row):
            self.selected = r.fired_row
            self._resolve_selected()
        return r.hit
