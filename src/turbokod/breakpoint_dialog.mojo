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
from .geometry import Point, Rect, center_in
from .string_utils import display_columns, tail_to_columns
from .text_field import TextField, text_field_bg
from .view import centered_row_start, FocusGroup, RowCursor
from .window import close_button_clicked, paint_close_button


comptime _DLG_WIDTH = 64
comptime _MIN_WIDTH = 32

# Tab order = slot order. The dialog has heterogeneous focusable
# elements (checkbox, dropdown, text field, two buttons); the
# FocusGroup pre-allocates a fixed slot per widget and the dialog
# refreshes each slot's rect + visitability per paint.
comptime _SLOT_ENABLED   = 0
comptime _SLOT_WAIT_FOR  = 1
comptime _SLOT_CONDITION = 2
comptime _SLOT_OK        = 3
comptime _SLOT_CANCEL    = 4

# Sentinel option in the wait-for dropdown that means "no dependency"
# — distinct from the empty-string fallback because the empty string
# *is* a valid dropdown value (it doubles as "stored as empty in the
# BP"). Using a literal "(none)" as the visible option keeps the
# popup readable; the dialog translates between this label and the
# empty string when reading/writing the value.
comptime _WAIT_FOR_NONE = String("(none)")


@fieldwise_init
struct _MenuLayout(ImplicitlyCopyable, Movable):
    """Pre-computed row anchors + rects for the BreakpointMenu.

    Top-flowing controls (title, Enabled checkbox, wait-for, condition)
    are placed via ``RowCursor`` so each pair of distinct controls is
    separated by a blank row. The labels for wait-for and condition
    sit one row above their inputs (place_tight) — label + input read
    as a single logical control.
    """
    var title_y: Int
    var checkbox_y: Int
    var wait_for_label_y: Int
    var wait_for_rect: Rect
    var condition_label_y: Int
    var condition_rect: Rect
    var buttons_y: Int


