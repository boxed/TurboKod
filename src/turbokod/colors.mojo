"""Color and text-attribute primitives.

We model an `Attr` as a foreground/background pair plus a small style bitfield.
Colors are 8-bit indexed (0..255) — the standard ANSI 256-color palette. This is
intentionally simpler than TurboVision's `TColorAttr`, which packs 4-bit BIOS
colors *and* optionally truecolor into a single value: that's a relic of fitting
into a 16-bit attribute byte and is unnecessary in Mojo.

Truecolor (24-bit) support is a future extension — the design leaves room.
"""

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

    fn __init__(out self):
        self.fg = LIGHT_GRAY
        self.bg = BLACK
        self.style = STYLE_NONE
        self.underline_color = -1

    fn __init__(out self, fg: UInt8, bg: UInt8):
        self.fg = fg
        self.bg = bg
        self.style = STYLE_NONE
        self.underline_color = -1

    fn __init__(out self, fg: UInt8, bg: UInt8, style: UInt8):
        self.fg = fg
        self.bg = bg
        self.style = style
        self.underline_color = -1

    fn with_fg(self, fg: UInt8) -> Attr:
        var a = Attr(fg, self.bg, self.style)
        a.underline_color = self.underline_color
        return a

    fn with_bg(self, bg: UInt8) -> Attr:
        var a = Attr(self.fg, bg, self.style)
        a.underline_color = self.underline_color
        return a

    fn with_style(self, style: UInt8) -> Attr:
        var a = Attr(self.fg, self.bg, style)
        a.underline_color = self.underline_color
        return a

    fn add_style(self, bits: UInt8) -> Attr:
        var a = Attr(self.fg, self.bg, self.style | bits)
        a.underline_color = self.underline_color
        return a

    fn with_underline_color(self, color: Int16) -> Attr:
        var a = Attr(self.fg, self.bg, self.style)
        a.underline_color = color
        return a

    fn __eq__(self, other: Attr) -> Bool:
        return self.fg == other.fg and self.bg == other.bg \
            and self.style == other.style \
            and self.underline_color == other.underline_color

    fn __ne__(self, other: Attr) -> Bool:
        return not (self == other)


fn default_attr() -> Attr:
    return Attr(LIGHT_GRAY, BLACK, STYLE_NONE)


fn attr_to_sgr(attr: Attr) -> String:
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
