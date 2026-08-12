"""Shared Vt-grid view: selection, grid paint, and key/mouse encoding.

Both the shell terminal (``terminal_pane.mojo``) and the test runner
(``test_pane.mojo``) render a ``Vt`` emulator grid into a bottom-docked
pane and let the user select / copy / scroll it and (for the shell)
type into it. The grid-view behavior — the cell+cursor paint loop, the
mouse-driven selection state machine (cell / word / line drag), and the
key→pty / mouse→pty wire encodings — is identical between them and lives
here so neither pane reimplements it.

The owning pane keeps the ``Vt`` and the ``PtyProcess`` (the pty is a
kernel handle the pane's lifecycle owns); this module's functions take
the ``Vt`` by borrow and *return* the bytes to send rather than writing
them, so the pane stays the single writer to its child.
"""

from std.collections.list import List

from .canvas import Canvas
from .cell import Cell
from .clipboard import clipboard_copy
from .colors import Attr, BG_TRUECOLOR, FG_TRUECOLOR, PANE_BG, WHITE
from .events import (
    Event,
    KEY_BACKSPACE, KEY_DELETE, KEY_DOWN, KEY_END, KEY_ENTER, KEY_ESC,
    KEY_F1, KEY_F2, KEY_F3, KEY_F4, KEY_F5, KEY_F6, KEY_F7, KEY_F8,
    KEY_F9, KEY_F10, KEY_F11, KEY_F12,
    KEY_HOME, KEY_INSERT, KEY_LEFT, KEY_PAGEDOWN, KEY_PAGEUP,
    KEY_RIGHT, KEY_TAB, KEY_UP,
    MOD_ALT, MOD_CTRL, MOD_SHIFT, MOUSE_BUTTON_NONE,
)
from .geometry import Point, Rect
from .painter import Painter
from .vt import Vt


