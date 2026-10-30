"""Shared Vt-grid view: selection, grid paint, and key/mouse encoding.

Both the shell terminal (``terminal_pane.mojo``) and the test runner
(``test_pane.mojo``) render a ``Vt`` emulator grid into a bottom-docked
pane and let the user select / copy / scroll it and (for the shell)
type into it. The grid-view behavior — the cell+cursor paint loop, the
mouse-driven selection state machine (cell / word / line drag), and the
key→pty / mouse→pty forwarding — is identical between them and lives here
so neither pane reimplements it. The wire encodings themselves are Ghostty's
(``Vt.encode_key`` / ``Vt.encode_mouse``), so they track whatever modes the
program enabled.

The owning pane keeps the ``Vt`` and the ``PtyProcess`` (the pty is a
kernel handle the pane's lifecycle owns); this module's functions take
the ``Vt`` by borrow and *return* the bytes to send rather than writing
them, so the pane stays the single writer to its child.
"""

from std.collections.list import List

from .canvas import Canvas
from .cell import Cell
from .clipboard import clipboard_copy
from .colors import Attr, BG_TRUECOLOR, FG_TRUECOLOR
from .events import (
    Event, KEY_PAGEDOWN, KEY_PAGEUP, MOD_META, MOD_SHIFT, MOUSE_BUTTON_LEFT,
)
from .geometry import Point, Rect
from .painter import Painter
from .pty import PtyProcess
from .vt import Vt


