"""Terminal emulator for the pty-backed panes, backed by libghostty-vt.

This is what sits between a pty's master fd and the on-screen ``Cell``
grid of the shell terminal (``terminal_pane.mojo``) and the test runner
(``test_pane.mojo``). The child writes bytes that look like a real
terminal session; Ghostty parses them and keeps the screen, scrollback,
modes and cursor; the pane paints the grid every frame.

Ghostty is a C library with an explicitly unstable API, so this module
never sees its headers. It talks to ``app/turbokod-shim/src/tk_vt.c``, a
flat ABI of integers, pointers and byte buffers that the shim compiles
against the pinned Ghostty (``scripts/build_ghostty.sh``). Everything
Ghostty-shaped — sized structs, enums, callbacks — stays on that side.

**Ownership.** ``Vt`` is a handle. Copies alias the same terminal (just
like ``PtyProcess`` copies alias one fd), and there is no destructor: the
owning pane calls ``release`` when it is torn down, and ``Desktop.shutdown``
reaches every pane. ``release`` through a second copy is a no-op — the
shim keeps a registry and frees only a handle it still holds — so the
hazard is using a handle *after* release, not releasing twice.
``vt_live_count`` is the leak gauge tests assert on. Because all state is
on the C side, two copies can never disagree about it.

**Reading cells.** ``grid`` returns a ``VtGrid``: a view of a snapshot the
shim builds through Ghostty's render state and caches until the next
mutating call. Paint loops take one grid and read every cell from it;
``view_cell_at`` / ``row_text`` are conveniences that do the same for one
lookup. A grid is invalid after ``feed`` / ``resize`` / scrolling.

**Colors.** A program's palette colors 0..15 stay palette indices, so they
follow the active theme like the rest of the UI. 16..255 are resolved to
their standard xterm RGB: our palette reserves 16..33 for editor / syntax /
chrome roles, and an index there would paint a theme's comment color where
the program asked for the xterm cube's dark blue. 24-bit colors pass
through as truecolor ``Attr``s.
"""

from std.collections.list import List
from std.ffi import external_call

from .cell import Cell
from .colors import (
    Attr, STYLE_BOLD, STYLE_DIM, STYLE_ITALIC, STYLE_REVERSE, STYLE_STRIKE,
    STYLE_UNDERLINE, STYLE_UNDERLINE_CURLY,
)
from .events import MOD_ALT, MOD_CTRL, MOD_META, MOD_SHIFT


comptime SCROLLBACK_LINES = 10000
"""Scrollback retained per terminal. Ghostty prunes at page granularity, so
the real figure is a little higher; its pages are compact enough that this
costs a few MB for a full history of 80-column output."""

# ``tk_vt_get`` keys — keep in step with ``TK_GET_*`` in ``tk_vt.c``.
comptime _K_COLS = 0
comptime _K_ROWS = 1
comptime _K_CURSOR_X = 2
comptime _K_CURSOR_Y = 3
comptime _K_CURSOR_VISIBLE = 4
comptime _K_ALT_SCREEN = 5
comptime _K_SCROLLBACK_ROWS = 6
comptime _K_VIEW_OFFSET = 7
comptime _K_MOUSE_TRACKING = 8
comptime _K_MOUSE_BUTTON_MOTION = 9
comptime _K_MOUSE_ANY_MOTION = 10
comptime _K_CURSOR_KEYS_APP = 11
comptime _K_BRACKETED_PASTE = 12
comptime _K_FOCUS_EVENTS = 13
comptime _K_PENDING_WRAP = 14
comptime _K_MOUSE_SGR = 15

# ``tk_vt_peek`` channels.
comptime _CHAN_REPLY = 0
comptime _CHAN_CLIPBOARD = 1
comptime _CHAN_TITLE = 2
comptime _CHAN_SCRATCH = 3

comptime _AREA_VIEWPORT = 0
comptime _AREA_ACTIVE = 1

comptime _CELL_WORDS = 6
"""Words per snapshot cell — the layout is documented above ``enc_color``
in ``tk_vt.c``."""

comptime _WIDE_WIDE = 1
comptime _WIDE_SPACER_TAIL = 2
comptime _WIDE_SPACER_HEAD = 3

comptime _UNDERLINE_CURLY = 3

