"""Modal dialog for ``window/showMessageRequest``.

An LSP server can ask the client to show a message *with action buttons*
and block until the user picks one (or dismisses) — e.g. "Reload window
to apply settings? [Reload] [Later]". Unlike ``window/showMessage`` (a
fire-and-forget toast we route to the status bar) the server is waiting
on a response carrying the chosen ``MessageActionItem``.

The dialog renders the wrapped message and a vertical list of action
titles. Up/Down move the selection, Enter picks it, Esc (or the ``[■]``
close glyph) dismisses with no choice. The host reads ``submitted`` then
``selected_index`` (``-1`` = dismissed) and relays it to the server via
``LspManager.respond_message_request``.
"""

from .canvas import Canvas, wrap_to_width
from .colors import Attr, BLACK, BLUE, LIGHT_GRAY, WHITE, YELLOW
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_DOWN, KEY_ENTER, KEY_ESC, KEY_UP,
    MOUSE_BUTTON_LEFT,
)
from .geometry import Point, Rect, center_in
from .string_utils import display_columns
from .window import close_button_clicked, paint_modal_frame


comptime _DEFAULT_WIDTH = 60
comptime _MIN_WIDTH     = 28


struct MessageRequestDialog(Movable):
    """Modal message + vertical action list for showMessageRequest."""
    var active: Bool
    var submitted: Bool
    """True once the user picks an action or dismisses; host reads
    ``selected_index`` then calls ``close()``."""
    var selected_index: Int
    """Index into the actions shown at ``open`` time, or -1 if dismissed."""
    var message: String
    var actions: List[String]
    var _sel: Int

    def __init__(out self):
        self.active = False
        self.submitted = False
        self.selected_index = -1
        self.message = String("")
        self.actions = List[String]()
        self._sel = 0

    def open(mut self, var message: String, var actions: List[String]):
        self.message = message^
        self.actions = actions^
        self.active = True
        self.submitted = False
        self.selected_index = -1
        self._sel = 0

    def close(mut self):
        self.active = False
        self.submitted = False
        self.selected_index = -1
        self.message = String("")
        self.actions = List[String]()
        self._sel = 0

    def _layout(self, container_bounds: Rect) -> Rect:
        var width = _DEFAULT_WIDTH
        # Grow to fit the longest action label if needed.
        for i in range(len(self.actions)):
            var need = display_columns(self.actions[i]) + 6
            if need > width:
                width = need
        if width > container_bounds.b.x - 4:
            width = container_bounds.b.x - 4
        if width < _MIN_WIDTH:
            width = _MIN_WIDTH
        var text_w = width - 4
        if text_w < 1:
            text_w = 1
        var lines = wrap_to_width(self.message, text_w)
        var msg_rows = len(lines)
        if msg_rows < 1:
            msg_rows = 1
        var n_actions = len(self.actions)
        if n_actions < 1:
            n_actions = 1
        # border / msg rows / gap / action rows / border.
        var height = 1 + msg_rows + 1 + n_actions + 1
        if height > container_bounds.b.y - 4:
            height = container_bounds.b.y - 4
        return center_in(container_bounds, width, height)

    def paint(mut self, mut canvas: Canvas, container_bounds: Rect):
        if not self.active:
            return
        var attr = Attr(BLACK, LIGHT_GRAY)
        var rect = self._layout(container_bounds)
        _ = paint_modal_frame(canvas, rect, attr)
        var content_x = rect.a.x + 2
        var clip_x = rect.b.x - 1
        var n_actions = len(self.actions)
        var msg_rect = Rect(
            content_x, rect.a.y + 1,
            clip_x, rect.b.y - 1 - n_actions - 1,
        )
        _ = canvas.put_wrapped_text(msg_rect, self.message, attr)
        # Action rows fill the bottom, one per row above the border.
        var first_row = rect.b.y - n_actions - 1
        for i in range(n_actions):
            var y = first_row + i
            var row_attr = attr
            if i == self._sel:
                row_attr = Attr(WHITE, BLUE)
            # Paint the full interior width so the selection bar is solid —
            # stop at ``rect.b.x - 1`` (exclusive) so the bar fills up to the
            # last interior column and leaves the right border intact.
            canvas.fill(
                Rect(rect.a.x + 1, y, rect.b.x - 1, y + 1),
                String(" "), row_attr,
            )
            var marker = String("▸ ") if i == self._sel else String("  ")
            _ = canvas.put_text(
                Point(content_x, y), marker + self.actions[i], row_attr, clip_x,
            )

    def _resolve(mut self, index: Int):
        self.selected_index = index
        self.submitted = True

    def handle_key(mut self, event: Event) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_KEY:
            return True
        var k = event.key
        if k == KEY_ESC:
            self._resolve(-1)
            return True
        if k == KEY_ENTER:
            if len(self.actions) > 0:
                self._resolve(self._sel)
            else:
                self._resolve(-1)
            return True
        if k == KEY_UP:
            if self._sel > 0:
                self._sel -= 1
            return True
        if k == KEY_DOWN:
            if self._sel < len(self.actions) - 1:
                self._sel += 1
            return True
        return True

    def handle_mouse(mut self, event: Event, container_bounds: Rect) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_MOUSE:
            return True
        var rect = self._layout(container_bounds)
        if close_button_clicked(rect, event):
            self._resolve(-1)
            return True
        var n_actions = len(self.actions)
        var first_row = rect.b.y - n_actions - 1
        if event.button == MOUSE_BUTTON_LEFT and event.pressed:
            var my = event.pos.y
            var mx = event.pos.x
            if my >= first_row and my < first_row + n_actions \
                    and mx > rect.a.x and mx < rect.b.x:
                self._resolve(my - first_row)
                return True
        return True   # swallow stray events while modal
