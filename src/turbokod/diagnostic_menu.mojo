"""Popup menu that opens when the user right-clicks a diagnostic
(LSP inspection error/warning/info/hint) squiggle in the editor's
text area. Currently offers a single action — copy the diagnostic
message to the system clipboard so the user can paste it into a
search engine, chat, or bug tracker.

Modeled on ``GitGutterMenu`` so the look and event protocol match:
the host (Desktop) is responsible for opening the menu in response
to ``Editor.consume_diagnostic_menu_request`` and for routing
keyboard / mouse events to it before any other widget.
"""

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


comptime DIAG_MENU_HIT_NONE    = -1
comptime DIAG_MENU_HIT_INSIDE  = 1
comptime DIAG_MENU_HIT_OUTSIDE = 2


comptime DIAG_MENU_ACTION_NONE = 0
comptime DIAG_MENU_ACTION_COPY = 1


comptime _LABEL_COPY = String("Copy message")


@fieldwise_init
struct DiagnosticMenuRequest(ImplicitlyCopyable, Movable):
    """Payload emitted when the user right-clicks a diagnostic span.
    ``message`` is the text to copy on submit; ``anchor_x``/``anchor_y``
    are the screen cell the menu should open against (immediately
    below the underlined span, left-aligned to its leftmost cell)."""
    var message: String
    var anchor_x: Int
    var anchor_y: Int


struct DiagnosticMenu(Movable):
    """Modal-ish popup menu anchored to a diagnostic squiggle."""

    var active: Bool
    var submitted: Bool
    var action: Int
    var message: String
    """The diagnostic text — captured at open time so the host can
    push it to the clipboard on submit without re-resolving which
    diagnostic was clicked."""

    var anchor_x: Int
    var anchor_y: Int
    var selected: Int

    def __init__(out self):
        self.active = False
        self.submitted = False
        self.action = DIAG_MENU_ACTION_NONE
        self.message = String("")
        self.anchor_x = 0
        self.anchor_y = 0
        self.selected = 0

    def open(mut self, var message: String, anchor: Point):
        self.message = message^
        self.anchor_x = anchor.x
        self.anchor_y = anchor.y
        self.active = True
        self.submitted = False
        self.action = DIAG_MENU_ACTION_NONE
        self.selected = 0

    def close(mut self):
        self.active = False
        self.submitted = False
        self.action = DIAG_MENU_ACTION_NONE
        self.message = String("")

    def _row_count(self) -> Int:
        return 1

    def _resolve(mut self, action: Int):
        self.action = action
        self.submitted = True

    def _rect(self, screen: Rect) -> Rect:
        var width = display_columns(_LABEL_COPY) + 4
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
            canvas, Point(rect.a.x + 2, y0), _LABEL_COPY, row_attr,
        )

    def handle_key(mut self, event: Event) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_KEY:
            return True
        var k = event.key
        if k == KEY_ESC:
            self._resolve(DIAG_MENU_ACTION_NONE)
            return True
        if k == KEY_UP or k == KEY_DOWN:
            return True
        if k == KEY_ENTER:
            self._resolve(DIAG_MENU_ACTION_COPY)
            return True
        return True

    def handle_mouse(mut self, event: Event, screen: Rect) -> Int:
        if not self.active:
            return DIAG_MENU_HIT_NONE
        if event.kind != EVENT_MOUSE:
            return DIAG_MENU_HIT_NONE
        if event.button != MOUSE_BUTTON_LEFT or not event.pressed \
                or event.motion:
            return DIAG_MENU_HIT_NONE
        var rect = self._rect(screen)
        if not rect.contains(event.pos):
            self._resolve(DIAG_MENU_ACTION_NONE)
            return DIAG_MENU_HIT_OUTSIDE
        var row = event.pos.y - _row_y(rect)
        if row < 0 or row >= self._row_count():
            return DIAG_MENU_HIT_INSIDE
        self.selected = row
        if row == 0:
            self._resolve(DIAG_MENU_ACTION_COPY)
        return DIAG_MENU_HIT_INSIDE
