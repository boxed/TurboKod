import AppKit
import CoreText
import CoreGraphics

/// Call ``body`` with ``s`` as a C-ABI ``(ptr, len)`` UTF-8 argument pair —
/// the shape every ``tk_*`` entry point that takes a string expects. The
/// pointer is only valid for the duration of ``body``.
@discardableResult
func withUTF8Arg<T>(_ s: String, _ body: (Int64, Int64) -> T) -> T {
    let bytes = Array(s.utf8)
    return bytes.withUnsafeBufferPointer { b in
        body(Int64(Int(bitPattern: b.baseAddress)), Int64(bytes.count))
    }
}

/// A scripted headless render (``TK_CAPTURE``) is in progress. Read once:
/// ``ProcessInfo.environment`` builds a fresh dictionary per access, and the
/// check sits on every mouse-move / key / timer path.
let isCapturing = ProcessInfo.processInfo.environment["TK_CAPTURE"] != nil

/// FNV-1a over ``words`` — a cheap "did this buffer change?" fingerprint
/// for the laid-out frame and the menu snapshot.
func fnv1a<S: Sequence>(_ words: S) -> UInt64 where S.Element: BinaryInteger {
    var h: UInt64 = 0xcbf29ce484222325
    for w in words { h = (h ^ UInt64(w)) &* 0x100000001b3 }
    return h
}

// The bundled IBM VGA fonts, both with a 1:2 cell and the same vertical
// metrics, so 16pt gives an 8×16pt cell either way:
// - TurboKodVGA16x32.ttf (the default): a 16×32 redraw of the VGA font as
//   outlines, plus the original 8×16 pixels as an embedded 16px bitmap
//   strike. Core Text picks the strike when a cell is 16 device pixels tall
//   (16pt on a 1x screen) and the 16×32 outlines otherwise (Retina, 32px+).
// - Px437_IBM_VGA_8x16.ttf (Settings ▸ Font ▸ classic): the original 8×16
//   font at every size.
let BUNDLED_FONT_FILE = "TurboKodVGA16x32.ttf"
let CLASSIC_FONT_FILE = "Px437_IBM_VGA_8x16.ttf"
// config.font value that selects the classic font — CLASSIC_FONT in config.mojo.
let CLASSIC_FONT_NAME = "Px437 IBM VGA 8x16"
// Family names of the bundled fonts, kept out of the system font list:
// they're registered in-process, so FontCatalog would otherwise list them
// alongside the built-in rows.
let BUNDLED_FONT_FAMILIES: Set<String> = ["TurboKod VGA 16x32", CLASSIC_FONT_NAME]

