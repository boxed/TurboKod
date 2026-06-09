"""Interactive color picker modal.

Opened on a documentColor swatch (Color Picker… in the symbol-actions
menu). Edits the color in one of three color spaces — **OkLab** (the
default, perceptually uniform), **RGB**, or **HSL** — and on apply writes
the new value back over the swatch's range as a CSS color literal in the
selected space.

The single source of truth while a space is selected is the channel
triple ``chan`` (in that space's units); switching spaces converts the
current color through sRGB so the on-screen color is preserved.
Switching is non-destructive in the sense that the displayed color is
the same — only its representation changes.

Frontend-agnostic: like ``MessageRequestDialog`` it only paints into a
``Canvas`` and consumes ``Event``s, so both the terminal and the native
macOS host drive it unchanged. The host reads ``submitted`` /
``accepted`` / ``result_text`` and then calls ``close()``.

Keys:
* **Tab** / click — move focus through the color-space selector + 3
  channels.
* **↑ / +** and **↓ / -** — nudge the focused channel (or cycle the
  color space when the selector is focused).
* digits / ``.`` / ``-`` — type an exact value into the focused channel;
  **Enter** commits the field, **Esc** discards it.
* **Enter** (not editing) — apply. **Esc** (not editing) — cancel.
"""

from .buttons import (
    BUTTON_FIRED, BUTTON_NONE, ShadowButton, paint_shadow_button,
)
from .canvas import Canvas
from .colors import Attr, BLACK, BLUE, GREEN, LIGHT_GRAY, WHITE
from .color_convert import (
    fmt_fixed, parse_float,
    srgb_to_rgb255, rgb255_to_srgb, unpack_rgb,
    srgb_to_oklab, oklab_to_srgb, srgb_to_hsl, hsl_to_srgb,
    format_oklab, format_rgb, format_hsl, format_hex,
)
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_BACKSPACE, KEY_DOWN, KEY_ENTER, KEY_ESC, KEY_LEFT, KEY_RIGHT,
    KEY_TAB, KEY_UP, MOUSE_BUTTON_LEFT,
)
from .geometry import Point, Rect, center_in
from .string_utils import display_columns
from .view import centered_row_start
from .window import close_button_clicked, paint_modal_frame


comptime MODE_OKLAB = 0
comptime MODE_RGB   = 1
comptime MODE_HSL   = 2
comptime _N_MODES   = 3

comptime _WIDTH  = 46
comptime _HEIGHT = 14


def _mode_label(mode: Int) -> String:
    if mode == MODE_RGB:
        return String("RGB")
    if mode == MODE_HSL:
        return String("HSL")
    return String("OkLab")


def _chan_name(mode: Int, i: Int) -> String:
    if mode == MODE_OKLAB:
        if i == 0:
            return String("L")
        if i == 1:
            return String("a")
        return String("b")
    if mode == MODE_RGB:
        if i == 0:
            return String("R")
        if i == 1:
            return String("G")
        return String("B")
    # HSL
    if i == 0:
        return String("H")
    if i == 1:
        return String("S")
    return String("L")


def _chan_min(mode: Int, i: Int) -> Float64:
    if mode == MODE_OKLAB:
        return 0.0 if i == 0 else -0.4
    return 0.0


def _chan_max(mode: Int, i: Int) -> Float64:
    if mode == MODE_OKLAB:
        return 1.0 if i == 0 else 0.4
    if mode == MODE_RGB:
        return 255.0
    # HSL: H 0..360, S/L 0..100
    return 360.0 if i == 0 else 100.0


def _chan_step(mode: Int, i: Int) -> Float64:
    if mode == MODE_OKLAB:
        return 0.01 if i == 0 else 0.005
    return 1.0


def _chan_decimals(mode: Int, i: Int) -> Int:
    if mode == MODE_OKLAB:
        return 3
    return 0


