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
    BUTTON_FIRED, BUTTON_NONE, Checkbox, ShadowButton, paint_checkbox,
    paint_shadow_button,
)
from .canvas import Canvas, paint_drop_shadow
from .painter import Painter
from .cell import Cell
from .colors import (
    Attr, BLACK, BLUE, CYAN, DARK_GRAY, GREEN, LIGHT_GRAY, LIGHT_RED,
    LIGHT_YELLOW, WHITE,
)
from .dropdown import (
    DROPDOWN_HIT_BODY, DROPDOWN_HIT_NONE, DROPDOWN_HIT_OUTSIDE,
    DROPDOWN_HIT_POPUP, Dropdown,
)
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_ENTER, KEY_ESC, KEY_LEFT, KEY_RIGHT, KEY_SPACE, KEY_TAB,
    KEY_UP, KEY_DOWN, MOD_SHIFT, MOUSE_BUTTON_LEFT,
)
from .geometry import Point, Rect
from .text_field import TextField, text_field_bg


comptime _DLG_WIDTH = 64
comptime _MIN_WIDTH = 32

# Focus tokens — small UInt8 enum walked by Tab. We model focus
# explicitly because the dialog has heterogeneous focusable elements
# (a checkbox, a dropdown, a text field, two buttons) and
# ``ShadowButton`` alone doesn't carry focus state for a tab chain.
comptime _FOCUS_ENABLED   = UInt8(0)
comptime _FOCUS_WAIT_FOR  = UInt8(1)
comptime _FOCUS_CONDITION = UInt8(2)
comptime _FOCUS_OK        = UInt8(3)
comptime _FOCUS_CANCEL    = UInt8(4)

# Sentinel option in the wait-for dropdown that means "no dependency"
# — distinct from the empty-string fallback because the empty string
# *is* a valid dropdown value (it doubles as "stored as empty in the
# BP"). Using a literal "(none)" as the visible option keeps the
# popup readable; the dialog translates between this label and the
# empty string when reading/writing the value.
comptime _WAIT_FOR_NONE = String("(none)")