// Falls back to Menlo if the bundled TTF is missing.
func loadCellFont(size: CGFloat = 16, file: String = BUNDLED_FONT_FILE) -> NSFont {
    if let res = Bundle.main.resourcePath {
        let url = URL(fileURLWithPath: res + "/" + file)
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
// crisp, everything else must not. `cellFontIsAdaptive` marks the default
// bundled font, whose pixel-exact sizes depend on the screen's backing
// scale — see `cellFontRendersCrisp`.
var cellFont = loadCellFont()
var cellFontIsBitmap = true
var cellFontIsAdaptive = true

/// Whether cells should render without antialiasing on a screen with
/// `backingScale`. The default bundled font is pixel-exact when a cell is
/// 16 device pixels tall (its embedded 8×16 strike) or a multiple of 32
/// (its 16×32 outlines); every other font follows `cellFontIsBitmap`.
func cellFontRendersCrisp(backingScale: CGFloat) -> Bool {
    if cellFontIsAdaptive {
        let px = Int((CGFloat(cellFontEffectiveSize) * backingScale).rounded())
        return px == 16 || px % 32 == 0
    }
    return cellFontIsBitmap
}

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
            if family.hasPrefix(".") || BUNDLED_FONT_FAMILIES.contains(family) { continue }
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

/// A bundled VGA font at `size` points (0 = its 16pt design size): the
/// default 16×32 font, or the original Px437 8×16 when `classic`. Either
/// glyph grid is exactly 8×16pt at 16pt, so the cell scales as a strict
/// 1:2 box. Crisp (no-AA) rendering only where the pixels land exactly on
/// device pixels (`cellFontRendersCrisp`) — fractional scales look better
/// antialiased. For the classic font that's integer multiples of 16pt.
private func applyBundledCellFont(_ size: CGFloat, classic: Bool = false) {
    let eff = size > 0 ? size : CGFloat(BITMAP_FONT_DEFAULT_SIZE)
    cellFont = loadCellFont(size: eff, file: classic ? CLASSIC_FONT_FILE : BUNDLED_FONT_FILE)
    cellFontGlyphCache.removeAll()
    cellFontEffectiveSize = Int(eff.rounded())
    cellFontIdealSize = BITMAP_FONT_DEFAULT_SIZE
    cellFontIsBitmap = cellFontEffectiveSize % BITMAP_FONT_DEFAULT_SIZE == 0
    cellFontIsAdaptive = !classic
    CELL_W = max(1, (eff / 2).rounded())
    CELL_H = max(1, eff.rounded())
}

/// Switch the cell font to `name` (a family from `monospaceFontFamilies`;
/// empty = the bundled VGA font, CLASSIC_FONT_NAME = the original 8×16
/// one) at `size` points (0 = the font's
/// default) and recompute CELL_W/CELL_H from its metrics. No-op when both
/// are already active. Derives `cellFontEffectiveSize` / `cellFontIdealSize`
/// for the caller to report back to the Mojo core.
func applyCellFont(_ name: String, size: CGFloat = 0) {
    if name == currentCellFontName && size == currentCellFontSize { return }
    currentCellFontName = name
    currentCellFontSize = size
    if name.isEmpty || name == CLASSIC_FONT_NAME {
        applyBundledCellFont(size, classic: !name.isEmpty)
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
    cellFontIsAdaptive = false
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
        fnv1a(UnsafeBufferPointer(start: buf, count: words))
    }

    override var isFlipped: Bool { true }            // y increases downward (row index)
    override var acceptsFirstResponder: Bool { true }
    override var wantsDefaultClipping: Bool { false }
    // The floating panels window is a companion to the project window, which
    // normally holds key focus (e.g. after a breakpoint stop jumps the editor).
    // Without click-through, AppKit spends the first click only activating the
    // panels window, so a click on the debug console's `>>>` line never
    // reached the pane — it stayed unfocused and the typing that followed was
    // dropped. Let that first click through to the panel under it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { surface == .panels }

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
    /// Show the cursor for a ``host_abi.SHAPE_*`` code.
    private func applyCursorShape(_ code: Int32) {
        switch code {
        case 1: NSCursor.iBeam.set()
        case 2: NSCursor.pointingHand.set()
        case 3: NSCursor.resizeUpDown.set()
        case 4: NSCursor.resizeLeftRight.set()
        default: NSCursor.arrow.set()
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

    // `buf` and `regionBuf` are manual allocations, so ARC releasing the
    // view reclaims the object but not them. They're grown to the window's
    // cell count and never shrink, so a closed window stranded both at its
    // final size (~1.6 MB for a large grid) for the life of the app — and
    // the app deliberately outlives its windows.
    deinit {
        buf.deallocate()
        regionBuf.deallocate()
    }

    // Grow-only cell buffer: reallocate when `cells` exceeds `capacity`.
    private static func growCells(_ p: inout UnsafeMutablePointer<UInt32>,
                                  _ capacity: inout Int, _ cells: Int) {
        if cells > capacity {
            p.deallocate()
            p = UnsafeMutablePointer<UInt32>.allocate(capacity: cells * CELL_WORDS)
            capacity = cells
        }
    }

    private func ensureBuf(_ cells: Int) { Self.growCells(&buf, &bufCells, cells) }

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
        // The VGA fonts are pixel fonts — render them crisp (no anti-aliasing
        // / font smoothing) or the glyphs come out blurred. Cells are on
        // integer pixel boundaries so hard-edged rasterization is exact.
        // Vector fonts (Settings ▸ Font) want the opposite: hard-edged
        // rasterization makes them jagged, so antialias those.
        let aa = !cellFontRendersCrisp(backingScale: window?.backingScaleFactor ?? 1)
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
        // macOS-style UI: the bottom (status) row re-typeset as a native bar.
        if surface == .main && r > 1 && tk_desktop_native_ui(handle) != 0 {
            drawNativeStatusBar(buf, n, c, r)
        }
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

    /// The status row in system type on a window-colored bar. Each run of
    /// same-colored cells is redrawn at its own cell column, so every click
    /// target (git area, run targets, LSP status) stays exactly where the
    /// core hit-tests it — this is presentation only. Runs whose background
    /// differs from the bar's become pills; runs in a non-default color keep
    /// it (the green "uncommitted" dot, a red LSP error).
    private func drawNativeStatusBar(_ p: UnsafeMutablePointer<UInt32>, _ n: Int, _ c: Int, _ r: Int) {
        let row = r - 1
        let start = row * c
        guard start + c <= n else { return }
        var bgCount: [UInt32: Int] = [:], fgCount: [UInt32: Int] = [:]
        for i in start..<(start + c) {
            let (fg, bg, _) = cellColors(p, i)
            bgCount[bg, default: 0] += 1
            if p[i * CELL_WORDS] & 0x1FFFFF > 0x20 { fgCount[fg, default: 0] += 1 }
        }
        let barBg = bgCount.max { $0.value < $1.value }?.key ?? 0
        let barFg = fgCount.max { $0.value < $1.value }?.key ?? 0
        let y = CGFloat(row) * CELL_H
        // The cell pass turned anti-aliasing off for the pixel font; system
        // type needs it back on.
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.setShouldAntialias(true)
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldSmoothFonts(true)
            ctx.setAllowsFontSmoothing(true)
        }
        NSGraphicsContext.current?.shouldAntialias = true
        let bar = NSRect(x: 0, y: y, width: bounds.width, height: bounds.height - y)
        NSColor.windowBackgroundColor.setFill()
        bar.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: y, width: bounds.width, height: 1).fill()
        let font = NSFont.systemFont(ofSize: min(12, max(10, CELL_H * 0.68)))
        var i = 0
        while i < c {
            let (fg, bg, _) = cellColors(p, start + i)
            var j = i
            var text = ""
            while j < c {
                let (f2, b2, _) = cellColors(p, start + j)
                if f2 != fg || b2 != bg { break }
                let cp = p[(start + j) * CELL_WORDS] & 0x1FFFFF
                text.unicodeScalars.append(Unicode.Scalar(cp > 0 ? cp : 0x20) ?? " ")
                j += 1
            }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                let lead = CGFloat(text.prefix { $0 == " " }.count)
                let x = CGFloat(i) * CELL_W + lead * CELL_W
                let color: NSColor = fg == barFg ? .secondaryLabelColor : nscolor(fg)
                let pill = bg != barBg
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: pill ? NSFont.systemFont(ofSize: font.pointSize, weight: .medium) : font,
                    .foregroundColor: pill ? NSColor.labelColor : color,
                ]
                let size = (trimmed as NSString).size(withAttributes: attrs)
                if pill {
                    let pr = NSRect(x: CGFloat(i) * CELL_W + 1, y: y + 2,
                                    width: CGFloat(j - i) * CELL_W - 2, height: CELL_H - 3)
                    NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
                    NSBezierPath(roundedRect: pr, xRadius: 4, yRadius: 4).fill()
                }
                (trimmed as NSString).draw(at: NSPoint(x: x, y: y + (CELL_H - size.height) / 2 + 0.5),
                                           withAttributes: attrs)
            }
            i = j
        }
    }

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
            // Word 0 is the codepoint, with the core's cell width (0 / 1 / 2)
            // in the top byte — we never recompute it from the codepoint.
            let w0 = p[i * CELL_WORDS]
            let cp = w0 & 0x1FFFFF
            let wide = (w0 >> 24) == 2
            let (fg, _, style) = cellColors(p, i)
            let col = i % c, row = i / c
            let x = originX + CGFloat(col) * CELL_W
            let y = originY + CGFloat(row) * CELL_H
            if cp != 0x20 && cp != 0, let scalar = Unicode.Scalar(cp) {
                let s = String(scalar) as NSString
                if wide {
                    drawWide(s, fg: fg, cellX: x, cellY: y, cellW: CELL_W * 2)
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
        Self.growCells(&regionBuf, &regionBufCells, cells)
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
        if let ob = overlayBounds() {
            let oclip = CGRect(x: CGFloat(ob[0]) * CELL_W, y: CGFloat(ob[1]) * CELL_H,
                               width: CGFloat(ob[2]) * CELL_W,
                               height: CGFloat(ob[3]) * CELL_H)
            ctx.saveGState()
            ctx.clip(to: oclip)
            drawCells(ctx, buf, mainN, mainCols, originX: 0, originY: 0)
            ctx.restoreGState()
        }
    }

    /// The focused editor's body popup box `[x, y, w, h]` in cells, or nil
    /// when no popup is up.
    private func overlayBounds() -> [Int32]? {
        var ob = [Int32](repeating: 0, count: 4)
        let has = ob.withUnsafeMutableBufferPointer { b in
            Int(tk_editor_overlay_bounds(handle, Int64(cols()), Int64(rows()),
                Int64(Int(bitPattern: b.baseAddress))))
        }
        return has == 1 ? ob : nil
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
        guard let ob = overlayBounds(), ob[2] > 0, ob[3] > 0 else { return }
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

    /// Draw a wide (two-cell) glyph — an emoji or a CJK character — shrunk to
    /// fit a `cellW`×`CELL_H` box, centered. The bitmap cell font has neither,
    /// so this is the system font's fallback. Apple Color Emoji at the
    /// cell-font point size massively overflows the cell; glyph metrics scale
    /// linearly with point size, so we measure at a reference size and pick
    /// the size whose rendered glyph fits within (cellW, CELL_H). Reserving two
    /// cells (cellW = 2·CELL_W) gives the glyph a near-square box. `fg` colors
    /// text glyphs; color emoji ignore it.
    private func drawWide(_ s: NSString, fg: UInt32, cellX x: CGFloat,
                          cellY y: CGFloat, cellW: CGFloat) {
        let ref: CGFloat = CELL_H
        let probe = s.size(withAttributes: [.font: NSFont.systemFont(ofSize: ref)])
        guard probe.width > 0, probe.height > 0 else { return }
        let scale = min(cellW / probe.width, CELL_H / probe.height)
        let font = NSFont.systemFont(ofSize: max(1, ref * scale))
        let glyph = s.size(withAttributes: [.font: font])
        s.draw(at: NSPoint(x: x + (cellW - glyph.width) / 2,
                           y: y + (CELL_H - glyph.height) / 2),
               withAttributes: [.font: font, .foregroundColor: nscolor(fg)])
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
        if isCapturing { return }
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
        if isCapturing { return }
        if s.isEmpty { return }
        for scalar in s.unicodeScalars {
            handleAction(keySurface(scalar.value, 0, cols(), rows()))
        }
        invalidateFrame()
        needsDisplay = true
    }

    override func flagsChanged(with event: NSEvent) {
        // See keyDown — scripted capture runs ignore live input.
        if isCapturing { return }
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

    /// `quiet` dispatches the event into the core but skips the cursor-shape
    /// query and the change detection. `detectChange` lays out and hashes the
    /// whole surface — 5 ms with a real editor open — so a caller emitting a
    /// run of events in one gesture (see `legacyNotchScroll`) must pass it and
    /// settle up once at the end, not per event.
    private func sendMouse(_ e: NSEvent, button: UInt8, pressed: UInt8, motion: UInt8,
                           passive: Bool = false, quiet: Bool = false) {
        // See keyDown — scripted capture runs ignore live input.
        if isCapturing { return }
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
        if quiet { return }
        // Cursor hint.
        applyCursorShape(pointerShapeSurface(col, row, cols(), rows()))
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
        if isCapturing { return }
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

    /// Load the continuous scroll position + clamp for region `r` from the
    /// core (O(lines) for a wrapped editor; trivial otherwise).
    private func seedSmooth(_ r: SmoothRegion) {
        var m = [Int32](repeating: 0, count: 2)
        m.withUnsafeMutableBufferPointer { b in
            _ = tk_editor_smooth_begin(handle, Int64(r.winIdx),
                Int64(cols()), Int64(rows()),
                Int64(Int(bitPattern: b.baseAddress)))
        }
        smoothWinIdx = r.winIdx
        smoothLines = CGFloat(m[0]) / 1000.0
        smoothMax = Int(m[1]) / 1000
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
            seedSmooth(r)
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
            seedSmooth(r)   // once per gesture
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
        // One trackpad event carries enough delta for several notches, and a
        // flick's momentum keeps them coming at the display rate. Each notch
        // used to go through the full `sendMouse` tail — cursor-shape query
        // plus `detectChange`, which lays out and hashes the entire surface at
        // ~5 ms a call with an editor open. A big swipe therefore asked for
        // tens of full layouts per event, arriving every 8-16 ms: the app
        // couldn't keep up, the event queue backed up, and a core pegged
        // while it drained long after the fingers were off the glass. The
        // notches go in quiet and the surface is settled once, here.
        var sent = 0
        while abs(scrollAccumY) >= perNotch {
            let up = scrollAccumY > 0
            sendMouse(e, button: up ? 4 : 5, pressed: 1, motion: 0, quiet: true)
            scrollAccumY += up ? -perNotch : perNotch
            sent += 1
        }
        if sent == 0 { return }
        // Content moved under a stationary pointer, so the hover shape can
        // have changed even though the position didn't.
        let p = convert(e.locationInWindow, from: nil)
        applyCursorShape(pointerShapeSurface(Int64(max(0, p.x) / CELL_W),
                                             Int64(max(0, p.y) / CELL_H),
                                             cols(), rows()))
        if detectChange() { needsDisplay = true }
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
        let paths = urls.map { $0.path }.joined(separator: "\n")
        let r = withUTF8Arg(paths) { ptr, len -> Int32 in
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
        let r = withUTF8Arg(text) { ptr, len in
            tk_desktop_insert_text(handle, col, row, ptr, len,
                                   Int64(cols()), Int64(rows()))
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
        _ = withUTF8Arg(text) { ptr, len in tk_desktop_paste_text(handle, ptr, len) }
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
        let consumed = withUTF8Arg(text) { ptr, len in
            tk_desktop_paste_clipboard_text(handle, ptr, len)
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
    // Desktop views that render in their own native window (Settings,
    // Project Settings), one per project window per surface, keyed by the
    // main view like `panels`. Opened/closed by polling the surface's active
    // flag each tick — the Mojo side opens them via a menu action and closes
    // them via Esc / their Close button, so the host can't know without asking.
    private struct DialogSurface {
        let surface: CellSurface
        let title: String
        let cols: CGFloat, rows: CGFloat   // default size, in cells
        let isActive: (Int64) -> Int32
        let close: (Int64) -> Void
    }
    private let dialogSurfaces: [DialogSurface] = [
        // Sized for the settings layout (left rail + right pane) without
        // dwarfing the editor behind it — the whole point of the separate
        // window is watching a theme change retint the workspace live.
        DialogSurface(surface: .settings, title: "Settings", cols: 110, rows: 34,
                      isActive: tk_desktop_settings_active,
                      close: tk_desktop_settings_close),
        DialogSurface(surface: .projectSettings, title: "Project Settings",
                      cols: 100, rows: 32,
                      isActive: tk_desktop_project_settings_active,
                      close: tk_desktop_project_settings_close),
    ]
    private var dialogWins: [CellSurface: [ObjectIdentifier: (window: NSWindow, view: CellView)]] = [:]
    // macOS-style UI: the native sheet currently showing each view's core
    // dialog (see the "native dialogs" extension at the bottom of the file).
    var nativeSheets: [ObjectIdentifier: NSWindow] = [:]
    var nativeDialogBuf = [UInt8](repeating: 0, count: 4096)
    // macOS-style UI: each window's native tab strip (a titlebar accessory).
    var tabStrips: [ObjectIdentifier: (accessory: NSTitlebarAccessoryViewController, strip: TabStripView)] = [:]
    var tabsBuf = [UInt8](repeating: 0, count: 4096)
    // macOS-style UI: the native picker sheet up on each window, if any.
    var pickers: [ObjectIdentifier: PickerController] = [:]
    var welcome: WelcomeController?
    // macOS-style UI: the NSMenu standing in for a core popup, per window.
    var popups: [ObjectIdentifier: PopupMenu] = [:]
    // macOS-style UI: the native git sheet per window.
    var gitSheets: [ObjectIdentifier: GitController] = [:]
    // macOS-style UI: each window's find bar (a titlebar accessory).
    var findBars: [ObjectIdentifier: (accessory: NSTitlebarAccessoryViewController, bar: FindBar)] = [:]
    // macOS-style UI: the native file tree laid over each window's tree cells.
    var trees: [ObjectIdentifier: FileTreeOverlay] = [:]
    // macOS-style UI: the native Settings window (one per Desktop that opened it).
    var prefsWindows: [ObjectIdentifier: PrefsController] = [:]
    // macOS-style UI: Project ▸ Spelling as a sheet, per window.
    var spellingSheets: [ObjectIdentifier: SpellingController] = [:]
    // macOS-style UI: Git history as a sheet, per window.
    var historySheets: [ObjectIdentifier: HistoryController] = [:]
    // macOS-style UI: the on-disk-change merge as a sheet, per window.
    var mergeSheets: [ObjectIdentifier: MergeController] = [:]
    // macOS-style UI review mode: the picker sheet, and the native bar laid
    // over the toolbar row while reviewing.
    var reviewPickers: [ObjectIdentifier: ReviewPickerController] = [:]
    var reviewBars: [ObjectIdentifier: ReviewBar] = [:]
    // macOS-style UI: native headers over the docked tool panes, per window
    // and keyed "kind:idx".
    var paneHeaders: [ObjectIdentifier: [String: PaneHeader]] = [:]
    var treeBuf = [UInt8](repeating: 0, count: 1 << 16)
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

    // MENU_MARK_OPEN in menu.mojo: "open, but not the current one".
    static let menuMarkOpen = 1

    /// Diamond for the menu's state column, standing in for the checkmark
    /// on a project that's open in another window (see MENU_MARK_OPEN).
    /// Template-rendered so it tints with the menu's text color, and sized
    /// down from the default state-image metrics so it reads as a marker
    /// rather than competing with the checkmark. nil on a system without
    /// the symbol, in which case the row just goes unmarked.
    static let openElsewhereStateImage: NSImage? = {
        let cfg = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
        guard let img = NSImage(systemSymbolName: "diamond.fill",
                                accessibilityDescription: "open in another window")?
                .withSymbolConfiguration(cfg) else { return nil }
        img.isTemplate = true
        return img
    }()

    /// Menu-item icons: an SF Symbol from the snapshot's `icon` field, drawn
    /// centered in one fixed box. Symbols differ in width, and macOS 15
    /// doesn't reserve an image column for the rows without one, so a mixed
    /// menu would otherwise start every title at a different x. `""` is the
    /// blank spacer the imageless rows of an iconed menu get for the same
    /// reason. Template images, so they tint with the menu highlight.
    private static var menuIconCache: [String: NSImage] = [:]
    static func menuIcon(_ name: String) -> NSImage {
        if let img = menuIconCache[name] { return img }
        let box = NSSize(width: 18, height: 16)
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let sym = name.isEmpty ? nil
            : NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg)
        let img = NSImage(size: box, flipped: false) { rect in
            guard let sym = sym else { return true }
            let s = sym.size
            let k = min(1, rect.width / s.width, rect.height / s.height)
            let w = s.width * k, h = s.height * k
            sym.draw(in: NSRect(x: (rect.width - w) / 2, y: (rect.height - h) / 2,
                                width: w, height: h))
            return true
        }
        img.isTemplate = true
        menuIconCache[name] = img
        return img
    }

    // Memo for pushOpenProjects: the raw per-window project paths the
    // canonicalized payload was last built from, and that payload.
    private var openProjectsRaw: [String] = []
    private var openProjectsPayload = ""

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
                // CLI ``./run_swift.sh <project-or-file>``: same as a Dock
                // drop, except a path that doesn't exist yet still opens
                // as a new file buffer.
                let p = args[1]
                if FileManager.default.fileExists(atPath: p) {
                    self.openDroppedPath(p)
                } else {
                    self.openFile(self.newWindow(), p)
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
            let capturing = isCapturing
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
            // Dialog-window lifecycle (Settings, Project Settings): poll each
            // surface's active flag and open/close the NSWindow on transitions.
            for d in self.dialogSurfaces {
                for v in self.views where v.handle != 0 {
                    let id = ObjectIdentifier(v)
                    let open = self.dialogWins[d.surface]?[id] != nil
                    let active = d.isActive(v.handle) != 0
                    if active && !open {
                        self.showDialogWindow(d, for: v); changed = true
                    } else if !active && open {
                        self.closeDialogWindow(d.surface, for: v); changed = true
                    }
                }
                // Like the panel views, dialog views share the main Desktop and
                // don't tick — just detect whether the surface needs a repaint.
                for pair in (self.dialogWins[d.surface] ?? [:]).values {
                    let sv = pair.view
                    guard let w = sv.window, w.isVisible,
                          w.occlusionState.contains(.visible) else { continue }
                    if sv.pollFrame() { sv.needsDisplay = true; changed = true }
                }
            }
            for v in self.views where v.handle != 0 {
                if self.pollNativeDialog(v) { changed = true }
                if self.pollTabStrip(v) { changed = true }
                if self.pollPicker(v) { changed = true }
                if self.pollPopup(v) { changed = true }
                if self.pollGit(v) { changed = true }
                if self.pollFindBar(v) { changed = true }
                if self.pollTree(v) { changed = true }
                if self.pollPrefs(v) { changed = true }
                if self.pollSpelling(v) { changed = true }
                if self.pollHistory(v) { changed = true }
                if self.pollMerge(v) { changed = true }
                if self.pollReview(v) { changed = true }
                if self.pollPaneHeaders(v) { changed = true }
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
        // TK_OPEN takes a comma-separated list; the last one ends up focused.
        for spec in (env["TK_OPEN"] ?? "").split(separator: ",").map(String.init) {
            guard let v = views.first else { break }
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
                    // TK_CAPTURE_WINDOW=1 grabs the whole window — titlebar,
                    // tab strip, and an attached sheet composited on top —
                    // instead of just the cell grid (macOS-style UI shots).
                    if let title = env["TK_CAPTURE_TITLE"],
                       let w = NSApp.windows.first(where: { $0.title == title && $0.isVisible }) {
                        captureWindowPNG(w, to: cap)
                    } else if env["TK_WELCOME"] != nil, let w = self.welcome?.window {
                        captureWindowPNG(w, to: cap)
                    } else if env["TK_CAPTURE_WINDOW"] != nil, let w = self.windows.first {
                        captureWindowPNG(w, to: cap)
                    } else {
                        self.views.first?.capturePNG(to: cap)
                    }
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
        _ = withUTF8Arg(action) { ptr, len in
            tk_desktop_menu_invoke(v.handle, ptr, len, Int64(v.cols()), Int64(v.rows()))
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
        appMenu.addItem(withTitle: "Welcome to TurboKod…",
                        action: #selector(welcomeAction), keyEquivalent: "")
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

    /// Push the set of project roots open across the app onto `h`, so its
    /// Project menu can mark an entry as already open in another window. A
    /// Desktop only knows its own project; this is the only channel for the
    /// rest. Cheap enough to do every frame — the core compares the list and
    /// early-outs when it hasn't moved.
    private func pushOpenProjects(to h: Int64) {
        // The push itself has to happen every frame (`h` follows the key
        // window), but canonicalizing is a filesystem resolution per
        // window — so only redo it when the raw project list moves.
        let raw = views.filter { $0.surface == .main }.compactMap { $0.project }
        if raw != openProjectsRaw {
            openProjectsRaw = raw
            openProjectsPayload = raw.map { canonicalPath($0) }
                                     .joined(separator: "\n")
        }
        withUTF8Arg(openProjectsPayload) { ptr, len in
            tk_desktop_set_open_projects(h, ptr, len)
        }
    }

    @discardableResult
    func refreshMenu() -> Bool {
        let h = menuHandle()
        // Before the snapshot, so the Project menu's open-elsewhere markers
        // are built from the current window set. Unguarded by menuTracking:
        // the core only rebuilds the menu when the list actually changes,
        // and a change while a dropdown is open should still land.
        if h != 0 { pushOpenProjects(to: h) }
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
        var n = 0
        while true {
            n = menuBuf.withUnsafeMutableBufferPointer { buf -> Int in
                Int(tk_desktop_menu_snapshot(h,
                    Int64(Int(bitPattern: buf.baseAddress)), Int64(buf.count)))
            }
            if n < menuBuf.count { break }
            menuBuf = [UInt8](repeating: 0, count: menuBuf.count * 2)
        }
        let hash = fnv1a(menuBuf[0..<n])
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
                    addAboutItem(to: submenu)
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
                // I\t<label>\t<action>\t<is_separator>\t<checkable>\t<checked>\t<shortcut>\t<mark>\t<icon>
                guard let menu = curSubmenu, parts.count >= 7 else { continue }
                let label = String(parts[1])
                let action = String(parts[2])
                let isSep = parts[3] == "1"
                let checkable = parts[4] == "1"
                let checked = parts[5] == "1"
                let shortcut = String(parts[6])
                // MENU_MARK_* (menu.mojo): the alternate glyph for the
                // check column. Tolerates an older snapshot without it.
                let mark = parts.count >= 8 ? Int(parts[7]) ?? 0 : 0
                let icon = parts.count >= 9 ? String(parts[8]) : ""
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
                // A mark shows in the same column a checkmark would, by
                // swapping the on-state image rather than the title —
                // AppKit's own Window menu marks a non-frontmost window
                // the same way.
                if !checked, mark == Self.menuMarkOpen,
                   let img = Self.openElsewhereStateImage {
                    item.onStateImage = img
                    item.state = .on
                }
                if !icon.isEmpty { item.image = Self.menuIcon(icon) }
                applyShortcut(shortcut, to: item)
                menu.addItem(item)
            default: continue
            }
        }

        // Line up titles in menus that carry any icon (see `menuIcon`).
        for top in mainMenu.items {
            guard let sub = top.submenu,
                  sub.items.contains(where: { $0.image != nil }) else { continue }
            for it in sub.items where !it.isSeparatorItem && it.image == nil {
                it.image = Self.menuIcon("")
            }
        }

        // Fallback: if Mojo emitted no system menu (shouldn't happen, but
        // defensive — snapshot could be empty during a race), synthesize
        // one so macOS has an app-menu slot to label.
        if !sawSystem {
            let appSub = NSMenu(title: "TurboKod")
            addAboutItem(to: appSub)
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
        // A native text field has focus (a macOS-style UI sheet, a save
        // panel): the Edit menu's key equivalents belong to it, not to the
        // editor behind it.
        if NSApp.keyWindow?.firstResponder is NSText,
           let sel = Self.textFieldEditActions[action] {
            NSApp.sendAction(sel, to: nil, from: sender)
            return
        }
        // Paste of a file (e.g. copied in Finder) offers the same full-path /
        // filename / relative menu as a drop, inserting the chosen form at the
        // caret. Only kicks in for an editor with a file on the clipboard;
        // otherwise falls through to the normal text paste below.
        let view = keyView() ?? views.first
        if action == "edit:paste", let v = view {
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
        let h = view?.handle ?? chromeDesktop
        guard h != 0 else { return }
        let cols = Int64(view?.cols() ?? 80)
        let rows = Int64(view?.rows() ?? 24)
        let code = withUTF8Arg(action) { ptr, len in
            tk_desktop_menu_invoke(h, ptr, len, cols, rows)
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
    @objc func openAction() { openFilePanel(keyView()) }
    @objc func openProjectAction() { openProjectPanel(keyView()) }

    // The macOS app-menu convention on top of Mojo's items: "About"
    // followed by a separator.
    private func addAboutItem(to menu: NSMenu) {
        menu.addItem(NSMenuItem(title: "About TurboKod",
                                action: #selector(aboutAction),
                                keyEquivalent: ""))
        // Reopens the first-launch look / theme / font chooser any time.
        menu.addItem(NSMenuItem(title: "Welcome to TurboKod…",
                                action: #selector(welcomeAction),
                                keyEquivalent: ""))
        menu.addItem(.separator())
    }

    @objc func welcomeAction() { showWelcome(force: true) }

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
        case .openFile, .quickOpen: openFilePanel(view)
        case .openProject: openProjectPanel(view)
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
        withUTF8Arg(path) { ptr, len in
            tk_desktop_open_file_at(v.handle, ptr, len, Int64(line), Int64(character),
                                    Int64(v.cols()), Int64(v.rows()))
        }
        if v.project == nil { setWindowPath(v, path) }
        v.needsDisplay = true
    }

    // Open one forwarded filesystem path in its own fresh window: a
    // directory becomes a project at its remembered frame (the Mojo core
    // records it into the recent-projects list via open_project →
    // _set_project); anything else opens as a file buffer.
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
        withUTF8Arg(families) { ptr, len in tk_desktop_set_font_options(h, ptr, len) }
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
        showWelcomeIfNeeded()
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
        // dialogWins) — the main surface skips the in-grid overlay and
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

    // Title the window after `path` and give it that path's proxy icon.
    private func setWindowPath(_ v: CellView, _ path: String) {
        guard let win = v.window else { return }
        let url = URL(fileURLWithPath: path)
        win.title = url.lastPathComponent
        win.representedURL = url
    }

    func openFile(_ v: CellView, _ path: String) {
        withUTF8Arg(path) { ptr, len in
            tk_desktop_open_file(v.handle, ptr, len, Int64(v.cols()), Int64(v.rows()))
        }
        // File-only windows (no project loaded): title + proxy track the
        // file itself. When a project is loaded the title is the project
        // name and stays put even as additional files are opened — the
        // window represents the project, not the active buffer.
        if v.project == nil { setWindowPath(v, path) }
        v.needsDisplay = true
    }

    func openProject(_ v: CellView, _ path: String) {
        withUTF8Arg(path) { ptr, len in tk_desktop_open_project(v.handle, ptr, len) }
        v.project = path
        // Title + proxy icon: macOS convention is for project/document
        // windows to show the project name with a draggable folder proxy
        // icon next to it. `representedURL` is what makes the proxy appear;
        // AppKit picks up the icon from the URL itself (the OS folder icon
        // for a directory, the file's icon for a file). Cmd-click the title
        // for the path popover; drag the icon to other apps.
        setWindowPath(v, path)
        // Apply the per-display-config layout: size the window and float or
        // dock the tool panels per what was saved for the current set of
        // screens. New-window-at-launch paths pre-apply the main frame via
        // newWindow(frame:) so there's no visible resize flash; this also
        // restores the floating panel window when the config calls for it.
        applyGeometryForCurrentConfig(v)
        saveSession()
        v.needsDisplay = true
    }

    // One NSOpenPanel for files (multi-select) or a directory (single).
    // nil when the user cancels.
    private func runOpenPanel(directories: Bool) -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directories
        panel.canChooseDirectories = directories
        panel.allowsMultipleSelection = !directories
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return nil }
        return panel.urls
    }

    // File ▸ Open…: load the picks into `v`, or into a fresh window when
    // no window is open (dropping the user's pick on the floor is worse).
    func openFilePanel(_ v: CellView?) {
        guard let urls = runOpenPanel(directories: false) else { return }
        let target = v ?? newWindow()
        for url in urls { openFile(target, url.path) }
    }

    func openProjectPanel(_ v: CellView?) {
        guard let url = runOpenPanel(directories: true)?.first else { return }
        // A window already showing a project can't swap its root in
        // place — the Mojo Desktop is one-project-per-window and
        // open_project no-ops once a project is set (so the pick
        // would silently do nothing and never reach the recents
        // list). Open it in a fresh window instead, matching how
        // Project ▸ <recent> behaves. An empty/file-only window
        // adopts the project directly.
        if let v = v, v.project == nil {
            openProject(v, url.path)
        } else {
            openProject(newWindow(frame: loadProjectFrame(url.path)), url.path)
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
        // Closing a dialog window (Settings, Project Settings) via the red
        // button closes the view on the Mojo side too (the reverse of the
        // active-flag poll that opened the window).
        for d in dialogSurfaces {
            if let entry = dialogWins[d.surface]?.first(where: { $0.value.window === sender }) {
                if let mv = mainViewByObjectId(entry.key) {
                    d.close(mv.handle)
                    closeDialogWindow(d.surface, for: mv)
                }
                return false
            }
        }
        guard let idx = windows.firstIndex(of: sender) else { return false }
        let v = views[idx]
        // Capture the final geometry (including floating state + panel frame)
        // before teardown so the next open restores it, then drop the panel
        // window — without double-freeing the shared Desktop handle.
        if !isTerminating { saveGeometryFor(v) }
        closePanelWindow(for: v, save: false)
        for d in dialogSurfaces { closeDialogWindow(d.surface, for: v, focusMain: false) }
        let h = v.handle
        v.handle = 0
        windows.remove(at: idx)
        views.remove(at: idx)
        tabStrips[ObjectIdentifier(v)] = nil
        nativeSheets[ObjectIdentifier(v)] = nil
        pickers[ObjectIdentifier(v)] = nil
        popups[ObjectIdentifier(v)] = nil
        gitSheets[ObjectIdentifier(v)] = nil
        findBars[ObjectIdentifier(v)] = nil
        trees[ObjectIdentifier(v)] = nil
        if let p = prefsWindows.removeValue(forKey: ObjectIdentifier(v)) { p.dismiss() }
        spellingSheets[ObjectIdentifier(v)] = nil
        historySheets[ObjectIdentifier(v)] = nil
        mergeSheets[ObjectIdentifier(v)] = nil
        reviewPickers[ObjectIdentifier(v)] = nil
        reviewBars[ObjectIdentifier(v)] = nil
        paneHeaders[ObjectIdentifier(v)] = nil
        // Close is instant; the language servers get their goodbye in the
        // background. `begin_close` terminates every child except the LSP
        // transports and sends each server `shutdown`, then we poll off the
        // runloop and free once they've answered. Blocking here instead
        // would stall the close by however long the slowest server takes.
        //
        // During a Cmd+Q cascade there is no "later" to drain on — the
        // process exits as soon as applicationShouldTerminate returns — so
        // that path takes the blocking teardown.
        if isTerminating {
            tk_desktop_free(h)
        } else {
            tk_desktop_begin_close(h)
            drainClosingDesktop(h, deadline: Date().addingTimeInterval(2.0))
        }
        // Save the session each time a window closes so the on-disk state
        // matches what's open. `isTerminating` (set by applicationShould
        // Terminate during Cmd+Q) suppresses these mid-quit saves so they
        // don't rewrite the file as windows drop one-by-one.
        if !isTerminating { saveSession() }
        sender.orderOut(nil)
        return false
    }

    /// Poll a closing Desktop until its language servers have finished the
    /// LSP `shutdown` → `exit` handshake, then free it.
    ///
    /// Re-arms itself every 25 ms rather than looping, so the runloop stays
    /// responsive — the whole point is that the window is already gone. The
    /// `deadline` is the backstop: a server that never answers gets SIGTERM
    /// from `tk_desktop_free`, which is exactly what happened unconditionally
    /// before this path existed. Freeing is therefore guaranteed on both
    /// branches, which matters because the handle owns child processes.
    func drainClosingDesktop(_ h: Int64, deadline: Date) {
        if h == 0 { return }
        if tk_desktop_close_poll(h) == 1 || Date() >= deadline {
            tk_desktop_free(h)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
            guard let self = self else {
                // The app is going away; don't strand the children.
                tk_desktop_free(h)
                return
            }
            self.drainClosingDesktop(h, deadline: deadline)
        }
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

    // A second CellView over the project window's Desktop handle, rendering
    // one secondary surface (the tool panels, Settings, …).
    private func makeSurfaceView(for mainView: CellView, surface: CellSurface) -> CellView {
        let v = CellView()
        v.handle = mainView.handle    // shared Desktop, second surface
        v.surface = surface
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
            pv = makeSurfaceView(for: mainView, surface: .panels)
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

    // MARK: standalone dialog windows (Settings, Project Settings)

    private func showDialogWindow(_ d: DialogSurface, for mainView: CellView) {
        guard let mainWin = mainView.window else { return }
        let id = ObjectIdentifier(mainView)
        let sv: CellView
        let win: NSWindow
        if let existing = dialogWins[d.surface]?[id] {
            sv = existing.view; win = existing.window
        } else {
            sv = makeSurfaceView(for: mainView, surface: d.surface)
            // Centered over the project window.
            let w = d.cols * CELL_W, h = d.rows * CELL_H
            let mf = mainWin.frame
            win = UnconstrainedWindow(
                contentRect: NSRect(x: mf.midX - w / 2, y: mf.midY - h / 2,
                                    width: w, height: h),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered, defer: false)
            win.delegate = self
            win.contentView = sv
            win.makeFirstResponder(sv)
            win.acceptsMouseMovedEvents = true
            win.title = d.title
            dialogWins[d.surface, default: [:]][id] = (window: win, view: sv)
        }
        win.makeKeyAndOrderFront(nil)
        sv.invalidateFrame(); sv.needsDisplay = true
    }

    private func closeDialogWindow(_ surface: CellSurface, for mainView: CellView,
                                   focusMain: Bool = true) {
        let id = ObjectIdentifier(mainView)
        guard let pair = dialogWins[surface]?[id] else { return }
        dialogWins[surface]?.removeValue(forKey: id)
        pair.view.handle = 0          // shared handle is owned by the main view
        pair.window.orderOut(nil)     // Sequoia-safe (see windowShouldClose)
        // Hand focus back to the project window so Esc-closing the dialog
        // drops the user straight back into the editor. Skipped when the
        // project window itself is the one going away.
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


// MARK: - macOS-style UI: native dialogs
//
// With View ▸ macOS-style UI on, the core stops painting its confirm / prompt /
// save-as dialogs and describes them over `tk_desktop_native_dialog` instead.
// Each tick polls every window; a newly reported dialog is shown as a sheet,
// and the sheet's answer goes back through `tk_desktop_native_*_answer`, which
// runs the same submit handler as the in-grid dialog. If the core drops the
// dialog itself while the sheet is up, the sheet is ended without answering.

extension AppController {
    static let textFieldEditActions: [String: Selector] = [
        "edit:cut": #selector(NSText.cut(_:)),
        "edit:copy": #selector(NSText.copy(_:)),
        "edit:paste": #selector(NSText.paste(_:)),
        "edit:select-all": #selector(NSText.selectAll(_:)),
        "edit:undo": Selector(("undo:")),
        "edit:redo": Selector(("redo:")),
    ]

    /// Read a core JSON export into `buf` (growing it when the core reports
    /// a longer payload than fits). Nil when the core had nothing to say.
    private func readCoreJSON(_ buf: inout [UInt8],
                              _ fill: (Int64, Int64) -> Int64) -> Data? {
        var n = 0
        while true {
            n = buf.withUnsafeMutableBufferPointer { b -> Int in
                Int(fill(Int64(Int(bitPattern: b.baseAddress)), Int64(b.count)))
            }
            if n <= buf.count { break }
            buf = [UInt8](repeating: 0, count: n)
        }
        return n > 0 ? Data(buf[0..<n]) : nil
    }

    private func nativeDialogJSON(_ h: Int64) -> [String: Any]? {
        guard let data = readCoreJSON(&nativeDialogBuf, { tk_desktop_native_dialog(h, $0, $1) })
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Lay native headers over the docked tool panes' header rows.
    func pollPaneHeaders(_ v: CellView) -> Bool {
        let id = ObjectIdentifier(v)
        let cols = Int64(v.cols()), rows = Int64(v.rows())
        let data = readCoreJSON(&nativeDialogBuf, { tk_desktop_panes(v.handle, cols, rows, $0, $1) })
        let list = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [[String: Any]] } ?? []
        var current = paneHeaders[id] ?? [:]
        var changed = false
        var seen = Set<String>()
        for p in list {
            let key = "\(p["kind"] as? Int ?? 0):\(p["idx"] as? Int ?? 0)"
            seen.insert(key)
            let hv = current[key] ?? {
                let h = PaneHeader(view: v)
                v.addSubview(h)
                current[key] = h
                return h
            }()
            if hv.update(p) { changed = true }
        }
        for (key, hv) in current where !seen.contains(key) {
            hv.removeFromSuperview()
            current[key] = nil
            changed = true
        }
        paneHeaders[id] = current
        return changed
    }

    /// Review mode: the picker sheet while choosing, the native bar while
    /// reviewing, neither otherwise.
    func pollReview(_ v: CellView) -> Bool {
        let id = ObjectIdentifier(v)
        let cols = Int64(v.cols()), rows = Int64(v.rows())
        let data = readCoreJSON(&nativeDialogBuf, { tk_desktop_review(v.handle, cols, rows, $0, $1) })
        let o = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        let mode = o?["mode"] as? String ?? ""
        var changed = false
        // Picker sheet. It steps aside while the core asks a question of
        // its own (check out the branch?) — a window shows one sheet.
        let asking = readCoreJSON(&nativeDialogBuf, { tk_desktop_native_dialog(v.handle, $0, $1) }) != nil
        if let pc = reviewPickers[id], mode != "picker" || asking {
            reviewPickers[id] = nil
            pc.dismiss()
            changed = true
        }
        if mode == "picker", !asking, let o = o {
            if let pc = reviewPickers[id] {
                pc.update(o)
            } else if let win = v.window, win.isVisible, win.attachedSheet == nil {
                let pc = ReviewPickerController(view: v)
                reviewPickers[id] = pc
                pc.update(o)
                pc.present(in: win)
                changed = true
                // Scripted screenshots: pick a row to show the review bar.
                if isCapturing, let n = Int(ProcessInfo.processInfo.environment["TK_CAPTURE_REVIEW_PICK"] ?? "") {
                    tk_desktop_review_act(v.handle, 1, Int64(n))
                }
            }
        }
        // Reviewing bar.
        if mode == "reviewing", let o = o {
            let bar = reviewBars[id] ?? {
                let b = ReviewBar(view: v)
                v.addSubview(b)
                reviewBars[id] = b
                return b
            }()
            if bar.update(o) { changed = true }
        } else if let bar = reviewBars.removeValue(forKey: id) {
            bar.removeFromSuperview()
            changed = true
        }
        return changed
    }

    /// Show, refresh or retract `v`'s merge sheet.
    func pollMerge(_ v: CellView) -> Bool {
        let id = ObjectIdentifier(v)
        let data = readCoreJSON(&nativeDialogBuf, { tk_desktop_merge(v.handle, $0, $1) })
        if let mc = mergeSheets[id] {
            guard let data = data else {
                mergeSheets[id] = nil
                mc.dismiss()
                return true
            }
            return mc.update(data)
        }
        guard let data = data, let win = v.window, win.isVisible, win.attachedSheet == nil
        else { return false }
        let mc = MergeController(view: v)
        mc.onAfterAction = { [weak v] in v?.invalidateFrame(); v?.needsDisplay = true }
        mergeSheets[id] = mc
        _ = mc.update(data)
        mc.present(in: win)
        return true
    }

    /// Show, refresh or retract `v`'s Git history sheet.
    func pollHistory(_ v: CellView) -> Bool {
        let id = ObjectIdentifier(v)
        let data = readCoreJSON(&nativeDialogBuf, { tk_desktop_history(v.handle, $0, $1) })
        if let hc = historySheets[id] {
            guard let data = data else {
                historySheets[id] = nil
                hc.dismiss()
                return true
            }
            return hc.update(data)
        }
        guard let data = data, let win = v.window, win.isVisible, win.attachedSheet == nil
        else { return false }
        let hc = HistoryController(view: v)
        historySheets[id] = hc
        _ = hc.update(data)
        hc.present(in: win)
        return true
    }

    /// Show, refresh or retract `v`'s Spelling sheet.
    func pollSpelling(_ v: CellView) -> Bool {
        let id = ObjectIdentifier(v)
        let data = readCoreJSON(&nativeDialogBuf, { tk_desktop_spelling(v.handle, $0, $1) })
        if let sc = spellingSheets[id] {
            guard let data = data else {
                spellingSheets[id] = nil
                sc.dismiss()
                return true
            }
            return sc.update(data)
        }
        guard let data = data, let win = v.window, win.isVisible, win.attachedSheet == nil
        else { return false }
        let sc = SpellingController(view: v)
        spellingSheets[id] = sc
        _ = sc.update(data)
        sc.present(in: win)
        return true
    }

    /// Open, refresh or retire the native Settings window for `v`.
    func pollPrefs(_ v: CellView) -> Bool {
        let id = ObjectIdentifier(v)
        let data = readCoreJSON(&nativeDialogBuf, { tk_desktop_prefs(v.handle, $0, $1) })
        if let pc = prefsWindows[id] {
            guard let data = data else {
                prefsWindows[id] = nil
                pc.dismiss()
                return true
            }
            pc.update(data)
            pc.refreshLists()
            return false
        }
        guard let data = data,
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        let pc = PrefsController(values: o, view: v) { [weak self, weak v] in
            // Closed by the user: the core's Settings closes with it.
            guard let v = v else { return }
            self?.prefsWindows[ObjectIdentifier(v)] = nil
            if v.handle != 0 { tk_desktop_prefs_close(v.handle) }
        }
        prefsWindows[id] = pc
        pc.show()
        return true
    }

    /// Lay (or lift) the native source list over the file tree's cells.
    func pollTree(_ v: CellView) -> Bool {
        let id = ObjectIdentifier(v)
        let cols = Int64(v.cols()), rows = Int64(v.rows())
        guard let data = readCoreJSON(&treeBuf, { tk_desktop_tree(v.handle, cols, rows, $0, $1) }) else {
            if let t = trees[id] {
                t.removeFromSuperview()
                trees[id] = nil
                return true
            }
            return false
        }
        let t = trees[id] ?? {
            let t = FileTreeOverlay(view: v)
            v.addSubview(t)
            trees[id] = t
            return t
        }()
        return t.update(data)
    }

    /// Show the find bar when the core asked for Find / Replace; hide it
    /// when the macOS-style UI is switched off.
    func pollFindBar(_ v: CellView) -> Bool {
        let id = ObjectIdentifier(v)
        if tk_desktop_native_ui(v.handle) == 0 {
            if let fb = findBars[id], !fb.accessory.isHidden {
                fb.accessory.isHidden = true
                return true
            }
            return false
        }
        guard let data = readCoreJSON(&nativeDialogBuf, { tk_desktop_take_find_request(v.handle, $0, $1) }),
              let req = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let win = v.window
        else { return false }
        if findBars[id] == nil {
            let bar = FindBar(frame: NSRect(x: 0, y: 0, width: 600, height: 34))
            let acc = NSTitlebarAccessoryViewController()
            acc.layoutAttribute = .bottom
            acc.view = bar
            bar.onOp = { [weak v] json in
                guard let v = v, v.handle != 0 else { return }
                withUTF8Arg(json) { p, l in tk_desktop_find(v.handle, p, l) }
                v.invalidateFrame()
                v.needsDisplay = true
            }
            bar.onClose = { [weak v] in
                guard let v = v else { return }
                if let fb = self.findBars[ObjectIdentifier(v)] { fb.accessory.isHidden = true }
                v.window?.makeFirstResponder(v)
            }
            win.addTitlebarAccessoryViewController(acc)
            findBars[id] = (acc, bar)
        }
        guard let fb = findBars[id] else { return false }
        fb.accessory.isHidden = false
        fb.bar.show(req)
        return true
    }

    /// Show, refresh or retract `v`'s native git sheet.
    func pollGit(_ v: CellView) -> Bool {
        let id = ObjectIdentifier(v)
        let cols = Int64(v.cols()), rows = Int64(v.rows())
        let data = readCoreJSON(&nativeDialogBuf, { tk_desktop_git(v.handle, cols, rows, $0, $1) })
        if let gc = gitSheets[id] {
            guard let data = data else {
                gitSheets[id] = nil
                gc.dismiss()
                return true
            }
            return gc.update(data)
        }
        guard let data = data, let win = v.window, win.isVisible, win.attachedSheet == nil
        else { return false }
        let gc = GitController(view: v)
        gc.onAfterAction = { [weak v] in
            v?.invalidateFrame()
            v?.needsDisplay = true
        }
        gitSheets[id] = gc
        _ = gc.update(data)
        gc.present(in: win)
        return true
    }

    /// Pop the core's anchored popup up as an NSMenu, or refresh the one
    /// that's open (quick fixes land while it's tracking).
    func pollPopup(_ v: CellView) -> Bool {
        let id = ObjectIdentifier(v)
        let data = readCoreJSON(&nativeDialogBuf, { tk_desktop_popup(v.handle, $0, $1) })
        if let open = popups[id] {
            if let data = data { open.refresh(data) }
            return false
        }
        guard let data = data, let win = v.window, win.isVisible, win.attachedSheet == nil
        else { return false }
        let pm = PopupMenu(view: v)
        popups[id] = pm
        pm.refresh(data)
        // Pop up outside the timer callback: NSMenu tracking is a nested
        // run loop, and the tick has to keep running (common modes) under it.
        DispatchQueue.main.async { [weak self, weak v] in
            guard let self = self, let v = v else { return }
            let code = pm.track()
            self.popups[id] = nil
            guard v.handle != 0 else { return }
            let act = tk_desktop_popup_choose(v.handle, Int64(code))
            self.handleHostAction(act, sourceHandle: v.handle, view: v)
            v.invalidateFrame()
            v.needsDisplay = true
        }
        return true
    }

    /// Show, refresh or retract `v`'s native picker sheet. True on change.
    func pollPicker(_ v: CellView) -> Bool {
        let id = ObjectIdentifier(v)
        let data = readCoreJSON(&nativeDialogBuf, { tk_desktop_picker(v.handle, $0, $1) })
        let state = data.flatMap {
            (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
        }
        if let pc = pickers[id] {
            guard let state = state, state["kind"] as? String == pc.kind else {
                pickers[id] = nil
                pc.dismiss()
                return true
            }
            return pc.update(state, raw: data!)
        }
        guard let state = state, let kind = state["kind"] as? String,
              let win = v.window, win.isVisible, win.attachedSheet == nil
        else { return false }
        let pc = PickerController(kind: kind, view: v)
        pc.onActivate = { [weak self, weak v] code in
            guard let self = self, let v = v else { return }
            self.handleHostAction(code, sourceHandle: v.handle, view: v)
            v.invalidateFrame()
            v.needsDisplay = true
        }
        pickers[id] = pc
        _ = pc.update(state, raw: data!)
        pc.present(in: win)
        if isCapturing, let q = ProcessInfo.processInfo.environment["TK_CAPTURE_PICKER_QUERY"] {
            pc.typeQuery(q)   // scripted screenshots: show real results
        }
        return true
    }

    /// Show / hide / refresh `v`'s native tab strip. True when it changed.
    func pollTabStrip(_ v: CellView) -> Bool {
        guard let win = v.window else { return false }
        let id = ObjectIdentifier(v)
        let on = tk_desktop_native_ui(v.handle) != 0
        if tabStrips[id] == nil {
            guard on else { return false }
            let strip = TabStripView(frame: NSRect(x: 0, y: 0, width: 400, height: TabStripView.height))
            let acc = NSTitlebarAccessoryViewController()
            acc.layoutAttribute = .bottom
            acc.view = strip
            strip.onSelect = { [weak self, weak v] i in
                guard let self = self, let v = v, v.handle != 0 else { return }
                let code = tk_desktop_tab_select(v.handle, Int64(i), Int64(v.cols()), Int64(v.rows()))
                self.handleHostAction(code, sourceHandle: v.handle, view: v)
                v.window?.makeFirstResponder(v)
                v.invalidateFrame()
                v.needsDisplay = true
            }
            strip.onClose = { [weak v] i in
                guard let v = v, v.handle != 0 else { return }
                tk_desktop_tab_close(v.handle, Int64(i))
                v.invalidateFrame()
                v.needsDisplay = true
            }
            win.addTitlebarAccessoryViewController(acc)
            tabStrips[id] = (acc, strip)
        }
        guard let entry = tabStrips[id] else { return false }
        var changed = false
        let data = on ? readCoreJSON(&tabsBuf, { tk_desktop_tabs(v.handle, $0, $1) }) : nil
        if let data = data { changed = entry.strip.update(from: data) }
        // No payload means "no strip" (e.g. during review), not "unchanged".
        let hidden = !on || data == nil || entry.strip.tabs.isEmpty
        if entry.accessory.isHidden != hidden {
            entry.accessory.isHidden = hidden
            changed = true
        }
        return changed
    }

    /// First launch: ask for the look (macOS-style or retro), theme and font.
    /// Scripted captures skip it unless TK_WELCOME asks for it.
    func showWelcomeIfNeeded() { showWelcome(force: false) }

    /// `force`: from TurboKod ▸ Welcome to TurboKod…, regardless of whether
    /// it was answered before.
    func showWelcome(force: Bool) {
        let env = ProcessInfo.processInfo.environment
        if let w = welcome { w.window.makeKeyAndOrderFront(nil); return }
        guard force || !isCapturing || env["TK_WELCOME"] != nil else { return }
        let h = views.first?.handle ?? chromeDesktop
        guard h != 0, force || tk_desktop_welcome_needed(h) != 0 || env["TK_WELCOME"] != nil,
              let data = readCoreJSON(&nativeDialogBuf, { tk_desktop_welcome_options(h, $0, $1) }),
              let opts = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        let w = WelcomeController(options: opts, palette: { [weak self] in
            var p = [UInt32](repeating: 0, count: 256)
            let h = self?.views.first?.handle ?? self?.chromeDesktop ?? 0
            if h != 0 {
                p.withUnsafeMutableBufferPointer { b in
                    _ = tk_theme_palette(h, Int64(Int(bitPattern: b.baseAddress)), Int64(b.count))
                }
            }
            return p
        }) { [weak self] json, done in
            guard let self = self else { return }
            let h = self.views.first?.handle ?? self.chromeDesktop
            guard h != 0 else { return }
            withUTF8Arg(json) { p, l in tk_desktop_welcome_apply(h, p, l, done ? 1 : 0) }
            for v in self.views { v.invalidateFrame(); v.needsDisplay = true }
            if done { self.welcome = nil }
        }
        welcome = w
        w.show()
    }

    /// Show, or retract, `v`'s native dialog. True when anything changed.
    func pollNativeDialog(_ v: CellView) -> Bool {
        let id = ObjectIdentifier(v)
        let dialog = nativeDialogJSON(v.handle)
        if let sheet = nativeSheets[id] {
            if dialog == nil {
                nativeSheets[id] = nil
                sheet.sheetParent?.endSheet(sheet, returnCode: .abort)
                return true
            }
            return false
        }
        guard let dialog = dialog, let kind = dialog["kind"] as? String,
              let win = v.window, win.isVisible, win.attachedSheet == nil
        else { return false }
        switch kind {
        case "confirm": showConfirmSheet(dialog, for: v, in: win)
        case "prompt": showPromptSheet(dialog, for: v, in: win)
        case "save_as": showSavePanel(dialog, for: v, in: win)
        case "choice": showChoiceSheet(dialog, for: v, in: win)
        case "color": showColorSheet(dialog, for: v, in: win)
        case "form": showFormSheet(dialog, for: v, in: win)
        default: return false
        }
        return true
    }

    /// Common tail for every sheet: forget it, run the answer, and act on
    /// whatever host action the core's submit handler handed back.
    private func finishNativeSheet(_ v: CellView, _ answer: () -> Int32) {
        nativeSheets[ObjectIdentifier(v)] = nil
        guard v.handle != 0 else { return }
        let code = answer()
        handleHostAction(code, sourceHandle: v.handle, view: v)
        v.invalidateFrame()
        v.needsDisplay = true
    }

    private func showConfirmSheet(_ d: [String: Any], for v: CellView, in win: NSWindow) {
        let labels = d["buttons"] as? [String] ?? []
        guard !labels.isEmpty else { return }
        let def = min(max(d["default"] as? Int ?? 0, 0), labels.count - 1)
        let destructive = d["destructive"] as? Int ?? -1
        let alert = NSAlert()
        alert.messageText = d["message"] as? String ?? ""
        alert.alertStyle = destructive >= 0 ? .warning : .informational
        // NSAlert lays buttons out right to left and gives the first one
        // Return: add the default, then the rest from the right, so the row
        // reads in the core's left-to-right order with the default rightmost.
        var order = [def]
        for i in stride(from: labels.count - 1, through: 0, by: -1) where i != def {
            order.append(i)
        }
        for (pos, i) in order.enumerated() {
            let b = alert.addButton(withTitle: labels[i])
            if i == destructive { b.hasDestructiveAction = true }
            if labels[i] == "Cancel" {
                b.keyEquivalent = "\u{1b}"
            } else if pos > 0, let c = labels[i].lowercased().first {
                // The in-grid dialog answers to each label's first letter;
                // natively that's the ⌘-letter convention (⌘D, Don't Save).
                b.keyEquivalent = String(c)
                b.keyEquivalentModifierMask = .command
            }
        }
        nativeSheets[ObjectIdentifier(v)] = alert.window
        alert.beginSheetModal(for: win) { [weak self, weak v] resp in
            guard let self = self, let v = v, resp != .abort else { return }
            let pos = resp.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            let choice = pos >= 0 && pos < order.count ? order[pos] : -1
            self.finishNativeSheet(v) { tk_desktop_native_confirm_answer(v.handle, Int64(choice)) }
        }
    }

    private func showPromptSheet(_ d: [String: Any], for v: CellView, in win: NSWindow) {
        let alert = NSAlert()
        var label = (d["label"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        if label.hasSuffix(":") { label.removeLast() }
        alert.messageText = label
        alert.addButton(withTitle: d["action"] as? String ?? "OK")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
        field.stringValue = d["text"] as? String ?? ""
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        nativeSheets[ObjectIdentifier(v)] = alert.window
        alert.beginSheetModal(for: win) { [weak self, weak v] resp in
            guard let self = self, let v = v, resp != .abort else { return }
            let ok = resp == .alertFirstButtonReturn
            let text = field.stringValue
            self.finishNativeSheet(v) {
                withUTF8Arg(text) { ptr, len in
                    tk_desktop_native_prompt_answer(v.handle, ptr, len, ok ? 1 : 0)
                }
            }
        }
    }

    /// A list of named actions from a language server (or the color
    /// presentations of a color): one button per action, plus Dismiss.
    private func showChoiceSheet(_ d: [String: Any], for v: CellView, in win: NSWindow) {
        let actions = d["actions"] as? [String] ?? []
        let alert = NSAlert()
        alert.messageText = d["message"] as? String ?? ""
        for a in actions { alert.addButton(withTitle: a) }
        alert.addButton(withTitle: actions.isEmpty ? "OK" : "Dismiss").keyEquivalent = "\u{1b}"
        nativeSheets[ObjectIdentifier(v)] = alert.window
        alert.beginSheetModal(for: win) { [weak self, weak v] resp in
            guard let self = self, let v = v, resp != .abort else { return }
            let i = resp.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            let index = i >= 0 && i < actions.count ? i : -1
            self.finishNativeSheet(v) { tk_desktop_native_choice_answer(v.handle, Int64(index)); return 0 }
        }
    }

    /// The color under the swatch: a system color well (it opens the macOS
    /// color panel) and the notation to write it back in.
    private func showColorSheet(_ d: [String: Any], for v: CellView, in win: NSWindow) {
        let rgb = d["rgb"] as? Int ?? 0
        let well = NSColorWell(frame: NSRect(x: 0, y: 34, width: 280, height: 44))
        if #available(macOS 13.0, *) { well.colorWellStyle = .expanded }
        well.color = PickerController.rgb(rgb)
        let format = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        format.addItems(withTitles: ["OkLab", "RGB", "HSL"])
        format.selectItem(at: d["mode"] as? Int ?? 0)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 80))
        box.addSubview(well)
        box.addSubview(format)
        let alert = NSAlert()
        alert.messageText = "Color"
        alert.informativeText = "Pick a color; it's written back in the notation below."
        alert.accessoryView = box
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        nativeSheets[ObjectIdentifier(v)] = alert.window
        alert.beginSheetModal(for: win) { [weak self, weak v] resp in
            guard let self = self, let v = v, resp != .abort else { return }
            NSColorPanel.shared.orderOut(nil)
            let c = well.color.usingColorSpace(.sRGB) ?? well.color
            let packed = (Int((c.redComponent * 255).rounded()) << 16)
                | (Int((c.greenComponent * 255).rounded()) << 8)
                | Int((c.blueComponent * 255).rounded())
            let ok = resp == .alertFirstButtonReturn
            let mode = format.indexOfSelectedItem
            self.finishNativeSheet(v) {
                tk_desktop_native_color_answer(v.handle, Int64(packed), Int64(mode), ok ? 1 : 0)
                return 0
            }
        }
    }

    /// A small form (Fill, Breakpoint, a failed breakpoint condition): one
    /// native control per field in a grid, the dialog's own buttons (the
    /// first is the default, the last is Cancel).
    private func showFormSheet(_ d: [String: Any], for v: CellView, in win: NSWindow) {
        let alert = NSAlert()
        alert.messageText = d["title"] as? String ?? ""
        alert.informativeText = d["message"] as? String ?? ""
        var rows: [[NSView]] = []
        var read: [String: () -> Any] = [:]
        for f in d["fields"] as? [[String: Any]] ?? [] {
            let id = f["id"] as? String ?? ""
            let label = NSTextField(labelWithString: (f["label"] as? String ?? "") + ":")
            label.alignment = .right
            switch f["type"] as? String ?? "" {
            case "check":
                let cb = NSButton(checkboxWithTitle: f["label"] as? String ?? "", target: nil, action: nil)
                cb.state = (f["value"] as? Bool ?? false) ? .on : .off
                rows.append([NSGridCell.emptyContentView, cb])
                read[id] = { cb.state == .on }
            case "choice":
                let pop = NSPopUpButton()
                pop.addItems(withTitles: f["options"] as? [String] ?? [])
                pop.selectItem(at: f["value"] as? Int ?? 0)
                rows.append([label, pop])
                read[id] = { pop.indexOfSelectedItem }
            case "info":
                let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 90))
                let tv = NSTextView(frame: sv.bounds)
                tv.isEditable = false
                tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                tv.string = f["value"] as? String ?? ""
                tv.autoresizingMask = [.width]
                sv.documentView = tv
                sv.hasVerticalScroller = true
                sv.borderType = .bezelBorder
                sv.heightAnchor.constraint(equalToConstant: 90).isActive = true
                rows.append([label, sv])
            default:
                let tf = NSTextField(string: f["value"] as? String ?? "")
                tf.usesSingleLineMode = true
                rows.append([label, tf])
                read[id] = { tf.stringValue }
            }
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 300
        grid.layoutSubtreeIfNeeded()
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)
        alert.accessoryView = grid
        let buttons = d["buttons"] as? [String] ?? ["OK", "Cancel"]
        for (i, b) in buttons.enumerated() {
            let btn = alert.addButton(withTitle: b)
            if i == buttons.count - 1 { btn.keyEquivalent = "\u{1b}" }
        }
        nativeSheets[ObjectIdentifier(v)] = alert.window
        alert.beginSheetModal(for: win) { [weak self, weak v] resp in
            guard let self = self, let v = v, resp != .abort else { return }
            let button = resp.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            var values: [String: Any] = [:]
            for (k, r) in read { values[k] = r() }
            let json = (try? JSONSerialization.data(withJSONObject: values))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            self.finishNativeSheet(v) {
                withUTF8Arg(json) { p, l in
                    tk_desktop_native_form_answer(v.handle, Int64(button), p, l)
                }
                return 0
            }
        }
    }

    private func showSavePanel(_ d: [String: Any], for v: CellView, in win: NSWindow) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        let dir = d["dir"] as? String ?? ""
        if !dir.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: dir, isDirectory: true)
        }
        panel.nameFieldStringValue = d["name"] as? String ?? ""
        nativeSheets[ObjectIdentifier(v)] = panel
        panel.beginSheetModal(for: win) { [weak self, weak v] resp in
            guard let self = self, let v = v, resp != .abort else { return }
            let path = resp == .OK ? (panel.url?.path ?? "") : ""
            self.finishNativeSheet(v) {
                withUTF8Arg(path) { ptr, len in
                    tk_desktop_native_save_as_answer(v.handle, ptr, len)
                }
                return 0
            }
        }
    }
}


// MARK: - macOS-style UI: tab strip
//
// One tab per core window (index order, so an index goes straight back to
// `tk_desktop_tab_select` / `_tab_close`), drawn with system colors so it
// follows light / dark appearance. Close button on the left, Safari-style;
// an unsaved tab shows a dot there until hovered.

struct TabInfo: Equatable {
    var title: String
    var path: String
    var dirty: Bool
}

final class TabStripView: NSView {
    static let height: CGFloat = 30
    private static let maxTabW: CGFloat = 260
    private static let minTabW: CGFloat = 64
    private static let closeSize: CGFloat = 16
    // A roomy tab: close button 5pt in, the title right after it, 8pt of
    // air on the right. A squeezed tab gives the close slot to the title
    // (the button then overlays the name's start, on hover only).
    private static let pad: CGFloat = 8
    private static let closeSlot: CGFloat = 5 + closeSize

    private(set) var tabs: [TabInfo] = []
    private(set) var focused = -1
    private var lastData = Data()
    private var hover = -1
    private var hoverClose = false
    private var frames: [NSRect] = []
    private var layoutWidth: CGFloat = -1
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Adopt a `tk_desktop_tabs` payload; true when it changed anything.
    func update(from data: Data) -> Bool {
        if data == lastData { return false }
        lastData = data
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        focused = obj["focused"] as? Int ?? -1
        tabs = (obj["tabs"] as? [[String: Any]] ?? []).map {
            TabInfo(title: $0["title"] as? String ?? "",
                    path: $0["path"] as? String ?? "",
                    dirty: $0["dirty"] as? Bool ?? false)
        }
        if hover >= tabs.count { hover = -1 }
        layoutWidth = -1
        needsDisplay = true
        return true
    }

    private static func font(selected: Bool) -> NSFont {
        .systemFont(ofSize: 12, weight: selected ? .medium : .regular)
    }

    private func titleWidth(_ s: String, selected: Bool) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: Self.font(selected: selected)]).width)
    }

    /// Tabs take their title's width. Only when they don't all fit do the
    /// widest shrink — down to a shared cap, so short names never pay for
    /// long ones.
    private func layoutTabs() {
        guard layoutWidth != bounds.width else { return }
        layoutWidth = bounds.width
        let natural = tabs.indices.map { naturalWidth($0) }
        let avail = bounds.width - 16
        var widths = natural
        if natural.reduce(0, +) > avail && !natural.isEmpty {
            // Largest cap c with sum(min(w, c)) <= avail.
            let sorted = natural.sorted()
            var rest = avail
            var cap = Self.minTabW
            for (k, w) in sorted.enumerated() {
                let share = rest / CGFloat(sorted.count - k)
                if w <= share { rest -= w } else { cap = max(Self.minTabW, share); break }
            }
            widths = natural.map { min($0, cap) }
        }
        var x: CGFloat = 8
        frames = widths.map { w in
            defer { x += w }
            return NSRect(x: x, y: 3, width: w, height: bounds.height - 6)
        }
    }

    private func naturalWidth(_ i: Int) -> CGFloat {
        min(Self.maxTabW, max(Self.minTabW,
            titleWidth(tabs[i].title, selected: true) + Self.closeSlot + 2 * Self.pad))
    }

    private func squeezed(_ i: Int) -> Bool { tabRect(i).width < naturalWidth(i) - 0.5 }

    private func tabRect(_ i: Int) -> NSRect {
        layoutTabs()
        return i < frames.count ? frames[i] : .zero
    }

    private func closeRect(_ i: Int) -> NSRect {
        let r = tabRect(i)
        return NSRect(x: r.minX + 5, y: r.midY - Self.closeSize / 2,
                      width: Self.closeSize, height: Self.closeSize)
    }

    private func index(at p: NSPoint) -> Int {
        for i in tabs.indices where tabRect(i).contains(p) { return i }
        return -1
    }

    /// `title` cut to `width`: the extension goes first (it's the least
    /// telling part of a file name), then the end of the stem.
    private func fitted(_ title: String, _ width: CGFloat, selected: Bool) -> String {
        if titleWidth(title, selected: selected) <= width { return title }
        var stem = title
        if let dot = title.lastIndex(of: "."), dot != title.startIndex {
            stem = String(title[..<dot])
            if titleWidth(stem, selected: selected) <= width { return stem }
        }
        var chars = Array(stem)
        while chars.count > 1 {
            chars.removeLast()
            let s = String(chars) + "…"
            if titleWidth(s, selected: selected) <= width { return s }
        }
        return String(chars) + "…"
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutWidth = -1
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        for i in tabs.indices {
            let r = tabRect(i)
            let selected = i == focused
            if selected {
                let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
                NSColor.controlBackgroundColor.setFill()
                path.fill()
                NSColor.separatorColor.setStroke()
                path.lineWidth = 0.5
                path.stroke()
            } else {
                if i == hover {
                    NSColor.labelColor.withAlphaComponent(0.06).setFill()
                    NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
                }
                // Hairline divider, skipped next to the selected tab.
                if i + 1 < tabs.count && i + 1 != focused && i + 1 != hover && i != hover {
                    NSColor.separatorColor.setFill()
                    NSRect(x: r.maxX - 0.5, y: r.minY + 6, width: 1, height: r.height - 12).fill()
                }
            }
            let font = Self.font(selected: selected)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: selected ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ]
            // Squeezed: the title takes the close slot (minus room for an
            // unsaved dot); the close button overlays it on hover.
            let left: CGFloat = squeezed(i) ? (tabs[i].dirty ? 19 : Self.pad)
                                            : Self.pad + Self.closeSlot - 4
            let room = max(0, r.width - left - Self.pad)
            let text = fitted(tabs[i].title, room, selected: selected)
            let textH = font.ascender - font.descender + font.leading
            (text as NSString).draw(at: NSPoint(x: r.minX + left, y: r.midY - textH / 2),
                                    withAttributes: attrs)
            drawCloseOrDot(i, selected: selected)
        }
    }

    private func drawCloseOrDot(_ i: Int, selected: Bool) {
        let c = closeRect(i)
        if i == hover {
            if squeezed(i) {
                // Overlays the title's first letters: give it a backing.
                (selected ? NSColor.controlBackgroundColor : NSColor.windowBackgroundColor).setFill()
                NSBezierPath(roundedRect: c.insetBy(dx: -2, dy: -1), xRadius: 4, yRadius: 4).fill()
            }
            if hoverClose {
                NSColor.labelColor.withAlphaComponent(0.1).setFill()
                NSBezierPath(roundedRect: c, xRadius: 4, yRadius: 4).fill()
            }
            let cfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            if let img = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")?
                .withSymbolConfiguration(cfg) {
                let tinted = img.copy() as! NSImage
                tinted.lockFocus()
                NSColor.secondaryLabelColor.set()
                NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
                tinted.unlockFocus()
                let s = tinted.size
                tinted.draw(in: NSRect(x: c.midX - s.width / 2, y: c.midY - s.height / 2,
                                       width: s.width, height: s.height),
                            from: .zero, operation: .sourceOver, fraction: 1,
                            respectFlipped: true, hints: nil)
            }
        } else if tabs[i].dirty {
            (selected ? NSColor.labelColor : NSColor.secondaryLabelColor).setFill()
            NSBezierPath(ovalIn: NSRect(x: c.midX - 3.5, y: c.midY - 3.5, width: 7, height: 7)).fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    private func setHover(_ p: NSPoint?) {
        let i = p.map { index(at: $0) } ?? -1
        let onClose = i >= 0 && p.map { closeRect(i).contains($0) } == true
        if i != hover || onClose != hoverClose {
            hover = i
            hoverClose = onClose
            needsDisplay = true
        }
    }

    override func mouseMoved(with e: NSEvent) { setHover(convert(e.locationInWindow, from: nil)) }
    override func mouseExited(with e: NSEvent) { setHover(nil) }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let i = index(at: p)
        guard i >= 0 else { return }
        if closeRect(i).contains(p) { onClose?(i) } else { onSelect?(i) }
    }

    override func otherMouseDown(with e: NSEvent) {
        // Middle click closes, as in every browser.
        let i = index(at: convert(e.locationInWindow, from: nil))
        if i >= 0 && e.buttonNumber == 2 { onClose?(i) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let i = index(at: convert(event.locationInWindow, from: nil))
        guard i >= 0 else { return nil }
        let menu = NSMenu()
        menu.addItem(TabMenuItem("Close Tab") { [weak self] in self?.onClose?(i) })
        let path = tabs[i].path
        if !path.isEmpty {
            menu.addItem(.separator())
            menu.addItem(TabMenuItem("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            })
            menu.addItem(TabMenuItem("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            })
        }
        return menu
    }
}

/// An NSMenuItem that runs a closure — the tab strip's context menu.
final class TabMenuItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }
    @objc private func fire() { run() }
}


// MARK: - macOS-style UI: picker sheet
//
// Quick Open, Find Symbol and Find in Project as one native sheet. The core
// keeps the search machinery (file indexer, symbol index, rg runners); this
// pushes the fields' text in (`tk_desktop_picker_set`), mirrors `count` /
// `selected` / `status` from the polled state, and fetches only the rows the
// table actually shows (`tk_desktop_picker_rows`). Return / double-click
// runs the core's own submit path (`tk_desktop_picker_activate`).

final class PickerController: NSObject, NSTableViewDataSource, NSTableViewDelegate,
                              NSSearchFieldDelegate {
    let kind: String
    weak var view: CellView?
    var onActivate: ((Int32) -> Void)?

    private let panel: NSPanel
    private let search = NSSearchField()
    private var replaceField: NSTextField?
    private var scopeField: NSTextField?
    private var globField: NSTextField?
    private var toggles: [String: NSButton] = [:]
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private var actionButton: NSButton?
    private var previewView: NSTextView?
    private var splitView: NSSplitView?

    private var count = 0
    private var selected = -1
    private var multi = false
    private var lastRaw = Data()
    private var rows: [Int: [String: Any]] = [:]
    private var rowBuf = [UInt8](repeating: 0, count: 16384)
    private var previewKey = ""
    private var syncingSelection = false
    private var dismissed = false

    private var isFind: Bool { kind == "project_find" }

    init(kind: String, view: CellView) {
        self.kind = kind
        self.view = view
        let size = kind == "project_find" ? NSSize(width: 920, height: 660)
                                          : NSSize(width: 640, height: 440)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        super.init()
        panel.minSize = NSSize(width: 420, height: 260)
        build()
    }

    // MARK: layout

    private func build() {
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        search.placeholderString = kind == "quick_open" ? "File name"
            : kind == "find_symbol" || kind == "symbol_pick" ? "Symbol name" : "Search"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.font = .systemFont(ofSize: 15)

        var topRows: [NSView] = [titleLabel, search]
        if isFind {
            let rf = field("Replace with")
            replaceField = rf
            topRows.append(rf)
            let sf = field("In folder (relative to project)")
            let gf = field("Files, e.g. *.py, !tests/**")
            scopeField = sf
            globField = gf
            var row: [NSView] = [sf, gf]
            for (key, label, tip) in [("case", "Aa", "Match case"),
                                      ("word", "W", "Whole word"),
                                      ("regex", ".*", "Regular expression")] {
                let b = NSButton(title: label, target: self, action: #selector(toggleChanged(_:)))
                b.setButtonType(.pushOnPushOff)
                b.bezelStyle = .recessed
                b.toolTip = tip
                b.identifier = NSUserInterfaceItemIdentifier(key)
                toggles[key] = b
                row.append(b)
            }
            let h = NSStackView(views: row)
            h.distribution = .fill
            h.spacing = 6
            sf.setContentHuggingPriority(.defaultLow, for: .horizontal)
            gf.setContentHuggingPriority(.defaultLow, for: .horizontal)
            sf.widthAnchor.constraint(equalTo: gf.widthAnchor).isActive = true
            topRows.append(h)
        }

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 40
        table.style = .inset
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(activateClicked)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        var middle: NSView = scroll
        if isFind {
            let tv = NSTextView()
            tv.isEditable = false
            tv.isRichText = true
            tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            tv.textContainerInset = NSSize(width: 6, height: 6)
            tv.isHorizontallyResizable = true
            tv.textContainer?.widthTracksTextView = false
            tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                     height: CGFloat.greatestFiniteMagnitude)
            let ps = NSScrollView()
            ps.documentView = tv
            ps.hasVerticalScroller = true
            ps.hasHorizontalScroller = true
            previewView = tv
            let split = NSSplitView()
            split.isVertical = false
            split.dividerStyle = .thin
            split.addArrangedSubview(scroll)
            split.addArrangedSubview(ps)
            split.setHoldingPriority(.defaultLow, forSubviewAt: 1)
            middle = split
            splitView = split
        }

        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let open = NSButton(title: kind == "find_symbol" || kind == "symbol_pick" ? "Go to Symbol"
                                 : kind == "reference_pick" ? "Go to Reference" : "Open",
                            target: self, action: #selector(activateClicked))
        open.keyEquivalent = "\r"
        var bottom: [NSView] = [status, NSView(), cancel]
        if isFind {
            let b = NSButton(title: "Show in Panel", target: self, action: #selector(actionClicked))
            actionButton = b
            bottom.append(b)
        }
        bottom.append(open)
        let bar = NSStackView(views: bottom)
        bar.spacing = 8

        // Fields on top, the button bar at the bottom, and the list (plus
        // preview) taking every point in between.
        let top = NSStackView(views: topRows)
        top.orientation = .vertical
        top.distribution = .fill
        top.alignment = .leading
        top.spacing = 8
        for v in topRows {
            v.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true
        }
        for v in [top, bar] {
            v.setHuggingPriority(.required, for: .vertical)
            v.setContentHuggingPriority(.defaultHigh, for: .vertical)
        }
        middle.setContentHuggingPriority(.defaultLow, for: .vertical)
        let content = NSView()
        for v in [top, middle, bar] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
                v.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            ])
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            middle.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            bar.topAnchor.constraint(equalTo: middle.bottomAnchor, constant: 10),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            middle.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
        // The list wants all the height there is; the field rows and the
        // button bar keep their natural size.
        let grow = middle.heightAnchor.constraint(equalTo: content.heightAnchor)
        grow.priority = NSLayoutConstraint.Priority(500)
        grow.isActive = true
        panel.contentView = content
        panel.initialFirstResponder = search
    }

    private func field(_ placeholder: String) -> NSTextField {
        let f = NSTextField()
        f.placeholderString = placeholder
        f.delegate = self
        f.usesSingleLineMode = true
        f.cell?.isScrollable = true
        return f
    }

    func present(in win: NSWindow) {
        // Never taller or wider than the window it hangs from.
        let room = win.contentLayoutRect.size
        let want = panel.frame.size
        panel.setContentSize(NSSize(width: min(want.width, room.width - 40),
                                    height: min(want.height, room.height - 20)))
        panel.contentView?.layoutSubtreeIfNeeded()
        if let split = splitView {
            split.setPosition(split.bounds.height * 0.55, ofDividerAt: 0)
        }
        win.beginSheet(panel, completionHandler: nil)
        panel.makeFirstResponder(search)
    }

    func typeQuery(_ q: String) {
        search.stringValue = q
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
    }

    func dismiss() {
        guard !dismissed else { return }
        dismissed = true
        panel.sheetParent?.endSheet(panel)
    }

    // MARK: state from the core

    /// Adopt a polled state; true when anything changed.
    func update(_ st: [String: Any], raw: Data) -> Bool {
        if raw == lastRaw { return refreshVisibleRows() }
        let first = lastRaw.isEmpty
        lastRaw = raw
        titleLabel.stringValue = st["title"] as? String ?? ""
        status.stringValue = st["status"] as? String ?? ""
        multi = st["multi"] as? Bool ?? false
        table.allowsMultipleSelection = multi
        if first {
            // The core seeds the fields (a resumed search, the editor's
            // selection); after that the fields are the user's.
            search.stringValue = st["query"] as? String ?? ""
            replaceField?.stringValue = st["replace"] as? String ?? ""
            scopeField?.stringValue = st["scope"] as? String ?? ""
            globField?.stringValue = st["glob"] as? String ?? ""
            for (k, b) in toggles { b.state = (st[k] as? Bool ?? false) ? .on : .off }
            if isFind {
                let rm = st["replace_mode"] as? Bool ?? false
                replaceField?.isHidden = !rm
                actionButton?.title = rm ? "Replace All" : "Show in Panel"
            }
            DispatchQueue.main.async { self.search.currentEditor()?.selectAll(nil) }
            // A list with nothing to type into (References) drops the field.
            search.isHidden = !(st["searchable"] as? Bool ?? true)
        }
        actionButton?.isEnabled = (st["count"] as? Int ?? 0) > 0
        count = st["count"] as? Int ?? 0
        let sel = st["selected"] as? Int ?? -1
        rows.removeAll(keepingCapacity: true)
        table.reloadData()
        syncingSelection = true
        if sel >= 0 && sel < count {
            if !table.selectedRowIndexes.contains(sel) || !multi {
                table.selectRowIndexes(IndexSet(integer: sel), byExtendingSelection: false)
            }
            if sel != selected { table.scrollRowToVisible(sel) }
        } else {
            table.deselectAll(nil)
        }
        syncingSelection = false
        selected = sel
        refreshPreview()
        return true
    }

    /// Rows can change under an unchanged state (Find Symbol re-ranks as
    /// sources land): re-fetch what's visible and redraw on a difference.
    private func refreshVisibleRows() -> Bool {
        let vis = table.rows(in: table.visibleRect)
        guard vis.length > 0, let fresh = fetch(vis.location, vis.length) else { return false }
        var changed = false
        for (i, r) in fresh.enumerated() {
            let idx = vis.location + i
            if !NSDictionary(dictionary: r).isEqual(to: rows[idx] ?? [:]) {
                rows[idx] = r
                changed = true
            }
        }
        if changed {
            table.reloadData(forRowIndexes: IndexSet(integersIn: vis.location..<(vis.location + vis.length)),
                             columnIndexes: IndexSet(integer: 0))
        }
        return changed
    }

    private func fetch(_ start: Int, _ n: Int) -> [[String: Any]]? {
        guard let h = view?.handle, h != 0 else { return nil }
        var buf = rowBuf
        var len = 0
        while true {
            len = buf.withUnsafeMutableBufferPointer { b -> Int in
                Int(tk_desktop_picker_rows(h, Int64(start), Int64(n),
                    Int64(Int(bitPattern: b.baseAddress)), Int64(b.count)))
            }
            if len <= buf.count { break }
            buf = [UInt8](repeating: 0, count: len)
        }
        rowBuf = buf
        guard len > 0 else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(buf[0..<len]))) as? [[String: Any]]
    }

    private func row(_ i: Int) -> [String: Any] {
        if let r = rows[i] { return r }
        let page = 64
        let start = (i / page) * page
        if let got = fetch(start, page) {
            for (k, r) in got.enumerated() { rows[start + k] = r }
        }
        return rows[i] ?? [:]
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row i: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("pickerCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? PickerCell) ?? {
            let c = PickerCell(); c.identifier = id; return c
        }()
        let r = row(i)
        if isFind {
            let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            let s = NSMutableAttributedString(string: r["pre"] as? String ?? "",
                                              attributes: [.font: mono])
            if let hit = r["hit"] as? String {
                s.append(NSAttributedString(string: hit, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
                    .backgroundColor: NSColor.findHighlightColor.withAlphaComponent(0.6),
                    .foregroundColor: NSColor.black,
                ]))
            }
            s.append(NSAttributedString(string: r["post"] as? String ?? "", attributes: [.font: mono]))
            cell.title.attributedStringValue = s
        } else {
            cell.title.font = .systemFont(ofSize: 13, weight: .medium)
            cell.title.stringValue = r["title"] as? String ?? ""
        }
        cell.detail.stringValue = r["detail"] as? String ?? ""
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncingSelection, let h = view?.handle, h != 0 else { return }
        let (idx, anchor) = selectionEnds()
        guard idx >= 0 else { return }
        selected = idx
        tk_desktop_picker_select(h, Int64(idx), Int64(anchor))
        refreshPreview()
    }

    /// The cursor row and the far end of a contiguous multi-selection.
    private func selectionEnds() -> (Int, Int) {
        let rowsSel = table.selectedRowIndexes
        guard let first = rowsSel.first, let last = rowsSel.last else { return (-1, -1) }
        if rowsSel.count == 1 { return (first, first) }
        // The cursor is whichever end the user moved last; AppKit doesn't
        // say, so take the end that isn't the core's previous cursor.
        return selected == first ? (last, first) : (first, last)
    }

    // MARK: preview (Find in Project)

    private func refreshPreview() {
        guard isFind, let tv = previewView, let h = view?.handle, h != 0 else { return }
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        var len = 0
        while true {
            len = buf.withUnsafeMutableBufferPointer { b -> Int in
                Int(tk_desktop_picker_preview(h, Int64(Int(bitPattern: b.baseAddress)), Int64(b.count)))
            }
            if len <= buf.count { break }
            buf = [UInt8](repeating: 0, count: len)
        }
        guard len > 0, let pv = (try? JSONSerialization.jsonObject(with: Data(buf[0..<len]))) as? [String: Any]
        else {
            if !previewKey.isEmpty { tv.string = ""; previewKey = "" }
            return
        }
        let path = pv["path"] as? String ?? ""
        let line = pv["line"] as? Int ?? 1
        let lines = pv["lines"] as? [String] ?? []
        let key = "\(path)#\(lines.count)"
        if key != previewKey {
            previewKey = key
            tv.textStorage?.setAttributedString(PickerController.colored(pv))
            let bg = PickerController.rgb(pv["bg"] as? Int ?? 0)
            tv.backgroundColor = bg
            tv.enclosingScrollView?.backgroundColor = bg
        }
        PickerController.markLine(tv, lines: lines, line: line)
    }

    static func rgb(_ v: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// The file's lines with the core's syntax spans (byte ranges per row)
    /// mapped onto UTF-16 offsets.
    static func colored(_ pv: [String: Any]) -> NSAttributedString {
        let lines = pv["lines"] as? [String] ?? []
        let fg = rgb(pv["fg"] as? Int ?? 0xFFFFFF)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let s = NSMutableAttributedString(string: lines.joined(separator: "\n"),
                                          attributes: [.font: font, .foregroundColor: fg])
        var starts: [Int] = []
        var off = 0
        for l in lines { starts.append(off); off += l.utf16.count + 1 }
        var maps: [Int: [Int]] = [:]
        func utf16Offset(_ row: Int, _ byte: Int) -> Int {
            if maps[row] == nil {
                var m: [Int] = []
                var u = 0
                for scalar in lines[row].unicodeScalars {
                    let n = String(scalar).utf8.count
                    for _ in 0..<n { m.append(u) }
                    u += scalar.utf16.count
                }
                m.append(u)
                maps[row] = m
            }
            let m = maps[row]!
            return m[min(max(byte, 0), m.count - 1)]
        }
        for sp in pv["spans"] as? [[Int]] ?? [] where sp.count == 4 {
            let row = sp[0]
            guard row >= 0 && row < lines.count else { continue }
            let a = utf16Offset(row, sp[1]), b = utf16Offset(row, sp[2])
            guard b > a else { continue }
            s.addAttribute(.foregroundColor, value: rgb(sp[3]),
                           range: NSRange(location: starts[row] + a, length: b - a))
        }
        return s
    }

    /// Tint the match's line and park it at the golden-ratio line, like
    /// every jump in the editor.
    static func markLine(_ tv: NSTextView, lines: [String], line: Int) {
        guard let ts = tv.textStorage, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        ts.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: ts.length))
        let row = min(max(line - 1, 0), max(lines.count - 1, 0))
        guard row < lines.count else { return }
        var start = 0
        for i in 0..<row { start += lines[i].utf16.count + 1 }
        let range = NSRange(location: start, length: lines[row].utf16.count)
        ts.addAttribute(.backgroundColor,
                        value: NSColor.findHighlightColor.withAlphaComponent(0.35), range: range)
        lm.ensureLayout(for: tc)
        let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: start, length: 0),
                                   actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        guard let clip = tv.enclosingScrollView?.contentView else { return }
        let y = max(0, rect.minY - clip.bounds.height * 0.38)
        clip.scroll(to: NSPoint(x: 0, y: y))
        tv.enclosingScrollView?.reflectScrolledClipView(clip)
    }

    // MARK: input

    func controlTextDidChange(_ obj: Notification) {
        guard let f = obj.object as? NSTextField, let h = view?.handle, h != 0 else { return }
        let name = f === search ? "query" : f === replaceField ? "replace"
                 : f === scopeField ? "scope" : f === globField ? "glob" : ""
        guard !name.isEmpty else { return }
        withUTF8Arg(name) { np, nl in
            withUTF8Arg(f.stringValue) { tp, tl in tk_desktop_picker_set(h, np, nl, tp, tl) }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveUp(_:)): move(-1, extend: false); return true
        case #selector(NSResponder.moveDown(_:)): move(1, extend: false); return true
        case #selector(NSResponder.moveUpAndModifySelection(_:)): move(-1, extend: true); return true
        case #selector(NSResponder.moveDownAndModifySelection(_:)): move(1, extend: true); return true
        case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)):
            move(-pageRows(), extend: false); return true
        case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)):
            move(pageRows(), extend: false); return true
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true { actionClicked() }
            else { activateClicked() }
            return true
        case #selector(NSResponder.cancelOperation(_:)): cancelClicked(); return true
        default: return false
        }
    }

    private func pageRows() -> Int {
        max(1, Int(table.enclosingScrollView?.contentView.bounds.height ?? 300 / table.rowHeight) / Int(table.rowHeight) - 1)
    }

    private func move(_ delta: Int, extend: Bool) {
        guard count > 0 else { return }
        let cur = selected < 0 ? (delta > 0 ? -1 : count) : selected
        let next = min(max(cur + delta, 0), count - 1)
        if extend && multi {
            let (_, anchor) = selectionEnds()
            let lo = min(anchor, next), hi = max(anchor, next)
            syncingSelection = true
            table.selectRowIndexes(IndexSet(integersIn: lo...hi), byExtendingSelection: false)
            syncingSelection = false
            selected = next
            if let h = view?.handle { tk_desktop_picker_select(h, Int64(next), Int64(anchor)) }
        } else {
            table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        }
        table.scrollRowToVisible(next)
    }

    @objc private func toggleChanged(_ b: NSButton) {
        guard let key = b.identifier?.rawValue, let h = view?.handle, h != 0 else { return }
        withUTF8Arg(key) { p, l in tk_desktop_picker_option(h, p, l, b.state == .on ? 1 : 0) }
    }

    @objc private func activateClicked() {
        guard let v = view, v.handle != 0 else { return }
        var (idx, anchor) = selectionEnds()
        // A double-click opens the row under the pointer. (Only read mouse
        // state off a mouse event: `clickCount` on the key event Return
        // produces raises, which is what used to make Return do nothing.)
        if let ev = NSApp.currentEvent,
           ev.type == .leftMouseDown || ev.type == .leftMouseUp,
           table.clickedRow >= 0 {
            idx = table.clickedRow
            if !table.selectedRowIndexes.contains(idx) { anchor = idx }
        }
        // Return opens the selected row — the first one when the results
        // landed after the last poll and nothing is selected here yet. The
        // core clamps to what it actually has, so never refuse on a stale
        // `count`.
        if idx < 0 { idx = max(selected, 0); anchor = idx }
        let code = tk_desktop_picker_activate(v.handle, Int64(idx), Int64(anchor),
                                              Int64(v.cols()), Int64(v.rows()))
        onActivate?(code)
    }

    @objc private func actionClicked() {
        guard isFind, let v = view, v.handle != 0, count > 0 else { return }
        let name = replaceField?.isHidden == false ? "replace_all" : "send_to_panel"
        withUTF8Arg(name) { p, l in
            tk_desktop_picker_action(v.handle, p, l, Int64(v.cols()), Int64(v.rows()))
        }
        onActivate?(0)
    }

    @objc private func cancelClicked() {
        if let h = view?.handle, h != 0 { tk_desktop_picker_close(h) }
        onActivate?(0)
    }
}

/// Two-line picker row: the name / matched line over its location.
final class PickerCell: NSTableCellView {
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.lineBreakMode = .byTruncatingTail
        detail.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}


/// Render `win` (frame view: titlebar + accessories + content) and its
/// attached sheet into one PNG, entirely offscreen — works with the display
/// asleep, unlike `screencapture`.
func captureWindowPNG(_ win: NSWindow, to path: String) {
    guard let frameView = win.contentView?.superview,
          let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)
    else { return }
    frameView.cacheDisplay(in: frameView.bounds, to: rep)
    let size = frameView.bounds.size
    let img = NSImage(size: size)
    img.addRepresentation(rep)
    let out = NSImage(size: size)
    out.lockFocus()
    // The titlebar material renders transparent offscreen: back it with the
    // window color so the PNG isn't see-through (in a dark viewer the tab
    // titles otherwise read black on black).
    win.effectiveAppearance.performAsCurrentDrawingAppearance {
        NSColor.windowBackgroundColor.setFill()
        NSRect(origin: .zero, size: size).fill()
    }
    img.draw(in: NSRect(origin: .zero, size: size))
    if let sheet = win.attachedSheet, let sv = sheet.contentView?.superview,
       let srep = sv.bitmapImageRepForCachingDisplay(in: sv.bounds) {
        sv.cacheDisplay(in: sv.bounds, to: srep)
        let sz = sv.bounds.size
        // Sheets hang from the bottom of the titlebar, centered.
        let top = size.height - (win.frame.height - win.contentLayoutRect.height)
        let r = NSRect(x: (size.width - sz.width) / 2, y: top - sz.height,
                       width: sz.width, height: sz.height)
        NSColor.black.withAlphaComponent(0.25).setFill()
        NSBezierPath(rect: r.insetBy(dx: -1, dy: -1)).fill()
        srep.draw(in: r)
    }
    out.unlockFocus()
    guard let tiff = out.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff),
          let png = bmp.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}