struct GridSelection(Copyable, Movable):
    """Mouse selection state over a ``Vt`` grid, in grid (row, col)
    coordinates. Drives the inverted overlay during paint and the
    extracted text on copy. Cell / word / line drag modes mirror the
    editor's selection gestures. ``_last_body`` is the body rect from
    the last paint, used to map screen positions back to grid coords."""
    var sel_active: Bool
    """True when a finished selection is on screen."""
    var sel_dragging: Bool
    """True between LMB-press and LMB-release while extending by drag."""
    var sel_anchor_r: Int
    var sel_anchor_c: Int
    var sel_focus_r: Int
    var sel_focus_c: Int
    var _drag_word: Bool
    """True while a double-click drag is in flight: the moving end snaps
    to whole-word boundaries, anchored on the double-clicked word."""
    var _drag_line: Bool
    """True while a triple-click drag is in flight: the selection grows
    by whole rows, anchored on the triple-clicked row."""
    var _dc_anchor_r: Int
    var _dc_anchor_lo: Int
    var _dc_anchor_hi: Int
    """Grid bounds (row, lo-inclusive, hi-exclusive) of the double-clicked
    word — the fixed end of a word-snapped drag."""
    var _tc_anchor_r: Int
    """Row the triple-click landed on — the fixed end of a line drag."""
    var _last_body: Rect
    """Body rect from the last paint. ``Rect.empty`` means the body
    wasn't laid out (minimized / first frame)."""

    def __init__(out self):
        self.sel_active = False
        self.sel_dragging = False
        self.sel_anchor_r = 0
        self.sel_anchor_c = 0
        self.sel_focus_r = 0
        self.sel_focus_c = 0
        self._drag_word = False
        self._drag_line = False
        self._dc_anchor_r = 0
        self._dc_anchor_lo = 0
        self._dc_anchor_hi = 0
        self._tc_anchor_r = 0
        self._last_body = Rect.empty()

    def __copyinit__(mut self, copy: Self):
        self.sel_active = copy.sel_active
        self.sel_dragging = copy.sel_dragging
        self.sel_anchor_r = copy.sel_anchor_r
        self.sel_anchor_c = copy.sel_anchor_c
        self.sel_focus_r = copy.sel_focus_r
        self.sel_focus_c = copy.sel_focus_c
        self._drag_word = copy._drag_word
        self._drag_line = copy._drag_line
        self._dc_anchor_r = copy._dc_anchor_r
        self._dc_anchor_lo = copy._dc_anchor_lo
        self._dc_anchor_hi = copy._dc_anchor_hi
        self._tc_anchor_r = copy._tc_anchor_r
        self._last_body = copy._last_body

    # --- query ---------------------------------------------------------

    def has_selection(self) -> Bool:
        return self.sel_active

    def cell_in_selection(self, r: Int, c: Int) -> Bool:
        if not (self.sel_active or self.sel_dragging):
            return False
        var sr0 = self.sel_anchor_r
        var sc0 = self.sel_anchor_c
        var sr1 = self.sel_focus_r
        var sc1 = self.sel_focus_c
        # Order so (sr0, sc0) is the top-left in reading order.
        if sr1 < sr0 or (sr1 == sr0 and sc1 < sc0):
            var tmpr = sr0; sr0 = sr1; sr1 = tmpr
            var tmpc = sc0; sc0 = sc1; sc1 = tmpc
        if r < sr0 or r > sr1:
            return False
        if sr0 == sr1:
            return c >= sc0 and c < sc1
        if r == sr0:
            return c >= sc0
        if r == sr1:
            return c < sc1
        return True

    def clear(mut self):
        self.sel_active = False
        self.sel_dragging = False
        self._drag_word = False
        self._drag_line = False

    # --- copy ----------------------------------------------------------

    def selected_text(self, vt: Vt) -> String:
        if not self.sel_active:
            return String("")
        return self._extract_selection(vt)

    def copy_to_clipboard(self, vt: Vt) -> Bool:
        var text = self.selected_text(vt)
        if len(text.as_bytes()) == 0:
            return False
        clipboard_copy(text)
        return True

    def _extract_selection(self, vt: Vt) -> String:
        var sr0 = self.sel_anchor_r
        var sc0 = self.sel_anchor_c
        var sr1 = self.sel_focus_r
        var sc1 = self.sel_focus_c
        if sr1 < sr0 or (sr1 == sr0 and sc1 < sc0):
            var tmpr = sr0; sr0 = sr1; sr1 = tmpr
            var tmpc = sc0; sc0 = sc1; sc1 = tmpc
        var out = String("")
        for r in range(sr0, sr1 + 1):
            var c_start = sc0 if r == sr0 else 0
            var c_end   = sc1 if r == sr1 else vt.cols
            if c_end > vt.cols: c_end = vt.cols
            if c_start < 0: c_start = 0
            var row_bytes = List[UInt8]()
            for c in range(c_start, c_end):
                # View-aware lookup so a selection made while scrolled
                # back captures the historical text, not the live tail.
                var g = vt.view_cell_at(r, c).glyph.as_bytes()
                for k in range(len(g)):
                    row_bytes.append(g[k])
            # Strip trailing spaces — the grid is rectangular but content
            # rarely fills the row, and copy should give visible text.
            var end = len(row_bytes)
            while end > 0 and row_bytes[end - 1] == 0x20:
                end -= 1
            out = out + String(StringSpan(unsafe_from_utf8=Span(unsafe_ptr=row_bytes.unsafe_ptr(), length=end)))
            if r < sr1:
                out = out + String("\n")
        return out^

    # --- screen→grid mapping -------------------------------------------

    def grid_xy_for_pos(self, vt: Vt, pos: Point) -> Tuple[Int, Int]:
        """Convert a screen position to ``(row, col)`` in the VT grid.
        Out-of-body positions clamp to the nearest edge — that's what
        you want for a drag that left the body."""
        if self._last_body.is_empty():
            return (0, 0)
        var r = pos.y - self._last_body.a.y
        var c = pos.x - self._last_body.a.x
        if r < 0: r = 0
        if r >= vt.rows: r = vt.rows - 1
        if c < 0: c = 0
        if c > vt.cols: c = vt.cols
        return (r, c)

    # --- drag ----------------------------------------------------------

    def begin_drag(mut self, vt: Vt, pos: Point):
        var rc = self.grid_xy_for_pos(vt, pos)
        self.sel_anchor_r = rc[0]
        self.sel_anchor_c = rc[1]
        self.sel_focus_r  = rc[0]
        self.sel_focus_c  = rc[1]
        self.sel_dragging = True
        self.sel_active   = False
        # A plain single-click drag selects cell-by-cell, not snapped.
        self._drag_word = False
        self._drag_line = False

    def extend_drag(mut self, vt: Vt, pos: Point):
        # While a double-/triple-click drag is in flight the moving end
        # snaps to whole-word / whole-line boundaries.
        var rc = self.grid_xy_for_pos(vt, pos)
        if self._drag_line:
            self._extend_line_drag(vt, rc[0])
        elif self._drag_word:
            self._extend_word_drag(vt, rc[0], rc[1])
        else:
            self.sel_focus_r = rc[0]
            self.sel_focus_c = rc[1]

    def end_drag(mut self, vt: Vt, pos: Point):
        self.extend_drag(vt, pos)
        self.sel_dragging = False
        self._drag_word = False
        self._drag_line = False
        # Tiny drag (or single click) → no selection. Saves the user
        # from clobbering the clipboard with a one-cell capture when
        # they meant to focus the pane.
        if self.sel_anchor_r == self.sel_focus_r \
                and self.sel_anchor_c == self.sel_focus_c:
            self.sel_active = False
            return
        self.sel_active = True

    def _word_bounds_at(self, vt: Vt, r: Int, c_in: Int) -> Tuple[Int, Int]:
        """``(lo, hi)`` of the word-class run around column ``c_in`` on
        row ``r`` — ``lo`` inclusive, ``hi`` exclusive. A separator cell
        returns just that single cell."""
        var c = c_in
        if c >= vt.cols: c = vt.cols - 1
        if c < 0: c = 0
        if not _is_word_glyph(vt.view_cell_at(r, c).glyph):
            return (c, c + 1)
        var lo = c
        while lo > 0:
            if not _is_word_glyph(vt.view_cell_at(r, lo - 1).glyph):
                break
            lo -= 1
        var hi = c
        while hi + 1 < vt.cols:
            if not _is_word_glyph(vt.view_cell_at(r, hi + 1).glyph):
                break
            hi += 1
        return (lo, hi + 1)

    def select_word_at(mut self, vt: Vt, pos: Point):
        """Select the word under ``pos`` and arm a word-snapped drag."""
        var rc = self.grid_xy_for_pos(vt, pos)
        var r = rc[0]
        var c = rc[1]
        if c >= vt.cols: c = vt.cols - 1
        if c < 0:
            self.sel_active = False
            return
        var bounds = self._word_bounds_at(vt, r, c)
        self.sel_anchor_r = r
        self.sel_anchor_c = bounds[0]
        self.sel_focus_r = r
        self.sel_focus_c = bounds[1]
        self.sel_active = True
        # Stay "dragging" so a drag without lifting keeps consuming
        # motion, and remember the clicked word as the fixed anchor.
        self.sel_dragging = True
        self._drag_word = True
        self._drag_line = False
        self._dc_anchor_r = r
        self._dc_anchor_lo = bounds[0]
        self._dc_anchor_hi = bounds[1]

    def _extend_word_drag(mut self, vt: Vt, r: Int, c: Int):
        """Word-snapped extend: the double-clicked word stays anchored;
        the moving end snaps to whichever word the pointer is over."""
        var bounds = self._word_bounds_at(vt, r, c)
        var word_lo = bounds[0]
        var word_hi = bounds[1]
        var ar = self._dc_anchor_r
        var a_lo = self._dc_anchor_lo
        var a_hi = self._dc_anchor_hi
        var backward = (r < ar) or (r == ar and word_hi <= a_lo)
        if backward:
            self.sel_anchor_r = ar
            self.sel_anchor_c = a_hi
            self.sel_focus_r = r
            self.sel_focus_c = word_lo
        else:
            self.sel_anchor_r = ar
            self.sel_anchor_c = a_lo
            self.sel_focus_r = r
            self.sel_focus_c = word_hi
        self.sel_active = True

    def select_line_at(mut self, vt: Vt, pos: Point):
        """Select the full visual row at ``pos`` (triple-click) and arm
        a line-snapped drag."""
        var rc = self.grid_xy_for_pos(vt, pos)
        var r = rc[0]
        self.sel_anchor_r = r
        self.sel_anchor_c = 0
        self.sel_focus_r = r
        self.sel_focus_c = vt.cols
        self.sel_active = True
        self.sel_dragging = True
        self._drag_word = False
        self._drag_line = True
        self._tc_anchor_r = r

    def _extend_line_drag(mut self, vt: Vt, r: Int):
        """Line-snapped extend: whole rows from the triple-clicked anchor
        row to the row under the pointer."""
        var ar = self._tc_anchor_r
        if r >= ar:
            self.sel_anchor_r = ar
            self.sel_anchor_c = 0
            self.sel_focus_r = r
            self.sel_focus_c = vt.cols
        else:
            self.sel_anchor_r = ar
            self.sel_anchor_c = vt.cols
            self.sel_focus_r = r
            self.sel_focus_c = 0
        self.sel_active = True

    # --- mouse forward -------------------------------------------------

    def encode_mouse_forward(
        self, vt: Vt, event: Event, motion: Bool, released: Bool,
    ) -> String:
        """Convert a panel-relative ``Event`` to an xterm mouse byte
        sequence for the child. Returns empty outside the body or when
        the encoder can't represent the coordinates (legacy mode at
        column > 223). The caller writes the bytes to the pty."""
        if self._last_body.is_empty():
            return String("")
        var r = event.pos.y - self._last_body.a.y
        var c = event.pos.x - self._last_body.a.x
        if r < 0 or r >= vt.rows or c < 0 or c >= vt.cols:
            return String("")
        var btn_for_encoder = Int(event.button) - 1
        if event.button == MOUSE_BUTTON_NONE:
            # Motion without a button-change — encode as button 0 with
            # the motion bit set (xterm's "release-button" SGR semantics).
            btn_for_encoder = 0
        if Int(event.button) == 4:    # MOUSE_WHEEL_UP
            btn_for_encoder = 4
        elif Int(event.button) == 5:  # MOUSE_WHEEL_DOWN
            btn_for_encoder = 5
        return vt.encode_mouse(
            button=btn_for_encoder,
            col=c, row=r,
            motion=motion,
            released=released,
            shift=(event.mods & MOD_SHIFT) != 0,
            meta=(event.mods & MOD_ALT) != 0,
            ctrl=(event.mods & MOD_CTRL) != 0,
        )