struct ColorPickerDialog(Movable):
    """Modal color editor over a documentColor swatch."""
    var active: Bool
    var submitted: Bool
    """True once the user applies or cancels; the host reads ``accepted``
    / ``result_text`` then calls ``close()``."""
    var accepted: Bool
    """True = apply ``result_text``; False = cancel (leave the buffer)."""
    var result_text: String
    """The CSS literal to write back, set when ``accepted`` is True."""
    var mode: Int
    var chan: List[Float64]
    var focus: Int
    """0 = color-space selector, 1..3 = the three channels."""
    var editing: Bool
    var edit_buf: String
    var _apply_button: ShadowButton
    var _cancel_button: ShadowButton

    def __init__(out self):
        self.active = False
        self.submitted = False
        self.accepted = False
        self.result_text = String("")
        self.mode = MODE_OKLAB
        self.chan = [0.0, 0.0, 0.0]
        self.focus = 1
        self.editing = False
        self.edit_buf = String("")
        self._apply_button = ShadowButton(String(" Apply "), 0, 0)
        self._cancel_button = ShadowButton(String(" Cancel "), 0, 0)

    def _reset_buttons(mut self):
        self._apply_button.pressed = False
        self._apply_button.pressed_inside = False
        self._cancel_button.pressed = False
        self._cancel_button.pressed_inside = False

    def open(mut self, rgb_packed: UInt32):
        """Open the picker seeded from a packed ``0xRRGGBB`` swatch color,
        defaulting to the OkLab space."""
        var rgb = unpack_rgb(rgb_packed)
        var srgb = rgb255_to_srgb(rgb[0], rgb[1], rgb[2])
        self.active = True
        self.submitted = False
        self.accepted = False
        self.result_text = String("")
        self.mode = MODE_OKLAB
        self.focus = 1
        self.editing = False
        self.edit_buf = String("")
        self._reset_buttons()
        self._set_chan_from_srgb(srgb[0], srgb[1], srgb[2])

    def close(mut self):
        self.active = False
        self.submitted = False
        self.accepted = False
        self.result_text = String("")
        self.editing = False
        self.edit_buf = String("")
        self._reset_buttons()

    # --- color state ------------------------------------------------------

    def _set_chan_from_srgb(mut self, r: Float64, g: Float64, b: Float64):
        """Recompute the channel triple for the current mode from an sRGB
        color (each component in ``[0,1]``)."""
        if self.mode == MODE_OKLAB:
            var ok = srgb_to_oklab(r, g, b)
            self.chan = [ok[0], ok[1], ok[2]]
        elif self.mode == MODE_RGB:
            var c = srgb_to_rgb255(r, g, b)
            self.chan = [Float64(c[0]), Float64(c[1]), Float64(c[2])]
        else:
            var h = srgb_to_hsl(r, g, b)
            self.chan = [h[0], h[1], h[2]]

    def _current_srgb(self) -> Tuple[Float64, Float64, Float64]:
        """The current color as sRGB ``[0,1]``, derived from ``chan``."""
        if self.mode == MODE_OKLAB:
            return oklab_to_srgb(self.chan[0], self.chan[1], self.chan[2])
        if self.mode == MODE_RGB:
            return rgb255_to_srgb(
                Int(self.chan[0] + 0.5),
                Int(self.chan[1] + 0.5),
                Int(self.chan[2] + 0.5),
            )
        return hsl_to_srgb(self.chan[0], self.chan[1], self.chan[2])

    def _format_current(self) -> String:
        if self.mode == MODE_OKLAB:
            return format_oklab(self.chan[0], self.chan[1], self.chan[2])
        if self.mode == MODE_RGB:
            return format_rgb(
                Int(self.chan[0] + 0.5),
                Int(self.chan[1] + 0.5),
                Int(self.chan[2] + 0.5),
            )
        return format_hsl(self.chan[0], self.chan[1], self.chan[2])

    def _set_mode(mut self, new_mode: Int):
        """Switch color space, preserving the on-screen color through
        sRGB."""
        if new_mode == self.mode:
            return
        var srgb = self._current_srgb()
        self.mode = new_mode
        self._set_chan_from_srgb(srgb[0], srgb[1], srgb[2])

    def _clamp_chan(self, i: Int, v: Float64) -> Float64:
        var lo = _chan_min(self.mode, i)
        var hi = _chan_max(self.mode, i)
        if v < lo:
            return lo
        if v > hi:
            return hi
        return v

    def _nudge_channel(mut self, i: Int, dir: Int):
        var step = _chan_step(self.mode, i)
        self.chan[i] = self._clamp_chan(i, self.chan[i] + step * Float64(dir))

    # --- value display ----------------------------------------------------

    def _chan_text(self, i: Int) -> String:
        if self.editing and self.focus == i + 1:
            return self.edit_buf
        return fmt_fixed(self.chan[i], _chan_decimals(self.mode, i))

    # --- layout -----------------------------------------------------------

    def _layout(self, container: Rect) -> Rect:
        var w = _WIDTH
        if w > container.b.x - 4:
            w = container.b.x - 4
        var h = _HEIGHT
        if h > container.b.y - 4:
            h = container.b.y - 4
        return center_in(container, w, h)

    def _mode_arrows_x(self, rect: Rect) -> Tuple[Int, Int]:
        """Screen x of the ``‹`` and ``›`` glyphs in the color-space row,
        for mouse hit-testing."""
        var label_x = rect.a.x + 3 + display_columns(String("Color space:  "))
        var left = label_x
        var lbl = _mode_label(self.mode)
        var right = label_x + 2 + display_columns(lbl) + 1
        return (left, right)

    def _channel_row_y(self, rect: Rect, i: Int) -> Int:
        return rect.a.y + 4 + i

    def _place_buttons(mut self, rect: Rect):
        """Center the Apply / Cancel pair on the button row, two up from
        the bottom border (the row below holds the drop shadow)."""
        var by = rect.b.y - 3
        var aw = self._apply_button.total_width()
        var cw = self._cancel_button.total_width()
        var gap = 2
        var bx = centered_row_start(rect, aw + gap + cw)
        self._apply_button.move_to(bx, by)
        self._cancel_button.move_to(bx + aw + gap, by)

    # --- paint ------------------------------------------------------------

    def paint(mut self, mut canvas: Canvas, container: Rect):
        if not self.active:
            return
        var attr = Attr(BLACK, LIGHT_GRAY)
        var rect = self._layout(container)
        _ = paint_modal_frame(canvas, rect, attr)
        # Title.
        _ = canvas.put_text(
            Point(rect.a.x + 5, rect.a.y), String(" Color Picker "), attr,
            rect.b.x - 1,
        )
        var content_x = rect.a.x + 3
        var clip = rect.b.x - 1
        # Color-space selector row.
        var sel_attr = attr
        if self.focus == 0:
            sel_attr = Attr(WHITE, BLUE)
        var space_y = rect.a.y + 2
        _ = canvas.put_text(
            Point(content_x, space_y), String("Color space:  "), attr, clip,
        )
        var lbl = _mode_label(self.mode)
        var arrows = self._mode_arrows_x(rect)
        _ = canvas.put_text(Point(arrows[0], space_y), String("‹ "), attr, clip)
        _ = canvas.put_text(
            Point(arrows[0] + 2, space_y), lbl, sel_attr, clip,
        )
        _ = canvas.put_text(
            Point(arrows[0] + 2 + display_columns(lbl) + 1, space_y),
            String("›"), attr, clip,
        )
        # Channel rows.
        for i in range(3):
            var y = self._channel_row_y(rect, i)
            var row_attr = attr
            var focused = self.focus == i + 1
            if focused:
                row_attr = Attr(WHITE, BLUE)
                canvas.fill(
                    Rect(rect.a.x + 1, y, rect.b.x - 1, y + 1),
                    String(" "), row_attr,
                )
            _ = canvas.put_text(
                Point(content_x + 1, y), _chan_name(self.mode, i), row_attr,
                clip,
            )
            var vtext = self._chan_text(i)
            if self.editing and focused:
                vtext = vtext + String("_")
            _ = canvas.put_text(
                Point(content_x + 5, y), vtext, row_attr, clip,
            )
        # Preview swatch + hex.
        var srgb = self._current_srgb()
        var rgb = srgb_to_rgb255(srgb[0], srgb[1], srgb[2])
        var packed = (UInt32(rgb[0]) << 16) | (UInt32(rgb[1]) << 8) \
            | UInt32(rgb[2])
        var lum = (rgb[0] * 299 + rgb[1] * 587 + rgb[2] * 114) // 1000
        var sw_fg = BLACK if lum > 140 else WHITE
        var sw_attr = Attr(sw_fg, BLACK).with_bg_rgb(packed)
        var prev_y = rect.a.y + 8
        _ = canvas.put_text(
            Point(content_x, prev_y), String("Preview "), attr, clip,
        )
        canvas.fill(
            Rect(content_x + 8, prev_y, content_x + 18, prev_y + 1),
            String(" "), sw_attr,
        )
        _ = canvas.put_text(
            Point(content_x + 20, prev_y),
            format_hex(rgb[0], rgb[1], rgb[2]), attr, clip,
        )
        # Hint line.
        _ = canvas.put_text(
            Point(content_x, rect.a.y + 9),
            String("Tab move · ↑↓ adjust · type to edit"), attr, clip,
        )
        # Apply / Cancel — standard Turbo-Vision shadow buttons.
        self._place_buttons(rect)
        paint_shadow_button(
            canvas, self._apply_button, Attr(BLACK, GREEN), LIGHT_GRAY,
        )
        paint_shadow_button(
            canvas, self._cancel_button, Attr(BLACK, GREEN), LIGHT_GRAY,
        )

    # --- key handling -----------------------------------------------------

    def _apply(mut self):
        self.result_text = self._format_current()
        self.accepted = True
        self.submitted = True

    def _cancel(mut self):
        self.accepted = False
        self.submitted = True

    def _commit_edit(mut self):
        """Parse the in-progress text into the focused channel (clamped),
        or discard it silently when it isn't a number."""
        if not self.editing:
            return
        var ci = self.focus - 1
        var parsed = parse_float(self.edit_buf)
        if parsed and 0 <= ci and ci < 3:
            self.chan[ci] = self._clamp_chan(ci, parsed.value())
        self.editing = False
        self.edit_buf = String("")

    def handle_key(mut self, event: Event) -> Bool:
        if not self.active or event.kind != EVENT_KEY:
            return True
        var k = event.key
        # While typing a value, the field owns most keys.
        if self.editing:
            if k == KEY_ENTER:
                self._commit_edit()
                return True
            if k == KEY_ESC:
                self.editing = False
                self.edit_buf = String("")
                return True
            if k == KEY_BACKSPACE:
                var b = self.edit_buf.as_bytes()
                if len(b) > 0:
                    self.edit_buf = String(
                        StringSlice(unsafe_from_utf8=b[0 : len(b) - 1])
                    )
                return True
            if self._is_value_char(k):
                self.edit_buf = self.edit_buf + chr(Int(k))
                return True
            # Tab commits and moves on; anything else is ignored.
            if k == KEY_TAB:
                self._commit_edit()
                self.focus = (self.focus + 1) % 4
                return True
            return True
        # Not editing.
        if k == KEY_ESC:
            self._cancel()
            return True
        if k == KEY_ENTER:
            self._apply()
            return True
        if k == KEY_TAB:
            self.focus = (self.focus + 1) % 4
            return True
        if k == KEY_UP or k == KEY_RIGHT or self._is_char(k, ord("+")):
            self._step(1)
            return True
        # '-' only steps down on the space selector; on a channel it begins
        # entry of a negative value (handled by the value-char branch below).
        if k == KEY_DOWN or k == KEY_LEFT \
                or (self._is_char(k, ord("-")) and self.focus == 0):
            self._step(-1)
            return True
        # On a channel, start text entry from a typed value char.
        if self.focus >= 1 and self._is_value_char(k):
            self.editing = True
            self.edit_buf = chr(Int(k))
            return True
        return True

    def _step(mut self, dir: Int):
        """Nudge — cycle the color space when the selector is focused,
        otherwise adjust the focused channel."""
        if self.focus == 0:
            if dir > 0:
                self._set_mode((self.mode + 1) % _N_MODES)
            else:
                self._set_mode((self.mode + _N_MODES - 1) % _N_MODES)
        else:
            self._nudge_channel(self.focus - 1, dir)

    @staticmethod
    def _is_char(k: UInt32, code: Int) -> Bool:
        return UInt32(0x20) <= k and k < UInt32(0x7F) and Int(k) == code

    @staticmethod
    def _is_value_char(k: UInt32) -> Bool:
        if not (UInt32(0x20) <= k and k < UInt32(0x7F)):
            return False
        var c = Int(k)
        return (ord("0") <= c and c <= ord("9")) \
            or c == ord(".") or c == ord("-")

    # --- mouse handling ---------------------------------------------------

    def handle_mouse(mut self, event: Event, container: Rect) -> Bool:
        if not self.active or event.kind != EVENT_MOUSE:
            return True
        var rect = self._layout(container)
        if close_button_clicked(rect, event):
            self._cancel()
            return True
        # Route to the standard shadow buttons first so their press / drag /
        # release machine owns the click (and a drag-off cancels cleanly).
        self._place_buttons(rect)
        var sa = self._apply_button.handle_mouse(event)
        if sa != BUTTON_NONE:
            if sa == BUTTON_FIRED:
                self._commit_edit()
                self._apply()
            return True
        var sc = self._cancel_button.handle_mouse(event)
        if sc != BUTTON_NONE:
            if sc == BUTTON_FIRED:
                self._cancel()
            return True
        if not (event.button == MOUSE_BUTTON_LEFT and event.pressed
                and not event.motion):
            return True
        var p = event.pos
        # Color-space row: clicking the label / arrows focuses the selector
        # and cycles forward.
        var space_y = rect.a.y + 2
        if p.y == space_y:
            self._commit_edit()
            self.focus = 0
            var arrows = self._mode_arrows_x(rect)
            if p.x <= arrows[0] + 1:
                self._set_mode((self.mode + _N_MODES - 1) % _N_MODES)
            else:
                self._set_mode((self.mode + 1) % _N_MODES)
            return True
        # Channel rows: focus the clicked channel.
        for i in range(3):
            if p.y == self._channel_row_y(rect, i):
                self._commit_edit()
                self.focus = i + 1
                return True
        return True