// MARK: - first-launch welcome window
//
// Picks the look — the macOS-style UI or the classic Turbo Vision one — plus
// theme, font and size, applying each choice live to the window behind it
// (`tk_desktop_welcome_apply`). Choosing a look also picks sensible defaults
// for the other three, which the user can then override.

final class WelcomeController: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let apply: (String, Bool) -> Void
    private let modernCard: LookCard
    private let retroCard: LookCard
    private let themePopup = NSPopUpButton()
    private let fontPopup = NSPopUpButton()
    private let sizePopup = NSPopUpButton()
    private let builtinFonts: [String]
    private var nativeUI: Bool
    private var finished = false
    private let palette: () -> [UInt32]
    private let preview = CodePreview()
    private static let sizes = CodePreview.sizes

    init(options o: [String: Any], palette: @escaping () -> [UInt32],
         apply: @escaping (String, Bool) -> Void) {
        self.apply = apply
        self.palette = palette
        builtinFonts = o["builtin_fonts"] as? [String] ?? []
        nativeUI = o["native_ui"] as? Bool ?? false
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        modernCard = LookCard(title: "Modern macOS",
                              detail: "Native tabs, sheets and pickers.\nSystem fonts around your code.",
                              retro: false)
        retroCard = LookCard(title: "Retro",
                             detail: "The full Turbo Vision experience:\nDOS windows, menus and dialogs.",
                             retro: true)
        super.init()
        window.title = "Welcome to TurboKod"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let heading = NSTextField(labelWithString: "Welcome to TurboKod")
        heading.font = .systemFont(ofSize: 26, weight: .bold)
        let sub = NSTextField(wrappingLabelWithString:
            "Choose how it should look. You can change all of this later in Settings and the View menu.")
        sub.textColor = .secondaryLabelColor
        sub.font = .systemFont(ofSize: 13)

        modernCard.onPick = { [weak self] in self?.pickLook(native: true) }
        retroCard.onPick = { [weak self] in self?.pickLook(native: false) }
        let cards = NSStackView(views: [modernCard, retroCard])
        cards.distribution = .fillEqually
        cards.spacing = 16

        themePopup.addItems(withTitles: o["themes"] as? [String] ?? [])
        fontPopup.addItems(withTitles: builtinFonts + FontCatalog.monospaceFamilies)
        sizePopup.addItems(withTitles: Self.sizes.map { $0 == 0 ? "Default" : "\($0) pt" })
        themePopup.selectItem(withTitle: o["theme"] as? String ?? "")
        fontPopup.selectItem(withTitle: o["font"] as? String ?? "")
        sizePopup.selectItem(at: Self.sizes.firstIndex(of: o["font_size"] as? Int ?? 0) ?? 0)
        for p in [themePopup, fontPopup, sizePopup] {
            p.target = self
            p.action = #selector(controlChanged)
        }
        let grid = NSGridView(views: [
            [label("Theme:"), themePopup],
            [label("Font:"), fontPopup],
            [label("Size:"), sizePopup],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        themePopup.widthAnchor.constraint(equalToConstant: 280).isActive = true
        fontPopup.widthAnchor.constraint(equalToConstant: 280).isActive = true

        let start = NSButton(title: "Get Started", target: self, action: #selector(getStarted))
        start.keyEquivalent = "\r"
        start.bezelColor = .controlAccentColor
        start.controlSize = .large

        // The pickers apply to either look: center them under both cards,
        // not wherever the grid's own width would push them.
        let gridBox = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        gridBox.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.centerXAnchor.constraint(equalTo: gridBox.centerXAnchor),
            grid.topAnchor.constraint(equalTo: gridBox.topAnchor),
            grid.bottomAnchor.constraint(equalTo: gridBox.bottomAnchor),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: gridBox.leadingAnchor),
        ])
        preview.heightAnchor.constraint(equalToConstant: 150).isActive = true
        let stack = NSStackView(views: [heading, sub, cards, gridBox, preview, start])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 32, bottom: 26, right: 32)
        stack.setCustomSpacing(6, after: heading)
        stack.setCustomSpacing(24, after: cards)
        stack.translatesAutoresizingMaskIntoConstraints = false
        cards.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -64).isActive = true
        cards.heightAnchor.constraint(equalToConstant: 260).isActive = true
        gridBox.widthAnchor.constraint(equalTo: cards.widthAnchor).isActive = true
        preview.widthAnchor.constraint(equalTo: cards.widthAnchor).isActive = true
        sub.widthAnchor.constraint(equalTo: cards.widthAnchor).isActive = true
        sub.alignment = .center
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        // Size the window to its content rather than stretching the rows.
        grid.setContentHuggingPriority(.required, for: .vertical)
        grid.setContentHuggingPriority(.required, for: .horizontal)
        stack.setHuggingPriority(.required, for: .vertical)
        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 760, height: stack.fittingSize.height))
        refreshCards()
        renderPreview()
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.textColor = .secondaryLabelColor
        return l
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func refreshCards() {
        modernCard.selected = nativeUI
        retroCard.selected = !nativeUI
    }

    // MARK: live preview

    private func renderPreview() {
        let size = Self.sizes[max(0, sizePopup.indexOfSelectedItem)]
        preview.render(palette: palette(),
                       font: CodePreview.font(label: fontPopup.titleOfSelectedItem ?? "",
                                              size: size, builtins: builtinFonts))
    }

    /// A look comes with its natural theme and font; the popups stay
    /// editable afterwards.
    private func pickLook(native: Bool) {
        nativeUI = native
        refreshCards()
        if native {
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            themePopup.selectItem(withTitle: dark ? "One Dark" : "GitHub Light")
            let fonts = FontCatalog.monospaceFamilies
            if let f = ["SF Mono", "Menlo", "Monaco"].first(where: fonts.contains) {
                fontPopup.selectItem(withTitle: f)
            }
            sizePopup.selectItem(at: Self.sizes.firstIndex(of: 13) ?? 0)
        } else {
            themePopup.selectItem(withTitle: "Turbo C++ 3.0")
            if let f = builtinFonts.first { fontPopup.selectItem(withTitle: f) }
            sizePopup.selectItem(at: 0)
        }
        push(done: false)
    }

    @objc private func controlChanged() { push(done: false) }

    private func push(done: Bool) {
        let size = Self.sizes[max(0, sizePopup.indexOfSelectedItem)]
        let o: [String: Any] = [
            "native_ui": nativeUI,
            "theme": themePopup.titleOfSelectedItem ?? "",
            "font": fontPopup.titleOfSelectedItem ?? "",
            "font_size": size,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: o),
              let json = String(data: data, encoding: .utf8) else { return }
        apply(json, done)
        renderPreview()   // the core has the new theme now
    }

    @objc private func getStarted() { window.close() }

    func windowWillClose(_ notification: Notification) {
        guard !finished else { return }
        finished = true
        push(done: true)
    }
}

