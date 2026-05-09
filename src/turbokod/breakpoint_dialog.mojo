"""Breakpoint context dialogs.

Two modal dialogs hang off the right-click on a breakpoint dot:

* ``BreakpointMenu`` — the "edit this breakpoint" dialog. Shows an
  enable checkbox and a single-line condition expression, with OK /
  Cancel.
* ``BreakpointConditionErrorDialog`` — opened when the adapter
  rejects the condition (debugpy reports ``verified=false`` with a
  message). Shows the error, an optional locals dump, the same
  condition field, and Try again / Disable & Continue / Cancel.

Both modals follow the codebase's existing dialog conventions:
``LIGHT_GRAY`` body, ``ShadowButton`` for actions, a focus chain
that ``Tab`` walks. They sit at the desktop layer like
``ConfirmDialog`` / ``GitGutterMenu`` — the host (Desktop) opens
them, paints them, and routes events to them ahead of any other
widget.
"""

from std.collections.list import List
from std.collections.optional import Optional

from .buttons import (
    BUTTON_FIRED, BUTTON_NONE, ShadowButton, paint_shadow_button,
)
from .canvas import Canvas
from .painter import Painter
from .cell import Cell
from .colors import (
    Attr, BLACK, BLUE, DARK_GRAY, GREEN, LIGHT_GRAY, LIGHT_RED,
    LIGHT_YELLOW, WHITE,
)
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_ENTER, KEY_ESC, KEY_LEFT, KEY_RIGHT, KEY_SPACE, KEY_TAB,
    KEY_UP, KEY_DOWN, MOD_SHIFT, MOUSE_BUTTON_LEFT,
)
from .geometry import Point, Rect
from .text_field import TextField, text_field_bg
from .window import paint_drop_shadow


comptime _DLG_WIDTH = 64
comptime _MIN_WIDTH = 32

# Focus tokens — small UInt8 enum walked by Tab. We model focus
# explicitly because the dialog has heterogeneous focusable elements
# (a checkbox plus a text field plus two buttons) and ``ShadowButton``
# alone doesn't carry focus state for a tab chain.
comptime _FOCUS_ENABLED   = UInt8(0)
comptime _FOCUS_CONDITION = UInt8(1)
comptime _FOCUS_OK        = UInt8(2)
comptime _FOCUS_CANCEL    = UInt8(3)


@fieldwise_init
struct BreakpointMenuResult(ImplicitlyCopyable, Movable):
    """Captured outcome of a closed ``BreakpointMenu``. ``confirmed`` is
    True iff the user pressed OK; otherwise ``enabled`` / ``condition``
    are unchanged from what the dialog opened with and the host should
    skip the apply step."""
    var confirmed: Bool
    var enabled: Bool
    var condition: String