struct GridSelection(Copyable, Movable):
    """Mouse selection state over a ``Vt`` grid, in (row, col)
    coordinates whose row is *absolute* — counted from the top of the
    scrollback (``_view_top``), not from the viewport — so a selection
    stays on its text while the view scrolls or new output pushes it up. Drives the inverted overlay during paint and the
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
        # Rows scrolled out of the view are only readable through the
        # viewport, so scroll a (handle-aliasing) copy over them and put
        # the view back where the user left it.
        var v = vt
        var orig_offset = v.view_offset()
        var rows = v.rows()
        var out = String("")
        for r in range(sr0, sr1 + 1):
            var c_start = sc0 if r == sr0 else 0
            var c_end   = sc1 if r == sr1 else v.cols()
            if c_end > v.cols(): c_end = v.cols()
            if c_start < 0: c_start = 0
            var vr = r - _view_top(v)
            if vr < 0:
                v.scroll_view_by(-vr)
                vr = r - _view_top(v)
            elif vr >= rows:
                v.scroll_view_by(-(vr - rows + 1))
                vr = r - _view_top(v)
            if 0 <= vr and vr < rows:
                out += v.row_text(vr, c_start, c_end)
            if r < sr1:
                out = out + String("\n")
        if v.view_offset() != orig_offset:
            if orig_offset == 0:
                v.reset_view()
            else:
                v.scroll_view_by(orig_offset - v.view_offset())
        return out^

    # --- screen→grid mapping -------------------------------------------

    def grid_xy_for_pos(self, vt: Vt, pos: Point) -> Tuple[Int, Int]:
        """Convert a screen position to ``(row, col)`` in the VT grid,
        the row absolute (see the struct docstring). Out-of-body positions
        clamp to the nearest edge — that's what you want for a drag that
        left the body."""
        if self._last_body.is_empty():
            return (0, 0)
        var r = pos.y - self._last_body.a.y
        var c = pos.x - self._last_body.a.x
        var rows = vt.rows()
        var cols = vt.cols()
        if r < 0: r = 0
        if r >= rows: r = rows - 1
        if c < 0: c = 0
        if c > cols: c = cols
        return (r + _view_top(vt), c)

    # --- drag ----------------------------------------------------------

    def continue_drag(mut self, vt: Vt, event: Event) -> Bool:
        """Feed an in-flight drag selection: a left release ends it, motion
        extends it. Runs before the pane's body hit-test so a fast drag
        that overshoots the edge keeps selecting. True when consumed."""
        if not self.sel_dragging:
            return False
        if event.button == MOUSE_BUTTON_LEFT and not event.pressed:
            self.end_drag(vt, event.pos)
            return True
        if event.motion:
            self.extend_drag(vt, event.pos)
            return True
        return False

    def click(mut self, vt: Vt, event: Event):
        """A left press in the body: triple-click selects the row,
        double-click the word under the pointer, a single click starts a
        cell drag. ``click_count`` comes from the input parser, so no
        timing state lives here."""
        if event.click_count >= 3:
            self.select_line_at(vt, event.pos)
        elif event.click_count == 2:
            self.select_word_at(vt, event.pos)
        else:
            self.begin_drag(vt, event.pos)

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

    def _word_bounds_at(
        self, vt: Vt, r_abs: Int, c_in: Int,
    ) -> Tuple[Int, Int]:
        """``(lo, hi)`` of the word-class run around column ``c_in`` on
        row ``r`` — ``lo`` inclusive, ``hi`` exclusive. A separator cell
        returns just that single cell. ``r_abs`` is absolute and must be
        in the view (it's the row under the pointer)."""
        var grid = vt.grid()
        var r = r_abs - _view_top(vt)
        if r < 0 or r >= grid.rows:
            return (c_in, c_in + 1)
        var c = c_in
        if c >= grid.cols: c = grid.cols - 1
        if c < 0: c = 0
        if not _is_word_glyph(grid.cell(r, c).glyph):
            return (c, c + 1)
        var lo = c
        while lo > 0:
            if not _is_word_glyph(grid.cell(r, lo - 1).glyph):
                break
            lo -= 1
        var hi = c
        while hi + 1 < grid.cols:
            if not _is_word_glyph(grid.cell(r, hi + 1).glyph):
                break
            hi += 1
        return (lo, hi + 1)

    def select_word_at(mut self, vt: Vt, pos: Point):
        """Select the word under ``pos`` and arm a word-snapped drag."""
        var rc = self.grid_xy_for_pos(vt, pos)
        var r = rc[0]
        var c = rc[1]
        if c >= vt.cols(): c = vt.cols() - 1
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
        self.sel_focus_c = vt.cols()
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
            self.sel_focus_c = vt.cols()
        else:
            self.sel_anchor_r = ar
            self.sel_anchor_c = vt.cols()
            self.sel_focus_r = r
            self.sel_focus_c = 0
        self.sel_active = True

    # --- mouse forward -------------------------------------------------

    def encode_mouse_forward(
        self, vt: Vt, event: Event, action: Int,
    ) -> String:
        """Convert a panel-relative ``Event`` to the mouse report the child
        asked for (``action`` is a ``vt.MOUSE_*`` value). Returns empty
        outside the body, or when the child enabled no report for it. The
        caller writes the bytes to the pty."""
        if self._last_body.is_empty():
            return String("")
        var r = event.pos.y - self._last_body.a.y
        var c = event.pos.x - self._last_body.a.x
        if r < 0 or r >= vt.rows() or c < 0 or c >= vt.cols():
            return String("")
        return vt.encode_mouse(action, event.button, c, r, event.mods)


# --- grid paint -----------------------------------------------------------


def paint_grid(
    mut canvas: Canvas, painter: Painter, vt: Vt,
    sel: GridSelection, body: Rect, focused: Bool,
):
    """Paint the ``Vt`` grid into ``body`` through ``painter`` (whose
    clip rect protects neighbouring panes). Overlays the selection and,
    when ``focused``, a reverse-video cursor caret.

    Reads the viewport — scrollback included when the user has scrolled
    up — from one snapshot, so a frame costs one pass over the cells."""
    var grid = vt.grid()
    var top = _view_top(vt)
    for r in range(grid.rows):
        for c in range(grid.cols):
            var cell = grid.cell(r, c)
            # Selection overlay: invert the selected cells — the same
            # affordance every terminal uses (xterm, iTerm, alacritty).
            if sel.cell_in_selection(top + r, c):
                cell.attr = _invert_attr(cell.attr)
            painter.set(canvas, body.a.x + c, body.a.y + r, cell)
    # Cursor caret: reverse-video block over the cursor cell when the
    # pane is focused, the child hasn't hidden the cursor (``?25l``),
    # the cursor is in bounds, and the user isn't scrolled back (a
    # scrolled-back view is read-only history; painting the live cursor
    # on a historical row would be confusing).
    if focused and vt.cursor_visible() and vt.view_offset() == 0:
        var cr = vt.cursor_row()
        var cc = vt.cursor_col()
        if 0 <= cr and cr < grid.rows and 0 <= cc and cc < grid.cols:
            var cell = grid.cell(cr, cc)
            painter.set(
                canvas, body.a.x + cc, body.a.y + cr,
                Cell(cell.glyph, _invert_attr(cell.attr), cell.width),
            )


# --- visual helpers -------------------------------------------------------


def _view_top(vt: Vt) -> Int:
    """Absolute row (counted from the top of the scrollback) of the
    viewport's first row — what ``GridSelection`` adds to a view row."""
    return vt.scrollback_rows() - vt.view_offset()


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


def flush_vt_side_effects(pty: PtyProcess, mut vt: Vt):
    """Deliver what the last ``Vt.feed`` queued: DSR / DA / OSC replies go
    back to the child, OSC 52 clipboard writes to the system clipboard.
    Without the replies, prompts that probe (oh-my-zsh / starship) stall;
    without the clipboard, ``vim`` / ``tmux`` yanks silently drop."""
    var reply = vt.take_reply()
    if len(reply.as_bytes()) > 0:
        pty.write_all(reply)
    var clip = vt.take_clipboard()
    if len(clip.as_bytes()) > 0:
        clipboard_copy(clip)


def paste_to_pty(pty: PtyProcess, vt: Vt, text: String):
    """Send pasted ``text`` to the child — wrapped in ``ESC[200~`` /
    ``ESC[201~`` when it enabled bracketed paste (DECSET 2004), so a
    multi-line paste into a shell or vim doesn't run each line as a
    command."""
    if vt.bracketed_paste():
        pty.write_all(String("\x1b[200~") + text + String("\x1b[201~"))
    else:
        pty.write_all(text)


def forward_key_to_grid(
    pty: PtyProcess, mut vt: Vt, mut sel: GridSelection, event: Event,
) -> Bool:
    """The key handling a pty pane shares once its own chrome keys (Cmd+W,
    ESC) are dealt with: Shift+PgUp/PgDn scroll the scrollback, Cmd+C
    copies an active selection (otherwise it falls through so the child
    gets a real Ctrl+C), any other key clears the selection, snaps the
    view back to the live tail and goes to the child encoded."""
    if event.key == KEY_PAGEUP and (event.mods & MOD_SHIFT) != 0:
        vt.scroll_view_by(vt.rows() - 2)
        return True
    if event.key == KEY_PAGEDOWN and (event.mods & MOD_SHIFT) != 0:
        vt.scroll_view_by(-(vt.rows() - 2))
        return True
    if event.key == UInt32(ord("c")) and event.mods == MOD_META \
            and sel.sel_active:
        _ = sel.copy_to_clipboard(vt)
        sel.clear()
        return True
    # Any keystroke clears a finished selection, and typing snaps back to
    # the live tail — same as every terminal app.
    sel.sel_active = False
    if vt.view_offset() != 0:
        vt.reset_view()
    var encoded = vt.encode_key(event.key, event.mods)
    if len(encoded.as_bytes()) > 0:
        pty.write_all(encoded)
        return True
    return False