/// One clickable look in the welcome window: a drawn miniature of the UI
/// over a title and a line of description.
final class LookCard: NSView {
    var onPick: (() -> Void)?
    var selected = false { didSet { needsDisplay = true } }
    private let retro: Bool
    private let title: String
    private let detail: String

    init(title: String, detail: String, retro: Bool) {
        self.title = title
        self.detail = detail
        self.retro = retro
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) { onPick?() }

    override func draw(_ dirtyRect: NSRect) {
        let card = bounds.insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        (selected ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = selected ? 3 : 1
        path.stroke()
        let shot = NSRect(x: card.minX + 16, y: card.minY + 16,
                          width: card.width - 32, height: card.height - 100)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: shot, xRadius: 6, yRadius: 6).addClip()
        if retro { drawRetro(shot) } else { drawModern(shot) }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: shot, xRadius: 6, yRadius: 6).stroke()
        let t = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.labelColor])
        t.draw(at: NSPoint(x: shot.minX, y: shot.maxY + 12))
        let d = NSAttributedString(string: detail, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor])
        d.draw(in: NSRect(x: shot.minX, y: shot.maxY + 34, width: shot.width, height: 40))
    }

    private func fill(_ c: NSColor, _ r: NSRect, radius: CGFloat = 0) {
        c.setFill()
        radius > 0 ? NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill() : r.fill()
    }

    private func codeLines(_ r: NSRect, colors: [NSColor], step: CGFloat, height: CGFloat) {
        let widths: [CGFloat] = [0.55, 0.7, 0.4, 0.8, 0.3, 0.65, 0.5, 0.75, 0.45, 0.6]
        var y = r.minY + 8
        var i = 0
        while y + height < r.maxY - 4 {
            let indent: CGFloat = (i % 4 == 1 || i % 4 == 2) ? 14 : 0
            fill(colors[i % colors.count],
                 NSRect(x: r.minX + 10 + indent, y: y, width: (r.width - 30) * widths[i % widths.count], height: height),
                 radius: height / 2)
            y += step
            i += 1
        }
    }

    private func drawModern(_ r: NSRect) {
        fill(NSColor(white: 0.93, alpha: 1), r)
        // Title bar + traffic lights, tab strip, editor, sheet.
        for (k, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            fill(c, NSRect(x: r.minX + 8 + CGFloat(k) * 11, y: r.minY + 7, width: 7, height: 7), radius: 3.5)
        }
        let tabs = NSRect(x: r.minX, y: r.minY + 20, width: r.width, height: 16)
        for k in 0..<3 {
            let tr = NSRect(x: tabs.minX + 6 + CGFloat(k) * 54, y: tabs.minY + 2, width: 50, height: 12)
            fill(k == 0 ? .white : NSColor(white: 0.87, alpha: 1), tr, radius: 3)
        }
        let editor = NSRect(x: r.minX, y: tabs.maxY, width: r.width, height: r.maxY - tabs.maxY)
        fill(.white, editor)
        codeLines(editor, colors: [.systemPurple.withAlphaComponent(0.6), .systemBlue.withAlphaComponent(0.5),
                                   .systemGreen.withAlphaComponent(0.55), NSColor(white: 0.75, alpha: 1)],
                  step: 11, height: 5)
        let sheet = NSRect(x: r.midX - r.width * 0.3, y: tabs.maxY, width: r.width * 0.6, height: r.height * 0.42)
        NSShadow().set()
        let sh = NSShadow()
        sh.shadowBlurRadius = 8
        sh.shadowColor = NSColor.black.withAlphaComponent(0.25)
        NSGraphicsContext.saveGraphicsState()
        sh.set()
        fill(NSColor(white: 0.97, alpha: 1), sheet, radius: 6)
        NSGraphicsContext.restoreGraphicsState()
        fill(.white, NSRect(x: sheet.minX + 8, y: sheet.minY + 10, width: sheet.width - 16, height: 12), radius: 4)
        for k in 0..<3 {
            fill(k == 0 ? NSColor.controlAccentColor.withAlphaComponent(0.25) : NSColor(white: 0.9, alpha: 1),
                 NSRect(x: sheet.minX + 8, y: sheet.minY + 28 + CGFloat(k) * 12, width: sheet.width - 16, height: 10),
                 radius: 3)
        }
    }

    private func drawRetro(_ r: NSRect) {
        let blue = NSColor(srgbRed: 0, green: 0, blue: 0.67, alpha: 1)
        let gray = NSColor(srgbRed: 0.67, green: 0.67, blue: 0.67, alpha: 1)
        let cyan = NSColor(srgbRed: 0.33, green: 1, blue: 1, alpha: 1)
        let yellow = NSColor(srgbRed: 1, green: 1, blue: 0.33, alpha: 1)
        fill(blue, r)
        fill(gray, NSRect(x: r.minX, y: r.minY, width: r.width, height: 12))
        for k in 0..<5 {
            fill(.black, NSRect(x: r.minX + 10 + CGFloat(k) * 34, y: r.minY + 4, width: 22, height: 4))
        }
        // Editor window: double-line frame, code in VGA colors.
        let win = NSRect(x: r.minX + 6, y: r.minY + 18, width: r.width - 12, height: r.height - 36)
        NSColor.white.setStroke()
        for inset in [CGFloat(0), 3] {
            let p = NSBezierPath(rect: win.insetBy(dx: inset + 0.5, dy: inset + 0.5))
            p.lineWidth = 1
            p.stroke()
        }
        codeLines(win.insetBy(dx: 6, dy: 6), colors: [yellow, cyan, .white, cyan], step: 11, height: 4)
        // A gray dialog with its black drop shadow.
        let dlg = NSRect(x: r.midX - r.width * 0.28, y: r.midY - 18, width: r.width * 0.56, height: 46)
        fill(.black, dlg.offsetBy(dx: 6, dy: 5))
        fill(gray, dlg)
        NSColor.white.setStroke()
        NSBezierPath(rect: dlg.insetBy(dx: 3.5, dy: 3.5)).stroke()
        fill(.black, NSRect(x: dlg.minX + 12, y: dlg.minY + 12, width: dlg.width * 0.6, height: 4))
        fill(NSColor(srgbRed: 0, green: 0.67, blue: 0, alpha: 1),
             NSRect(x: dlg.midX - 20, y: dlg.maxY - 17, width: 40, height: 9))
        fill(.black, NSRect(x: r.minX, y: r.maxY - 10, width: r.width, height: 10))
        fill(gray, NSRect(x: r.minX, y: r.maxY - 10, width: r.width, height: 10))
    }
}


