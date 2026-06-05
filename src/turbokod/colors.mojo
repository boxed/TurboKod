"""Color and text-attribute primitives.

We model an `Attr` as a foreground/background pair plus a small style bitfield.
Colors are 8-bit indexed (0..255) — the standard ANSI 256-color palette. This is
intentionally simpler than TurboVision's `TColorAttr`, which packs 4-bit BIOS
colors *and* optionally truecolor into a single value: that's a relic of fitting
into a 16-bit attribute byte and is unnecessary in Mojo.

Truecolor (24-bit) support is a future extension — the design leaves room.
"""

from std.collections.list import List

# --- Standard 16-color ANSI palette as named constants -----------------------

comptime BLACK         = UInt8(0)
comptime RED           = UInt8(1)
comptime GREEN         = UInt8(2)
comptime YELLOW        = UInt8(3)
comptime BLUE          = UInt8(4)
comptime MAGENTA       = UInt8(5)
comptime CYAN          = UInt8(6)
comptime LIGHT_GRAY    = UInt8(7)
comptime DARK_GRAY     = UInt8(8)
comptime LIGHT_RED     = UInt8(9)
comptime LIGHT_GREEN   = UInt8(10)
comptime LIGHT_YELLOW  = UInt8(11)
comptime LIGHT_BLUE    = UInt8(12)
comptime LIGHT_MAGENTA = UInt8(13)
comptime LIGHT_CYAN    = UInt8(14)
comptime WHITE         = UInt8(15)

# --- Reserved theme slots ----------------------------------------------------
#
# Indices 0..15 above are the ANSI-16 palette and drive *all* UI chrome
# (menus, windows, dialogs, status bar). A theme remaps their RGB at the
# frontend boundary, so re-skinning the chrome needs no change to the
# hundreds of ``Attr(...)`` literals that reference the named constants.
#
# The editor body and syntax-highlight tokens, however, want colors that are
# *independent* of the chrome palette (e.g. yellow strings without recoloring
# menu hotkeys). They use the reserved indices below — picked out of the
# 6x6x6 color-cube range (16..231), which nothing else in the app references
# (every other color goes through the named constants 0..15). A `Theme`
# overrides exactly these slots; everything else in 16..255 keeps the standard
# cube/grayscale values. The indices are stable across themes, so highlights
# baked at tokenize time stay valid — switching theme is a pure palette swap,
# no re-tokenize.
comptime EDITOR_BG     = UInt8(16)
comptime EDITOR_FG     = UInt8(17)
comptime SYN_KEYWORD   = UInt8(18)
comptime SYN_STRING    = UInt8(19)
comptime SYN_COMMENT   = UInt8(20)
comptime SYN_NUMBER    = UInt8(21)
comptime SYN_IDENT     = UInt8(22)
comptime SYN_DECORATOR = UInt8(23)
comptime SYN_OPERATOR  = UInt8(24)
# Tool-pane surface (terminal / debug / test panels) and window drop-shadow.
# These are a *dark terminal-like* surface in every theme, independent of the
# chrome palette: keeping them on a dedicated slot frees the chrome ``BLACK``
# (slot 0) / ``LIGHT_GRAY`` (slot 7) pair to flip light-on-dark for dark themes
# without turning the panes or shadows into low-contrast mud. ``PANE_FG`` is the
# neutral text/border color on that surface.
comptime PANE_BG       = UInt8(25)
comptime PANE_FG       = UInt8(26)
# The editor caret block: ``CARET_BG`` is the block color, ``CARET_FG`` the
# glyph showing through it. Dedicated slots because the caret must contrast
# with *every* theme's editor surface — the classic ``BLUE``-on-``YELLOW``
# pair only worked because those slots happened to be blue and yellow; under
# a theme they're arbitrary accents. Each theme sets these to its published
# cursor color (Monokai #F8F8F0, One Dark #528BFF, …); the default keeps the
# exact classic yellow-block-blue-glyph RGB.
comptime CARET_FG      = UInt8(27)
comptime CARET_BG      = UInt8(28)
# Focused window-border / chrome-line color. Border *backgrounds* match the
# window's content (``EDITOR_BG``), so the line color must contrast with that
# surface in every theme: near-white for dark editors, a strong dark for light
# ones. Unfocused borders don't need a slot — they use ``EDITOR_FG``, which
# contrasts with ``EDITOR_BG`` by construction (and resolves to the same RGB
# the old LIGHT_GRAY border had under the default theme).
comptime BORDER_FOCUS  = UInt8(29)
# Number of palette slots a theme defines (ANSI 0..15 + every reserved slot
# above). Derived from the last reserved index so adding a slot can't leave a
# stale count anywhere; ``theme.mojo`` sizes its rows and prefix-copy with it.
comptime THEME_SLOT_COUNT = Int(BORDER_FOCUS) + 1