# --- grid paint -----------------------------------------------------------


def paint_grid(
    mut canvas: Canvas, painter: Painter, vt: Vt,
    sel: GridSelection, body: Rect, focused: Bool,
):
    """Paint the ``Vt`` grid into ``body`` through ``painter`` (whose
    clip rect protects neighbouring panes). Overlays the selection and,
    when ``focused``, a reverse-video cursor caret.

    When the user is scrolled back, the historical rows live in
    ``vt.scrollback`` as ``List[List[Cell]]``. Reading ``scrollback[i]``
    returns by value, so we copy each scrollback row exactly ONCE per
    paint pass rather than once per cell (``view_cell_at`` would copy the
    whole row on every cell lookup — O(rows×cols²) allocs and measurable
    lag when scrolled into a long history)."""
    var sb_len = len(vt.scrollback)
    var scrolled_back = vt.view_offset > 0 and not vt.using_alt
    for r in range(vt.rows):
        var sb_row = List[Cell]()
        var use_sb = False
        if scrolled_back:
            var abs_row = (sb_len - vt.view_offset) + r
            if abs_row >= 0 and abs_row < sb_len:
                sb_row = vt.scrollback[abs_row].copy()
                use_sb = True
        for c in range(vt.cols):
            var cell: Cell
            if use_sb:
                if c < len(sb_row):
                    cell = sb_row[c]
                else:
                    cell = Cell(String(" "), Attr(WHITE, PANE_BG), 1)
            elif scrolled_back:
                # Scrolled back into the live tail's residual rows
                # (when scrollback is shorter than view_offset).
                var abs_row = (sb_len - vt.view_offset) + r
                cell = vt.cell_at(abs_row - sb_len, c)
            else:
                cell = vt.cell_at(r, c)
            var attr = cell.attr
            # Selection overlay: invert the selected cells — the same
            # affordance every terminal uses (xterm, iTerm, alacritty).
            if sel.cell_in_selection(r, c):
                attr = _invert_attr(attr)
            painter.set(
                canvas, body.a.x + c, body.a.y + r,
                Cell(cell.glyph, attr, cell.width),
            )
    # Cursor caret: reverse-video block over the cursor cell when the
    # pane is focused, the child hasn't hidden the cursor (``?25l``),
    # the cursor is in bounds, and the user isn't scrolled back (a
    # scrolled-back view is read-only history; painting the live cursor
    # on a historical row would be confusing).
    if focused and vt.cursor_visible and vt.view_offset == 0:
        var cr = vt.cur_r
        var cc = vt.cur_c
        if 0 <= cr and cr < vt.rows and 0 <= cc and cc < vt.cols:
            var cell = vt.cell_at(cr, cc)
            painter.set(
                canvas, body.a.x + cc, body.a.y + cr,
                Cell(cell.glyph, _invert_attr(cell.attr), cell.width),
            )