// MARK: - macOS-style UI: popup menus
//
// The core's anchored popups (context menus, spelling, test gutter,
// diagnostics, LSP status) as a real NSMenu at the anchor cell. The answer
// is the picked item's code, 0 when dismissed; the core runs the menu's own
// submit handler either way.

final class PopupMenu: NSObject {
    private weak var view: CellView?
    private let menu = NSMenu()
    private var last = Data()
    private var anchor = NSPoint.zero
    private var chosen = 0

    init(view: CellView) {
        self.view = view
        super.init()
        menu.autoenablesItems = false
    }

    func refresh(_ data: Data) {
        guard data != last,
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        last = data
        anchor = NSPoint(x: CGFloat(o["x"] as? Int ?? 0) * CELL_W,
                         y: CGFloat((o["y"] as? Int ?? 0) + 1) * CELL_H)
        menu.removeAllItems()
        for it in o["items"] as? [[String: Any]] ?? [] {
            let mi = NSMenuItem(title: it["label"] as? String ?? "",
                                action: #selector(pick(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = it["code"] as? Int ?? 0
            mi.isEnabled = it["enabled"] as? Bool ?? true
            menu.addItem(mi)
        }
    }

    /// Runs the menu (blocking, nested run loop); the picked code or 0.
    func track() -> Int {
        guard let v = view else { return 0 }
        chosen = 0
        menu.popUp(positioning: nil, at: anchor, in: v)
        return chosen
    }

    @objc private func pick(_ sender: NSMenuItem) { chosen = sender.tag }
}


// MARK: - macOS-style UI: git sheet
//
// The git view (LocalChanges) as a native sheet in the style of a Mac
// source-control client. Nothing git-shaped lives here: selection and focus
// are pushed into the core, operations are the view's own keys
// (`tk_desktop_git_key`), and every in-grid overlay (confirm, merge-or-
// rebase, reword, remote choice, typed delete, output) is shown as an alert
// whose answer goes back through `tk_desktop_git_answer`.

// Panes and LocalChanges' _LINE_* row kinds. Static members, not top-level
// lets: this is the app's main file, where a top-level global is initialized
// only when execution reaches its declaration — and these sit after the code
// that starts the run loop, so as plain globals they read 0.
private enum GitPane {
    static let files = 0, branches = 1, commits = 2
    static let unstaged = 3, staged = 4, info = 5
}
private enum GitLine {
    static let fileHdr = 1, info = 2, ctx = 3, add = 4, rem = 5, sep = 7
}

/// A table that reports Space / Return / Delete / Esc instead of beeping.
final class GitTable: NSTableView {
    var onKey: ((String) -> Bool)?
    override func keyDown(with e: NSEvent) {
        let k: String
        switch e.keyCode {
        case 49: k = "space"
        case 36, 76: k = "enter"
        case 51, 117: k = "delete"
        case 53: k = "esc"
        default: k = ""
        }
        if !k.isEmpty, onKey?(k) == true { return }
        super.keyDown(with: e)
    }
}

/// The diff view: Space acts on the line under the cursor.
final class GitDiffView: NSTextView {
    var onKey: ((String) -> Bool)?
    override func keyDown(with e: NSEvent) {
        let k = e.keyCode == 49 ? "space" : e.keyCode == 53 ? "esc"
              : (e.keyCode == 36 || e.keyCode == 76) ? "enter" : ""
        if !k.isEmpty, onKey?(k) == true { return }
        super.keyDown(with: e)
    }
}

final class GitController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate {
    weak var view: CellView?
    var onAfterAction: (() -> Void)?

    private let panel: NSPanel
    private let branchLabel = NSTextField(labelWithString: "")
    private let flashLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let segment = NSSegmentedControl(labels: ["Changes", "Branches", "History"],
                                             trackingMode: .selectOne, target: nil, action: nil)
    private let table = GitTable()
    private let commitBox = NSView()
    private let messageView = NSTextView()
    private let commitButton = NSButton(title: "Commit", target: nil, action: nil)
    private let amendButton = NSButton(title: "Amend Last Commit", target: nil, action: nil)
    private let diff = GitDiffView()
    private var actionButtons: [NSButton] = []

    private var state: [String: Any] = [:]
    private var lastData = Data()
    private var lastPanels = Data()
    private var files: [[String: Any]] = []
    private var branches: [[String: Any]] = []
    private var commits: [[String: Any]] = []
    /// Per line of the diff view: (pane, row) of the core panel row, or nil.
    private var lineMap: [(Int, Int)?] = []
    private var lineStarts: [Int] = []
    private var cursorLine = -1
    private var syncing = false
    private var overlayShown = ""
    private var dismissed = false

    private var list: Int { segment.selectedSegment }

    init(view: CellView) {
        self.view = view
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                        styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        super.init()
        build()
    }

    // MARK: layout

    private func build() {
        branchLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        flashLabel.textColor = .secondaryLabelColor
        flashLabel.lineBreakMode = .byTruncatingTail
        flashLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let branchIcon = NSImageView(image: NSImage(systemSymbolName: "arrow.triangle.branch",
                                                    accessibilityDescription: "Branch") ?? NSImage())
        func button(_ title: String, _ symbol: String, _ sel: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: sel)
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            b.imagePosition = .imageLeading
            b.bezelStyle = .rounded
            return b
        }
        let pull = button("Pull", "arrow.down", #selector(pullClicked))
        let push = button("Push", "arrow.up", #selector(pushClicked))
        let pushTo = button("Push To…", "arrow.up.forward", #selector(pushToClicked))
        let close = NSButton(title: "Close", target: self, action: #selector(closeClicked))
        close.keyEquivalent = "\u{1b}"
        actionButtons = [pull, push, pushTo]
        let top = NSStackView(views: [branchIcon, branchLabel, spinner, flashLabel, NSView(),
                                      pull, push, pushTo, close])
        top.spacing = 8

        segment.target = self
        segment.action = #selector(segmentChanged)
        segment.selectedSegment = 0
        segment.segmentDistribution = .fillEqually

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 38
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(tableDoubleClicked)
        table.menu = NSMenu()
        table.menu?.delegate = self
        table.onKey = { [weak self] k in self?.tableKey(k) ?? false }
        let tableScroll = NSScrollView()
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true

        // Commit box (Changes only): message over the two commit buttons.
        messageView.isRichText = false
        messageView.font = .systemFont(ofSize: 13)
        messageView.textContainerInset = NSSize(width: 4, height: 6)
        let msgScroll = NSScrollView()
        msgScroll.documentView = messageView
        msgScroll.hasVerticalScroller = true
        msgScroll.borderType = .bezelBorder
        commitButton.target = self
        commitButton.action = #selector(commitClicked)
        commitButton.bezelColor = .controlAccentColor
        commitButton.keyEquivalent = "\r"
        commitButton.keyEquivalentModifierMask = .command
        amendButton.target = self
        amendButton.action = #selector(amendClicked)
        let commitRow = NSStackView(views: [amendButton, NSView(), commitButton])
        let placeholder = NSTextField(labelWithString: "Commit message")
        placeholder.textColor = .secondaryLabelColor
        placeholder.font = .systemFont(ofSize: 11)
        let commitStack = NSStackView(views: [placeholder, msgScroll, commitRow])
        commitStack.orientation = .vertical
        commitStack.alignment = .leading
        commitStack.spacing = 6
        for v in [msgScroll, commitRow] {
            v.widthAnchor.constraint(equalTo: commitStack.widthAnchor).isActive = true
        }
        msgScroll.heightAnchor.constraint(equalToConstant: 72).isActive = true
        commitStack.translatesAutoresizingMaskIntoConstraints = false
        commitBox.addSubview(commitStack)
        NSLayoutConstraint.activate([
            commitStack.leadingAnchor.constraint(equalTo: commitBox.leadingAnchor),
            commitStack.trailingAnchor.constraint(equalTo: commitBox.trailingAnchor),
            commitStack.topAnchor.constraint(equalTo: commitBox.topAnchor),
            commitStack.bottomAnchor.constraint(equalTo: commitBox.bottomAnchor),
        ])

        let left = NSStackView(views: [segment, tableScroll, commitBox])
        left.orientation = .vertical
        left.spacing = 8
        left.distribution = .fill
        for v in [segment, tableScroll, commitBox] as [NSView] {
            v.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true
        }
        tableScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        commitBox.setContentHuggingPriority(.required, for: .vertical)

        diff.isEditable = false
        diff.isSelectable = true
        diff.isRichText = true
        diff.delegate = self
        diff.textContainerInset = NSSize(width: 4, height: 6)
        diff.isHorizontallyResizable = true
        diff.textContainer?.widthTracksTextView = false
        diff.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                   height: CGFloat.greatestFiniteMagnitude)
        diff.onKey = { [weak self] k in self?.diffKey(k) ?? false }
        diff.menu = NSMenu()
        diff.menu?.delegate = self
        let diffScroll = NSScrollView()
        diffScroll.documentView = diff
        diffScroll.hasVerticalScroller = true
        diffScroll.hasHorizontalScroller = true

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(left)
        split.addArrangedSubview(diffScroll)
        left.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)

        let content = NSView()
        for v in [top, split] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
                v.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            ])
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            split.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            split.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        panel.contentView = content
        splitView = split
    }

    private var splitView: NSSplitView?

    func present(in win: NSWindow) {
        let room = win.contentLayoutRect.size
        panel.setContentSize(NSSize(width: max(700, room.width - 40), height: max(460, room.height - 30)))
        panel.contentView?.layoutSubtreeIfNeeded()
        splitView?.setPosition(min(360, panel.frame.width * 0.34), ofDividerAt: 0)
        win.beginSheet(panel, completionHandler: nil)
        panel.makeFirstResponder(table)
    }

    func dismiss() {
        guard !dismissed else { return }
        dismissed = true
        panel.sheetParent?.endSheet(panel)
    }

    // MARK: state

    /// Adopt a polled state; true when anything changed.
    func update(_ data: Data) -> Bool {
        if data == lastData { return false }
        lastData = data
        guard let st = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        state = st
        files = st["files"] as? [[String: Any]] ?? []
        branches = st["branches"] as? [[String: Any]] ?? []
        commits = st["commits"] as? [[String: Any]] ?? []
        let branch = st["branch"] as? String ?? ""
        branchLabel.stringValue = branch.isEmpty ? "(detached)" : branch
        commitButton.title = branch.isEmpty ? "Commit" : "Commit to \(branch)"
        let busy = st["busy"] as? Bool ?? false
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        let status = st["status"] as? String ?? ""
        let flash = st["flash"] as? String ?? ""
        flashLabel.stringValue = busy ? (st["busy_label"] as? String ?? "Working…")
                               : !status.isEmpty ? status : flash
        for b in actionButtons + [commitButton, amendButton] { b.isEnabled = !busy }
        // Follow the core's focus to the list it's driving.
        let focus = st["focus"] as? Int ?? 0
        if focus <= GitPane.commits && focus != list {
            segment.selectedSegment = focus
        }
        commitBox.isHidden = list != GitPane.files
        syncing = true
        table.reloadData()
        let sel = selectedIndex(for: list)
        if sel >= 0 && sel < table.numberOfRows {
            table.selectRowIndexes(IndexSet(integer: sel), byExtendingSelection: false)
            table.scrollRowToVisible(sel)
        } else {
            table.deselectAll(nil)
        }
        syncing = false
        refreshPanels()
        showOverlayIfNeeded(st["overlay"] as? [String: Any] ?? [:])
        return true
    }

    private func selectedIndex(for l: Int) -> Int {
        state[l == GitPane.files ? "sel_file" : l == GitPane.branches ? "sel_branch" : "sel_commit"] as? Int ?? -1
    }

    // MARK: lists

    func numberOfRows(in tableView: NSTableView) -> Int {
        list == GitPane.files ? files.count : list == GitPane.branches ? branches.count : commits.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row i: Int) -> NSView? {
        let cell = GitRowCell()
        switch list {
        case GitPane.files:
            let f = files[i]
            let x = f["x"] as? String ?? " ", y = f["y"] as? String ?? " "
            let path = f["path"] as? String ?? ""
            let name = (path as NSString).lastPathComponent
            let dir = (path as NSString).deletingLastPathComponent
            cell.set(title: name, detail: dir.isEmpty ? statusWord(x, y) : "\(dir) · \(statusWord(x, y))",
                     badge: (x + y).trimmingCharacters(in: .whitespaces),
                     badgeColor: x == "?" ? .systemGray : y != " " ? .systemOrange : .systemGreen)
            let staged = x != " " && x != "?"
            let partial = staged && y != " "
            cell.addCheckbox(state: partial ? .mixed : staged ? .on : .off) { [weak self] in
                self?.stageToggle(row: i)
            }
        case GitPane.branches:
            let b = branches[i]
            let current = b["current"] as? Bool ?? false
            let remote = b["remote"] as? Bool ?? false
            cell.set(title: (current ? "✓ " : "") + (b["name"] as? String ?? ""),
                     detail: [b["age"] as? String ?? "", b["subject"] as? String ?? ""]
                        .filter { !$0.isEmpty }.joined(separator: " · "),
                     badge: remote ? "remote" : "", badgeColor: .systemGray,
                     bold: current, dim: remote)
        default:
            let c = commits[i]
            let pushed = c["pushed"] as? Bool ?? true
            let tags = c["tags"] as? String ?? ""
            cell.set(title: c["subject"] as? String ?? "",
                     detail: "\(c["sha"] as? String ?? "") · \(c["author"] as? String ?? "") · \(c["date"] as? String ?? "")",
                     badge: !pushed ? "↑ unpushed" : tags, badgeColor: !pushed ? .systemRed : .systemPurple)
        }
        return cell
    }