# --- Style bits --------------------------------------------------------------

comptime STYLE_NONE            = UInt8(0)
comptime STYLE_BOLD            = UInt8(1 << 0)
comptime STYLE_DIM             = UInt8(1 << 1)
comptime STYLE_ITALIC          = UInt8(1 << 2)
comptime STYLE_UNDERLINE       = UInt8(1 << 3)
comptime STYLE_REVERSE         = UInt8(1 << 4)
comptime STYLE_STRIKE          = UInt8(1 << 5)
# Curly variant of underline. Only meaningful when STYLE_UNDERLINE is
# also set; emits ``SGR 4:3`` instead of ``SGR 4``. Modern terminals
# (iTerm2, kitty, vte, Windows Terminal, WezTerm) render this as a
# squiggle; older terminals that don't grok the colon-separated form
# fall back to plain underline. Whoever sets this bit is responsible
# for ensuring the terminal supports it (see
# ``terminal_supports_extended_underline``).
comptime STYLE_UNDERLINE_CURLY = UInt8(1 << 6)


struct Attr(ImplicitlyCopyable, Movable):
    """Visual attributes for a single cell.

    ``underline_color`` is the 256-color palette index used for the
    underline when ``STYLE_UNDERLINE`` is set. ``-1`` (the default)
    means "use the foreground color" — that's plain ``SGR 4`` and the
    line picks up whatever ``fg`` is. Anything in ``0..=255`` emits
    ``SGR 58:5:N`` so the underline can be a different color from the
    glyph (e.g. red squiggle under cyan comment text). Terminals that
    don't support ``58`` ignore the parameter and the underline falls
    back to the foreground color.
    """
    var fg: UInt8
    var bg: UInt8
    var style: UInt8
    var underline_color: Int16

    def __init__(out self):
        self.fg = LIGHT_GRAY
        self.bg = BLACK
        self.style = STYLE_NONE
        self.underline_color = -1

    def __init__(out self, fg: UInt8, bg: UInt8):
        self.fg = fg
        self.bg = bg
        self.style = STYLE_NONE
        self.underline_color = -1

    def __init__(out self, fg: UInt8, bg: UInt8, style: UInt8):
        self.fg = fg
        self.bg = bg
        self.style = style
        self.underline_color = -1

    def with_fg(self, fg: UInt8) -> Attr:
        var a = Attr(fg, self.bg, self.style)
        a.underline_color = self.underline_color
        return a

    def with_bg(self, bg: UInt8) -> Attr:
        var a = Attr(self.fg, bg, self.style)
        a.underline_color = self.underline_color
        return a

    def with_style(self, style: UInt8) -> Attr:
        var a = Attr(self.fg, self.bg, style)
        a.underline_color = self.underline_color
        return a

    def add_style(self, bits: UInt8) -> Attr:
        var a = Attr(self.fg, self.bg, self.style | bits)
        a.underline_color = self.underline_color
        return a

    def with_underline_color(self, color: Int16) -> Attr:
        var a = Attr(self.fg, self.bg, self.style)
        a.underline_color = color
        return a

    def __eq__(self, other: Attr) -> Bool:
        return self.fg == other.fg and self.bg == other.bg \
            and self.style == other.style \
            and self.underline_color == other.underline_color

    def __ne__(self, other: Attr) -> Bool:
        return not (self == other)


def default_attr() -> Attr:
    return Attr(LIGHT_GRAY, BLACK, STYLE_NONE)


@fieldwise_init
struct ColorRun(ImplicitlyCopyable, Movable):
    """A sub-line span ``[start, end)`` (byte offsets into the *clean*,
    escape-stripped text) that paints with ``attr`` instead of the line's
    base attribute. Produced by ``parse_sgr`` from ANSI SGR color runs —
    the segmented-color counterpart to a single per-line ``Attr``."""
    var start: Int
    var end: Int
    var attr: Attr


def attr_to_sgr(attr: Attr) -> String:
    """Render an `Attr` as a CSI SGR escape sequence (no leading ESC[)."""
    var s = String("0")  # reset first; simpler than diffing previous attr
    if (attr.style & STYLE_BOLD) != 0:      s += String(";1")
    if (attr.style & STYLE_DIM) != 0:       s += String(";2")
    if (attr.style & STYLE_ITALIC) != 0:    s += String(";3")
    if (attr.style & STYLE_UNDERLINE) != 0:
        if (attr.style & STYLE_UNDERLINE_CURLY) != 0:
            s += String(";4:3")
        else:
            s += String(";4")
    if (attr.style & STYLE_REVERSE) != 0:   s += String(";7")
    if (attr.style & STYLE_STRIKE) != 0:    s += String(";9")
    s += String(";38;5;") + String(Int(attr.fg))
    s += String(";48;5;") + String(Int(attr.bg))
    if attr.underline_color >= 0:
        s += String(";58;5;") + String(Int(attr.underline_color))
    return s