@fieldwise_init
struct BreakpointMenuResult(ImplicitlyCopyable, Movable):
    """Captured outcome of a closed ``BreakpointMenu``. ``confirmed`` is
    True iff the user pressed OK; otherwise ``enabled`` / ``condition``
    / ``wait_for`` are unchanged from what the dialog opened with and
    the host should skip the apply step.

    ``wait_for`` is the empty string for "no dependency" or a
    ``"<path>:<1-based-line>"`` key matching one of the options the
    host populated the dropdown with."""
    var confirmed: Bool
    var enabled: Bool
    var condition: String
    var wait_for: String


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
    var enabled: Checkbox
    """Live state + geometry for the Enabled checkbox chip."""
    var wait_for: Dropdown
    """Trigger-BP picker. Index 0 is always the ``(none)`` sentinel;
    indices ≥ 1 are ``"<path>:<1-based-line>"`` keys for the other
    breakpoints in the project, populated by the host on ``open``.
    The selected key is what gets pushed into ``_bp_wait_for`` — the
    sentinel resolves to an empty string."""
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
        self.enabled = Checkbox(String("Enabled"), 0, 0, True)
        self.wait_for = _build_wait_for_dropdown(
            List[String](), String(""),
        )
        self.condition = TextField()
        self._focus = _FOCUS_CONDITION
        self._ok = ShadowButton(String(" OK "), 0, 0)
        self._cancel = ShadowButton(String(" Cancel "), 0, 0)
        self._confirmed = False

    fn open(
        mut self, var path: String, line: Int, enabled: Bool,
        var condition: String, var wait_for: String,
        var wait_for_options: List[String],
    ):
        """Open the dialog seeded with the BP's current state plus the
        full set of *other* BPs the user can chain off of.

        ``wait_for_options`` is the raw list of other-BP keys (no
        ``(none)`` prefix) — the dialog adds the sentinel itself.
        """
        self.active = True
        self.submitted = False
        self.path = path^
        self.line = line
        self.enabled = Checkbox(String("Enabled"), 0, 0, enabled)
        self.wait_for = _build_wait_for_dropdown(
            wait_for_options^, wait_for^,
        )
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
        self.wait_for = _build_wait_for_dropdown(
            List[String](), String(""),
        )
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
            self._confirmed, self.enabled.on, self.condition.text,
            _wait_for_value(self.wait_for),
        )

    fn _layout(self, screen: Rect) -> Rect:
        var width = _DLG_WIDTH
        if width > screen.b.x - 4:
            width = screen.b.x - 4
        if width < _MIN_WIDTH:
            width = _MIN_WIDTH
        # Rows: top border / title / blank / [Enabled] line / blank /
        # "Enable after BP:" label / wait-for dropdown / blank /
        # Condition: label / input / blank / button row / shadow /
        # bottom border
        var height = 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1
        if height > screen.b.y - 4:
            height = screen.b.y - 4
        var x = (screen.b.x - width) // 2
        var y = (screen.b.y - height) // 2
        if x < 0: x = 0
        if y < 0: y = 0
        return Rect(x, y, x + width, y + height)

    fn _wait_for_rect(self, dlg: Rect) -> Rect:
        # Dropdown row sits on row 6 of the dialog (label on row 5).
        var y = dlg.a.y + 6
        return Rect(dlg.a.x + 2, y, dlg.b.x - 2, y + 1)

    fn _input_rect(self, dlg: Rect) -> Rect:
        # Condition field row, with the label on the row above.
        var y = dlg.a.y + 9
        return Rect(dlg.a.x + 2, y, dlg.b.x - 2, y + 1)

    fn _position_checkbox(mut self, dlg: Rect):
        """Repoint the checkbox at the dialog's current position. Run
        from both ``paint`` and ``handle_mouse`` so the chip's
        ``hit_rect`` is in sync with where it was last drawn even if
        the dialog has since moved/resized."""
        self.enabled.move_to(dlg.a.x + 2, dlg.a.y + 3)

    fn paint(mut self, mut canvas: Canvas, screen: Rect):
        if not self.active:
            return
        var attr = Attr(BLACK, LIGHT_GRAY)
        var rect = self._layout(screen)
        paint_drop_shadow(canvas, rect)
        var painter = Painter(rect)
        painter.fill(canvas, rect, String(" "), attr)
        painter = painter.draw_box_inner(canvas, rect, attr, False)
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
            # Reserve one column for the "…" prefix — without this
            # the prefix pushes one cell past avail.
            var visible = avail - 1
            if visible < 0: visible = 0
            var start = len(loc_b) - visible
            loc = String("…") + String(StringSlice(
                ptr=loc_b.unsafe_ptr() + start,
                length=visible,
            ))
        _ = painter.put_text(
            canvas, Point(rect.a.x + 2, rect.a.y + 1), title + loc, attr,
        )
        # Enabled checkbox: render the box+label on a contrasting
        # chip so the click target reads as wider than just the 3-cell
        # ``[x]`` glyph.
        self._position_checkbox(rect)
        paint_checkbox(
            canvas, self.enabled,
            Attr(BLACK, CYAN), Attr(BLACK, GREEN),
            self._focus == _FOCUS_ENABLED,
            rect.b.x - 1,
        )
        # Wait-for label + dropdown.
        _ = painter.put_text(
            canvas, Point(rect.a.x + 2, rect.a.y + 5),
            String("Enable after another breakpoint is hit:"), attr,
        )
        var wf_rect = self._wait_for_rect(rect)
        self.wait_for.paint(
            canvas, wf_rect, self._focus == _FOCUS_WAIT_FOR,
            Attr(WHITE, BLUE), Attr(BLACK, CYAN),
            _WAIT_FOR_NONE,
        )
        # Condition label + field.
        _ = painter.put_text(
            canvas, Point(rect.a.x + 2, rect.a.y + 8),
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

    fn paint_popup(self, mut canvas: Canvas, screen: Rect):
        """Render the wait-for dropdown popup on top. Caller invokes
        this after every other modal layer so the popup overlays them
        — same z-order pattern as ``Settings`` and ``ActionEditor``."""
        if not self.active or not self.wait_for.is_open:
            return
        var rect = self._layout(screen)
        var anchor = self._wait_for_rect(rect)
        self.wait_for.paint_popup(canvas, anchor, screen)

    fn _resolve(mut self, confirmed: Bool):
        self.submitted = True
        self._confirmed = confirmed

    fn _toggle_enabled(mut self):
        self.enabled.toggle()

    fn _focus_next(mut self, backward: Bool = False):
        # 5 stops: Enabled → Wait-for → Condition → OK → Cancel → wrap.
        # Tabbing away from the wait-for dropdown also closes its popup
        # so a half-open menu doesn't bleed past focus changes.
        if self._focus == _FOCUS_WAIT_FOR:
            self.wait_for.close()
        if backward:
            if self._focus == _FOCUS_ENABLED:
                self._focus = _FOCUS_CANCEL
            elif self._focus == _FOCUS_WAIT_FOR:
                self._focus = _FOCUS_ENABLED
            elif self._focus == _FOCUS_CONDITION:
                self._focus = _FOCUS_WAIT_FOR
            elif self._focus == _FOCUS_OK:
                self._focus = _FOCUS_CONDITION
            else:
                self._focus = _FOCUS_OK
            return
        if self._focus == _FOCUS_ENABLED:
            self._focus = _FOCUS_WAIT_FOR
        elif self._focus == _FOCUS_WAIT_FOR:
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
        # When the wait-for popup is open, route all keys to it first
        # so Up/Down/Enter navigate options instead of leaking to the
        # dialog focus walk. Esc closes the popup without dismissing
        # the dialog.
        if self._focus == _FOCUS_WAIT_FOR and self.wait_for.is_open:
            if k == KEY_ESC:
                self.wait_for.close()
                return True
            if self.wait_for.handle_key(event):
                return True
        if k == KEY_ESC:
            self._resolve(False)
            return True
        if k == KEY_TAB:
            var backward = (event.mods & MOD_SHIFT) != 0
            self._focus_next(backward)
            return True
        if k == KEY_ENTER:
            # Enter on Enabled toggles; on Wait-for opens the popup;
            # otherwise commits OK (Cancel is explicit Esc / button).
            if self._focus == _FOCUS_ENABLED:
                self._toggle_enabled()
                return True
            if self._focus == _FOCUS_WAIT_FOR:
                _ = self.wait_for.handle_key(event)
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
        if self._focus == _FOCUS_WAIT_FOR:
            # Down arrow opens the popup (matching the closed-state
            # behavior of ``Dropdown``). Other keys are swallowed.
            if self.wait_for.handle_key(event):
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
        self._position_checkbox(rect)
        var wf_anchor = self._wait_for_rect(rect)
        # Run the dropdown first when its popup is open: the popup
        # overlays everything else, so a click that lands on it must
        # not also flip checkbox / text-field focus underneath.
        if self.wait_for.is_open:
            var hit = self.wait_for.handle_mouse(wf_anchor, screen, event)
            if hit == DROPDOWN_HIT_BODY or hit == DROPDOWN_HIT_POPUP:
                self._focus = _FOCUS_WAIT_FOR
                return True
            if hit == DROPDOWN_HIT_OUTSIDE:
                # Popup auto-closed — let the click fall through to the
                # rest of the dialog so e.g. clicking Cancel while the
                # popup is open both closes the popup and presses the
                # button.
                pass
        # Run the Enabled chip first — it captures mouse on press, so
        # a press inside the chip is consumed even if the focus shift
        # to text-field below would otherwise grab it.
        var cb_status = self.enabled.handle_mouse(event)
        if cb_status != BUTTON_NONE:
            if cb_status == BUTTON_FIRED:
                self._focus = _FOCUS_ENABLED
                self.enabled.toggle()
            elif cb_status == BUTTON_CAPTURED \
                    and event.pressed and not event.motion:
                self._focus = _FOCUS_ENABLED
            return True
        # Closed-dropdown click on the strip toggles it open and grabs
        # focus. Done after the checkbox check because the checkbox
        # captures mouse and would otherwise win on overlapping rows.
        if not self.wait_for.is_open:
            var hit2 = self.wait_for.handle_mouse(
                wf_anchor, screen, event,
            )
            if hit2 == DROPDOWN_HIT_BODY:
                self._focus = _FOCUS_WAIT_FOR
                return True
        if event.button == MOUSE_BUTTON_LEFT \
                and event.pressed and not event.motion:
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
        painter = painter.draw_box_inner(canvas, rect, attr, False)
        var title = String(" Bad breakpoint condition — ")
        # Title bytes != cols (the em-dash is 3 bytes / 1 col); trim
        # budget has to be in display columns, not bytes.
        var tb = title.as_bytes()
        var title_cols = 0
        for i in range(len(tb)):
            if (Int(tb[i]) & 0xC0) != 0x80:
                title_cols += 1
        var loc = self.path + String(":") + String(self.line + 1)
        var avail = rect.width() - 2 - title_cols - 1
        var loc_b = loc.as_bytes()
        if avail < 0: avail = 0
        if len(loc_b) > avail:
            # Trim the head so the visible tail keeps filename + line.
            # Reserve one column for the "…" prefix.
            var visible = avail - 1
            if visible < 0: visible = 0
            var start = len(loc_b) - visible
            loc = String("…") + String(StringSlice(
                ptr=loc_b.unsafe_ptr() + start,
                length=visible,
            ))
        _ = painter.put_text(
            canvas, Point(rect.a.x + 2, rect.a.y + 1),
            title + loc, attr,
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


# --- wait-for dropdown helpers --------------------------------------------


fn _build_wait_for_dropdown(
    var options: List[String], var current: String,
) -> Dropdown:
    """Construct the trigger-BP dropdown with a leading ``(none)`` row
    plus one row per other-BP key. ``current`` is the BP's stored
    ``wait_for`` — empty selects ``(none)``; non-empty selects the
    matching option (or appends it as a synthetic entry, so a
    reference to a since-deleted BP is preserved across paint cycles
    rather than silently snapping to None)."""
    var entries = List[String]()
    entries.append(_WAIT_FOR_NONE)
    for k in range(len(options)):
        # Skip empties / accidental duplicates of the sentinel — the
        # sentinel is reserved for "no dependency."
        if len(options[k].as_bytes()) == 0:
            continue
        if options[k] == _WAIT_FOR_NONE:
            continue
        entries.append(options[k])
    var dd = Dropdown(entries^, 0)
    if len(current.as_bytes()) > 0:
        dd.set_value(current^)
    return dd^


fn _wait_for_value(dd: Dropdown) -> String:
    """Translate a dropdown selection back to the storage form: the
    ``(none)`` sentinel maps to the empty string; everything else
    passes through verbatim."""
    var v = dd.value()
    if v == _WAIT_FOR_NONE:
        return String("")
    return v^
