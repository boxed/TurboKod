import AppKit
import CoreText
import CoreGraphics

// The bundled IBM VGA bitmap font (8×16), matching the terminal/Rust look.
// Designed at 16px, so 16pt gives an 8pt advance — exactly our cell size.
// Falls back to Menlo if the bundled TTF is missing.
func loadCellFont(size: CGFloat = 16) -> NSFont {
    if let res = Bundle.main.resourcePath {
        let url = URL(fileURLWithPath: res + "/Px437_IBM_VGA_8x16.ttf")
        if FileManager.default.fileExists(atPath: url.path) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            if let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL)
                as? [CTFontDescriptor], let desc = descs.first {
                return CTFontCreateWithFontDescriptor(desc, size, nil) as NSFont
            }
        }
    }
    return NSFont(name: "Menlo", size: 13)
        ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
}

// Default point sizes when config.font_size is 0 ("the font's default"):
// the bundled bitmap font's 16px design size, and the conventional 13pt
// for system monospace families.
let BITMAP_FONT_DEFAULT_SIZE = 16
let VECTOR_FONT_DEFAULT_SIZE = 13

// Active cell font (Settings ▸ Font). Defaults to the bundled bitmap font;
// `applyCellFont` swaps in a system monospace family and/or point size and
// recomputes the cell metrics — every CellView reads these globals per draw,
// so the whole grid reflows on the next frame. `cellFontIsBitmap` gates the
// no-antialias path: bitmap glyphs at their pixel-exact size must render
// crisp, everything else must not.
var cellFont = loadCellFont()
var cellFontIsBitmap = true

// Per-codepoint "does the cell font actually have a glyph for this?" cache.
// The bundled Px437 bitmap font only covers CP437, so codepoints outside it
// (e.g. U+00B3 ³ — there's no superscript-three in CP437, though ² U+00B2 is
// present) have no glyph. Left to `NSString.draw`, Core Text silently swaps in
// a system fallback font whose metrics overflow the 8×16 cell and bleed over
// the neighbouring cell — so the same character renders differently depending
// on what sits beside it. We detect the gap and render it cell-fitted instead.
// Cleared whenever `cellFont` changes (Settings ▸ Font).
var cellFontGlyphCache: [UInt32: Bool] = [:]

func cellFontHasGlyph(_ cp: UInt32) -> Bool {
    if let v = cellFontGlyphCache[cp] { return v }
    var present = false
    if let scalar = Unicode.Scalar(cp) {
        var utf16 = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        let ok = CTFontGetGlyphsForCharacters(
            cellFont as CTFont, &utf16, &glyphs, utf16.count)
        present = ok && glyphs[0] != 0
    }
    cellFontGlyphCache[cp] = present
    return present
}
var currentCellFontName = ""             // "" = the bundled default
var currentCellFontSize: CGFloat = -1    // 0 = font default; -1 forces the first apply through
// Resolved size info the host reports back to the Mojo core after every
// apply (tk_desktop_set_font_size_info): the point size actually rendering,
// and the active font's design ("ideal") size — 0 when it has none.
var cellFontEffectiveSize = BITMAP_FONT_DEFAULT_SIZE
var cellFontIdealSize = BITMAP_FONT_DEFAULT_SIZE

// Monospace families the user may pick from (Settings ▸ Font). A lazy
// static (not a top-level let — those initialize eagerly in main-file
// mode) enumerated once: NSFontManager probes every installed family,
// which is too slow to run per window. Hidden system families (leading
// ".") are skipped.
enum FontCatalog {
    static let monospaceFamilies: [String] = {
        let fm = NSFontManager.shared
        var out: [String] = []
        for family in fm.availableFontFamilies {
            if family.hasPrefix(".") { continue }
            guard let members = fm.availableMembers(ofFontFamily: family),
                  let first = members.first,
                  let name = first[0] as? String,
                  let f = NSFont(name: name, size: 13),
                  f.isFixedPitch else { continue }
            out.append(family)
        }
        return out.sorted()
    }()
}

/// Read the configured cell-font family name out of a Mojo Desktop
/// (empty = the bundled bitmap font).
func fetchFontName(_ h: Int64) -> String {
    var buf = [UInt8](repeating: 0, count: 256)
    let n = buf.withUnsafeMutableBufferPointer { b -> Int in
        Int(tk_font_name(h, Int64(Int(bitPattern: b.baseAddress)), Int64(b.count)))
    }
    return n > 0 ? (String(bytes: buf[0..<n], encoding: .utf8) ?? "") : ""
}

/// FourCC for a CTFontCopyTable tag (e.g. "EBLC").
private func fontTableTag(_ s: String) -> CTFontTableTag {
    var v: UInt32 = 0
    for u in s.unicodeScalars { v = (v << 8) | (u.value & 0xFF) }
    return CTFontTableTag(v)
}

/// Native ("ideal") pixel-per-em size of a font's embedded bitmap strikes,
/// or 0 when the font has none (ordinary vector fonts). A true bitmap font
/// only looks right at a strike size — Settings surfaces this as the
/// "Restore ideal" button. EBLC / CBLC / bloc share the 48-byte
/// bitmapSize-record layout (ppemY at record offset 45); sbix keeps a
/// u16 ppem per strike. When a font ships several strikes, pick the one
/// closest to 16 — the app's classic cell height — preferring the larger
/// on ties.
func bitmapStrikePPEM(_ font: NSFont) -> Int {
    var strikes: [Int] = []
    let ct = font as CTFont
    for tag in ["EBLC", "CBLC", "bloc"] {
        guard let cfData = CTFontCopyTable(ct, fontTableTag(tag), []) else { continue }
        let d = [UInt8](cfData as Data)
        guard d.count >= 8 else { continue }
        let numSizes = Int(d[4]) << 24 | Int(d[5]) << 16 | Int(d[6]) << 8 | Int(d[7])
        for i in 0..<numSizes {
            let rec = 8 + i * 48
            guard rec + 48 <= d.count else { break }
            let ppem = Int(d[rec + 45])   // ppemY
            if ppem > 0 { strikes.append(ppem) }
        }
    }
    if let cfData = CTFontCopyTable(ct, fontTableTag("sbix"), []) {
        let d = [UInt8](cfData as Data)
        if d.count >= 8 {
            let numStrikes = Int(d[4]) << 24 | Int(d[5]) << 16 | Int(d[6]) << 8 | Int(d[7])
            for i in 0..<numStrikes {
                let op = 8 + i * 4
                guard op + 4 <= d.count else { break }
                let off = Int(d[op]) << 24 | Int(d[op + 1]) << 16
                        | Int(d[op + 2]) << 8 | Int(d[op + 3])
                guard off >= 0, off + 2 <= d.count else { continue }
                let ppem = Int(d[off]) << 8 | Int(d[off + 1])
                if ppem > 0 { strikes.append(ppem) }
            }
        }
    }
    return strikes.min { a, b in
        let (da, db) = (abs(a - 16), abs(b - 16))
        return da != db ? da < db : a > b
    } ?? 0
}

/// The bundled Px437 font at `size` points (0 = its 16px design size).
/// The glyph grid is exactly 8×16 at 16pt, so the cell scales as a strict
/// 1:2 box. Crisp (no-AA) rendering only at integer multiples of the
/// design size, where the bitmap pixels land exactly on cell pixels —
/// fractional scales look better antialiased.
private func applyBundledCellFont(_ size: CGFloat) {
    let eff = size > 0 ? size : CGFloat(BITMAP_FONT_DEFAULT_SIZE)
    cellFont = loadCellFont(size: eff)
    cellFontGlyphCache.removeAll()
    cellFontEffectiveSize = Int(eff.rounded())
    cellFontIdealSize = BITMAP_FONT_DEFAULT_SIZE
    cellFontIsBitmap = cellFontEffectiveSize % BITMAP_FONT_DEFAULT_SIZE == 0
    CELL_W = max(1, (eff / 2).rounded())
    CELL_H = max(1, eff.rounded())
}

/// Switch the cell font to `name` (a family from `monospaceFontFamilies`;
/// empty = the bundled bitmap font) at `size` points (0 = the font's
/// default) and recompute CELL_W/CELL_H from its metrics. No-op when both
/// are already active. Derives `cellFontEffectiveSize` / `cellFontIdealSize`
/// for the caller to report back to the Mojo core.
func applyCellFont(_ name: String, size: CGFloat = 0) {
    if name == currentCellFontName && size == currentCellFontSize { return }
    currentCellFontName = name
    currentCellFontSize = size
    if name.isEmpty {
        applyBundledCellFont(size)
        return
    }
    let eff = size > 0 ? size : CGFloat(VECTOR_FONT_DEFAULT_SIZE)
    guard let f = NSFontManager.shared.font(withFamily: name, traits: [],
                                            weight: 5, size: eff)
        ?? NSFont(name: name, size: eff) else {
        // Unknown family (e.g. config written on another machine): keep
        // the bundled default rather than rendering nothing.
        applyBundledCellFont(size)
        return
    }
    cellFont = f
    cellFontGlyphCache.removeAll()
    cellFontEffectiveSize = Int(eff.rounded())
    cellFontIdealSize = bitmapStrikePPEM(f)
    // A font with embedded bitmap strikes renders crisp (no AA) at exactly
    // its strike size — same rule as the bundled bitmap font.
    cellFontIsBitmap = cellFontIdealSize > 0
        && cellFontEffectiveSize == cellFontIdealSize
    // Cell metrics: a monospace glyph advance for the width, the font's
    // line height for the cell height — same numbers a terminal emulator
    // would use for its grid.
    let adv = ("0" as NSString).size(withAttributes: [.font: f]).width
    CELL_W = max(1, ceil(adv))
    CELL_H = max(1, ceil(f.ascender - f.descender + f.leading))
}

// MARK: - 256-color palette (mirrors render.rs / colors.mojo)

func buildPalette() -> [UInt32] {
    let base16: [UInt32] = [
        0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0021AA, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
        0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF,
    ]
    let cube: [UInt32] = [0, 95, 135, 175, 215, 255]
    var p = [UInt32](repeating: 0, count: 256)
    for i in 0..<16 { p[i] = base16[i] }
    var i = 16
    for r in 0..<6 { for g in 0..<6 { for b in 0..<6 {
        p[i] = (cube[r] << 16) | (cube[g] << 8) | cube[b]; i += 1
    }}}
    for k in 0..<24 { let v = UInt32(8 + 10 * k); p[232 + k] = (v << 16) | (v << 8) | v }
    return p
}

// Style bits (colors.mojo)
let STYLE_BOLD: UInt32 = 1 << 0
let STYLE_DIM: UInt32 = 1 << 1
let STYLE_UNDERLINE: UInt32 = 1 << 3
let STYLE_REVERSE: UInt32 = 1 << 4
let STYLE_UNDERLINE_CURLY: UInt32 = 1 << 6

// color_mode bits (colors.mojo): fg/bg carry 24-bit truecolor in the
// per-cell fg_rgb / bg_rgb words instead of a palette index.
let FG_TRUECOLOR: UInt32 = 1 << 0
let BG_TRUECOLOR: UInt32 = 1 << 1
// Per-cell word stride of the layout buffer (native_api.mojo _pack_canvas):
// [codepoint, fg|bg<<8|style<<16|color_mode<<24, underline, fg_rgb, bg_rgb].
let CELL_WORDS = 5
// Reserved palette index for the editor background (colors.mojo EDITOR_BG).
// The smooth-scroll composite fills the clip with this before drawing the
// region so a rubber-band gap past the top/bottom edge reads as empty
// editor space, not the default desktop background.
let EDITOR_BG_IDX = 16

// turbokod key constants (events.mojo private-use codes)
let KEY_ENTER: UInt32 = 0xE001, KEY_TAB: UInt32 = 0xE002, KEY_BACKSPACE: UInt32 = 0xE003
let KEY_ESC: UInt32 = 0xE004
let KEY_UP: UInt32 = 0xE010, KEY_DOWN: UInt32 = 0xE011, KEY_LEFT: UInt32 = 0xE012, KEY_RIGHT: UInt32 = 0xE013
let KEY_HOME: UInt32 = 0xE014, KEY_END: UInt32 = 0xE015, KEY_PAGEUP: UInt32 = 0xE016
let KEY_PAGEDOWN: UInt32 = 0xE017, KEY_INSERT: UInt32 = 0xE018, KEY_DELETE: UInt32 = 0xE019
let KEY_F1: UInt32 = 0xE020

let MOD_SHIFT: UInt8 = 1, MOD_ALT: UInt8 = 2, MOD_CTRL: UInt8 = 4, MOD_META: UInt8 = 8
// Modifier IDs for bare-transition events (EVENT_MOD_KEY) — see events.mojo.
let MOD_KEY_ALT: UInt32 = 2

var CELL_W: CGFloat = 8, CELL_H: CGFloat = 16

func nscolor(_ rgb: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0, alpha: 1.0)
}

func cgcolor(_ rgb: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0, alpha: 1.0)
}

// MARK: - Cell-grid view, backed by a Mojo Desktop handle

// Which Mojo render surface a CellView draws. `.main` is the project window
// (editors + file tree + status, panels docked unless floated). `.panels` is
// the separate floating-panels window, which shares the main view's Desktop
// handle and draws ONLY the tool panels via the `_panels` C ABI. See
// docs/floating-panels.md.
// `.settings` is the standalone Settings window — like `.panels` it shares the
// main view's Desktop handle and never ticks; it renders via the `_settings`
// C ABI and is opened/closed by polling tk_desktop_settings_active.
// `.projectSettings` is the twin standalone Project Settings window (On save /
// Targets / Grammars), driven by the `_project_settings` C ABI.
enum CellSurface { case main, panels, settings, projectSettings }

final class CellView: NSView {
    var handle: Int64 = 0
    var surface: CellSurface = .main
    // For a `.panels` view: the project window's view it mirrors. Actions the
    // panel surface bubbles up (e.g. an open-file from a debug-output link)
    // route to this peer so they land in the project window, not the panel
    // window. nil for `.main` views.
    weak var mainPeer: CellView?
    var project: String?      // set when a project is opened; drives session save
    private var buf = UnsafeMutablePointer<UInt32>.allocate(capacity: CELL_WORDS)
    private var bufCells = 1
    // Last cell a passive (no-button) mouse move was dispatched for. macOS
    // delivers bare motion at the display refresh rate (60–120 Hz), but the
    // Mojo side works in cell coordinates — every pixel move inside one cell
    // produces identical hover state and pointer shape. Dispatching them is
    // pure waste (two FFI hit-tests per event), so we drop motion that didn't
    // cross a cell boundary. -1 forces the first move through.
    private var lastPassiveCol: Int64 = -1, lastPassiveRow: Int64 = -1
    // Accumulated vertical scroll delta not yet turned into wheel notches.
    // macOS delivers scroll as a high-frequency stream of small (often
    // sub-line) deltas plus post-liftoff momentum; the Mojo core consumes
    // discrete wheel notches (3 lines each). We integrate the delta here
    // and emit one notch per notch-worth of travel so scroll speed tracks
    // the gesture, not the raw event rate. See scrollWheel.
    private var scrollAccumY: CGFloat = 0
    // Horizontal twin of scrollAccumY — a trackpad horizontal swipe or
    // Shift+wheel is integrated here and emitted as Shift+wheel notches.
    private var scrollAccumX: CGFloat = 0
    // --- Native smooth (pixel-level) scrolling, main surface only --------
    // The host owns a continuous scroll position in fractional buffer lines
    // for the focused editor; the Mojo core stores the integer split +
    // sub-row anchor (tk_editor_smooth_set) and reports the scroll region
    // (tk_editor_scroll_regions). When the fraction is non-zero, `draw`
    // composites an overdraw render of the editor body translated by the
    // pixel offset. `smoothLines` is the *raw* continuous position (it
    // overshoots [0, max] during a rubber-band); damping is applied only to
    // the displayed value. `smoothActive` is true while a precise gesture /
    // momentum is in flight (events drive it); the spring timer drives the
    // post-gesture rubber-band release and stores into the core.
    private var smoothWinIdx = -1
    private var smoothLines: CGFloat = 0
    private var smoothMax = 0
    private var smoothActive = false
    private var springTarget: CGFloat = 0
    private var springTimer: Timer?
    // Per-run easing factor for the spring timer (fraction of the remaining
    // distance closed each 120 Hz tick). The post-gesture rubber-band release
    // wants a brisker snap than the mouse-wheel glide.
    private var springSpeed: CGFloat = 0.30
    // Cap on how far the *raw* `smoothLines` may run past an edge. The
    // rubber-band curve pins the *displayed* overshoot to a few rows no matter
    // how large the raw is, but momentum can drive the raw hundreds of rows out
    // — and then the spring-back wastes its first dozen ticks dragging the raw
    // back toward the edge while the displayed position sits pinned at the
    // asymptote (the "floats out there, then snaps" sluggishness). Clamping the
    // raw keeps the visible overshoot identical but lets the release move the
    // displayed position from the very first tick.
    private let smoothOvershootCap: CGFloat = 12
    // True while a post-overshoot spring-back is in flight. macOS keeps
    // delivering momentum events for ~1-2 s after finger-lift; without this
    // latch each one cancels the spring and re-pins the view at the overshoot,
    // so the bounce wouldn't fire until momentum fully decayed. While set, the
    // momentum tail is dropped. Cleared by a fresh finger-down or when the
    // spring settles.
    private var smoothReleasing = false
    // Second cell buffer for the overdraw region render (the editor body one
    // grid taller than the viewport), packed by tk_editor_region_layout.
    private var regionBuf = UnsafeMutablePointer<UInt32>.allocate(capacity: CELL_WORDS)
    private var regionBufCells = 1
    // True while a left-drag that began on the minimap gutter is in flight.
    // The minimap doubles as a scrollbar; we scroll it from the raw sub-cell
    // pointer Y (proportional) instead of the cell-quantized core hit-test,
    // so dragging a large file scrolls finely rather than ~100 lines a cell.
    private var minimapDragging = false
    // True while a left-drag on the window-border vertical scrollbar thumb is
    // in flight. The core owns the drag state; we just route motion through
    // the sub-cell `tk_desktop_vscroll_drag` so a long file scrolls
    // line-by-line instead of ~150 lines per (cell-quantized) thumb cell.
    private var sbDragging = false
    // Last-seen Option/Alt key state, so flagsChanged (which fires for any
    // modifier transition) can detect Option's own up/down edges and report
    // them as bare EVENT_MOD_KEY transitions for the Alt-tap gestures.
    private var optionDown = false
    // Live Shift-key state, tracked from flagsChanged. Used to decide a
    // Shift+scroll is horizontal — more reliable than a scrollWheel event's
    // own modifierFlags, which (depending on device/momentum) may not carry
    // Shift, and macOS doesn't always axis-swap it to deltaX for us.
    private var shiftDown = false
    // Palette is the active theme's index→RGB table. Seeded with the classic
    // built-in palette and refreshed from the Mojo core whenever the theme
    // version changes (Settings ▸ Theme). `themeVersion = -1` forces the first
    // refresh through.
    private var palette = buildPalette()
    private var themeVersion: Int64 = -1
    // Cell-font version mirror — like `themeVersion`, but for Settings ▸
    // Font. When the Mojo counter moves we refetch the family name and
    // swap the global `cellFont` + cell metrics. -1 forces the first
    // check through (a no-op while the config holds the default).
    private var fontVersion: Int64 = -1

    /// Refetch the configured cell font + size if the Mojo core's font
    /// version has moved. Returns true when the font actually changed (the
    /// grid metrics are different, so everything must re-lay-out + redraw).
    @discardableResult
    private func refreshFontIfNeeded() -> Bool {
        guard handle != 0 else { return false }
        let v = tk_font_version(handle)
        if v == fontVersion { return false }
        fontVersion = v
        let prevName = currentCellFontName
        let prevSize = currentCellFontSize
        applyCellFont(fetchFontName(handle),
                      size: CGFloat(tk_font_size(handle)))
        // Report the resolved effective + ideal sizes back to the core —
        // the Settings size stepper and "Restore ideal" button read these.
        tk_desktop_set_font_size_info(handle,
                                      Int64(cellFontEffectiveSize),
                                      Int64(cellFontIdealSize))
        return prevName != currentCellFontName
            || prevSize != currentCellFontSize
    }

    /// Refetch the active theme's palette if the Mojo core's theme version has
    /// moved. Returns true when the palette changed (so a redraw is warranted
    /// even if the cell buffer is byte-identical — a theme swap changes only
    /// the index→RGB mapping, not the indices in the buffer).
    @discardableResult
    private func refreshPaletteIfNeeded() -> Bool {
        guard handle != 0 else { return false }
        let v = tk_theme_version(handle)
        if v == themeVersion { return false }
        themeVersion = v
        var p = [UInt32](repeating: 0, count: 256)
        p.withUnsafeMutableBufferPointer { b in
            _ = tk_theme_palette(handle,
                                 Int64(Int(bitPattern: b.baseAddress)),
                                 Int64(b.count))
        }
        palette = p
        return true
    }