def _rgb_triplet(rgb: UInt32) -> String:
    """``r;g;b`` decimal from a packed ``0xRRGGBB`` value."""
    var r = (Int(rgb) >> 16) & 0xFF
    var g = (Int(rgb) >> 8) & 0xFF
    var b = Int(rgb) & 0xFF
    return String(r) + String(";") + String(g) + String(";") + String(b)


def attr_to_sgr_rgb(attr: Attr, palette: List[UInt32]) -> String:
    """Like ``attr_to_sgr`` but resolves the palette indices to 24-bit
    truecolor through ``palette`` and emits ``38;2;r;g;b`` / ``48;2;r;g;b``.

    This is what the terminal frontend uses on truecolor-capable terminals so
    a bundled theme renders identically to the native app — independent of the
    user's own terminal color scheme. ``palette`` must have 256 entries
    (``0xRRGGBB``); out-of-range indices fall back to index 0.
    """
    var s = String("0")  # reset first; simpler than diffing previous attr
    if (attr.style & STYLE_BOLD) != 0:      s += String(";1")
    if (attr.style & STYLE_DIM) != 0:       s += String(";2")
    if (attr.style & STYLE_ITALIC) != 0:    s += String(";3")
    if (attr.style & STYLE_UNDERLINE) != 0:
        if (attr.style & STYLE_UNDERLINE_CURLY) != 0:
            s += String(";4:3")
        else:
            s += String(";4")
    if (attr.style & STYLE_REVERSE) != 0:   s += String(";7")
    if (attr.style & STYLE_STRIKE) != 0:    s += String(";9")
    var n = len(palette)
    var fg_i = Int(attr.fg) if Int(attr.fg) < n else 0
    var bg_i = Int(attr.bg) if Int(attr.bg) < n else 0
    s += String(";38;2;") + _rgb_triplet(palette[fg_i])
    s += String(";48;2;") + _rgb_triplet(palette[bg_i])
    if attr.underline_color >= 0:
        var uc = Int(attr.underline_color)
        if uc < n:
            s += String(";58;2;") + _rgb_triplet(palette[uc])
    return s


# --- SGR (incoming) decoding -------------------------------------------------
#
# ``parse_sgr`` is the inverse of ``attr_to_sgr``: it reads ANSI SGR color
# escapes out of a *child process's* output stream and turns colored spans into
# ``ColorRun``s over the escape-free text. The terminal frontend's ``present``
# already speaks SGR going *out* to the user's terminal; this is the missing
# *in* direction so tool panes can colorize e.g. ``pytest --color=yes`` instead
# of showing raw escape bytes.


def _sgr_channel(v: Int) -> Int:
    """Map an 8-bit color channel to its 0..5 index in the xterm 6x6x6 cube."""
    if v < 48:
        return 0
    if v < 115:
        return 1
    return (v - 35) // 40


