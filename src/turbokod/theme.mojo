"""Color themes.

A `Theme` is just a **256-entry RGB palette** (`0xRRGGBB`) plus a name. Every
widget in the app paints through *palette indices* (the named constants in
`colors.mojo`), and both frontends resolve indices to RGB at the very edge — the
Swift app via this palette, the terminal via truecolor SGR built from it. So a
theme retints the *entire* UI — chrome, menus, desktop background, and syntax —
purely by changing what each index maps to, with no change to the paint sites.

Index layout (see `colors.mojo`):

* `0..15`  — the ANSI-16 palette. Drives all UI chrome (menus, dialogs, window
  frames, status bar, selections). The role of each slot is fixed by the paint
  code: `7` (LIGHT_GRAY) is the primary chrome *surface*, `0` (BLACK) the *text*
  on it, `15` (WHITE) bright text / borders / selected text, `2` (GREEN) the
  selection surface, `6` (CYAN) secondary list surfaces, `1` (RED) menu hotkeys,
  `8` (DARK_GRAY) dim text / line numbers. Dark themes flip `0`→light and
  `7`→dark; light themes keep `0`→dark and `7`→light. Because the code is
  identical and only the RGB differs, the flip is per-theme data, not a branch.
* `16..24` — reserved editor/syntax slots: `EDITOR_BG`, `EDITOR_FG`, then the
  seven token roles `SYN_KEYWORD/STRING/COMMENT/NUMBER/IDENT/DECORATOR/OPERATOR`.
  Decoupled from chrome so token hues match the theme regardless of menu colors.
* `25..26` — `PANE_BG` / `PANE_FG`: the dark terminal-like surface used by the
  tool panels and window shadows, dark in every theme.
* `29` — `BORDER_FOCUS`: focused window-border / chrome-line color — borders
  share the window content's background, so this must contrast with
  `EDITOR_BG` (near-white on dark editors, strong dark on light ones).
  Unfocused borders use `EDITOR_FG` and need no slot.
* `27..28` — `CARET_FG` / `CARET_BG`: the editor caret block (block color =
  `CARET_BG`, glyph through it = `CARET_FG`), so every theme ships its
  published cursor color and the caret can never vanish into the editor
  surface.
* everything else in `16..255` keeps the standard xterm 6x6x6 cube + grayscale
  ramp (identical to the values the Swift host shipped before themes existed),
  so any incidental cube color still resolves sensibly.

Switching theme is a pure palette swap + repaint — highlights bake the stable
reserved indices at tokenize time, so no re-tokenize is needed.
"""

from std.collections.list import List

from .colors import (
    DIFF_ADD_BG, DIFF_ADD_EMPH, DIFF_REM_BG, DIFF_REM_EMPH,
    EDITOR_BG, THEME_SLOT_COUNT,
)


@fieldwise_init
struct Theme(Copyable, Movable):
    var name: String
    var palette: List[UInt32]  # 256 entries, packed 0xRRGGBB


def _standard_palette() -> List[UInt32]:
    """A 256-entry palette pre-filled with the standard xterm cube + grayscale
    (indices 16..255). Indices 0..15 are zero placeholders that every theme
    overwrites. Mirrors ``buildPalette()`` in ``app/swift/TurboKod.swift`` so
    untouched cube colors are byte-identical to the pre-theme behavior."""
    var p = List[UInt32]()
    for _ in range(256):
        p.append(UInt32(0))
    var cube = List[Int]()
    cube.append(0); cube.append(95); cube.append(135)
    cube.append(175); cube.append(215); cube.append(255)
    var idx = 16
    for r in range(6):
        for g in range(6):
            for b in range(6):
                p[idx] = (UInt32(cube[r]) << 16) \
                       | (UInt32(cube[g]) << 8) | UInt32(cube[b])
                idx += 1
    for k in range(24):
        var v = UInt32(8 + 10 * k)
        p[232 + k] = (v << 16) | (v << 8) | v
    return p^


