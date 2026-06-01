import AppKit
import CoreText

// The bundled IBM VGA bitmap font (8×16), matching the terminal/Rust look.
// Designed at 16px, so 16pt gives an 8pt advance — exactly our cell size.
// Falls back to Menlo if the bundled TTF is missing.
func loadCellFont() -> NSFont {
    if let res = Bundle.main.resourcePath {
        let url = URL(fileURLWithPath: res + "/Px437_IBM_VGA_8x16.ttf")
        if FileManager.default.fileExists(atPath: url.path) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            if let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL)
                as? [CTFontDescriptor], let desc = descs.first {
                return CTFontCreateWithFontDescriptor(desc, 16, nil) as NSFont
            }
        }
    }
    return NSFont(name: "Menlo", size: 13)
        ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
}
let cellFont = loadCellFont()

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
let STYLE_UNDERLINE: UInt32 = 1 << 3
let STYLE_REVERSE: UInt32 = 1 << 4
let STYLE_UNDERLINE_CURLY: UInt32 = 1 << 6

// turbokod key constants (events.mojo private-use codes)
let KEY_ENTER: UInt32 = 0xE001, KEY_TAB: UInt32 = 0xE002, KEY_BACKSPACE: UInt32 = 0xE003
let KEY_ESC: UInt32 = 0xE004
let KEY_UP: UInt32 = 0xE010, KEY_DOWN: UInt32 = 0xE011, KEY_LEFT: UInt32 = 0xE012, KEY_RIGHT: UInt32 = 0xE013
let KEY_HOME: UInt32 = 0xE014, KEY_END: UInt32 = 0xE015, KEY_PAGEUP: UInt32 = 0xE016
let KEY_PAGEDOWN: UInt32 = 0xE017, KEY_INSERT: UInt32 = 0xE018, KEY_DELETE: UInt32 = 0xE019
let KEY_F1: UInt32 = 0xE020

let MOD_SHIFT: UInt8 = 1, MOD_ALT: UInt8 = 2, MOD_CTRL: UInt8 = 4, MOD_META: UInt8 = 8

let CELL_W: CGFloat = 8, CELL_H: CGFloat = 16

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

final class CellView: NSView {
    var handle: Int64 = 0
    var project: String?      // set when a project is opened; drives session save
    private var buf = UnsafeMutablePointer<UInt32>.allocate(capacity: 3)
    private var bufCells = 1
    // Last cell a passive (no-button) mouse move was dispatched for. macOS
    // delivers bare motion at the display refresh rate (60–120 Hz), but the
    // Mojo side works in cell coordinates — every pixel move inside one cell
    // produces identical hover state and pointer shape. Dispatching them is
    // pure waste (two FFI hit-tests per event), so we drop motion that didn't
    // cross a cell boundary. -1 forces the first move through.
    private var lastPassiveCol: Int64 = -1, lastPassiveRow: Int64 = -1
    private let palette = buildPalette()
    private let font = cellFont

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

