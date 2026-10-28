"""Modal confirm dialog: a wrapped message and a row of buttons, each
named for what it does.

There is deliberately no Yes / No. A button says what happens —
``Install``, ``Replace``, ``Delete`` — so the user can answer without
re-reading the question, and can't answer the wrong question by
reflex. ``open`` is the common two-button case (Cancel + one action);
``open_choices`` takes any list of labels (e.g. Cancel / Delete / Save
when closing a buffer with unsaved changes).

Each button answers to the first letter of its label (underlined on its
face); ``Esc`` and the ``[■]`` close glyph cancel; ``Enter`` presses the
focused button; ``Tab`` / Left / Right move focus. A destructive button
is painted red.
"""

from .buttons import (
    button_face, BUTTON_FIRED, BUTTON_NONE, paint_shadow_button, ShadowButton,
)
from .canvas import Canvas, wrap_to_width
from .colors import Attr, BLACK, LIGHT_GRAY, RED, WHITE, YELLOW
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE, KEY_ENTER, KEY_ESC, KEY_LEFT, KEY_RIGHT,
    KEY_TAB,
)
from .geometry import Rect, center_in
from .view import centered_row_start, FocusGroup
from .window import close_button_clicked, paint_modal_frame


comptime CONFIRM_DISMISSED = -1
"""``choice`` after Esc / the close glyph: no button was pressed."""


comptime _DEFAULT_WIDTH = 60
comptime _MIN_HEIGHT    = 5
comptime _MIN_WIDTH     = 24


def _lower_ascii(k: UInt32) -> UInt32:
    if k >= 0x41 and k <= 0x5A:
        return k + 0x20
    return k