    // Change detection. There is no cursor blink, so an idle Desktop lays out
    // a byte-identical frame every tick — `pollFrame` hashes the laid-out
    // buffer and reports whether anything actually changed, letting the timer
    // skip the (expensive) Core Text draw when nothing did. When a change is
    // detected the buffer it produced is handed to the next `draw` verbatim
    // (`framePending`) so we tick + layout only once per presented frame.
    private var lastFrameHash: UInt64 = 0
    private var framePending = false
    private var frameCols = 0, frameRows = 0, frameN = 0

    private func hashBuf(_ words: Int) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for i in 0..<words { h = (h ^ UInt64(buf[i])) &* 0x100000001b3 }
        return h
    }

    override var isFlipped: Bool { true }            // y increases downward (row index)
    override var acceptsFirstResponder: Bool { true }
    override var wantsDefaultClipping: Bool { false }

    func cols() -> Int { max(1, Int(bounds.width / CELL_W)) }
    func rows() -> Int { max(1, Int(bounds.height / CELL_H)) }

    // Surface-aware C-ABI shims: `.main` drives the whole Desktop; `.panels`
    // draws only the tool panels and never ticks (the main window's tick runs
    // the shared Desktop's per-frame work for both surfaces).
    private func layoutSurface(_ c: Int, _ r: Int, _ cap: Int) -> Int {
        let p = Int64(Int(bitPattern: buf))
        switch surface {
        case .main:     return Int(tk_desktop_layout(handle, Int64(c), Int64(r), p, Int64(cap)))
        case .panels:   return Int(tk_desktop_layout_panels(handle, Int64(c), Int64(r), p, Int64(cap)))
        case .settings: return Int(tk_desktop_layout_settings(handle, Int64(c), Int64(r), p, Int64(cap)))
        case .projectSettings: return Int(tk_desktop_layout_project_settings(handle, Int64(c), Int64(r), p, Int64(cap)))
        }
    }
    private func tickSurface(_ c: Int, _ r: Int) {
        if surface == .main { tk_desktop_tick(handle, Int64(c), Int64(r)) }
    }
    private func keySurface(_ key: UInt32, _ m: UInt8, _ c: Int, _ r: Int) -> Int32 {
        switch surface {
        case .main:     return tk_desktop_key(handle, key, m, Int64(c), Int64(r))
        case .panels:   return tk_desktop_panels_key(handle, key, m, Int64(c), Int64(r))
        case .settings: return tk_desktop_settings_key(handle, key, m, Int64(c), Int64(r))
        case .projectSettings: return tk_desktop_project_settings_key(handle, key, m, Int64(c), Int64(r))
        }
    }
    private func modKeySurface(_ modId: UInt32, _ pressed: UInt8) -> Int32 {
        // Editors only live on the main Desktop surface; the floating
        // panels and Settings windows have no text editors, so a bare
        // modifier transition there has nothing to drive.
        switch surface {
        case .main: return tk_desktop_mod_key(handle, modId, pressed)
        default:    return 0
        }
    }
    private func mouseSurface(_ col: Int64, _ row: Int64, _ button: UInt8,
                              _ pressed: UInt8, _ motion: UInt8, _ m: UInt8,
                              _ c: Int, _ r: Int, _ cc: UInt8) -> Int32 {
        switch surface {
        case .main:     return tk_desktop_mouse(handle, col, row, button, pressed, motion, m, Int64(c), Int64(r), cc)
        case .panels:   return tk_desktop_panels_mouse(handle, col, row, button, pressed, motion, m, Int64(c), Int64(r), cc)
        case .settings: return tk_desktop_settings_mouse(handle, col, row, button, pressed, motion, m, Int64(c), Int64(r), cc)
        case .projectSettings: return tk_desktop_project_settings_mouse(handle, col, row, button, pressed, motion, m, Int64(c), Int64(r), cc)
        }
    }
    private func pointerShapeSurface(_ col: Int64, _ row: Int64, _ c: Int, _ r: Int) -> Int32 {
        switch surface {
        case .main:     return tk_desktop_pointer_shape(handle, col, row, Int64(c), Int64(r))
        case .panels:   return tk_desktop_panels_pointer_shape(handle, col, row, Int64(c), Int64(r))
        case .settings: return 0   // default arrow everywhere in Settings
        case .projectSettings: return 0   // default arrow everywhere here
        }
    }

    private func ensureBuf(_ cells: Int) {
        if cells > bufCells {
            buf.deallocate()
            buf = UnsafeMutablePointer<UInt32>.allocate(capacity: cells * CELL_WORDS)
            bufCells = cells
        }
    }

    /// Run the Mojo per-frame tick + layout into `buf` and report whether the
    /// resulting frame differs from the one last presented. The timer uses this
    /// to decide whether to invalidate the view: with no cursor blink an idle
    /// Desktop produces an identical frame, so we can skip the Core Text draw
    /// entirely. On a real change the buffer is kept for the next `draw`
    /// (`framePending`) so the frame is laid out exactly once.
    @discardableResult
    func pollFrame() -> Bool {
        guard handle != 0 else { return false }
        tickSurface(cols(), rows())
        return detectChange()
    }

    /// Bare tick with no layout / change detection — for views whose window
    /// is hidden or fully occluded. Keeps the Mojo state machines (pty
    /// drain, LSP, DAP) advancing so attention events (a Claude turn
    /// finishing, the debugger stopping) still fire and badge the Dock
    /// while the app is buried, without paying for Core Text repaints.
    func tickOnly() {
        guard handle != 0, surface == .main else { return }
        tickSurface(cols(), rows())
    }

    /// Lay out the current Desktop state and report whether it differs from
    /// what's on screen, caching the buffer for the next `draw` if so. Unlike
    /// `pollFrame` this does *not* run the async tick — callers that already
    /// know why the frame might have changed (a mouse/scroll event) use it to
    /// avoid a full repaint when the event didn't actually change anything.
    @discardableResult
    func detectChange() -> Bool {
        guard handle != 0 else { return false }
        // Font first — a swap changes CELL_W/CELL_H, and cols()/rows()
        // below must already see the new grid metrics.
        let fontChanged = refreshFontIfNeeded()
        let c = cols(), r = rows()
        ensureBuf(c * r)
        let n = layoutSurface(c, r, c * r)
        frameCols = c; frameRows = r; frameN = n
        let hash = hashBuf(n * CELL_WORDS)
        // A theme swap changes only the palette, not the laid-out indices, so
        // force a frame through even when the buffer hash is unchanged.
        let themeChanged = refreshPaletteIfNeeded()
        if hash == lastFrameHash && !themeChanged && !fontChanged { return false }
        lastFrameHash = hash
        framePending = true
        return true
    }

    /// Drop the cached frame so the next `draw` re-runs tick + layout. Input
    /// handlers call this because a key/mouse event mutates the Desktop, making
    /// any frame an earlier `pollFrame` left behind stale.
    func invalidateFrame() { framePending = false }

    /// Resolve a cell's foreground/background to 24-bit ``0xRRGGBB``, honoring
    /// the ``color_mode`` truecolor bits (real RGB from the per-cell fg_rgb /
    /// bg_rgb words) and the ``STYLE_REVERSE`` fg/bg swap. Non-truecolor
    /// channels look up the theme palette by index, as before.
    private func cellColors(_ p: UnsafeMutablePointer<UInt32>, _ i: Int)
        -> (fg: UInt32, bg: UInt32, style: UInt32) {
        let packed = p[i * CELL_WORDS + 1]
        let mode = (packed >> 24) & 0xFF
        let style = (packed >> 16) & 0xFF
        var fgIdx = Int(packed & 0xFF)
        // Bold (SGR 1) brightens the 8 base ANSI colors to their bright
        // variants (0..7 -> 8..15) — the classic terminal behavior, and how
        // bold reads here since the Px437 bitmap cell font has no heavier
        // weight. Truecolor / already-bright / 256-cube fg are left as-is.
        if style & STYLE_BOLD != 0 && (mode & FG_TRUECOLOR) == 0 && fgIdx < 8 {
            fgIdx += 8
        }
        var fg = (mode & FG_TRUECOLOR) != 0 ? p[i * CELL_WORDS + 3]
                                            : palette[fgIdx]
        var bg = (mode & BG_TRUECOLOR) != 0 ? p[i * CELL_WORDS + 4]
                                            : palette[Int((packed >> 8) & 0xFF)]
        if style & STYLE_REVERSE != 0 { swap(&fg, &bg) }
        // Faint (SGR 2): scale the foreground toward black. Claude Code paints
        // ghost/suggestion text dim, and without this it'd be indistinguishable
        // from normal input. Foreground only — faint never touches the bg.
        if style & STYLE_DIM != 0 { fg = dimmed(fg) }
        return (fg, bg, style)
    }

    /// Scale a packed ``0xRRGGBB`` toward black for SGR-2 faint text.
    private func dimmed(_ rgb: UInt32) -> UInt32 {
        let r = UInt32(Double((rgb >> 16) & 0xFF) * 0.6)
        let g = UInt32(Double((rgb >> 8) & 0xFF) * 0.6)
        let b = UInt32(Double(rgb & 0xFF) * 0.6)
        return (r << 16) | (g << 8) | b
    }

    override func draw(_ dirtyRect: NSRect) {
        guard handle != 0, let ctx = NSGraphicsContext.current?.cgContext else { return }
        refreshFontIfNeeded()
        refreshPaletteIfNeeded()
        // Px437 is a pixel font — render it crisp (no anti-aliasing / font
        // smoothing) or the bitmap glyphs come out blurred. Cells are on
        // integer pixel boundaries so hard-edged rasterization is exact.
        // Vector fonts (Settings ▸ Font) want the opposite: hard-edged
        // rasterization makes them jagged, so antialias those.
        let aa = !cellFontIsBitmap
        ctx.setShouldAntialias(aa)
        ctx.setShouldSmoothFonts(aa)
        ctx.setAllowsAntialiasing(aa)
        ctx.setAllowsFontSmoothing(aa)
        NSGraphicsContext.current?.shouldAntialias = aa
        let c = cols(), r = rows()
        ensureBuf(c * r)
        let n: Int
        if framePending && frameCols == c && frameRows == r {
            // The timer's pollFrame just laid this exact frame out — reuse it
            // rather than ticking + laying out a second time.
            n = frameN
        } else {
            tickSurface(c, r)
            n = layoutSurface(c, r, c * r)
            // Keep the change detector in sync with what we actually present so
            // the next pollFrame compares against this frame.
            frameCols = c; frameRows = r; frameN = n
            lastFrameHash = hashBuf(n * CELL_WORDS)
        }
        framePending = false

        // Clear to default background once.
        ctx.setFillColor(cgcolor(palette[0]))
        ctx.fill(bounds)

        drawCells(ctx, buf, n, c, originX: 0, originY: 0)
        // Smooth scroll: when the focused editor rests (or is being dragged)
        // at a sub-line offset, overdraw its body translated by the fraction.
        if surface == .main { compositeSmoothScroll(ctx, mainN: n, mainCols: c) }
        // Editor body popups (minimap tooltip / LSP hover) carry a translucent
        // drop shadow drawn here, after the main draw + smooth composite, so it
        // lands on the final (smooth-scrolled) body instead of a baked cell
        // shadow torn off the un-shifted frame. Runs at rest too (the composite
        // early-returns when not scrolling).
        if surface == .main { drawPopupShadow(ctx) }
        // First main-surface frame is now on screen. Kick the deferred
        // startup work (PATH recovery, font-family scan) on the next runloop
        // turn so it runs *after* this draw flushes — not inside it. One-shot
        // across all windows; async so the heavy work doesn't extend this draw.
        if surface == .main && !CellView.didFirstMainPaint {
            CellView.didFirstMainPaint = true
            DispatchQueue.main.async { AppController.shared?.afterFirstFrame() }
        }
    }
    static var didFirstMainPaint = false

    /// Paint `n` packed cells from buffer `p` (`c` columns) at pixel origin
    /// (`originX`, `originY`). Two passes — all backgrounds, then glyphs +
    /// underlines — so a wide emoji painted across two cells isn't clipped
    /// by the next cell's background fill. Shared by the full-frame draw
    /// (origin 0,0) and the smooth-scroll region composite (origin offset by
    /// the sub-line pixel fraction).
    private func drawCells(_ ctx: CGContext,
                           _ p: UnsafeMutablePointer<UInt32>,
                           _ n: Int, _ c: Int,
                           originX: CGFloat, originY: CGFloat) {
        for i in 0..<n {
            let (_, bg, _) = cellColors(p, i)
            if bg != palette[0] {
                let col = i % c, row = i / c
                let x = originX + CGFloat(col) * CELL_W
                let y = originY + CGFloat(row) * CELL_H
                ctx.setFillColor(cgcolor(bg))
                ctx.fill(CGRect(x: x, y: y, width: CELL_W, height: CELL_H))
            }
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: cellFont]
        for i in 0..<n {
            let cp = p[i * CELL_WORDS]
            let (fg, _, style) = cellColors(p, i)
            let col = i % c, row = i / c
            let x = originX + CGFloat(col) * CELL_W
            let y = originY + CGFloat(row) * CELL_H
            if cp != 0x20 && cp != 0, let scalar = Unicode.Scalar(cp) {
                let s = String(scalar) as NSString
                if charWidth(cp) == 2 {
                    drawEmoji(s, cellX: x, cellY: y, cellW: CELL_W * 2)
                } else if cellFontHasGlyph(cp) {
                    var a = attrs
                    a[.foregroundColor] = nscolor(fg)
                    s.draw(at: NSPoint(x: x, y: y), withAttributes: a)
                } else {
                    drawFallbackGlyph(ctx, s, fg: fg, cellX: x, cellY: y)
                }
            }
            if style & STYLE_UNDERLINE != 0 {
                let uw = p[i * CELL_WORDS + 2]
                let uc = uw == 0xFFFFFFFF ? fg : palette[Int(uw & 0xFF)]
                ctx.setFillColor(cgcolor(uc))
                ctx.fill(CGRect(x: x, y: y + CELL_H - 2, width: CELL_W, height: 1))
            }
        }
    }

    // MARK: - Smooth (pixel-level) scrolling

    /// One editor scroll region as reported by `tk_editor_scroll_regions`.
    /// `sub` + `frac` are in *visual rows*: the overdraw render is shifted up
    /// by `(sub + frac) * CELL_H` and clipped to the interior rect.
    private struct SmoothRegion {
        var winIdx: Int, x: Int, y: Int, w: Int, h: Int
        var sub: Int, frac: CGFloat
        // Sticky-scroll header rows pinned at the interior top, and the
        // right-edge minimap gutter — both fixed (scrollbar-like). The
        // compositor leaves them to the main paint and only translates the
        // scrolling body between them.
        var nSticky: Int, rightGutter: Int
    }

    /// Query the focused editor's smooth-scroll region (phase one reports at
    /// most one — the focused, frontmost editor). nil when nothing is
    /// eligible (non-editor focus, an overlay is up, or the completion popup
    /// is open). Works for wrapped and non-wrapped editors alike.
    private func focusedSmoothRegion() -> SmoothRegion? {
        guard handle != 0, surface == .main else { return nil }
        var rec = [Int32](repeating: 0, count: 9)
        let n = rec.withUnsafeMutableBufferPointer { b in
            Int(tk_editor_scroll_regions(handle, Int64(cols()), Int64(rows()),
                Int64(Int(bitPattern: b.baseAddress)), 1))
        }
        guard n >= 1 else { return nil }
        return SmoothRegion(
            winIdx: Int(rec[0]), x: Int(rec[1]), y: Int(rec[2]),
            w: Int(rec[3]), h: Int(rec[4]), sub: Int(rec[5]),
            frac: CGFloat(rec[6]) / 1000.0, nSticky: Int(rec[7]),
            rightGutter: Int(rec[8]))
    }

    private func ensureRegionBuf(_ cells: Int) {
        if cells > regionBufCells {
            regionBuf.deallocate()
            regionBuf = UnsafeMutablePointer<UInt32>.allocate(
                capacity: cells * CELL_WORDS)
            regionBufCells = cells
        }
    }

    /// After the full-frame draw, overdraw the focused editor's body shifted
    /// up by `(sub + frac)` visual rows. The core renders the body taller by
    /// `sub + 2` rows (`tk_editor_region_layout`) so the segments shifted off
    /// the top, the partially-visible bottom line, and a rubber-band gap all
    /// have content to slide into the clip.
    private func compositeSmoothScroll(_ ctx: CGContext, mainN: Int, mainCols: Int) {
        guard let r = focusedSmoothRegion(),
              (r.frac != 0 || r.sub != 0), r.w > 0, r.h > 0 else { return }
        let regionRows = r.sub + r.h + 2
        ensureRegionBuf(r.w * regionRows)
        let cells = Int(tk_editor_region_layout(
            handle, Int64(r.winIdx), Int64(r.w), Int64(regionRows),
            Int64(Int(bitPattern: regionBuf)), Int64(r.w * regionRows)))
        // Clip to the scrolling body only — between the fixed regions the
        // main paint owns: below the pinned sticky-scroll band (top) and left
        // of the minimap gutter (right). The overdraw render suppressed its
        // own band, and the minimap columns are simply excluded, so the body
        // (text + left line-number/debug gutters) slides cleanly between them.
        let bodyTop = CGFloat(r.y + r.nSticky) * CELL_H
        let clip = CGRect(x: CGFloat(r.x) * CELL_W, y: bodyTop,
                          width: CGFloat(r.w - r.rightGutter) * CELL_W,
                          height: CGFloat(r.h - r.nSticky) * CELL_H)
        ctx.saveGState()
        ctx.clip(to: clip)
        // Fill the clip with editor background so a rubber-band gap past the
        // first / last line reads as empty editor space, not desktop bg.
        ctx.setFillColor(cgcolor(palette[EDITOR_BG_IDX]))
        ctx.fill(clip)
        drawCells(ctx, regionBuf, cells, r.w,
                  originX: CGFloat(r.x) * CELL_W,
                  originY: CGFloat(r.y) * CELL_H
                      - (CGFloat(r.sub) + r.frac) * CELL_H)
        ctx.restoreGState()
        // The overdraw above suppressed the editor's screen-anchored overlays
        // (minimap/diagnostic/spell tooltip, LSP hover popup) and just painted
        // over them — they don't scroll with the body. The main frame already
        // rendered the popup box into `buf` (shadow excluded — host_owns_shadows;
        // drawPopupShadow paints it later as a translucent layer), so re-blit
        // just that box on top, untranslated. (Clip + redraw the whole main
        // buffer: only the overlay box cells land.)
        var ob = [Int32](repeating: 0, count: 4)
        let hasOverlay = ob.withUnsafeMutableBufferPointer { b in
            Int(tk_editor_overlay_bounds(handle, Int64(cols()), Int64(rows()),
                Int64(Int(bitPattern: b.baseAddress))))
        }
        if hasOverlay == 1 {
            let oclip = CGRect(x: CGFloat(ob[0]) * CELL_W, y: CGFloat(ob[1]) * CELL_H,
                               width: CGFloat(ob[2]) * CELL_W,
                               height: CGFloat(ob[3]) * CELL_H)
            ctx.saveGState()
            ctx.clip(to: oclip)
            drawCells(ctx, buf, mainN, mainCols, originX: 0, originY: 0)
            ctx.restoreGState()
        }
    }

    /// Translucent drop shadow under the focused editor's body popup (minimap
    /// tooltip / LSP hover). With `host_owns_shadows` the core paints the popup
    /// box only and `tk_editor_overlay_bounds` reports that box; we darken the
    /// classic Turbo Vision L-strips (2 cells right from one row down, 1 row
    /// below shifted right 2 — matching `paint_drop_shadow`) as a real alpha
    /// layer over whatever the body composited beneath. Because it darkens the
    /// live pixels, it tracks the sub-cell smooth scroll instead of tearing.
    /// The strips sit outside the box, so drawing last never covers it.
    private func drawPopupShadow(_ ctx: CGContext) {
        guard handle != 0, surface == .main else { return }
        var ob = [Int32](repeating: 0, count: 4)
        let has = ob.withUnsafeMutableBufferPointer { b in
            Int(tk_editor_overlay_bounds(handle, Int64(cols()), Int64(rows()),
                Int64(Int(bitPattern: b.baseAddress))))
        }
        guard has == 1, ob[2] > 0, ob[3] > 0 else { return }
        // Clip to the editor interior so the shadow can't bleed past the popup's
        // reserved right margin onto chrome / the next pane. No region (a rare
        // edge: completion popup open over a lingering minimap tooltip) → skip
        // the shadow rather than draw it unclipped.
        guard let r = focusedSmoothRegion() else { return }
        let bx = CGFloat(ob[0]), by = CGFloat(ob[1])
        let bw = CGFloat(ob[2]), bh = CGFloat(ob[3])
        ctx.saveGState()
        ctx.clip(to: CGRect(x: CGFloat(r.x) * CELL_W, y: CGFloat(r.y) * CELL_H,
                            width: CGFloat(r.w) * CELL_W,
                            height: CGFloat(r.h) * CELL_H))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.5))
        // Right strip: 2 cells wide, from one row below the top to the bottom.
        if bh > 1 {
            ctx.fill(CGRect(x: (bx + bw) * CELL_W, y: (by + 1) * CELL_H,
                            width: 2 * CELL_W, height: (bh - 1) * CELL_H))
        }
        // Bottom strip: 1 row tall, shifted right by 2 for the diagonal lift.
        ctx.fill(CGRect(x: (bx + 2) * CELL_W, y: (by + bh) * CELL_H,
                        width: bw * CELL_W, height: CELL_H))
        ctx.restoreGState()
    }

    /// Damped overscroll distance (in visual rows) for a raw overshoot past
    /// an edge — the classic rubber-band curve, asymptotic to `dim` rows.
    private func rubberBand(_ x: CGFloat) -> CGFloat {
        let dim: CGFloat = 4.0, c: CGFloat = 0.55
        return (1 - 1 / (x / dim * c + 1)) * dim
    }

    /// Push the current continuous position (`smoothLines`, in visual rows)
    /// into the core: damp any overshoot past the [0, max] range, then store
    /// the absolute visual-row coordinate (the core maps it to a buffer-line
    /// + sub-row anchor) and request a repaint.
    private func applySmooth() {
        guard smoothWinIdx >= 0 else { return }
        let maxV = CGFloat(smoothMax)
        var displayed = smoothLines
        if smoothLines < 0 {
            displayed = -rubberBand(-smoothLines)
        } else if smoothLines > maxV {
            displayed = maxV + rubberBand(smoothLines - maxV)
        }
        tk_editor_smooth_set(handle, Int64(smoothWinIdx),
                             Int64(cols()), Int64(rows()),
                             Int64(displayed * 1000))
        needsDisplay = true
    }

    private func cancelSpring() {
        springTimer?.invalidate(); springTimer = nil
    }

    /// Ease `smoothLines` toward `target` over a few frames (exponential),
    /// applying each step to the core. Drives both the post-gesture
    /// rubber-band release and discrete mouse-wheel notches (which retarget
    /// mid-flight — calling this again just updates `springTarget`, the
    /// running timer keeps converging). Runs in `.common` mode so it keeps
    /// ticking during tracking.
    private func easeTo(_ target: CGFloat, speed: CGFloat = 0.30) {
        springTarget = target
        springSpeed = speed
        if springTimer != nil { return }
        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] tm in
            guard let self = self else { tm.invalidate(); return }
            self.smoothLines += (self.springTarget - self.smoothLines) * self.springSpeed
            if abs(self.smoothLines - self.springTarget) < 0.01 {
                self.smoothLines = self.springTarget
                self.applySmooth()
                tm.invalidate(); self.springTimer = nil
            } else {
                self.applySmooth()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        springTimer = t
    }

    /// Display width of a codepoint in grid cells: 2 for the emoji blocks
    /// terminals render double-wide, 1 otherwise. Ported verbatim from
    /// `char_width` in `string_utils.mojo` — the two MUST agree, or the Mojo
    /// core's cell layout and this renderer disagree on where glyphs land.
    private func charWidth(_ cp: UInt32) -> Int {
        if cp < 0x231A { return 1 }
        switch cp {
        case 0x231A, 0x231B, 0x2329, 0x232A,
             0x23F0, 0x23F3,
             0x25FD, 0x25FE, 0x2614, 0x2615,
             0x267F, 0x2693, 0x26A1, 0x26AA, 0x26AB,
             0x26BD, 0x26BE, 0x26C4, 0x26C5, 0x26CE, 0x26D4, 0x26EA,
             0x26F2, 0x26F3, 0x26F5, 0x26FA, 0x26FD,
             0x2705, 0x270A, 0x270B, 0x2728, 0x274C, 0x274E,
             0x2757, 0x27B0, 0x27BF,
             0x2B1B, 0x2B1C, 0x2B50, 0x2B55,
             0x1F004, 0x1F0CF, 0x1F18E:
            return 2
        default:
            break
        }
        if (0x23E9...0x23EC).contains(cp) { return 2 }
        if (0x2648...0x2653).contains(cp) { return 2 }
        if (0x2753...0x2755).contains(cp) { return 2 }
        if (0x2795...0x2797).contains(cp) { return 2 }
        if (0x1F191...0x1F19A).contains(cp) { return 2 }
        if (0x1F200...0x1F2FF).contains(cp) { return 2 }
        if (0x1F300...0x1F64F).contains(cp) { return 2 }
        if (0x1F680...0x1F6FF).contains(cp) { return 2 }
        if (0x1F900...0x1F9FF).contains(cp) { return 2 }
        if (0x1FA70...0x1FAFF).contains(cp) { return 2 }
        return 1
    }

    /// Draw a color-emoji glyph shrunk to fit a `cellW`×`CELL_H` box, centered.
    /// Apple Color Emoji at the cell-font point size massively overflows the
    /// cell; emoji glyph metrics scale linearly with point size, so we measure
    /// at a reference size and pick the size whose rendered glyph fits within
    /// (cellW, CELL_H). Reserving two cells (cellW = 2·CELL_W) gives the glyph
    /// a near-square box, so it renders far larger than in a single cell.
    private func drawEmoji(_ s: NSString, cellX x: CGFloat, cellY y: CGFloat,
                           cellW: CGFloat) {
        let ref: CGFloat = CELL_H
        let probe = s.size(withAttributes: [.font: NSFont.systemFont(ofSize: ref)])
        guard probe.width > 0, probe.height > 0 else { return }
        let scale = min(cellW / probe.width, CELL_H / probe.height)
        let font = NSFont.systemFont(ofSize: max(1, ref * scale))
        let glyph = s.size(withAttributes: [.font: font])
        s.draw(at: NSPoint(x: x + (cellW - glyph.width) / 2,
                           y: y + (CELL_H - glyph.height) / 2),
               withAttributes: [.font: font])
    }

    /// Draw a single-width codepoint the cell font has no glyph for. Letting
    /// `NSString.draw` pick its own Core Text fallback renders it with foreign
    /// metrics that overflow the cell and overdraw the neighbour (so the same
    /// codepoint looks different depending on what's beside it — the symptom on
    /// `m³`, U+00B3, which is absent from the CP437 bitmap font). Render it via
    /// a monospaced fallback scaled to fit, centered, and clipped to the one
    /// cell so it stays put regardless of context.
    private func drawFallbackGlyph(_ ctx: CGContext, _ s: NSString, fg: UInt32,
                                   cellX x: CGFloat, cellY y: CGFloat) {
        let ref: CGFloat = CELL_H
        let baseFont = NSFont.monospacedSystemFont(ofSize: ref, weight: .regular)
        let probe = s.size(withAttributes: [.font: baseFont])
        guard probe.width > 0, probe.height > 0 else { return }
        let scale = min(1, min(CELL_W / probe.width, CELL_H / probe.height))
        let font = NSFont.monospacedSystemFont(
            ofSize: max(1, ref * scale), weight: .regular)
        let g = s.size(withAttributes: [.font: font])
        ctx.saveGState()
        ctx.clip(to: CGRect(x: x, y: y, width: CELL_W, height: CELL_H))
        s.draw(at: NSPoint(x: x + (CELL_W - g.width) / 2,
                           y: y + (CELL_H - g.height) / 2),
               withAttributes: [.font: font, .foregroundColor: nscolor(fg)])
        ctx.restoreGState()
    }

    // MARK: input

    private func mods(_ e: NSEvent) -> UInt8 {
        var m: UInt8 = 0
        let f = e.modifierFlags
        if f.contains(.shift) { m |= MOD_SHIFT }
        if f.contains(.option) { m |= MOD_ALT }
        if f.contains(.control) { m |= MOD_CTRL }
        if f.contains(.command) { m |= MOD_META }
        return m
    }

    private func specialKey(_ code: UInt16) -> UInt32? {
        switch code {
        case 36, 76: return KEY_ENTER
        case 48: return KEY_TAB
        case 51: return KEY_BACKSPACE
        case 53: return KEY_ESC
        case 123: return KEY_LEFT
        case 124: return KEY_RIGHT
        case 125: return KEY_DOWN
        case 126: return KEY_UP
        case 115: return KEY_HOME
        case 119: return KEY_END
        case 116: return KEY_PAGEUP
        case 121: return KEY_PAGEDOWN
        case 117: return KEY_DELETE
        case 114: return KEY_INSERT
        case 122: return KEY_F1
        case 120: return KEY_F1 + 1
        case 99:  return KEY_F1 + 2
        case 118: return KEY_F1 + 3
        case 96:  return KEY_F1 + 4
        case 97:  return KEY_F1 + 5
        case 98:  return KEY_F1 + 6
        case 100: return KEY_F1 + 7
        case 101: return KEY_F1 + 8
        case 109: return KEY_F1 + 9
        case 103: return KEY_F1 + 10
        case 111: return KEY_F1 + 11
        default: return nil
        }
    }

    override func keyDown(with event: NSEvent) {
        // Capture runs are scripted via env (TK_OPEN / TK_CAPTURE_ACTIONS);
        // the window briefly steals focus on the user's desktop, so any
        // typing mid-run would land in the staged buffer — and autosave
        // would write it to the real file on disk. Drop keyboard input
        // entirely while capturing.
        if ProcessInfo.processInfo.environment["TK_CAPTURE"] != nil { return }
        var key: UInt32 = 0
        if let sp = specialKey(event.keyCode) {
            key = sp
        } else if let ch = event.charactersIgnoringModifiers, let sc = ch.unicodeScalars.first {
            key = sc.value
        }
        if key == 0 { return }
        let action = keySurface(key, mods(event), cols(), rows())
        handleAction(action)
        invalidateFrame()
        needsDisplay = true
    }

    /// Forward inserted text — emoji palette / Character Viewer (which deliver
    /// via NSTextInputClient.insertText, never keyDown) — to the Mojo core one
    /// Unicode scalar at a time. The core's key path takes a single codepoint
    /// per call and the editor buffer is byte-addressed, so feeding each scalar
    /// in order reconstructs multi-scalar sequences (ZWJ emoji, flags) byte for
    /// byte. mods=0: palette text carries no modifier semantics.
    func insertScalars(_ s: String) {
        if ProcessInfo.processInfo.environment["TK_CAPTURE"] != nil { return }
        if s.isEmpty { return }
        for scalar in s.unicodeScalars {
            handleAction(keySurface(scalar.value, 0, cols(), rows()))
        }
        invalidateFrame()
        needsDisplay = true
    }

    override func flagsChanged(with event: NSEvent) {
        // See keyDown — scripted capture runs ignore live input.
        if ProcessInfo.processInfo.environment["TK_CAPTURE"] != nil { return }
        // flagsChanged fires for *every* modifier transition; keep the live
        // Shift state current (scrollWheel reads it) before isolating Option's
        // own up/down edges by diffing against the last state.
        shiftDown = event.modifierFlags.contains(.shift)
        let nowDown = event.modifierFlags.contains(.option)
        if nowDown == optionDown { return }   // some other modifier moved
        optionDown = nowDown
        let action = modKeySurface(MOD_KEY_ALT, nowDown ? 1 : 0)
        handleAction(action)
        invalidateFrame()
        needsDisplay = true
    }

    private func sendMouse(_ e: NSEvent, button: UInt8, pressed: UInt8, motion: UInt8,
                           passive: Bool = false) {
        // See keyDown — scripted capture runs ignore live input.
        if ProcessInfo.processInfo.environment["TK_CAPTURE"] != nil { return }
        let p = convert(e.locationInWindow, from: nil)
        // Window-border vertical scrollbar thumb drag: while one is in flight
        // (started by the press hit-test in the core), route motion through
        // the sub-cell path with the raw pointer Y so a long file scrolls
        // line-by-line instead of ~150 lines per (cell-quantized) thumb cell.
        if surface == .main && button == 1 && motion == 1 && sbDragging {
            _ = tk_desktop_vscroll_drag(handle, Int64((p.y / CELL_H) * 1000))
            needsDisplay = true
            return
        }
        // Minimap gutter: a plain click jumps to the item under it — we let
        // the press fall through to the normal dispatch so the core's
        // _try_minimap_click moves the cursor there and golden-reveals it.
        // A left-*drag* that began on the gutter instead scrubs the scroll
        // proportionally from the raw (sub-cell) pointer Y, bypassing the
        // cell-quantized core hit-test (without which the minimap maps one
        // whole cell row to lines/height lines — ~100+ on a 10k-line file —
        // so the smallest drag step jumps that far).
        if surface == .main && button == 1 {
            if pressed == 1 && motion == 0 {
                // Fresh press: arm a potential scrub-drag if it landed on the
                // gutter, but do NOT scroll yet — fall through so the core
                // handles the click as a jump. Only later motion scrubs.
                minimapDragging = false
                if let sr = focusedSmoothRegion(), sr.rightGutter > 0 {
                    let c = Int(max(0, p.x) / CELL_W), r = Int(max(0, p.y) / CELL_H)
                    if c >= sr.x + sr.w - sr.rightGutter && c < sr.x + sr.w
                        && r >= sr.y && r < sr.y + sr.h {
                        minimapDragging = true
                    }
                }
            } else if minimapDragging {
                // In-flight scrub: motion scrolls proportionally, release ends it.
                if pressed == 0 {
                    minimapDragging = false      // released — fall through so
                    // the core sees the release and clears the drag latch its
                    // matching press armed (via _handle_press).
                } else if let sr = focusedSmoothRegion() {
                    let top = CGFloat(sr.y) * CELL_H
                    let hgt = max(1, CGFloat(sr.h) * CELL_H)
                    var f = (p.y - top) / hgt
                    if f < 0 { f = 0 }; if f > 1 { f = 1 }
                    // Micro precision: a 1000-step (milli) fraction quantizes
                    // a 10k-row file to ~10-row stops; micro maps at pointer
                    // (sub-pixel on Retina) resolution so the drag glides.
                    tk_editor_minimap_to(handle, Int64(sr.winIdx),
                                         Int64(f * 1_000_000))
                    needsDisplay = true
                    return
                } else {
                    return
                }
            }
        }
        let col = Int64(max(0, p.x) / CELL_W)
        var py = max(0, p.y)
        // When the focused editor rests at a smooth-scroll offset its body is
        // drawn shifted up by (sub + frac)*CELL_H; nudge a click/drag's
        // pixel-Y by the same amount so the cell row maps to the line that's
        // visually under the pointer (passive hover doesn't need precision).
        if !passive && surface == .main, let sr = focusedSmoothRegion(),
           sr.sub != 0 || sr.frac != 0 {
            let cc0 = Int(max(0, p.x) / CELL_W), rr0 = Int(py / CELL_H)
            // Only within the scrolling body — not the fixed sticky band
            // (top) or minimap gutter (right), where a click maps straight
            // through (jump to header / scroll-to-here).
            if cc0 >= sr.x && cc0 < sr.x + sr.w - sr.rightGutter
                && rr0 >= sr.y + sr.nSticky && rr0 < sr.y + sr.h {
                py = max(0, py + (CGFloat(sr.sub) + sr.frac) * CELL_H)
            }
        }
        let row = Int64(py / CELL_H)
        if passive {
            // Coalesce bare motion to cell granularity — see lastPassiveCol.
            if col == lastPassiveCol && row == lastPassiveRow { return }
            lastPassiveCol = col; lastPassiveRow = row
        } else {
            // A button event can change hover/shape without a position change
            // (e.g. release ending a drag); don't let the passive cache stale
            // it out. Reset so the next bare move always re-dispatches.
            lastPassiveCol = -1; lastPassiveRow = -1
        }
        // Consecutive-press count for double-click detection. AppKit already
        // tracks this against the system double-click speed; the Mojo core
        // expects it stamped only on genuine button presses (0 for motion /
        // release / wheel), matching the terminal frontend's contract. Read
        // e.clickCount only for real mouse buttons (1–3) — AppKit raises if
        // it's read on a scroll-wheel event (which reaches here as button 4/5).
        let cc: UInt8 = (pressed == 1 && motion == 0 && button >= 1 && button <= 3)
            ? UInt8(min(255, max(0, e.clickCount))) : 0
        let action = mouseSurface(col, row, button, pressed, motion,
                                  mods(e), cols(), rows(), cc)
        handleAction(action)
        // A left press that landed on the v-scrollbar thumb starts a drag in
        // the core; latch it so subsequent motion takes the sub-cell path
        // above. Any release ends it.
        if surface == .main && button == 1 {
            if pressed == 1 && motion == 0 {
                sbDragging = tk_desktop_vscroll_active(handle) != 0
            } else if pressed == 0 {
                sbDragging = false
            }
        }
        // Cursor hint.
        let shape = pointerShapeSurface(col, row, cols(), rows())
        switch shape {
        case 1: NSCursor.iBeam.set()
        case 2: NSCursor.pointingHand.set()
        default: NSCursor.arrow.set()
        }
        if passive {
            // Bare mouse motion (no button). macOS delivers these at the
            // display refresh rate; laying out + repainting the whole Desktop
            // on each one is what pegs a core when you jiggle the mouse. The
            // Mojo side has been told the new position (hover state) and the
            // cursor shape is set — that's all that must happen synchronously.
            // Any resulting visual change is caught by the timer's pollFrame
            // at its gated cadence; noteActivity keeps that at full 20 Hz
            // while the mouse is moving so hover feedback stays prompt.
            AppController.shared?.noteActivity()
        } else if detectChange() {
            // Clicks / drags / scroll: repaint only if the event actually
            // changed what's on screen.
            needsDisplay = true
        }
    }

    override func mouseDown(with e: NSEvent) { sendMouse(e, button: 1, pressed: 1, motion: 0) }
    override func mouseDragged(with e: NSEvent) { sendMouse(e, button: 1, pressed: 1, motion: 1) }
    override func mouseUp(with e: NSEvent) { sendMouse(e, button: 1, pressed: 0, motion: 0) }
    override func rightMouseDown(with e: NSEvent) { sendMouse(e, button: 3, pressed: 1, motion: 0) }
    override func rightMouseUp(with e: NSEvent) { sendMouse(e, button: 3, pressed: 0, motion: 0) }
    override func mouseMoved(with e: NSEvent) { sendMouse(e, button: 0, pressed: 0, motion: 1, passive: true) }
    override func scrollWheel(with e: NSEvent) {
        // Scripted capture runs ignore live input (matches sendMouse).
        if ProcessInfo.processInfo.environment["TK_CAPTURE"] != nil { return }
        let dx = e.scrollingDeltaX
        let dy = e.scrollingDeltaY
        let shift = shiftDown || e.modifierFlags.contains(.shift)
        if ProcessInfo.processInfo.environment["TK_SCROLL_DEBUG"] != nil {
            FileHandle.standardError.write("DBGSCROLL dx=\(dx) dy=\(dy) shift=\(shift) precise=\(e.hasPreciseScrollingDeltas) phase=\(e.phase.rawValue) mom=\(e.momentumPhase.rawValue)\n".data(using: .utf8)!)
        }
        // A zero-delta event still matters at gesture/momentum end — that's
        // when an out-of-range smooth scroll starts its rubber-band spring.
        if dx == 0 && dy == 0 && e.phase != .ended && e.phase != .cancelled
            && e.momentumPhase != .ended { return }

        // Horizontal scroll: an explicit horizontal swipe, or Shift+wheel (the
        // GUI convention — macOS reports the held-Shift scroll on either axis
        // depending on the device). Scrolls the focused editor's scroll_x
        // directly (never the vertical smooth-scroll path).
        if shift || abs(dx) > abs(dy) {
            // With Shift held the intended magnitude is the wheel's natural
            // axis (dy) unless macOS already swapped it onto dx.
            let amount = abs(dx) > abs(dy) ? dx : dy
            if amount != 0 { horizontalScroll(e, delta: amount) }
            return
        }

        // Smooth pixel scrolling: a precise device (trackpad / Magic Mouse)
        // over the focused editor body. Everything else — legacy wheels, or
        // the pointer over a terminal / output pane or a non-focused editor —
        // falls back to discrete notch scrolling, which the core routes by
        // pointer position.
        if surface == .main, let r = focusedSmoothRegion() {
            let p = convert(e.locationInWindow, from: nil)
            let col = Int(max(0, p.x) / CELL_W), row = Int(max(0, p.y) / CELL_H)
            if col >= r.x && col < r.x + r.w && row >= r.y && row < r.y + r.h {
                if e.hasPreciseScrollingDeltas {
                    smoothScroll(e, region: r)      // trackpad: continuous 1:1
                } else {
                    wheelScroll(e, region: r)        // mouse wheel: eased notches
                }
                return
            }
        }
        // End any in-flight smooth gesture cleanly before handing off so the
        // next precise event over the editor re-seeds from the core.
        smoothActive = false
        legacyNotchScroll(e)
    }

    /// Mouse-wheel (non-precise) scroll of the focused editor. Each detent
    /// moves the OS-reported line delta (typically ~1 line, scaled by the
    /// system scroll-speed setting) — not the core's fixed 3-line notch — and
    /// the move is *eased* so it glides sub-line rather than snapping. The
    /// target accumulates across detents so a fast spin stays responsive.
    private func wheelScroll(_ e: NSEvent, region r: SmoothRegion) {
        if e.scrollingDeltaY == 0 { return }
        // Seed from the core when starting fresh (no precise gesture or ease
        // already in flight), so the target tracks the real current position.
        if springTimer == nil && !smoothActive {
            var m = [Int32](repeating: 0, count: 2)
            m.withUnsafeMutableBufferPointer { b in
                _ = tk_editor_smooth_begin(handle, Int64(r.winIdx),
                    Int64(cols()), Int64(rows()),
                    Int64(Int(bitPattern: b.baseAddress)))
            }
            smoothWinIdx = r.winIdx
            smoothLines = CGFloat(m[0]) / 1000.0
            smoothMax = Int(m[1]) / 1000
            springTarget = smoothLines
        }
        // One line per unit of line-based delta (positive = up). The core's
        // old path forced 3 lines a notch; this honors the OS granularity.
        var t = springTarget - e.scrollingDeltaY
        if t < 0 { t = 0 }
        if t > CGFloat(smoothMax) { t = CGFloat(smoothMax) }
        easeTo(t)
    }

    /// Continuous trackpad scroll of the focused editor: track the gesture
    /// 1:1 in fractional visual rows, push the absolute visual-row position
    /// into the core, and spring back from any rubber-band overshoot at the
    /// end. Works for wrapped and non-wrapped editors — the core resolves the
    /// visual-row coordinate to a buffer-line + sub-row anchor.
    private func smoothScroll(_ e: NSEvent, region r: SmoothRegion) {
        // A fresh finger-down pre-empts any in-flight rubber-band release.
        if e.phase == .began { smoothReleasing = false }
        // Once a release is latched, swallow the whole momentum tail — letting
        // any of it through would re-seed past the edge and bounce again. The
        // latch is held until the inertia stream ends (or a new gesture), NOT
        // until the spring settles, since the spring finishes long before
        // momentum decays.
        if smoothReleasing {
            if e.momentumPhase == .ended { smoothReleasing = false }
            return
        }
        cancelSpring()
        if e.phase == .began || !smoothActive {
            // Seed the continuous position + clamp from the core (O(lines)
            // once per gesture for a wrapped editor; trivial otherwise).
            var m = [Int32](repeating: 0, count: 2)
            m.withUnsafeMutableBufferPointer { b in
                _ = tk_editor_smooth_begin(handle, Int64(r.winIdx),
                    Int64(cols()), Int64(rows()),
                    Int64(Int(bitPattern: b.baseAddress)))
            }
            smoothWinIdx = r.winIdx
            smoothLines = CGFloat(m[0]) / 1000.0
            smoothMax = Int(m[1]) / 1000
            smoothActive = true
        }
        // Positive scrollingDeltaY scrolls up (toward the top), matching the
        // legacy notch path's button-4/5 sign convention.
        smoothLines -= e.scrollingDeltaY / CELL_H
        // Bound the raw overshoot (see `smoothOvershootCap`) so a hard flick's
        // momentum can't strand the spring-back behind a long flat dwell.
        let maxV = CGFloat(smoothMax)
        if smoothLines < -smoothOvershootCap {
            smoothLines = -smoothOvershootCap
        } else if smoothLines > maxV + smoothOvershootCap {
            smoothLines = maxV + smoothOvershootCap
        }
        applySmooth()
        // Bounce back the moment fingers are up (post-lift *or* momentum) and
        // we're past an edge — don't wait for momentum to fully decay. Latch
        // `smoothReleasing` so the remaining momentum tail can't re-pin us.
        let dragging = e.phase == .began || e.phase == .changed
        if !dragging && (smoothLines < 0 || smoothLines > maxV) {
            smoothActive = false
            smoothReleasing = true
            easeTo(smoothLines < 0 ? 0 : maxV, speed: 0.45)
        } else if e.phase == .ended || e.phase == .cancelled
            || e.momentumPhase == .ended {
            // In range at gesture end: rest at the sub-line offset.
            smoothActive = false
        }
    }

    /// Discrete notch scrolling — the original behavior. Each emitted notch
    /// scrolls 3 lines in the core (editor.mojo). Precise deltas are
    /// integrated and emitted one notch per ~2 cell-rows of travel so speed
    /// tracks the gesture; legacy wheels report line detents (one per click).
    private func legacyNotchScroll(_ e: NSEvent) {
        // Drop the fractional carry at the start of a fresh gesture so
        // leftover momentum from a previous flick can't bleed into this one.
        if e.phase == .began { scrollAccumY = 0 }
        let dy = e.scrollingDeltaY
        if dy == 0 { return }
        let perNotch: CGFloat = e.hasPreciseScrollingDeltas ? CELL_H * 2 : 1
        scrollAccumY += dy
        while abs(scrollAccumY) >= perNotch {
            let up = scrollAccumY > 0
            sendMouse(e, button: up ? 4 : 5, pressed: 1, motion: 0)
            scrollAccumY += up ? -perNotch : perNotch
        }
    }

    /// Horizontal scroll of the *focused* editor (not the pointer's window —
    /// matches the vertical smooth-scroll target). `delta > 0` (content/finger
    /// moving right) scrolls the view left; `delta < 0` scrolls right, matching
    /// AppKit's scroll-axis sign. A precise device integrates pixels into whole
    /// columns (1 column per cell-width of travel); a legacy wheel moves a few
    /// columns per line detent.
    private func horizontalScroll(_ e: NSEvent, delta: CGFloat) {
        if e.phase == .began { scrollAccumX = 0 }
        var cols = 0
        if e.hasPreciseScrollingDeltas {
            scrollAccumX += delta
            let perCol = max(1, CELL_W)
            while abs(scrollAccumX) >= perCol {
                cols += scrollAccumX > 0 ? -1 : 1   // delta>0 → scroll left
                scrollAccumX += scrollAccumX > 0 ? -perCol : perCol
            }
        } else {
            // Legacy wheel: each line detent is ~3 columns, like the 3-line
            // vertical notch.
            cols = delta > 0 ? -3 : 3
        }
        if cols == 0 { return }
        if tk_desktop_hscroll_by(handle, Int64(cols),
                                 Int64(self.cols()), Int64(rows())) != 0 {
            needsDisplay = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for ta in trackingAreas { removeTrackingArea(ta) }
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect], owner: self))
    }

    // --- Drag-and-drop -----------------------------------------------------
    // Dropping file(s) inserts their path(s) where they land. Over a *terminal
    // pane* the paths go in shell-escaped, as a bracketed paste — the gesture a
    // terminal emulator supports, so a shell / Claude session receives them as
    // if typed. Over an *editor body* a small menu offers full path / filename
    // / project-relative path, and the chosen form is inserted verbatim at the
    // drop point. The Mojo core owns the hit-test (tk_desktop_drop_target); the
    // host just routes by its answer. Settings windows don't accept drops.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && (surface == .main || surface == .panels) {
            registerForDraggedTypes([.fileURL])
        }
    }

    /// Drop cell under the drag/drop location, mapped the same way as sendMouse.
    private func dropCell(_ sender: NSDraggingInfo) -> (Int64, Int64) {
        let p = convert(sender.draggingLocation, from: nil)
        return (Int64(max(0, p.x) / CELL_W), Int64(max(0, p.y) / CELL_H))
    }

    private func droppedURLs(_ sender: NSDraggingInfo) -> [URL] {
        return (sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// 0 = nothing droppable, 1 = terminal pane, 2 = editor body.
    private func dropTargetSurface(_ col: Int64, _ row: Int64) -> Int32 {
        switch surface {
        case .main:   return tk_desktop_drop_target(handle, col, row, Int64(cols()), Int64(rows()))
        case .panels: return tk_desktop_panels_drop_target(handle, col, row, Int64(cols()), Int64(rows()))
        default:      return 0
        }
    }

    // Show the copy cursor only over a real target (terminal pane or editor) so
    // dragging over the file tree / chrome reads as "no drop", not a false +.
    private func dragOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard handle != 0, !droppedURLs(sender).isEmpty else { return [] }
        let (col, row) = dropCell(sender)
        return dropTargetSurface(col, row) != 0 ? .copy : []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return dragOperation(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return dragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard handle != 0 else { return false }
        let urls = droppedURLs(sender)
        guard !urls.isEmpty else { return false }
        let (col, row) = dropCell(sender)
        let consumed: Bool
        switch dropTargetSurface(col, row) {
        case 1:  consumed = dropOnTerminal(urls, col, row)
        case 2:  consumed = dropOnEditor(urls, col, row, at: sender.draggingLocation)
        default: return false
        }
        guard consumed else { return false }
        invalidateFrame()
        needsDisplay = true
        return true
    }

    /// Terminal pane: hand the raw paths to the core, which shell-escapes and
    /// pastes them (full path, the terminal drag convention — no menu).
    private func dropOnTerminal(_ urls: [URL], _ col: Int64, _ row: Int64) -> Bool {
        let bytes = Array(urls.map { $0.path }.joined(separator: "\n").utf8)
        let r = bytes.withUnsafeBufferPointer { b -> Int32 in
            let ptr = Int64(Int(bitPattern: b.baseAddress)), len = Int64(bytes.count)
            switch surface {
            case .main:   return tk_desktop_drop_paths(handle, col, row, ptr, len, Int64(cols()), Int64(rows()))
            case .panels: return tk_desktop_panels_drop_paths(handle, col, row, ptr, len, Int64(cols()), Int64(rows()))
            default:      return 0
            }
        }
        return r != 0
    }

    // The editor format-choice menu: dropChoice is stamped by the menu action
    // (which fires synchronously inside NSMenu.popUp) and read back after.
    private var dropChoice: Int32 = -1
    @objc private func chooseDropFormat(_ sender: NSMenuItem) { dropChoice = Int32(sender.tag) }

    /// Pop the path-format menu at `point` (view coords) and return the chosen
    /// tag (0 = full path, 1 = filename, 2 = project-relative) or -1 if the
    /// user dismissed it. popUp is modal, so chooseDropFormat has fired by the
    /// time it returns. Shared by drag-drop and file-paste into editors.
    private func choosePathFormat(at point: NSPoint) -> Int32 {
        let menu = NSMenu()
        for (title, tag) in [("Insert full path", 0), ("Insert filename", 1)] {
            let mi = NSMenuItem(title: title, action: #selector(chooseDropFormat(_:)), keyEquivalent: "")
            mi.target = self; mi.tag = tag; menu.addItem(mi)
        }
        // Relative path only makes sense with a project open; otherwise it
        // would just duplicate "full path".
        if project != nil {
            let mi = NSMenuItem(title: "Insert path relative to project",
                                action: #selector(chooseDropFormat(_:)), keyEquivalent: "")
            mi.target = self; mi.tag = 2; menu.addItem(mi)
        }
        dropChoice = -1
        menu.popUp(positioning: nil, at: point, in: self)
        return dropChoice
    }

    /// Editor body: pick a format and insert the result verbatim at the drop
    /// point (the core moves the caret there first).
    private func dropOnEditor(_ urls: [URL], _ col: Int64, _ row: Int64,
                              at location: NSPoint) -> Bool {
        let fmt = choosePathFormat(at: convert(location, from: nil))
        guard fmt >= 0 else { return false }   // dismissed without choosing
        let text = urls.map { formatPath($0, fmt) }.joined(separator: " ")
        let bytes = Array(text.utf8)
        let r = bytes.withUnsafeBufferPointer { b -> Int32 in
            tk_desktop_insert_text(handle, col, row,
                                   Int64(Int(bitPattern: b.baseAddress)),
                                   Int64(bytes.count), Int64(cols()), Int64(rows()))
        }
        return r != 0
    }

    /// Cmd+V / Edit▸Paste of file(s) on the clipboard (e.g. copied in Finder):
    /// offer the same format menu as a drop and insert the chosen form at the
    /// caret. Returns true when it handled the paste (including a cancelled
    /// menu); false to let the normal text paste proceed — no file on the
    /// clipboard, or the focus isn't an editor.
    func pasteFilesWithMenu() -> Bool {
        guard surface == .main, handle != 0,
              tk_desktop_paste_target_is_editor(handle) != 0 else { return false }
        guard let urls = NSPasteboard.general.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        // No caret rect is exposed, so anchor the menu at the pointer.
        let anchor: NSPoint = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) }
            ?? NSPoint(x: bounds.midX, y: bounds.midY)
        let fmt = choosePathFormat(at: anchor)
        guard fmt >= 0 else { return true }   // cancelled — swallow, don't text-paste
        let text = urls.map { formatPath($0, fmt) }.joined(separator: " ")
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { b in
            tk_desktop_paste_text(handle, Int64(Int(bitPattern: b.baseAddress)), Int64(bytes.count))
        }
        invalidateFrame()
        needsDisplay = true
        return true
    }

    /// Normal text paste (Cmd+V / Edit▸Paste): read the pasteboard as a string
    /// and normalize to NFC before handing it to the core. macOS routinely
    /// stores text decomposed (e.g. "a" + U+030A combining ring for "å"); the
    /// bitmap font has no glyph for a lone combining mark, so an unnormalized
    /// paste renders as "?". `precomposedStringWithCanonicalMapping` is
    /// Foundation's complete, correct NFC. Returns true when the core consumed
    /// the paste; false (no string on the pasteboard / nothing focused) lets
    /// the caller fall back to the in-core clipboard path.
    func pasteTextNormalized() -> Bool {
        guard handle != 0,
              let s = NSPasteboard.general.string(forType: .string) else { return false }
        let text = s.precomposedStringWithCanonicalMapping
        let bytes = Array(text.utf8)
        let consumed = bytes.withUnsafeBufferPointer { b in
            tk_desktop_paste_clipboard_text(
                handle, Int64(Int(bitPattern: b.baseAddress)), Int64(bytes.count))
        }
        return consumed != 0
    }

    private func formatPath(_ url: URL, _ fmt: Int32) -> String {
        switch fmt {
        case 1: return url.lastPathComponent
        case 2:
            if let p = project {
                let base = p.hasSuffix("/") ? p : p + "/"
                if url.path.hasPrefix(base) { return String(url.path.dropFirst(base.count)) }
            }
            return url.path   // no project, or file outside it → full path
        default: return url.path
        }
    }

    // AppKit may only invalidate the newly-exposed strip during a live resize,
    // leaving the rest of the view with stale (stretched) content. Force a
    // full redraw on every size change so the Desktop reflows live.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    func handleAction(_ code: Int32) {
        // Actions from the panel surface route to the project window's view so
        // an open-file (etc.) lands there, not in the panel window.
        AppController.shared?.handleAction(code, view: mainPeer ?? self)
    }

    func capturePNG(to path: String) {
        // Render the grab into an explicitly hi-DPI bitmap rather than
        // `bitmapImageRepForCachingDisplay`, whose 1× point-resolution grab
        // leaves the 8×16 pixel font soft once a viewer scales the PNG. We
        // allocate `scale`× the pixels (2× by default; TK_CAPTURE_SCALE
        // overrides), then drive the normal `draw(_:)` through a CTM scaled +
        // flipped to match the view — so the no-AA pixel font lands on integer
        // pixel boundaries and each glyph pixel becomes a crisp scale×scale block.
        let scale = max(1, Int(ProcessInfo.processInfo.environment["TK_CAPTURE_SCALE"]
                                ?? "2") ?? 2)
        let pw = Int((bounds.width * CGFloat(scale)).rounded())
        let ph = Int((bounds.height * CGFloat(scale)).rounded())
        guard pw > 0, ph > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0),
              let base = NSGraphicsContext(bitmapImageRep: rep) else { return }
        // 1 unit == 1 pixel in the rep's context; our CTM does points→pixels.
        rep.size = NSSize(width: pw, height: ph)
        let cg = base.cgContext
        cg.scaleBy(x: CGFloat(scale), y: CGFloat(scale))   // points → pixels
        cg.translateBy(x: 0, y: bounds.height)             // flip y to match
        cg.scaleBy(x: 1, y: -1)                            // the flipped view
        // Wrap the y-flipped CG context as a *flipped* NSGraphicsContext so
        // NSString.draw() lays glyphs out right-side-up (text honors the NS
        // context's flippedness, not just the raw CTM).
        let nsctx = NSGraphicsContext(cgContext: cg, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsctx
        draw(bounds)
        nsctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

// Text-input client conformance exists solely so the macOS emoji palette /
// Character Viewer have a valid client to deliver into — without it the palette
// targets nothing and a double-clicked emoji is silently dropped. Regular keys
// keep flowing through keyDown directly (we never call interpretKeyEvents), so
// there's no double-insertion. We don't implement marked-text/IME composition;
// the stubs report "no marked text" so AppKit treats every insertText as final.
extension CellView: NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        if let attr = string as? NSAttributedString { insertScalars(attr.string) }
        else if let s = string as? String { insertScalars(s) }
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}
    func unmarkText() {}
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { false }
    func attributedSubstring(forProposedRange range: NSRange,
                             actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange,
                   actualRange: NSRangePointer?) -> NSRect {
        // Best-effort caret anchor for any IME candidate window; the emoji
        // palette positions itself and ignores this.
        guard let win = window else { return .zero }
        return win.convertToScreen(convert(NSRect(x: 0, y: 0, width: 1, height: CELL_H),
                                           to: nil))
    }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
}