    private func ensureBuf(_ cells: Int) {
        if cells > bufCells {
            buf.deallocate()
            buf = UnsafeMutablePointer<UInt32>.allocate(capacity: cells * 3)
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
        tk_desktop_tick(handle, Int64(cols()), Int64(rows()))
        return detectChange()
    }

    /// Lay out the current Desktop state and report whether it differs from
    /// what's on screen, caching the buffer for the next `draw` if so. Unlike
    /// `pollFrame` this does *not* run the async tick — callers that already
    /// know why the frame might have changed (a mouse/scroll event) use it to
    /// avoid a full repaint when the event didn't actually change anything.
    @discardableResult
    func detectChange() -> Bool {
        guard handle != 0 else { return false }
        let c = cols(), r = rows()
        ensureBuf(c * r)
        let n = Int(tk_desktop_layout(handle, Int64(c), Int64(r),
                                      Int64(Int(bitPattern: buf)), Int64(c * r)))
        frameCols = c; frameRows = r; frameN = n
        let hash = hashBuf(n * 3)
        if hash == lastFrameHash { return false }
        lastFrameHash = hash
        framePending = true
        return true
    }

    /// Drop the cached frame so the next `draw` re-runs tick + layout. Input
    /// handlers call this because a key/mouse event mutates the Desktop, making
    /// any frame an earlier `pollFrame` left behind stale.
    func invalidateFrame() { framePending = false }

    override func draw(_ dirtyRect: NSRect) {
        guard handle != 0, let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Px437 is a pixel font — render it crisp (no anti-aliasing / font
        // smoothing) or the bitmap glyphs come out blurred. Cells are on
        // integer pixel boundaries so hard-edged rasterization is exact.
        ctx.setShouldAntialias(false)
        ctx.setShouldSmoothFonts(false)
        ctx.setAllowsAntialiasing(false)
        ctx.setAllowsFontSmoothing(false)
        NSGraphicsContext.current?.shouldAntialias = false
        let c = cols(), r = rows()
        ensureBuf(c * r)
        let n: Int
        if framePending && frameCols == c && frameRows == r {
            // The timer's pollFrame just laid this exact frame out — reuse it
            // rather than ticking + laying out a second time.
            n = frameN
        } else {
            tk_desktop_tick(handle, Int64(c), Int64(r))
            n = Int(tk_desktop_layout(handle, Int64(c), Int64(r),
                                      Int64(Int(bitPattern: buf)), Int64(c * r)))
            // Keep the change detector in sync with what we actually present so
            // the next pollFrame compares against this frame.
            frameCols = c; frameRows = r; frameN = n
            lastFrameHash = hashBuf(n * 3)
        }
        framePending = false

        // Clear to default background once.
        ctx.setFillColor(cgcolor(palette[0]))
        ctx.fill(bounds)

        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        for i in 0..<n {
            let cp = buf[i * 3]
            let packed = buf[i * 3 + 1]
            var fg = palette[Int(packed & 0xFF)]
            var bg = palette[Int((packed >> 8) & 0xFF)]
            let style = (packed >> 16) & 0xFF
            if style & STYLE_REVERSE != 0 { swap(&fg, &bg) }
            let col = i % c, row = i / c
            let x = CGFloat(col) * CELL_W, y = CGFloat(row) * CELL_H

            if bg != palette[0] {
                ctx.setFillColor(cgcolor(bg))
                ctx.fill(CGRect(x: x, y: y, width: CELL_W, height: CELL_H))
            }
            if cp != 0x20 && cp != 0, let scalar = Unicode.Scalar(cp) {
                let s = String(scalar) as NSString
                var a = attrs
                a[.foregroundColor] = nscolor(fg)
                s.draw(at: NSPoint(x: x, y: y), withAttributes: a)
            }
            if style & STYLE_UNDERLINE != 0 {
                let uw = buf[i * 3 + 2]
                let uc = uw == 0xFFFFFFFF ? fg : palette[Int(uw & 0xFF)]
                ctx.setFillColor(cgcolor(uc))
                ctx.fill(CGRect(x: x, y: y + CELL_H - 2, width: CELL_W, height: 1))
            }
        }
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
        var key: UInt32 = 0
        if let sp = specialKey(event.keyCode) {
            key = sp
        } else if let ch = event.charactersIgnoringModifiers, let sc = ch.unicodeScalars.first {
            key = sc.value
        }
        if key == 0 { return }
        let action = tk_desktop_key(handle, key, mods(event), Int64(cols()), Int64(rows()))
        handleAction(action)
        invalidateFrame()
        needsDisplay = true
    }

    private func sendMouse(_ e: NSEvent, button: UInt8, pressed: UInt8, motion: UInt8,
                           passive: Bool = false) {
        let p = convert(e.locationInWindow, from: nil)
        let col = Int64(max(0, p.x) / CELL_W), row = Int64(max(0, p.y) / CELL_H)
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
        let action = tk_desktop_mouse(handle, col, row, button, pressed, motion,
                                      mods(e), Int64(cols()), Int64(rows()))
        handleAction(action)
        // Cursor hint.
        let shape = tk_desktop_pointer_shape(handle, col, row, Int64(cols()), Int64(rows()))
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
        sendMouse(e, button: e.scrollingDeltaY > 0 ? 4 : 5, pressed: 1, motion: 0)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for ta in trackingAreas { removeTrackingArea(ta) }
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect], owner: self))
    }

    // AppKit may only invalidate the newly-exposed strip during a live resize,
    // leaving the rest of the view with stale (stretched) content. Force a
    // full redraw on every size change so the Desktop reflows live.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    func handleAction(_ code: Int32) {
        AppController.shared?.handleAction(code, view: self)
    }

    func capturePNG(to path: String) {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return }
        cacheDisplay(in: bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
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

    func applicationDidFinishLaunching(_ note: Notification) {
        AppController.shared = self
        chdirToResourceRoot()
        buildMenu()
        // Initialize the chrome Desktop before any session restore so its
        // menu snapshot is ready to drive NSApp.mainMenu the moment we
        // have zero windows (empty session, or last window closed).
        chromeDesktop = tk_desktop_new()
        if chromeDesktop != 0 {
            tk_desktop_set_host_owns_menu(chromeDesktop, 1)
        }

        let args = CommandLine.arguments
        if args.count > 1 {
            let p = args[1]
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: p, isDirectory: &isDir)
            if isDir.boolValue {
                // CLI ``./run_swift.sh /path/to/project`` — pre-apply the
                // project's remembered frame to newWindow so the window opens
                // at its previous size, not the 1000×640 default.
                persistSession = true
                let v = newWindow(frame: loadProjectFrame(p))
                openProject(v, p)
            } else {
                let v = newWindow()
                openFile(v, p)
            }
        } else if !pendingOpenPaths.isEmpty {
            // Launched by dropping folders/files on the Dock icon (or
            // "Open With"). Open those instead of restoring the previous
            // session — the drop is the explicit intent.
            persistSession = true
            let dropped = pendingOpenPaths
            pendingOpenPaths.removeAll()
            for p in dropped { openDroppedPath(p) }
        } else {
            persistSession = true
            let saved = loadSession()
            // Empty session: leave zero windows. The macOS menu bar stays
            // up (sourced from chromeDesktop) so the user can quit, open
            // a project, or pick a recent project — all of which spawn a
            // new window as needed. No blank-window auto-open.
            for entry in saved {
                // Per-project file wins; ``native_session.txt``'s frame
                // is the legacy fallback for projects that haven't yet
                // written the new file (first launch after upgrade).
                let frame = loadProjectFrame(entry.project) ?? entry.frame
                let v = newWindow(frame: frame)
                openProject(v, entry.project)
            }
        }
        // From here on, drops open immediately rather than buffering.
        // Drain anything that raced in during launch setup.
        didFinishLaunchingDone = true
        let late = pendingOpenPaths
        pendingOpenPaths.removeAll()
        for p in late { openDroppedPath(p) }
        // Drain turbokod:// URLs after session restore so they can route
        // into restored project windows.
        let lateURLs = pendingOpenURLs
        pendingOpenURLs.removeAll()
        for u in lateURLs { openTurbokodURL(u) }

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
            if NSApp.isHidden { return }
            self.tickSeq &+= 1
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
            for v in self.views {
                guard let w = v.window, w.isVisible,
                      w.occlusionState.contains(.visible) else { continue }
                // Only mark for redraw when the laid-out frame actually
                // differs from what's on screen — no cursor blink means an
                // idle frame is identical and needs no Core Text repaint.
                if v.pollFrame() { v.needsDisplay = true; changed = true }
            }
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
            self.refreshMenu()
            for v in self.views { v.invalidateFrame(); v.needsDisplay = true }
        }
        nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                       object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let w = note.object as? NSWindow,
                  w.occlusionState.contains(.visible),
                  let v = w.contentView as? CellView,
                  self.views.contains(v) == true else { return }
            self.idleTicks = 0
            v.invalidateFrame()
            v.needsDisplay = true
        }

        if let cap = ProcessInfo.processInfo.environment["TK_CAPTURE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                // Optional: fire Quick Open via the menu invoke path before
                // capturing, so the captured frame shows the picker dialog.
                if ProcessInfo.processInfo.environment["TK_QUICK_OPEN"] != nil,
                   let v = self.views.first {
                    let action = "file:quick_open"
                    let bytes = Array(action.utf8)
                    _ = bytes.withUnsafeBufferPointer { b in
                        tk_desktop_menu_invoke(v.handle,
                            Int64(Int(bitPattern: b.baseAddress)),
                            Int64(bytes.count),
                            Int64(v.cols()), Int64(v.rows()))
                    }
                    v.needsDisplay = true
                }
                // Optional extra delay so the async indexer has time to
                // produce entries before the capture.
                let extra = ProcessInfo.processInfo.environment["TK_CAPTURE_DELAY"]
                    .flatMap(Double.init) ?? 0.0
                DispatchQueue.main.asyncAfter(deadline: .now() + extra) {
                self.views.first?.capturePNG(to: cap)
                print("captured to \(cap)")
                // TK_QUIT_VIA=close simulates the red-button close on the last
                // window (exercises the session-save-before-remove path).
                // Default: NSApp.terminate (the Cmd+Q path).
                if ProcessInfo.processInfo.environment["TK_QUIT_VIA"] == "close" {
                    self.windows.first?.performClose(nil)
                } else {
                    NSApp.terminate(nil)
                }
                }
            }
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
        appMenu.addItem(withTitle: "About TurboKod", action: nil, keyEquivalent: "")
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
        guard !menuTracking, h != 0 else { return false }
        // The chrome Desktop never gets drawn (its draw cycle is what
        // ticks per-window Desktops via tk_desktop_tick), so its menu
        // visibility flags would otherwise never update — Edit / View
        // would stay visible with no editor. Tick it manually right
        // before snapshotting so the snapshot reflects "no editor
        // focused" state.
        if h == chromeDesktop { tk_desktop_tick(h, 80, 24) }
        // Snapshot into the existing buffer; grow once if it was too small.
        var n = menuBuf.withUnsafeMutableBufferPointer { buf -> Int in
            Int(tk_desktop_menu_snapshot(h,
                Int64(Int(bitPattern: buf.baseAddress)), Int64(buf.count)))
        }
        if n == menuBuf.count {
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
                                               action: nil, keyEquivalent: ""))
                    submenu.addItem(.separator())
                }
                let item = NSMenuItem()
                item.title = title
                item.submenu = submenu
                mainMenu.addItem(item)
                curSubmenu = submenu
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
                                      action: nil, keyEquivalent: ""))
            appSub.addItem(.separator())
            appSub.addItem(NSMenuItem(
                title: "Quit TurboKod",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"))
            let app = NSMenuItem(); app.title = "TurboKod"; app.submenu = appSub
            mainMenu.insertItem(app, at: 0)
        }
        NSApp.mainMenu = mainMenu
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

    @discardableResult
    func newWindow(frame: NSRect? = nil) -> CellView {
        let h = tk_desktop_new()
        // Tell the Desktop the host owns the menu surface — it stops painting
        // the in-grid menu bar and stops routing top-row mouse / Alt-letter
        // mnemonic events to it. We mirror the menu via tk_desktop_menu_snapshot.
        tk_desktop_set_host_owns_menu(h, 1)
        let view = CellView()
        view.handle = h
        let initial = frame ?? NSRect(x: 0, y: 0, width: 1000, height: 640)
        let win = NSWindow(contentRect: initial,
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
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
        // If this project has a remembered window frame, resize/reposition to
        // it. New-window-at-launch paths pre-apply via newWindow(frame:) so
        // there's no visible flash; for Open Project… on an existing window
        // this is the one that resizes mid-session.
        if let saved = loadProjectFrame(path), let win = v.window,
           !NSEqualRects(win.frame, saved) {
            win.setFrame(saved, display: true)
        }
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
        guard let idx = windows.firstIndex(of: sender) else { return false }
        let v = views[idx]
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

    func loadProjectFrame(_ project: String) -> NSRect? {
        let path = nativeWindowPath(project)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let frame = obj["frame"] as? [Any], frame.count == 4
        else { return nil }
        // Accept either integer or floating-point components — JSONSerialization
        // gives NSNumber, which bridges to both Int and Double.
        let nums = frame.compactMap { ($0 as? NSNumber)?.doubleValue }
        guard nums.count == 4, nums[2] > 0, nums[3] > 0 else { return nil }
        return NSRect(x: nums[0], y: nums[1], width: nums[2], height: nums[3])
    }

    func saveProjectFrame(_ project: String, _ frame: NSRect) {
        try? FileManager.default.createDirectory(
            atPath: nativeWindowDir(project), withIntermediateDirectories: true)
        let obj: [String: Any] = ["frame": [
            Int(frame.origin.x), Int(frame.origin.y),
            Int(frame.size.width), Int(frame.size.height),
        ]]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [])
        else { return }
        try? data.write(to: URL(fileURLWithPath: nativeWindowPath(project)), options: .atomic)
    }

    // MARK: live resize/move persistence

    func windowDidResize(_ note: Notification) { scheduleFrameSave(note) }
    func windowDidMove(_ note: Notification)   { scheduleFrameSave(note) }

    // AppKit fires didResize/didMove on every frame of a live drag — debounce
    // to ~150 ms after the last event so we write once per gesture instead of
    // dozens of times. Cancelled-and-rescheduled rather than throttled so the
    // *final* frame is what lands on disk.
    private func scheduleFrameSave(_ note: Notification) {
        guard let win = note.object as? NSWindow,
              let idx = windows.firstIndex(of: win),
              let project = views[idx].project else { return }
        let key = ObjectIdentifier(win)
        frameSaveTimers[key]?.invalidate()
        let frame = win.frame
        let proj  = project
        let t = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            self?.saveProjectFrame(proj, frame)
            self?.frameSaveTimers.removeValue(forKey: key)
        }
        frameSaveTimers[key] = t
    }
}

setvbuf(stdout, nil, _IONBF, 0)   // unbuffered so logs survive a SIGTERM
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let controller = AppController()
app.delegate = controller
app.activate(ignoringOtherApps: true)
app.run()