    private func statusWord(_ x: String, _ y: String) -> String {
        if x == "?" { return "untracked" }
        let c = y != " " ? y : x
        switch c {
        case "M": return "modified"
        case "A": return "added"
        case "D": return "deleted"
        case "R": return "renamed"
        case "U": return "conflicted"
        default: return "changed"
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncing, let v = view, v.handle != 0, table.selectedRow >= 0 else { return }
        tk_desktop_git_select(v.handle, Int64(list), Int64(table.selectedRow),
                              Int64(v.cols()), Int64(v.rows()))
        lastData = Data()   // force the next poll to re-render
        cursorLine = -1
    }

    @objc private func segmentChanged() {
        guard let v = view, v.handle != 0 else { return }
        commitBox.isHidden = list != GitPane.files
        let sel = max(0, selectedIndex(for: list))
        tk_desktop_git_select(v.handle, Int64(list), Int64(sel), Int64(v.cols()), Int64(v.rows()))
        lastData = Data()
        syncing = true
        table.reloadData()
        syncing = false
    }

    // MARK: operations (the view's own keys)

    private func key(_ pane: Int, _ k: UInt32, mods: UInt8 = 0) {
        guard let v = view, v.handle != 0 else { return }
        _ = tk_desktop_git_key(v.handle, Int64(pane), Int64(k), Int64(mods),
                               Int64(v.cols()), Int64(v.rows()))
        lastData = Data()
        onAfterAction?()
    }

    private func ch(_ c: Character) -> UInt32 { c.unicodeScalars.first!.value }

    private func stageToggle(row: Int) {
        guard let v = view, v.handle != 0 else { return }
        tk_desktop_git_select(v.handle, Int64(GitPane.files), Int64(row), Int64(v.cols()), Int64(v.rows()))
        key(GitPane.files, 0x20)
    }

    private func tableKey(_ k: String) -> Bool {
        let row = table.selectedRow
        switch (k, list) {
        case ("esc", _): closeClicked(); return true
        case ("space", GitPane.files) where row >= 0: key(GitPane.files, 0x20); return true
        case ("space", GitPane.branches) where row >= 0: key(GitPane.branches, 0x20); return true
        case ("enter", _) where row >= 0: tableDoubleClicked(); return true
        case ("delete", GitPane.files) where row >= 0, ("delete", GitPane.branches) where row >= 0:
            key(list, ch("d")); return true
        default: return false
        }
    }

    @objc private func tableDoubleClicked() {
        guard let v = view, v.handle != 0 else { return }
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0 else { return }
        switch list {
        case GitPane.files:
            tk_desktop_git_select(v.handle, Int64(GitPane.files), Int64(row), Int64(v.cols()), Int64(v.rows()))
            tk_desktop_git_open(v.handle, Int64(GitPane.files), Int64(row), Int64(v.cols()), Int64(v.rows()))
            onAfterAction?()
        case GitPane.branches:
            key(GitPane.branches, 0x20)   // check it out
        default:
            break
        }
    }

    @objc private func pullClicked() { key(-1, ch("p")) }
    @objc private func pushClicked() { key(-1, ch("P")) }
    @objc private func pushToClicked() { key(-1, ch("p"), mods: 1 << 2) }   // Ctrl+P

    @objc private func commitClicked() {
        guard let v = view, v.handle != 0 else { return }
        let msg = messageView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { NSSound.beep(); panel.makeFirstResponder(messageView); return }
        withUTF8Arg(msg) { p, l in tk_desktop_git_commit(v.handle, p, l) }
        messageView.string = ""
        lastData = Data()
        onAfterAction?()
    }

    @objc private func amendClicked() { key(GitPane.files, ch("A")) }

    @objc private func closeClicked() {
        guard let v = view, v.handle != 0 else { return }
        if tk_desktop_git_close(v.handle) == 0 {
            NSSound.beep()
            flashLabel.stringValue = "Wait for the running git operation to finish."
        }
        onAfterAction?()
    }

    // MARK: diff

    private func refreshPanels() {
        guard let v = view, v.handle != 0 else { return }
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        var n = 0
        while true {
            n = buf.withUnsafeMutableBufferPointer { b -> Int in
                Int(tk_desktop_git_panels(v.handle, Int64(v.cols()), Int64(v.rows()),
                                          Int64(Int(bitPattern: b.baseAddress)), Int64(b.count)))
            }
            if n <= buf.count { break }
            buf = [UInt8](repeating: 0, count: n)
        }
        let data = n > 0 ? Data(buf[0..<n]) : Data()
        guard data != lastPanels else { return }
        lastPanels = data
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            diff.string = ""
            lineMap = []
            return
        }
        render(o)
    }

    private func render(_ o: [String: Any]) {
        let bg = PickerController.rgb(o["bg"] as? Int ?? 0)
        let fg = PickerController.rgb(o["fg"] as? Int ?? 0xFFFFFF)
        diff.backgroundColor = bg
        diff.enclosingScrollView?.backgroundColor = bg
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let out = NSMutableAttributedString()
        lineMap = []
        lineStarts = []
        let addBg = NSColor.systemGreen.withAlphaComponent(0.22)
        let remBg = NSColor.systemRed.withAlphaComponent(0.22)
        func line(_ text: String, _ attrs: [NSAttributedString.Key: Any], _ map: (Int, Int)?) -> Int {
            lineStarts.append(out.length)
            lineMap.append(map)
            let start = out.length
            out.append(NSAttributedString(string: text + "\n", attributes: attrs))
            return start
        }
        let panels = o["panels"] as? [[String: Any]] ?? []
        for p in panels {
            let pane = p["pane"] as? Int ?? GitPane.info
            let rows = p["rows"] as? [[Any]] ?? []
            if pane != GitPane.info {
                let title = pane == GitPane.unstaged ? "Unstaged changes" : "Staged changes"
                _ = line(title, [.font: NSFont.systemFont(ofSize: 12, weight: .bold),
                                 .foregroundColor: fg.withAlphaComponent(0.8)], nil)
                if rows.isEmpty {
                    _ = line("  None", [.font: mono, .foregroundColor: fg.withAlphaComponent(0.45)], nil)
                }
            }
            var rowStart: [Int] = []
            for (r, row) in rows.enumerated() {
                let kind = row.first as? Int ?? 0
                let text = row.count > 1 ? (row[1] as? String ?? "") : ""
                var attrs: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: fg]
                var shown = text
                switch kind {
                case GitLine.add: attrs[.backgroundColor] = addBg; shown = "+ " + text
                case GitLine.rem: attrs[.backgroundColor] = remBg; shown = "- " + text
                case GitLine.ctx: shown = "  " + text
                case GitLine.fileHdr:
                    attrs[.font] = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
                case GitLine.sep:
                    shown = "  ⋯"
                    attrs[.foregroundColor] = fg.withAlphaComponent(0.4)
                default: break
                }
                rowStart.append(line(shown, attrs, (pane, r)) + (kind == GitLine.add || kind == GitLine.rem || kind == GitLine.ctx ? 2 : 0))
            }
            // Syntax spans: byte ranges in the stripped row text.
            for sp in p["spans"] as? [[Int]] ?? [] where sp.count == 4 && sp[0] < rows.count {
                let text = rows[sp[0]].count > 1 ? (rows[sp[0]][1] as? String ?? "") : ""
                let u = Array(text.utf8)
                let a = min(max(sp[1], 0), u.count), b = min(max(sp[2], a), u.count)
                let pre = String(decoding: u[0..<a], as: UTF8.self).utf16.count
                let len = String(decoding: u[a..<b], as: UTF8.self).utf16.count
                guard len > 0 else { continue }
                out.addAttribute(.foregroundColor, value: PickerController.rgb(sp[3]),
                                 range: NSRange(location: rowStart[sp[0]] + pre, length: len))
            }
            _ = line("", [.font: mono], nil)
        }
        let clip = diff.enclosingScrollView?.contentView
        let keep = clip?.bounds.origin ?? .zero
        diff.textStorage?.setAttributedString(out)
        // Same selection, same scroll: re-render after staging a line must
        // not yank the view.
        if let clip = clip {
            clip.scroll(to: keep)
            diff.enclosingScrollView?.reflectScrolledClipView(clip)
        }
        markCursor()
    }

    private func lineIndex(at loc: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1, ans = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lineStarts[mid] <= loc { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return ans
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let v = view, v.handle != 0 else { return }
        let li = lineIndex(at: diff.selectedRange().location)
        guard li >= 0, li < lineMap.count, let (pane, row) = lineMap[li] else { return }
        cursorLine = li
        tk_desktop_git_cursor(v.handle, Int64(pane), Int64(row))
        markCursor()
    }

    private func markCursor() {
        guard let lm = diff.layoutManager else { return }
        lm.removeTemporaryAttribute(.underlineStyle,
                                    forCharacterRange: NSRange(location: 0, length: diff.textStorage?.length ?? 0))
        guard cursorLine >= 0, cursorLine < lineStarts.count else { return }
        let end = cursorLine + 1 < lineStarts.count ? lineStarts[cursorLine + 1] - 1 : (diff.textStorage?.length ?? 0)
        lm.addTemporaryAttribute(.underlineStyle, value: NSUnderlineStyle.thick.rawValue,
                                 forCharacterRange: NSRange(location: lineStarts[cursorLine],
                                                            length: max(0, end - lineStarts[cursorLine])))
    }

    private func cursorTarget() -> (Int, Int)? {
        guard cursorLine >= 0, cursorLine < lineMap.count else { return nil }
        return lineMap[cursorLine]
    }

    private func diffKey(_ k: String) -> Bool {
        switch k {
        case "esc": closeClicked(); return true
        case "space":
            guard let (pane, _) = cursorTarget(), pane != GitPane.info else { return false }
            key(pane, 0x20); return true
        case "enter":
            openCursor(); return true
        default: return false
        }
    }

    private func openCursor() {
        guard let v = view, v.handle != 0, let (pane, row) = cursorTarget() else { return }
        tk_desktop_git_open(v.handle, Int64(pane), Int64(row), Int64(v.cols()), Int64(v.rows()))
        onAfterAction?()
    }

    // MARK: overlays → alerts

    private func showOverlayIfNeeded(_ ov: [String: Any]) {
        let kind = ov["kind"] as? String ?? ""
        if kind.isEmpty { overlayShown = ""; return }
        guard kind != overlayShown, panel.attachedSheet == nil else { return }
        overlayShown = kind
        let message = (ov["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let action = (ov["action"] as? String ?? "").capitalized
        let alert = NSAlert()
        var answer: (NSApplication.ModalResponse) -> (String, String) = { r in
            (r == .alertFirstButtonReturn ? "ok" : "cancel", "")
        }
        switch kind {
        case "status":
            alert.messageText = "Git"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Close")
        case "output":
            alert.messageText = "Git output"
            alert.addButton(withTitle: "Close")
            alert.accessoryView = scrollingText(ov["output"] as? String ?? "", height: 260, editable: false).0
        case "merge_choice":
            alert.messageText = message.isEmpty ? "Bring the branch in" : message
            alert.informativeText = "A merge commit keeps both histories; a rebase replays the branch's commits for straight history."
            alert.addButton(withTitle: "Merge Commit")
            alert.addButton(withTitle: "Rebase")
            alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
            answer = { r in
                r == .alertFirstButtonReturn ? ("merge", "") :
                r == .alertSecondButtonReturn ? ("rebase", "") : ("cancel", "")
            }
        case "edit_message", "commit":
            alert.messageText = kind == "commit" ? "Commit" : "Reword commit"
            let (sv, tv) = scrollingText(ov["text"] as? String ?? "", height: 120, editable: true)
            alert.accessoryView = sv
            alert.addButton(withTitle: kind == "commit" ? "Commit" : "Reword")
            alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
            alert.window.initialFirstResponder = tv
            answer = { r in (r == .alertFirstButtonReturn ? "ok" : "cancel", tv.string) }
        case "remote_pick":
            alert.messageText = "Push to which remote?"
            let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
            pop.addItems(withTitles: ov["remotes"] as? [String] ?? [])
            pop.selectItem(at: ov["remote_sel"] as? Int ?? 0)
            alert.accessoryView = pop
            alert.addButton(withTitle: "Push")
            alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
            answer = { r in (r == .alertFirstButtonReturn ? "ok" : "cancel", "\(pop.indexOfSelectedItem)") }
        case "delete_remote_typed":
            let prefix = ov["prefix"] as? String ?? ""
            alert.messageText = message
            alert.informativeText = "Its work isn't on the main line. Type “\(prefix)” to delete it on the remote."
            alert.alertStyle = .critical
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            let del = alert.addButton(withTitle: "Delete")
            del.hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
            answer = { r in (r == .alertFirstButtonReturn ? "ok" : "cancel", field.stringValue) }
        default:   // amend / revert / discard_line / delete_branch
            alert.messageText = message.isEmpty ? "Are you sure?" : message
            alert.alertStyle = kind == "amend" ? .informational : .warning
            let b = alert.addButton(withTitle: action.isEmpty ? "Continue" : action)
            b.hasDestructiveAction = kind != "amend"
            alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        }
        alert.beginSheetModal(for: panel) { [weak self] r in
            guard let self = self, let v = self.view, v.handle != 0 else { return }
            let (choice, text) = answer(r)
            withUTF8Arg(choice) { cp, cl in
                withUTF8Arg(text) { tp, tl in tk_desktop_git_answer(v.handle, cp, cl, tp, tl) }
            }
            self.overlayShown = ""
            self.lastData = Data()
            self.onAfterAction?()
        }
    }

    private func scrollingText(_ text: String, height: CGFloat, editable: Bool) -> (NSScrollView, NSTextView) {
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: height))
        let tv = NSTextView(frame: sv.bounds)
        tv.isEditable = editable
        tv.isRichText = false
        tv.font = editable ? .systemFont(ofSize: 13) : .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.string = text
        tv.autoresizingMask = [.width]
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.borderType = .bezelBorder
        if !editable { tv.scrollToEndOfDocument(nil) }
        return (sv, tv)
    }
}

extension GitController: NSMenuDelegate {
    /// Context menus for the list and the diff, built for what's under the
    /// pointer — each item is one of the view's keys.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ run: @escaping () -> Void) { menu.addItem(TabMenuItem(title, run)) }
        if menu === table.menu {
            let row = table.clickedRow
            guard row >= 0, let v = view, v.handle != 0 else { return }
            tk_desktop_git_select(v.handle, Int64(list), Int64(row), Int64(v.cols()), Int64(v.rows()))
            switch list {
            case GitPane.files:
                let f = files[row]
                let staged = (f["x"] as? String ?? " ") != " " && (f["x"] as? String) != "?"
                add(staged ? "Unstage" : "Stage") { [weak self] in self?.key(GitPane.files, 0x20) }
                add("Open in Editor") { [weak self] in self?.tableDoubleClicked() }
                menu.addItem(.separator())
                add((f["x"] as? String) == "?" ? "Delete File…" : "Discard Changes…") { [weak self] in
                    self?.key(GitPane.files, self?.ch("d") ?? 0) }
            case GitPane.branches:
                let b = branches[row]
                let name = b["name"] as? String ?? ""
                let current = state["branch"] as? String ?? ""
                add("Check Out") { [weak self] in self?.key(GitPane.branches, 0x20) }
                if !(b["current"] as? Bool ?? false) {
                    add("Bring “\(name)” into “\(current)”…") { [weak self] in self?.key(GitPane.branches, self?.ch("M") ?? 0) }
                    add("Rebase") { [weak self] in self?.key(GitPane.branches, self?.ch("r") ?? 0) }
                }
                add("Compare on GitHub") { [weak self] in self?.key(GitPane.branches, self?.ch("o") ?? 0) }
                menu.addItem(.separator())
                add("Delete Branch…") { [weak self] in self?.key(GitPane.branches, self?.ch("d") ?? 0) }
            default:
                let c = commits[row]
                add("Reword…") { [weak self] in self?.key(GitPane.commits, self?.ch("e") ?? 0) }
                add("Copy SHA") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(c["sha"] as? String ?? "", forType: .string)
                }
            }
        } else if menu === diff.menu {
            guard let (pane, _) = cursorTarget() else { return }
            if pane == GitPane.unstaged {
                add("Stage Line") { [weak self] in self?.key(GitPane.unstaged, 0x20) }
                add("Discard Line…") { [weak self] in self?.key(GitPane.unstaged, self?.ch("d") ?? 0) }
            } else if pane == GitPane.staged {
                add("Unstage Line") { [weak self] in self?.key(GitPane.staged, 0x20) }
            }
            add("Open in Editor") { [weak self] in self?.openCursor() }
        }
    }
}

/// A git list row: title (+ optional badge) over a detail line, with an
/// optional leading stage checkbox.
final class GitRowCell: NSTableCellView {
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let row = NSStackView()
    private var onCheck: (() -> Void)?

