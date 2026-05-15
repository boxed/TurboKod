"""Minimal vt100-ish terminal emulator.

This is what sits between the pty's master fd and the on-screen
``Cell`` grid. The child writes bytes that look like a real terminal
session (text + ANSI escapes); we parse the escapes, mutate a 2D
``Cell`` grid + cursor, and the pane paints the grid every frame.

Scope: enough to host ``claude``, ``vim``, ``less``, and other
ink/curses-style apps. We deliberately do *not* implement every
xterm extension — only the sequences these programs actually emit:

* Control chars: BS, HT, LF/VT/FF, CR, BEL (and the implicit
  newline-on-LF behavior with scroll region).
* CSI cursor moves: CUU/CUD/CUF/CUB (A/B/C/D), CHA (G), CUP (H/f),
  VPA (d).
* CSI erase: ED (J), EL (K).
* CSI line ops: IL (L), DL (M), ICH (@), DCH (P), ECH (X).
* CSI scroll region: DECSTBM (r).
* CSI SGR (m) — colors (16/256), bold/dim/italic/underline/reverse/
  strike, reset.
* DEC private modes: ?1049 (alternate screen + save cursor),
  ?25 (cursor visibility), ?7 (DECAWM auto-wrap). Mouse/bracketed-
  paste modes are accepted-but-ignored so the child doesn't see an
  error when it tries to enable them.
* ESC dispatches: 7/8 (DECSC/DECRC), D (IND), E (NEL), M (RI), c
  (RIS reset).
* OSC 0/1/2: window title (consumed into ``title``).

Not implemented (deliberate): scrollback (the pane owns scrollback
on top of us), origin mode (DECOM), character sets (G0/G1), tab
stops (we treat tabs as "advance to next column-multiple-of-8"),
SOS/PM/APC strings (skipped), DCS strings (skipped).

The parser is a tiny state machine — GROUND → ESC → CSI/OSC/etc. We
keep all state on the ``Vt`` struct so the emulator is value-type
and trivially unit-testable: feed bytes, inspect cells/cursor,
assert.
"""

from std.collections.list import List
from std.memory.span import Span

from .cell import Cell, blank_cell
from .colors import (
    Attr, BLACK, BLUE, CYAN, GREEN, LIGHT_BLUE, LIGHT_CYAN, LIGHT_GRAY,
    LIGHT_GREEN, LIGHT_MAGENTA, LIGHT_RED, LIGHT_YELLOW, MAGENTA,
    RED, WHITE, YELLOW,
    DARK_GRAY,
    STYLE_BOLD, STYLE_DIM, STYLE_ITALIC, STYLE_NONE, STYLE_REVERSE,
    STYLE_STRIKE, STYLE_UNDERLINE,
)


# --- parser states --------------------------------------------------------
# These are deliberately small ints so the state field can live as a
# UInt8 — saves nothing measurable but matches the rest of the codebase's
# pattern of tagged-union discriminants.

comptime _S_GROUND      = UInt8(0)
"""Plain output — bytes paint into the grid as glyphs."""
comptime _S_ESC         = UInt8(1)
"""Just saw ESC (0x1B), dispatching on the next byte."""
comptime _S_CSI         = UInt8(2)
"""Inside ``ESC [`` — accumulating parameter bytes (digits, ``;``)
and optional intermediates (``?``, ``>``, etc.) until a final byte
(0x40..0x7E) closes the sequence."""
comptime _S_OSC         = UInt8(3)
"""Inside ``ESC ]`` — accumulating text until BEL (0x07) or ST
(``ESC \\``). Used for window title."""
comptime _S_OSC_ESC     = UInt8(4)
"""Inside an OSC, just saw an ESC — looking for the ``\\`` that
finishes a String Terminator. If anything else follows, abort the
OSC and re-feed the byte."""
comptime _S_UTF8        = UInt8(5)
"""Building a multi-byte UTF-8 codepoint. Continuation bytes accumulate
until the codepoint is complete, then the whole thing is placed as
one cell."""
comptime _S_ESC_CHARSET = UInt8(6)
"""Seen ``ESC (`` / ``ESC )`` / ``ESC *`` / ``ESC +`` — a G0/G1
charset designator. Consume exactly one more byte (the designator,
e.g. ``B`` for ASCII) then return to GROUND. We don't track which
charset is active; UTF-8 makes this irrelevant for the apps we
host."""


# --- default palette mapping ---------------------------------------------
# ANSI SGR uses 0..7 / 8..15 (bright) for the 16-color palette. Our
# project's ``Attr`` uses the same 256-color indices, so the mapping
# is the identity for these — but a few of our named constants (e.g.
# LIGHT_GRAY for SGR 7, DARK_GRAY for SGR 8 "bright black") differ from
# what a naive 0..7 cast would suggest. Build a table so the SGR
# parser is one indexed lookup.

fn _ansi_color(idx: Int) -> UInt8:
    """Map an SGR 30-37 / 90-97 base color to our palette index."""
    if idx == 0: return BLACK
    if idx == 1: return RED
    if idx == 2: return GREEN
    if idx == 3: return YELLOW
    if idx == 4: return BLUE
    if idx == 5: return MAGENTA
    if idx == 6: return CYAN
    if idx == 7: return LIGHT_GRAY
    if idx == 8: return DARK_GRAY
    if idx == 9: return LIGHT_RED
    if idx == 10: return LIGHT_GREEN
    if idx == 11: return LIGHT_YELLOW
    if idx == 12: return LIGHT_BLUE
    if idx == 13: return LIGHT_MAGENTA
    if idx == 14: return LIGHT_CYAN
    return WHITE


# --- emulator struct ------------------------------------------------------