def _build(name: String, vals: List[UInt32]) -> Theme:
    """Build a theme from ``THEME_SLOT_COUNT`` RGB values: ``vals[0..15]`` are
    the ANSI-16 slots (palette 0..15) and the rest the reserved slots
    (``EDITOR_BG..CARET_BG``). The reserved positions line up 1:1 with their
    palette indices, so the copy below is a straight prefix write."""
    var p = _standard_palette()
    for i in range(THEME_SLOT_COUNT):
        p[i] = vals[i]
    # Derive the review diff washes from this theme's editor background so the
    # added (green) / modified (red) line tint stays faint and readable on dark
    # and light surfaces alike — no per-theme literal needed.
    var ed = p[Int(EDITOR_BG)]
    p[Int(DIFF_ADD_BG)] = _blend_rgb(ed, UInt32(0x33B233), 22)
    p[Int(DIFF_REM_BG)] = _blend_rgb(ed, UInt32(0xC8503C), 22)
    # Intra-line emphasis blends harder toward green / red so the exact
    # changed characters stand out from the faint surrounding wash.
    p[Int(DIFF_ADD_EMPH)] = _blend_rgb(ed, UInt32(0x33B233), 48)
    p[Int(DIFF_REM_EMPH)] = _blend_rgb(ed, UInt32(0xC8503C), 48)
    return Theme(name, p^)


def _blend_rgb(src: UInt32, dst: UInt32, pct: Int) -> UInt32:
    """Mix ``src`` ``pct``% of the way toward ``dst`` (both ``0xRRGGBB``)."""
    var sr = Int((src >> 16) & 0xFF)
    var sg = Int((src >> 8) & 0xFF)
    var sb = Int(src & 0xFF)
    var dr = Int((dst >> 16) & 0xFF)
    var dg = Int((dst >> 8) & 0xFF)
    var db = Int(dst & 0xFF)
    var rr = (sr * (100 - pct) + dr * pct) // 100
    var rg = (sg * (100 - pct) + dg * pct) // 100
    var rb = (sb * (100 - pct) + db * pct) // 100
    return (UInt32(rr) << 16) | (UInt32(rg) << 8) | UInt32(rb)


def _v(*args: UInt32) -> List[UInt32]:
    """Pack a variadic of RGB literals into a List (``THEME_SLOT_COUNT``
    values expected — ``_build`` reads exactly that many)."""
    var out = List[UInt32]()
    for a in args:
        out.append(a)
    return out^


# ---------------------------------------------------------------------------
# Theme registry. Order here is the order shown in Settings ▸ Theme.
# Each row is THEME_SLOT_COUNT values: ANSI 0..15, then EDITOR_BG, EDITOR_FG, SYN_KEYWORD,
# SYN_STRING, SYN_COMMENT, SYN_NUMBER, SYN_IDENT, SYN_DECORATOR, SYN_OPERATOR,
# PANE_BG, PANE_FG, CARET_FG, CARET_BG (caret block = CARET_BG, glyph through
# it = CARET_FG — each theme's published cursor color), BORDER_FOCUS.
# ---------------------------------------------------------------------------

comptime DEFAULT_THEME = "Turbo C++ 3.0"


def default_theme_name() -> String:
    return String(DEFAULT_THEME)