    init() {
        super.init(frame: .zero)
        title.lineBreakMode = .byTruncatingMiddle
        detail.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        badge.font = .systemFont(ofSize: 10, weight: .semibold)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let titleRow = NSStackView(views: [title, NSView(), badge])
        let text = NSStackView(views: [titleRow, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        titleRow.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        row.addArrangedSubview(text)
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func set(title t: String, detail d: String, badge b: String, badgeColor: NSColor,
             bold: Bool = false, dim: Bool = false) {
        title.stringValue = t
        title.font = .systemFont(ofSize: 13, weight: bold ? .semibold : .regular)
        title.textColor = dim ? .secondaryLabelColor : .labelColor
        detail.stringValue = d
        badge.stringValue = b
        badge.textColor = badgeColor
    }

    func addCheckbox(state: NSControl.StateValue, onChange: @escaping () -> Void) {
        onCheck = onChange
        let cb = NSButton(checkboxWithTitle: "", target: self, action: #selector(checked))
        cb.allowsMixedState = true
        cb.state = state
        cb.toolTip = "Staged for the next commit"
        row.insertArrangedSubview(cb, at: 0)
    }

    @objc private func checked() { onCheck?() }
}


// MARK: - macOS-style UI: find bar
//
// In-file Find / Replace as a bar under the tabs (Safari / Xcode style)
// rather than a modal: the editor stays live while stepping through matches.
// Every button is one `tk_desktop_find` op on the focused editor, through
// the same find / replace / mark code the in-grid prompt uses.

final class FindBar: NSView, NSSearchFieldDelegate {
    var onOp: ((String) -> Void)?
    var onClose: (() -> Void)?
    private let find = NSSearchField()
    private let replace = NSTextField()
    private var toggles: [String: NSButton] = [:]
    private var replaceViews: [NSView] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        find.placeholderString = "Find"
        find.delegate = self
        find.sendsSearchStringImmediately = false
        replace.placeholderString = "Replace with"
        replace.delegate = self
        replace.usesSingleLineMode = true
        func button(_ title: String, symbol: String? = nil, _ op: String) -> NSButton {
            let b = NSButton(title: title, target: self, action: #selector(opClicked(_:)))
            if let s = symbol {
                b.image = NSImage(systemSymbolName: s, accessibilityDescription: title)
                b.imagePosition = .imageOnly
            }
            b.bezelStyle = .texturedRounded
            b.identifier = NSUserInterfaceItemIdentifier(op)
            b.toolTip = title
            return b
        }
        var views: [NSView] = [find]
        for (key, label, tip) in [("case", "Aa", "Match case"), ("word", "W", "Whole word"),
                                  ("regex", ".*", "Regular expression")] {
            let b = NSButton(title: label, target: nil, action: nil)
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .texturedRounded
            b.toolTip = tip
            toggles[key] = b
            views.append(b)
        }
        views.append(button("Previous", symbol: "chevron.left", "prev"))
        views.append(button("Next", symbol: "chevron.right", "next"))
        views.append(button("Mark All", "mark"))
        let rep = button("Replace", "replace")
        let all = button("Replace All", "replace_all")
        replaceViews = [replace, rep, all]
        views += [replace, rep, all]
        let done = NSButton(title: "Done", target: self, action: #selector(closeClicked))
        done.bezelStyle = .texturedRounded
        views.append(done)
        let stack = NSStackView(views: views)
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            find.widthAnchor.constraint(equalToConstant: 260),
            replace.widthAnchor.constraint(equalToConstant: 200),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var mouseDownCanMoveWindow: Bool { false }

    /// Open (or re-focus) for a core request: seed, toggles, and whether
    /// the Replace half shows.
    func show(_ req: [String: Any]) {
        let seed = req["seed"] as? String ?? ""
        if !seed.isEmpty { find.stringValue = seed }
        for (k, b) in toggles { b.state = (req[k] as? Bool ?? false) ? .on : .off }
        let replacing = req["mode"] as? String == "replace"
        for v in replaceViews { v.isHidden = !replacing }
        window?.makeFirstResponder(find)
        find.currentEditor()?.selectAll(nil)
    }

    private func send(_ op: String) {
        let o: [String: Any] = [
            "op": op, "find": find.stringValue, "replace": replace.stringValue,
            "case": toggles["case"]?.state == .on, "word": toggles["word"]?.state == .on,
            "regex": toggles["regex"]?.state == .on,
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: o),
              let json = String(data: d, encoding: .utf8) else { return }
        onOp?(json)
    }

    @objc private func opClicked(_ b: NSButton) {
        guard let op = b.identifier?.rawValue else { return }
        send(op)
    }

    @objc private func closeClicked() { onClose?() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            send(control === replace ? "replace" : shift ? "prev" : "next")
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}


// MARK: - macOS-style UI: file tree
//
// A native source list laid over the file tree's cells (a subview of the
// cell view, framed from the core's cell rect). The core keeps the model —
// the flat visible-entry list, expansion, selection — and the separator
// column it still paints stays the resize handle. Row actions go back
// through `tk_desktop_tree_act`; the context menu is the core's own
// Rename / Delete popup, which arrives here as an NSMenu.

final class FileTreeTable: NSTableView {
    var onKey: ((String) -> Bool)?
    override func keyDown(with e: NSEvent) {
        let k: String
        switch e.keyCode {
        case 36, 76: k = "enter"
        case 123: k = "left"
        case 124: k = "right"
        default: k = ""
        }
        if !k.isEmpty, onKey?(k) == true { return }
        super.keyDown(with: e)
    }
}

final class FileTreeOverlay: NSVisualEffectView, NSTableViewDataSource, NSTableViewDelegate {
    private weak var cellView: CellView?
    private let table = FileTreeTable()
    private let scroll = NSScrollView()
    private var entries: [[Any]] = []
    private var lastData = Data()
    private var syncing = false
    private var iconCache: [String: NSImage] = [:]

    init(view: CellView) {
        cellView = view
        super.init(frame: .zero)
        material = .sidebar
        blendingMode = .withinWindow
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        table.addTableColumn(col)
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 22
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.menu = NSMenu()
        table.menu?.delegate = self
        table.onKey = { [weak self] k in self?.key(k) ?? false }
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Adopt a `tk_desktop_tree` payload; true when it changed anything.
    func update(_ data: Data) -> Bool {
        guard data != lastData,
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        lastData = data
        let x = CGFloat(o["x"] as? Int ?? 0), y = CGFloat(o["y"] as? Int ?? 0)
        let w = CGFloat(o["w"] as? Int ?? 0), h = CGFloat(o["h"] as? Int ?? 0)
        let f = NSRect(x: x * CELL_W, y: y * CELL_H, width: w * CELL_W, height: h * CELL_H)
        if frame != f { frame = f }
        let newEntries = o["entries"] as? [[Any]] ?? []
        let changed = newEntries.count != entries.count
            || !zip(newEntries, entries).allSatisfy { NSArray(array: $0).isEqual(to: $1) }
        entries = newEntries
        syncing = true
        if changed { table.reloadData() }
        let sel = o["selected"] as? Int ?? -1
        if sel >= 0 && sel < entries.count {
            if table.selectedRow != sel {
                table.selectRowIndexes(IndexSet(integer: sel), byExtendingSelection: false)
                table.scrollRowToVisible(sel)
            }
        } else {
            table.deselectAll(nil)
        }
        syncing = false
        return true
    }

    private func act(_ op: Int, _ idx: Int, _ at: NSPoint = .zero) {
        guard let v = cellView, v.handle != 0 else { return }
        tk_desktop_tree_act(v.handle, Int64(op), Int64(idx),
                            Int64(at.x / CELL_W), Int64(at.y / CELL_H))
        lastData = Data()
        v.invalidateFrame()
        v.needsDisplay = true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row i: Int) -> NSView? {
        let e = entries[i]
        let name = e[0] as? String ?? ""
        let depth = e[1] as? Int ?? 0
        let isDir = e[2] as? Bool ?? false
        let expanded = e[3] as? Bool ?? false
        let modified = e[4] as? Bool ?? false
        let path = e.count > 5 ? (e[5] as? String ?? "") : ""
        let cell = NSTableCellView()
        let indent = CGFloat(depth) * 14 + 2
        var x = indent
        if isDir {
            let chevron = NSButton(image: NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right",
                                                  accessibilityDescription: expanded ? "Collapse" : "Expand")!,
                                   target: self, action: #selector(chevronClicked(_:)))
            chevron.isBordered = false
            chevron.tag = i
            chevron.imageScaling = .scaleProportionallyDown
            chevron.frame = NSRect(x: x, y: 3, width: 14, height: 16)
            chevron.contentTintColor = .secondaryLabelColor
            cell.addSubview(chevron)
        }
        x += 16
        let icon = NSImageView(frame: NSRect(x: x, y: 3, width: 16, height: 16))
        icon.image = self.icon(path: path, isDir: isDir)
        cell.addSubview(icon)
        let label = NSTextField(labelWithString: name)
        label.frame = NSRect(x: x + 20, y: 3, width: 1000, height: 16)
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 13)
        label.textColor = modified ? .systemOrange : .labelColor
        cell.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: x + 20),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        if modified {
            label.stringValue = name + "  ●"
        }
        return cell
    }

    private func icon(path: String, isDir: Bool) -> NSImage {
        let key = isDir ? "/dir" : (path as NSString).pathExtension
        if let i = iconCache[key] { return i }
        let img: NSImage
        if isDir {
            img = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Folder")
                ?? NSWorkspace.shared.icon(for: .folder)
            img.isTemplate = true
        } else {
            img = NSWorkspace.shared.icon(forFile: path)
        }
        img.size = NSSize(width: 16, height: 16)
        iconCache[key] = img
        return img
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { nil }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncing, table.selectedRow >= 0 else { return }
        act(0, table.selectedRow)
    }

    @objc private func chevronClicked(_ b: NSButton) { act(1, b.tag) }

    @objc private func doubleClicked() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0 else { return }
        open(row)
    }

    private func open(_ row: Int) {
        let isDir = entries[row][2] as? Bool ?? false
        act(2, row)
        // A file lands in the editor: hand it the keyboard.
        if !isDir, let v = cellView { v.window?.makeFirstResponder(v) }
    }

    private func key(_ k: String) -> Bool {
        let row = table.selectedRow
        guard row >= 0, row < entries.count else { return false }
        let isDir = entries[row][2] as? Bool ?? false
        let expanded = entries[row][3] as? Bool ?? false
        switch k {
        case "enter": open(row); return true
        case "right" where isDir && !expanded: act(1, row); return true
        case "left" where isDir && expanded: act(1, row); return true
        default: return false
        }
    }
}

extension FileTreeOverlay: NSMenuDelegate {
    /// Right-click: arm the core's own row menu (Rename / Delete), which
    /// pops up as an NSMenu through the popup poll. Nothing shows here.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard row >= 0, let v = cellView, let ev = NSApp.currentEvent else { return }
        let p = v.convert(ev.locationInWindow, from: nil)
        DispatchQueue.main.async { [weak self] in self?.act(3, row, p) }
    }
}


// MARK: - code preview (welcome window, Settings ▸ Appearance)

/// A few lines of code painted through a theme's editor and syntax slots
/// (EDITOR_BG / EDITOR_FG = 16 / 17, SYN_* = 18…24) in a given font.
final class CodePreview: NSTextView {
    static let sizes = [0, 11, 12, 13, 14, 15, 16, 18, 20, 24]

    convenience init() {
        self.init(frame: NSRect(x: 0, y: 0, width: 400, height: 150))
        isEditable = false
        isSelectable = false
        textContainerInset = NSSize(width: 14, height: 12)
        wantsLayer = true
        layer?.cornerRadius = 8
    }

    /// A Font-list label at a size, resolved the way the editor resolves
    /// it: the built-in rows are the bundled VGA fonts (16pt default),
    /// anything else a system monospace family (13pt default).
    static func font(label: String, size: Int, builtins: [String]) -> NSFont {
        if let i = builtins.firstIndex(of: label) {
            return loadCellFont(size: CGFloat(size > 0 ? size : 16),
                                file: i == 1 ? CLASSIC_FONT_FILE : BUNDLED_FONT_FILE)
        }
        let s = CGFloat(size > 0 ? size : 13)
        return NSFontManager.shared.font(withFamily: label, traits: [], weight: 5, size: s)
            ?? .monospacedSystemFont(ofSize: s, weight: .regular)
    }

    func render(palette pal: [UInt32], font: NSFont) {
        func c(_ slot: Int) -> NSColor {
            PickerController.rgb(Int(slot < pal.count ? pal[slot] : 0xFFFFFF))
        }
        let (fg, kw, str, com, num, ident, deco, op) = (17, 18, 19, 20, 21, 22, 23, 24)
        let lines: [[(String, Int)]] = [
            [("# A taste of your editor", com)],
            [("@", deco), ("dataclass", deco)],
            [("class", kw), (" ", fg), ("Point", ident), (":", op)],
            [("    x", fg), (":", op), (" ", fg), ("int", kw), (" = ", op), ("0", num)],
            [("", fg)],
            [("def", kw), (" ", fg), ("greet", ident), ("(", op), ("name", fg), (")", op), (":", op)],
            [("    count", fg), (" = ", op), ("42", num)],
            [("    return", kw), (" ", fg), ("f\"Hello, {name}!\"", str)],
        ]
        let out = NSMutableAttributedString()
        for (i, line) in lines.enumerated() {
            for (text, slot) in line {
                out.append(NSAttributedString(string: text, attributes: [
                    .font: font, .foregroundColor: c(slot)]))
            }
            if i + 1 < lines.count {
                out.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            }
        }
        textStorage?.setAttributedString(out)
        backgroundColor = c(16)
    }
}


// MARK: - macOS-style UI: Settings window
//
// The everyday settings as a native window — General, Appearance, Language
// Features — over the same `Settings` state the grid window edits: each
// change goes in through `tk_desktop_prefs_set` and the Desktop's per-frame
// settings sync applies it, side effects and persistence included.
// "Advanced Settings…" hands the open Settings to the grid window, which has
// every section (language servers, spelling dictionaries, projects).

final class PrefsController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private let window: NSWindow
    private weak var view: CellView?
    private let onClose: () -> Void
    private var closingForAdvanced = false
    private var dismissed = false
    private let preview = CodePreview()
    private let themePopup = NSPopUpButton()
    private let fontPopup = NSPopUpButton()
    private let sizePopup = NSPopUpButton()
    private var builtins: [String] = []
    private var lastData = Data()
    private lazy var lists = PrefsLists(view: view, window: window)
    private let tabView = NSTabView()

    func refreshLists() { lists.refresh() }

    private static let lsp: [(String, String)] = [
        ("ls_format_on_save", "Format on save"),
        ("ls_signature_help", "Signature help while typing"),
        ("ls_document_highlight", "Highlight occurrences of the symbol at the caret"),
        ("ls_document_links", "Clickable links in documents"),
        ("ls_inlay_hints", "Inlay hints (inline types and parameter names)"),
        ("ls_code_lens", "Code lens (actionable annotations)"),
        ("ls_document_colors", "Color swatches"),
        ("ls_linked_editing", "Linked editing (rename matching tags together)"),
        ("ls_server_progress", "Show language-server progress"),
    ]

    init(values o: [String: Any], view: CellView, onClose: @escaping () -> Void) {
        self.view = view
        self.onClose = onClose
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        build(o)
    }

    // MARK: building

    private func set(_ key: String, _ value: Any) {
        guard let h = view?.handle, h != 0,
              let d = try? JSONSerialization.data(withJSONObject: [key: value]),
              let json = String(data: d, encoding: .utf8) else { return }
        withUTF8Arg(json) { p, l in tk_desktop_prefs_set(h, p, l) }
    }

    private func check(_ title: String, _ key: String, _ o: [String: Any]) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: #selector(checkChanged(_:)))
        b.identifier = NSUserInterfaceItemIdentifier(key)
        b.state = (o[key] as? Bool ?? false) ? .on : .off
        return b
    }

    @objc private func checkChanged(_ b: NSButton) {
        guard let key = b.identifier?.rawValue else { return }
        set(key, b.state == .on)
    }

    private func popup(_ items: [String], _ selected: Int, _ key: String) -> NSPopUpButton {
        let p = NSPopUpButton()
        p.addItems(withTitles: items)
        p.selectItem(at: selected)
        p.identifier = NSUserInterfaceItemIdentifier(key)
        p.target = self
        p.action = #selector(popupChanged(_:))
        return p
    }

    @objc private func popupChanged(_ p: NSPopUpButton) {
        switch p.identifier?.rawValue ?? "" {
        case "auto_save": set("auto_save", p.indexOfSelectedItem == 1)
        case "wrap_mode": set("wrap_mode", p.indexOfSelectedItem)
        default: break
        }
    }

    private func numberField(_ value: Int, empty: Int, _ key: String) -> NSTextField {
        let f = NSTextField(string: value == empty || value < 0 ? "" : "\(value)")
        f.placeholderString = key == "max_open_windows" ? "No limit" : "Off"
        f.identifier = NSUserInterfaceItemIdentifier(key)
        f.delegate = self
        f.widthAnchor.constraint(equalToConstant: 80).isActive = true
        return f
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let f = obj.object as? NSTextField, let key = f.identifier?.rawValue else { return }
        let n = Int(f.stringValue.trimmingCharacters(in: .whitespaces))
        set(key, n ?? (key == "max_open_windows" ? 0 : -1))
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        return l
    }

    private func pane(_ rows: [[NSView]]) -> NSView {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false
        let v = NSView()
        v.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: v.topAnchor, constant: 20),
            grid.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: v.leadingAnchor, constant: 20),
        ])
        return v
    }

    private func build(_ o: [String: Any]) {
        let empty = NSGridCell.emptyContentView
        let general = pane([
            [label("Saving:"), popup(["Manual", "Automatic"], (o["auto_save"] as? Bool ?? false) ? 1 : 0, "auto_save")],
            [empty, check("Trim trailing whitespace on save", "trim_trailing_whitespace", o)],
            [empty, check("Ensure a final newline on save", "ensure_final_newline", o)],
            [label("Line wrapping:"), popup(["None", "Soft", "Smart"], o["wrap_mode"] as? Int ?? 0, "wrap_mode")],
            [label("Smart wrap at commas:"), numberField(o["comma_threshold"] as? Int ?? -1, empty: -1, "comma_threshold")],
            [label("Open documents:"), numberField(o["max_open_windows"] as? Int ?? 0, empty: 0, "max_open_windows")],
            [empty, check("Compress keyword arguments", "compress_kwargs", o)],
            [empty, check("Blinking caret", "cursor_blink", o)],
        ])

        builtins = Array((o["fonts"] as? [String] ?? []).prefix(2))
        themePopup.addItems(withTitles: o["themes"] as? [String] ?? [])
        themePopup.selectItem(withTitle: o["theme"] as? String ?? "")
        fontPopup.addItems(withTitles: o["fonts"] as? [String] ?? [])
        fontPopup.selectItem(withTitle: o["font"] as? String ?? "")
        sizePopup.addItems(withTitles: CodePreview.sizes.map { $0 == 0 ? "Default" : "\($0) pt" })
        sizePopup.selectItem(at: CodePreview.sizes.firstIndex(of: o["font_size"] as? Int ?? 0) ?? 0)
        for p in [themePopup, fontPopup, sizePopup] {
            p.target = self
            p.action = #selector(appearanceChanged(_:))
        }
        let look = NSButton(checkboxWithTitle: "macOS-style UI (native tabs, sheets and pickers)",
                            target: self, action: #selector(lookChanged(_:)))
        look.state = (o["native_ui"] as? Bool ?? false) ? .on : .off
        preview.heightAnchor.constraint(equalToConstant: 150).isActive = true
        preview.widthAnchor.constraint(equalToConstant: 460).isActive = true
        let appearance = pane([
            [empty, look],
            [label("Theme:"), themePopup],
            [label("Font:"), fontPopup],
            [label("Size:"), sizePopup],
            [empty, preview],
        ])
        themePopup.widthAnchor.constraint(equalToConstant: 260).isActive = true
        fontPopup.widthAnchor.constraint(equalToConstant: 260).isActive = true

        var lspRows: [[NSView]] = []
        for (key, title) in Self.lsp { lspRows.append([empty, check(title, key, o)]) }
        let features = pane(lspRows)

        let tabs = tabView
        for (title, v) in [("General", general), ("Appearance", appearance), ("Language Features", features),
                           ("Languages", lists.languagesPane()), ("Spelling", lists.dictionariesPane()),
                           ("Projects", lists.projectsPane())] {
            let item = NSTabViewItem(identifier: title)
            item.label = title
            item.view = v
            tabs.addTabViewItem(item)
        }
        let content = NSView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            tabs.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        window.contentView = content
        renderPreview()
    }

    @objc private func appearanceChanged(_ p: NSPopUpButton) {
        if p === themePopup { set("theme", themePopup.titleOfSelectedItem ?? "") }
        if p === fontPopup { set("font", fontPopup.titleOfSelectedItem ?? "") }
        if p === sizePopup { set("font_size", CodePreview.sizes[max(0, sizePopup.indexOfSelectedItem)]) }
        renderPreview()
    }

    @objc private func lookChanged(_ b: NSButton) {
        guard let v = view, v.handle != 0 else { return }
        _ = withUTF8Arg("view:native_ui") { p, l in
            tk_desktop_menu_invoke(v.handle, p, l, Int64(v.cols()), Int64(v.rows()))
        }
    }

    private func renderPreview() {
        var pal = [UInt32](repeating: 0, count: 256)
        if let h = view?.handle, h != 0 {
            pal.withUnsafeMutableBufferPointer { b in
                _ = tk_theme_palette(h, Int64(Int(bitPattern: b.baseAddress)), Int64(b.count))
            }
        }
        preview.render(palette: pal,
                       font: CodePreview.font(label: fontPopup.titleOfSelectedItem ?? "",
                                              size: CodePreview.sizes[max(0, sizePopup.indexOfSelectedItem)],
                                              builtins: builtins))
    }

    /// The core applies a theme on its next frame; re-read the palette when
    /// its state moves so the preview follows.
    func update(_ data: Data) {
        guard data != lastData else { return }
        lastData = data
        renderPreview()
    }

    func show() {
        refreshLists()
        if isCapturing, let t = Int(ProcessInfo.processInfo.environment["TK_CAPTURE_PREFS_TAB"] ?? "") {
            tabView.selectTabViewItem(at: t)   // scripted screenshots
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        guard !dismissed else { return }
        dismissed = true
        closingForAdvanced = true   // the core already closed it
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        if !closingForAdvanced { onClose() }
    }
}


// MARK: - macOS-style UI: Spelling sheet
//
// Project ▸ Spelling: the core runs the incremental project scan and keeps
// the sorted word list; this shows it as a table (refetched whenever the
// scan's `version` moves, with the selection carried by word) and sends the
// selected rows to `tk_desktop_spelling_act`, which runs the dialog's own
// Add path.

final class SpellingController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private weak var view: CellView?
    private let panel: NSPanel
    private let status = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let table = NSTableView()
    private let addProject = NSButton(title: "Add to Project Dictionary", target: nil, action: nil)
    private let addUser = NSButton(title: "Add to My Dictionary", target: nil, action: nil)
    private var rows: [[Any]] = []
    private var version = -1
    private var lastData = Data()
    private var dismissed = false
    private var buf = [UInt8](repeating: 0, count: 1 << 16)

    init(view: CellView) {
        self.view = view
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
                        styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        super.init()
        let title = NSTextField(labelWithString: "Spelling")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        status.textColor = .secondaryLabelColor
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1000
        progress.style = .bar
        for (id, label, w) in [("count", "Count", 60.0), ("word", "Word", 200.0), ("where", "First seen", 300.0)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = label
            c.width = CGFloat(w)
            table.addTableColumn(c)
        }
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        addProject.target = self
        addProject.action = #selector(addProjectClicked)
        addUser.target = self
        addUser.action = #selector(addUserClicked)
        let close = NSButton(title: "Close", target: self, action: #selector(closeClicked))
        close.keyEquivalent = "\u{1b}"
        let hint = NSTextField(labelWithString: "Select words that are spelled right to teach the checker.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        let bar = NSStackView(views: [addProject, addUser, NSView(), close])
        let content = NSView()
        for v in [title, status, progress, scroll, hint, bar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
                v.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            ])
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            status.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            progress.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 4),
            scroll.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 8),
            hint.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            bar.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 10),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        panel.contentView = content
    }

    func present(in win: NSWindow) {
        let room = win.contentLayoutRect.size
        panel.setContentSize(NSSize(width: min(620, room.width - 40), height: min(520, room.height - 20)))
        win.beginSheet(panel, completionHandler: nil)
        panel.makeFirstResponder(table)
    }

    func dismiss() {
        guard !dismissed else { return }
        dismissed = true
        panel.sheetParent?.endSheet(panel)
    }

    func update(_ data: Data) -> Bool {
        guard data != lastData,
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        lastData = data
        status.stringValue = o["status"] as? String ?? ""
        let scanning = o["scanning"] as? Bool ?? false
        progress.isHidden = !scanning
        progress.doubleValue = Double(o["progress"] as? Int ?? 0)
        addProject.isEnabled = o["has_project"] as? Bool ?? false
        let v = o["version"] as? Int ?? 0
        if v != version || (o["count"] as? Int ?? 0) != rows.count {
            version = v
            reloadRows()
        }
        updateButtons()
        return true
    }

    /// Refetch the rows, keeping the selected words selected across the
    /// re-sort.
    private func reloadRows() {
        guard let h = view?.handle, h != 0 else { return }
        let keep = Set(table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0][0] as? String : nil })
        var n = 0
        while true {
            n = buf.withUnsafeMutableBufferPointer { b -> Int in
                Int(tk_desktop_spelling_rows(h, Int64(Int(bitPattern: b.baseAddress)), Int64(b.count)))
            }
            if n <= buf.count { break }
            buf = [UInt8](repeating: 0, count: n)
        }
        rows = n > 0 ? ((try? JSONSerialization.jsonObject(with: Data(buf[0..<n]))) as? [[Any]] ?? []) : []
        table.reloadData()
        var sel = IndexSet()
        for (i, r) in rows.enumerated() where keep.contains(r[0] as? String ?? "") { sel.insert(i) }
        table.selectRowIndexes(sel, byExtendingSelection: false)
    }

    private func updateButtons() {
        let any = !table.selectedRowIndexes.isEmpty
        addUser.isEnabled = any
        addProject.isEnabled = any && (try? JSONSerialization.jsonObject(with: lastData) as? [String: Any])?["has_project"] as? Bool == true
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row i: Int) -> NSView? {
        let r = rows[i]
        let text: String
        switch tableColumn?.identifier.rawValue ?? "" {
        case "count": text = "\(r.count > 1 ? (r[1] as? Int ?? 0) : 0)"
        case "word": text = r.first as? String ?? ""
        default: text = r.count > 3 ? "\(r[2] as? String ?? ""):\(r[3] as? Int ?? 0)" : ""
        }
        let l = NSTextField(labelWithString: text)
        l.lineBreakMode = .byTruncatingMiddle
        if tableColumn?.identifier.rawValue == "count" {
            l.alignment = .right
            l.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        }
        if tableColumn?.identifier.rawValue == "where" { l.textColor = .secondaryLabelColor }
        return l
    }

    private func act(_ action: Int) {
        guard let h = view?.handle, h != 0 else { return }
        let sel = Array(table.selectedRowIndexes)
        let json = (try? JSONSerialization.data(withJSONObject: sel))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        withUTF8Arg(json) { p, l in tk_desktop_spelling_act(h, Int64(action), p, l) }
        table.deselectAll(nil)
        lastData = Data()
        version = -1
    }

    @objc private func addProjectClicked() { act(1) }
    @objc private func addUserClicked() { act(2) }
    @objc private func closeClicked() { act(0) }
}


// MARK: - macOS-style UI: Git history sheet
//
// Git ▸ History of a file or a selection: commits on the left, the selected
// commit's patch on the right, colored like the grid view colors it (by
// line prefix) on the theme's editor background. The core fetched
// everything when it opened; this only selects and closes.

final class HistoryController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private weak var view: CellView?
    private let panel: NSPanel
    private let titleLabel = NSTextField(labelWithString: "")
    private let table = GitTable()
    private let patch = NSTextView()
    private var entries: [[Any]] = []
    private var lastData = Data()
    private var shown = -1
    private var syncing = false
    private var dismissed = false
    private var buf = [UInt8](repeating: 0, count: 1 << 16)

    init(view: CellView) {
        self.view = view
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
                        styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        super.init()
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        let close = NSButton(title: "Close", target: self, action: #selector(closeClicked))
        close.keyEquivalent = "\u{1b}"
        let top = NSStackView(views: [NSImageView(image: NSImage(systemSymbolName: "clock.arrow.circlepath",
                                                                 accessibilityDescription: "History") ?? NSImage()),
                                      titleLabel, NSView(), close])
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 38
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.onKey = { [weak self] k in
            if k == "esc" { self?.closeClicked(); return true }
            return false
        }
        let tableScroll = NSScrollView()
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        patch.isEditable = false
        patch.textContainerInset = NSSize(width: 6, height: 6)
        patch.isHorizontallyResizable = true
        patch.textContainer?.widthTracksTextView = false
        patch.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                    height: CGFloat.greatestFiniteMagnitude)
        let patchScroll = NSScrollView()
        patchScroll.documentView = patch
        patchScroll.hasVerticalScroller = true
        patchScroll.hasHorizontalScroller = true
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(tableScroll)
        split.addArrangedSubview(patchScroll)
        tableScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        let content = NSView()
        for v in [top, split] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
                v.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            ])
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            split.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            split.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        panel.contentView = content
        splitView = split
    }

    private var splitView: NSSplitView?

    func present(in win: NSWindow) {
        let room = win.contentLayoutRect.size
        panel.setContentSize(NSSize(width: max(700, room.width - 40), height: max(460, room.height - 30)))
        panel.contentView?.layoutSubtreeIfNeeded()
        splitView?.setPosition(min(380, panel.frame.width * 0.36), ofDividerAt: 0)
        win.beginSheet(panel, completionHandler: nil)
        panel.makeFirstResponder(table)
    }

    func dismiss() {
        guard !dismissed else { return }
        dismissed = true
        panel.sheetParent?.endSheet(panel)
    }

    func update(_ data: Data) -> Bool {
        guard data != lastData,
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        lastData = data
        titleLabel.stringValue = o["title"] as? String ?? "History"
        let newEntries = o["entries"] as? [[Any]] ?? []
        if newEntries.count != entries.count { entries = newEntries; table.reloadData() }
        let sel = o["selected"] as? Int ?? -1
        syncing = true
        if sel >= 0 && sel < entries.count && table.selectedRow != sel {
            table.selectRowIndexes(IndexSet(integer: sel), byExtendingSelection: false)
            table.scrollRowToVisible(sel)
        }
        syncing = false
        if sel != shown { showPatch(sel) }
        return true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row i: Int) -> NSView? {
        let e = entries[i]
        let cell = GitRowCell()
        let pushed = e.count > 4 ? (e[4] as? Bool ?? true) : true
        cell.set(title: e.count > 3 ? (e[3] as? String ?? "") : "",
                 detail: "\(e[0] as? String ?? "") · \(e.count > 1 ? (e[1] as? String ?? "") : "") · \(e.count > 2 ? (e[2] as? String ?? "") : "")",
                 badge: pushed ? "" : "↑ unpushed", badgeColor: .systemRed)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncing, let h = view?.handle, h != 0, table.selectedRow >= 0 else { return }
        tk_desktop_history_act(h, 0, Int64(table.selectedRow))
        lastData = Data()
    }

    private func showPatch(_ idx: Int) {
        shown = idx
        guard let h = view?.handle, h != 0, idx >= 0 else { patch.string = ""; return }
        var n = 0
        while true {
            n = buf.withUnsafeMutableBufferPointer { b -> Int in
                Int(tk_desktop_history_patch(h, Int64(idx), Int64(Int(bitPattern: b.baseAddress)), Int64(b.count)))
            }
            if n <= buf.count { break }
            buf = [UInt8](repeating: 0, count: n)
        }
        let text = String(decoding: buf[0..<max(n, 0)], as: UTF8.self)
        var pal = [UInt32](repeating: 0, count: 256)
        pal.withUnsafeMutableBufferPointer { b in
            _ = tk_theme_palette(h, Int64(Int(bitPattern: b.baseAddress)), Int64(b.count))
        }
        let bg = PickerController.rgb(Int(pal[16])), fg = PickerController.rgb(Int(pal[17]))
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let out = NSMutableAttributedString()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var attrs: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: fg]
            if line.hasPrefix("@@") {
                attrs[.foregroundColor] = NSColor.systemTeal
            } else if line.hasPrefix("+++") || line.hasPrefix("---") {
                attrs[.foregroundColor] = fg.withAlphaComponent(0.55)
            } else if line.hasPrefix("diff --git") || line.hasPrefix("index ") || line.hasPrefix("rename ")
                        || line.hasPrefix("new file") || line.hasPrefix("deleted file") {
                attrs[.foregroundColor] = NSColor.systemYellow
                attrs[.font] = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
            } else if line.hasPrefix("+") {
                attrs[.backgroundColor] = NSColor.systemGreen.withAlphaComponent(0.22)
            } else if line.hasPrefix("-") {
                attrs[.backgroundColor] = NSColor.systemRed.withAlphaComponent(0.22)
            }
            out.append(NSAttributedString(string: String(line) + "\n", attributes: attrs))
        }
        patch.textStorage?.setAttributedString(out)
        patch.backgroundColor = bg
        patch.enclosingScrollView?.backgroundColor = bg
        patch.scrollToBeginningOfDocument(nil)
    }

    @objc private func closeClicked() {
        guard let h = view?.handle, h != 0 else { return }
        tk_desktop_history_act(h, 1, 0)
        view?.invalidateFrame()
        view?.needsDisplay = true
    }
}


// MARK: - macOS-style UI: merge sheet
//
// A file changed on disk while its buffer had unsaved edits and the two
// don't merge cleanly. One card per conflict: your edits beside the disk's
// version with a little agreed context, and Keep Mine / Use Disk / Keep Both
// / Edit. Choices go to `tk_desktop_merge_choose`; Apply / Postpone run the
// core's own merge-done / merge-cancel handlers.

final class FlippedStack: NSView { override var isFlipped: Bool { true } }

final class MergeController: NSObject, NSTextViewDelegate {
    weak var view: CellView?
    var onAfterAction: (() -> Void)?
    private let panel: NSPanel
    private let titleLabel = NSTextField(labelWithString: "")
    private let note = NSTextField(labelWithString: "")
    private let cards = NSStackView()
    private var segments: [NSSegmentedControl] = []
    private var editors: [NSScrollView] = []
    private var editViews: [NSTextView] = []
    private var conflicts: [[String: Any]] = []
    private var lastData = Data()
    private var dismissed = false