def _build_menu_layout(rect: Rect) -> _MenuLayout:
    var cursor = RowCursor(rect.a.y + 1)
    var title_y = cursor.place()
    var checkbox_y = cursor.place()
    var wait_for_label_y = cursor.place()
    var wait_for_y = cursor.place_tight()
    var condition_label_y = cursor.place()
    var condition_y = cursor.place_tight()
    var left = rect.a.x + 2
    var right = rect.b.x - 2
    return _MenuLayout(
        title_y, checkbox_y, wait_for_label_y,
        Rect(left, wait_for_y, right, wait_for_y + 1),
        condition_label_y,
        Rect(left, condition_y, right, condition_y + 1),
        rect.b.y - 3,
    )


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
    var _focus: FocusGroup
    var _ok: ShadowButton
    var _cancel: ShadowButton
    var _confirmed: Bool
    """Latch flipped when the user resolves with OK; remains False on
    Esc / Cancel. The host gates its apply step on this so cancelled
    dialogs leave the BP untouched."""

    def __init__(out self):
        self.active = False
        self.submitted = False
        self.path = String("")
        self.line = -1
        self.enabled = Checkbox(String("Enabled"), 0, 0, True)
        self.wait_for = _build_wait_for_dropdown(
            List[String](), String(""),
        )
        self.condition = TextField()
        self._focus = FocusGroup(5)
        self._focus.focus_force(_SLOT_CONDITION)
        self._ok = ShadowButton(String(" OK "), 0, 0)
        self._cancel = ShadowButton(String(" Cancel "), 0, 0)
        self._confirmed = False

    def open(
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
        self._focus.focus_force(_SLOT_CONDITION)
        self._ok.pressed = False
        self._ok.pressed_inside = False
        self._cancel.pressed = False
        self._cancel.pressed_inside = False
        self._confirmed = False

    def close(mut self):
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

    def result(self) -> BreakpointMenuResult:
        """Captured state at submit time. Caller pulls this *before*
        calling ``close`` so the strings come out in the live form,
        not the post-close empty form."""
        return BreakpointMenuResult(
            self._confirmed, self.enabled.on, self.condition.text,
            _wait_for_value(self.wait_for),
        )

    def _layout(self, container_bounds: Rect) -> Rect:
        var width = _DLG_WIDTH
        if width > container_bounds.b.x - 4:
            width = container_bounds.b.x - 4
        if width < _MIN_WIDTH:
            width = _MIN_WIDTH
        # Rows: top border / title / blank / [Enabled] line / blank /
        # "Enable after BP:" label / wait-for dropdown / blank /
        # Condition: label / input / blank / button row / shadow /
        # bottom border
        var height = 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1
        if height > container_bounds.b.y - 4:
            height = container_bounds.b.y - 4
        return center_in(container_bounds, width, height)

    def _position_checkbox(mut self, layout: _MenuLayout, dlg: Rect):
        """Repoint the checkbox at the dialog's current position. Run
        from both ``paint`` and ``handle_mouse`` so the chip's
        ``hit_rect`` is in sync with where it was last drawn even if
        the dialog has since moved/resized."""
        self.enabled.move_to(dlg.a.x + 2, layout.checkbox_y)

    def paint(mut self, mut canvas: Canvas, container_bounds: Rect):
        if not self.active:
            return
        var attr = Attr(BLACK, LIGHT_GRAY)
        var rect = self._layout(container_bounds)
        var layout = _build_menu_layout(rect)
        paint_drop_shadow(canvas, rect)
        var painter = Painter(rect)
        painter.fill(canvas, rect, String(" "), attr)
        painter = painter.draw_box_inner(canvas, rect, attr, False)
        # Standard ``[■]`` close button at the top-LEFT — equivalent to
        # ESC / Cancel. Same chrome the editor windows and other dialogs
        # use, painted via the shared ``paint_close_button`` helper.
        paint_close_button(canvas, Point(rect.a.x, rect.a.y), attr)
        # Title — show file:line.
        var title = String(" Breakpoint at ")
        var loc = self.path + String(":") + String(self.line + 1)
        # Cap the location to the dialog interior so it can't bleed
        # past the right border on a long path.
        var avail = rect.width() - 2 - display_columns(title) - 1
        if avail < 0: avail = 0
        if display_columns(loc) > avail:
            # Trim the head so the visible tail keeps the filename. Reserve
            # one column for the "…" prefix, and truncate by display columns
            # so a multi-byte path isn't sliced mid-codepoint.
            var visible = avail - 1
            if visible < 0: visible = 0
            loc = String("…") + tail_to_columns(loc, visible)
        _ = painter.put_text(
            canvas, Point(rect.a.x + 2, layout.title_y), title + loc, attr,
        )
        # Enabled checkbox: render the box+label on a contrasting
        # chip so the click target reads as wider than just the 3-cell
        # ``[x]`` glyph.
        self._position_checkbox(layout, rect)
        # Refresh focus slot rects. Checkbox + dropdown + condition
        # come straight from the layout; OK / Cancel get rects computed
        # below once buttons are positioned.
        self._focus.update(_SLOT_ENABLED, self.enabled.hit_rect(), True)
        self._focus.update(_SLOT_WAIT_FOR, layout.wait_for_rect, True)
        self._focus.update(_SLOT_CONDITION, layout.condition_rect, True)
        paint_checkbox(
            canvas, self.enabled,
            Attr(BLACK, CYAN), Attr(BLACK, GREEN),
            self._focus.is_focused(_SLOT_ENABLED),
            rect.b.x - 1,
        )
        # Wait-for label + dropdown.
        _ = painter.put_text(
            canvas, Point(rect.a.x + 2, layout.wait_for_label_y),
            String("Enable after another breakpoint is hit:"), attr,
        )
        self.wait_for.paint(
            canvas, layout.wait_for_rect,
            self._focus.is_focused(_SLOT_WAIT_FOR),
            Attr(WHITE, BLUE), Attr(BLACK, CYAN),
            _WAIT_FOR_NONE,
        )
        # Condition label + field.
        _ = painter.put_text(
            canvas, Point(rect.a.x + 2, layout.condition_label_y),
            String("Condition:"), attr,
        )
        self.condition.paint(
            canvas, layout.condition_rect,
            self._focus.is_focused(_SLOT_CONDITION),
        )
        # Button row — bottom of dialog, two cells above the bottom
        # border to leave room for the shadow.
        var by = layout.buttons_y
        var ok_w = self._ok.total_width()
        var cancel_w = self._cancel.total_width()
        var gap = 2
        var total = ok_w + gap + cancel_w
        var bx = centered_row_start(rect, total)
        self._ok.move_to(bx, by)
        self._cancel.move_to(bx + ok_w + gap, by)
        # Now that the buttons have their final positions, refresh the
        # focus slot rects so the FocusGroup's hit-test sees the same
        # geometry the user can click on.
        self._focus.update(
            _SLOT_OK,
            Rect(bx, by, bx + self._ok.face_width(), by + 1),
        )
        self._focus.update(
            _SLOT_CANCEL,
            Rect(bx + ok_w + gap, by,
                 bx + ok_w + gap + self._cancel.face_width(), by + 1),
        )
        var ok_face: Attr
        var cancel_face: Attr
        if self._focus.is_focused(_SLOT_OK):
            ok_face = Attr(WHITE, BLUE)
            cancel_face = Attr(BLACK, GREEN)
        elif self._focus.is_focused(_SLOT_CANCEL):
            ok_face = Attr(BLACK, GREEN)
            cancel_face = Attr(WHITE, BLUE)
        else:
            ok_face = Attr(BLACK, GREEN)
            cancel_face = Attr(BLACK, GREEN)
        paint_shadow_button(canvas, self._ok, ok_face, LIGHT_GRAY)
        paint_shadow_button(canvas, self._cancel, cancel_face, LIGHT_GRAY)

    def paint_popup(self, mut canvas: Canvas, container_bounds: Rect):
        """Render the wait-for dropdown popup on top. Caller invokes
        this after every other modal layer so the popup overlays them
        — same z-order pattern as ``Settings`` and ``ActionEditor``."""
        if not self.active or not self.wait_for.is_open:
            return
        var rect = self._layout(container_bounds)
        var layout = _build_menu_layout(rect)
        self.wait_for.paint_popup(canvas, layout.wait_for_rect, container_bounds)

    def _resolve(mut self, confirmed: Bool):
        self.submitted = True
        self._confirmed = confirmed

    def _toggle_enabled(mut self):
        self.enabled.toggle()

    def _focus_next(mut self, backward: Bool = False):
        # Slot order = tab order: Enabled → Wait-for → Condition → OK
        # → Cancel → wrap. Tabbing away from the wait-for dropdown
        # also closes its popup so a half-open menu doesn't bleed
        # past focus changes.
        if self._focus.is_focused(_SLOT_WAIT_FOR):
            self.wait_for.close()
        self._focus.cycle(backward)

    def handle_key(mut self, event: Event) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_KEY:
            return True
        var k = event.key
        # When the wait-for popup is open, route all keys to it first
        # so Up/Down/Enter navigate options instead of leaking to the
        # dialog focus walk. Esc closes the popup without dismissing
        # the dialog.
        if self._focus.is_focused(_SLOT_WAIT_FOR) and self.wait_for.is_open:
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
            if self._focus.is_focused(_SLOT_ENABLED):
                self._toggle_enabled()
                return True
            if self._focus.is_focused(_SLOT_WAIT_FOR):
                _ = self.wait_for.handle_key(event)
                return True
            if self._focus.is_focused(_SLOT_CANCEL):
                self._resolve(False)
                return True
            self._resolve(True)
            return True
        if self._focus.is_focused(_SLOT_ENABLED):
            if k == KEY_SPACE:
                self._toggle_enabled()
                return True
            return True
        if self._focus.is_focused(_SLOT_WAIT_FOR):
            # Down arrow opens the popup (matching the closed-state
            # behavior of ``Dropdown``). Other keys are swallowed.
            if self.wait_for.handle_key(event):
                return True
            return True
        if self._focus.is_focused(_SLOT_CONDITION):
            var r = self.condition.handle_key(event)
            if r.consumed:
                return True
            return True
        # Buttons: no per-key activate beyond Enter / Esc / Tab handled
        # above — the underlying ``ShadowButton`` only responds to mouse.
        return True

    def handle_mouse(mut self, event: Event, container_bounds: Rect) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_MOUSE:
            return True
        var rect = self._layout(container_bounds)
        var layout = _build_menu_layout(rect)
        self._position_checkbox(layout, rect)
        # Standard ``[■]`` close button — equivalent to ESC / Cancel.
        # Checked before any other routing so a click on the chrome
        # glyph always dismisses the dialog without applying changes.
        if close_button_clicked(rect, event):
            self._resolve(False)
            return True
        # Run the dropdown first when its popup is open: the popup
        # overlays everything else, so a click that lands on it must
        # not also flip checkbox / text-field focus underneath.
        if self.wait_for.is_open:
            var hit = self.wait_for.handle_mouse(
                layout.wait_for_rect, container_bounds, event,
            )
            if hit == DROPDOWN_HIT_BODY or hit == DROPDOWN_HIT_POPUP:
                self._focus.focus_force(_SLOT_WAIT_FOR)
                return True
            if hit == DROPDOWN_HIT_OUTSIDE:
                # Popup auto-closed — let the click fall through to the
                # rest of the dialog so e.g. clicking Cancel while the
                # popup is open both closes the popup and presses the
                # button.
                pass
        # Refresh focus slot rects (paint hasn't run since the dialog
        # was last touched; geometry may have moved on a window
        # resize) and let FocusGroup move focus on a real click.
        # Hover never moves focus — that's the FocusGroup's contract.
        self._focus.update(_SLOT_ENABLED, self.enabled.hit_rect(), True)
        self._focus.update(_SLOT_WAIT_FOR, layout.wait_for_rect, True)
        self._focus.update(_SLOT_CONDITION, layout.condition_rect, True)
        self._focus.update(_SLOT_OK, self._ok.hit_rect(), True)
        self._focus.update(_SLOT_CANCEL, self._cancel.hit_rect(), True)
        _ = self._focus.handle_click(event)
        # Run the Enabled chip first — it captures mouse on press, so
        # a press inside the chip is consumed even if the focus shift
        # to text-field below would otherwise grab it. The checkbox's
        # own toggle fires on FIRED status; focus has already moved.
        var cb_status = self.enabled.handle_mouse(event)
        if cb_status != BUTTON_NONE:
            if cb_status == BUTTON_FIRED:
                self.enabled.toggle()
            return True
        # Closed-dropdown click on the strip toggles it open. Done
        # after the checkbox check because the checkbox captures mouse
        # and would otherwise win on overlapping rows.
        if not self.wait_for.is_open:
            var hit2 = self.wait_for.handle_mouse(
                layout.wait_for_rect, container_bounds, event,
            )
            if hit2 == DROPDOWN_HIT_BODY:
                return True
        # Forward to the text field while focused.
        if self._focus.is_focused(_SLOT_CONDITION):
            if self.condition.handle_mouse(event, layout.condition_rect):
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


comptime _ERR_SLOT_CONDITION = 0
comptime _ERR_SLOT_TRY       = 1
comptime _ERR_SLOT_DISABLE   = 2
comptime _ERR_SLOT_CANCEL    = 3


@fieldwise_init
struct _ErrorLayout(ImplicitlyCopyable, Movable):
    """Pre-computed row anchors + rects for the error dialog.

    Top of the dialog flows through ``RowCursor`` (title, error,
    locals label + rows); the condition field + buttons are
    anchored to the bottom so the locals section can stretch in
    between without disturbing them.
    """
    var title_y: Int
    var error_y: Int
    var locals_label_y: Int
    var locals_start_y: Int
    var condition_label_y: Int
    var condition_rect: Rect
    var buttons_y: Int


def _build_error_layout(rect: Rect) -> _ErrorLayout:
    var cursor = RowCursor(rect.a.y + 1)
    var title_y = cursor.place()
    var error_y = cursor.place()
    var locals_label_y = cursor.place()
    # Locals rows sit directly under the label (the label heads the
    # block — no gap).
    var locals_start_y = locals_label_y + 1
    # Bottom-anchored chrome:
    var buttons_y = rect.b.y - 3
    var condition_y = rect.b.y - 5
    var condition_label_y = condition_y - 1
    var left = rect.a.x + 2
    var right = rect.b.x - 2
    return _ErrorLayout(
        title_y, error_y, locals_label_y, locals_start_y,
        condition_label_y,
        Rect(left, condition_y, right, condition_y + 1),
        buttons_y,
    )


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
    doesn't blow the dialog past the container_bounds."""
    var condition: TextField
    var _focus: FocusGroup
    var _try: ShadowButton
    var _disable: ShadowButton
    var _cancel: ShadowButton

    def __init__(out self):
        self.active = False
        self.submitted = False
        self.action = BP_ERR_NONE
        self.path = String("")
        self.line = -1
        self.error = String("")
        self.locals_ = List[String]()
        self.condition = TextField()
        self._focus = FocusGroup(4)
        self._focus.focus_force(_ERR_SLOT_CONDITION)
        self._try = ShadowButton(String(" Try again "), 0, 0)
        self._disable = ShadowButton(
            String(" Disable & Continue "), 0, 0,
        )
        self._cancel = ShadowButton(String(" Cancel "), 0, 0)

    def open(
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
        self._focus.focus_force(_ERR_SLOT_CONDITION)
        self._try.pressed = False
        self._try.pressed_inside = False
        self._disable.pressed = False
        self._disable.pressed_inside = False
        self._cancel.pressed = False
        self._cancel.pressed_inside = False

    def close(mut self):
        self.active = False
        self.submitted = False
        self.action = BP_ERR_NONE
        self.path = String("")
        self.line = -1
        self.error = String("")
        self.locals_ = List[String]()
        self.condition = TextField()

    def set_error(mut self, var error: String):
        """Update the error text without closing — used when ``Try
        again`` re-submits an edited condition that's still bad."""
        self.error = error^
        self.submitted = False
        self.action = BP_ERR_NONE
        # Refocus the condition so the user can keep typing.
        self._focus.focus_force(_ERR_SLOT_CONDITION)

    def _layout(self, container_bounds: Rect) -> Rect:
        var width = _DLG_WIDTH + 8
        if width > container_bounds.b.x - 4:
            width = container_bounds.b.x - 4
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
        if height > container_bounds.b.y - 4:
            height = container_bounds.b.y - 4
        return center_in(container_bounds, width, height)

    def paint(mut self, mut canvas: Canvas, container_bounds: Rect):
        if not self.active:
            return
        var attr = Attr(BLACK, LIGHT_GRAY)
        var err_attr = Attr(LIGHT_RED, LIGHT_GRAY)
        var rect = self._layout(container_bounds)
        var layout = _build_error_layout(rect)
        paint_drop_shadow(canvas, rect)
        var painter = Painter(rect)
        painter.fill(canvas, rect, String(" "), attr)
        painter = painter.draw_box_inner(canvas, rect, attr, False)
        # Standard ``[■]`` close button at the top-LEFT — equivalent to
        # ESC / Cancel. Same chrome the editor windows and other dialogs
        # use, painted via the shared ``paint_close_button`` helper.
        paint_close_button(canvas, Point(rect.a.x, rect.a.y), attr)
        var title = String(" Bad breakpoint condition — ")
        # Title bytes != cols (the em-dash is 3 bytes / 1 col); trim
        # budget has to be in display columns, not bytes.
        var title_cols = display_columns(title)
        var loc = self.path + String(":") + String(self.line + 1)
        var avail = rect.width() - 2 - title_cols - 1
        if avail < 0: avail = 0
        if display_columns(loc) > avail:
            # Trim the head so the visible tail keeps filename + line. Reserve
            # one column for the "…" prefix, and truncate by display columns
            # so a multi-byte path isn't sliced mid-codepoint.
            var visible = avail - 1
            if visible < 0: visible = 0
            loc = String("…") + tail_to_columns(loc, visible)
        _ = painter.put_text(
            canvas, Point(rect.a.x + 2, layout.title_y),
            title + loc, attr,
        )
        # Error line.
        _ = painter.put_text(
            canvas, Point(rect.a.x + 2, layout.error_y),
            String("Error: ") + self.error, err_attr,
        )
        # Locals.
        _ = painter.put_text(
            canvas, Point(rect.a.x + 2, layout.locals_label_y),
            String("Locals:"), attr,
        )
        var max_rows = len(self.locals_)
        if max_rows > 6: max_rows = 6
        for i in range(max_rows):
            _ = painter.put_text(
                canvas, Point(rect.a.x + 4, layout.locals_start_y + i),
                self.locals_[i], attr,
            )
        if len(self.locals_) == 0:
            _ = painter.put_text(
                canvas, Point(rect.a.x + 4, layout.locals_start_y),
                String("(no locals — not paused at this BP)"), attr,
            )
        # Condition input — label one row above the input strip.
        _ = painter.put_text(
            canvas, Point(rect.a.x + 2, layout.condition_label_y),
            String("Condition:"), attr,
        )
        self._focus.update(_ERR_SLOT_CONDITION, layout.condition_rect, True)
        self.condition.paint(
            canvas, layout.condition_rect,
            self._focus.is_focused(_ERR_SLOT_CONDITION),
        )
        # Buttons.
        var by = layout.buttons_y
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
        # Refresh focus slot rects from final button positions.
        self._focus.update(
            _ERR_SLOT_TRY,
            Rect(bx, by, bx + self._try.face_width(), by + 1),
        )
        self._focus.update(
            _ERR_SLOT_DISABLE,
            Rect(bx + tw + gap, by,
                 bx + tw + gap + self._disable.face_width(), by + 1),
        )
        self._focus.update(
            _ERR_SLOT_CANCEL,
            Rect(bx + tw + gap + dw + gap, by,
                 bx + tw + gap + dw + gap + self._cancel.face_width(),
                 by + 1),
        )
        var try_face = Attr(BLACK, GREEN)
        var dis_face = Attr(BLACK, GREEN)
        var can_face = Attr(BLACK, GREEN)
        if self._focus.is_focused(_ERR_SLOT_TRY):
            try_face = Attr(WHITE, BLUE)
        elif self._focus.is_focused(_ERR_SLOT_DISABLE):
            dis_face = Attr(WHITE, BLUE)
        elif self._focus.is_focused(_ERR_SLOT_CANCEL):
            can_face = Attr(WHITE, BLUE)
        paint_shadow_button(canvas, self._try, try_face, LIGHT_GRAY)
        paint_shadow_button(canvas, self._disable, dis_face, LIGHT_GRAY)
        paint_shadow_button(canvas, self._cancel, can_face, LIGHT_GRAY)

    def _focus_next(mut self, backward: Bool = False):
        # Slot order = tab order: Condition → Try → Disable → Cancel.
        self._focus.cycle(backward)

    def handle_key(mut self, event: Event) -> Bool:
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
            if self._focus.is_focused(_ERR_SLOT_DISABLE):
                self.action = BP_ERR_DISABLE
            elif self._focus.is_focused(_ERR_SLOT_CANCEL):
                self.action = BP_ERR_CANCEL
            else:
                self.action = BP_ERR_TRY
            self.submitted = True
            return True
        if self._focus.is_focused(_ERR_SLOT_CONDITION):
            var r = self.condition.handle_key(event)
            if r.consumed:
                return True
            return True
        return True

    def handle_mouse(mut self, event: Event, container_bounds: Rect) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_MOUSE:
            return True
        var rect = self._layout(container_bounds)
        var layout = _build_error_layout(rect)
        # Standard ``[■]`` close button — equivalent to ESC / Cancel.
        # Checked before any other routing so a click on the chrome
        # glyph always cancels the dialog without applying changes.
        if close_button_clicked(rect, event):
            self.action = BP_ERR_CANCEL
            self.submitted = True
            return True
        # Refresh slot rects + move focus on a real click. Hover does
        # not change focus — same FocusGroup contract every dialog uses.
        self._focus.update(_ERR_SLOT_CONDITION, layout.condition_rect, True)
        self._focus.update(_ERR_SLOT_TRY, self._try.hit_rect(), True)
        self._focus.update(_ERR_SLOT_DISABLE, self._disable.hit_rect(), True)
        self._focus.update(_ERR_SLOT_CANCEL, self._cancel.hit_rect(), True)
        _ = self._focus.handle_click(event)
        if self._focus.is_focused(_ERR_SLOT_CONDITION):
            if self.condition.handle_mouse(event, layout.condition_rect):
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


def _build_wait_for_dropdown(
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


def _wait_for_value(dd: Dropdown) -> String:
    """Translate a dropdown selection back to the storage form: the
    ``(none)`` sentinel maps to the empty string; everything else
    passes through verbatim."""
    var v = dd.value()
    if v == _WAIT_FOR_NONE:
        return String("")
    return v^
