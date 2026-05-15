"""Popup menu that opens when the user right-clicks the LSP indicator
on the right of the status bar. Currently offers a single action —
restart the language server for the focused editor's file.

Modeled on ``GitGutterMenu`` / ``SpellMenu``: the host (Desktop) is
responsible for opening the menu in response to a right-click hit on
the status-bar message rect, and for routing keyboard / mouse events
to it before any other widget while ``active`` is True.
"""

from std.collections.list import List

from .canvas import Canvas, paint_drop_shadow
from .painter import Painter
from .colors import (
    Attr, BLACK, GREEN, LIGHT_GRAY,
)
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_DOWN, KEY_ENTER, KEY_ESC, KEY_UP,
    MOUSE_BUTTON_LEFT,
)
from .geometry import Point, Rect
from .string_utils import display_columns
from .view import RowCursor


def _row_y(rect: Rect) -> Int:
    var cursor = RowCursor(rect.a.y + 1)
    return cursor.place()


comptime LSP_MENU_HIT_NONE    = -1
comptime LSP_MENU_HIT_INSIDE  = 1
comptime LSP_MENU_HIT_OUTSIDE = 2


comptime LSP_MENU_ACTION_NONE    = 0
comptime LSP_MENU_ACTION_RESTART = 1


comptime _LABEL_RESTART = String("Restart LSP")


struct LspStatusMenu(Movable):
    """Modal-ish popup menu anchored to a right-click on the LSP
    indicator. One row: "Restart LSP"."""

    var active: Bool
    var submitted: Bool
    var action: Int
    var anchor_x: Int
    var anchor_y: Int
    var selected: Int

    def __init__(out self):
        self.active = False
        self.submitted = False
        self.action = LSP_MENU_ACTION_NONE
        self.anchor_x = 0
        self.anchor_y = 0
        self.selected = 0

    def open(mut self, anchor: Point):
        self.anchor_x = anchor.x
        self.anchor_y = anchor.y
        self.active = True
        self.submitted = False
        self.action = LSP_MENU_ACTION_NONE
        self.selected = 0

    def close(mut self):
        self.active = False
        self.submitted = False
        self.action = LSP_MENU_ACTION_NONE

    def _row_count(self) -> Int:
        return 1

    def _resolve(mut self, action: Int):
        self.action = action
        self.submitted = True

    def _rect(self, screen: Rect) -> Rect:
        var width = display_columns(_LABEL_RESTART) + 4
        var height = self._row_count() + 2
        # Anchor sits on the status bar (bottom row); open the menu
        # *above* it by default so it doesn't try to render off-screen.
        var x = self.anchor_x
        if x + width > screen.b.x:
            x = screen.b.x - width
        if x < 0:
            x = 0
        var y = self.anchor_y - height
        if y < 0:
            y = self.anchor_y + 1
            if y + height > screen.b.y:
                y = screen.b.y - height
                if y < 0:
                    y = 0
        return Rect(x, y, x + width, y + height)

    def paint(self, mut canvas: Canvas, screen: Rect):
        if not self.active:
            return
        var rect = self._rect(screen)
        var attr = Attr(BLACK, LIGHT_GRAY)
        var sel_attr = Attr(BLACK, GREEN)
        paint_drop_shadow(canvas, rect)
        var painter = Painter(rect)
        painter.fill(canvas, rect, String(" "), attr)
        painter.draw_box(canvas, rect, attr, False)
        var y0 = _row_y(rect)
        var is_sel = (self.selected == 0)
        var row_attr = sel_attr if is_sel else attr
        if is_sel:
            painter.fill(
                canvas, Rect(rect.a.x + 1, y0, rect.b.x - 1, y0 + 1),
                String(" "), row_attr,
            )
        _ = painter.put_text(
            canvas, Point(rect.a.x + 2, y0), _LABEL_RESTART, row_attr,
        )

    def handle_key(mut self, event: Event) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_KEY:
            return True
        var k = event.key
        if k == KEY_ESC:
            self._resolve(LSP_MENU_ACTION_NONE)
            return True
        if k == KEY_UP or k == KEY_DOWN:
            return True
        if k == KEY_ENTER:
            self._resolve(LSP_MENU_ACTION_RESTART)
            return True
        return True

    def handle_mouse(mut self, event: Event, screen: Rect) -> Int:
        if not self.active:
            return LSP_MENU_HIT_NONE
        if event.kind != EVENT_MOUSE:
            return LSP_MENU_HIT_NONE
        if event.button != MOUSE_BUTTON_LEFT or not event.pressed \
                or event.motion:
            return LSP_MENU_HIT_NONE
        var rect = self._rect(screen)
        if not rect.contains(event.pos):
            self._resolve(LSP_MENU_ACTION_NONE)
            return LSP_MENU_HIT_OUTSIDE
        var row = event.pos.y - _row_y(rect)
        if row < 0 or row >= self._row_count():
            return LSP_MENU_HIT_INSIDE
        self.selected = row
        if row == 0:
            self._resolve(LSP_MENU_ACTION_RESTART)
        return LSP_MENU_HIT_INSIDE
