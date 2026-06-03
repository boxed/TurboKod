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
