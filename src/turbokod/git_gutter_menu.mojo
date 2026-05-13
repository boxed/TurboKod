"""Popup menu that opens when the user clicks the per-line bar in the
git-changes gutter. Currently offers a single action — revert the
clicked block back to its content at HEAD.

Modeled on ``SpellMenu`` so the look and event protocol match: the
host (Desktop) is responsible for opening the menu in response to
``Editor.consume_git_revert_request`` and for routing keyboard /
mouse events to it before any other widget.
"""

from std.collections.list import List

from .canvas import Canvas, paint_drop_shadow
from .painter import Painter
from .cell import Cell
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


fn _row_y(rect: Rect) -> Int:
    """Y of the menu's single action row. Driven by ``RowCursor`` so
    paint and hit-testing share one source of truth."""
    var cursor = RowCursor(rect.a.y + 1)
    return cursor.place()


# Hit-test result codes for ``GitGutterMenu.handle_mouse``. Mirrors the
# ``SPELL_HIT_*`` shape so callers can pattern-match similarly.
comptime GUTTER_HIT_NONE    = -1
comptime GUTTER_HIT_INSIDE  = 1
comptime GUTTER_HIT_OUTSIDE = 2


# Action codes returned to the host on resolve.
comptime GUTTER_ACTION_NONE   = 0
comptime GUTTER_ACTION_REVERT = 1


comptime _LABEL_REVERT = String("Revert this line")


struct GitGutterMenu(Movable):
    """Modal-ish popup menu anchored to a git-change gutter click."""

    var active: Bool
    var submitted: Bool
    var action: Int
    var row: Int
    """Buffer row the click landed on. Forwarded back to the host so it
    can recompute the revert block at submission time (the buffer may
    have shifted between the click and the confirmation, though in the
    current synchronous flow it won't)."""

    var anchor_x: Int
    var anchor_y: Int
    var selected: Int

    fn __init__(out self):
        self.active = False
        self.submitted = False
        self.action = GUTTER_ACTION_NONE
        self.row = -1
        self.anchor_x = 0
        self.anchor_y = 0
        self.selected = 0

    fn open(mut self, row: Int, anchor: Point):
        self.row = row
        self.anchor_x = anchor.x
        self.anchor_y = anchor.y
        self.active = True
        self.submitted = False
        self.action = GUTTER_ACTION_NONE
        self.selected = 0

    fn close(mut self):
        self.active = False
        self.submitted = False
        self.action = GUTTER_ACTION_NONE
        self.row = -1

    fn _row_count(self) -> Int:
        return 1

    fn _resolve(mut self, action: Int):
        self.action = action
        self.submitted = True

    fn _rect(self, screen: Rect) -> Rect:
        var width = display_columns(_LABEL_REVERT) + 4
        var height = self._row_count() + 2
        var x = self.anchor_x
        if x + width > screen.b.x:
            x = screen.b.x - width
        if x < 0:
            x = 0
        var y = self.anchor_y + 1
        if y + height > screen.b.y:
            y = self.anchor_y - height
            if y < 0:
                y = 0
        return Rect(x, y, x + width, y + height)

    fn paint(self, mut canvas: Canvas, screen: Rect):
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
            canvas, Point(rect.a.x + 2, y0), _LABEL_REVERT, row_attr,
        )

    fn handle_key(mut self, event: Event) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_KEY:
            return True
        var k = event.key
        if k == KEY_ESC:
            self._resolve(GUTTER_ACTION_NONE)
            return True
        if k == KEY_UP or k == KEY_DOWN:
            # Single row — arrows are no-ops, but swallow them so they
            # don't reach the editor underneath.
            return True
        if k == KEY_ENTER:
            self._resolve(GUTTER_ACTION_REVERT)
            return True
        return True

    fn handle_mouse(mut self, event: Event, screen: Rect) -> Int:
        if not self.active:
            return GUTTER_HIT_NONE
        if event.kind != EVENT_MOUSE:
            return GUTTER_HIT_NONE
        if event.button != MOUSE_BUTTON_LEFT or not event.pressed \
                or event.motion:
            return GUTTER_HIT_NONE
        var rect = self._rect(screen)
        if not rect.contains(event.pos):
            self._resolve(GUTTER_ACTION_NONE)
            return GUTTER_HIT_OUTSIDE
        var row = event.pos.y - _row_y(rect)
        if row < 0 or row >= self._row_count():
            return GUTTER_HIT_INSIDE
        self.selected = row
        if row == 0:
            self._resolve(GUTTER_ACTION_REVERT)
        return GUTTER_HIT_INSIDE