// NSWindow that honors a programmatically-restored frame verbatim, even on a
// secondary display. AppKit's default `constrainFrameRect(_:to:)` keeps the
// title bar on the "current" screen, which yanks a window saved on a secondary
// monitor back onto the primary one as it's positioned/ordered at launch. The
// floating-panels window is always placed from saved per-display-config
// geometry that's been visibility-checked against the attached screens
// (`frameIsVisible`), so the constraint only does harm here — opt out of it.
final class UnconstrainedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }
}

// MARK: - App controller: windows + Mojo desktops + render timer

final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    static var shared: AppController?
    var windows: [NSWindow] = []
    var views: [CellView] = []
    var timer: Timer?
    var persistSession = false   // off for one-off file opens, on for sessions/projects
    var isTerminating = false    // suppress per-window session saves during quit
    // Filesystem paths handed to us via application(_:open:) — Dock
    // drag-and-drop and "Open With". They can arrive before launch
    // finishes (delegate is wired before app.run()), so we buffer them
    // here and either drain them or use them in place of session restore
    // once applicationDidFinishLaunching runs. `didFinishLaunchingDone`
    // flips true at the end of launch so later drops open immediately.
    private var pendingOpenPaths: [String] = []
    // turbokod://open?file=X&line=N URLs that arrived before launch
    // finished (e.g. a click on a link is what cold-launched the app).
    // Unlike dropped paths, these do NOT suppress session restore — we
    // want the restored project windows to exist so the URL's file can
    // route into the right one. Drained after restore in didFinishLaunching.
    private var pendingOpenURLs: [URL] = []
    private var didFinishLaunchingDone = false
    // Debouncer for windowDidResize/windowDidMove — AppKit fires these every
    // frame during a live resize; debouncing keeps us from rewriting the
    // per-project JSON hundreds of times per drag. Keyed by NSWindow identity
    // so two windows resized simultaneously don't share a timer.
    private var frameSaveTimers: [ObjectIdentifier: Timer] = [:]
    // Floating panels: the separate tool-panel window for a project window,
    // keyed by ObjectIdentifier(mainView). Its CellView is `.panels` and
    // shares the main view's Desktop handle. Absent ⇒ panels are docked.
    // See docs/floating-panels.md.
    private var panels: [ObjectIdentifier: (window: NSWindow, view: CellView)] = [:]
    // Standalone Settings windows, one per project window (keyed by the main
    // view, like `panels`). Opened/closed by polling tk_desktop_settings_active
    // each tick — the Mojo side opens Settings via the menu action and closes
    // it via Esc / its Close button, so the host can't know without asking.
    private var settingsWins: [ObjectIdentifier: (window: NSWindow, view: CellView)] = [:]
    // Standalone Project Settings windows — twin of `settingsWins`, polled via
    // tk_desktop_project_settings_active. Keep the two in lock-step.
    private var projectSettingsWins: [ObjectIdentifier: (window: NSWindow, view: CellView)] = [:]
    // Menu mirror: the snapshot from Mojo's menu_bar, hashed so we only
    // rebuild NSMenu when something actually changed (focus/visibility/
    // checkmark/edit-extras flips). `menuTracking` is set while AppKit is
    // displaying an open NSMenu — pausing rebuilds then so the dropdown
    // doesn't get yanked out from under the user mid-click.
    private var menuBuf: [UInt8] = [UInt8](repeating: 0, count: 8192)
    private var lastMenuHash: UInt64 = 0
    private var menuTracking = false
    // Idle backoff for the redraw timer. With no cursor blink, a still Desktop
    // needs no repaint at all, so once frames have been identical for ~1s we
    // poll at ~4 Hz instead of 20 Hz (and skip even that work when nothing
    // changes). Any visible change resets `idleTicks` to 0 → full rate.
    private var idleTicks = 0
    private var tickSeq = 0
    // Running Dock-badge count. Attention events (a Claude session in a
    // terminal pane finishing its turn, the debugger hitting a stop) are
    // drained from every project Desktop once per tick; while the app is
    // in the background each batch bounces the Dock icon and adds to this
    // count. While frontmost the events are discarded — the user is
    // already looking. Cleared (badge removed) when the app activates.
    private var attentionBadge = 0

    private func drainAttention() {
        var n = 0
        for v in views where v.handle != 0 {
            n += Int(tk_desktop_take_attention(v.handle))
        }
        guard n > 0, !NSApp.isActive else { return }
        attentionBadge += n
        NSApp.dockTile.badgeLabel = String(attentionBadge)
        NSApp.requestUserAttention(.informationalRequest)
    }

    /// Nudge the redraw timer out of deep idle on activity that doesn't
    /// itself trigger a redraw — notably bare mouse motion.
    ///
    /// It deliberately does NOT force full 20 Hz. Profiling showed that
    /// pinning 20 Hz during continuous mouse movement spent ~6% of a core
    /// laying out + hashing the whole Desktop every tick purely to detect
    /// change — and `draw` almost never fired, i.e. the frame rarely
    /// actually changed. Hover hints are dwell-based and don't need 20 Hz,
    /// and the cursor *shape* is set synchronously in `sendMouse`, not by
    /// this timer. So we clamp into the medium (~10 Hz) tier: prompt enough
    /// for hover, half the repaint cost. A frame that genuinely changes
    /// still resets `idleTicks` to 0 (full rate) via the timer body below.
    func noteActivity() { if idleTicks > 30 { idleTicks = 30 } }
    // Always-alive Mojo Desktop used to drive the menu bar when no window
    // is open. Without it, closing the last window (or starting with an
    // empty session) leaves NSApp.mainMenu pointing at items wired to
    // `menuActionFired`, which used to bail when `views` was empty —
    // turning Cmd+Q + Project ▸ Recent into no-ops. The chrome desktop
    // is created in applicationDidFinishLaunching, has host_owns_menu
    // set, and loads config so its menu snapshot reflects the real
    // recent-projects list.
    private var chromeDesktop: Int64 = 0

    // The monospace-family scan (FontCatalog) is ~140 ms and only feeds the
    // Settings ▸ Font picker, so newWindow defers it past the first frame
    // (see afterFirstFrame). This flips true once the scan has run; windows
    // opened after that apply the (now-cached) list inline.
    private var fontOptionsReady = false

    // Launch-time window/project opening, deferred until the app first becomes
    // active so it lands *with* the menu install (in the didBecomeActive
    // handler) rather than before it. One-shot: cleared the first time it runs.
    private var pendingLaunchOpen: (() -> Void)?

    private func runPendingLaunchOpen() {
        guard let work = pendingLaunchOpen else { return }
        pendingLaunchOpen = nil
        work()
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        AppController.shared = self
        // Disable macOS window/state restoration ("Resume"). We persist and
        // restore our own session (per-project, in the Mojo core), so the
        // system's restoration is redundant — and after an abnormal exit it
        // pops the "reopen windows?" alert, which does nothing useful here and
        // blocks startup. Turning it off means macOS never saves restorable
        // state and never shows that dialog. Paired with isRestorable=false on
        // each window (newWindow) so no per-window state is written either.
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
        chdirToResourceRoot()
        installCliHelperIfNeeded()
        buildMenu()
        // Initialize the chrome Desktop before any session restore so its
        // menu snapshot is ready to drive NSApp.mainMenu the moment we
        // have zero windows (empty session, or last window closed).
        chromeDesktop = tk_desktop_new()
        // The slow startup work — the user's interactive $PATH recovery
        // (~100 ms login shell) and the monospace-family scan (~140 ms) — is
        // deferred until the first frame is on screen (afterFirstFrame), so
        // the project window paints (syntax-colored) before either runs.
        // tk_desktop_new already did the cheap synchronous PATH prepend, so an
        // LSP server in a standard location still resolves even if a spawn
        // somehow beats the full recovery. The first-frame hook lives at the
        // end of CellView.draw.
        if chromeDesktop != 0 {
            tk_desktop_set_host_owns_menu(chromeDesktop, 1)
            tk_desktop_set_host_owns_shadows(chromeDesktop, 1)
            // The chrome Desktop loaded the user config — apply the saved
            // cell font + size now so the first window opens with the right
            // grid metrics instead of reflowing one frame in.
            applyCellFont(fetchFontName(chromeDesktop),
                          size: CGFloat(tk_font_size(chromeDesktop)))
        }

        let args = CommandLine.arguments
        // Everything that creates a window (opening a project / file / drop /
        // restoring the session) is deferred to the next runloop turn. Ordering
        // a window front *during* launch makes the window server composite it
        // before it repaints the menu bar, so the macOS menu visibly lags the
        // window. The no-project path feels instant precisely because it opens
        // no window here — so we mimic it: install the (chrome) menu and return
        // now, letting the bar draw immediately, then open the project a beat
        // later. The menu updates to its project form once the window exists.
        let openWork: () -> Void = { [weak self] in
            guard let self else { return }
            if args.count > 1 {
                let p = args[1]
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: p, isDirectory: &isDir)
                if isDir.boolValue {
                    // CLI ``./run_swift.sh /path/to/project`` — pre-apply the
                    // project's remembered frame so it opens at its previous
                    // size, not the 1000×640 default.
                    self.persistSession = true
                    let v = self.newWindow(frame: self.loadProjectFrame(p))
                    self.openProject(v, p)
                } else {
                    let v = self.newWindow()
                    self.openFile(v, p)
                }
            } else if !self.pendingOpenPaths.isEmpty {
                // Launched by dropping folders/files on the Dock icon (or
                // "Open With"). Open those instead of restoring the previous
                // session — the drop is the explicit intent.
                self.persistSession = true
                let dropped = self.pendingOpenPaths
                self.pendingOpenPaths.removeAll()
                for p in dropped { self.openDroppedPath(p) }
            } else {
                self.persistSession = true
                let saved = self.loadSession()
                // Empty session: leave zero windows. The macOS menu bar stays
                // up (sourced from chromeDesktop) so the user can quit, open
                // a project, or pick a recent project.
                for entry in saved {
                    // Per-project file wins; ``native_session.txt``'s frame
                    // is the legacy fallback for projects that haven't yet
                    // written the new file (first launch after upgrade).
                    let frame = self.loadProjectFrame(entry.project) ?? entry.frame
                    let v = self.newWindow(frame: frame)
                    self.openProject(v, entry.project)
                }
            }
            // From here on, drops open immediately rather than buffering.
            // Drain anything that raced in during launch setup.
            self.didFinishLaunchingDone = true
            let late = self.pendingOpenPaths
            self.pendingOpenPaths.removeAll()
            for p in late { self.openDroppedPath(p) }
            // Drain turbokod:// URLs after session restore so they can route
            // into restored project windows.
            let lateURLs = self.pendingOpenURLs
            self.pendingOpenURLs.removeAll()
            for u in lateURLs { self.openTurbokodURL(u) }
            // The project window now exists — update the menu to reflect it
            // (in-place submenu swap when titles match; a full rebuild when the
            // editor-dependent Edit/View/Git/Debug menus appear).
            self.refreshMenu()
        }

        // Run the window/project work the first time the app becomes active —
        // from the didBecomeActive handler, right after the menu installs — so
        // the menu (drawn with the now-resolved appearance, correct colors) and
        // the window land together. Doing it as a plain async instead lets the
        // window beat didBecomeActive, so it appears well ahead of the menu;
        // doing it pre-active draws the menu bar with inverted colors. A short
        // fallback covers launches that never activate (e.g. headless capture),
        // so the window always opens.
        pendingLaunchOpen = openWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.runPendingLaunchOpen()
        }

        // Schedule in .common mode (not just default) so the timer also fires
        // during the modal event-tracking run loop AppKit uses for live
        // resize, window dragging, menus, etc. Without this, async-driven
        // redraws (LSP/terminal output, external file changes) would freeze
        // during those operations.
        //
        // The body is gated on visibility so an idle, hidden, or fully
        // occluded app doesn't burn CPU at 20 Hz. Concretely:
        //   - When NSApp is hidden (Cmd+H), do nothing — no menu, no
        //     windows, nothing to paint.
        //   - When NSApp is not active (another app is frontmost), skip
        //     refreshMenu — our menu isn't being shown anyway; it'll
        //     refresh on the next tick after we regain focus (≤50 ms).
        //   - Only set ``needsDisplay = true`` for views whose window is
        //     visible AND not fully covered by other windows. Hidden /
        //     occluded views would otherwise drive a full ``tk_desktop_tick``
        //     + ``tk_desktop_layout`` + canvas repaint every 50 ms even
        //     though nothing visible would change.
        // The user observed high idle CPU when the app was buried behind
        // other windows; this is what closes that.
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.tickSeq &+= 1
            if NSApp.isHidden {
                // Hidden (Cmd+H): no menu, no windows, nothing to paint —
                // but keep the Mojo state machines advancing at the deep-
                // idle rate so attention events (a Claude turn finishing,
                // a debugger stop) still bounce + badge the Dock.
                if self.tickSeq % 5 == 0 {
                    for v in self.views { v.tickOnly() }
                    self.drainAttention()
                }
                return
            }
            // Three-tier backoff. The work below — tick + layout + the menu
            // snapshot — is what costs CPU; running it less often when nothing
            // is visibly changing is the whole game. Any frame that actually
            // changes resets idleTicks to 0 (full rate); `noteActivity`
            // (bare mouse motion) clamps into the medium tier rather than
            // forcing full rate, since hover hints don't need 20 Hz.
            //   idleTicks 0–20  : full 20 Hz (something is visibly changing)
            //   idleTicks 21–60 : ~10 Hz     (mouse moving, frame steady)
            //   idleTicks >60   : ~4 Hz      (deep idle)
            // Async work (LSP, terminal, external edits) still surfaces within
            // ~100–250 ms at the lower tiers.
            if self.idleTicks > 60 {
                if self.tickSeq % 5 != 0 { return }
            } else if self.idleTicks > 20 {
                if self.tickSeq % 2 != 0 { return }
            }

            var changed = false
            if NSApp.isActive && self.refreshMenu() { changed = true }
            // Scripted captures (TK_CAPTURE) must keep ticking even when the
            // window is occluded or the display is asleep — the DAP/LSP state
            // machines only advance inside tk_desktop_tick, and a capture
            // waiting on TK_CAPTURE_WHEN=debug-stopped would otherwise stall
            // until the watchdog kills the session.
            let capturing = ProcessInfo.processInfo.environment["TK_CAPTURE"] != nil
            // Only the key window's Desktop should animate its caret — with
            // several projects open each runs its own Desktop, and a blink
            // in a background window reads as a second live cursor. Stamp
            // every view's focus state so background editors fall back to a
            // steady caret.
            let keyWin = NSApp.isActive ? NSApp.keyWindow : nil
            for v in self.views where v.handle != 0 {
                tk_desktop_set_host_focused(v.handle, (v.window === keyWin) ? 1 : 0)
                // The user just explicitly opened a new terminal pane. When the
                // tool panels float on their own window, in-process focus isn't
                // enough — make that window key so the shell is typeable without
                // a click. Always drain (even when docked, where focus already
                // works in-core) so the one-shot flag can't fire stale later.
                if tk_desktop_take_panel_focus_request(v.handle) != 0 {
                    if let pair = self.panels[ObjectIdentifier(v)] {
                        pair.window.makeKeyAndOrderFront(nil); changed = true
                    }
                }
                // A target run / test / debug just (re)started. Raise the
                // floating panel window so the output is visible even when it's
                // buried behind other windows — orderFront, not makeKey, so
                // keyboard focus stays in the editor (the auto-show poll only
                // fires on the empty→non-empty transition, missing restarts).
                // Always drain so the one-shot can't fire stale later.
                if tk_desktop_take_panel_front_request(v.handle) != 0 {
                    if let pair = self.panels[ObjectIdentifier(v)] {
                        pair.window.orderFront(nil); changed = true
                    }
                }
                // A link click / command-line open just jumped to a line in
                // this view's editor. Raise the main window to the front +
                // key — the click may have come from the floating panels
                // window sitting on top of it. Always drain so the one-shot
                // flag can't fire stale later (no-op when docked + frontmost).
                if tk_desktop_take_main_focus_request(v.handle) != 0 {
                    NSApp.activate(ignoringOtherApps: true)
                    v.window?.makeKeyAndOrderFront(nil); changed = true
                }
            }
            for v in self.views {
                guard let w = v.window, w.isVisible,
                      capturing || w.occlusionState.contains(.visible) else {
                    // Not paintable (miniaturized / fully covered) — bare-
                    // tick so background work keeps advancing and attention
                    // events still fire while the window is buried.
                    v.tickOnly()
                    continue
                }
                // Only mark for redraw when the laid-out frame actually
                // differs from what's on screen — no cursor blink means an
                // idle frame is identical and needs no Core Text repaint.
                if v.pollFrame() { v.needsDisplay = true; changed = true }
            }
            // Panel windows share the main Desktop and don't tick (pollFrame on
            // a `.panels` view only re-lays-out), so the main window's tick
            // above already advanced the shared state — here we just detect
            // whether the panel surface needs a repaint.
            for pair in self.panels.values {
                let pv = pair.view
                // Auto-hide: with no tool panels open the floating window has
                // nothing to show, so order it out (the Desktop stays detached
                // — floating mode is still on). Show it again the moment a
                // panel reopens. orderFront, not makeKey, to avoid yanking
                // focus off the editor. See docs/floating-panels.md.
                let hasPanels = pv.handle != 0
                    && tk_desktop_panels_visible_count(pv.handle) > 0
                if hasPanels {
                    if !pair.window.isVisible { pair.window.orderFront(nil); changed = true }
                } else if pair.window.isVisible {
                    pair.window.orderOut(nil); changed = true; continue
                }
                guard let w = pv.window, w.isVisible,
                      w.occlusionState.contains(.visible) else { continue }
                if pv.pollFrame() { pv.needsDisplay = true; changed = true }
            }
            // Settings window lifecycle: the Mojo side opens Settings via the
            // menu action and closes it via Esc / its Close button — poll the
            // active flag and open/close the NSWindow on transitions.
            for v in self.views where v.handle != 0 {
                let id = ObjectIdentifier(v)
                let active = tk_desktop_settings_active(v.handle) != 0
                if active && self.settingsWins[id] == nil {
                    self.showSettingsWindow(for: v); changed = true
                } else if !active, self.settingsWins[id] != nil {
                    self.closeSettingsWindow(for: v); changed = true
                }
            }
            // Like the panel views, settings views share the main Desktop and
            // don't tick — just detect whether the surface needs a repaint.
            for pair in self.settingsWins.values {
                let sv = pair.view
                guard let w = sv.window, w.isVisible,
                      w.occlusionState.contains(.visible) else { continue }
                if sv.pollFrame() { sv.needsDisplay = true; changed = true }
            }
            // Project Settings window lifecycle — twin of the Settings block.
            for v in self.views where v.handle != 0 {
                let id = ObjectIdentifier(v)
                let active = tk_desktop_project_settings_active(v.handle) != 0
                if active && self.projectSettingsWins[id] == nil {
                    self.showProjectSettingsWindow(for: v); changed = true
                } else if !active, self.projectSettingsWins[id] != nil {
                    self.closeProjectSettingsWindow(for: v); changed = true
                }
            }
            for pair in self.projectSettingsWins.values {
                let sv = pair.view
                guard let w = sv.window, w.isVisible,
                      w.occlusionState.contains(.visible) else { continue }
                if sv.pollFrame() { sv.needsDisplay = true; changed = true }
            }
            self.drainAttention()
            self.idleTicks = changed ? 0 : self.idleTicks &+ 1
        }
        RunLoop.current.add(t, forMode: .common)
        timer = t

        // When the app regains focus or a window emerges from occlusion,
        // refresh immediately rather than waiting up to 50 ms for the
        // next tick. Without this the menu / cursor briefly show stale
        // state on Cmd+Tab back to TurboKod.
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification,
                       object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.idleTicks = 0   // run full-rate after refocus
            // The user is looking again — retire the attention badge.
            self.attentionBadge = 0
            NSApp.dockTile.badgeLabel = nil
            // Install/refresh the menu FIRST (app is active now, so it draws
            // with correct colors — no pre-active inverted-color blink).
            self.refreshMenu()
            // THEN, once the menu bar has had a moment to actually draw, load
            // the saved projects. This is the order the app must boot in:
            // stabilize with a menu, *then* open windows. Opening a window in
            // the same runloop turn as the menu install lets the window server
            // composite the window before it repaints the menu bar, so the menu
            // appears to pop in only after the project loads. The short gap
            // sequences it correctly. One-shot (pendingLaunchOpen self-clears);
            // a no-op on later Cmd+Tab-back activations.
            if self.pendingLaunchOpen != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.runPendingLaunchOpen()
                }
            }
            // The user may have committed / checked out / edited files in
            // another app while we were backgrounded; force the git change
            // gutters to re-diff against HEAD instead of waiting on the 1 Hz
            // mtime poll (which a worktree-only edit doesn't even trip).
            for v in self.views { tk_desktop_refresh_git(v.handle) }
            for v in self.views { v.invalidateFrame(); v.needsDisplay = true }
        }
        nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                       object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let w = note.object as? NSWindow,
                  w.occlusionState.contains(.visible),
                  let v = w.contentView as? CellView else { return }
            self.idleTicks = 0
            v.invalidateFrame()
            v.needsDisplay = true
        }
        // Display connect/disconnect / resolution change: re-evaluate every
        // open project against the now-current configuration, floating or
        // docking its panels per the saved per-config layout. This is what
        // makes unplugging the external display fall back to docked.
        nc.addObserver(self, selector: #selector(screenParametersChanged(_:)),
                       name: NSApplication.didChangeScreenParametersNotification,
                       object: nil)

        if let cap = ProcessInfo.processInfo.environment["TK_CAPTURE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                self.runCaptureScene(to: cap)
            }
        }
    }

    // MARK: scripted screenshot capture (TK_CAPTURE)

    // Drive a scene before the TK_CAPTURE grab, all via env vars so
    // scripts/screenshots.sh can stage README shots without poking at
    // saved sessions:
    //   TK_OPEN="path[:line]"      open a file (absolute path; 1-based
    //                              line) in the first window's Desktop.
    //   TK_CAPTURE_ACTIONS="a,b"   menu actions invoked in order, 0.3 s
    //                              apart, through the same
    //                              tk_desktop_menu_invoke path a click
    //                              would take (e.g. "debug:toggle_bp,
    //                              debug:start_or_continue").
    //   TK_QUICK_OPEN              legacy alias for
    //                              TK_CAPTURE_ACTIONS=file:quick_open.
    //   TK_CAPTURE_WHEN=debug-stopped
    //                              poll tk_desktop_debug_stopped until the
    //                              debugger pauses (breakpoint hit), then
    //                              settle 1 s so the stack/variables panes
    //                              populate before the grab.
    //   TK_CAPTURE_TIMEOUT=secs    give up on the WHEN condition after
    //                              this long (default 30) — capture
    //                              anyway with a warning so the script
    //                              still produces an inspectable PNG.
    //   TK_CAPTURE_DELAY=secs      extra settle before the grab (async
    //                              indexers, LSP, etc.).
    //   TK_QUIT_VIA=close          quit via red-button close instead of
    //                              NSApp.terminate.
    private func runCaptureScene(to cap: String) {
        let env = ProcessInfo.processInfo.environment
        if let spec = env["TK_OPEN"], let v = views.first {
            // "path[:line]" — only treat the suffix as a line number when
            // it parses, so plain paths containing ':' still open.
            var path = spec
            var line0 = 0
            if let idx = spec.lastIndex(of: ":"),
               let n = Int(spec[spec.index(after: idx)...]), n > 0 {
                path = String(spec[..<idx])
                line0 = n - 1
            }
            openFileAt(v, path, line0, 0)
        }
        var actions = (env["TK_CAPTURE_ACTIONS"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if env["TK_QUICK_OPEN"] != nil { actions.insert("file:quick_open", at: 0) }
        invokeCaptureActions(actions, then: {
            let timeout = env["TK_CAPTURE_TIMEOUT"].flatMap(Double.init) ?? 30.0
            self.awaitCaptureCondition(env["TK_CAPTURE_WHEN"], timeout: timeout) {
                let extra = env["TK_CAPTURE_DELAY"].flatMap(Double.init) ?? 0.0
                DispatchQueue.main.asyncAfter(deadline: .now() + extra) {
                    self.views.first?.capturePNG(to: cap)
                    print("captured to \(cap)")
                    // TK_QUIT_VIA=close simulates the red-button close on the
                    // last window (exercises the session-save-before-remove
                    // path). Default: NSApp.terminate (the Cmd+Q path).
                    if env["TK_QUIT_VIA"] == "close" {
                        self.windows.first?.performClose(nil)
                    } else {
                        NSApp.terminate(nil)
                    }
                }
            }
        })
    }

    // Fire each action 0.3 s after the previous so the 20 Hz tick runs
    // between them — debug:start_or_continue must see the breakpoint
    // debug:toggle_bp just registered.
    private func invokeCaptureActions(_ actions: [String], then done: @escaping () -> Void) {
        guard let action = actions.first, let v = views.first else { done(); return }
        let bytes = Array(action.utf8)
        _ = bytes.withUnsafeBufferPointer { b in
            tk_desktop_menu_invoke(v.handle,
                Int64(Int(bitPattern: b.baseAddress)),
                Int64(bytes.count),
                Int64(v.cols()), Int64(v.rows()))
        }
        v.needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.invokeCaptureActions(Array(actions.dropFirst()), then: done)
        }
    }

    private func awaitCaptureCondition(_ cond: String?, timeout: Double,
                                       _ done: @escaping () -> Void) {
        guard cond == "debug-stopped", let v = views.first else { done(); return }
        if tk_desktop_debug_stopped(v.handle) != 0 {
            // Paused — give the stack / variables / debug pane a beat to
            // fetch and paint before the grab.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: done)
            return
        }
        if timeout <= 0 {
            print("warning: TK_CAPTURE_WHEN=debug-stopped never satisfied; capturing anyway")
            done()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.awaitCaptureCondition(cond, timeout: timeout - 0.25, done)
        }
    }

    // MARK: native menu

    // The native NSMenu mirrors Mojo's `menu_bar`. We snapshot it via
    // `tk_desktop_menu_snapshot` (TSV) and rebuild whenever the snapshot's
    // content hash changes. Items dispatch through `menuActionFired`, which
    // calls `tk_desktop_menu_invoke` — the same `dispatch_action` path the
    // in-grid menu would have taken — and routes any leftover host-level
    // action code through `handleAction`.
    func buildMenu() {
        // Stub the menu bar so `applicationDidFinishLaunching` has a chrome
        // surface even before any Desktop is created. The real content is
        // installed by the first `refreshMenu()` once we have a handle.
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(); mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About TurboKod",
                        action: #selector(aboutAction), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit TurboKod",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    /// Pull the latest snapshot from Mojo and rebuild NSMenu when it changes.
    /// Called from the per-frame timer; cheap on the steady state (one
    /// snapshot + FNV-1a hash compare). Skipped while AppKit is tracking an
    /// open NSMenu so the dropdown isn't ripped out mid-click.
    // Whichever Mojo Desktop should source the macOS menu bar right now —
    // the key window's view's Desktop when one is focused, otherwise any
    // open window's view, and finally the always-alive chrome Desktop when
    // no windows exist. Returns 0 only if even the chrome Desktop failed
    // to allocate.
    private func menuHandle() -> Int64 {
        if let v = NSApp.keyWindow?.contentView as? CellView, v.handle != 0 {
            return v.handle
        }
        if let v = views.first, v.handle != 0 { return v.handle }
        return chromeDesktop
    }

    @discardableResult
    func refreshMenu() -> Bool {
        let h = menuHandle()
        // Only touch NSApp.mainMenu while the app is active. The menu bar is
        // only visible then, and installing it pre-active (during launch,
        // before the appearance is resolved) draws the bar with the wrong
        // label color until activation repaints it — the white-on-white /
        // black-on-black blink. didBecomeActive does the first install.
        guard !menuTracking, h != 0, NSApp.isActive else { return false }
        // The chrome Desktop never gets drawn (its draw cycle is what
        // ticks per-window Desktops via tk_desktop_tick), so its menu
        // visibility flags would otherwise never update — Edit / View
        // would stay visible with no editor. Tick it manually right
        // before snapshotting so the snapshot reflects "no editor
        // focused" state.
        if h == chromeDesktop { tk_desktop_tick(h, 80, 24) }
        // Snapshot into the existing buffer; grow and retry until it fits.
        // A single grow could still truncate a menu more than 2x the buffer,
        // so loop (n == count signals the snapshot filled the whole buffer).
        var n = menuBuf.withUnsafeMutableBufferPointer { buf -> Int in
            Int(tk_desktop_menu_snapshot(h,
                Int64(Int(bitPattern: buf.baseAddress)), Int64(buf.count)))
        }
        while n == menuBuf.count {
            menuBuf = [UInt8](repeating: 0, count: menuBuf.count * 2)
            n = menuBuf.withUnsafeMutableBufferPointer { buf -> Int in
                Int(tk_desktop_menu_snapshot(h,
                    Int64(Int(bitPattern: buf.baseAddress)), Int64(buf.count)))
            }
        }
        // FNV-1a hash over the snapshot bytes.
        var hash: UInt64 = 0xcbf29ce484222325
        for i in 0..<n {
            hash = (hash ^ UInt64(menuBuf[i])) &* 0x100000001b3
        }
        if hash == lastMenuHash { return false }
        lastMenuHash = hash
        let text = String(bytes: menuBuf[0..<n], encoding: .utf8) ?? ""
        installMenu(from: text)
        return true
    }

    /// Parse a TSV snapshot into NSMenus, replacing the current mainMenu.
    ///
    /// The snapshot is already in painted display order (Mojo's
    /// `MenuBar._display_order_indices`), so we just iterate: the system
    /// (`≡`) menu lands first, where macOS expects the app-menu slot and
    /// renames it after the bundle ("TurboKod"); rank-sorted left-aligned
    /// menus follow (File, Edit, View, Git, Debug, Window); right-aligned
    /// menus (Project) come last, which puts them on the right of the bar.
    /// If Mojo emitted no system menu we synthesize one so macOS still
    /// has an app-menu slot with About + Quit.
    private func installMenu(from text: String) {
        let mainMenu = NSMenu()
        var sawSystem = false
        // Cleared up front so a rebuild that omits Help can't leave a
        // dangling reference to the previous menu's submenu.
        NSApp.helpMenu = nil

        var curSubmenu: NSMenu? = nil
        var curIsSystem = false

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let parts = rawLine.split(separator: "\t", omittingEmptySubsequences: false)
            if parts.isEmpty { continue }
            switch parts[0] {
            case "M":
                // M\t<label>\t<visible>\t<is_system>\t<right_aligned>
                guard parts.count >= 5 else { continue }
                let label = String(parts[1])
                // The snapshot only emits visible menus, but defensively
                // honor the flag in case that ever changes.
                guard parts[2] == "1" else { curSubmenu = nil; continue }
                curIsSystem = parts[3] == "1"
                let title = curIsSystem ? "TurboKod" : label
                let submenu = NSMenu(title: title)
                submenu.delegate = self
                submenu.autoenablesItems = false
                if curIsSystem {
                    sawSystem = true
                    // macOS app-menu conventions on top of Mojo's items.
                    submenu.addItem(NSMenuItem(title: "About TurboKod",
                                               action: #selector(aboutAction),
                                               keyEquivalent: ""))
                    submenu.addItem(.separator())
                }
                let item = NSMenuItem()
                item.title = title
                item.submenu = submenu
                mainMenu.addItem(item)
                curSubmenu = submenu
                // Designating the "Help" submenu as the app's help menu is
                // what makes AppKit add its built-in search field (which
                // searches every menu item across the bar). The Mojo core
                // places Help rightmost via `_menu_rank`.
                if !curIsSystem && label == "Help" {
                    NSApp.helpMenu = submenu
                }
            case "I":
                // I\t<label>\t<action>\t<is_separator>\t<checkable>\t<checked>\t<shortcut>
                guard let menu = curSubmenu, parts.count >= 7 else { continue }
                let label = String(parts[1])
                let action = String(parts[2])
                let isSep = parts[3] == "1"
                let checkable = parts[4] == "1"
                let checked = parts[5] == "1"
                let shortcut = String(parts[6])
                if isSep {
                    menu.addItem(.separator())
                    continue
                }
                // A few app-level actions need to use AppKit's native
                // selectors so their key equivalents still dispatch when
                // the app has no key window (Cmd+Q with no windows open
                // otherwise doesn't reach a custom `menuActionFired:`
                // because AppKit walks mainMenu via the responder chain
                // and our AppController-as-NSObject isn't on it). Mouse
                // clicks happen to work either way, but a uniform path
                // for both is cleaner.
                let nativeSel: Selector?
                switch action {
                case "quit":           nativeSel = #selector(NSApplication.terminate(_:))
                case "app.new_window": nativeSel = #selector(newWindowAction)
                case "project:open":   nativeSel = #selector(openProjectAction)
                case "file:open":      nativeSel = #selector(openAction)
                default:               nativeSel = nil
                }
                let item: NSMenuItem
                if let sel = nativeSel {
                    item = NSMenuItem(title: label, action: sel, keyEquivalent: "")
                    // Native selectors go to the application via the
                    // responder chain (target=nil) so AppKit's standard
                    // dispatch picks them up regardless of key-window state.
                } else {
                    item = NSMenuItem(
                        title: label,
                        action: #selector(menuActionFired(_:)),
                        keyEquivalent: ""
                    )
                    item.target = self
                    item.representedObject = action
                }
                item.isEnabled = true
                if checkable { item.state = checked ? .on : .off }
                applyShortcut(shortcut, to: item)
                menu.addItem(item)
            default: continue
            }
        }

        // Fallback: if Mojo emitted no system menu (shouldn't happen, but
        // defensive — snapshot could be empty during a race), synthesize
        // one so macOS has an app-menu slot to label.
        if !sawSystem {
            let appSub = NSMenu(title: "TurboKod")
            appSub.addItem(NSMenuItem(title: "About TurboKod",
                                      action: #selector(aboutAction),
                                      keyEquivalent: ""))
            appSub.addItem(.separator())
            appSub.addItem(NSMenuItem(
                title: "Quit TurboKod",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"))
            let app = NSMenuItem(); app.title = "TurboKod"; app.submenu = appSub
            mainMenu.insertItem(app, at: 0)
        }
        // Diff-and-modify rather than replace the menu wholesale. The menu bar
        // displays only the top-level titles; when those are unchanged — the
        // common case, where only submenu *contents* changed (the Window menu
        // populating, shortcuts getting stamped after restore) — we keep the
        // existing top-level items AND their submenu objects and move the
        // freshly-built items into the existing submenus. Reassigning
        // NSApp.mainMenu, or even swapping the submenu *objects*
        // (`old.submenu = new.submenu`), makes AppKit redraw the bar titles —
        // and during the launch/activation transition that redraw flashes them
        // with the wrong contrast (the white-on-white blink). Touching only the
        // (closed) dropdown contents leaves the bar itself alone. Only a
        // structural change (a top-level menu shown/hidden) reassigns mainMenu.
        if let existing = NSApp.mainMenu,
           existing.items.count == mainMenu.items.count,
           zip(existing.items, mainMenu.items).allSatisfy({ $0.title == $1.title }) {
            for (old, new) in zip(existing.items, mainMenu.items) {
                guard let oldSub = old.submenu, let newSub = new.submenu else {
                    let sub = new.submenu; new.submenu = nil; old.submenu = sub
                    continue
                }
                // NSMenuItems belong to one menu only — detach from the freshly
                // built submenu before re-homing them into the existing one.
                let moved = newSub.items
                newSub.removeAllItems()
                oldSub.removeAllItems()
                for it in moved { oldSub.addItem(it) }
                // The build pointed NSApp.helpMenu at the now-emptied freshly
                // built Help submenu; re-point it at the one we kept.
                if old.title == "Help" { NSApp.helpMenu = oldSub }
            }
        } else {
            NSApp.mainMenu = mainMenu
        }
    }

    /// Map Mojo's `"Cmd+Shift+S"`-style shortcut strings onto an NSMenuItem.
    /// Unknown tokens leave the item with no shortcut (still clickable).
    private func applyShortcut(_ s: String, to item: NSMenuItem) {
        if s.isEmpty { return }
        var mask: NSEvent.ModifierFlags = []
        let toks = s.split(separator: "+").map(String.init)
        guard !toks.isEmpty else { return }
        for mod in toks.dropLast() {
            switch mod {
            case "Cmd":   mask.insert(.command)
            case "Ctrl":  mask.insert(.control)
            case "Alt":   mask.insert(.option)
            case "Shift": mask.insert(.shift)
            default:      return    // unrecognized modifier — bail
            }
        }
        let key = toks.last!
        let equiv: String
        switch key {
        case "Up":    equiv = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        case "Down":  equiv = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        case "Left":  equiv = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        case "Right": equiv = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        case "Home":  equiv = String(Character(UnicodeScalar(NSHomeFunctionKey)!))
        case "End":   equiv = String(Character(UnicodeScalar(NSEndFunctionKey)!))
        case "PgUp":  equiv = String(Character(UnicodeScalar(NSPageUpFunctionKey)!))
        case "PgDn":  equiv = String(Character(UnicodeScalar(NSPageDownFunctionKey)!))
        case "Tab":   equiv = "\t"
        case "Enter": equiv = "\r"
        case "Esc":   equiv = "\u{1b}"
        case "Space": equiv = " "
        case "BkSp":  equiv = String(Character(UnicodeScalar(NSBackspaceCharacter)!))
        case "Del":   equiv = String(Character(UnicodeScalar(NSDeleteCharacter)!))
        case "F1":    equiv = String(Character(UnicodeScalar(NSF1FunctionKey)!))
        case "F2":    equiv = String(Character(UnicodeScalar(NSF2FunctionKey)!))
        case "F3":    equiv = String(Character(UnicodeScalar(NSF3FunctionKey)!))
        case "F4":    equiv = String(Character(UnicodeScalar(NSF4FunctionKey)!))
        case "F5":    equiv = String(Character(UnicodeScalar(NSF5FunctionKey)!))
        case "F6":    equiv = String(Character(UnicodeScalar(NSF6FunctionKey)!))
        case "F7":    equiv = String(Character(UnicodeScalar(NSF7FunctionKey)!))
        case "F8":    equiv = String(Character(UnicodeScalar(NSF8FunctionKey)!))
        case "F9":    equiv = String(Character(UnicodeScalar(NSF9FunctionKey)!))
        case "F10":   equiv = String(Character(UnicodeScalar(NSF10FunctionKey)!))
        case "F11":   equiv = String(Character(UnicodeScalar(NSF11FunctionKey)!))
        case "F12":   equiv = String(Character(UnicodeScalar(NSF12FunctionKey)!))
        default:
            // Mojo emits letters as uppercase. NSMenuItem expects lowercase
            // (with .shift in the modifier mask to mean "with Shift") — so
            // lowercase the letter unless Shift was explicitly present.
            equiv = mask.contains(.shift) ? key : key.lowercased()
        }
        item.keyEquivalent = equiv
        item.keyEquivalentModifierMask = mask
    }

    /// Dispatch a menu pick by forwarding its action string into Mojo's
    /// dispatch_action, then routing any host-level action code through the
    /// existing handler (Open/Quit/etc.).
    @objc func menuActionFired(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? String else { return }
        // Paste of a file (e.g. copied in Finder) offers the same full-path /
        // filename / relative menu as a drop, inserting the chosen form at the
        // caret. Only kicks in for an editor with a file on the clipboard;
        // otherwise falls through to the normal text paste below.
        if action == "edit:paste",
           let v = (NSApp.keyWindow?.contentView as? CellView) ?? views.first {
            // File(s) on the clipboard → the path-format menu.
            if v.pasteFilesWithMenu() { return }
            // Plain text → NFC-normalize in the host (macOS hands out
            // decomposed text that the bitmap font can't render) then paste.
            if v.pasteTextNormalized() {
                v.invalidateFrame()
                v.needsDisplay = true
                return
            }
        }
        // Dispatch through whatever Desktop is currently driving the menu
        // (key window's, any open window's, or the chrome desktop when no
        // windows exist) — same handle `refreshMenu` snapshotted from, so
        // the action's source-Desktop state (e.g. the recent-project
        // pending-path stash) is read back from the right place.
        let view = (NSApp.keyWindow?.contentView as? CellView) ?? views.first
        let h = view?.handle ?? chromeDesktop
        guard h != 0 else { return }
        let cols = Int64(view?.cols() ?? 80)
        let rows = Int64(view?.rows() ?? 24)
        let bytes = Array(action.utf8)
        let code = bytes.withUnsafeBufferPointer { b in
            tk_desktop_menu_invoke(h,
                Int64(Int(bitPattern: b.baseAddress)), Int64(bytes.count),
                cols, rows)
        }
        handleHostAction(code, sourceHandle: h, view: view)
        view?.invalidateFrame()
        view?.needsDisplay = true
    }

    // NSMenuDelegate — pause refreshMenu while AppKit is tracking an open
    // dropdown so a rebuild can't pull it out from under the user. Both the
    // top-level menus and their submenus call back here because we set
    // `submenu.delegate = self` in `installMenu`.
    func menuWillOpen(_ menu: NSMenu) { menuTracking = true }
    func menuDidClose(_ menu: NSMenu) { menuTracking = false }

    // The Mojo side loads grammars/wordlists via paths relative to cwd
    // (src/turbokod/grammars, src/turbokod/data). run_swift.sh bundles those
    // under Contents/Resources/src/turbokod, so chdir to Resources makes them
    // resolve regardless of how the app was launched (Dock, moved .app, no
    // repo present). Nothing else depends on cwd: git uses `git -C <root>`,
    // and the LSP spawn saves/restores cwd around its own chdir.
    private func chdirToResourceRoot() {
        guard let res = Bundle.main.resourcePath else { return }
        FileManager.default.changeCurrentDirectoryPath(res)
    }

    // Install the `tk` CLI helper to ~/.local/bin on first run (and re-point it
    // if the .app later moves). The helper opens this app for a path, or — over
    // SSH / when `--tui` is passed — runs the bundled terminal frontend
    // (Contents/MacOS/tk-tui). All best-effort and headless: no dialog, no sudo;
    // failures log to stderr and are otherwise ignored. We never clobber a `tk`
    // the user wrote themselves (only one carrying our marker line is replaced).
    private func installCliHelperIfNeeded() {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let binDir = home + "/.local/bin"
        let tkPath = binDir + "/tk"
        let markerDir = home + "/.config/turbokod"
        let markerPath = markerDir + "/.tk-cli-installed"
        let bundlePath = Bundle.main.bundlePath
        // Identifies a script we generated — both the overwrite guard and the
        // generated banner reference it, so they can't drift.
        let scriptMarker = "# turbokod-cli-helper"

        func log(_ msg: String) {
            FileHandle.standardError.write(Data(("[tk-cli] " + msg + "\n").utf8))
        }

        if let existing = try? String(contentsOfFile: tkPath, encoding: .utf8) {
            if !existing.contains(scriptMarker) {
                log("\(tkPath) exists and is not ours; leaving it alone")
                return
            }
            // Ours already — only rewrite if the bundle moved since last install.
            let stored = (try? String(contentsOfFile: markerPath, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if stored == bundlePath { return }
            log("bundle path changed (\(stored ?? "?") -> \(bundlePath)); re-pointing tk")
        }

        do {
            try fm.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        } catch {
            log("cannot create \(binDir): \(error.localizedDescription); skipping install")
            return
        }

        let script = Self.tkScript(bundlePath: bundlePath)
        do {
            try script.write(toFile: tkPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tkPath)
        } catch {
            log("failed to write \(tkPath): \(error.localizedDescription)")
            return
        }

        // Record the bundle path last, so an interrupted write isn't recorded
        // as "installed for this path".
        do {
            try fm.createDirectory(atPath: markerDir, withIntermediateDirectories: true)
            try bundlePath.write(toFile: markerPath, atomically: true, encoding: .utf8)
        } catch {
            log("installed tk but failed to write marker \(markerPath): \(error.localizedDescription)")
        }
        log("installed \(tkPath) -> \(bundlePath)")
    }

    // The `tk` script body, with this bundle's path baked in. Kept as a static
    // string so the marker line and the install guard stay in lockstep.
    private static func tkScript(bundlePath: String) -> String {
        // Single-quote the path for the shell; escape any embedded quote.
        let q = bundlePath.replacingOccurrences(of: "'", with: "'\\''")
        return """
        #!/usr/bin/env bash
        # turbokod-cli-helper — auto-generated by TurboKod.app. Do not edit;
        # it is regenerated on launch (and re-pointed if the app moves).
        set -euo pipefail

        APP_BUNDLE='\(q)'
        BUNDLE_ID="net.kodare.turbokod.native"
        TUI="$APP_BUNDLE/Contents/MacOS/tk-tui"

        # If the baked bundle path is gone (app moved/renamed), relocate by id.
        if [ ! -d "$APP_BUNDLE" ]; then
          found="$(mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null | head -1)"
          if [ -n "$found" ]; then
            APP_BUNDLE="$found"
            TUI="$APP_BUNDLE/Contents/MacOS/tk-tui"
          fi
        fi

        # Strip a --tui flag (force the terminal frontend); collect the rest.
        force_tui=0
        args=()
        for a in "$@"; do
          if [ "$a" = "--tui" ]; then force_tui=1; else args+=("$a"); fi
        done

        # Use the terminal frontend when asked, or when there's no GUI session
        # (e.g. connected over SSH).
        use_tui=0
        if [ "$force_tui" -eq 1 ]; then
          use_tui=1
        elif [ -n "${SSH_CONNECTION:-}" ] || [ -n "${SSH_TTY:-}" ] || [ -n "${SSH_CLIENT:-}" ]; then
          use_tui=1
        fi

        if [ "$use_tui" -eq 1 ]; then
          if [ ! -x "$TUI" ]; then
            echo "tk: terminal frontend not found at: $TUI" >&2
            echo "tk: relaunch TurboKod.app to repair the install." >&2
            exit 1
          fi
          exec "$TUI" ${args[@]+"${args[@]}"}
        fi

        # Native path: absolutize relative paths (the app's cwd is its Resources
        # dir, so a relative path would otherwise misresolve), then reuse the
        # running instance via `open -b`.
        abs=()
        for a in ${args[@]+"${args[@]}"}; do
          case "$a" in
            -*|/*) abs+=("$a") ;;
            *)
              d="$(cd "$(dirname -- "$a")" 2>/dev/null && pwd || true)"
              if [ -n "$d" ]; then abs+=("$d/$(basename -- "$a")"); else abs+=("$a"); fi
              ;;
          esac
        done

        if [ "${#abs[@]}" -eq 0 ]; then
          exec open -b "$BUNDLE_ID"
        fi

        # `open` errors on a path that doesn't exist, so split existing paths
        # (delivered to the running app via application(_:open:)) from new ones
        # (handed to a cold launch as argv so a brand-new file opens as an empty
        # buffer). New files while the app is already running may not open — a
        # known limitation; not worth a URL-scheme bridge here.
        existing=()
        missing=()
        for p in "${abs[@]}"; do
          case "$p" in
            -*) existing+=("$p") ;;
            *) if [ -e "$p" ]; then existing+=("$p"); else missing+=("$p"); fi ;;
          esac
        done

        rc=0
        if [ "${#existing[@]}" -gt 0 ]; then
          open -b "$BUNDLE_ID" "${existing[@]}" || rc=$?
        fi
        if [ "$rc" -eq 0 ] && [ "${#missing[@]}" -gt 0 ]; then
          open -b "$BUNDLE_ID" --args "${missing[@]}" || rc=$?
        fi

        if [ "$rc" -ne 0 ]; then
          # No GUI session we could open into — fall back to the terminal.
          if [ -x "$TUI" ]; then exec "$TUI" ${args[@]+"${args[@]}"}; fi
          echo "tk: could not open TurboKod.app (rc=$rc) and no terminal frontend available." >&2
          exit "$rc"
        fi
        """
    }

    private func keyView() -> CellView? {
        NSApp.keyWindow?.contentView as? CellView
    }

    @objc func newWindowAction() { _ = newWindow() }
    @objc func openAction() {
        if let v = keyView() { openFilePanel(v) }
        else { openFilePanelInNewWindow() }
    }
    @objc func openProjectAction() {
        if let v = keyView() { openProjectPanel(v) }
        else { openProjectPanelInNewWindow() }
    }

    // macOS "About TurboKod" — a small panel with a link to the project
    // on GitHub. Handled entirely in the Swift host (the item is a macOS
    // app-menu convention, not part of Mojo's shared menu).
    @objc func aboutAction() {
        let repoURL = "https://github.com/boxed/TurboKod"
        let alert = NSAlert()
        alert.messageText = "TurboKod"
        alert.informativeText = "Experimental IDE inspired by TurboC++ 3.\n\n\(repoURL)"
        if let icon = NSApp.applicationIconImage { alert.icon = icon }
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "View on GitHub")
        if alert.runModal() == .alertSecondButtonReturn,
           let url = URL(string: repoURL) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: action codes from Mojo (in-grid menu / Ctrl shortcuts)

    // CellView's keyDown / mouse handlers go through this one — they
    // always have a real view, so the source Desktop is that view's handle.
    func handleAction(_ code: Int32, view: CellView) {
        handleHostAction(code, sourceHandle: view.handle, view: view)
    }

    // Action codes the Mojo core bubbles up when an action can't be
    // handled below the frontend boundary — mirrors the ACT_* constants
    // in native_api.mojo (kept in sync by hand; the C ABI is plain Int32).
    enum HostAction: Int32 {
        case none        = 0   // ACT_NONE — handled inside Desktop
        case quit        = 1   // ACT_QUIT
        case openFile    = 2   // ACT_OPEN_FILE
        case quickOpen   = 3   // ACT_QUICK_OPEN
        case openProject = 4   // ACT_OPEN_PROJECT
        case newWindow   = 5   // ACT_NEW_WINDOW (also Project ▸ recent)
        case closeWindow = 6   // ACT_CLOSE_WINDOW (Close project)
        case toggleFloatingPanels = 7  // ACT_TOGGLE_FLOATING_PANELS
    }

    // Generalized action-code dispatch. The source `sourceHandle` is the
    // Mojo Desktop that produced this action (a real window's, or the
    // chrome desktop when a menu pick fired without a window). `view` is
    // the window the action came from (when one exists) so file/project
    // dialogs can land back in it — when nil we open a fresh window for
    // those, since dropping the user's pick on the floor is worse.
    func handleHostAction(_ code: Int32, sourceHandle: Int64, view: CellView?) {
        guard let action = HostAction(rawValue: code) else { return }
        switch action {
        case .none: break   // handled inside Desktop; nothing for the host
        case .quit: NSApp.terminate(nil)
        case .openFile, .quickOpen:
            if let v = view { openFilePanel(v) }
            else { openFilePanelInNewWindow() }
        case .openProject:
            if let v = view { openProjectPanel(v) }
            else { openProjectPanelInNewWindow() }
        case .newWindow:
            // Two paths share this code: a plain File ▸ New window (no
            // payload) and a Project ▸ <recent> pick (path queued on the
            // source Desktop). We drain the pending project off the
            // *source* Desktop — that may be the chrome desktop when the
            // pick came from a no-window menu. If there's a path, spawn the
            // window at its remembered frame and load the project.
            let pending = takePendingNewWindowProject(sourceHandle)
            if let path = pending {
                // If this project is already open in a window, just bring
                // that window to the front instead of opening a duplicate.
                // Recents paths are realpath-canonical from the Mojo side,
                // so canonicalize the window's path the same way to match.
                let want = canonicalPath(path)
                if let existing = views.first(where: {
                    ($0.project).map { canonicalPath($0) == want } ?? false
                }) {
                    existing.window?.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                } else {
                    let v = newWindow(frame: loadProjectFrame(path))
                    openProject(v, path)
                }
            } else {
                _ = newWindow()
            }
        case .closeWindow:
            // "Close project". The window is the project on macOS, so close
            // it (same path as the red close button). The Project menu only
            // offers this when a project is open, so `view` is its window.
            if let v = view { closeWindow(v) }
        case .toggleFloatingPanels:
            // Resolve to the project window's view: the menu can fire while
            // the panel window is key, in which case `view` is the `.panels`
            // view and its `mainPeer` is the project window.
            if let v = view {
                toggleFloatingPanels(v.surface == .panels ? (v.mainPeer ?? v) : v)
            }
        }
    }

    // No-window variants of the file/project open panels: spawn a fresh
    // window and load the user's pick into it. Used when the user fires
    // Open… / Open project… from the menu while no windows are open.
    private func openFilePanelInNewWindow() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let nv = newWindow()
        for url in panel.urls { openFile(nv, url.path) }
    }

    private func openProjectPanelInNewWindow() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }
        let nv = newWindow(frame: loadProjectFrame(url.path))
        openProject(nv, url.path)
    }

    // Dock drag-and-drop and "Open With": macOS hands us the dropped
    // folders/files here (folders are accepted because Info.plist
    // declares the public.folder document type). Before launch finishes
    // we buffer them — applicationDidFinishLaunching opens them in place
    // of restoring the session; after launch we open them immediately.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.isFileURL {
                if didFinishLaunchingDone { openDroppedPath(url.path) }
                else { pendingOpenPaths.append(url.path) }
            } else if url.scheme == "turbokod" {
                if didFinishLaunchingDone { openTurbokodURL(url) }
                else { pendingOpenURLs.append(url) }
            }
        }
    }

    // Handle a turbokod://open?file=X&line=N URL: open the file (1-based
    // `line`, optional) and jump the cursor there. Route into an already-open
    // project window whose project contains the file when there is one, so a
    // link to a file in an open project lands in that project's window rather
    // than spawning a bare file window.
    func openTurbokodURL(_ url: URL) {
        guard url.host == "open" || url.path == "open" || url.host == nil,
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems,
              let file = items.first(where: { $0.name == "file" })?.value,
              !file.isEmpty
        else { return }
        // URL line is 1-based (matching editor line numbers); the Mojo
        // side wants 0-based. Absent/malformed → open at the top.
        var line0 = 0
        if let lv = items.first(where: { $0.name == "line" })?.value,
           let n = Int(lv), n > 0 { line0 = n - 1 }

        let target = canonicalPath(file)
        let host = views.first { v in
            guard let p = v.project else { return false }
            let proj = canonicalPath(p)
            return target == proj || target.hasPrefix(proj + "/")
        }
        let v = host ?? newWindow()
        if host != nil { v.window?.makeKeyAndOrderFront(nil) }
        openFileAt(v, file, line0, 0)
    }

    func openFileAt(_ v: CellView, _ path: String, _ line: Int, _ character: Int) {
        let bytes = Array(path.utf8)
        bytes.withUnsafeBufferPointer { b in
            tk_desktop_open_file_at(v.handle, Int64(Int(bitPattern: b.baseAddress)),
                                    Int64(bytes.count), Int64(line), Int64(character),
                                    Int64(v.cols()), Int64(v.rows()))
        }
        if v.project == nil, let win = v.window {
            win.title = URL(fileURLWithPath: path).lastPathComponent
            win.representedURL = URL(fileURLWithPath: path)
        }
        v.needsDisplay = true
    }

    // Open one forwarded filesystem path in its own fresh window: a
    // directory becomes a project (the Mojo core records it into the
    // recent-projects list via open_project → _set_project); anything
    // else opens as a file buffer.
    func openDroppedPath(_ path: String) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        else { return }
        if isDir.boolValue {
            persistSession = true
            let v = newWindow(frame: loadProjectFrame(path))
            openProject(v, path)
        } else {
            let v = newWindow()
            openFile(v, path)
        }
    }

    // Resolve symlinks + normalize so two spellings of the same project
    // path compare equal. Mirrors the Mojo side's realpath() (which is
    // how paths land in the recent-projects list).
    private func canonicalPath(_ p: String) -> String {
        return URL(fileURLWithPath: p).resolvingSymlinksInPath().path
    }

    // Pull the path the Mojo Desktop queued when the user picked a
    // recent project from the right-aligned Project menu. Returns nil
    // when no path is queued (the usual case for File ▸ New window).
    private func takePendingNewWindowProject(_ h: Int64) -> String? {
        // 4 KiB covers every realistic project path; PATH_MAX on macOS
        // is 1024 and even deep monorepos rarely exceed a few hundred
        // bytes. If the Mojo side ever queues something larger,
        // tk_desktop_take_pending_new_window_project returns 0 *and
        // leaves the path queued*, so we'd need to retry with a bigger
        // buffer — not worth the complication today.
        let cap = 4096
        var buf = [UInt8](repeating: 0, count: cap)
        let n = buf.withUnsafeMutableBufferPointer { b -> Int in
            return Int(tk_desktop_take_pending_new_window_project(
                h, Int64(Int(bitPattern: b.baseAddress)), Int64(cap),
            ))
        }
        if n <= 0 { return nil }
        return String(bytes: buf[0..<n], encoding: .utf8)
    }

    // MARK: windows + desktops

    /// Push the system monospace-family list onto a Desktop so its Settings ▸
    /// Font picker is populated. First call pays the ~140 ms FontCatalog scan;
    /// the result is a cached static, so later calls are cheap.
    func applyFontOptions(to h: Int64) {
        let families = FontCatalog.monospaceFamilies.joined(separator: "\n")
        let fb = Array(families.utf8)
        fb.withUnsafeBufferPointer { b in
            tk_desktop_set_font_options(h, Int64(Int(bitPattern: b.baseAddress)),
                                        Int64(fb.count))
        }
    }

    /// Run once, right after the first frame is on screen. This is where the
    /// deferred startup work lands so it never delays the window appearing:
    /// the user's interactive $PATH recovery (slow login shell) and the
    /// monospace-family scan (applied to every open Desktop). Both are
    /// idempotent, so a stray second call is harmless.
    func afterFirstFrame() {
        tk_recover_user_shell_path()
        fontOptionsReady = true
        for v in views where v.handle != 0 { applyFontOptions(to: v.handle) }
        if chromeDesktop != 0 { applyFontOptions(to: chromeDesktop) }
        // The first frame ran session restore, so the focused editor now
        // exists — refresh the menu to pick up its editor-dependent items
        // (Edit / View). Doing it here, off the first paint, means the menu
        // tracks the window instead of waiting for NSApp.isActive (which can
        // lag a Dock launch by hundreds of ms — the visible stale-menu bug).
        refreshMenu()
    }

    @discardableResult
    func newWindow(frame: NSRect? = nil) -> CellView {
        let h = tk_desktop_new()
        // Tell the Desktop the host owns the menu surface — it stops painting
        // the in-grid menu bar and stops routing top-row mouse / Alt-letter
        // mnemonic events to it. We mirror the menu via tk_desktop_menu_snapshot.
        // TK_MENU_INGRID=1 skips the handoff so the classic in-grid menu bar
        // stays visible — scripts/screenshots.sh uses it for the terminal-style
        // README hero shot.
        if ProcessInfo.processInfo.environment["TK_MENU_INGRID"] == nil {
            tk_desktop_set_host_owns_menu(h, 1)
        }
        // The host draws the editor body popups' drop shadows as a real
        // translucent layer (drawPopupShadow) so they composite correctly over
        // the sub-cell smooth-scroll body instead of tearing. The core stops
        // baking the cell shadow under those popups.
        tk_desktop_set_host_owns_shadows(h, 1)
        // Likewise the Settings view renders in its own native window (see
        // settingsWins) — the main surface skips the in-grid overlay and
        // stays interactive while Settings is open.
        tk_desktop_set_settings_detached(h, 1)
        // Project Settings likewise renders in its own native window.
        tk_desktop_set_project_settings_detached(h, 1)
        // Register the system's monospace families so the Settings view grows
        // its Font section (the terminal frontend never does this). The scan
        // is ~140 ms and only feeds the Settings picker — which can't be open
        // before the first frame — so defer it until afterFirstFrame on the
        // launch window. Windows opened later (fontOptionsReady already true)
        // apply the cached list inline.
        if fontOptionsReady { applyFontOptions(to: h) }
        let view = CellView()
        view.handle = h
        let initial = frame ?? NSRect(x: 0, y: 0, width: 1000, height: 640)
        let win = NSWindow(contentRect: initial,
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        // We own session persistence; opt out of macOS window restoration so
        // no per-window state is saved and no post-crash "reopen windows?"
        // dialog appears. See NSQuitAlwaysKeepsWindows in didFinishLaunching.
        win.isRestorable = false
        win.title = "TurboKod"
        win.delegate = self
        win.contentView = view
        win.makeFirstResponder(view)
        win.acceptsMouseMovedEvents = true
        if let f = frame {
            // Restored: place at the saved screen-coord frame.
            win.setFrame(f, display: false)
        } else {
            // Fresh: cascade so multiple New Window clicks don't stack.
            win.cascadeTopLeft(from: NSPoint(x: 40, y: 40))
        }
        win.makeKeyAndOrderFront(nil)
        windows.append(win)
        views.append(view)
        let f = win.frame
        print("window opened — total open: \(views.count)"
            + " frame: \(Int(f.origin.x)),\(Int(f.origin.y))"
            + " \(Int(f.size.width))x\(Int(f.size.height))")
        return view
    }

    func openFile(_ v: CellView, _ path: String) {
        let bytes = Array(path.utf8)
        bytes.withUnsafeBufferPointer { b in
            tk_desktop_open_file(v.handle, Int64(Int(bitPattern: b.baseAddress)),
                                 Int64(bytes.count), Int64(v.cols()), Int64(v.rows()))
        }
        // File-only windows (no project loaded): title + proxy track the
        // file itself. When a project is loaded the title is the project
        // name and stays put even as additional files are opened — the
        // window represents the project, not the active buffer.
        if v.project == nil, let win = v.window {
            win.title = URL(fileURLWithPath: path).lastPathComponent
            win.representedURL = URL(fileURLWithPath: path)
        }
        v.needsDisplay = true
    }

    func openProject(_ v: CellView, _ path: String) {
        let bytes = Array(path.utf8)
        bytes.withUnsafeBufferPointer { b in
            tk_desktop_open_project(v.handle, Int64(Int(bitPattern: b.baseAddress)),
                                    Int64(bytes.count))
        }
        v.project = path
        // Title + proxy icon: macOS convention is for project/document
        // windows to show the project name with a draggable folder proxy
        // icon next to it. `representedURL` is what makes the proxy appear;
        // AppKit picks up the icon from the URL itself (the OS folder icon
        // for a directory, the file's icon for a file). Cmd-click the title
        // for the path popover; drag the icon to other apps.
        if let win = v.window {
            win.title = URL(fileURLWithPath: path).lastPathComponent
            win.representedURL = URL(fileURLWithPath: path)
        }
        // Apply the per-display-config layout: size the window and float or
        // dock the tool panels per what was saved for the current set of
        // screens. New-window-at-launch paths pre-apply the main frame via
        // newWindow(frame:) so there's no visible resize flash; this also
        // restores the floating panel window when the config calls for it.
        applyGeometryForCurrentConfig(v)
        saveSession()
        v.needsDisplay = true
    }

    func openFilePanel(_ v: CellView) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls { openFile(v, url.path) }
        }
    }

    func openProjectPanel(_ v: CellView) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.urls.first {
            // A window already showing a project can't swap its root in
            // place — the Mojo Desktop is one-project-per-window and
            // open_project no-ops once a project is set (so the pick
            // would silently do nothing and never reach the recents
            // list). Open it in a fresh window instead, matching how
            // Project ▸ <recent> behaves. An empty/file-only window
            // adopts the project directly.
            if v.project != nil {
                let nv = newWindow(frame: loadProjectFrame(url.path))
                openProject(nv, url.path)
            } else {
                openProject(v, url.path)
            }
        }
    }

    func closeWindow(_ view: CellView) {
        if let idx = views.firstIndex(where: { $0 === view }) {
            // performClose routes through `windowShouldClose` (our safe path).
            // NSWindow.close() bypasses it and tears down via `windowWillClose`,
            // which lands in a Sequoia AppKit regression (see windowShouldClose).
            windows[idx].performClose(nil)
        }
    }

    // macOS Sequoia (Darwin 24.x) AppKit regression: the standard close
    // cascade — `performClose` (or `close`) → `windowWillClose` → AppKit
    // window teardown — segfaults inside `objc_autoreleasePoolPop` on the
    // next runloop turn (`AutoreleasePoolPage::releaseUntil` releasing an
    // object at ~0x20). Reproducible in a stub Swift app with a single
    // empty NSWindow and no delegate or custom view — i.e. the bug is in
    // AppKit's own teardown, not user code.
    //
    // Workaround: intercept at `windowShouldClose` (which runs *before*
    // AppKit starts the broken cascade), do all our cleanup + `orderOut`,
    // and return `false` so AppKit skips the teardown entirely. The window
    // object is technically leaked (still owned by AppKit's NSApp.windows),
    // but it's hidden and our handle/Desktop are freed — a small price for
    // not segfaulting. `windowWillClose` is intentionally not implemented;
    // returning false here means it never fires.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closing a panel window just docks the panels — the Desktop lives on
        // the project window, which stays open. (Re-open via View ▸ Floating
        // panels.)
        if let entry = panels.first(where: { $0.value.window === sender }) {
            if let mv = mainViewByObjectId(entry.key) { closePanelWindow(for: mv) }
            return false
        }
        // Closing the Settings window via the red button closes the Settings
        // view on the Mojo side too (the reverse of the active-flag poll that
        // opened this window).
        if let entry = settingsWins.first(where: { $0.value.window === sender }) {
            if let mv = mainViewByObjectId(entry.key) {
                tk_desktop_settings_close(mv.handle)
                closeSettingsWindow(for: mv)
            }
            return false
        }
        // Same for the Project Settings window (twin of the Settings arm).
        if let entry = projectSettingsWins.first(where: { $0.value.window === sender }) {
            if let mv = mainViewByObjectId(entry.key) {
                tk_desktop_project_settings_close(mv.handle)
                closeProjectSettingsWindow(for: mv)
            }
            return false
        }
        guard let idx = windows.firstIndex(of: sender) else { return false }
        let v = views[idx]
        // Capture the final geometry (including floating state + panel frame)
        // before teardown so the next open restores it, then drop the panel
        // window — without double-freeing the shared Desktop handle.
        if !isTerminating { saveGeometryFor(v) }
        closePanelWindow(for: v, save: false)
        closeSettingsWindow(for: v, focusMain: false)
        closeProjectSettingsWindow(for: v, focusMain: false)
        let h = v.handle
        v.handle = 0
        windows.remove(at: idx)
        views.remove(at: idx)
        tk_desktop_free(h)
        // Save the session each time a window closes so the on-disk state
        // matches what's open. `isTerminating` (set by applicationShould
        // Terminate during Cmd+Q) suppresses these mid-quit saves so they
        // don't rewrite the file as windows drop one-by-one.
        if !isTerminating { saveSession() }
        sender.orderOut(nil)
        return false
    }

    // App stays alive with no windows open (Finder/Safari-style). The user
    // re-opens via the menu (File ▸ New Window / Open Project…). Quitting
    // requires explicit Cmd+Q (NSApp.terminate).
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ s: NSApplication) -> NSApplication.TerminateReply {
        // Snapshot the open windows + projects before exit so the next launch
        // restores them. `isTerminating` is checked by windowShouldClose to
        // suppress per-window saves during a Cmd+Q cascade (windows close one
        // by one; without the guard, each would rewrite the file with an
        // emptying list and the final state would be `no windows`).
        if !isTerminating {
            saveSession()
            isTerminating = true
        }
        // Free the chrome Desktop so a clean leaks(1) run reports zero
        // hangers. The real per-window Desktops are freed in
        // windowShouldClose; this is the one allocation outside that path.
        if chromeDesktop != 0 {
            tk_desktop_free(chromeDesktop)
            chromeDesktop = 0
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ note: Notification) {
        // SIGTERM every spawned child (run target, LSP servers, pty
        // shells). The Rust shim has a dyld-terminator backstop for
        // this, but NSApp.terminate exits via _exit(), which skips
        // static terminators — without this explicit call a process
        // running in the Run pane would survive Cmd+Q.
        tk_terminate_all()
    }

    // MARK: app-level session (which windows + their projects)

    private func sessionPath() -> String { NSHomeDirectory() + "/.turbokod/native_session.txt" }

    // Per-line format: ``project\tx\ty\tw\th`` (TSV). Lines without tabs are
    // accepted as legacy project-only entries — they restore with a default
    // frame so old sessions still work.
    func loadSession() -> [(project: String, frame: NSRect?)] {
        guard let content = try? String(contentsOfFile: sessionPath(), encoding: .utf8)
        else { return [] }
        var out: [(String, NSRect?)] = []
        for line in content.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            let proj = String(parts[0])
            if proj.isEmpty { continue }
            if parts.count >= 5,
               let x = Double(parts[1]), let y = Double(parts[2]),
               let w = Double(parts[3]), let h = Double(parts[4]),
               w > 0, h > 0 {
                out.append((proj, NSRect(x: x, y: y, width: w, height: h)))
            } else {
                out.append((proj, nil))
            }
        }
        return out
    }

    func saveSession() {
        guard persistSession else { return }
        let dir = NSHomeDirectory() + "/.turbokod"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var lines: [String] = []
        for i in 0..<views.count {
            guard let p = views[i].project else { continue }
            let f = windows[i].frame
            lines.append("\(p)\t\(Int(f.origin.x))\t\(Int(f.origin.y))"
                       + "\t\(Int(f.size.width))\t\(Int(f.size.height))")
        }
        let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try? text.write(toFile: sessionPath(), atomically: true, encoding: .utf8)
    }

    // MARK: per-project NSWindow frame
    //
    // Lives at <project>/.turbokod/per_user/<USER>/native_window.json, matching
    // the existing session.json / view_states.json / breakpoints.json layout
    // the Mojo side uses for its own per-project state. Storing the frame
    // here (rather than only in ~/.turbokod/native_session.txt) means a
    // project remembers its window size/position even when:
    //   - opened in a fresh window mid-session (Open Project…),
    //   - opened from the CLI on a project not in the previous session,
    //   - moved to another machine that shares the project directory.
    // native_session.txt still records which projects to auto-open at next
    // launch; the per-project file is the source of truth for geometry.

    private func nativeWindowDir(_ project: String) -> String {
        return project + "/.turbokod/per_user/" + NSUserName()
    }

    private func nativeWindowPath(_ project: String) -> String {
        return nativeWindowDir(project) + "/native_window.json"
    }

    // Per-display-configuration geometry. The window size/position AND the
    // floating-vs-docked choice are remembered per display configuration, so a
    // roaming setup (laptop ± external display) restores the layout that
    // matched the screens it was last used with — and falls back to docked
    // when it meets a configuration it hasn't floated under. See
    // docs/floating-panels.md.
    struct PanelConfigEntry {
        var main: NSRect?       // project window frame for this config
        var floating: Bool      // were panels floated under this config?
        var panel: NSRect?      // panel window frame (when floating)
    }
    struct ProjectGeometry {
        var last: NSRect?                       // fallback size for a new config
        var configs: [String: PanelConfigEntry] // keyed by displayConfigKey()
    }

    // A stable key for the current set of attached displays: each screen's
    // CGDisplay UUID (stable across disconnect/reconnect and reboot) plus its
    // pixel resolution, sorted so the key is order-independent. Distinct
    // setups (laptop-only vs laptop+4K vs laptop+ultrawide) get distinct keys.
    func displayConfigKey() -> String {
        var parts: [String] = []
        for screen in NSScreen.screens {
            var ident = "?"
            if let num = (screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value {
                let did = CGDirectDisplayID(num)
                if let cf = CGDisplayCreateUUIDFromDisplayID(did) {
                    ident = CFUUIDCreateString(nil, cf.takeRetainedValue()) as String
                } else {
                    ident = String(num)
                }
            }
            let f = screen.frame, s = screen.backingScaleFactor
            parts.append("\(ident)@\(Int(f.width * s))x\(Int(f.height * s))")
        }
        return parts.isEmpty ? "none" : parts.sorted().joined(separator: "|")
    }

    private func rectFromJSON(_ any: Any?) -> NSRect? {
        guard let arr = any as? [Any] else { return nil }
        let nums = arr.compactMap { ($0 as? NSNumber)?.doubleValue }
        guard nums.count == 4, nums[2] > 0, nums[3] > 0 else { return nil }
        return NSRect(x: nums[0], y: nums[1], width: nums[2], height: nums[3])
    }

    private func jsonFromRect(_ r: NSRect) -> [Int] {
        [Int(r.origin.x), Int(r.origin.y), Int(r.size.width), Int(r.size.height)]
    }

    func loadProjectGeometry(_ project: String) -> ProjectGeometry {
        var geom = ProjectGeometry(last: nil, configs: [:])
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: nativeWindowPath(project))),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return geom }
        // Legacy single-frame form ({"frame":[…]}) seeds `last` so existing
        // projects open at their remembered size (docked) and start recording
        // per-config state from there.
        if let legacy = rectFromJSON(obj["frame"]) { geom.last = legacy }
        if let last = rectFromJSON(obj["last"]) { geom.last = last }
        if let cfgs = obj["configs"] as? [String: Any] {
            for (k, v) in cfgs {
                guard let d = v as? [String: Any] else { continue }
                geom.configs[k] = PanelConfigEntry(
                    main: rectFromJSON(d["main"]),
                    floating: (d["floating"] as? Bool) ?? false,
                    panel: rectFromJSON(d["panel"]))
            }
        }
        return geom
    }

    func saveProjectGeometry(_ project: String, _ geom: ProjectGeometry) {
        try? FileManager.default.createDirectory(
            atPath: nativeWindowDir(project), withIntermediateDirectories: true)
        var obj: [String: Any] = [:]
        if let last = geom.last { obj["last"] = jsonFromRect(last) }
        var cfgs: [String: Any] = [:]
        for (k, e) in geom.configs {
            var d: [String: Any] = ["floating": e.floating]
            if let m = e.main { d["main"] = jsonFromRect(m) }
            if let p = e.panel { d["panel"] = jsonFromRect(p) }
            cfgs[k] = d
        }
        obj["configs"] = cfgs
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: nativeWindowPath(project)), options: .atomic)
    }

    // Back-compat shim for the many call sites that just want a main-window
    // frame to open at: the current config's saved frame, else the last-used
    // size (else nil → caller's default).
    func loadProjectFrame(_ project: String) -> NSRect? {
        let geom = loadProjectGeometry(project)
        if let e = geom.configs[displayConfigKey()], let m = e.main { return m }
        return geom.last
    }

    // Read/modify/write the current config's entry, preserving every other
    // config's saved layout. A docked save keeps the last-known panel frame so
    // re-floating returns to the remembered size.
    private func recordProjectGeometry(
        _ project: String, main: NSRect, floating: Bool, panel: NSRect?) {
        var geom = loadProjectGeometry(project)
        geom.last = main
        let key = displayConfigKey()
        let keepPanel = floating ? panel : geom.configs[key]?.panel
        geom.configs[key] = PanelConfigEntry(main: main, floating: floating, panel: keepPanel)
        saveProjectGeometry(project, geom)
    }

    // Capture a project window's full geometry — main frame, whether its
    // panels are currently floating, and the panel window frame — under the
    // current display config.
    private func saveGeometryFor(_ mainView: CellView) {
        guard let project = mainView.project, let mainWin = mainView.window else { return }
        let id = ObjectIdentifier(mainView)
        let floating = panels[id] != nil
        recordProjectGeometry(project, main: mainWin.frame,
                              floating: floating, panel: panels[id]?.window.frame)
    }

    private func mainViewByObjectId(_ id: ObjectIdentifier) -> CellView? {
        return views.first { ObjectIdentifier($0) == id }
    }

    // MARK: live resize/move persistence

    // Snap interactive resizes to whole cells. cols()/rows() floor the content
    // area by CELL_W/CELL_H, so any leftover fractional-cell strip along the
    // right/bottom edge stays unpainted and reads as blank desktop background.
    // Flooring the content size to an exact multiple here makes the grid always
    // fill the window. Works off contentRect so the title-bar (and any side
    // chrome) is excluded; all our windows are CellView grids and share this
    // delegate, so every window snaps uniformly.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let cr = sender.contentRect(forFrameRect: sender.frame)
        let chromeW = sender.frame.width - cr.width
        let chromeH = sender.frame.height - cr.height
        let contentW = frameSize.width - chromeW
        let contentH = frameSize.height - chromeH
        let snapW = max(CELL_W, (contentW / CELL_W).rounded(.down) * CELL_W)
        let snapH = max(CELL_H, (contentH / CELL_H).rounded(.down) * CELL_H)
        return NSSize(width: snapW + chromeW, height: snapH + chromeH)
    }

    func windowDidResize(_ note: Notification) { scheduleFrameSave(note) }
    func windowDidMove(_ note: Notification)   { scheduleFrameSave(note) }

    // AppKit fires didResize/didMove on every frame of a live drag — debounce
    // to ~150 ms after the last event so we write once per gesture instead of
    // dozens of times. Cancelled-and-rescheduled rather than throttled so the
    // *final* frame is what lands on disk. Both the project window and its
    // panel window route here; either resolves to the project's main view, and
    // we snapshot the whole geometry (so moving the panel window records the
    // panel frame, moving the main window records the main frame).
    private func scheduleFrameSave(_ note: Notification) {
        guard let win = note.object as? NSWindow else { return }
        var mainView: CellView?
        if let idx = windows.firstIndex(of: win) {
            mainView = views[idx]
        } else {
            for (id, pair) in panels where pair.window === win {
                mainView = mainViewByObjectId(id)
            }
        }
        guard let mv = mainView, mv.project != nil else { return }
        let key = ObjectIdentifier(win)
        frameSaveTimers[key]?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) {
            [weak self, weak mv] _ in
            if let mv = mv { self?.saveGeometryFor(mv) }
            self?.frameSaveTimers.removeValue(forKey: key)
        }
        frameSaveTimers[key] = t
    }

    // MARK: floating panels — window, toggle, restore, fallback

    // Build the panel window's CellView, sharing the project window's Desktop
    // handle and rendering only the tool panels.
    private func makePanelView(for mainView: CellView) -> CellView {
        let v = CellView()
        v.handle = mainView.handle
        v.surface = .panels
        v.mainPeer = mainView
        return v
    }

    // Place the panel window beside the main window by default — to the right,
    // overflowing onto an external display when there is one, since that's the
    // common roaming target. Used only when no per-config panel frame is saved.
    private func defaultPanelFrame(besides mainWin: NSWindow) -> NSRect {
        let mf = mainWin.frame
        let screen = mainWin.screen ?? NSScreen.main
        let w: CGFloat = 720, h = mf.height
        var x = mf.maxX + 20
        var y = mf.origin.y
        if let other = NSScreen.screens.first(where: { $0 !== screen }) {
            // Prefer the secondary display's left edge.
            x = other.frame.origin.x + 40
            y = other.frame.origin.y + 40
        }
        return NSRect(x: x, y: y, width: w, height: h)
    }

    // True when `frame` is at least partly on some currently-attached screen —
    // the test that makes a vanished display fall back to docked.
    private func frameIsVisible(_ frame: NSRect) -> Bool {
        for s in NSScreen.screens where s.frame.intersects(frame) { return true }
        return false
    }

    // Open (or reposition) the panel window for a project window and flip the
    // Desktop into detached mode.
    private func showPanelWindow(for mainView: CellView, frame: NSRect?) {
        guard let mainWin = mainView.window else { return }
        let id = ObjectIdentifier(mainView)
        let pv: CellView
        let win: NSWindow
        if let existing = panels[id] {
            pv = existing.view; win = existing.window
        } else {
            pv = makePanelView(for: mainView)
            win = UnconstrainedWindow(
                contentRect: frame ?? defaultPanelFrame(besides: mainWin),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            win.delegate = self
            win.contentView = pv
            win.makeFirstResponder(pv)
            win.acceptsMouseMovedEvents = true
            win.title = (mainView.project.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "TurboKod") + " — Panels"
            panels[id] = (window: win, view: pv)
        }
        if let f = frame { win.setFrame(f, display: false) }
        tk_desktop_set_panels_detached(mainView.handle, 1)
        // orderFront (not makeKey): toggling panels on shouldn't yank keyboard
        // focus off the editor. The user clicks into the panel window when
        // they want to drive the terminal/debugger there. Skip the show when
        // there are no panels yet — the tick-loop auto-hide owns visibility,
        // and ordering an empty window front here would flash it for one tick.
        if tk_desktop_panels_visible_count(mainView.handle) > 0 {
            win.orderFront(nil)
        }
        mainView.invalidateFrame(); mainView.needsDisplay = true
        pv.invalidateFrame(); pv.needsDisplay = true
    }

    // Tear the panel window down and re-dock the panels.
    private func closePanelWindow(for mainView: CellView, save: Bool = true) {
        let id = ObjectIdentifier(mainView)
        guard let pair = panels[id] else {
            tk_desktop_set_panels_detached(mainView.handle, 0)
            return
        }
        panels.removeValue(forKey: id)
        pair.view.handle = 0          // shared handle is owned by the main view
        tk_desktop_set_panels_detached(mainView.handle, 0)
        pair.window.orderOut(nil)     // see windowShouldClose (Sequoia teardown)
        mainView.invalidateFrame(); mainView.needsDisplay = true
        if save && !isTerminating { saveGeometryFor(mainView) }
    }

    // View ▸ Floating panels — flip the current project window between docked
    // and floating, persisting the new choice under the current display config.
    func toggleFloatingPanels(_ mainView: CellView) {
        let id = ObjectIdentifier(mainView)
        if panels[id] != nil {
            closePanelWindow(for: mainView)
        } else {
            // Reuse the saved panel frame for this config if any.
            let saved = mainView.project.flatMap {
                loadProjectGeometry($0).configs[displayConfigKey()]?.panel
            }
            showPanelWindow(for: mainView, frame: saved)
            saveGeometryFor(mainView)
        }
    }

    // MARK: standalone Settings window

    private func makeSettingsView(for mainView: CellView) -> CellView {
        let v = CellView()
        v.handle = mainView.handle    // shared Desktop, second surface
        v.surface = .settings
        v.mainPeer = mainView
        return v
    }

    private func defaultSettingsFrame(over mainWin: NSWindow) -> NSRect {
        // Centered over the project window; sized for the settings layout
        // (left rail + right pane) without dwarfing the editor behind it —
        // the whole point of the separate window is watching a theme change
        // retint the workspace live.
        let w: CGFloat = 110 * CELL_W, h: CGFloat = 34 * CELL_H
        let mf = mainWin.frame
        return NSRect(x: mf.midX - w / 2, y: mf.midY - h / 2, width: w, height: h)
    }

    private func showSettingsWindow(for mainView: CellView) {
        guard let mainWin = mainView.window else { return }
        let id = ObjectIdentifier(mainView)
        let sv: CellView
        let win: NSWindow
        if let existing = settingsWins[id] {
            sv = existing.view; win = existing.window
        } else {
            sv = makeSettingsView(for: mainView)
            win = UnconstrainedWindow(
                contentRect: defaultSettingsFrame(over: mainWin),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered, defer: false)
            win.delegate = self
            win.contentView = sv
            win.makeFirstResponder(sv)
            win.acceptsMouseMovedEvents = true
            win.title = "Settings"
            settingsWins[id] = (window: win, view: sv)
        }
        win.makeKeyAndOrderFront(nil)
        sv.invalidateFrame(); sv.needsDisplay = true
    }

    private func closeSettingsWindow(for mainView: CellView, focusMain: Bool = true) {
        let id = ObjectIdentifier(mainView)
        guard let pair = settingsWins[id] else { return }
        settingsWins.removeValue(forKey: id)
        pair.view.handle = 0          // shared handle is owned by the main view
        pair.window.orderOut(nil)     // Sequoia-safe (see windowShouldClose)
        // Hand focus back to the project window so Esc-closing Settings
        // drops the user straight back into the editor. Skipped when the
        // project window itself is the one going away.
        if focusMain { mainView.window?.makeKeyAndOrderFront(nil) }
    }

    // --- Project Settings window (twin of the Settings window above) ---------

    private func makeProjectSettingsView(for mainView: CellView) -> CellView {
        let v = CellView()
        v.handle = mainView.handle    // shared Desktop, second surface
        v.surface = .projectSettings
        v.mainPeer = mainView
        return v
    }

    private func defaultProjectSettingsFrame(over mainWin: NSWindow) -> NSRect {
        let w: CGFloat = 100 * CELL_W, h: CGFloat = 32 * CELL_H
        let mf = mainWin.frame
        return NSRect(x: mf.midX - w / 2, y: mf.midY - h / 2, width: w, height: h)
    }

    private func showProjectSettingsWindow(for mainView: CellView) {
        guard let mainWin = mainView.window else { return }
        let id = ObjectIdentifier(mainView)
        let sv: CellView
        let win: NSWindow
        if let existing = projectSettingsWins[id] {
            sv = existing.view; win = existing.window
        } else {
            sv = makeProjectSettingsView(for: mainView)
            win = UnconstrainedWindow(
                contentRect: defaultProjectSettingsFrame(over: mainWin),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered, defer: false)
            win.delegate = self
            win.contentView = sv
            win.makeFirstResponder(sv)
            win.acceptsMouseMovedEvents = true
            win.title = "Project Settings"
            projectSettingsWins[id] = (window: win, view: sv)
        }
        win.makeKeyAndOrderFront(nil)
        sv.invalidateFrame(); sv.needsDisplay = true
    }

    private func closeProjectSettingsWindow(for mainView: CellView, focusMain: Bool = true) {
        let id = ObjectIdentifier(mainView)
        guard let pair = projectSettingsWins[id] else { return }
        projectSettingsWins.removeValue(forKey: id)
        pair.view.handle = 0          // shared handle is owned by the main view
        pair.window.orderOut(nil)     // Sequoia-safe (see windowShouldClose)
        if focusMain { mainView.window?.makeKeyAndOrderFront(nil) }
    }

    // Apply the saved layout for the current display config to a project
    // window: size the main window, and float or dock the panels. Called when
    // a project opens and whenever the screen configuration changes. Falls back
    // to docked whenever the current config has no floating entry, or the saved
    // panel frame is no longer visible on any attached screen.
    func applyGeometryForCurrentConfig(_ mainView: CellView) {
        guard let project = mainView.project, let mainWin = mainView.window else { return }
        let geom = loadProjectGeometry(project)
        let entry = geom.configs[displayConfigKey()]
        if let m = entry?.main ?? geom.last, !NSEqualRects(mainWin.frame, m) {
            mainWin.setFrame(m, display: true)
        }
        // Capture runs grab a single window — keep the panels docked so a
        // staged debug/terminal pane is actually in the shot, regardless of
        // the layout saved for this display config. Read-only: the saved
        // floating entry survives for the next interactive launch.
        let wantFloat = (entry?.floating ?? false)
            && (entry?.panel.map { frameIsVisible($0) } ?? false)
            && ProcessInfo.processInfo.environment["TK_CAPTURE"] == nil
        if wantFloat {
            showPanelWindow(for: mainView, frame: entry?.panel)
        } else {
            // Unknown config or the panel's display is gone → dock. Don't
            // re-save here: the floating entry for the *other* config must
            // survive so re-plugging restores it.
            closePanelWindow(for: mainView, save: false)
        }
    }

    // React to display connect/disconnect / resolution changes: re-evaluate
    // every open project window against the now-current configuration.
    @objc func screenParametersChanged(_ note: Notification) {
        for v in views { applyGeometryForCurrentConfig(v) }
    }
}

setvbuf(stdout, nil, _IONBF, 0)   // unbuffered so logs survive a SIGTERM
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let controller = AppController()
app.delegate = controller
app.activate(ignoringOtherApps: true)
app.run()