struct Vt(Copyable, Movable):
    """Pure-data terminal emulator.

    Owns a primary screen, an alt screen, a cursor, an SGR-derived
    ``current_attr``, and a tiny parse-state machine. Mutation
    happens exclusively through ``feed(bytes)`` — the caller pushes
    raw bytes drained off the pty, we update internal state, the
    pane reads the grid back via ``cell_at``.
    """
    var cols: Int
    var rows: Int

    var primary: List[Cell]
    """Main screen — flat ``cols * rows`` row-major buffer."""
    var alt: List[Cell]
    """Alternate screen — same shape, swapped in by ``?1049h`` (used
    by vim, less, fzf, mc, …). Switching back via ``?1049l`` restores
    the primary verbatim so the user's scrollback isn't trampled."""
    var using_alt: Bool

    var cur_r: Int
    var cur_c: Int
    var saved_cur_r: Int
    var saved_cur_c: Int
    """DEC saved cursor — ``ESC 7`` stashes ``(cur_r, cur_c, attr)``,
    ``ESC 8`` restores. Also used implicitly by ``?1049h/l``."""
    var saved_attr: Attr

    var current_attr: Attr
    """SGR state applied to every glyph painted in GROUND state."""

    var scroll_top: Int
    """Inclusive top of the scroll region (0-indexed). LF at the
    bottom of the region scrolls the lines inside the region, not
    the whole screen."""
    var scroll_bot: Int
    """Inclusive bottom of the scroll region."""

    var auto_wrap: Bool
    """DECAWM — when true (default), writing past the last column
    causes the cursor to wrap to column 0 of the next row on the
    *next* glyph (delayed-wrap semantics matching xterm)."""
    var wrap_pending: Bool
    """True when the last printed glyph filled the last column.
    The next printable byte triggers the actual wrap; intervening
    cursor-moving CSI escapes cancel it. This matches xterm's
    behavior and is what ``vim`` / ``less`` depend on to avoid an
    unwanted blank line after a full-width line."""

    var cursor_visible: Bool
    """``?25l`` hides, ``?25h`` shows. The pane honors this in its
    overlay — when False, no cursor caret is painted."""

    var title: String
    """Last OSC 0/1/2 title set by the child. Empty if none. The
    pane displays this in its chrome alongside the Claude-state
    label (see ``claude_detect.mojo``)."""

    var bell_pending: Bool
    """BEL (0x07) latched here so the pane can flash the title
    once and clear; we don't otherwise act on it. Set by the parser,
    consumed by ``take_bell``."""

    # --- parser state ---------------------------------------------------
    var _state: UInt8
    var _csi_params: List[Int]
    """Numeric parameters accumulated in the current CSI. Each entry
    is a parsed integer; a missing parameter (``;;``) shows up as 0
    (treated as "default" by the dispatch table — that's the standard
    behavior). Note: this loses sub-parameter (``:``) detail, which
    is fine for the sequences we handle."""
    var _csi_current: Int
    """Digits accumulated for the in-progress parameter; flushed
    into ``_csi_params`` on ``;`` or on dispatch."""
    var _csi_has_digit: Bool
    """Did the current parameter have any digit? Lets us distinguish
    ``ESC [ m`` (one default param = 0 → reset) from ``ESC [ 0 m``
    (one explicit 0 → reset). Both behave the same for SGR, but the
    distinction matters for sequences where default != 0."""
    var _csi_private: UInt8
    """Private-marker byte (``?``, ``>``, ``=``) if any, else 0.
    DECSET/DECRESET use ``?``."""
    var _csi_intermediate: UInt8
    """Intermediate byte (``0x20..0x2F``) if any, else 0. The only
    one we actually care about today is ``SP`` (0x20) which marks
    ``CSI Ps SP q`` — DECSCUSR (cursor shape). Anything else gets
    parsed but ignored at dispatch."""
    var _osc_buf: String
    """Accumulator for the OSC string body."""
    var _utf8_remaining: Int
    var _utf8_buf: List[UInt8]

    # --- scrollback -----------------------------------------------------
    var scrollback: List[List[Cell]]
    """Rows that have scrolled off the *top* of the primary grid. One
    inner ``List[Cell]`` per row, oldest first. Bounded by
    ``scrollback_cap`` — pushing past the cap drops the oldest entry.

    Alt screen scrolls don't go here: vim / less / fzf own their own
    history (and the scrollback's whole point is preserving content
    that the *shell* produced). When ``using_alt`` is True we just
    blank the displaced rows and move on."""
    var scrollback_cap: Int
    """Maximum number of rows retained. 1000 by default — enough for
    a couple of screenfuls of recent shell output, small enough that
    a typical session's memory footprint stays well under a megabyte
    (each row is roughly ``cols`` × 32B-ish; an 80-column grid uses
    ~3 KB per row, ~3 MB at the cap). Resize doesn't touch this."""
    var view_offset: Int
    """How many rows of scrollback to show *above* the live grid.
    ``0`` means "live view" (rendering matches ``cell_at``). Each
    increment shifts the viewport one row toward older content; the
    bottom row drops off the bottom of the visible window. Capped at
    ``len(scrollback)``."""

    # --- mouse tracking -------------------------------------------------
    var mouse_track_press: Bool
    """``?1000h`` — report mouse press + release."""
    var mouse_track_btn_motion: Bool
    """``?1002h`` — report drag motion *while a button is held*. The
    layered tracking precedence is 1003 > 1002 > 1000; the pane
    consults ``mouse_track_mode`` for the effective level."""
    var mouse_track_any_motion: Bool
    """``?1003h`` — report all motion regardless of button state."""
    var mouse_sgr: Bool
    """``?1006h`` — use the SGR encoding (``\\x1b[<…M/m``) which
    handles columns > 223 and unambiguous release events. Most
    modern apps enable this alongside 1000; we encode in the SGR form
    when this is set, fall back to the legacy X10/normal form when
    not."""
    var app_cursor_keys: Bool
    """DECCKM (``?1``) — when on, arrow keys are sent as SS3 (``ESC O
    A`` etc.) instead of CSI (``ESC [ A``). ``less`` / ``man`` /
    ``vim``'s alternate-screen pager modes flip this on so they can
    bind arrow-style readline differently from cursor-style; without
    honoring it, arrow keys do the wrong thing inside those apps.
    Encoding lives in the pane's ``_encode_key``; we just expose the
    state."""
    var bracketed_paste: Bool
    """``?2004`` — when on, the pane wraps pasted text with
    ``ESC[200~ … ESC[201~`` before forwarding. Without it, multi-line
    paste into shells / editors runs each line as a separate command;
    with it, the receiver knows to treat the whole blob as a single
    insert."""
    var focus_events: Bool
    """``?1004`` — when on, the pane reports focus-in (``ESC[I``) and
    focus-out (``ESC[O``) to the child. vim uses these for
    ``FocusGained``/``FocusLost`` autocmds."""
    var cursor_shape: UInt8
    """DECSCUSR (``CSI Ps SP q``) — block / underline / bar. 0 = host
    default (block), 1/2 = blinking/steady block, 3/4 =
    blinking/steady underline, 5/6 = blinking/steady bar. We surface
    the raw param so a future painter can use it; today the pane only
    distinguishes "block" from "bar" for the cursor caret style."""
    var reply_buf: String
    """Outbound queue of bytes for the child. The emulator pushes
    here on DSR / DA / OSC-with-reply; the pane drains it via
    ``take_reply`` each tick and writes the result to the pty master.
    Without this channel, prompts that probe (oh-my-zsh, starship)
    stall briefly on every redraw."""
    var _clipboard_pending: String
    """Most recent OSC 52 payload (already base64-decoded). The pane
    drains this via ``take_clipboard`` each tick and writes it to the
    system clipboard. We don't ack the write back to the child."""

    fn __init__(out self, cols: Int = 80, rows: Int = 24):
        self.cols       = cols if cols > 0 else 1
        self.rows       = rows if rows > 0 else 1
        self.primary    = _make_grid(self.cols, self.rows)
        self.alt        = _make_grid(self.cols, self.rows)
        self.using_alt  = False
        self.cur_r      = 0
        self.cur_c      = 0
        self.saved_cur_r = 0
        self.saved_cur_c = 0
        self.saved_attr = Attr()
        self.current_attr = Attr()
        self.scroll_top = 0
        self.scroll_bot = self.rows - 1
        self.auto_wrap  = True
        self.wrap_pending = False
        self.cursor_visible = True
        self.title      = String("")
        self.bell_pending = False
        self._state     = _S_GROUND
        self._csi_params = List[Int]()
        self._csi_current = 0
        self._csi_has_digit = False
        self._csi_private = 0
        self._csi_intermediate = 0
        self._osc_buf   = String("")
        self._utf8_remaining = 0
        self._utf8_buf  = List[UInt8]()
        self.scrollback = List[List[Cell]]()
        self.scrollback_cap = 1000
        self.view_offset = 0
        self.mouse_track_press = False
        self.mouse_track_btn_motion = False
        self.mouse_track_any_motion = False
        self.mouse_sgr = False
        self.app_cursor_keys = False
        self.bracketed_paste = False
        self.focus_events = False
        self.cursor_shape = 0
        self.reply_buf = String("")
        self._clipboard_pending = String("")

    fn __copyinit__(mut self, copy: Self):
        # Explicit because ``List[Cell]`` isn't auto-copyable — Mojo's
        # value semantics require the deep copy to be spelled out.
        # The pane composes a Vt and is ImplicitlyCopyable itself
        # (matching DebugPane / TerminalPane), so this is the bridge
        # that lets the outer copies actually compile.
        self.cols       = copy.cols
        self.rows       = copy.rows
        self.primary    = copy.primary.copy()
        self.alt        = copy.alt.copy()
        self.using_alt  = copy.using_alt
        self.cur_r      = copy.cur_r
        self.cur_c      = copy.cur_c
        self.saved_cur_r = copy.saved_cur_r
        self.saved_cur_c = copy.saved_cur_c
        self.saved_attr = copy.saved_attr
        self.current_attr = copy.current_attr
        self.scroll_top = copy.scroll_top
        self.scroll_bot = copy.scroll_bot
        self.auto_wrap  = copy.auto_wrap
        self.wrap_pending = copy.wrap_pending
        self.cursor_visible = copy.cursor_visible
        self.title      = copy.title
        self.bell_pending = copy.bell_pending
        self._state     = copy._state
        self._csi_params = copy._csi_params.copy()
        self._csi_current = copy._csi_current
        self._csi_has_digit = copy._csi_has_digit
        self._csi_private = copy._csi_private
        self._csi_intermediate = copy._csi_intermediate
        self._osc_buf   = copy._osc_buf
        self._utf8_remaining = copy._utf8_remaining
        self._utf8_buf  = copy._utf8_buf.copy()
        self.scrollback = copy.scrollback.copy()
        self.scrollback_cap = copy.scrollback_cap
        self.view_offset = copy.view_offset
        self.mouse_track_press      = copy.mouse_track_press
        self.mouse_track_btn_motion = copy.mouse_track_btn_motion
        self.mouse_track_any_motion = copy.mouse_track_any_motion
        self.mouse_sgr              = copy.mouse_sgr
        self.app_cursor_keys        = copy.app_cursor_keys
        self.bracketed_paste        = copy.bracketed_paste
        self.focus_events           = copy.focus_events
        self.cursor_shape           = copy.cursor_shape
        self.reply_buf              = copy.reply_buf
        self._clipboard_pending     = copy._clipboard_pending

    # --- accessors -----------------------------------------------------

    fn cell_at(self, r: Int, c: Int) -> Cell:
        """Read the current cell at ``(r, c)``. Out-of-range returns
        a blank cell — defensive so a paint loop that miscalculates
        bounds doesn't index past the buffer."""
        if r < 0 or r >= self.rows or c < 0 or c >= self.cols:
            return blank_cell()
        var idx = self._idx(r, c)
        if self.using_alt:
            return self.alt[idx]
        return self.primary[idx]

    fn tail_rows(self, n: Int) -> List[String]:
        """Return the bottom ``n`` rows of the active grid as strings,
        one entry per row, trailing spaces trimmed off each row. Used
        by the Claude-state detector — it wants tail-of-output line
        view, not the 2D grid. With ``n > rows`` we return everything;
        with ``n <= 0`` we return an empty list."""
        var out = List[String]()
        if n <= 0:
            return out^
        var start = self.rows - n
        if start < 0: start = 0
        for r in range(start, self.rows):
            var bytes = List[UInt8]()
            for c in range(self.cols):
                var g = self.cell_at(r, c).glyph.as_bytes()
                for k in range(len(g)):
                    bytes.append(g[k])
            # Trim trailing spaces (each row is padded to full width).
            var end = len(bytes)
            while end > 0 and bytes[end - 1] == 0x20:
                end -= 1
            out.append(String(StringSlice(
                ptr=bytes.unsafe_ptr(), length=end,
            )))
        return out^

    fn view_cell_at(self, r: Int, c: Int) -> Cell:
        """Cell as seen by the user at view-row ``r``, accounting for
        ``view_offset``. When ``view_offset == 0`` this matches
        ``cell_at`` exactly. Otherwise rows are pulled from the top of
        scrollback first, then the live grid covers the remaining
        rows. Used by the pane for paint and selection extraction so
        the same data path serves both."""
        if r < 0 or r >= self.rows or c < 0 or c >= self.cols:
            return blank_cell()
        if self.view_offset <= 0:
            return self.cell_at(r, c)
        # On the alt screen we never expose scrollback — alt-screen
        # apps render their own world and the scrollback buffer
        # belongs to the shell behind them. Defensive: even if a caller
        # changed view_offset while alt is active, we still pull from
        # alt's live grid.
        if self.using_alt:
            return self.cell_at(r, c)
        var sb_len = len(self.scrollback)
        # Absolute row in the (scrollback ++ visible) timeline.
        var abs_row = (sb_len - self.view_offset) + r
        if abs_row < 0:
            return blank_cell()
        if abs_row < sb_len:
            # Index without copying — only the single Cell we return
            # needs to leave the function. ``UnsafePointer`` into the
            # nested list is overkill for one cell; ``copy()`` of the
            # inner row is one allocation we'd like to avoid, but Mojo
            # won't let us index a non-implicitly-copyable nested List
            # otherwise. ``len(self.scrollback)`` access is cheap and
            # we've bounds-checked above.
            var row = self.scrollback[abs_row].copy()
            if c >= len(row):
                return blank_cell()
            return row[c]
        return self.cell_at(abs_row - sb_len, c)

    fn scroll_view_by(mut self, delta: Int):
        """Shift the viewport by ``delta`` rows. Positive means "show
        older content" (mouse wheel up); negative is the inverse.
        Clamped at 0 (live tail) and ``len(scrollback)`` (top of
        history). No-op on the alt screen."""
        if self.using_alt:
            self.view_offset = 0
            return
        var max_off = len(self.scrollback)
        var new_off = self.view_offset + delta
        if new_off < 0: new_off = 0
        if new_off > max_off: new_off = max_off
        self.view_offset = new_off

    fn reset_view(mut self):
        """Snap back to the live tail. The pane calls this on
        keyboard input — typing into the shell while scrolled back
        almost always means the user wants to interact with the live
        prompt, not the historical view."""
        self.view_offset = 0

    fn tracks_mouse(self) -> Bool:
        """True when the child has enabled any form of mouse tracking
        (1000 / 1002 / 1003). The pane uses this to decide whether
        mouse events go to the child or to its own selection /
        scrollback handlers."""
        return self.mouse_track_press \
            or self.mouse_track_btn_motion \
            or self.mouse_track_any_motion

    fn take_reply(mut self) -> String:
        """Drain the outbound reply queue. The pane calls this each
        tick and writes the result to the pty master so DSR / DA1 /
        OSC replies actually reach the child. Returns the empty
        string when there's nothing pending."""
        var out = self.reply_buf
        self.reply_buf = String("")
        return out^

    fn take_clipboard(mut self) -> String:
        """Drain the pending OSC 52 clipboard write (already
        base64-decoded). The pane calls this each tick and forwards
        any non-empty payload to the system clipboard. Returns the
        empty string when there's nothing pending."""
        var out = self._clipboard_pending
        self._clipboard_pending = String("")
        return out^

    fn notify_focus_change(mut self, focused: Bool):
        """Tell the emulator the host gained / lost focus. When the
        child has enabled focus reporting (``?1004h``) this enqueues
        ``ESC[I`` (gained) or ``ESC[O`` (lost) on the reply queue.
        No-op otherwise."""
        if not self.focus_events:
            return
        if focused:
            self.reply_buf = self.reply_buf + String("\x1b[I")
        else:
            self.reply_buf = self.reply_buf + String("\x1b[O")

    fn encode_mouse(
        self,
        button: Int,
        col: Int, row: Int,
        motion: Bool,
        released: Bool,
        shift: Bool, meta: Bool, ctrl: Bool,
    ) -> String:
        """Encode a mouse event into the byte sequence the child
        expects on its stdin. ``button`` is 0=left, 1=middle, 2=right,
        4=wheel-up, 5=wheel-down — same values our ``Event`` uses.
        ``col`` / ``row`` are 0-based cell coordinates inside the
        emulator grid; the wire format is 1-based and we offset here
        so the caller can pass grid-local values directly.

        Encoding mirrors xterm:

        * Button low bits: 0/1/2 for L/M/R, 64/65 for wheel up/down.
        * +4/+8/+16 for Shift/Meta/Ctrl modifiers.
        * +32 marks a motion event (drag without a fresh press).
        * SGR form (``\\x1b[<Cb;X;YM/m``) when ``mouse_sgr`` is on —
          ``M`` for press, ``m`` for release. The SGR form survives
          columns > 223 and disambiguates release from press; legacy
          form can't and doesn't.
        * Legacy form (``\\x1b[M`` + 3 bytes of ``Cb+32, X+32, Y+32``)
          otherwise. Coordinates > 223 can't be represented and we
          drop the event rather than emit a malformed sequence.

        Returns an empty string when no tracking mode is enabled, or
        when the protocol can't express the coordinates."""
        if not self.tracks_mouse():
            return String("")
        var cb: Int
        if button == 4:        # wheel up
            cb = 64
        elif button == 5:      # wheel down
            cb = 65
        elif button == 0:      # left
            cb = 0
        elif button == 1:      # middle
            cb = 1
        elif button == 2:      # right
            cb = 2
        else:
            return String("")
        if motion:
            cb = cb + 32
        if shift: cb = cb + 4
        if meta:  cb = cb + 8
        if ctrl:  cb = cb + 16
        var x = col + 1
        var y = row + 1
        if self.mouse_sgr:
            var final = String("m") if released else String("M")
            return String("\x1b[<") + String(cb) + String(";") \
                + String(x) + String(";") + String(y) + final
        # Legacy: encode each value as one byte (value + 32). Caps at
        # 223 + 32 = 255; out-of-range becomes a no-op.
        if released:
            # Legacy uses button 3 for any release.
            cb = 3
            if shift: cb = cb + 4
            if meta:  cb = cb + 8
            if ctrl:  cb = cb + 16
            if motion: cb = cb + 32
        if x > 223 or y > 223 or cb > 223:
            return String("")
        var bytes = List[UInt8]()
        bytes.append(0x1B)
        bytes.append(0x5B)  # '['
        bytes.append(0x4D)  # 'M'
        bytes.append(UInt8(cb + 32))
        bytes.append(UInt8(x + 32))
        bytes.append(UInt8(y + 32))
        return String(StringSlice(
            ptr=bytes.unsafe_ptr(), length=len(bytes),
        ))

    fn take_bell(mut self) -> Bool:
        """Consume the latched-bell flag. Returns True iff a BEL
        arrived since the last call. The pane uses this to flash a
        visual indicator without echoing a beep to its own host
        terminal."""
        var b = self.bell_pending
        self.bell_pending = False
        return b

    fn _idx(self, r: Int, c: Int) -> Int:
        return r * self.cols + c

    fn _row_start(self, r: Int) -> Int:
        return r * self.cols

    fn _grid_ref_set(mut self, idx: Int, cell: Cell):
        """Write into whichever grid is currently in use. Pulling
        this out of the call sites keeps the alt-screen dispatch
        in one place — no caller has to remember to branch."""
        if self.using_alt:
            self.alt[idx] = cell
        else:
            self.primary[idx] = cell

    # --- resize --------------------------------------------------------

    fn resize(mut self, cols: Int, rows: Int):
        """Resize to ``cols`` × ``rows``. Existing content is
        preserved where it still fits (top-left anchored); new
        cells are blank. The cursor is clamped to the new bounds.

        We deliberately don't re-flow soft-wrapped lines — terminal
        protocols don't carry "was this row wrapped from the
        previous" metadata, so any re-flow would be a guess. Real
        clients all repaint on SIGWINCH anyway."""
        if cols <= 0 or rows <= 0: return
        if cols == self.cols and rows == self.rows: return
        var new_primary = _make_grid(cols, rows)
        var new_alt     = _make_grid(cols, rows)
        var keep_rows = rows if rows < self.rows else self.rows
        var keep_cols = cols if cols < self.cols else self.cols
        for r in range(keep_rows):
            for c in range(keep_cols):
                new_primary[r * cols + c] = self.primary[r * self.cols + c]
                new_alt[r * cols + c]     = self.alt[r * self.cols + c]
        self.primary = new_primary^
        self.alt     = new_alt^
        self.cols    = cols
        self.rows    = rows
        if self.cur_r >= rows: self.cur_r = rows - 1
        if self.cur_c >= cols: self.cur_c = cols - 1
        # Scroll region rebases to full screen on resize — that's
        # what vt100 does, and any program that cares re-issues
        # DECSTBM after seeing SIGWINCH.
        self.scroll_top = 0
        self.scroll_bot = rows - 1
        self.wrap_pending = False
        # Snap scrollback view back to live. The user's view-offset is
        # in terms of rows; with the row count changed, the offset no
        # longer means what it did. Snapping is the simplest correct
        # behavior — real clients SIGWINCH-repaint anyway, so the user
        # gets a fresh frame either way.
        self.view_offset = 0

    # --- input feed ----------------------------------------------------

    fn feed(mut self, data: Span[UInt8, _]):
        """Consume ``data`` and advance internal state. The pane calls
        this once per drain — typically with whatever ``read(2)`` got
        off the master fd this tick."""
        var n = len(data)
        var i = 0
        while i < n:
            var b = Int(data[i])
            self._step(UInt8(b))
            i += 1

    fn feed_string(mut self, s: String):
        """Convenience for tests / callers with String-shaped data.
        Internally we operate on bytes."""
        var b = s.as_bytes()
        self.feed(b)

    # --- inner step ----------------------------------------------------

    fn _step(mut self, b: UInt8):
        var v = Int(b)
        if self._state == _S_GROUND:
            self._step_ground(v)
            return
        if self._state == _S_ESC:
            self._step_esc(v)
            return
        if self._state == _S_CSI:
            self._step_csi(v)
            return
        if self._state == _S_OSC:
            self._step_osc(v)
            return
        if self._state == _S_OSC_ESC:
            self._step_osc_esc(v)
            return
        if self._state == _S_UTF8:
            self._step_utf8(v)
            return
        if self._state == _S_ESC_CHARSET:
            # Whatever this byte is, the designator is now consumed.
            self._state = _S_GROUND
            return

    fn _step_ground(mut self, b: Int):
        # Control characters first.
        if b == 0x1B:  # ESC
            self._enter_esc()
            return
        if b == 0x07:  # BEL
            self.bell_pending = True
            return
        if b == 0x08:  # BS
            if self.cur_c > 0:
                self.cur_c -= 1
            self.wrap_pending = False
            return
        if b == 0x09:  # HT — advance to next column-multiple-of-8.
            var next_c = (self.cur_c // 8) * 8 + 8
            if next_c >= self.cols:
                next_c = self.cols - 1
            self.cur_c = next_c
            self.wrap_pending = False
            return
        if b == 0x0A or b == 0x0B or b == 0x0C:  # LF / VT / FF
            self._line_feed()
            self.wrap_pending = False
            return
        if b == 0x0D:  # CR
            self.cur_c = 0
            self.wrap_pending = False
            return
        if b < 0x20:
            # Other C0 controls — silently drop. Includes SO (0x0E),
            # SI (0x0F) which we'd want for G1 charset switching;
            # we don't implement charsets, so dropping is fine for
            # English content.
            return
        if b == 0x7F:
            # DEL — explicitly a no-op in terminals.
            return
        # Printable byte. Could be ASCII or the leading byte of a
        # multi-byte UTF-8 sequence.
        if b < 0x80:
            var one = List[UInt8]()
            one.append(UInt8(b))
            self._print_glyph(String(StringSlice(
                ptr=one.unsafe_ptr(), length=1,
            )))
            return
        # UTF-8 leading byte → enter UTF-8 collection.
        var remaining: Int
        if (b & 0xE0) == 0xC0:
            remaining = 1
        elif (b & 0xF0) == 0xE0:
            remaining = 2
        elif (b & 0xF8) == 0xF0:
            remaining = 3
        else:
            # Invalid leading byte — paint a replacement char.
            self._print_glyph(String("?"))
            return
        self._utf8_buf = List[UInt8]()
        self._utf8_buf.append(UInt8(b))
        self._utf8_remaining = remaining
        self._state = _S_UTF8

    fn _step_utf8(mut self, b: Int):
        if (b & 0xC0) != 0x80:
            # Invalid continuation — abort, paint replacement, then
            # re-feed the offending byte from GROUND.
            self._state = _S_GROUND
            self._print_glyph(String("?"))
            self._step(UInt8(b))
            return
        self._utf8_buf.append(UInt8(b))
        self._utf8_remaining -= 1
        if self._utf8_remaining > 0:
            return
        # Complete — assemble the glyph.
        var glyph = String(StringSlice(
            ptr=self._utf8_buf.unsafe_ptr(),
            length=len(self._utf8_buf),
        ))
        self._state = _S_GROUND
        self._print_glyph(glyph)

    fn _print_glyph(mut self, glyph: String):
        # Delayed-wrap: if the previous print filled the last column
        # and auto-wrap is on, advance to the next row now.
        if self.wrap_pending and self.auto_wrap:
            self.cur_c = 0
            self._cursor_down_or_scroll()
            self.wrap_pending = False
        if self.cur_c >= self.cols:
            # Clamp — should be rare since wrap_pending handles the
            # normal case, but defensive against direct CUF past EOL.
            self.cur_c = self.cols - 1
        var idx = self._idx(self.cur_r, self.cur_c)
        self._grid_ref_set(idx, Cell(glyph, self.current_attr, 1))
        if self.cur_c == self.cols - 1:
            self.wrap_pending = True
        else:
            self.cur_c += 1

    fn _line_feed(mut self):
        """LF behavior: move down one row, scrolling if the cursor is
        at the bottom of the scroll region. Outside the scroll region,
        LF at the very bottom of the screen also scrolls (matches
        xterm)."""
        if self.cur_r == self.scroll_bot:
            self._scroll_up_in_region(1)
            return
        if self.cur_r < self.rows - 1:
            self.cur_r += 1

    fn _cursor_down_or_scroll(mut self):
        # Used by auto-wrap. Same semantics as LF.
        self._line_feed()

    fn _scroll_up_in_region(mut self, n: Int):
        """Shift rows in ``[scroll_top, scroll_bot]`` up by ``n``,
        filling the bottom with blanks at the current attr's bg.

        When the scroll covers the very top of the primary grid (the
        only case the user thinks of as "the line scrolled out of
        view"), the displaced rows are snapshotted into ``scrollback``
        first. Alt-screen scrolls don't push history — apps that use
        the alt screen own their own viewport and would be confused if
        we kept their transient frames in the buffer that the shell
        owns."""
        if n <= 0: return
        var top = self.scroll_top
        var bot = self.scroll_bot
        if top < 0: top = 0
        if bot >= self.rows: bot = self.rows - 1
        if top > bot: return
        var height = bot - top + 1
        var shift = n if n < height else height
        # Push the rows about to be discarded into scrollback (primary
        # screen only, and only when the scroll origin is the very top
        # — a mid-screen scroll region is a curses-style frame, not
        # output history).
        if not self.using_alt and top == 0:
            for r in range(shift):
                var row_cells = List[Cell]()
                for c in range(self.cols):
                    row_cells.append(self.primary[self._idx(r, c)])
                self.scrollback.append(row_cells^)
            # Trim the front to maintain the cap. ``pop(0)`` is O(n)
            # in List size but at our cap (1000) and event rate this
            # is well under the per-frame budget.
            while len(self.scrollback) > self.scrollback_cap:
                _ = self.scrollback.pop(0)
            # If the user is currently scrolled back, keep their view
            # pinned to the same absolute scrollback position by
            # bumping the offset along with the new content. Without
            # this, every fresh output line during a scrollback review
            # would make the user's view "drift forward" toward the
            # live tail — which is exactly what most terminals (xterm,
            # iTerm, alacritty) avoid.
            if self.view_offset > 0:
                self.view_offset += shift
                var max_off = len(self.scrollback)
                if self.view_offset > max_off:
                    self.view_offset = max_off
        for r in range(top, bot + 1 - shift):
            for c in range(self.cols):
                var src = self._idx(r + shift, c)
                var dst = self._idx(r, c)
                if self.using_alt:
                    self.alt[dst] = self.alt[src]
                else:
                    self.primary[dst] = self.primary[src]
        var blank = Cell(String(" "), self.current_attr, 1)
        for r in range(bot + 1 - shift, bot + 1):
            for c in range(self.cols):
                self._grid_ref_set(self._idx(r, c), blank)

    fn _scroll_down_in_region(mut self, n: Int):
        """Shift rows in ``[scroll_top, scroll_bot]`` down by ``n``,
        filling the top with blanks. Used by RI (reverse index)."""
        if n <= 0: return
        var top = self.scroll_top
        var bot = self.scroll_bot
        if top < 0: top = 0
        if bot >= self.rows: bot = self.rows - 1
        if top > bot: return
        var height = bot - top + 1
        var shift = n if n < height else height
        var r = bot
        while r >= top + shift:
            for c in range(self.cols):
                var src = self._idx(r - shift, c)
                var dst = self._idx(r, c)
                if self.using_alt:
                    self.alt[dst] = self.alt[src]
                else:
                    self.primary[dst] = self.primary[src]
            r -= 1
        var blank = Cell(String(" "), self.current_attr, 1)
        for r2 in range(top, top + shift):
            for c in range(self.cols):
                self._grid_ref_set(self._idx(r2, c), blank)

    # --- ESC dispatch --------------------------------------------------

    fn _enter_esc(mut self):
        self._state = _S_ESC

    fn _step_esc(mut self, b: Int):
        if b == 0x5B:  # '[' — CSI
            self._csi_params = List[Int]()
            self._csi_current = 0
            self._csi_has_digit = False
            self._csi_private = 0
            self._csi_intermediate = 0
            self._state = _S_CSI
            return
        if b == 0x5D:  # ']' — OSC
            self._osc_buf = String("")
            self._state = _S_OSC
            return
        if b == 0x50:  # 'P' — DCS, ignored. Skip until ST.
            # Easiest implementation: enter OSC state with an empty
            # buf so any string terminator drops us back to GROUND;
            # we just discard everything in between. The OSC parser
            # already handles BEL/ST exit.
            self._osc_buf = String("")
            self._state = _S_OSC
            return
        # Single-char ESC dispatches.
        if b == 0x37:  # '7' — DECSC
            self._save_cursor()
            self._state = _S_GROUND
            return
        if b == 0x38:  # '8' — DECRC
            self._restore_cursor()
            self._state = _S_GROUND
            return
        if b == 0x44:  # 'D' — IND (index)
            self._line_feed()
            self._state = _S_GROUND
            return
        if b == 0x45:  # 'E' — NEL (next line)
            self.cur_c = 0
            self._line_feed()
            self._state = _S_GROUND
            return
        if b == 0x4D:  # 'M' — RI (reverse index)
            if self.cur_r == self.scroll_top:
                self._scroll_down_in_region(1)
            elif self.cur_r > 0:
                self.cur_r -= 1
            self._state = _S_GROUND
            return
        if b == 0x63:  # 'c' — RIS (full reset)
            self._reset()
            self._state = _S_GROUND
            return
        if b == 0x3D or b == 0x3E:
            # ``=`` / ``>`` — DECKPAM / DECKPNM (application /
            # numeric keypad). We don't differentiate keypad modes
            # yet; just consume so the byte isn't painted.
            self._state = _S_GROUND
            return
        # Unhandled — drop back to GROUND. Includes charset
        # designators (``ESC ( B`` etc.) which would otherwise be
        # painted as garbage characters.
        if b == 0x28 or b == 0x29 or b == 0x2A or b == 0x2B:
            # G0/G1 charset designator — consume the next byte too
            # so we don't paint it. We don't track which charset
            # is active; ASCII passthrough is fine for english
            # content and UTF-8 wins over G1 anyway.
            self._state = _S_ESC_CHARSET
            return
        self._state = _S_GROUND

    # --- CSI dispatch --------------------------------------------------

    fn _step_csi(mut self, b: Int):
        # Parameter bytes: digits and ';'.
        if b >= 0x30 and b <= 0x39:  # '0'..'9'
            self._csi_current = self._csi_current * 10 + (b - 0x30)
            self._csi_has_digit = True
            return
        if b == 0x3B:  # ';'
            self._csi_params.append(self._csi_current)
            self._csi_current = 0
            self._csi_has_digit = False
            return
        if b == 0x3A:  # ':' — sub-parameter separator (we coarsen to ';')
            self._csi_params.append(self._csi_current)
            self._csi_current = 0
            self._csi_has_digit = False
            return
        if b == 0x3F or b == 0x3E or b == 0x3D:
            # Private parameter prefix — only valid as first param byte
            # but xterm tolerates anywhere; we just remember it.
            self._csi_private = UInt8(b)
            return
        if b == 0x20 or b == 0x21 or b == 0x22 or b == 0x23 \
                or b == 0x24 or b == 0x25 or b == 0x26 or b == 0x27 \
                or b == 0x28 or b == 0x29 or b == 0x2A or b == 0x2B \
                or b == 0x2C or b == 0x2D or b == 0x2E or b == 0x2F:
            # Intermediate bytes — last one wins (matches xterm).
            # Stored so DECSCUSR (``CSI Ps SP q``) can recognize the
            # 0x20 prefix at dispatch.
            self._csi_intermediate = UInt8(b)
            return
        # Final byte (0x40..0x7E) — dispatch.
        if b >= 0x40 and b <= 0x7E:
            # Flush the in-progress parameter (the last one before
            # the final byte). Even if it had no digits we push 0
            # so the dispatch table sees a deterministic param count.
            if self._csi_has_digit or len(self._csi_params) > 0:
                self._csi_params.append(self._csi_current)
            self._dispatch_csi(b)
            self._state = _S_GROUND
            return
        # Anything else aborts the sequence.
        self._state = _S_GROUND

    fn _param(self, i: Int, default: Int) -> Int:
        """Read the i-th param, falling back to ``default`` when the
        param is missing (off the end of the list) or zero. ``0``
        meaning "default" is a vt100 convention used by most CSI
        commands."""
        if i >= len(self._csi_params):
            return default
        var v = self._csi_params[i]
        if v == 0:
            return default
        return v

    fn _param_raw(self, i: Int, default: Int) -> Int:
        """Read i-th param literally; missing → default but a
        present 0 stays 0. SGR uses this (0 is "reset"); ED/EL use
        it because their "0" sub-action differs from the absent
        case. Actually for ED/EL absent IS 0, so this is mostly
        for SGR."""
        if i >= len(self._csi_params):
            return default
        return self._csi_params[i]

    fn _dispatch_csi(mut self, final_byte: Int):
        # Private-mode dispatches use a separate table because the
        # parameters are mode numbers, not coords.
        if self._csi_private == 0x3F:  # '?'
            if final_byte == 0x68:  # 'h' — DECSET
                self._dec_set(True)
                return
            if final_byte == 0x6C:  # 'l' — DECRESET
                self._dec_set(False)
                return
            # Other private finals (e.g. ``?p`` for DECRQSS responses)
            # we silently drop. Children that probe and get no reply
            # fall back to defaults.
            return
        # Public CSI finals.
        if final_byte == 0x40:  # '@' — ICH (insert blanks)
            self._ich(self._param(0, 1))
            return
        if final_byte == 0x41:  # 'A' — CUU
            self.cur_r -= self._param(0, 1)
            if self.cur_r < self.scroll_top: self.cur_r = self.scroll_top
            if self.cur_r < 0: self.cur_r = 0
            self.wrap_pending = False
            return
        if final_byte == 0x42:  # 'B' — CUD
            self.cur_r += self._param(0, 1)
            if self.cur_r > self.scroll_bot: self.cur_r = self.scroll_bot
            if self.cur_r >= self.rows: self.cur_r = self.rows - 1
            self.wrap_pending = False
            return
        if final_byte == 0x43:  # 'C' — CUF
            self.cur_c += self._param(0, 1)
            if self.cur_c >= self.cols: self.cur_c = self.cols - 1
            self.wrap_pending = False
            return
        if final_byte == 0x44:  # 'D' — CUB
            self.cur_c -= self._param(0, 1)
            if self.cur_c < 0: self.cur_c = 0
            self.wrap_pending = False
            return
        if final_byte == 0x45:  # 'E' — CNL (cursor next line)
            self.cur_r += self._param(0, 1)
            if self.cur_r > self.scroll_bot: self.cur_r = self.scroll_bot
            if self.cur_r >= self.rows: self.cur_r = self.rows - 1
            self.cur_c = 0
            self.wrap_pending = False
            return
        if final_byte == 0x46:  # 'F' — CPL (cursor previous line)
            self.cur_r -= self._param(0, 1)
            if self.cur_r < self.scroll_top: self.cur_r = self.scroll_top
            if self.cur_r < 0: self.cur_r = 0
            self.cur_c = 0
            self.wrap_pending = False
            return
        if final_byte == 0x47:  # 'G' — CHA (column absolute)
            self.cur_c = self._param(0, 1) - 1
            if self.cur_c < 0: self.cur_c = 0
            if self.cur_c >= self.cols: self.cur_c = self.cols - 1
            self.wrap_pending = False
            return
        if final_byte == 0x48 or final_byte == 0x66:  # 'H' / 'f' — CUP
            self.cur_r = self._param(0, 1) - 1
            self.cur_c = self._param(1, 1) - 1
            if self.cur_r < 0: self.cur_r = 0
            if self.cur_r >= self.rows: self.cur_r = self.rows - 1
            if self.cur_c < 0: self.cur_c = 0
            if self.cur_c >= self.cols: self.cur_c = self.cols - 1
            self.wrap_pending = False
            return
        if final_byte == 0x4A:  # 'J' — ED
            self._erase_in_display(self._param_raw(0, 0))
            return
        if final_byte == 0x4B:  # 'K' — EL
            self._erase_in_line(self._param_raw(0, 0))
            return
        if final_byte == 0x4C:  # 'L' — IL (insert lines)
            self._il(self._param(0, 1))
            return
        if final_byte == 0x4D:  # 'M' — DL (delete lines)
            self._dl(self._param(0, 1))
            return
        if final_byte == 0x50:  # 'P' — DCH (delete chars)
            self._dch(self._param(0, 1))
            return
        if final_byte == 0x53:  # 'S' — SU (scroll up)
            self._scroll_up_in_region(self._param(0, 1))
            return
        if final_byte == 0x54:  # 'T' — SD (scroll down)
            self._scroll_down_in_region(self._param(0, 1))
            return
        if final_byte == 0x58:  # 'X' — ECH (erase chars)
            self._ech(self._param(0, 1))
            return
        if final_byte == 0x64:  # 'd' — VPA (row absolute)
            self.cur_r = self._param(0, 1) - 1
            if self.cur_r < 0: self.cur_r = 0
            if self.cur_r >= self.rows: self.cur_r = self.rows - 1
            self.wrap_pending = False
            return
        if final_byte == 0x6D:  # 'm' — SGR
            self._sgr()
            return
        if final_byte == 0x72:  # 'r' — DECSTBM
            self._set_scroll_region()
            return
        if final_byte == 0x73:  # 's' — save cursor (xterm extension)
            self._save_cursor()
            return
        if final_byte == 0x75:  # 'u' — restore cursor
            self._restore_cursor()
            return
        if final_byte == 0x63:  # 'c' — DA1 (primary device attributes)
            # Answer with "VT102" — the same canned reply xterm sends
            # by default. Apps that probe for capabilities (terminfo
            # detection, oh-my-zsh / starship init) treat any reply
            # here as "this is a real terminal, proceed."
            self.reply_buf = self.reply_buf + String("\x1b[?6c")
            return
        if final_byte == 0x6E:  # 'n' — DSR
            var which = self._param_raw(0, 0)
            if which == 5:
                # "Status report" — reply "OK".
                self.reply_buf = self.reply_buf + String("\x1b[0n")
            elif which == 6:
                # Cursor Position Report — 1-based row;col.
                var r1 = self.cur_r + 1
                var c1 = self.cur_c + 1
                self.reply_buf = self.reply_buf \
                    + String("\x1b[") + String(r1) \
                    + String(";") + String(c1) + String("R")
            return
        if final_byte == 0x71 and self._csi_intermediate == 0x20:
            # DECSCUSR (``CSI Ps SP q``) — cursor shape.
            # 0 / 1 / 2: block; 3 / 4: underline; 5 / 6: bar.
            # We store the raw param; the pane caret already renders
            # as a reverse-video block, so the visual difference
            # between shapes is left for a future painter pass — but
            # tracking the state means apps that probe (``DECRQM 25``)
            # see a coherent terminal.
            var ps = self._param_raw(0, 0)
            if ps < 0: ps = 0
            if ps > 6: ps = 0
            self.cursor_shape = UInt8(ps)
            return
        # Unhandled — drop silently.

    # --- erase ---------------------------------------------------------

    fn _erase_in_display(mut self, mode: Int):
        var blank = Cell(String(" "), self.current_attr, 1)
        if mode == 0:
            # Cursor to end of screen.
            for c in range(self.cur_c, self.cols):
                self._grid_ref_set(self._idx(self.cur_r, c), blank)
            for r in range(self.cur_r + 1, self.rows):
                for c in range(self.cols):
                    self._grid_ref_set(self._idx(r, c), blank)
            return
        if mode == 1:
            # Start of screen to cursor.
            for r in range(self.cur_r):
                for c in range(self.cols):
                    self._grid_ref_set(self._idx(r, c), blank)
            for c in range(self.cur_c + 1):
                self._grid_ref_set(self._idx(self.cur_r, c), blank)
            return
        if mode == 2 or mode == 3:
            # 2: entire screen. 3: scrollback — we have none, treat
            # same as 2. Cursor doesn't move.
            for r in range(self.rows):
                for c in range(self.cols):
                    self._grid_ref_set(self._idx(r, c), blank)

    fn _erase_in_line(mut self, mode: Int):
        var blank = Cell(String(" "), self.current_attr, 1)
        if mode == 0:
            for c in range(self.cur_c, self.cols):
                self._grid_ref_set(self._idx(self.cur_r, c), blank)
            return
        if mode == 1:
            for c in range(self.cur_c + 1):
                self._grid_ref_set(self._idx(self.cur_r, c), blank)
            return
        if mode == 2:
            for c in range(self.cols):
                self._grid_ref_set(self._idx(self.cur_r, c), blank)

    fn _ich(mut self, n: Int):
        """Insert ``n`` blanks at cursor, shifting the rest of the
        line right. Cells past the right edge fall off."""
        if n <= 0: return
        var shift = n if n < (self.cols - self.cur_c) else (self.cols - self.cur_c)
        var c = self.cols - 1
        while c >= self.cur_c + shift:
            var src = self._idx(self.cur_r, c - shift)
            var dst = self._idx(self.cur_r, c)
            if self.using_alt:
                self.alt[dst] = self.alt[src]
            else:
                self.primary[dst] = self.primary[src]
            c -= 1
        var blank = Cell(String(" "), self.current_attr, 1)
        for c2 in range(self.cur_c, self.cur_c + shift):
            self._grid_ref_set(self._idx(self.cur_r, c2), blank)

    fn _dch(mut self, n: Int):
        """Delete ``n`` chars at cursor; rest of the line shifts
        left, right edge backfills with blanks."""
        if n <= 0: return
        var shift = n if n < (self.cols - self.cur_c) else (self.cols - self.cur_c)
        for c in range(self.cur_c, self.cols - shift):
            var src = self._idx(self.cur_r, c + shift)
            var dst = self._idx(self.cur_r, c)
            if self.using_alt:
                self.alt[dst] = self.alt[src]
            else:
                self.primary[dst] = self.primary[src]
        var blank = Cell(String(" "), self.current_attr, 1)
        for c2 in range(self.cols - shift, self.cols):
            self._grid_ref_set(self._idx(self.cur_r, c2), blank)

    fn _ech(mut self, n: Int):
        """Erase ``n`` chars at cursor — doesn't shift, just blanks."""
        if n <= 0: return
        var end = self.cur_c + n
        if end > self.cols: end = self.cols
        var blank = Cell(String(" "), self.current_attr, 1)
        for c in range(self.cur_c, end):
            self._grid_ref_set(self._idx(self.cur_r, c), blank)

    fn _il(mut self, n: Int):
        """Insert ``n`` blank lines at cursor row, within the scroll
        region. Lines below shift down; lines pushed past
        ``scroll_bot`` are lost."""
        if self.cur_r < self.scroll_top or self.cur_r > self.scroll_bot:
            return
        if n <= 0: return
        var saved_top = self.scroll_top
        self.scroll_top = self.cur_r
        self._scroll_down_in_region(n)
        self.scroll_top = saved_top

    fn _dl(mut self, n: Int):
        """Delete ``n`` lines at cursor row, within the scroll region.
        Lines below shift up; bottom backfills with blanks."""
        if self.cur_r < self.scroll_top or self.cur_r > self.scroll_bot:
            return
        if n <= 0: return
        var saved_top = self.scroll_top
        self.scroll_top = self.cur_r
        self._scroll_up_in_region(n)
        self.scroll_top = saved_top

    # --- scroll region -------------------------------------------------

    fn _set_scroll_region(mut self):
        var top = self._param(0, 1) - 1
        var bot = self._param(1, self.rows) - 1
        if top < 0: top = 0
        if bot >= self.rows: bot = self.rows - 1
        if top >= bot:
            # Invalid region — vt100 says reset to full screen.
            top = 0
            bot = self.rows - 1
        self.scroll_top = top
        self.scroll_bot = bot
        # DECSTBM resets cursor to home (within region, but origin
        # mode is off so home is screen 0,0).
        self.cur_r = 0
        self.cur_c = 0
        self.wrap_pending = False

    # --- save / restore cursor -----------------------------------------

    fn _save_cursor(mut self):
        self.saved_cur_r = self.cur_r
        self.saved_cur_c = self.cur_c
        self.saved_attr  = self.current_attr

    fn _restore_cursor(mut self):
        self.cur_r = self.saved_cur_r
        self.cur_c = self.saved_cur_c
        self.current_attr = self.saved_attr
        if self.cur_r >= self.rows: self.cur_r = self.rows - 1
        if self.cur_c >= self.cols: self.cur_c = self.cols - 1
        self.wrap_pending = False

    # --- SGR -----------------------------------------------------------

    fn _sgr(mut self):
        # ``ESC [ m`` with no params is the same as ``ESC [ 0 m`` — reset.
        if len(self._csi_params) == 0:
            self.current_attr = Attr()
            return
        var a = self.current_attr
        var i = 0
        while i < len(self._csi_params):
            var p = self._csi_params[i]
            if p == 0:
                a = Attr()
            elif p == 1:
                a.style = a.style | STYLE_BOLD
            elif p == 2:
                a.style = a.style | STYLE_DIM
            elif p == 3:
                a.style = a.style | STYLE_ITALIC
            elif p == 4:
                a.style = a.style | STYLE_UNDERLINE
            elif p == 7:
                a.style = a.style | STYLE_REVERSE
            elif p == 9:
                a.style = a.style | STYLE_STRIKE
            elif p == 22:
                a.style = a.style & ~(STYLE_BOLD | STYLE_DIM)
            elif p == 23:
                a.style = a.style & ~STYLE_ITALIC
            elif p == 24:
                a.style = a.style & ~STYLE_UNDERLINE
            elif p == 27:
                a.style = a.style & ~STYLE_REVERSE
            elif p == 29:
                a.style = a.style & ~STYLE_STRIKE
            elif p >= 30 and p <= 37:
                a.fg = _ansi_color(p - 30)
            elif p == 38:
                # Extended fg color: 38;5;N (256) or 38;2;R;G;B (truecolor).
                # We collapse truecolor → nearest 256-color slot, but for
                # now just consume the params and use 256-mode index when
                # available.
                if i + 2 < len(self._csi_params) and self._csi_params[i + 1] == 5:
                    a.fg = UInt8(self._csi_params[i + 2] & 0xFF)
                    i += 2
                elif i + 4 < len(self._csi_params) and self._csi_params[i + 1] == 2:
                    a.fg = _rgb_to_256(
                        self._csi_params[i + 2],
                        self._csi_params[i + 3],
                        self._csi_params[i + 4],
                    )
                    i += 4
            elif p == 39:
                a.fg = Attr().fg
            elif p >= 40 and p <= 47:
                a.bg = _ansi_color(p - 40)
            elif p == 48:
                if i + 2 < len(self._csi_params) and self._csi_params[i + 1] == 5:
                    a.bg = UInt8(self._csi_params[i + 2] & 0xFF)
                    i += 2
                elif i + 4 < len(self._csi_params) and self._csi_params[i + 1] == 2:
                    a.bg = _rgb_to_256(
                        self._csi_params[i + 2],
                        self._csi_params[i + 3],
                        self._csi_params[i + 4],
                    )
                    i += 4
            elif p == 49:
                a.bg = Attr().bg
            elif p >= 90 and p <= 97:
                a.fg = _ansi_color(p - 90 + 8)
            elif p >= 100 and p <= 107:
                a.bg = _ansi_color(p - 100 + 8)
            i += 1
        self.current_attr = a

    # --- DEC private modes ---------------------------------------------

    fn _dec_set(mut self, on: Bool):
        for i in range(len(self._csi_params)):
            var m = self._csi_params[i]
            if m == 1:
                self.app_cursor_keys = on
            elif m == 7:
                self.auto_wrap = on
            elif m == 25:
                self.cursor_visible = on
            elif m == 1000:
                self.mouse_track_press = on
            elif m == 1002:
                self.mouse_track_btn_motion = on
            elif m == 1003:
                self.mouse_track_any_motion = on
            elif m == 1004:
                self.focus_events = on
            elif m == 1006:
                self.mouse_sgr = on
            elif m == 1049:
                self._toggle_alt_screen(on)
                # Snap view to live on alt-screen switch — alt-screen
                # apps want a fresh viewport, and scrolled-back state
                # would confuse their (re)paint.
                if on: self.view_offset = 0
            elif m == 2004:
                self.bracketed_paste = on
            # All other modes (DECOM origin mode, ?12 cursor blink, …)
            # accepted-but-ignored. Children can probe with impunity;
            # we just don't act on them yet.

    fn _toggle_alt_screen(mut self, on: Bool):
        if on:
            if self.using_alt: return
            self._save_cursor()
            self.using_alt = True
            # Alt screen always starts blank — matches xterm.
            self.alt = _make_grid(self.cols, self.rows)
            self.cur_r = 0
            self.cur_c = 0
            self.wrap_pending = False
        else:
            if not self.using_alt: return
            self.using_alt = False
            self._restore_cursor()

    # --- OSC -----------------------------------------------------------

    fn _step_osc(mut self, b: Int):
        if b == 0x07:  # BEL — string terminator
            self._dispatch_osc()
            self._state = _S_GROUND
            return
        if b == 0x1B:  # ESC — maybe ST follows
            self._state = _S_OSC_ESC
            return
        # Accept the byte verbatim. We accumulate as raw bytes via the
        # StringSlice trick; for an OSC title the byte stream is
        # well-formed UTF-8 in practice.
        var tmp = List[UInt8]()
        tmp.append(UInt8(b))
        self._osc_buf = self._osc_buf + String(StringSlice(
            ptr=tmp.unsafe_ptr(), length=1,
        ))

    fn _step_osc_esc(mut self, b: Int):
        if b == 0x5C:  # '\\' — String Terminator
            self._dispatch_osc()
            self._state = _S_GROUND
            return
        # Not ST — abort the OSC, push the ESC back into the parser
        # so any meaningful sequence starting at this byte still runs.
        self._dispatch_osc()
        self._state = _S_GROUND
        self._step(UInt8(0x1B))
        self._step(UInt8(b))

    fn _dispatch_osc(mut self):
        # OSC body is ``<num>;<text>``. We honor 0/1/2 (title) and
        # 52 (clipboard); the rest get silently dropped so children
        # probing for capabilities (palette set, hyperlink, …) don't
        # see an error.
        var b = self._osc_buf.as_bytes()
        var n = len(b)
        var sep = -1
        var i = 0
        while i < n:
            if b[i] == 0x3B:  # ';'
                sep = i
                break
            i += 1
        if sep < 0:
            return
        # Extract param prefix as int.
        var param = 0
        for j in range(sep):
            var c = Int(b[j])
            if c < 0x30 or c > 0x39:
                return
            param = param * 10 + (c - 0x30)
        if param == 0 or param == 1 or param == 2:
            var t_start = sep + 1
            self.title = String(StringSlice(
                ptr=b.unsafe_ptr() + t_start, length=n - t_start,
            ))
            return
        if param == 52:
            # OSC 52: ``52;<targets>;<base64>``. Targets are c/p/s
            # for clipboard / primary / select; we don't distinguish
            # and route everything to the system clipboard. A ``?``
            # in place of base64 is a *query*, which we don't answer
            # (would leak clipboard contents to the child) — just
            # drop. ``-`` (empty base64) means "clear clipboard"; we
            # treat it as a no-op for the same reason.
            var t_start = sep + 1
            if t_start >= n:
                return
            # Find the second ``;`` separating targets from payload.
            var sep2 = -1
            var k = t_start
            while k < n:
                if b[k] == 0x3B:
                    sep2 = k
                    break
                k += 1
            if sep2 < 0:
                return
            var p_start = sep2 + 1
            if p_start >= n:
                return
            # First payload byte ``?`` is a query — skip.
            if b[p_start] == 0x3F:  # '?'
                return
            var payload = String(StringSlice(
                ptr=b.unsafe_ptr() + p_start, length=n - p_start,
            ))
            var decoded = _b64_decode(payload^)
            if len(decoded.as_bytes()) > 0:
                # Defer the actual clipboard write to the pane — the
                # emulator is pure-data and shouldn't touch system
                # state directly. Stash the most recent payload; the
                # pane drains it via ``take_clipboard``.
                self._clipboard_pending = decoded^

    # --- reset / charset stub ------------------------------------------

    fn _reset(mut self):
        self.primary    = _make_grid(self.cols, self.rows)
        self.alt        = _make_grid(self.cols, self.rows)
        self.using_alt  = False
        self.cur_r      = 0
        self.cur_c      = 0
        self.saved_cur_r = 0
        self.saved_cur_c = 0
        self.saved_attr = Attr()
        self.current_attr = Attr()
        self.scroll_top = 0
        self.scroll_bot = self.rows - 1
        self.auto_wrap  = True
        self.wrap_pending = False
        self.cursor_visible = True
        self.title      = String("")
        self.bell_pending = False
        # RIS is a hard reset — also drop the mode flags any previous
        # child enabled. Otherwise a fresh shell coming up after a
        # ``vim`` crash would inherit alt-screen mouse tracking /
        # bracketed paste and route events to the wrong handler.
        self.mouse_track_press = False
        self.mouse_track_btn_motion = False
        self.mouse_track_any_motion = False
        self.mouse_sgr = False
        self.app_cursor_keys = False
        self.bracketed_paste = False
        self.focus_events = False
        self.cursor_shape = 0


# --- helpers --------------------------------------------------------------


fn _make_grid(cols: Int, rows: Int) -> List[Cell]:
    var g = List[Cell]()
    var blank = blank_cell()
    for _ in range(cols * rows):
        g.append(blank)
    return g^


fn _rgb_to_256(r: Int, g: Int, b: Int) -> UInt8:
    """Collapse 24-bit RGB to the nearest 256-color palette index.
    Used by ``SGR 38;2;…`` / ``48;2;…`` when truecolor is sent but
    we only store an 8-bit palette index. Standard xterm formula:
    the 6×6×6 color cube lives at indices 16..231; we map each
    channel to a 0..5 cell index using the boundaries (0, 95, 135,
    175, 215, 255)."""
    return UInt8(16 + 36 * _rgb_step(r) + 6 * _rgb_step(g) + _rgb_step(b))


fn _rgb_step(v: Int) -> Int:
    if v < 48: return 0
    if v < 115: return 1
    return (v - 35) // 40


fn _b64_decode(var s: String) -> String:
    """Decode a base64 payload. Stops at the first non-alphabet,
    non-padding byte (so trailing whitespace from the OSC body is
    tolerated). Returns the empty string on malformed input — better
    to drop a clipboard write silently than feed garbage to the
    system clipboard.

    Pure-Mojo: OSC 52 payloads are tiny (kilobytes at most), so a
    branchy byte loop is fine."""
    var b = s.as_bytes()
    var n = len(b)
    var out = List[UInt8]()
    var accum = 0
    var bits = 0
    var pad = 0
    for i in range(n):
        var c = Int(b[i])
        var v: Int
        if c >= 0x41 and c <= 0x5A:   # A..Z
            v = c - 0x41
        elif c >= 0x61 and c <= 0x7A: # a..z
            v = c - 0x61 + 26
        elif c >= 0x30 and c <= 0x39: # 0..9
            v = c - 0x30 + 52
        elif c == 0x2B:               # '+'
            v = 62
        elif c == 0x2F:               # '/'
            v = 63
        elif c == 0x3D:               # '='
            pad += 1
            continue
        else:
            # Skip whitespace; stop at anything else.
            if c == 0x20 or c == 0x09 or c == 0x0A or c == 0x0D:
                continue
            break
        if pad > 0:
            # Data byte after padding — malformed. Bail.
            return String("")
        accum = (accum << 6) | v
        bits += 6
        if bits >= 8:
            bits -= 8
            out.append(UInt8((accum >> bits) & 0xFF))
    if len(out) == 0:
        return String("")
    return String(StringSlice(ptr=out.unsafe_ptr(), length=len(out)))
