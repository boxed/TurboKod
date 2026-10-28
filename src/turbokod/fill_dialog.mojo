"""Multi-cursor "Fill..." dialog.

Opened from the Edit menu when an editor has multiple cursors active.
Lets the user insert either a fixed text or a numeric sequence (with
configurable start, increment, zero-padding, and base) at every
caret. The dialog owns no editor state — the host queries
``confirmed`` after submit and calls ``generate(n)`` to build the
per-caret string list, then routes it to the focused editor's
``apply_fill_strings``.

Follows the same dialog conventions as ``BreakpointMenu``:
``LIGHT_GRAY`` body, ``ShadowButton`` for actions, a ``FocusGroup``
that ``Tab`` walks, and Esc to cancel.
"""

from std.collections.list import List
from std.collections.optional import Optional

from .ui_tree import (
    UI_CANCEL, UI_DEFAULT, UI_SECONDARY, UINode, ui_bool, ui_buttons,
    ui_check, ui_choice, ui_dialog, ui_form, ui_int, ui_label, ui_row,
    ui_text, ui_vstack, ui_button,
)


# Choice labels for the mode picker.
comptime _MODE_TEXT    = String("Text")
comptime _MODE_NUMBERS = String("Numbers")

# Dropdown labels for the numeric format picker.
comptime _FMT_DEC = String("Decimal")
comptime _FMT_HEX = String("Hexadecimal")
comptime _FMT_OCT = String("Octal")
comptime _FMT_BIN = String("Binary")


def _parse_signed_int(s: String) -> Optional[Int]:
    """Parse a decimal integer with an optional leading ``-`` or ``+``.
    Returns the value or an empty Optional on any junk. Used for the
    initial / increment fields so the user can start from a negative
    base or step backwards through a range."""
    var b = s.as_bytes()
    var n = len(b)
    if n == 0:
        return Optional[Int]()
    var i = 0
    var sign = 1
    if b[0] == 0x2D:
        sign = -1
        i = 1
    elif b[0] == 0x2B:
        i = 1
    if i >= n:
        return Optional[Int]()
    var v = 0
    while i < n:
        var c = Int(b[i])
        if c < 0x30 or c > 0x39:
            return Optional[Int]()
        v = v * 10 + (c - 0x30)
        i += 1
    return Optional[Int](sign * v)


def _format_int(value: Int, base: Int, min_digits: Int) -> String:
    """Render ``value`` in the chosen base, padded with leading zeros
    to at least ``min_digits`` digits. ``base`` is 2 / 8 / 10 / 16. A
    leading ``-`` sign is preserved; padding applies to the digit
    portion so ``-5`` with width 3 reads ``-005``."""
    var negative = value < 0
    var n = -value if negative else value
    var rev = List[UInt8]()
    if n == 0:
        rev.append(UInt8(0x30))
    else:
        while n > 0:
            var d = n % base
            n = n // base
            var ch: Int
            if d < 10:
                ch = 0x30 + d
            else:
                ch = 0x61 + (d - 10)
            rev.append(UInt8(ch))
    var pad_n = min_digits - len(rev)
    var fwd = List[UInt8]()
    while pad_n > 0:
        fwd.append(UInt8(0x30))
        pad_n -= 1
    var i = len(rev) - 1
    while i >= 0:
        fwd.append(rev[i])
        i -= 1
    var digits = String(StringSpan(unsafe_from_utf8=Span(unsafe_ptr=fwd.unsafe_ptr(), length=len(fwd))))
    if negative:
        return String("-") + digits
    return digits


def _digit_width(value: Int, base: Int) -> Int:
    """Number of base-N digits needed to render ``abs(value)``. Used
    by the leading-zero pass to find the widest entry in the series so
    every generated number gets the same digit width."""
    var n = -value if value < 0 else value
    if n == 0:
        return 1
    var w = 0
    while n > 0:
        n = n // base
        w += 1
    return w


