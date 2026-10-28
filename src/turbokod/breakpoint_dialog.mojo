"""Breakpoint context dialogs.

Two modal dialogs hang off the right-click on a breakpoint dot:

* ``BreakpointMenu`` — the "edit this breakpoint" dialog: an enable
  checkbox, the breakpoint it waits for, and a condition expression.
* ``BreakpointConditionErrorDialog`` — opened when the adapter rejects
  the condition (debugpy reports ``verified=false`` with a message):
  the error, an optional locals dump, the same condition field, and
  Try Again / Disable & Continue / Cancel.

Both are plain state plus a declarative UI (``ui`` / ``ui_set`` /
``ui_act``, see ``ui_tree.mojo``); the grid and native projectors draw
them. The host (Desktop) opens them and reads the outcome.
"""

from std.collections.list import List

from .string_utils import display_columns, tail_to_columns
from .ui_tree import (
    UI_CANCEL, UI_DEFAULT, UI_HEADING, UI_SECONDARY, UINode, ui_bool,
    ui_button, ui_buttons, ui_check, ui_choice, ui_dialog, ui_form, ui_int,
    ui_label, ui_row, ui_text, ui_vstack,
)


# Sentinel option in the wait-for choice that means "no dependency" —
# the dialog translates between this label and the empty string the
# breakpoint stores.
comptime _WAIT_FOR_NONE = String("(none)")

comptime _MAX_LOCALS = 6
comptime _LOCATION_COLUMNS = 40


@fieldwise_init
struct BreakpointMenuResult(ImplicitlyCopyable, Movable):
    """Captured outcome of a closed ``BreakpointMenu``. ``confirmed`` is
    True iff the user pressed OK; otherwise ``enabled`` / ``condition``
    / ``wait_for`` are unchanged from what the dialog opened with and
    the host should skip the apply step.

    ``wait_for`` is the empty string for "no dependency" or a
    ``"<path>:<1-based-line>"`` key matching one of the options the
    host offered."""
    var confirmed: Bool
    var enabled: Bool
    var condition: String
    var wait_for: String


def _location(path: String, line: Int) -> String:
    """``<path>:<line+1>``, its head trimmed (``…``) to keep the filename
    and line visible in a title."""
    var loc = path + String(":") + String(line + 1)
    if display_columns(loc) > _LOCATION_COLUMNS:
        loc = String("…") + tail_to_columns(loc, _LOCATION_COLUMNS - 1)
    return loc^


struct BreakpointMenu(Movable):
    var active: Bool
    var submitted: Bool
    var path: String
    var line: Int
    var enabled: Bool
    var wait_for_options: List[String]
    """``(none)`` then every other breakpoint's key."""
    var wait_for: Int
    var condition: String
    var _confirmed: Bool

    def __init__(out self):
        self.active = False
        self.submitted = False
        self.path = String("")
        self.line = -1
        self.enabled = True
        self.wait_for_options = [_WAIT_FOR_NONE]
        self.wait_for = 0
        self.condition = String("")
        self._confirmed = False

    def open(
        mut self, var path: String, line: Int, enabled: Bool,
        var condition: String, var wait_for: String,
        var wait_for_options: List[String],
    ):
        """Open the dialog seeded with the BP's current state plus the
        full set of *other* BPs the user can chain off of.

        ``wait_for_options`` is the raw list of other-BP keys (no
        ``(none)`` prefix) — the dialog adds the sentinel itself. A
        ``wait_for`` naming a since-deleted breakpoint is kept as an extra
        option rather than silently snapping to ``(none)``."""
        self = BreakpointMenu()
        self.active = True
        self.path = path^
        self.line = line
        self.enabled = enabled
        self.condition = condition^
        for k in range(len(wait_for_options)):
            var o = wait_for_options[k]
            if len(o.as_bytes()) == 0 or o == _WAIT_FOR_NONE:
                continue
            self.wait_for_options.append(o)
        if len(wait_for.as_bytes()) > 0:
            var found = -1
            for k in range(len(self.wait_for_options)):
                if self.wait_for_options[k] == wait_for:
                    found = k
            if found < 0:
                self.wait_for_options.append(wait_for)
                found = len(self.wait_for_options) - 1
            self.wait_for = found

    def close(mut self):
        self = BreakpointMenu()

    def result(self) -> BreakpointMenuResult:
        """Captured state at submit time. Caller pulls this *before*
        calling ``close``."""
        var w = String("")
        if self.wait_for > 0 and self.wait_for < len(self.wait_for_options):
            w = self.wait_for_options[self.wait_for]
        return BreakpointMenuResult(
            self._confirmed, self.enabled, self.condition, w,
        )

    def ui(self) -> UINode:
        var rows = List[UINode]()
        rows.append(ui_row(String(""), ui_check(
            String("enabled"), String("Enabled"), self.enabled,
        )))
        rows.append(ui_row(String("Enable after"), ui_choice(
            String("wait_for"), self.wait_for_options.copy(), self.wait_for,
        )))
        rows.append(ui_row(String("Condition"), ui_text(
            String("condition"), self.condition, String("always stop"),
        )))
        var buttons = List[UINode]()
        buttons.append(ui_button(String("cancel"), String("Cancel"), UI_CANCEL))
        buttons.append(ui_button(String("ok"), String("Apply"), UI_DEFAULT))
        var body = List[UINode]()
        body.append(ui_form(rows^))
        body.append(ui_buttons(buttons^))
        return ui_dialog(
            String("Breakpoint at ") + _location(self.path, self.line),
            String("cancel"), ui_vstack(body^),
        )

    def ui_set(mut self, key: String, value: String):
        if key == String("enabled"):
            self.enabled = ui_bool(value)
        elif key == String("wait_for"):
            self.wait_for = ui_int(value, self.wait_for)
        elif key == String("condition"):
            self.condition = value

    def ui_act(mut self, id: String):
        if id == String("ok"):
            self._resolve(True)
        elif id == String("cancel"):
            self._resolve(False)

    def _resolve(mut self, confirmed: Bool):
        self.submitted = True
        self._confirmed = confirmed