struct BreakpointMenu(Movable):
    """Modal dialog for editing one breakpoint's enable + condition.

    The instance is held by the host across paints (the inner
    ``ShadowButton``s carry latch state across frames; recreating per
    frame would drop a captured press). ``open()`` re-arms it,
    ``close()`` clears all transient state.
    """

    var active: Bool
    var submitted: Bool
    var path: String
    """File the BP belongs to. Forwarded back to the host on submit so
    it can locate the BP in the DAP manager."""
    var line: Int
    """0-based buffer row. Same convention as ``DapManager._bp_line``."""
    var enabled: Bool
    """Live state of the Enabled checkbox."""
    var condition: TextField
    var _focus: UInt8
    var _ok: ShadowButton
    var _cancel: ShadowButton
    var _confirmed: Bool
    """Latch flipped when the user resolves with OK; remains False on
    Esc / Cancel. The host gates its apply step on this so cancelled
    dialogs leave the BP untouched."""

    fn __init__(out self):
        self.active = False
        self.submitted = False
        self.path = String("")
        self.line = -1
        self.enabled = True
        self.condition = TextField()
        self._focus = _FOCUS_CONDITION
        self._ok = ShadowButton(String(" OK "), 0, 0)
        self._cancel = ShadowButton(String(" Cancel "), 0, 0)
        self._confirmed = False

    fn open(
        mut self, var path: String, line: Int, enabled: Bool,
        var condition: String,
    ):
        self.active = True
        self.submitted = False
        self.path = path^
        self.line = line
        self.enabled = enabled
        self.condition = TextField()
        self.condition.set_text(condition^)
        self._focus = _FOCUS_CONDITION
        self._ok.pressed = False
        self._ok.pressed_inside = False
        self._cancel.pressed = False
        self._cancel.pressed_inside = False
        self._confirmed = False

    fn close(mut self):
        self.active = False
        self.submitted = False
        self.path = String("")
        self.line = -1
        self.condition = TextField()
        self._ok.pressed = False
        self._ok.pressed_inside = False
        self._cancel.pressed = False
        self._cancel.pressed_inside = False
        self._confirmed = False

    fn result(self) -> BreakpointMenuResult:
        """Captured state at submit time. Caller pulls this *before*
        calling ``close`` so the strings come out in the live form,
        not the post-close empty form."""
        return BreakpointMenuResult(
            self._confirmed, self.enabled, self.condition.text,
        )

    fn _layout(self, screen: Rect) -> Rect:
        var width = _DLG_WIDTH
        if width > screen.b.x - 4:
            width = screen.b.x - 4
        if width < _MIN_WIDTH:
            width = _MIN_WIDTH
        # Rows: top border / title / blank / [Enabled] line / blank /
        # Condition: label / input / blank / button row / shadow / bottom border
        var height = 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1
        if height > screen.b.y - 4:
            height = screen.b.y - 4
        var x = (screen.b.x - width) // 2
        var y = (screen.b.y - height) // 2
        if x < 0: x = 0
        if y < 0: y = 0
        return Rect(x, y, x + width, y + height)

    fn _input_rect(self, dlg: Rect) -> Rect:
        # Condition field sits on the row labelled below; +5 columns from
        # left frame gives "Cond: " a comfortable padding.
        var y = dlg.a.y + 6
        return Rect(dlg.a.x + 2, y, dlg.b.x - 2, y + 1)

    fn _enabled_rect(self, dlg: Rect) -> Rect:
        # Enabled checkbox row.
        var y = dlg.a.y + 3
        return Rect(dlg.a.x + 2, y, dlg.a.x + 2 + 14, y + 1)

    fn paint(mut self, mut canvas: Canvas, screen: Rect):
        if not self.active:
            return
        var attr = Attr(BLACK, LIGHT_GRAY)
        var rect = self._layout(screen)
        paint_drop_shadow(canvas, rect)
        var painter = Painter(rect)
        painter.fill(canvas, rect, String(" "), attr)
        painter.draw_box(canvas, rect, attr, False)
        # Title — show file:line.
        var title = String(" Breakpoint at ")
        var loc = self.path + String(":") + String(self.line + 1)
        # Cap the location to the dialog interior so it can't bleed
        # past the right border on a long path.
        var avail = rect.width() - 2 - len(title.as_bytes()) - 1
        var loc_b = loc.as_bytes()
        if avail < 0: avail = 0
        if len(loc_b) > avail:
            # Trim the head so the visible tail keeps the filename.
            var start = len(loc_b) - avail
            if start < 0: start = 0
            loc = String("…") + String(StringSlice(
                ptr=loc_b.unsafe_ptr() + start,
                length=len(loc_b) - start,
            ))
        _ = painter.put_text(
            canvas, Point(rect.a.x + 2, rect.a.y + 1), title + loc, attr,
        )
        # Enabled checkbox row.
        var en_rect = self._enabled_rect(rect)
        var en_attr = attr
        if self._focus == _FOCUS_ENABLED:
            en_attr = Attr(BLACK, GREEN)
            painter.fill(canvas, en_rect, String(" "), en_attr)
        var box_glyph = String("[x]") if self.enabled else String("[ ]")
        _ = painter.put_text(
            canvas, Point(en_rect.a.x, en_rect.a.y),
            box_glyph + String(" Enabled"), en_attr,
        )
        # Condition label + field.
        _ = painter.put_text(
            canvas, Point(rect.a.x + 2, rect.a.y + 5),
            String("Condition:"), attr,
        )
        var ir = self._input_rect(rect)
        self.condition.paint(canvas, ir, self._focus == _FOCUS_CONDITION)
        # Button row — bottom of dialog, two cells above the bottom
        # border to leave room for the shadow.
        var by = rect.b.y - 3
        var ok_w = self._ok.total_width()
        var cancel_w = self._cancel.total_width()
        var gap = 2
        var total = ok_w + gap + cancel_w
        var bx = rect.a.x + (rect.width() - total) // 2
        if bx < rect.a.x + 2:
            bx = rect.a.x + 2
        self._ok.move_to(bx, by)
        self._cancel.move_to(bx + ok_w + gap, by)
        var ok_face: Attr
        var cancel_face: Attr
        if self._focus == _FOCUS_OK:
            ok_face = Attr(WHITE, BLUE)
            cancel_face = Attr(BLACK, GREEN)
        elif self._focus == _FOCUS_CANCEL:
            ok_face = Attr(BLACK, GREEN)
            cancel_face = Attr(WHITE, BLUE)
        else:
            ok_face = Attr(BLACK, GREEN)
            cancel_face = Attr(BLACK, GREEN)
        paint_shadow_button(canvas, self._ok, ok_face, LIGHT_GRAY)
        paint_shadow_button(canvas, self._cancel, cancel_face, LIGHT_GRAY)

    fn _resolve(mut self, confirmed: Bool):
        self.submitted = True
        self._confirmed = confirmed

    fn _toggle_enabled(mut self):
        self.enabled = not self.enabled

    fn _focus_next(mut self, backward: Bool = False):
        # 4 stops: Enabled → Condition → OK → Cancel → wrap.
        if backward:
            if self._focus == _FOCUS_ENABLED:
                self._focus = _FOCUS_CANCEL
            elif self._focus == _FOCUS_CONDITION:
                self._focus = _FOCUS_ENABLED
            elif self._focus == _FOCUS_OK:
                self._focus = _FOCUS_CONDITION
            else:
                self._focus = _FOCUS_OK
            return
        if self._focus == _FOCUS_ENABLED:
            self._focus = _FOCUS_CONDITION
        elif self._focus == _FOCUS_CONDITION:
            self._focus = _FOCUS_OK
        elif self._focus == _FOCUS_OK:
            self._focus = _FOCUS_CANCEL
        else:
            self._focus = _FOCUS_ENABLED

    fn handle_key(mut self, event: Event) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_KEY:
            return True
        var k = event.key
        if k == KEY_ESC:
            self._resolve(False)
            return True
        if k == KEY_TAB:
            var backward = (event.mods & MOD_SHIFT) != 0
            self._focus_next(backward)
            return True
        if k == KEY_ENTER:
            # Enter on Enabled toggles; otherwise commits OK (Cancel is
            # explicit Esc / button).
            if self._focus == _FOCUS_ENABLED:
                self._toggle_enabled()
                return True
            if self._focus == _FOCUS_CANCEL:
                self._resolve(False)
                return True
            self._resolve(True)
            return True
        if self._focus == _FOCUS_ENABLED:
            if k == KEY_SPACE:
                self._toggle_enabled()
                return True
            return True
        if self._focus == _FOCUS_CONDITION:
            var r = self.condition.handle_key(event)
            if r.consumed:
                return True
            return True
        # Buttons: no per-key activate beyond Enter / Esc / Tab handled
        # above — the underlying ``ShadowButton`` only responds to mouse.
        return True

    fn handle_mouse(mut self, event: Event, screen: Rect) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_MOUSE:
            return True
        var rect = self._layout(screen)
        # Click inside the Enabled rect toggles the checkbox.
        if event.button == MOUSE_BUTTON_LEFT \
                and event.pressed and not event.motion:
            var er = self._enabled_rect(rect)
            if er.contains(event.pos):
                self._focus = _FOCUS_ENABLED
                self._toggle_enabled()
                return True
            var ir = self._input_rect(rect)
            if ir.contains(event.pos):
                self._focus = _FOCUS_CONDITION
        # Forward to the text field while focused.
        if self._focus == _FOCUS_CONDITION:
            var ir2 = self._input_rect(rect)
            if self.condition.handle_mouse(event, ir2):
                return True
        # Then to buttons.
        var s = self._ok.handle_mouse(event)
        if s != BUTTON_NONE:
            if s == BUTTON_FIRED:
                self._resolve(True)
            return True
        s = self._cancel.handle_mouse(event)
        if s != BUTTON_NONE:
            if s == BUTTON_FIRED:
                self._resolve(False)
            return True
        return True