struct FillDialog(Movable):
    """Modal "Fill..." dialog: plain state plus its declarative UI
    (``ui`` / ``ui_set`` / ``ui_act``) — the grid projector and the native
    one both draw it from ``ui()``."""

    var active: Bool
    var submitted: Bool
    var caret_count: Int
    var mode: Int
    """Index into ``_mode_options()``: text or numbers."""
    var text: String
    var initial: String
    var increment: String
    var pad: Bool
    var format_: Int
    """Index into ``_format_options()``."""
    var error: String
    """Why OK was refused (an unparsable number); shown under the form."""
    var _confirmed: Bool

    def __init__(out self):
        self.active = False
        self.submitted = False
        self.caret_count = 0
        self.mode = 1
        self.text = String("")
        self.initial = String("1")
        self.increment = String("1")
        self.pad = False
        self.format_ = 0
        self.error = String("")
        self._confirmed = False

    def open(mut self, caret_count: Int):
        """Re-arm the dialog for a fresh invocation. The host passes the
        number of carets so ``generate`` can later produce exactly one
        string per caret without the caller having to thread it back
        in. Each field is re-seeded so a prior session's edits don't
        carry over silently."""
        self = FillDialog()
        self.active = True
        self.caret_count = caret_count

    def close(mut self):
        self = FillDialog()

    def confirmed(self) -> Bool:
        return self._confirmed

    def is_numbers_mode(self) -> Bool:
        return self.mode == 1

    # --- declarative UI ------------------------------------------------

    def ui(self) -> UINode:
        var numbers = self.is_numbers_mode()
        var rows = List[UINode]()
        rows.append(ui_row(String("Insert"), ui_choice(
            String("mode"), _mode_options(), self.mode,
        )))
        rows.append(ui_row(String("Text to insert"), ui_text(
            String("text"), self.text, enabled=not numbers,
        )))
        rows.append(ui_row(String("Initial number"), ui_text(
            String("initial"), self.initial, enabled=numbers,
        )))
        rows.append(ui_row(String("Increment"), ui_text(
            String("increment"), self.increment, enabled=numbers,
        )))
        rows.append(ui_row(String("Number format"), ui_choice(
            String("format"), _format_options(), self.format_, enabled=numbers,
        )))
        rows.append(ui_row(String(""), ui_check(
            String("pad"), String("Pad with leading zeros"), self.pad,
            enabled=numbers,
        )))
        var body = List[UINode]()
        body.append(ui_form(rows^))
        if len(self.error.as_bytes()) > 0:
            body.append(ui_label(self.error, UI_SECONDARY))
        var buttons = List[UINode]()
        buttons.append(ui_button(String("cancel"), String("Cancel"), UI_CANCEL))
        buttons.append(ui_button(String("ok"), String("Fill"), UI_DEFAULT))
        body.append(ui_buttons(buttons^))
        return ui_dialog(
            String("Fill ") + String(self.caret_count) + String(" cursors"),
            String("cancel"), ui_vstack(body^),
        )

    def ui_set(mut self, key: String, value: String):
        if key == String("mode"):
            self.mode = ui_int(value, self.mode)
        elif key == String("text"):
            self.text = value
        elif key == String("initial"):
            self.initial = value
        elif key == String("increment"):
            self.increment = value
        elif key == String("format"):
            self.format_ = ui_int(value, self.format_)
        elif key == String("pad"):
            self.pad = ui_bool(value)
        self.error = String("")

    def ui_act(mut self, id: String):
        if id == String("cancel"):
            self._resolve(False)
        elif id == String("ok"):
            self._resolve(True)

    def native_answer(
        mut self, ok: Bool, mode: Int, var text: String, var initial: String,
        var increment: String, pad: Bool, format_: Int,
    ):
        """All the fields at once, then OK / Cancel through the same
        validation (an unparsable number leaves the dialog open)."""
        self.mode = mode
        self.format_ = format_
        self.text = text^
        self.initial = initial^
        self.increment = increment^
        self.pad = pad
        self._resolve(ok)

    def generate(self, n: Int) -> List[String]:
        """Build the list of strings the host inserts at each caret.

        Length is exactly ``n``. In text mode every entry is the user's
        text verbatim; in numbers mode the entries are ``initial``,
        ``initial + increment``, ``initial + 2*increment``, … rendered
        in the chosen base. Padding (when enabled) is sized off the
        widest absolute value in the series so all generated digits
        line up.

        Malformed numeric inputs degrade to ``0`` for the relevant
        field — the dialog blocks submit on parse failure (see
        ``_can_submit``) so reaching this path with bad input means
        the host invoked us anyway and just gets zeros."""
        var out = List[String]()
        if not self.is_numbers_mode():
            for _ in range(n):
                out.append(self.text)
            return out^
        var init_opt = _parse_signed_int(self.initial)
        var inc_opt = _parse_signed_int(self.increment)
        var init_v = init_opt.value() if init_opt else 0
        var inc_v = inc_opt.value() if inc_opt else 0
        var base = 10
        if self.format_ == 1:
            base = 16
        elif self.format_ == 2:
            base = 8
        elif self.format_ == 3:
            base = 2
        var min_w = 0
        if self.pad and n > 0:
            # Width is the widest absolute-value digit count across the
            # whole series so every entry pads to the same length.
            for i in range(n):
                var v = init_v + i * inc_v
                var w = _digit_width(v, base)
                if w > min_w:
                    min_w = w
        for i in range(n):
            var v = init_v + i * inc_v
            out.append(_format_int(v, base, min_w))
        return out^

    def _can_submit(self) -> Bool:
        """Numbers mode requires both initial and increment to parse as
        signed decimals. Text mode is always submittable (an empty
        string fill is a legitimate "clear these spots" operation)."""
        if not self.is_numbers_mode():
            return True
        return Bool(_parse_signed_int(self.initial)) \
            and Bool(_parse_signed_int(self.increment))

    def _resolve(mut self, confirmed: Bool):
        if confirmed and not self._can_submit():
            if not _parse_signed_int(self.initial):
                self.error = String("The initial number must be a whole number.")
            else:
                self.error = String("The increment must be a whole number.")
            return
        self.submitted = True
        self._confirmed = confirmed


def _mode_options() -> List[String]:
    var o = List[String]()
    o.append(_MODE_TEXT)
    o.append(_MODE_NUMBERS)
    return o^


def _format_options() -> List[String]:
    var o = List[String]()
    o.append(_FMT_DEC)
    o.append(_FMT_HEX)
    o.append(_FMT_OCT)
    o.append(_FMT_BIN)
    return o^