struct ConfirmDialog(Movable):
    """Modal dialog with a wrapped message and named buttons.

    Persistent ``ShadowButton``s — the press latch (see
    ``ShadowButton.handle_mouse``) survives across paint cycles, so
    the dialog has to outlive each frame. ``open()`` re-arms it,
    ``close()`` clears any stale press state.
    """
    var active: Bool
    var submitted: Bool
    """True after the user closes the dialog with a verdict. The
    host reads ``confirmed`` / ``choice`` then calls ``close()``."""
    var confirmed: Bool
    """``open``: True if the user pressed the action button; False on
    Cancel / Esc. ``open_choices`` callers read ``choice`` instead."""
    var choice: Int
    """Index of the pressed button, or ``CONFIRM_DISMISSED``."""
    var message: String
    var _buttons: List[ShadowButton]
    var _keys: List[UInt32]
    """``_keys[i]``: lowercase answer key of ``_buttons[i]`` (0 = none)."""
    var _destructive: Int
    """Index of the button painted red, or -1."""
    var _confirm_index: Int
    """The button that sets ``confirmed`` (``open``'s action), or -1."""
    var _focus: FocusGroup

    def __init__(out self):
        self.active = False
        self.submitted = False
        self.confirmed = False
        self.choice = CONFIRM_DISMISSED
        self.message = String("")
        self._buttons = List[ShadowButton]()
        self._keys = List[UInt32]()
        self._destructive = -1
        self._confirm_index = -1
        self._focus = FocusGroup(0)

    def open(
        mut self, var message: String, action: String,
        default_action: Bool = False, destructive: Bool = False,
        cancel: String = String("Cancel"),
    ):
        """Ask ``message`` with a ``cancel`` button and an ``action``
        button. Focus starts on Cancel unless ``default_action`` — keep
        it there for anything that downloads, overwrites or deletes, so
        a stray Enter does nothing. ``destructive`` paints the action
        red."""
        var labels = List[String]()
        labels.append(cancel)
        labels.append(action)
        self.open_choices(
            message^, labels, 1 if default_action else 0,
            1 if destructive else -1,
        )
        self._confirm_index = 1

    def open_choices(
        mut self, var message: String, labels: List[String],
        default_index: Int, destructive_index: Int = -1,
    ):
        """Ask ``message`` with one button per label, left to right;
        ``choice`` reports which was pressed. Labels must start with
        distinct letters — those are the answer keys."""
        self._buttons = List[ShadowButton]()
        self._keys = List[UInt32]()
        for i in range(len(labels)):
            self._buttons.append(ShadowButton(
                String(" ") + labels[i] + String(" "), 0, 0, hotkey_col=1,
            ))
            var key = UInt32(0)
            var b = labels[i].as_bytes()
            if len(b) > 0:
                key = _lower_ascii(UInt32(b[0]))
            self._keys.append(key)
        self._focus = FocusGroup(len(labels))
        self._focus.focus_force(default_index)
        self._destructive = destructive_index
        self._confirm_index = -1
        self.message = message^
        self.active = True
        self.submitted = False
        self.confirmed = False
        self.choice = CONFIRM_DISMISSED

    def close(mut self):
        self.active = False
        self.submitted = False
        self.confirmed = False
        self.choice = CONFIRM_DISMISSED
        self.message = String("")
        self._buttons = List[ShadowButton]()
        self._keys = List[UInt32]()
        self._destructive = -1
        self._confirm_index = -1
        self._focus = FocusGroup(0)

    def _layout(self, container_bounds: Rect) -> Rect:
        var width = _DEFAULT_WIDTH
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
        # Layout from top: border / msg rows / gap / button row / shadow / border.
        var height = 1 + msg_rows + 1 + 1 + 1 + 1
        if height < _MIN_HEIGHT:
            height = _MIN_HEIGHT
        return center_in(container_bounds, width, height)

    def paint(mut self, mut canvas: Canvas, container_bounds: Rect):
        if not self.active:
            return
        var attr = Attr(BLACK, LIGHT_GRAY)
        var rect = self._layout(container_bounds)
        _ = paint_modal_frame(canvas, rect, attr)
        var content_x = rect.a.x + 2
        var clip_x = rect.b.x - 1
        # Reserve the bottom-most three rows for the button row + its
        # drop shadow + the dialog's bottom border.
        var msg_rect = Rect(
            content_x, rect.a.y + 1,
            clip_x, rect.b.y - 3,
        )
        _ = canvas.put_wrapped_text(msg_rect, self.message, attr)
        # Center the button row two rows up from the bottom border.
        var by = rect.b.y - 3
        var gap = 2
        var total = 0
        for i in range(len(self._buttons)):
            if i > 0:
                total += gap
            total += self._buttons[i].total_width()
        var bx = centered_row_start(rect, total)
        for i in range(len(self._buttons)):
            self._buttons[i].move_to(bx, by)
            bx += self._buttons[i].total_width() + gap
            # Use hit_rect (face + shadow) so the focusable area matches
            # exactly where the button's own handle_mouse fires — otherwise
            # a click on a button's shadow cell fires the action without
            # moving focus there.
            self._focus.update(i, self._buttons[i].hit_rect())
        for i in range(len(self._buttons)):
            var focused = self._focus.is_focused(i)
            var face = button_face(focused)
            if i == self._destructive:
                face = Attr(YELLOW if focused else WHITE, RED)
            paint_shadow_button(canvas, self._buttons[i], face, LIGHT_GRAY)

    def _resolve(mut self, choice: Int):
        self.choice = choice
        self.confirmed = choice >= 0 and choice == self._confirm_index
        self.submitted = True

    def handle_key(mut self, event: Event) -> Bool:
        """Returns True if the event was consumed by the dialog."""
        if not self.active:
            return False
        if event.kind != EVENT_KEY:
            return True
        var k = event.key
        if k == KEY_ESC:
            self._resolve(CONFIRM_DISMISSED)
            return True
        if k == KEY_ENTER:
            self._resolve(self._focus.focused)
            return True
        if k == KEY_TAB or k == KEY_RIGHT:
            self._focus.cycle()
            return True
        if k == KEY_LEFT:
            self._focus.cycle(backward=True)
            return True
        var lk = _lower_ascii(k)
        for i in range(len(self._keys)):
            if self._keys[i] != 0 and self._keys[i] == lk:
                self._resolve(i)
                return True
        return True

    def handle_mouse(mut self, event: Event, container_bounds: Rect) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_MOUSE:
            return True
        # Standard ``[■]`` close button — equivalent to ESC.
        # Checked before button routing so a click on the chrome glyph
        # always resolves the dialog as dismissed.
        var rect = self._layout(container_bounds)
        if close_button_clicked(rect, event):
            self._resolve(CONFIRM_DISMISSED)
            return True
        # Click on a button face moves focus there (used when the user
        # picks one button with the mouse but might then tab away).
        # Hovering does NOT shift focus — the FocusGroup's hit-test
        # only fires on press-and-not-motion.
        _ = self._focus.handle_click(event)
        for i in range(len(self._buttons)):
            var s = self._buttons[i].handle_mouse(event)
            if s != BUTTON_NONE:
                if s == BUTTON_FIRED:
                    self._resolve(i)
                return True
        return True   # swallow stray events while modal