def built_in_themes() -> List[Theme]:
    var t = List[Theme]()

    # --- Turbo C++ 3.0 (default) — reproduces the pre-theme look exactly. ----
    # ANSI = the original Swift base16; reserved = the RGB of the named
    # constants the code used before themes (BLUE editor bg, etc.).
    t.append(_build(String("Turbo C++ 3.0"), _v(
        0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0021AA, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
        0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF,
        0x0021AA, 0xE5E5E5, 0xFFFFFF, 0xCD0000, 0x00CDCD, 0xE5E5E5, 0x00FF00, 0x00FFFF, 0xFFFF00,
        0x000000, 0xE5E5E5, 0x0021AA, 0xCDCD00, 0xFFFFFF,
    )))

    # --- Monokai (dark) ------------------------------------------------------
    t.append(_build(String("Monokai"), _v(
        0xF8F8F2, 0xF92672, 0x49483E, 0xE6DB74, 0x66D9EF, 0xAE81FF, 0x2D2E28, 0x3E3D32,
        0x75715E, 0xF92672, 0xA6E22E, 0xE6DB74, 0x66D9EF, 0xAE81FF, 0x66D9EF, 0xFFFFFF,
        0x272822, 0xF8F8F2, 0xF92672, 0xE6DB74, 0x75715E, 0xAE81FF, 0xA6E22E, 0x66D9EF, 0xF92672,
        0x1E1F1C, 0xCFCFC2, 0x272822, 0xF8F8F0, 0xF8F8F2,
    )))

    # --- Dracula (dark) ------------------------------------------------------
    t.append(_build(String("Dracula"), _v(
        0xF8F8F2, 0xFF5555, 0x44475A, 0xF1FA8C, 0x8BE9FD, 0xBD93F9, 0x343746, 0x44475A,
        0x6272A4, 0xFF6E6E, 0x50FA7B, 0xFFFFA5, 0xBD93F9, 0xFF92DF, 0xA4FFFF, 0xFFFFFF,
        0x282A36, 0xF8F8F2, 0xFF79C6, 0xF1FA8C, 0x6272A4, 0xBD93F9, 0x50FA7B, 0x8BE9FD, 0xFF79C6,
        0x21222C, 0xF8F8F2, 0x282A36, 0xF8F8F2, 0xF8F8F2,
    )))

    # --- One Dark (dark) -----------------------------------------------------
    t.append(_build(String("One Dark"), _v(
        0xABB2BF, 0xE06C75, 0x3E4451, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x2C313A, 0x3B4048,
        0x5C6370, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xFFFFFF,
        0x282C34, 0xABB2BF, 0xC678DD, 0x98C379, 0x5C6370, 0xD19A66, 0x61AFEF, 0x56B6C2, 0x56B6C2,
        0x21252B, 0xABB2BF, 0x282C34, 0x528BFF, 0xD7DAE0,
    )))

    # --- Gruvbox Dark (dark) -------------------------------------------------
    t.append(_build(String("Gruvbox Dark"), _v(
        0xEBDBB2, 0xFB4934, 0x504945, 0xFABD2F, 0x83A598, 0xD3869B, 0x32302F, 0x3C3836,
        0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xFBF1C7,
        0x282828, 0xEBDBB2, 0xFB4934, 0xB8BB26, 0x928374, 0xD3869B, 0x83A598, 0xFABD2F, 0xFE8019,
        0x1D2021, 0xEBDBB2, 0x282828, 0xEBDBB2, 0xFBF1C7,
    )))

    # --- Solarized Dark (dark) -----------------------------------------------
    t.append(_build(String("Solarized Dark"), _v(
        0x839496, 0xDC322F, 0x094D5A, 0xB58900, 0x268BD2, 0xD33682, 0x062B34, 0x073642,
        0x586E75, 0xCB4B16, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xFDF6E3,
        0x002B36, 0x839496, 0x859900, 0x2AA198, 0x586E75, 0xD33682, 0x268BD2, 0xB58900, 0x6C71C4,
        0x001F27, 0x93A1A1, 0x002B36, 0x839496, 0xFDF6E3,
    )))

    # --- Solarized Light (light) ---------------------------------------------
    t.append(_build(String("Solarized Light"), _v(
        0x586E75, 0xDC322F, 0x268BD2, 0xB58900, 0x268BD2, 0xD33682, 0xEDE6D0, 0xEEE8D5,
        0x93A1A1, 0xCB4B16, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xFFFFFF,
        0xFDF6E3, 0x657B83, 0x859900, 0x2AA198, 0x93A1A1, 0xD33682, 0x268BD2, 0xB58900, 0x6C71C4,
        0x073642, 0x93A1A1, 0xFDF6E3, 0x657B83, 0x002B36,
    )))

    # --- GitHub Light (light) ------------------------------------------------
    t.append(_build(String("GitHub Light"), _v(
        0x24292E, 0xD73A49, 0x0366D6, 0xDBAB09, 0x0366D6, 0x6F42C1, 0xF1F8FF, 0xEAECEF,
        0x6A737D, 0xCB2431, 0x22863A, 0xB08800, 0x0366D6, 0x6F42C1, 0x1B7C83, 0xFFFFFF,
        0xFFFFFF, 0x24292E, 0xD73A49, 0x032F62, 0x6A737D, 0x005CC5, 0x6F42C1, 0x22863A, 0xD73A49,
        0x24292E, 0xD1D5DA, 0xFFFFFF, 0x044289, 0x24292E,
    )))

    # --- One Light (light) ---------------------------------------------------
    t.append(_build(String("One Light"), _v(
        0x383A42, 0xE45649, 0x4078F2, 0xC18401, 0x4078F2, 0xA626A4, 0xF2F2F2, 0xEAEAEB,
        0xA0A1A7, 0xE45649, 0x50A14F, 0xC18401, 0x4078F2, 0xA626A4, 0x0184BC, 0xFFFFFF,
        0xFAFAFA, 0x383A42, 0xA626A4, 0x50A14F, 0xA0A1A7, 0x986801, 0x4078F2, 0x0184BC, 0x0184BC,
        0x2B2B2B, 0xCCCCCC, 0xFAFAFA, 0x526FFF, 0x383A42,
    )))

    # --- Turbo Pascal 7 (retro DOS) — VGA 16-color, gray menus. --------------
    t.append(_build(String("Turbo Pascal 7"), _v(
        0x000000, 0xA80000, 0x00A800, 0xA85400, 0x0000A8, 0xA800A8, 0x00A8A8, 0xA8A8A8,
        0x545454, 0xFE5454, 0x54FE54, 0xFEFE54, 0x5454FE, 0xFE54FE, 0x54FEFE, 0xFFFFFF,
        0x0000A8, 0xFEFE54, 0xFFFFFF, 0x54FEFE, 0xA8A8A8, 0x54FE54, 0xFEFE54, 0x54FEFE, 0xFFFFFF,
        0x000000, 0xA8A8A8, 0x0000A8, 0xFEFE54, 0xFFFFFF,
    )))

    # --- Norton Commander (retro DOS) — signature black-on-cyan bar. ---------
    t.append(_build(String("Norton Commander"), _v(
        0x000000, 0xA80000, 0x00A800, 0xA85400, 0x0000A8, 0xA800A8, 0x000088, 0x00A8A8,
        0x545454, 0xFE5454, 0x54FE54, 0xFEFE54, 0x5454FE, 0xFE54FE, 0x54FEFE, 0xFFFFFF,
        0x0000A8, 0x54FEFE, 0xFFFFFF, 0x54FE54, 0xA8A8A8, 0xFEFE54, 0x54FEFE, 0xFEFE54, 0xFFFFFF,
        0x000000, 0xA8A8A8, 0x0000A8, 0x54FEFE, 0xFFFFFF,
    )))

    # --- QBasic (retro DOS) — VGA 16-color, gray menus, green comments. ------
    t.append(_build(String("QBasic"), _v(
        0x000000, 0xA80000, 0x00A800, 0xA85400, 0x0000A8, 0xA800A8, 0x00A8A8, 0xA8A8A8,
        0x545454, 0xFE5454, 0x54FE54, 0xFEFE54, 0x5454FE, 0xFE54FE, 0x54FEFE, 0xFFFFFF,
        0x0000A8, 0xA8A8A8, 0xFFFFFF, 0x54FEFE, 0x54FE54, 0xFEFE54, 0xA8A8A8, 0x54FEFE, 0xFFFFFF,
        0x000000, 0xA8A8A8, 0x0000A8, 0xFEFE54, 0xFFFFFF,
    )))

    return t^


def theme_names() -> List[String]:
    var out = List[String]()
    var themes = built_in_themes()
    for i in range(len(themes)):
        out.append(themes[i].name)
    return out^


def theme_by_name(name: String) -> Theme:
    """Look up a theme by name; falls back to the default if unknown (e.g. a
    config written by a newer build that names a theme we don't ship)."""
    var themes = built_in_themes()
    for i in range(len(themes)):
        if themes[i].name == name:
            return themes[i].copy()
    return themes[0].copy()