# --- key encoding ---------------------------------------------------------


def encode_key(key: UInt32, mods: UInt8, app_cursor: Bool = False) -> String:
    """Translate a Mojo key + modifier into the byte sequence a real
    pty child expects on its stdin. Mirrors what xterm sends.

    Modifiers:
      * Ctrl + letter → 0x01..0x1A (the canonical "control character").
      * Alt + key     → ESC prefix, same as xterm's meta-as-prefix.
      * Shift / Ctrl / Alt with named keys (arrows, Home/End/PageUp/
        PageDown, F1..F12, Tab) use the xterm CSI 1;Nc format where
        N = 1 + shift*1 + alt*2 + ctrl*4. Without this, word-motion
        bindings in zsh/bash and vim window-nav (Ctrl+Right etc.)
        don't work.
      * ``app_cursor`` honors DECCKM (``?1``) — arrow / Home / End
        come out as SS3 (``ESC O A``) instead of CSI (``ESC [ A``).
        ``less`` / ``man`` flip this on; without honoring it their
        readline bindings break.
      * Cmd/Meta is reserved for the host (Cmd+C copy, etc.)."""
    var alt = (mods & MOD_ALT) != 0
    var ctrl = (mods & MOD_CTRL) != 0
    var shift = (mods & MOD_SHIFT) != 0
    var prefix = String("\x1b") if alt else String("")
    # xterm-style modifier byte: 1 + shift*1 + alt*2 + ctrl*4 (encoded
    # as ASCII digits in the CSI parameter slot). 1 == no modifier;
    # we only insert the param block when the byte > 1.
    var mod_byte = 1
    if shift: mod_byte += 1
    if alt:   mod_byte += 2
    if ctrl:  mod_byte += 4
    var has_mods = mod_byte > 1
    # When the modifier param is set we drop the ESC prefix — the
    # modifier param IS the encoding for alt now; doubling it would
    # send ESC ESC [ 1;N…, which apps would parse as alt-ESC.
    if has_mods:
        prefix = String("")

    if key == KEY_ENTER:
        # ``\r`` (CR). Most tty drivers translate CR → NL via ICRNL, so
        # the child reads it as ``\n``. Sending ``\n`` directly would
        # skip that and confuse programs that distinguish (``read -r``).
        return prefix + String("\r")
    if key == KEY_TAB:
        # Shift+Tab → ``CSI Z`` (kcbt) so reverse-tab navigation works
        # (fzf, completion menus, vim's window cycler).
        if shift and not ctrl and not alt:
            return String("\x1b[Z")
        return prefix + String("\t")
    if key == KEY_BACKSPACE:
        # Most modern terminals send DEL (0x7F) for Backspace and let
        # the line discipline translate it via ``stty erase``. Ctrl+
        # Backspace sends BS (0x08) — many readline configs bind it to
        # backward-kill-word.
        if ctrl:
            return prefix + String("\x08")
        return prefix + String("\x7f")
    if key == KEY_ESC:
        return prefix + String("\x1b")
    # Arrows / Home / End — three forms depending on DECCKM + mods:
    #   1. modified           → ``ESC [ 1 ; N c``  (xterm modifyOtherKeys)
    #   2. unmodified, no app  → ``ESC [ c``        (CSI form)
    #   3. unmodified, app on  → ``ESC O c``        (SS3 form)
    if key == KEY_UP:
        if has_mods: return _csi_mod(String("A"), mod_byte)
        return prefix + (String("\x1bOA") if app_cursor else String("\x1b[A"))
    if key == KEY_DOWN:
        if has_mods: return _csi_mod(String("B"), mod_byte)
        return prefix + (String("\x1bOB") if app_cursor else String("\x1b[B"))
    if key == KEY_RIGHT:
        if has_mods: return _csi_mod(String("C"), mod_byte)
        return prefix + (String("\x1bOC") if app_cursor else String("\x1b[C"))
    if key == KEY_LEFT:
        if has_mods: return _csi_mod(String("D"), mod_byte)
        return prefix + (String("\x1bOD") if app_cursor else String("\x1b[D"))
    if key == KEY_HOME:
        if has_mods: return _csi_mod(String("H"), mod_byte)
        return prefix + (String("\x1bOH") if app_cursor else String("\x1b[H"))
    if key == KEY_END:
        if has_mods: return _csi_mod(String("F"), mod_byte)
        return prefix + (String("\x1bOF") if app_cursor else String("\x1b[F"))
    # ``~``-terminated nav / function keys — modifier param goes before
    # the tilde (``ESC [ 5 ; N ~``).
    if key == KEY_PAGEUP:
        if has_mods: return _csi_mod_tilde(5, mod_byte)
        return prefix + String("\x1b[5~")
    if key == KEY_PAGEDOWN:
        if has_mods: return _csi_mod_tilde(6, mod_byte)
        return prefix + String("\x1b[6~")
    if key == KEY_INSERT:
        if has_mods: return _csi_mod_tilde(2, mod_byte)
        return prefix + String("\x1b[2~")
    if key == KEY_DELETE:
        if has_mods: return _csi_mod_tilde(3, mod_byte)
        return prefix + String("\x1b[3~")
    # Function keys — SS3 form for F1..F4, CSI ~ form for F5+. Matches
    # xterm-256color's terminfo.
    if key == KEY_F1:
        if has_mods: return _csi_mod(String("P"), mod_byte)
        return prefix + String("\x1bOP")
    if key == KEY_F2:
        if has_mods: return _csi_mod(String("Q"), mod_byte)
        return prefix + String("\x1bOQ")
    if key == KEY_F3:
        if has_mods: return _csi_mod(String("R"), mod_byte)
        return prefix + String("\x1bOR")
    if key == KEY_F4:
        if has_mods: return _csi_mod(String("S"), mod_byte)
        return prefix + String("\x1bOS")
    if key == KEY_F5:
        if has_mods: return _csi_mod_tilde(15, mod_byte)
        return prefix + String("\x1b[15~")
    if key == KEY_F6:
        if has_mods: return _csi_mod_tilde(17, mod_byte)
        return prefix + String("\x1b[17~")
    if key == KEY_F7:
        if has_mods: return _csi_mod_tilde(18, mod_byte)
        return prefix + String("\x1b[18~")
    if key == KEY_F8:
        if has_mods: return _csi_mod_tilde(19, mod_byte)
        return prefix + String("\x1b[19~")
    if key == KEY_F9:
        if has_mods: return _csi_mod_tilde(20, mod_byte)
        return prefix + String("\x1b[20~")
    if key == KEY_F10:
        if has_mods: return _csi_mod_tilde(21, mod_byte)
        return prefix + String("\x1b[21~")
    if key == KEY_F11:
        if has_mods: return _csi_mod_tilde(23, mod_byte)
        return prefix + String("\x1b[23~")
    if key == KEY_F12:
        if has_mods: return _csi_mod_tilde(24, mod_byte)
        return prefix + String("\x1b[24~")

    # Printable character key.
    var ch = Int(key)
    if ch >= 0x20 and ch < 0x10FFFF and ch < 0xE000:
        # Ctrl + ascii letter / @ / [ / \ / ] / ^ / _ → C0 control byte.
        if ctrl:
            var upper = ch
            if upper >= 0x61 and upper <= 0x7A:  # lower → upper
                upper = upper - 0x20
            if upper >= 0x40 and upper <= 0x5F:
                var b = upper - 0x40
                return prefix + _ascii_to_string(UInt8(b))
            # Ctrl+space / Ctrl+2 → NUL.
            if upper == 0x20 or upper == 0x32:
                return prefix + _ascii_to_string(UInt8(0))
            # Other Ctrl+printable → just send the character; xterm's
            # behavior is similar (some glyphs aren't C0-mappable).
        return prefix + _codepoint_to_utf8(UInt32(ch))
    return String("")