def _rgb_to_256(r: Int, g: Int, b: Int) -> UInt8:
    """Approximate a 24-bit RGB triple with the nearest xterm-256 index:
    the 232..255 gray ramp for gray triples, else the 16..231 color cube.
    Truecolor SGR (``38;2;r;g;b``) folds into our 256-color ``Attr`` here."""
    if r == g and g == b:
        if r < 8:
            return UInt8(16)
        if r > 248:
            return UInt8(231)
        return UInt8(232 + ((r - 8) * 24) // 247)
    var idx = 16 + 36 * _sgr_channel(r) + 6 * _sgr_channel(g) + _sgr_channel(b)
    return UInt8(idx)


def _apply_sgr(cur: Attr, base: Attr, params: List[Int]) -> Attr:
    """Fold one SGR parameter list onto ``cur``. ``base`` is the fallback
    for reset (``0``) and default fg/bg (``39`` / ``49``) — for a tool pane
    that's the per-stream color, so a ``\\x1b[0m`` returns to it rather than
    to a hardcoded gray-on-black."""
    if len(params) == 0:
        return base
    var a = cur
    var i = 0
    var n = len(params)
    while i < n:
        var p = params[i]
        if p == 0:
            a = base
        elif p == 1:
            a = a.add_style(STYLE_BOLD)
        elif p == 2:
            a = a.add_style(STYLE_DIM)
        elif p == 3:
            a = a.add_style(STYLE_ITALIC)
        elif p == 4:
            a = a.add_style(STYLE_UNDERLINE)
        elif p == 7:
            a = a.add_style(STYLE_REVERSE)
        elif p == 9:
            a = a.add_style(STYLE_STRIKE)
        elif p == 22:
            a = a.with_style(a.style & ~(STYLE_BOLD | STYLE_DIM))
        elif p == 23:
            a = a.with_style(a.style & ~STYLE_ITALIC)
        elif p == 24:
            a = a.with_style(a.style & ~STYLE_UNDERLINE)
        elif p == 27:
            a = a.with_style(a.style & ~STYLE_REVERSE)
        elif p == 29:
            a = a.with_style(a.style & ~STYLE_STRIKE)
        elif p >= 30 and p <= 37:
            a = a.with_fg(UInt8(p - 30))
        elif p == 38:
            if i + 2 < n and params[i + 1] == 5:
                a = a.with_fg(UInt8(params[i + 2] & 0xFF))
                i += 2
            elif i + 4 < n and params[i + 1] == 2:
                a = a.with_fg(
                    _rgb_to_256(params[i + 2], params[i + 3], params[i + 4])
                )
                i += 4
        elif p == 39:
            a = a.with_fg(base.fg)
        elif p >= 40 and p <= 47:
            a = a.with_bg(UInt8(p - 40))
        elif p == 48:
            if i + 2 < n and params[i + 1] == 5:
                a = a.with_bg(UInt8(params[i + 2] & 0xFF))
                i += 2
            elif i + 4 < n and params[i + 1] == 2:
                a = a.with_bg(
                    _rgb_to_256(params[i + 2], params[i + 3], params[i + 4])
                )
                i += 4
        elif p == 49:
            a = a.with_bg(base.bg)
        elif p >= 90 and p <= 97:
            a = a.with_fg(UInt8(p - 90 + 8))
        elif p >= 100 and p <= 107:
            a = a.with_bg(UInt8(p - 100 + 8))
        # Unrecognized codes (e.g. 5 blink) are ignored.
        i += 1
    return a


def parse_sgr(text: String, base_attr: Attr) -> Tuple[String, List[ColorRun]]:
    """Decode CSI-SGR color escapes in ``text``. Returns the escape-free
    text plus a ``ColorRun`` for every span whose attribute differs from
    ``base_attr`` (gaps fall back to ``base_attr`` at paint time, so an
    all-default line yields zero runs).

    Handles reset, the 16 ANSI fg/bg codes, default fg/bg (39/49), the
    common style bits, 256-color (``38;5;n`` / ``48;5;n``) and truecolor
    (``38;2;r;g;b``, nearest-mapped). Non-SGR escapes — cursor moves,
    ``\\x1b[K``, OSC, a lone ESC — are stripped from the clean text."""
    var src = text.as_bytes()
    var n = len(src)
    var clean = List[UInt8]()
    var runs = List[ColorRun]()
    var cur = base_attr
    var run_start = 0
    var i = 0
    while i < n:
        if Int(src[i]) == 0x1B:  # ESC
            if i + 1 < n and Int(src[i + 1]) == 0x5B:  # '[' → CSI
                # Scan to the final byte (0x40..0x7E ends a CSI sequence).
                var j = i + 2
                while j < n and not (
                    Int(src[j]) >= 0x40 and Int(src[j]) <= 0x7E
                ):
                    j += 1
                if j < n and Int(src[j]) == 0x6D:  # 'm' → SGR
                    # Parse the ';'-separated params between '[' and 'm',
                    # taking only the leading int of each ':'-subparam chunk.
                    var params = List[Int]()
                    var k = i + 2
                    while k <= j:
                        var val = 0
                        while k < j and Int(src[k]) != 0x3B:  # until ';'
                            var c = Int(src[k])
                            if c >= 0x30 and c <= 0x39:
                                val = val * 10 + (c - 0x30)
                            elif c == 0x3A:  # ':' subparam — skip the rest
                                while k < j and Int(src[k]) != 0x3B:
                                    k += 1
                                break
                            k += 1
                        params.append(val)
                        if k >= j:
                            break
                        k += 1  # skip the ';'
                    var new = _apply_sgr(cur, base_attr, params)
                    if new != cur:
                        if len(clean) > run_start and cur != base_attr:
                            runs.append(ColorRun(run_start, len(clean), cur))
                        run_start = len(clean)
                        cur = new
                i = j + 1 if j < n else n
                continue
            else:
                i += 1  # lone ESC / non-CSI escape: drop just the ESC byte
                continue
        clean.append(src[i])
        i += 1
    if len(clean) > run_start and cur != base_attr:
        runs.append(ColorRun(run_start, len(clean), cur))
    var clean_str = String("")
    if len(clean) > 0:
        clean_str = String(
            StringSlice(ptr=clean.unsafe_ptr(), length=len(clean))
        )
    return (clean_str^, runs^)