    init(view: CellView) {
        self.view = view
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
                        styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        super.init()
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let sub = NSTextField(wrappingLabelWithString:
            "This file changed on disk while you had unsaved edits, and the two overlap. Choose what to keep for each change.")
        sub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sub.textColor = .secondaryLabelColor
        note.textColor = .systemOrange
        cards.orientation = .vertical
        cards.alignment = .leading
        cards.spacing = 18
        cards.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        let doc = FlippedStack()
        cards.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(cards)
        let scroll = NSScrollView()
        scroll.documentView = doc
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        doc.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            cards.topAnchor.constraint(equalTo: doc.topAnchor),
            cards.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            cards.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            cards.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        let postpone = NSButton(title: "Postpone", target: self, action: #selector(postponeClicked))
        postpone.keyEquivalent = "\u{1b}"
        postpone.toolTip = "Keep your edits for now; the merge is offered again on save"
        let apply = NSButton(title: "Apply", target: self, action: #selector(applyClicked))
        apply.keyEquivalent = "\r"
        let bar = NSStackView(views: [note, NSView(), postpone, apply])
        let content = NSView()
        for v in [titleLabel, sub, scroll, bar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
                v.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            ])
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            sub.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            scroll.topAnchor.constraint(equalTo: sub.bottomAnchor, constant: 10),
            bar.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        panel.contentView = content
    }

    func present(in win: NSWindow) {
        let room = win.contentLayoutRect.size
        panel.setContentSize(NSSize(width: max(640, min(1000, room.width - 40)), height: max(420, room.height - 30)))
        win.beginSheet(panel, completionHandler: nil)
    }

    func dismiss() {
        guard !dismissed else { return }
        dismissed = true
        panel.sheetParent?.endSheet(panel)
    }

    func update(_ data: Data) -> Bool {
        guard data != lastData,
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        lastData = data
        let name = ((o["file"] as? String ?? "") as NSString).lastPathComponent
        titleLabel.stringValue = "“\(name)” changed on disk"
        let cs = o["conflicts"] as? [[String: Any]] ?? []
        if cs.count != conflicts.count { conflicts = cs; buildCards() } else { conflicts = cs }
        for (i, c) in conflicts.enumerated() where i < segments.count {
            let choice = c["choice"] as? Int ?? 0
            segments[i].selectedSegment = choice == 0 ? -1 : choice - 1
            editors[i].isHidden = choice != 4
        }
        return true
    }

    private func block(_ title: String, _ lines: [String], tint: NSColor) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        let tv = NSTextField(wrappingLabelWithString: lines.isEmpty ? "(nothing)" : lines.joined(separator: "\n"))
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.isSelectable = true
        tv.wantsLayer = true
        tv.drawsBackground = true
        tv.backgroundColor = tint.withAlphaComponent(0.14)
        let s = NSStackView(views: [label, tv])
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 3
        tv.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true
        return s
    }

    private func context(_ lines: [String]) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: lines.joined(separator: "\n"))
        t.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        t.textColor = .tertiaryLabelColor
        return t
    }

    private func buildCards() {
        for v in cards.arrangedSubviews { cards.removeArrangedSubview(v); v.removeFromSuperview() }
        segments = []; editors = []; editViews = []
        for (i, c) in conflicts.enumerated() {
            let head = NSTextField(labelWithString: "Change \(i + 1) of \(conflicts.count)")
            head.font = .systemFont(ofSize: 12, weight: .semibold)
            let seg = NSSegmentedControl(labels: ["Keep Mine", "Use Disk", "Keep Both", "Edit…"],
                                         trackingMode: .selectOne, target: self, action: #selector(choiceChanged(_:)))
            seg.tag = i
            segments.append(seg)
            let sides = NSStackView(views: [
                block("YOUR EDITS", c["ours"] as? [String] ?? [], tint: .systemBlue),
                block("ON DISK", c["theirs"] as? [String] ?? [], tint: .systemOrange),
            ])
            sides.distribution = .fillEqually
            sides.alignment = .top
            sides.spacing = 12
            let ev = NSTextView()
            ev.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            ev.isRichText = false
            ev.delegate = self
            let edited = c["edited"] as? [String] ?? []
            ev.string = (edited.isEmpty ? (c["ours"] as? [String] ?? []) : edited).joined(separator: "\n")
            let es = NSScrollView()
            es.documentView = ev
            es.hasVerticalScroller = true
            es.borderType = .bezelBorder
            es.heightAnchor.constraint(equalToConstant: 110).isActive = true
            es.isHidden = true
            editors.append(es)
            editViews.append(ev)
            var parts: [NSView] = [NSStackView(views: [head, NSView(), seg])]
            let before = c["before"] as? [String] ?? []
            let after = c["after"] as? [String] ?? []
            if !before.isEmpty { parts.append(context(before)) }
            parts.append(sides)
            parts.append(es)
            if !after.isEmpty { parts.append(context(after)) }
            let card = NSStackView(views: parts)
            card.orientation = .vertical
            card.alignment = .leading
            card.spacing = 6
            for p in parts { p.widthAnchor.constraint(equalTo: card.widthAnchor).isActive = true }
            cards.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: cards.widthAnchor, constant: -16).isActive = true
            if i + 1 < conflicts.count {
                let sep = NSBox()
                sep.boxType = .separator
                cards.addArrangedSubview(sep)
                sep.widthAnchor.constraint(equalTo: cards.widthAnchor, constant: -16).isActive = true
            }
        }
    }

    private func choose(_ i: Int, _ choice: Int) {
        guard let h = view?.handle, h != 0 else { return }
        let lines = choice == 4 ? editViews[i].string.components(separatedBy: "\n") : []
        let json = (try? JSONSerialization.data(withJSONObject: lines))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        withUTF8Arg(json) { p, l in tk_desktop_merge_choose(h, Int64(i), Int64(choice), p, l) }
        note.stringValue = ""
        lastData = Data()
    }

    @objc private func choiceChanged(_ seg: NSSegmentedControl) {
        let i = seg.tag
        let choice = seg.selectedSegment + 1
        editors[i].isHidden = choice != 4
        if choice == 4 { panel.makeFirstResponder(editViews[i]) }
        choose(i, choice)
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView,
              let i = editViews.firstIndex(where: { $0 === tv }) else { return }
        choose(i, 4)
    }

    private func finish(_ apply: Bool) {
        guard let v = view, v.handle != 0 else { return }
        if tk_desktop_merge_finish(v.handle, apply ? 1 : 0, Int64(v.cols()), Int64(v.rows())) == 0 && apply {
            note.stringValue = "Choose what to keep for every change first."
            NSSound.beep()
        }
        lastData = Data()
        onAfterAction?()
    }

    @objc private func applyClicked() { finish(true) }
    @objc private func postponeClicked() { finish(false) }
}


// MARK: - macOS-style UI: review mode
//
// Git ▸ Review. The picker (commits / branches) is a sheet; picking runs the
// core's own start path, including its "check out the branch?" question.
// While reviewing, the body stays the core's grid editor — it is the review
// surface, with phantom diff rows and the git gutter — and `ReviewBar` is
// laid over the toolbar row it reserves: previous / next change, the
// line-weighted progress, the file and change counters, a file menu, Done.

final class ReviewPickerController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private weak var view: CellView?
    private let panel: NSPanel
    private let tabs = NSSegmentedControl(labels: ["Commits", "Branches"], trackingMode: .selectOne,
                                          target: nil, action: nil)
    private let table = GitTable()
    private var labels: [String] = []
    private var dismissed = false

    init(view: CellView) {
        self.view = view
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
                        styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        super.init()
        let title = NSTextField(labelWithString: "Review Changes")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        tabs.target = self
        tabs.action = #selector(tabChanged)
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 26
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(reviewClicked)
        table.onKey = { [weak self] k in
            switch k {
            case "enter": self?.reviewClicked(); return true
            case "esc": self?.cancelClicked(); return true
            default: return false
            }
        }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let review = NSButton(title: "Review", target: self, action: #selector(reviewClicked))
        review.keyEquivalent = "\r"
        let top = NSStackView(views: [title, NSView(), tabs])
        let bar = NSStackView(views: [NSView(), cancel, review])
        let content = NSView()
        for v in [top, scroll, bar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
                v.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            ])
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            bar.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        panel.contentView = content
    }

    func present(in win: NSWindow) {
        win.beginSheet(panel, completionHandler: nil)
        panel.makeFirstResponder(table)
    }

    func dismiss() {
        guard !dismissed else { return }
        dismissed = true
        panel.sheetParent?.endSheet(panel)
    }

    func update(_ o: [String: Any]) {
        tabs.selectedSegment = o["tab"] as? Int ?? 0
        let l = o["labels"] as? [String] ?? []
        if l != labels { labels = l; table.reloadData() }
        let cur = o["cursor"] as? Int ?? 0
        if cur >= 0 && cur < labels.count && table.selectedRow < 0 {
            table.selectRowIndexes(IndexSet(integer: cur), byExtendingSelection: false)
            table.scrollRowToVisible(cur)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { labels.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row i: Int) -> NSView? {
        let text = labels[i]
        // "sha  subject" / "name  subject": the key in monospace, the rest plain.
        let parts = text.components(separatedBy: "  ")
        let s = NSMutableAttributedString(string: parts.first ?? "", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)])
        if parts.count > 1 {
            s.append(NSAttributedString(string: "  " + parts.dropFirst().joined(separator: "  ")
                .trimmingCharacters(in: .whitespaces), attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        let l = NSTextField(labelWithAttributedString: s)
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    private func act(_ op: Int, _ arg: Int) {
        guard let h = view?.handle, h != 0 else { return }
        tk_desktop_review_act(h, Int64(op), Int64(arg))
        view?.invalidateFrame()
        view?.needsDisplay = true
    }

    @objc private func tabChanged() {
        table.deselectAll(nil)
        act(0, tabs.selectedSegment)
    }

    @objc private func reviewClicked() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0 else { return }
        act(1, row)
    }

    @objc private func cancelClicked() { act(2, 0) }
}

final class ReviewBar: NSVisualEffectView {
    private weak var cellView: CellView?
    private let prev = NSButton(title: "Previous Change", target: nil, action: nil)
    private let next = NSButton(title: "Next Change", target: nil, action: nil)
    private let files = NSPopUpButton()
    private let counter = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private var lastData = Data()

    init(view: CellView) {
        cellView = view
        super.init(frame: .zero)
        material = .titlebar
        blendingMode = .withinWindow
        prev.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
        prev.imagePosition = .imageLeading
        next.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        next.imagePosition = .imageTrailing
        for b in [prev, next] {
            b.bezelStyle = .texturedRounded
            b.controlSize = .small
            b.target = self
        }
        prev.action = #selector(prevClicked)
        next.action = #selector(nextClicked)
        prev.toolTip = "Previous change (⇧⌘←)"
        next.toolTip = "Next change (⇧⌘→)"
        files.controlSize = .small
        files.target = self
        files.action = #selector(fileChosen)
        counter.font = .systemFont(ofSize: 11)
        counter.textColor = .secondaryLabelColor
        progress.style = .bar
        progress.isIndeterminate = false
        progress.controlSize = .small
        let done = NSButton(title: "Done Reviewing", target: self, action: #selector(doneClicked))
        done.bezelStyle = .texturedRounded
        done.controlSize = .small
        let stack = NSStackView(views: [prev, progress, counter, files, NSView(), next, done])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            progress.widthAnchor.constraint(equalToConstant: 140),
            files.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
        ])
        files.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        counter.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(_ o: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: o), data != lastData else { return false }
        lastData = data
        if let bar = o["bar"] as? [String: Any] {
            // Two rows the core keeps clear: the toolbar row and the one
            // above it, so real controls fit without covering the editor.
            let f = NSRect(x: 0, y: CGFloat(bar["y"] as? Int ?? 0) * CELL_H,
                           width: CGFloat(bar["w"] as? Int ?? 0) * CELL_W,
                           height: CGFloat(bar["h"] as? Int ?? 1) * CELL_H)
            if frame != f { frame = f }
        }
        let fl = o["files"] as? [[Any]] ?? []
        let titles = fl.map { f -> String in
            let path = f.first as? String ?? ""
            let added = f.count > 1 && (f[1] as? Bool ?? false)
            let deleted = f.count > 2 && (f[2] as? Bool ?? false)
            return path + (added ? "  (new)" : deleted ? "  (deleted)" : "")
        }
        if titles != files.itemTitles {
            files.removeAllItems()
            files.addItems(withTitles: titles)
        }
        let cur = o["cur_file"] as? Int ?? 0
        if cur >= 0 && cur < titles.count { files.selectItem(at: cur) }
        let ci = o["change_index"] as? Int ?? 0, ct = o["change_total"] as? Int ?? 0
        // ``change_index`` is already 1-based (0 = before the first).
        counter.stringValue = "File \(min(cur + 1, fl.count)) of \(fl.count) · change \(min(ci, ct)) of \(ct)"
        let num = o["num"] as? Int ?? 0, den = o["den"] as? Int ?? 0
        progress.maxValue = Double(max(den, 1))
        progress.doubleValue = Double(num)
        return true
    }

    private func act(_ op: Int, _ arg: Int = 0) {
        guard let v = cellView, v.handle != 0 else { return }
        tk_desktop_review_act(v.handle, Int64(op), Int64(arg))
        lastData = Data()
        v.window?.makeFirstResponder(v)
        v.invalidateFrame()
        v.needsDisplay = true
    }

    @objc private func prevClicked() { act(4) }
    @objc private func nextClicked() { act(3) }
    @objc private func doneClicked() { act(2) }
    @objc private func fileChosen() { act(5, files.indexOfSelectedItem) }
}


// MARK: - Settings list sections (Languages, Spelling, Projects)
//
// Tables over `tk_desktop_prefs_lists`, refetched every tick but redrawn only
// on change (a dictionary install finishes asynchronously). Each button is a
// `tk_desktop_prefs_list_act` op that runs the in-grid section's own method.

final class PrefsLists: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private weak var view: CellView?
    private weak var window: NSWindow?
    private var languages: [[Any]] = []
    private var dictionaries: [[Any]] = []
    private var projects: [String] = []
    private var lastData = Data()
    private let langTable = NSTableView()
    private let dictTable = NSTableView()
    private let projTable = NSTableView()
    private let removeOverride = NSButton(title: "Remove Override", target: nil, action: nil)
    private let install = NSButton(title: "Install", target: nil, action: nil)
    private let uninstall = NSButton(title: "Remove", target: nil, action: nil)
    private var buf = [UInt8](repeating: 0, count: 1 << 15)

    init(view: CellView?, window: NSWindow) {
        self.view = view
        self.window = window
        super.init()
    }

    // MARK: data

    func refresh() {
        guard let h = view?.handle, h != 0 else { return }
        var n = 0
        while true {
            n = buf.withUnsafeMutableBufferPointer { b -> Int in
                Int(tk_desktop_prefs_lists(h, Int64(Int(bitPattern: b.baseAddress)), Int64(b.count)))
            }
            if n <= buf.count { break }
            buf = [UInt8](repeating: 0, count: n)
        }
        guard n > 0 else { return }
        let data = Data(buf[0..<n])
        guard data != lastData,
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        lastData = data
        languages = o["languages"] as? [[Any]] ?? []
        dictionaries = o["dictionaries"] as? [[Any]] ?? []
        projects = o["projects"] as? [String] ?? []
        for t in [langTable, dictTable, projTable] {
            let sel = t.selectedRowIndexes
            t.reloadData()
            t.selectRowIndexes(sel, byExtendingSelection: false)
        }
        updateButtons()
    }

    private func act(_ op: Int, _ idx: Int, _ payload: Any = "") {
        guard let h = view?.handle, h != 0 else { return }
        let json = (try? JSONSerialization.data(withJSONObject: payload, options: .fragmentsAllowed))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        withUTF8Arg(json) { p, l in tk_desktop_prefs_list_act(h, Int64(op), Int64(idx), p, l) }
        lastData = Data()
        // The core applies and persists on its next frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.refresh() }
    }

    // MARK: panes

    private func table(_ t: NSTableView, _ cols: [(String, String, CGFloat)]) -> NSScrollView {
        for (id, title, w) in cols {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = w
            t.addTableColumn(c)
        }
        t.usesAlternatingRowBackgroundColors = true
        t.dataSource = self
        t.delegate = self
        let s = NSScrollView()
        s.documentView = t
        s.hasVerticalScroller = true
        s.borderType = .bezelBorder
        return s
    }

    private func pane(_ intro: String, _ scroll: NSScrollView, _ buttons: [NSButton]) -> NSView {
        let note = NSTextField(wrappingLabelWithString: intro)
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 12)
        let bar = NSStackView(views: buttons + [NSView()])
        let v = NSView()
        for x in [note, scroll, bar] as [NSView] {
            x.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(x)
            NSLayoutConstraint.activate([
                x.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
                x.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -16),
            ])
        }
        NSLayoutConstraint.activate([
            note.topAnchor.constraint(equalTo: v.topAnchor, constant: 14),
            scroll.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 8),
            bar.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            bar.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -14),
        ])
        return v
    }

    private func button(_ title: String, _ sel: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: sel)
        return b
    }

    func languagesPane() -> NSView {
        langTable.target = self
        langTable.doubleAction = #selector(editLanguage)
        removeOverride.target = self
        removeOverride.action = #selector(removeLanguage)
        return pane("Which language server runs for which file types. Your changes override the built-in choices.",
                    table(langTable, [("id", "Language", 120), ("types", "File types", 180), ("server", "Server", 300)]),
                    [button("Add…", #selector(addLanguage)), button("Edit…", #selector(editLanguage)), removeOverride])
    }

    func dictionariesPane() -> NSView {
        install.target = self
        install.action = #selector(installDictionary)
        uninstall.target = self
        uninstall.action = #selector(removeDictionary)
        return pane("Extra spell-check dictionaries for other languages, downloaded once.",
                    table(dictTable, [("name", "Dictionary", 360), ("status", "Status", 160)]),
                    [install, uninstall])
    }

    func projectsPane() -> NSView {
        return pane("Folders that hold your projects — their subfolders are offered when you open a project.",
                    table(projTable, [("dir", "Folder", 560)]),
                    [button("Add…", #selector(addProject)), button("Remove", #selector(removeProject))])
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === langTable ? languages.count : tableView === dictTable ? dictionaries.count : projects.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row i: Int) -> NSView? {
        let id = tableColumn?.identifier.rawValue ?? ""
        var text = ""
        var color = NSColor.labelColor
        if tableView === langTable {
            let r = languages[i]
            switch id {
            case "id":
                text = r[0] as? String ?? ""
                if r.count > 3 && (r[3] as? Bool ?? false) { text += "  (yours)" }
            case "types": text = r[1] as? String ?? ""
            default:
                text = ((r[2] as? String ?? "").components(separatedBy: "\n").first ?? "")
                if text.isEmpty { text = "none"; color = .secondaryLabelColor }
            }
        } else if tableView === dictTable {
            let r = dictionaries[i]
            if id == "name" { text = r[0] as? String ?? "" } else {
                let installed = r.count > 1 && (r[1] as? Bool ?? false)
                text = installed ? "Installed" : "Not installed"
                color = installed ? .systemGreen : .secondaryLabelColor
            }
        } else {
            text = projects[i]
        }
        let l = NSTextField(labelWithString: text)
        l.lineBreakMode = .byTruncatingMiddle
        l.textColor = color
        return l
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    private func updateButtons() {
        let lr = langTable.selectedRow
        removeOverride.isEnabled = lr >= 0 && lr < languages.count
            && languages[lr].count > 3 && (languages[lr][3] as? Bool ?? false)
        let dr = dictTable.selectedRow
        let installed = dr >= 0 && dr < dictionaries.count && dictionaries[dr].count > 1
            && (dictionaries[dr][1] as? Bool ?? false)
        install.isEnabled = dr >= 0 && !installed
        uninstall.isEnabled = dr >= 0 && installed
    }

    // MARK: actions

    @objc private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add"
        guard let w = window else { return }
        panel.beginSheetModal(for: w) { [weak self] r in
            guard r == .OK, let url = panel.url else { return }
            self?.act(0, -1, url.path)
        }
    }

    @objc private func removeProject() {
        guard projTable.selectedRow >= 0 else { return }
        act(1, projTable.selectedRow)
    }

    @objc private func installDictionary() {
        guard dictTable.selectedRow >= 0 else { return }
        act(2, dictTable.selectedRow)
    }

    @objc private func removeDictionary() {
        guard dictTable.selectedRow >= 0 else { return }
        act(3, dictTable.selectedRow)
    }

    @objc private func removeLanguage() {
        guard langTable.selectedRow >= 0 else { return }
        act(5, langTable.selectedRow)
    }

    @objc private func addLanguage() { languageSheet(row: nil) }

    @objc private func editLanguage() {
        let r = langTable.clickedRow >= 0 ? langTable.clickedRow : langTable.selectedRow
        guard r >= 0, r < languages.count else { return }
        languageSheet(row: languages[r])
    }

    /// Add / edit a language's routing: its id, the file types, and the
    /// server command lines in priority order (the first one found runs).
    private func languageSheet(row: [Any]?) {
        guard let w = window else { return }
        let alert = NSAlert()
        alert.messageText = row == nil ? "Add Language" : "Edit \(row?[0] as? String ?? "")"
        alert.informativeText = "Server commands are tried top to bottom; the first one installed runs. Leave it empty for no language server."
        let id = NSTextField(string: row?[0] as? String ?? "")
        id.isEditable = row == nil
        id.placeholderString = "e.g. elixir"
        let types = NSTextField(string: row?[1] as? String ?? "")
        types.placeholderString = "e.g. ex exs"
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 340, height: 90))
        let servers = NSTextView(frame: sv.bounds)
        servers.isRichText = false
        servers.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        servers.string = row?[2] as? String ?? ""
        servers.autoresizingMask = [.width]
        sv.documentView = servers
        sv.hasVerticalScroller = true
        sv.borderType = .bezelBorder
        sv.heightAnchor.constraint(equalToConstant: 90).isActive = true
        func label(_ s: String) -> NSTextField { let l = NSTextField(labelWithString: s); l.alignment = .right; return l }
        let grid = NSGridView(views: [[label("Language:"), id], [label("File types:"), types], [label("Servers:"), sv]])
        grid.rowSpacing = 8
        grid.column(at: 1).width = 340
        grid.rowAlignment = .firstBaseline
        grid.layoutSubtreeIfNeeded()
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)
        alert.accessoryView = grid
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = row == nil ? id : types
        alert.beginSheetModal(for: w) { [weak self] r in
            guard r == .alertFirstButtonReturn else { return }
            let lines = servers.string.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            self?.act(4, -1, ["id": id.stringValue.trimmingCharacters(in: .whitespaces),
                              "file_types": types.stringValue, "servers": lines])
        }
    }
}


// MARK: - macOS-style UI: tool-pane headers
//
// One bar over each docked pane's header row: title, the pane's commands
// (Clear / Restart, Continue / Step…, Re-run…) as borderless buttons, and
// minimize / maximize / close. The pane's content stays the core's grid.
// The core paints that row blank with no hit zones and keeps it as the
// resize handle, so this view lets every click that isn't on a button fall
// through to the cell view (`hitTest`).

final class PaneHeader: NSView {
    private weak var cellView: CellView?
    private var kind = 0, idx = 0
    private let title = NSTextField(labelWithString: "")
    private let commands = NSStackView()
    private let minimize = NSButton()
    private let maximize = NSButton()
    private let close = NSButton()
    private var lastData = Data()
    private var focused = false

    init(view: CellView) {
        cellView = view
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        commands.spacing = 2
        for (b, sym, tip, op) in [(minimize, "minus", "Minimize", 2), (maximize, "arrow.up.left.and.arrow.down.right", "Maximize", 3),
                                  (close, "xmark", "Close", 1)] {
            b.image = NSImage(systemSymbolName: sym, accessibilityDescription: tip)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
            b.isBordered = false
            b.toolTip = tip
            b.tag = op
            b.target = self
            b.action = #selector(controlClicked(_:))
            b.contentTintColor = .secondaryLabelColor
        }
        let stack = NSStackView(views: [title, commands, NSView(), minimize, maximize, close])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// Only the buttons are ours; the rest of the row is the core's resize
    /// handle and focus target.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        return v is NSButton ? v : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        if focused {
            NSColor.controlAccentColor.setFill()
            NSRect(x: 0, y: bounds.height - 2, width: bounds.width, height: 2).fill()
        }
    }

    func update(_ p: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: p), data != lastData else { return false }
        lastData = data
        kind = p["kind"] as? Int ?? 0
        idx = p["idx"] as? Int ?? 0
        let f = NSRect(x: CGFloat(p["x"] as? Int ?? 0) * CELL_W, y: CGFloat(p["y"] as? Int ?? 0) * CELL_H,
                       width: CGFloat(p["w"] as? Int ?? 0) * CELL_W, height: CELL_H)
        if frame != f { frame = f }
        focused = p["focused"] as? Bool ?? false
        title.stringValue = p["title"] as? String ?? ""
        title.textColor = focused ? .labelColor : .secondaryLabelColor
        let state = p["state"] as? Int ?? 0
        minimize.image = NSImage(systemSymbolName: state == 1 ? "chevron.up" : "minus",
                                 accessibilityDescription: state == 1 ? "Restore" : "Minimize")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        maximize.image = NSImage(systemSymbolName: state == 2 ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                 accessibilityDescription: state == 2 ? "Restore" : "Maximize")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        close.isHidden = !(p["close"] as? Bool ?? false)
        for v in commands.arrangedSubviews { commands.removeArrangedSubview(v); v.removeFromSuperview() }
        for c in p["commands"] as? [[String]] ?? [] where c.count == 2 {
            let b = NSButton(title: c[0], target: self, action: #selector(commandClicked(_:)))
            b.isBordered = false
            b.font = .systemFont(ofSize: 11)
            b.contentTintColor = .controlAccentColor
            b.identifier = NSUserInterfaceItemIdentifier(c[1])
            commands.addArrangedSubview(b)
        }
        needsDisplay = true
        return true
    }

    private func act(_ op: Int, _ cmd: String = "") {
        guard let v = cellView, v.handle != 0 else { return }
        withUTF8Arg(cmd) { p, l in tk_desktop_pane_act(v.handle, Int64(kind), Int64(idx), Int64(op), p, l) }
        lastData = Data()
        v.window?.makeFirstResponder(v)
        v.invalidateFrame()
        v.needsDisplay = true
    }

    @objc private func controlClicked(_ b: NSButton) { act(b.tag) }
    @objc private func commandClicked(_ b: NSButton) { act(4, b.identifier?.rawValue ?? "") }
}
