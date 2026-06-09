"""Color-space conversions + literal formatting for the color picker.

Pure-Mojo, frontend-agnostic. The single source of truth is sRGB stored
as three ``Float64`` components in ``[0, 1]``. Everything else (OkLab,
HSL, 8-bit, hex) is derived from / converted back to that.

OkLab follows Björn Ottosson's reference matrices
(https://bottosson.github.io/posts/oklab/); HSL is the standard CSS
algorithm. All conversions clamp the round-trip back into gamut so a
literal we write is always renderable.

Color spaces and their channel ranges as the picker presents them:

* **OkLab** — ``L`` in ``[0, 1]``, ``a`` / ``b`` roughly ``[-0.4, 0.4]``.
* **RGB**   — each channel ``[0, 255]`` (integers).
* **HSL**   — ``H`` ``[0, 360)``, ``S`` / ``L`` ``[0, 100]`` (percent).
"""

from std.math import cbrt


# --- small numeric helpers -------------------------------------------------


def _clamp01(x: Float64) -> Float64:
    if x < 0.0:
        return 0.0
    if x > 1.0:
        return 1.0
    return x


def _clamp(x: Float64, lo: Float64, hi: Float64) -> Float64:
    if x < lo:
        return lo
    if x > hi:
        return hi
    return x


def _pow10(n: Int) -> Int:
    var p = 1
    for _ in range(n):
        p *= 10
    return p


def fmt_fixed(x: Float64, decimals: Int) -> String:
    """Format ``x`` with exactly ``decimals`` fractional digits (rounded
    half-up), no scientific notation or float-print noise. ``decimals==0``
    yields a plain integer string."""
    var neg = x < 0.0
    var v = -x if neg else x
    var p = _pow10(decimals)
    # Round half-up at the requested precision.
    var scaled = Int(v * Float64(p) + 0.5)
    var ip = scaled // p
    var s = String(ip)
    if decimals > 0:
        var fp = scaled % p
        var frac = String(fp)
        while len(frac.as_bytes()) < decimals:
            frac = String("0") + frac
        s = s + String(".") + frac
    if neg and scaled != 0:
        s = String("-") + s
    return s


def parse_float(text: String) -> Optional[Float64]:
    """Parse a decimal number (optional sign, optional fractional part).
    Returns empty for anything that isn't a clean number — the picker uses
    this to validate a typed channel value before committing it."""
    var bytes = text.as_bytes()
    var n = len(bytes)
    var i = 0
    # Leading whitespace.
    while i < n and (Int(bytes[i]) == 0x20 or Int(bytes[i]) == 0x09):
        i += 1
    if i >= n:
        return Optional[Float64]()
    var neg = False
    if Int(bytes[i]) == ord("-") or Int(bytes[i]) == ord("+"):
        neg = Int(bytes[i]) == ord("-")
        i += 1
    var int_part = 0.0
    var saw_digit = False
    while i < n and ord("0") <= Int(bytes[i]) and Int(bytes[i]) <= ord("9"):
        int_part = int_part * 10.0 + Float64(Int(bytes[i]) - ord("0"))
        saw_digit = True
        i += 1
    var frac_part = 0.0
    if i < n and Int(bytes[i]) == ord("."):
        i += 1
        var scale = 1.0
        while i < n and ord("0") <= Int(bytes[i]) and Int(bytes[i]) <= ord("9"):
            scale *= 10.0
            frac_part += Float64(Int(bytes[i]) - ord("0")) / scale
            saw_digit = True
            i += 1
    # Trailing whitespace, then must be at end.
    while i < n and (Int(bytes[i]) == 0x20 or Int(bytes[i]) == 0x09):
        i += 1
    if i != n or not saw_digit:
        return Optional[Float64]()
    var val = int_part + frac_part
    if neg:
        val = -val
    return Optional[Float64](val)


# --- sRGB <-> packed 0xRRGGBB ---------------------------------------------


def srgb_to_rgb255(r: Float64, g: Float64, b: Float64) -> Tuple[Int, Int, Int]:
    """sRGB ``[0,1]`` → 8-bit ``[0,255]`` (rounded, clamped)."""
    var ri = Int(_clamp01(r) * 255.0 + 0.5)
    var gi = Int(_clamp01(g) * 255.0 + 0.5)
    var bi = Int(_clamp01(b) * 255.0 + 0.5)
    return (ri, gi, bi)


def rgb255_to_srgb(r: Int, g: Int, b: Int) -> Tuple[Float64, Float64, Float64]:
    return (Float64(r) / 255.0, Float64(g) / 255.0, Float64(b) / 255.0)


def pack_rgb(r: Int, g: Int, b: Int) -> UInt32:
    var rr = UInt32(_clamp(Float64(r), 0.0, 255.0))
    var gg = UInt32(_clamp(Float64(g), 0.0, 255.0))
    var bb = UInt32(_clamp(Float64(b), 0.0, 255.0))
    return (rr << 16) | (gg << 8) | bb


def unpack_rgb(rgb: UInt32) -> Tuple[Int, Int, Int]:
    return (
        Int((rgb >> 16) & 0xFF),
        Int((rgb >> 8) & 0xFF),
        Int(rgb & 0xFF),
    )


# --- sRGB gamma ------------------------------------------------------------


def _srgb_to_linear(c: Float64) -> Float64:
    if c <= 0.04045:
        return c / 12.92
    return ((c + 0.055) / 1.055) ** 2.4


