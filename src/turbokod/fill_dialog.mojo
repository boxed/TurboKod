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

from .buttons import (
    BUTTON_FIRED, BUTTON_NONE, Checkbox, ShadowButton, paint_checkbox,
    paint_shadow_button,
)
from .canvas import Canvas, paint_drop_shadow
from .painter import Painter
from .cell import Cell
from .colors import (
    Attr, BLACK, BLUE, CYAN, GREEN, LIGHT_GRAY, WHITE,
)
from .dropdown import (
    DROPDOWN_HIT_BODY, DROPDOWN_HIT_NONE, DROPDOWN_HIT_OUTSIDE,
    DROPDOWN_HIT_POPUP, Dropdown,
)
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_ENTER, KEY_ESC, KEY_SPACE, KEY_TAB,
    MOD_SHIFT, MOUSE_BUTTON_LEFT,
)
from .geometry import Point, Rect, center_in
from .text_field import TextField
from .view import FocusGroup, RowCursor
from .window import close_button_clicked, paint_close_button


comptime _DLG_WIDTH = 56
comptime _MIN_WIDTH = 36

# Tab order. Slots are registered in this order; ``cycle`` walks the
# visitable ones. Mode-dependent visitability is refreshed each paint
# so Tab skips the inputs that don't apply to the current mode.
comptime _SLOT_MODE      = 0
comptime _SLOT_TEXT      = 1
comptime _SLOT_INITIAL   = 2
comptime _SLOT_INCREMENT = 3
comptime _SLOT_PAD       = 4
comptime _SLOT_FORMAT    = 5
comptime _SLOT_OK        = 6
comptime _SLOT_CANCEL    = 7

# Dropdown labels for the mode picker.
comptime _MODE_TEXT    = String("Text")
comptime _MODE_NUMBERS = String("Numbers")

# Dropdown labels for the numeric format picker.
comptime _FMT_DEC = String("Decimal")
comptime _FMT_HEX = String("Hexadecimal")
comptime _FMT_OCT = String("Octal")
comptime _FMT_BIN = String("Binary")


@fieldwise_init
struct _FillLayout(ImplicitlyCopyable, Movable):
    """Pre-computed rects + row anchors for the dialog. Built once per
    paint so geometry never lags the live container_bounds size."""
    var title_y: Int
    var mode_label_y: Int
    var mode_rect: Rect
    var text_label_y: Int
    var text_rect: Rect
    var initial_label_y: Int
    var initial_rect: Rect
    var increment_label_y: Int
    var increment_rect: Rect
    var pad_y: Int
    var format_label_y: Int
    var format_rect: Rect
    var buttons_y: Int