# Result codes the error dialog submits with. The host consults
# ``action`` *and* ``submitted`` — submitted alone doesn't tell us what to
# do because Try / Disable / Cancel all set it.
comptime BP_ERR_NONE    = UInt8(0)
comptime BP_ERR_TRY     = UInt8(1)
comptime BP_ERR_DISABLE = UInt8(2)
comptime BP_ERR_CANCEL  = UInt8(3)


struct BreakpointConditionErrorDialog(Movable):
    """Opens when the adapter rejects a BP condition: the error, any
    cached locals as ``name = value`` rows, the editable condition, and
    Try Again (re-submit the edited condition) / Disable & Continue /
    Cancel. ``set_error`` updates the error in place when a re-submit
    comes back rejected — the dialog stays open for another try."""

    var active: Bool
    var submitted: Bool
    var action: UInt8
    var path: String
    var line: Int
    var error: String
    var locals_: List[String]
    var condition: String

    def __init__(out self):
        self.active = False
        self.submitted = False
        self.action = BP_ERR_NONE
        self.path = String("")
        self.line = -1
        self.error = String("")
        self.locals_ = List[String]()
        self.condition = String("")

    def open(
        mut self, var path: String, line: Int,
        var error: String, var condition: String,
        var locals_: List[String],
    ):
        self = BreakpointConditionErrorDialog()
        self.active = True
        self.path = path^
        self.line = line
        self.error = error^
        self.locals_ = locals_^
        self.condition = condition^

    def close(mut self):
        self = BreakpointConditionErrorDialog()

    def set_error(mut self, var error: String):
        """Update the error text without closing — used when ``Try
        again`` re-submits an edited condition that's still bad."""
        self.error = error^
        self.submitted = False
        self.action = BP_ERR_NONE

    def ui(self) -> UINode:
        var body = List[UINode]()
        body.append(ui_label(String("Error: ") + self.error, UI_HEADING))
        if len(self.locals_) > 0:
            var locs = List[UINode]()
            locs.append(ui_label(String("Locals"), UI_SECONDARY))
            for i in range(min(len(self.locals_), _MAX_LOCALS)):
                locs.append(ui_label(String("  ") + self.locals_[i]))
            body.append(ui_vstack(locs^, 0))
        var rows = List[UINode]()
        rows.append(ui_row(String("Condition"), ui_text(
            String("condition"), self.condition,
        )))
        body.append(ui_form(rows^))
        var buttons = List[UINode]()
        buttons.append(ui_button(String("cancel"), String("Cancel"), UI_CANCEL))
        buttons.append(ui_button(String("disable"), String("Disable & Continue")))
        buttons.append(ui_button(String("try"), String("Try Again"), UI_DEFAULT))
        body.append(ui_buttons(buttons^))
        return ui_dialog(
            String("Bad breakpoint condition — ") + _location(self.path, self.line),
            String("cancel"), ui_vstack(body^),
        )

    def ui_set(mut self, key: String, value: String):
        if key == String("condition"):
            self.condition = value

    def ui_act(mut self, id: String):
        if id == String("try"):
            self.action = BP_ERR_TRY
        elif id == String("disable"):
            self.action = BP_ERR_DISABLE
        else:
            self.action = BP_ERR_CANCEL
        self.submitted = True