# --- BreakpointConditionErrorDialog --------------------------------------


comptime _ERR_FOCUS_CONDITION = UInt8(0)
comptime _ERR_FOCUS_TRY       = UInt8(1)
comptime _ERR_FOCUS_DISABLE   = UInt8(2)
comptime _ERR_FOCUS_CANCEL    = UInt8(3)


# Result codes returned by the error dialog on submit. The host
# consults ``action`` *and* ``submitted`` — submitted alone doesn't
# tell us what to do because Try / Disable / Cancel all set it.
comptime BP_ERR_NONE    = UInt8(0)
comptime BP_ERR_TRY     = UInt8(1)
comptime BP_ERR_DISABLE = UInt8(2)
comptime BP_ERR_CANCEL  = UInt8(3)


struct BreakpointConditionErrorDialog(Movable):
    """Modal dialog that opens when the adapter rejects a BP condition.

    Shows the error message at the top, then any cached locals as
    ``name = value`` rows, then the editable condition, then three
    actions:

    * **Try again** — sends the (possibly edited) condition back to
      the BP so the host can re-issue ``setBreakpoints``.
    * **Disable & Continue** — flips the BP to disabled and the host
      should resume the program if it's paused.
    * **Cancel** — close without changes.

    The ``error`` text is updated by the host (via ``set_error``) when
    a re-submit comes back rejected — the dialog stays open and the
    user can edit and retry.
    """

    var active: Bool
    var submitted: Bool
    var action: UInt8
    var path: String
    var line: Int
    var error: String
    var locals_: List[String]
    """``name = value`` strings, capped to a few lines so a huge frame
    doesn't blow the dialog past the screen."""
    var condition: TextField
    var _focus: UInt8
    var _try: ShadowButton
    var _disable: ShadowButton
    var _cancel: ShadowButton

    fn __init__(out self):
        self.active = False
        self.submitted = False
        self.action = BP_ERR_NONE
        self.path = String("")
        self.line = -1
        self.error = String("")
        self.locals_ = List[String]()
        self.condition = TextField()
        self._focus = _ERR_FOCUS_CONDITION
        self._try = ShadowButton(String(" Try again "), 0, 0)
        self._disable = ShadowButton(
            String(" Disable & Continue "), 0, 0,
        )
        self._cancel = ShadowButton(String(" Cancel "), 0, 0)

    fn open(
        mut self, var path: String, line: Int,
        var error: String, var condition: String,
        var locals_: List[String],
    ):
        self.active = True
        self.submitted = False
        self.action = BP_ERR_NONE
        self.path = path^
        self.line = line
        self.error = error^
        self.locals_ = locals_^
        self.condition = TextField()
        self.condition.set_text(condition^)
        self._focus = _ERR_FOCUS_CONDITION
        self._try.pressed = False
        self._try.pressed_inside = False
        self._disable.pressed = False
        self._disable.pressed_inside = False
        self._cancel.pressed = False
        self._cancel.pressed_inside = False

    fn close(mut self):
        self.active = False
        self.submitted = False
        self.action = BP_ERR_NONE
        self.path = String("")
        self.line = -1
        self.error = String("")
        self.locals_ = List[String]()
        self.condition = TextField()

    fn set_error(mut self, var error: String):
        """Update the error text without closing — used when ``Try
        again`` re-submits an edited condition that's still bad."""
        self.error = error^
        self.submitted = False
        self.action = BP_ERR_NONE
        # Refocus the condition so the user can keep typing.
        self._focus = _ERR_FOCUS_CONDITION

    fn _layout(self, screen: Rect) -> Rect:
        var width = _DLG_WIDTH + 8
        if width > screen.b.x - 4:
            width = screen.b.x - 4
        if width < _MIN_WIDTH:
            width = _MIN_WIDTH
        # Rows: top / title / blank / "Error:" / err line / blank /
        # "Locals:" / N local rows / blank / "Condition:" / input /
        # blank / button row / shadow / bottom
        var loc_rows = len(self.locals_)
        if loc_rows > 6: loc_rows = 6
        var height = 1 + 1 + 1 + 1 + 1 + 1 + 1 + loc_rows + 1 + 1 + 1 + 1 + 1 + 1 + 1
        if height < 12:
            height = 12
        if height > screen.b.y - 4:
            height = screen.b.y - 4
        var x = (screen.b.x - width) // 2
        var y = (screen.b.y - height) // 2
        if x < 0: x = 0
        if y < 0: y = 0
        return Rect(x, y, x + width, y + height)

    fn _input_rect(self, dlg: Rect) -> Rect:
        # Condition row sits two rows above the button strip + shadow +
        # bottom border (3 rows of bottom chrome, one blank above input).
        var y = dlg.b.y - 5
        return Rect(dlg.a.x + 2, y, dlg.b.x - 2, y + 1)

    fn paint(mut self, mut canvas: Canvas, screen: Rect):
        if not self.active:
            return
        var attr = Attr(BLACK, LIGHT_GRAY)
        var err_attr = Attr(LIGHT_RED, LIGHT_GRAY)
        var rect = self._layout(screen)
        paint_drop_shadow(canvas, rect)
        var painter = Painter(rect)
        painter.fill(canvas, rect, String(" "), attr)
        painter.draw_box(canvas, rect, attr, False)
        var title = String(" Bad breakpoint condition — ")
        _ = painter.put_text(
            canvas, Point(rect.a.x + 2, rect.a.y + 1),
            title + self.path + String(":") + String(self.line + 1),
            attr,
        )
        # Error line.
        _ = painter.put_text(
            canvas, Point(rect.a.x + 2, rect.a.y + 3),
            String("Error: ") + self.error, err_attr,
        )
        # Locals.
        _ = painter.put_text(
            canvas, Point(rect.a.x + 2, rect.a.y + 5),
            String("Locals:"), attr,
        )
        var max_rows = len(self.locals_)
        if max_rows > 6: max_rows = 6
        for i in range(max_rows):
            _ = painter.put_text(
                canvas, Point(rect.a.x + 4, rect.a.y + 6 + i),
                self.locals_[i], attr,
            )
        if len(self.locals_) == 0:
            _ = painter.put_text(
                canvas, Point(rect.a.x + 4, rect.a.y + 6),
                String("(no locals — not paused at this BP)"), attr,
            )
        # Condition input — label one row above the input strip.
        var ir = self._input_rect(rect)
        _ = painter.put_text(
            canvas, Point(rect.a.x + 2, ir.a.y - 1),
            String("Condition:"), attr,
        )
        self.condition.paint(canvas, ir, self._focus == _ERR_FOCUS_CONDITION)
        # Buttons.
        var by = rect.b.y - 3
        var tw = self._try.total_width()
        var dw = self._disable.total_width()
        var cw = self._cancel.total_width()
        var gap = 2
        var total = tw + gap + dw + gap + cw
        var bx = rect.a.x + (rect.width() - total) // 2
        if bx < rect.a.x + 2:
            bx = rect.a.x + 2
        self._try.move_to(bx, by)
        self._disable.move_to(bx + tw + gap, by)
        self._cancel.move_to(bx + tw + gap + dw + gap, by)
        var try_face = Attr(BLACK, GREEN)
        var dis_face = Attr(BLACK, GREEN)
        var can_face = Attr(BLACK, GREEN)
        if self._focus == _ERR_FOCUS_TRY:
            try_face = Attr(WHITE, BLUE)
        elif self._focus == _ERR_FOCUS_DISABLE:
            dis_face = Attr(WHITE, BLUE)
        elif self._focus == _ERR_FOCUS_CANCEL:
            can_face = Attr(WHITE, BLUE)
        paint_shadow_button(canvas, self._try, try_face, LIGHT_GRAY)
        paint_shadow_button(canvas, self._disable, dis_face, LIGHT_GRAY)
        paint_shadow_button(canvas, self._cancel, can_face, LIGHT_GRAY)

    fn _focus_next(mut self, backward: Bool = False):
        if backward:
            if self._focus == _ERR_FOCUS_CONDITION:
                self._focus = _ERR_FOCUS_CANCEL
            elif self._focus == _ERR_FOCUS_TRY:
                self._focus = _ERR_FOCUS_CONDITION
            elif self._focus == _ERR_FOCUS_DISABLE:
                self._focus = _ERR_FOCUS_TRY
            else:
                self._focus = _ERR_FOCUS_DISABLE
            return
        if self._focus == _ERR_FOCUS_CONDITION:
            self._focus = _ERR_FOCUS_TRY
        elif self._focus == _ERR_FOCUS_TRY:
            self._focus = _ERR_FOCUS_DISABLE
        elif self._focus == _ERR_FOCUS_DISABLE:
            self._focus = _ERR_FOCUS_CANCEL
        else:
            self._focus = _ERR_FOCUS_CONDITION

    fn handle_key(mut self, event: Event) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_KEY:
            return True
        var k = event.key
        if k == KEY_ESC:
            self.action = BP_ERR_CANCEL
            self.submitted = True
            return True
        if k == KEY_TAB:
            var backward = (event.mods & MOD_SHIFT) != 0
            self._focus_next(backward)
            return True
        if k == KEY_ENTER:
            if self._focus == _ERR_FOCUS_DISABLE:
                self.action = BP_ERR_DISABLE
            elif self._focus == _ERR_FOCUS_CANCEL:
                self.action = BP_ERR_CANCEL
            else:
                self.action = BP_ERR_TRY
            self.submitted = True
            return True
        if self._focus == _ERR_FOCUS_CONDITION:
            var r = self.condition.handle_key(event)
            if r.consumed:
                return True
            return True
        return True

    fn handle_mouse(mut self, event: Event, screen: Rect) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_MOUSE:
            return True
        var rect = self._layout(screen)
        var ir = self._input_rect(rect)
        if event.button == MOUSE_BUTTON_LEFT \
                and event.pressed and not event.motion:
            if ir.contains(event.pos):
                self._focus = _ERR_FOCUS_CONDITION
        if self._focus == _ERR_FOCUS_CONDITION:
            if self.condition.handle_mouse(event, ir):
                return True
        var s = self._try.handle_mouse(event)
        if s != BUTTON_NONE:
            if s == BUTTON_FIRED:
                self.action = BP_ERR_TRY
                self.submitted = True
            return True
        s = self._disable.handle_mouse(event)
        if s != BUTTON_NONE:
            if s == BUTTON_FIRED:
                self.action = BP_ERR_DISABLE
                self.submitted = True
            return True
        s = self._cancel.handle_mouse(event)
        if s != BUTTON_NONE:
            if s == BUTTON_FIRED:
                self.action = BP_ERR_CANCEL
                self.submitted = True
            return True
        return True