def _linear_to_srgb(c: Float64) -> Float64:
    if c <= 0.0031308:
        return 12.92 * c
    return 1.055 * (c ** (1.0 / 2.4)) - 0.055


# --- sRGB <-> OkLab --------------------------------------------------------


def srgb_to_oklab(
    r: Float64, g: Float64, b: Float64
) -> Tuple[Float64, Float64, Float64]:
    var lr = _srgb_to_linear(_clamp01(r))
    var lg = _srgb_to_linear(_clamp01(g))
    var lb = _srgb_to_linear(_clamp01(b))
    var l = 0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb
    var m = 0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb
    var s = 0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb
    var l_ = cbrt(l)
    var m_ = cbrt(m)
    var s_ = cbrt(s)
    var ll = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
    var aa = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
    var bb = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
    return (ll, aa, bb)


def oklab_to_srgb(
    L: Float64, a: Float64, b: Float64
) -> Tuple[Float64, Float64, Float64]:
    var l_ = L + 0.3963377774 * a + 0.2158037573 * b
    var m_ = L - 0.1055613458 * a - 0.0638541728 * b
    var s_ = L - 0.0894841775 * a - 1.2914855480 * b
    var l = l_ * l_ * l_
    var m = m_ * m_ * m_
    var s = s_ * s_ * s_
    var lr = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
    var lg = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
    var lb = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
    return (
        _clamp01(_linear_to_srgb(lr)),
        _clamp01(_linear_to_srgb(lg)),
        _clamp01(_linear_to_srgb(lb)),
    )


# --- sRGB <-> HSL ----------------------------------------------------------


def srgb_to_hsl(
    r: Float64, g: Float64, b: Float64
) -> Tuple[Float64, Float64, Float64]:
    """Returns ``(H[0,360), S[0,100], L[0,100])``."""
    var rr = _clamp01(r)
    var gg = _clamp01(g)
    var bb = _clamp01(b)
    var mx = rr
    if gg > mx:
        mx = gg
    if bb > mx:
        mx = bb
    var mn = rr
    if gg < mn:
        mn = gg
    if bb < mn:
        mn = bb
    var l = (mx + mn) / 2.0
    var d = mx - mn
    var h = 0.0
    var s = 0.0
    if d > 1e-9:
        if l > 0.5:
            s = d / (2.0 - mx - mn)
        else:
            s = d / (mx + mn)
        if mx == rr:
            h = (gg - bb) / d
            if gg < bb:
                h += 6.0
        elif mx == gg:
            h = (bb - rr) / d + 2.0
        else:
            h = (rr - gg) / d + 4.0
        h *= 60.0
    return (h, s * 100.0, l * 100.0)


def _hue_to_channel(p: Float64, q: Float64, t_in: Float64) -> Float64:
    var t = t_in
    if t < 0.0:
        t += 1.0
    if t > 1.0:
        t -= 1.0
    if t < 1.0 / 6.0:
        return p + (q - p) * 6.0 * t
    if t < 1.0 / 2.0:
        return q
    if t < 2.0 / 3.0:
        return p + (q - p) * (2.0 / 3.0 - t) * 6.0
    return p


def hsl_to_srgb(
    h: Float64, s_pct: Float64, l_pct: Float64
) -> Tuple[Float64, Float64, Float64]:
    var hn = (h / 360.0)
    # Wrap hue into [0,1).
    hn = hn - Float64(Int(hn))
    if hn < 0.0:
        hn += 1.0
    var s = _clamp01(s_pct / 100.0)
    var l = _clamp01(l_pct / 100.0)
    if s < 1e-9:
        return (l, l, l)
    var q: Float64
    if l < 0.5:
        q = l * (1.0 + s)
    else:
        q = l + s - l * s
    var p = 2.0 * l - q
    var r = _hue_to_channel(p, q, hn + 1.0 / 3.0)
    var g = _hue_to_channel(p, q, hn)
    var b = _hue_to_channel(p, q, hn - 1.0 / 3.0)
    return (_clamp01(r), _clamp01(g), _clamp01(b))


# --- literal formatting ----------------------------------------------------


def _hex_digit(d: Int) -> String:
    if d < 10:
        return chr(ord("0") + d)
    return chr(ord("a") + d - 10)


def _hex2(v: Int) -> String:
    var n = v
    if n < 0:
        n = 0
    if n > 255:
        n = 255
    return _hex_digit(n // 16) + _hex_digit(n % 16)


def format_hex(r: Int, g: Int, b: Int) -> String:
    return String("#") + _hex2(r) + _hex2(g) + _hex2(b)


def format_oklab(L: Float64, a: Float64, b: Float64) -> String:
    return String("oklab(") + fmt_fixed(L, 3) + String(" ") \
        + fmt_fixed(a, 3) + String(" ") + fmt_fixed(b, 3) + String(")")


def format_rgb(r: Int, g: Int, b: Int) -> String:
    return String("rgb(") + String(r) + String(", ") + String(g) \
        + String(", ") + String(b) + String(")")


def format_hsl(h: Float64, s_pct: Float64, l_pct: Float64) -> String:
    return String("hsl(") + fmt_fixed(h, 0) + String(", ") \
        + fmt_fixed(s_pct, 0) + String("%, ") \
        + fmt_fixed(l_pct, 0) + String("%)")