def _build_layout(rect: Rect) -> _FillLayout:
    var cursor = RowCursor(rect.a.y + 1)
    var title_y = cursor.place()
    var mode_label_y = cursor.place()
    var mode_y = cursor.place_tight()
    var text_label_y = cursor.place()
    var text_y = cursor.place_tight()
    var initial_label_y = cursor.place()
    var initial_y = cursor.place_tight()
    var increment_label_y = cursor.place()
    var increment_y = cursor.place_tight()
    var pad_y = cursor.place()
    var format_label_y = cursor.place()
    var format_y = cursor.place_tight()
    var left = rect.a.x + 2
    var right = rect.b.x - 2
    return _FillLayout(
        title_y,
        mode_label_y, Rect(left, mode_y, right, mode_y + 1),
        text_label_y, Rect(left, text_y, right, text_y + 1),
        initial_label_y, Rect(left, initial_y, right, initial_y + 1),
        increment_label_y, Rect(left, increment_y, right, increment_y + 1),
        pad_y,
        format_label_y, Rect(left, format_y, right, format_y + 1),
        rect.b.y - 3,
    )


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
    var digits = String(StringSlice(ptr=fwd.unsafe_ptr(), length=len(fwd)))
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
    """Modal "Fill..." dialog. Held by the host across paints so the
    inner ``ShadowButton``s retain latch state and the dropdowns hold
    their selection between events.
    """

    var active: Bool
    var submitted: Bool
    var caret_count: Int
    var mode: Dropdown
    var text: TextField
    var initial: TextField
    var increment: TextField
    var pad: Checkbox
    var format_: Dropdown
    var _focus: FocusGroup
    var _ok: ShadowButton
    var _cancel: ShadowButton
    var _confirmed: Bool

    def __init__(out self):
        self.active = False
        self.submitted = False
        self.caret_count = 0
        var mode_opts = List[String]()
        mode_opts.append(_MODE_TEXT)
        mode_opts.append(_MODE_NUMBERS)
        self.mode = Dropdown(mode_opts^, 1)
        self.text = TextField()
        self.initial = TextField()
        self.increment = TextField()
        self.pad = Checkbox(String("Pad with leading zeros"), 0, 0, False)
        var fmt_opts = List[String]()
        fmt_opts.append(_FMT_DEC)
        fmt_opts.append(_FMT_HEX)
        fmt_opts.append(_FMT_OCT)
        fmt_opts.append(_FMT_BIN)
        self.format_ = Dropdown(fmt_opts^, 0)
        self._focus = FocusGroup(8)
        self._focus.focus_force(_SLOT_INITIAL)
        self._ok = ShadowButton(String(" OK "), 0, 0)
        self._cancel = ShadowButton(String(" Cancel "), 0, 0)
        self._confirmed = False

    def open(mut self, caret_count: Int):
        """Re-arm the dialog for a fresh invocation. The host passes the
        number of carets so ``generate`` can later produce exactly one
        string per caret without the caller having to thread it back
        in."""
        self.active = True
        self.submitted = False
        self.caret_count = caret_count
        # Seed each field with sensible defaults each time so a prior
        # session's edits don't carry over silently.
        var mode_opts = List[String]()
        mode_opts.append(_MODE_TEXT)
        mode_opts.append(_MODE_NUMBERS)
        self.mode = Dropdown(mode_opts^, 1)
        self.text = TextField()
        self.initial = TextField()
        self.initial.set_text(String("1"))
        self.increment = TextField()
        self.increment.set_text(String("1"))
        self.pad = Checkbox(String("Pad with leading zeros"), 0, 0, False)
        var fmt_opts = List[String]()
        fmt_opts.append(_FMT_DEC)
        fmt_opts.append(_FMT_HEX)
        fmt_opts.append(_FMT_OCT)
        fmt_opts.append(_FMT_BIN)
        self.format_ = Dropdown(fmt_opts^, 0)
        self._focus.focus_force(_SLOT_INITIAL)
        self._ok.pressed = False
        self._ok.pressed_inside = False
        self._cancel.pressed = False
        self._cancel.pressed_inside = False
        self._confirmed = False

    def close(mut self):
        self.active = False
        self.submitted = False
        self.caret_count = 0
        self.mode.close()
        self.format_.close()
        self.text = TextField()
        self.initial = TextField()
        self.increment = TextField()
        self._ok.pressed = False
        self._ok.pressed_inside = False
        self._cancel.pressed = False
        self._cancel.pressed_inside = False
        self._confirmed = False

    def confirmed(self) -> Bool:
        return self._confirmed

    def is_numbers_mode(self) -> Bool:
        return self.mode.value() == _MODE_NUMBERS

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
                out.append(self.text.text)
            return out^
        var init_opt = _parse_signed_int(self.initial.text)
        var inc_opt = _parse_signed_int(self.increment.text)
        var init_v = init_opt.value() if init_opt else 0
        var inc_v = inc_opt.value() if inc_opt else 0
        var base = 10
        var fmt = self.format_.value()
        if fmt == _FMT_HEX:
            base = 16
        elif fmt == _FMT_OCT:
            base = 8
        elif fmt == _FMT_BIN:
            base = 2
        var min_w = 0
        if self.pad.on and n > 0:
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
        string is a valid insertion — it's the multi-caret equivalent
        of "do nothing per caret")."""
        if not self.is_numbers_mode():
            return True
        var init_opt = _parse_signed_int(self.initial.text)
        var inc_opt = _parse_signed_int(self.increment.text)
        return Bool(init_opt) and Bool(inc_opt)

    def _layout(self, container_bounds: Rect) -> Rect:
        var width = _DLG_WIDTH
        if width > container_bounds.b.x - 4:
            width = container_bounds.b.x - 4
        if width < _MIN_WIDTH:
            width = _MIN_WIDTH
        # Rows: top / title / blank / mode label / mode / blank /
        # text label / text / blank / initial label / initial / blank /
        # increment label / increment / blank / pad checkbox / blank /
        # format label / format / blank / buttons / shadow / bottom
        var height = 23
        if height > container_bounds.b.y - 4:
            height = container_bounds.b.y - 4
        return center_in(container_bounds, width, height)

    def _position_pad(mut self, layout: _FillLayout, dlg: Rect):
        self.pad.move_to(dlg.a.x + 2, layout.pad_y)

    def _refresh_focus_visitability(mut self, layout: _FillLayout):
        """Numbers / text mode hide each other's inputs from the Tab
        walk so a press doesn't land on a control the user can't see
        a use for."""
        var numbers = self.is_numbers_mode()
        self._focus.update(_SLOT_MODE, layout.mode_rect, True)
        self._focus.update(_SLOT_TEXT, layout.text_rect, not numbers)
        self._focus.update(_SLOT_INITIAL, layout.initial_rect, numbers)
        self._focus.update(_SLOT_INCREMENT, layout.increment_rect, numbers)
        self._focus.update(_SLOT_PAD, self.pad.hit_rect(), numbers)
        self._focus.update(_SLOT_FORMAT, layout.format_rect, numbers)

    def paint(mut self, mut canvas: Canvas, container_bounds: Rect):
        if not self.active:
            return
        var attr = Attr(BLACK, LIGHT_GRAY)
        var label_attr = Attr(BLACK, LIGHT_GRAY)
        var disabled_attr = Attr(WHITE, LIGHT_GRAY)
        var rect = self._layout(container_bounds)
        var layout = _build_layout(rect)
        paint_drop_shadow(canvas, rect)
        var painter = Painter(rect)
        painter.fill(canvas, rect, String(" "), attr)
        painter = painter.draw_box_inner(canvas, rect, attr, False)
        paint_close_button(canvas, Point(rect.a.x, rect.a.y), attr)
        _ = painter.put_text(
            canvas, Point(rect.a.x + 2, layout.title_y),
            String(" Fill ") + String(self.caret_count)
            + String(" cursors "), attr,
        )
        self._position_pad(layout, rect)
        self._refresh_focus_visitability(layout)
        var numbers = self.is_numbers_mode()
        # Mode label + dropdown.
        _ = painter.put_text(
            canvas, Point(rect.a.x + 2, layout.mode_label_y),
            String("Insert:"), label_attr,
        )
        self.mode.paint(
            canvas, layout.mode_rect,
            self._focus.is_focused(_SLOT_MODE),
            Attr(WHITE, BLUE), Attr(BLACK, CYAN),
        )
        # Text label + field — visible/usable only in text mode.
        var text_label_attr = label_attr if not numbers else disabled_attr
        _ = painter.put_text(
            canvas, Point(rect.a.x + 2, layout.text_label_y),
            String("Text to insert:"), text_label_attr,
        )
        if not numbers:
            self.text.paint(
                canvas, layout.text_rect,
                self._focus.is_focused(_SLOT_TEXT),
            )
        else:
            # Greyed-out placeholder so the row still reads as
            # "a field that exists but doesn't apply right now".
            var p2 = Painter(layout.text_rect)
            p2.fill(
                canvas, layout.text_rect, String(" "),
                Attr(WHITE, LIGHT_GRAY),
            )
        # Numeric inputs.
        var num_label_attr = label_attr if numbers else disabled_attr
        _ = painter.put_text(
            canvas, Point(rect.a.x + 2, layout.initial_label_y),
            String("Initial number:"), num_label_attr,
        )
        if numbers:
            self.initial.paint(
                canvas, layout.initial_rect,
                self._focus.is_focused(_SLOT_INITIAL),
            )
        else:
            var p3 = Painter(layout.initial_rect)
            p3.fill(
                canvas, layout.initial_rect, String(" "),
                Attr(WHITE, LIGHT_GRAY),
            )
        _ = painter.put_text(
            canvas, Point(rect.a.x + 2, layout.increment_label_y),
            String("Increment:"), num_label_attr,
        )
        if numbers:
            self.increment.paint(
                canvas, layout.increment_rect,
                self._focus.is_focused(_SLOT_INCREMENT),
            )
        else:
            var p4 = Painter(layout.increment_rect)
            p4.fill(
                canvas, layout.increment_rect, String(" "),
                Attr(WHITE, LIGHT_GRAY),
            )
        # Pad checkbox.
        if numbers:
            paint_checkbox(
                canvas, self.pad,
                Attr(BLACK, CYAN), Attr(BLACK, GREEN),
                self._focus.is_focused(_SLOT_PAD),
                rect.b.x - 1,
            )
        else:
            _ = painter.put_text(
                canvas, Point(rect.a.x + 2, layout.pad_y),
                self.pad.label, disabled_attr,
            )
        # Format dropdown.
        _ = painter.put_text(
            canvas, Point(rect.a.x + 2, layout.format_label_y),
            String("Number format:"), num_label_attr,
        )
        if numbers:
            self.format_.paint(
                canvas, layout.format_rect,
                self._focus.is_focused(_SLOT_FORMAT),
                Attr(WHITE, BLUE), Attr(BLACK, CYAN),
            )
        else:
            var p5 = Painter(layout.format_rect)
            p5.fill(
                canvas, layout.format_rect, String(" "),
                Attr(WHITE, LIGHT_GRAY),
            )
        # Buttons.
        var by = layout.buttons_y
        var ok_w = self._ok.total_width()
        var cancel_w = self._cancel.total_width()
        var gap = 2
        var total = ok_w + gap + cancel_w
        var bx = rect.a.x + (rect.width() - total) // 2
        if bx < rect.a.x + 2:
            bx = rect.a.x + 2
        self._ok.move_to(bx, by)
        self._cancel.move_to(bx + ok_w + gap, by)
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
        """Render any open dropdown popup on top of the rest of the
        dialog. The host invokes this after every other modal layer so
        the popup overlays them — same z-order pattern as
        ``BreakpointMenu``."""
        if not self.active:
            return
        var rect = self._layout(container_bounds)
        var layout = _build_layout(rect)
        if self.mode.is_open:
            self.mode.paint_popup(canvas, layout.mode_rect, container_bounds)
        if self.format_.is_open and self.is_numbers_mode():
            self.format_.paint_popup(canvas, layout.format_rect, container_bounds)

    def _resolve(mut self, confirmed: Bool):
        if confirmed and not self._can_submit():
            # Refocus a problematic field rather than silently failing.
            var init_opt = _parse_signed_int(self.initial.text)
            if not init_opt:
                self._focus.focus_force(_SLOT_INITIAL)
            else:
                self._focus.focus_force(_SLOT_INCREMENT)
            return
        self.submitted = True
        self._confirmed = confirmed

    def _focus_next(mut self, backward: Bool = False):
        if self._focus.is_focused(_SLOT_MODE):
            self.mode.close()
        if self._focus.is_focused(_SLOT_FORMAT):
            self.format_.close()
        self._focus.cycle(backward)

    def handle_key(mut self, event: Event) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_KEY:
            return True
        var k = event.key
        # While a dropdown popup is open, route to it first so Up/Down/
        # Enter navigate options instead of leaking into focus walk.
        if self._focus.is_focused(_SLOT_MODE) and self.mode.is_open:
            if k == KEY_ESC:
                self.mode.close()
                return True
            if self.mode.handle_key(event):
                return True
        if self._focus.is_focused(_SLOT_FORMAT) and self.format_.is_open:
            if k == KEY_ESC:
                self.format_.close()
                return True
            if self.format_.handle_key(event):
                return True
        if k == KEY_ESC:
            self._resolve(False)
            return True
        if k == KEY_TAB:
            var backward = (event.mods & MOD_SHIFT) != 0
            self._focus_next(backward)
            return True
        if k == KEY_ENTER:
            if self._focus.is_focused(_SLOT_MODE):
                _ = self.mode.handle_key(event)
                return True
            if self._focus.is_focused(_SLOT_FORMAT):
                _ = self.format_.handle_key(event)
                return True
            if self._focus.is_focused(_SLOT_PAD):
                self.pad.toggle()
                return True
            if self._focus.is_focused(_SLOT_CANCEL):
                self._resolve(False)
                return True
            self._resolve(True)
            return True
        if self._focus.is_focused(_SLOT_MODE):
            if self.mode.handle_key(event):
                return True
            return True
        if self._focus.is_focused(_SLOT_FORMAT):
            if self.format_.handle_key(event):
                return True
            return True
        if self._focus.is_focused(_SLOT_PAD):
            if k == KEY_SPACE:
                self.pad.toggle()
                return True
            return True
        if self._focus.is_focused(_SLOT_TEXT):
            var r = self.text.handle_key(event)
            if r.consumed:
                return True
            return True
        if self._focus.is_focused(_SLOT_INITIAL):
            var r2 = self.initial.handle_key(event)
            if r2.consumed:
                return True
            return True
        if self._focus.is_focused(_SLOT_INCREMENT):
            var r3 = self.increment.handle_key(event)
            if r3.consumed:
                return True
            return True
        return True

    def handle_mouse(mut self, event: Event, container_bounds: Rect) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_MOUSE:
            return True
        var rect = self._layout(container_bounds)
        var layout = _build_layout(rect)
        self._position_pad(layout, rect)
        # Standard close button — equivalent to Esc / Cancel.
        if close_button_clicked(rect, event):
            self._resolve(False)
            return True
        # Open popups overlay everything else — route to them first so
        # a click on the popup doesn't also shift focus underneath.
        if self.mode.is_open:
            var h1 = self.mode.handle_mouse(
                layout.mode_rect, container_bounds, event,
            )
            if h1 == DROPDOWN_HIT_BODY or h1 == DROPDOWN_HIT_POPUP:
                self._focus.focus_force(_SLOT_MODE)
                return True
        if self.format_.is_open and self.is_numbers_mode():
            var h2 = self.format_.handle_mouse(
                layout.format_rect, container_bounds, event,
            )
            if h2 == DROPDOWN_HIT_BODY or h2 == DROPDOWN_HIT_POPUP:
                self._focus.focus_force(_SLOT_FORMAT)
                return True
        self._refresh_focus_visitability(layout)
        self._focus.update(_SLOT_OK, self._ok.hit_rect(), True)
        self._focus.update(_SLOT_CANCEL, self._cancel.hit_rect(), True)
        _ = self._focus.handle_click(event)
        # Pad checkbox: captures press / commit on release inside chip.
        if self.is_numbers_mode():
            var cb_status = self.pad.handle_mouse(event)
            if cb_status != BUTTON_NONE:
                if cb_status == BUTTON_FIRED:
                    self.pad.toggle()
                return True
        # Closed-dropdown click on the strip toggles it open.
        if not self.mode.is_open:
            var h3 = self.mode.handle_mouse(
                layout.mode_rect, container_bounds, event,
            )
            if h3 == DROPDOWN_HIT_BODY:
                return True
        if self.is_numbers_mode() and not self.format_.is_open:
            var h4 = self.format_.handle_mouse(
                layout.format_rect, container_bounds, event,
            )
            if h4 == DROPDOWN_HIT_BODY:
                return True
        # Forward to focused text input.
        if self._focus.is_focused(_SLOT_TEXT):
            if self.text.handle_mouse(event, layout.text_rect):
                return True
        if self._focus.is_focused(_SLOT_INITIAL):
            if self.initial.handle_mouse(event, layout.initial_rect):
                return True
        if self._focus.is_focused(_SLOT_INCREMENT):
            if self.increment.handle_mouse(event, layout.increment_rect):
                return True
        # Buttons.
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
