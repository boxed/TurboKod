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

comptime STYLE_NONE      = UInt8(0)
comptime STYLE_BOLD      = UInt8(1 << 0)
comptime STYLE_DIM       = UInt8(1 << 1)
comptime STYLE_ITALIC    = UInt8(1 << 2)
comptime STYLE_UNDERLINE = UInt8(1 << 3)
comptime STYLE_REVERSE   = UInt8(1 << 4)
comptime STYLE_STRIKE    = UInt8(1 << 5)


struct Attr(ImplicitlyCopyable, Movable):
    """Visual attributes for a single cell."""
    var fg: UInt8
    var bg: UInt8
    var style: UInt8

    fn __init__(out self):
        self.fg = LIGHT_GRAY
        self.bg = BLACK
        self.style = STYLE_NONE

    fn __init__(out self, fg: UInt8, bg: UInt8):
        self.fg = fg
        self.bg = bg
        self.style = STYLE_NONE

    fn __init__(out self, fg: UInt8, bg: UInt8, style: UInt8):
        self.fg = fg
        self.bg = bg
        self.style = style

    fn with_fg(self, fg: UInt8) -> Attr:
        return Attr(fg, self.bg, self.style)

    fn with_bg(self, bg: UInt8) -> Attr:
        return Attr(self.fg, bg, self.style)

    fn with_style(self, style: UInt8) -> Attr:
        return Attr(self.fg, self.bg, style)

    fn add_style(self, bits: UInt8) -> Attr:
        return Attr(self.fg, self.bg, self.style | bits)

    fn __eq__(self, other: Attr) -> Bool:
        return self.fg == other.fg and self.bg == other.bg and self.style == other.style

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
    if (attr.style & STYLE_UNDERLINE) != 0: s += String(";4")
    if (attr.style & STYLE_REVERSE) != 0:   s += String(";7")
    if (attr.style & STYLE_STRIKE) != 0:    s += String(";9")
    s += String(";38;5;") + String(Int(attr.fg))
    s += String(";48;5;") + String(Int(attr.bg))
    return s