def _csi_mod(letter: String, mod_byte: Int) -> String:
    """xterm modifier-encoded form: ``ESC [ 1 ; N c`` where ``c`` is the
    final letter (A/B/C/D/H/F/P/Q/R/S). Modified arrows, Home/End,
    F1..F4."""
    return String("\x1b[1;") + String(mod_byte) + letter


def _csi_mod_tilde(num: Int, mod_byte: Int) -> String:
    """xterm modifier-encoded ``~``-terminated form: ``ESC [ n ; N ~``.
    Modified PageUp/PageDown/Insert/Delete and F5..F12."""
    return String("\x1b[") + String(num) + String(";") \
        + String(mod_byte) + String("~")


def _codepoint_to_utf8(cp: UInt32) -> String:
    """Encode a Unicode codepoint to its UTF-8 byte sequence as a
    String. The pty child reads bytes — we convert from Mojo's
    codepoint-as-UInt32 representation back to wire bytes."""
    var c = Int(cp)
    var buf = List[UInt8]()
    if c < 0x80:
        buf.append(UInt8(c))
    elif c < 0x800:
        buf.append(UInt8(0xC0 | (c >> 6)))
        buf.append(UInt8(0x80 | (c & 0x3F)))
    elif c < 0x10000:
        buf.append(UInt8(0xE0 | (c >> 12)))
        buf.append(UInt8(0x80 | ((c >> 6) & 0x3F)))
        buf.append(UInt8(0x80 | (c & 0x3F)))
    else:
        buf.append(UInt8(0xF0 | (c >> 18)))
        buf.append(UInt8(0x80 | ((c >> 12) & 0x3F)))
        buf.append(UInt8(0x80 | ((c >> 6) & 0x3F)))
        buf.append(UInt8(0x80 | (c & 0x3F)))
    return String(StringSpan(unsafe_from_utf8=Span(unsafe_ptr=buf.unsafe_ptr(), length=len(buf))))