# ``encode_mouse`` actions — ``TK_MOUSE_*`` in ``tk_vt.c``.
comptime MOUSE_PRESS = 0
comptime MOUSE_RELEASE = 1
comptime MOUSE_MOTION = 2


def vt_live_count() -> Int:
    """How many emulators exist and haven't been released — the measure of
    whether a teardown actually gave them back."""
    return external_call["tk_vt_live_count", Int]()


def _string_from(ptr: Int, n: Int) -> String:
    if ptr == 0 or n <= 0:
        return String("")
    var p = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=ptr)
    return String(StringSpan(unsafe_from_utf8=Span(unsafe_ptr=p, length=n)))


def xterm_256_rgb(idx: Int) -> UInt32:
    """The standard xterm RGB for a palette index in 16..255: the 6x6x6
    cube, then the 24-step grayscale ramp."""
    if idx >= 232:
        var v = UInt32(8 + 10 * (idx - 232))
        return (v << 16) | (v << 8) | v
    var i = idx - 16
    var r = i // 36
    var g = (i // 6) % 6
    var b = i % 6
    return (_cube_level(r) << 16) | (_cube_level(g) << 8) | _cube_level(b)


def _cube_level(n: Int) -> UInt32:
    return UInt32(0) if n == 0 else UInt32(55 + 40 * n)


def _with_fg(a: Attr, color: UInt32) -> Attr:
    var tag = color >> 24
    var value = color & 0xFFFFFF
    if tag == 1:
        if value < 16:
            return a.with_fg(UInt8(value))
        return a.with_fg_rgb(xterm_256_rgb(Int(value)))
    if tag == 2:
        return a.with_fg_rgb(value)
    return a


def _with_bg(a: Attr, color: UInt32) -> Attr:
    var tag = color >> 24
    var value = color & 0xFFFFFF
    if tag == 1:
        if value < 16:
            return a.with_bg(UInt8(value))
        return a.with_bg_rgb(xterm_256_rgb(Int(value)))
    if tag == 2:
        return a.with_bg_rgb(value)
    return a


def _attr_from(fg: UInt32, bg: UInt32, flags: UInt32, ul: UInt32) -> Attr:
    """Build an ``Attr`` from one snapshot cell's color and flag words.
    Default colors stay ``Attr()``'s (light gray on black), as they were
    before Ghostty."""
    var a = _with_bg(_with_fg(Attr(), fg), bg)
    var style = UInt8(0)
    if (flags & 0x01) != 0: style |= STYLE_BOLD
    if (flags & 0x02) != 0: style |= STYLE_ITALIC
    if (flags & 0x04) != 0: style |= STYLE_DIM
    if (flags & 0x10) != 0: style |= STYLE_REVERSE
    if (flags & 0x40) != 0: style |= STYLE_STRIKE
    var underline = Int((flags >> 8) & 0x7)
    if underline != 0:
        style |= STYLE_UNDERLINE
        if underline == _UNDERLINE_CURLY:
            style |= STYLE_UNDERLINE_CURLY
        # ``underline_color`` is a palette index; a program's own index is
        # only safe below 16 (see the module docstring on reserved slots).
        if (ul >> 24) == 1 and (ul & 0xFFFFFF) < 16:
            a.underline_color = Int16(ul & 0xFF)
    a.style = style
    return a


@fieldwise_init
struct VtGrid(ImplicitlyCopyable, Movable):
    """A read-only view of one emulator snapshot: the viewport (what the
    user sees, scrolled back or not) or the live screen. Valid until the
    next ``feed`` / ``resize`` / scroll on the ``Vt`` it came from."""
    var _words: Int
    var _text: Int
    var cols: Int
    var rows: Int

    def cell(self, r: Int, c: Int) -> Cell:
        """The cell at ``(r, c)``. A wide glyph is a ``width=2`` cell
        followed by an empty ``width=0`` continuation, the same shape
        ``Canvas.put_text`` produces. Out of range is a blank cell."""
        if r < 0 or r >= self.rows or c < 0 or c >= self.cols or self._words == 0:
            return Cell(String(" "), Attr(), 1)
        var w = Pointer[UInt32, MutUntrackedOrigin](unsafe_from_address=self._words)
        var base = (r * self.cols + c) * _CELL_WORDS
        var flags = w[unsafe_offset=base + 4]
        var attr = _attr_from(
            w[unsafe_offset=base + 2], w[unsafe_offset=base + 3], flags,
            w[unsafe_offset=base + 5],
        )
        var wide = Int((flags >> 12) & 0x3)
        if wide == _WIDE_SPACER_TAIL:
            return Cell(String(""), attr, 0)
        var n = Int(w[unsafe_offset=base + 1])
        # Empty, invisible (SGR 8) and the placeholder Ghostty leaves at a
        # row's end when a wide glyph wrapped to the next row all read as
        # a blank in their own colors.
        if n == 0 or (flags & 0x20) != 0 or wide == _WIDE_SPACER_HEAD:
            return Cell(String(" "), attr, 1)
        var glyph = _string_from(self._text + Int(w[unsafe_offset=base]), n)
        return Cell(glyph, attr, 2 if wide == _WIDE_WIDE else 1)

    def row_text(self, r: Int, c0: Int = 0, c1: Int = -1) -> String:
        """Glyphs of row ``r`` over columns ``[c0, c1)`` (``c1 < 0``: to the
        right edge), trailing spaces trimmed — the grid is padded to full
        width but callers want the visible text."""
        if r < 0 or r >= self.rows or self._words == 0:
            return String("")
        var end_c = self.cols if c1 < 0 else min(c1, self.cols)
        var w = Pointer[UInt32, MutUntrackedOrigin](unsafe_from_address=self._words)
        var out = List[UInt8]()
        for c in range(max(c0, 0), end_c):
            var base = (r * self.cols + c) * _CELL_WORDS
            var wide = Int((w[unsafe_offset=base + 4] >> 12) & 0x3)
            if wide == _WIDE_SPACER_TAIL:
                continue
            var n = Int(w[unsafe_offset=base + 1])
            if n == 0 or wide == _WIDE_SPACER_HEAD:
                out.append(0x20)
                continue
            var p = Pointer[UInt8, MutUntrackedOrigin](
                unsafe_from_address=self._text + Int(w[unsafe_offset=base])
            )
            for i in range(n):
                out.append(p[unsafe_offset=i])
        var end = len(out)
        while end > 0 and out[end - 1] == 0x20:
            end -= 1
        return String(StringSpan(unsafe_from_utf8=Span(out)[0:end]))


struct Vt(ImplicitlyCopyable, Movable):
    """A libghostty-vt terminal. See the module docstring for ownership:
    copies alias, and the owner calls ``release`` exactly where a destructor
    would have run."""
    var _h: Int

    def __init__(out self, cols: Int = 80, rows: Int = 24):
        self._h = external_call["tk_vt_new", Int](
            cols if cols > 0 else 1, rows if rows > 0 else 1, SCROLLBACK_LINES,
        )

    def release(mut self):
        """Free the emulator. Safe to call more than once, and through any
        copy; every *other* method is a no-op on a released ``Vt``."""
        if self._h != 0:
            _ = external_call["tk_vt_free", Int](self._h)
            self._h = 0

    def _get(self, key: Int) -> Int:
        if self._h == 0:
            return 0
        return external_call["tk_vt_get", Int](self._h, key)

    def _peek(self, chan: Int) -> String:
        if self._h == 0:
            return String("")
        var out = List[Int](length=1, fill=0)
        var n = external_call["tk_vt_peek", Int](self._h, chan, out.unsafe_ptr())
        return _string_from(out[0], n)

    # --- shape / state -------------------------------------------------

    def cols(self) -> Int:
        return self._get(_K_COLS)

    def rows(self) -> Int:
        return self._get(_K_ROWS)

    def cursor_row(self) -> Int:
        """Cursor row on the live screen (not the scrolled-back view)."""
        return self._get(_K_CURSOR_Y)

    def cursor_col(self) -> Int:
        return self._get(_K_CURSOR_X)

    def cursor_visible(self) -> Bool:
        """False after ``?25l``; the pane paints no caret then."""
        return self._get(_K_CURSOR_VISIBLE) != 0

    def wrap_pending(self) -> Bool:
        """True when the last glyph filled the last column and the wrap is
        deferred to the next printable byte (xterm's delayed wrap)."""
        return self._get(_K_PENDING_WRAP) != 0

    def using_alt(self) -> Bool:
        """True while a full-screen program (vim, less, fzf) has the
        alternate screen up."""
        return self._get(_K_ALT_SCREEN) != 0

    def title(self) -> String:
        """The last OSC 0/2 window title, empty if none was set. Shown in
        the pane chrome."""
        return self._peek(_CHAN_TITLE)

    def scrollback_rows(self) -> Int:
        """Rows of history above the live screen."""
        return self._get(_K_SCROLLBACK_ROWS)

    def view_offset(self) -> Int:
        """How many rows the view is scrolled up into history; 0 at the
        live tail."""
        return self._get(_K_VIEW_OFFSET)

    def tracks_mouse(self) -> Bool:
        """True when the program enabled mouse reporting (1000 / 1002 /
        1003), so mouse events go to it instead of to selection."""
        return self._get(_K_MOUSE_TRACKING) != 0

    def mouse_button_motion(self) -> Bool:
        """``?1002``: report drags while a button is held."""
        return self._get(_K_MOUSE_BUTTON_MOTION) != 0

    def mouse_any_motion(self) -> Bool:
        """``?1003``: report all motion."""
        return self._get(_K_MOUSE_ANY_MOTION) != 0

    def mouse_sgr(self) -> Bool:
        """``?1006``: SGR mouse encoding."""
        return self._get(_K_MOUSE_SGR) != 0

    def app_cursor_keys(self) -> Bool:
        """DECCKM (``?1``): arrows go out as SS3 instead of CSI."""
        return self._get(_K_CURSOR_KEYS_APP) != 0

    def bracketed_paste(self) -> Bool:
        """``?2004``: pastes are wrapped in ``ESC[200~`` / ``ESC[201~``."""
        return self._get(_K_BRACKETED_PASTE) != 0

    def focus_events(self) -> Bool:
        """``?1004``: the program wants focus-in / focus-out reports."""
        return self._get(_K_FOCUS_EVENTS) != 0

    # --- mutation ------------------------------------------------------

    def feed(mut self, data: Span[UInt8, _]):
        """Consume ``data`` — whatever the pane drained off the master fd
        this tick. Replies and clipboard writes it triggers queue up for
        ``take_reply`` / ``take_clipboard``."""
        if self._h == 0 or len(data) == 0:
            return
        external_call["tk_vt_write", NoneType](
            self._h, data.unsafe_ptr(), len(data)
        )

    def feed_string(mut self, s: String):
        """Convenience for tests / callers with String-shaped data."""
        self.feed(s.as_bytes())

    def resize(mut self, cols: Int, rows: Int):
        """Resize to ``cols`` x ``rows``. Ghostty reflows soft-wrapped lines
        on the primary screen, so shrinking and growing back is lossless
        (the alternate screen doesn't reflow; its program repaints on the
        SIGWINCH the pane sends)."""
        if self._h == 0 or cols <= 0 or rows <= 0:
            return
        external_call["tk_vt_resize", NoneType](self._h, cols, rows)

    def reset(mut self):
        """Wipe everything — screen, scrollback, modes, title — keeping the
        size. What a pane's Clear / Re-run / Restart wants: the same
        emulator, blank, so no copy is left holding a replaced handle."""
        if self._h == 0:
            return
        external_call["tk_vt_reset", NoneType](self._h)

    def scroll_view_by(mut self, delta: Int):
        """Scroll the view ``delta`` rows into history (negative: back
        toward the live tail). Clamped at both ends; a no-op on the
        alternate screen, which has no history."""
        if self._h == 0:
            return
        external_call["tk_vt_scroll", NoneType](self._h, delta)

    def reset_view(mut self):
        """Snap back to the live tail. The pane does this on typing — input
        while scrolled back is meant for the live prompt."""
        if self._h == 0:
            return
        external_call["tk_vt_scroll_to_bottom", NoneType](self._h)

    # --- cells ---------------------------------------------------------

    def grid(self, view: Bool = True) -> VtGrid:
        """A snapshot of the cells: the viewport as the user sees it
        (``view``), or the live screen regardless of scrolling. See
        ``VtGrid`` for how long it stays valid."""
        if self._h == 0:
            return VtGrid(0, 0, 0, 0)
        var out = List[Int](length=3, fill=0)
        var words = external_call["tk_vt_cells", Int](
            self._h, _AREA_VIEWPORT if view else _AREA_ACTIVE, out.unsafe_ptr(),
        )
        return VtGrid(words, out[0], out[1], out[2])

    def view_cell_at(self, r: Int, c: Int) -> Cell:
        """The cell the user sees at view-row ``r`` (scrolled back or not)."""
        return self.grid().cell(r, c)

    def cell_at(self, r: Int, c: Int) -> Cell:
        """The cell at ``(r, c)`` on the live screen, ignoring scrolling."""
        return self.grid(view=False).cell(r, c)

    def row_text(
        self, r: Int, c0: Int = 0, c1: Int = -1, view: Bool = True,
    ) -> String:
        """Glyphs of row ``r`` over ``[c0, c1)``, trailing spaces trimmed —
        of the view (``view``) or of the live screen."""
        return self.grid(view).row_text(r, c0, c1)

    def tail_rows(self, n: Int) -> List[String]:
        """The bottom ``n`` rows of the live screen as strings (trailing
        spaces trimmed) — what the Claude-state detector reads, whatever the
        user has scrolled to."""
        var out = List[String]()
        if n <= 0:
            return out^
        var g = self.grid(view=False)
        for r in range(max(g.rows - n, 0), g.rows):
            out.append(g.row_text(r))
        return out^

    # --- output to the child -------------------------------------------

    def take_reply(mut self) -> String:
        """Drain the bytes the terminal owes the child — DSR / DA answers,
        mode reports, focus reports. The pane writes them to the pty each
        tick; without that, prompts that probe (starship, fish) stall."""
        var out = self._peek(_CHAN_REPLY)
        if self._h != 0:
            external_call["tk_vt_consume", NoneType](self._h, _CHAN_REPLY)
        return out^

    def take_clipboard(mut self) -> String:
        """Drain the latest OSC 52 clipboard write (decoded), empty when
        there is none. The pane hands it to the system clipboard."""
        var out = self._peek(_CHAN_CLIPBOARD)
        if self._h != 0:
            external_call["tk_vt_consume", NoneType](self._h, _CHAN_CLIPBOARD)
        return out^

    def notify_focus_change(mut self, focused: Bool):
        """Queue ``ESC[I`` / ``ESC[O`` for the child if it enabled focus
        reporting (``?1004``); otherwise nothing."""
        if self._h == 0:
            return
        external_call["tk_vt_notify_focus", NoneType](
            self._h, 1 if focused else 0
        )

    def encode_key(self, key: UInt32, mods: UInt8) -> String:
        """The bytes a key press sends to the child: ``key`` is a ``KEY_*``
        constant or a codepoint, ``mods`` a ``MOD_*`` mask. Follows the
        modes the program enabled — DECCKM, modifyOtherKeys, the kitty
        keyboard protocol. Empty for a key that sends nothing."""
        if self._h == 0:
            return String("")
        # Cmd stays the host's (copy, close pane, …): a Cmd chord that
        # reaches us is sent as the bare key, as it always was.
        var n = external_call["tk_vt_encode_key", Int](
            self._h, Int(key), Int(mods & ~MOD_META)
        )
        if n <= 0:
            return String("")
        return self._peek(_CHAN_SCRATCH)

    def encode_mouse(
        self, action: Int, button: UInt8, col: Int, row: Int, mods: UInt8,
    ) -> String:
        """The bytes a mouse event at grid cell ``(col, row)`` sends to the
        child, in the tracking mode and wire format it enabled. ``action``
        is ``MOUSE_PRESS`` / ``MOUSE_RELEASE`` / ``MOUSE_MOTION``; ``button``
        a ``MOUSE_BUTTON_*`` / ``MOUSE_WHEEL_*`` value. Empty when the child
        asked for no such report."""
        if self._h == 0:
            return String("")
        var n = external_call["tk_vt_encode_mouse", Int](
            self._h, action, Int(button), col, row,
            Int(mods & (MOD_SHIFT | MOD_ALT | MOD_CTRL)),
        )
        if n <= 0:
            return String("")
        return self._peek(_CHAN_SCRATCH)
