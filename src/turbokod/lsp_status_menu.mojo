"""Popup menu that opens when the user right-clicks the LSP indicator
on the right of the status bar. Currently offers a single action —
restart the language server for the focused editor's file.

Modeled on ``GitGutterMenu`` / ``SpellMenu``: the host (Desktop) is
responsible for opening the menu in response to a right-click hit on
the status-bar message rect, and for routing keyboard / mouse events
to it before any other widget while ``active`` is True.
"""

from std.collections.list import List

from .canvas import Canvas
from .painter import Painter
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
from .view import RowCursor
from .anchored_menu import (
    anchored_menu_mouse, anchored_menu_rect, paint_anchored_chrome,
)


def _row_y(rect: Rect) -> Int:
    var cursor = RowCursor(rect.a.y + 1)
    return cursor.place()


# ``LspStatusMenu.handle_mouse`` returns the shared ``MENU_HIT_*`` codes
# (``events.mojo``).


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
    var tracking: Bool
    """True between a captured left-press inside the menu and its
    matching release. Like a button, the action only fires on
    release; a release without a prior tracked press is a non-event."""

    def __init__(out self):
        self.active = False
        self.submitted = False
        self.action = LSP_MENU_ACTION_NONE
        self.anchor_x = 0
        self.anchor_y = 0
        self.selected = 0
        self.tracking = False

    def open(mut self, anchor: Point):
        self.anchor_x = anchor.x
        self.anchor_y = anchor.y
        self.active = True
        self.submitted = False
        self.action = LSP_MENU_ACTION_NONE
        self.selected = 0
        self.tracking = False

    def close(mut self):
        self.active = False
        self.submitted = False
        self.action = LSP_MENU_ACTION_NONE
        self.tracking = False

    def _row_count(self) -> Int:
        return 1

    def _resolve(mut self, action: Int):
        self.action = action
        self.submitted = True

    def _rect(self, container_bounds: Rect) -> Rect:
        # Anchor sits on the status bar (bottom row); open the menu *above*
        # it by default (prefer_above) so it doesn't render off-screen.
        return anchored_menu_rect(
            self.anchor_x, self.anchor_y,
            display_columns(_LABEL_RESTART) + 4, self._row_count() + 2,
            container_bounds, True,
        )

    def paint(self, mut canvas: Canvas, container_bounds: Rect):
        if not self.active:
            return
        var rect = self._rect(container_bounds)
        var attr = Attr(BLACK, LIGHT_GRAY)
        var sel_attr = Attr(BLACK, GREEN)
        paint_anchored_chrome(canvas, rect, attr)
        var painter = Painter(rect)
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

    def handle_mouse(mut self, event: Event, container_bounds: Rect) -> Int:
        """Button-like press / release model. Press inside arms
        tracking + highlights; release inside fires the action.
        Releases without a prior tracked press are non-events so the
        right-click release that opened the menu can't auto-trigger."""
        if not self.active:
            return MENU_HIT_NONE
        var rect = self._rect(container_bounds)
        var r = anchored_menu_mouse(
            event, rect, _row_y(rect), self._row_count(),
            self.selected, self.tracking,
        )
        if r.cancel:
            self._resolve(LSP_MENU_ACTION_NONE)
        elif r.fired_row == 0:
            self._resolve(LSP_MENU_ACTION_RESTART)
        return r.hit