def _ascii_to_string(b: UInt8) -> String:
    var buf = List[UInt8]()
    buf.append(b)
    return String(StringSpan(unsafe_from_utf8=Span(unsafe_ptr=buf.unsafe_ptr(), length=1)))


# --- visual helpers -------------------------------------------------------


def _is_word_glyph(glyph: String) -> Bool:
    """Classify a cell's glyph for double-click word selection. Word
    characters are letters / digits / underscore / dot / slash / dash —
    generous enough that file paths and identifiers stay one word, but
    separators like spaces, brackets, and quotes split. Same broad
    definition every modern terminal uses."""
    var b = glyph.as_bytes()
    var n = len(b)
    if n == 0:
        return False
    # Look at the first codepoint only — good enough for ASCII content
    # and for CJK / emoji cells (treat any non-ASCII as "word" so a
    # boundary doesn't cut a Chinese / Japanese identifier in half).
    var c = Int(b[0])
    if c >= 0x80:
        return True
    if c >= 0x30 and c <= 0x39: return True  # 0-9
    if c >= 0x41 and c <= 0x5A: return True  # A-Z
    if c >= 0x61 and c <= 0x7A: return True  # a-z
    if c == 0x5F: return True                # _
    if c == 0x2E: return True                # .
    if c == 0x2D: return True                # -
    if c == 0x2F: return True                # /
    return False


def _invert_attr(a: Attr) -> Attr:
    """Swap fg/bg for selection / cursor overlay. We don't toggle
    ``STYLE_REVERSE`` because the underlying cell may already have it
    set (vim's status line) — swapping fg/bg lands at the same visual
    either way and saves the parity branch."""
    var r = Attr(a.bg, a.fg, a.style)
    r.underline_color = a.underline_color
    # Swap truecolor channels too: a selected/cursored truecolor cell
    # must invert its real RGB, not just the folded index.
    r.fg_rgb = a.bg_rgb
    r.bg_rgb = a.fg_rgb
    var mode = UInt8(0)
    if (a.color_mode & BG_TRUECOLOR) != 0:
        mode = mode | FG_TRUECOLOR
    if (a.color_mode & FG_TRUECOLOR) != 0:
        mode = mode | BG_TRUECOLOR
    r.color_mode = mode
    return r
