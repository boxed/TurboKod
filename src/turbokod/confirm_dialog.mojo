"""Modal yes/no confirm dialog.

Replaces the y/N text-input prompt for binary install decisions
("Install rust LSP?", "Download Elm syntax grammar?", ...). The
dialog has two ``ShadowButton``s — Yes and No — and accepts either a
mouse click or one of the keyboard shortcuts ``Y``/``N``/``Enter``/
``Esc``. ``Tab`` (and Left/Right) toggles which button Enter
activates.

Default focus is No on opening: every caller today is asking "should
we go install something?", and a misclick of Enter shouldn't kick off
a network download. Callers that want Yes pre-focused pass
``default_yes=True``.
"""

from .buttons import (
    BUTTON_FIRED, BUTTON_NONE,
    ShadowButton, paint_shadow_button,
)
from .canvas import Canvas, wrap_to_width
from .colors import (
    Attr, BLACK, BLUE, GREEN, LIGHT_GRAY, WHITE,
)
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_ENTER, KEY_ESC, KEY_LEFT, KEY_RIGHT, KEY_TAB,
)
from .geometry import Rect
from .window import paint_drop_shadow


comptime _DEFAULT_WIDTH = 60
comptime _MIN_HEIGHT    = 5
comptime _MIN_WIDTH     = 24

comptime _YES_LABEL = String(" Yes ")
comptime _NO_LABEL  = String(" No ")


struct ConfirmDialog(Movable):
    """Modal dialog with a wrapped message and Yes / No buttons.

    Persistent ``ShadowButton``s — the press latch (see
    ``ShadowButton.handle_mouse``) survives across paint cycles, so
    the dialog has to outlive each frame. ``open()`` re-arms it,
    ``close()`` clears any stale press state.
    """
    var active: Bool
    var submitted: Bool
    """True after the user closes the dialog with a verdict. The
    host reads ``confirmed`` then calls ``close()``."""
    var confirmed: Bool
    """True if the user picked Yes; False on No / Esc."""
    var message: String
    var _yes_button: ShadowButton
    var _no_button: ShadowButton
    var _focus_yes: Bool
    """Which button Enter activates. Defaults to No (safer choice for
    install / download prompts)."""

    fn __init__(out self):
        self.active = False
        self.submitted = False
        self.confirmed = False
        self.message = String("")
        self._yes_button = ShadowButton(_YES_LABEL, 0, 0)
        self._no_button = ShadowButton(_NO_LABEL, 0, 0)
        self._focus_yes = False

    fn open(mut self, var message: String, default_yes: Bool = False):
        self.message = message^
        self.active = True
        self.submitted = False
        self.confirmed = False
        self._focus_yes = default_yes
        self._yes_button.pressed = False
        self._yes_button.pressed_inside = False
        self._no_button.pressed = False
        self._no_button.pressed_inside = False

    fn close(mut self):
        self.active = False
        self.submitted = False
        self.confirmed = False
        self.message = String("")
        self._focus_yes = False
        self._yes_button.pressed = False
        self._yes_button.pressed_inside = False
        self._no_button.pressed = False
        self._no_button.pressed_inside = False

    fn _layout(self, screen: Rect) -> Rect:
        var width = _DEFAULT_WIDTH
        if width > screen.b.x - 4:
            width = screen.b.x - 4
        if width < _MIN_WIDTH:
            width = _MIN_WIDTH
        var text_w = width - 4
        if text_w < 1:
            text_w = 1
        var lines = wrap_to_width(self.message, text_w)
        var msg_rows = len(lines)
        if msg_rows < 1:
            msg_rows = 1
        # Layout from top: border / msg rows / gap / button row / shadow / border.
        var height = 1 + msg_rows + 1 + 1 + 1 + 1
        if height < _MIN_HEIGHT:
            height = _MIN_HEIGHT
        if height > screen.b.y - 4:
            height = screen.b.y - 4
        var x = (screen.b.x - width) // 2
        var y = (screen.b.y - height) // 2
        if x < 0: x = 0
        if y < 0: y = 0
        return Rect(x, y, x + width, y + height)

    fn paint(mut self, mut canvas: Canvas, screen: Rect):
        if not self.active:
            return
        var attr = Attr(BLACK, LIGHT_GRAY)
        var rect = self._layout(screen)
        paint_drop_shadow(canvas, rect)
        canvas.fill(rect, String(" "), attr)
        canvas.draw_box(rect, attr, False)
        var content_x = rect.a.x + 2
        var clip_x = rect.b.x - 1
        # Reserve the bottom-most three rows for the button row + its
        # drop shadow + the dialog's bottom border.
        var msg_rect = Rect(
            content_x, rect.a.y + 1,
            clip_x, rect.b.y - 3,
        )
        _ = canvas.put_wrapped_text(msg_rect, self.message, attr)
        # Center the Yes / No pair on the row two from the bottom border.
        var by = rect.b.y - 3
        var yes_w = self._yes_button.total_width()
        var no_w = self._no_button.total_width()
        var gap = 2
        var total = yes_w + gap + no_w
        var bx = rect.a.x + (rect.width() - total) // 2
        if bx < rect.a.x + 2:
            bx = rect.a.x + 2
        self._yes_button.move_to(bx, by)
        self._no_button.move_to(bx + yes_w + gap, by)
        var yes_face: Attr
        var no_face: Attr
        if self._focus_yes:
            yes_face = Attr(WHITE, BLUE)
            no_face = Attr(BLACK, GREEN)
        else:
            yes_face = Attr(BLACK, GREEN)
            no_face = Attr(WHITE, BLUE)
        paint_shadow_button(canvas, self._yes_button, yes_face, LIGHT_GRAY)
        paint_shadow_button(canvas, self._no_button, no_face, LIGHT_GRAY)

    fn _resolve(mut self, yes: Bool):
        self.confirmed = yes
        self.submitted = True

    fn handle_key(mut self, event: Event) -> Bool:
        """Returns True if the event was consumed by the dialog."""
        if not self.active:
            return False
        if event.kind != EVENT_KEY:
            return True
        var k = event.key
        if k == KEY_ESC:
            self._resolve(False)
            return True
        if k == KEY_ENTER:
            self._resolve(self._focus_yes)
            return True
        if k == KEY_TAB or k == KEY_LEFT or k == KEY_RIGHT:
            self._focus_yes = not self._focus_yes
            return True
        if k == UInt32(0x59) or k == UInt32(0x79):
            self._resolve(True)
            return True
        if k == UInt32(0x4E) or k == UInt32(0x6E):
            self._resolve(False)
            return True
        return True

    fn handle_mouse(mut self, event: Event, screen: Rect) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_MOUSE:
            return True
        var s = self._yes_button.handle_mouse(event)
        if s != BUTTON_NONE:
            if s == BUTTON_FIRED:
                self._resolve(True)
            return True
        s = self._no_button.handle_mouse(event)
        if s != BUTTON_NONE:
            if s == BUTTON_FIRED:
                self._resolve(False)
            return True
        return True   # swallow stray events while modal
