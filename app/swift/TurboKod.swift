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
    private let palette = buildPalette()
    private let font = cellFont

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
        tk_desktop_tick(handle, Int64(c), Int64(r))
        let n = Int(tk_desktop_layout(handle, Int64(c), Int64(r),
                                      Int64(Int(bitPattern: buf)), Int64(c * r)))

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
        needsDisplay = true
    }

    private func sendMouse(_ e: NSEvent, button: UInt8, pressed: UInt8, motion: UInt8) {
        let p = convert(e.locationInWindow, from: nil)
        let col = Int64(max(0, p.x) / CELL_W), row = Int64(max(0, p.y) / CELL_H)
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
        needsDisplay = true
    }

    override func mouseDown(with e: NSEvent) { sendMouse(e, button: 1, pressed: 1, motion: 0) }
    override func mouseDragged(with e: NSEvent) { sendMouse(e, button: 1, pressed: 1, motion: 1) }
    override func mouseUp(with e: NSEvent) { sendMouse(e, button: 1, pressed: 0, motion: 0) }
    override func rightMouseDown(with e: NSEvent) { sendMouse(e, button: 3, pressed: 1, motion: 0) }
    override func rightMouseUp(with e: NSEvent) { sendMouse(e, button: 3, pressed: 0, motion: 0) }
    override func mouseMoved(with e: NSEvent) { sendMouse(e, button: 0, pressed: 0, motion: 1) }
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

final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var shared: AppController?
    var windows: [NSWindow] = []
    var views: [CellView] = []
    var timer: Timer?
    var persistSession = false   // off for one-off file opens, on for sessions/projects
    var isTerminating = false    // suppress per-window session saves during quit

    func applicationDidFinishLaunching(_ note: Notification) {
        AppController.shared = self
        chdirToResourceRoot()
        buildMenu()

        let args = CommandLine.arguments
        if args.count > 1 {
            let p = args[1]
            let v = newWindow()
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: p, isDirectory: &isDir)
            if isDir.boolValue { persistSession = true; openProject(v, p) }
            else { openFile(v, p) }
        } else {
            persistSession = true
            let saved = loadSession()
            if saved.isEmpty {
                _ = newWindow()
            } else {
                for entry in saved {
                    let v = newWindow(frame: entry.frame)
                    openProject(v, entry.project)
                }
            }
        }

        // Schedule in .common mode (not just default) so the timer also fires
        // during the modal event-tracking run loop AppKit uses for live
        // resize, window dragging, menus, etc. Without this the cursor blink
        // and any background redraws freeze during those operations.
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            for v in self?.views ?? [] { v.needsDisplay = true }
        }
        RunLoop.current.add(t, forMode: .common)
        timer = t

        if let cap = ProcessInfo.processInfo.environment["TK_CAPTURE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                self.views.first?.capturePNG(to: cap)
                print("captured to \(cap)")
                // TK_QUIT_VIA=close simulates the red-button close on the last
                // window (triggers applicationShouldTerminateAfterLastWindowClosed
                // → cascade), exercising the session-save-before-remove path.
                // Default: NSApp.terminate (the Cmd+Q path).
                if ProcessInfo.processInfo.environment["TK_QUIT_VIA"] == "close" {
                    self.windows.first?.performClose(nil)
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    // MARK: native menu

    func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem(); mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About TurboKod", action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit TurboKod",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem(); mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        let nw = fileMenu.addItem(withTitle: "New Window",
                                  action: #selector(newWindowAction), keyEquivalent: "n")
        nw.target = self
        let op = fileMenu.addItem(withTitle: "Open…",
                                  action: #selector(openAction), keyEquivalent: "o")
        op.target = self
        let opp = fileMenu.addItem(withTitle: "Open Project…",
                                   action: #selector(openProjectAction), keyEquivalent: "O")
        opp.keyEquivalentModifierMask = [.command, .shift]
        opp.target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window",
                         action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu

        let winItem = NSMenuItem(); mainMenu.addItem(winItem)
        let winMenu = NSMenu(title: "Window")
        winMenu.addItem(withTitle: "Minimize",
                        action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = winMenu
        NSApp.windowsMenu = winMenu

        NSApp.mainMenu = mainMenu
    }

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
    @objc func openAction() { if let v = keyView() { openFilePanel(v) } }
    @objc func openProjectAction() { if let v = keyView() { openProjectPanel(v) } }

    // MARK: action codes from Mojo (in-grid menu / Ctrl shortcuts)

    func handleAction(_ code: Int32, view: CellView) {
        switch code {
        case 1: closeWindow(view)            // APP_QUIT_ACTION (Ctrl+Q / in-grid Quit)
        case 2, 3: openFilePanel(view)       // Open… / Quick open…
        case 4: openProjectPanel(view)       // Open project…
        case 5: _ = newWindow()              // in-grid File ▸ New window
        default: break
        }
    }

    // MARK: windows + desktops

    @discardableResult
    func newWindow(frame: NSRect? = nil) -> CellView {
        let h = tk_desktop_new()
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
        v.needsDisplay = true
    }

    func openProject(_ v: CellView, _ path: String) {
        let bytes = Array(path.utf8)
        bytes.withUnsafeBufferPointer { b in
            tk_desktop_open_project(v.handle, Int64(Int(bitPattern: b.baseAddress)),
                                    Int64(bytes.count))
        }
        v.project = path
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
            openProject(v, url.path)
        }
    }

    func closeWindow(_ view: CellView) {
        if let idx = views.firstIndex(where: { $0 === view }) {
            windows[idx].close()   // triggers windowWillClose → cleanup
        }
    }

    func windowWillClose(_ note: Notification) {
        guard let win = note.object as? NSWindow,
              let idx = windows.firstIndex(of: win) else { return }
        // Closing the *last* window auto-terminates the app (see
        // applicationShouldTerminateAfterLastWindowClosed). If we removed
        // this window first and *then* called saveSession, the file would
        // be written empty — wiping the saved session. Snapshot now, with
        // this window still in the lists, and set isTerminating so the
        // follow-up applicationShouldTerminate doesn't re-save (empty).
        let isLast = views.count == 1
        if isLast && !isTerminating {
            isTerminating = true
            saveSession()
        }
        let v = views[idx]
        let h = v.handle
        v.handle = 0
        windows.remove(at: idx)
        views.remove(at: idx)
        tk_desktop_free(h)
        // During quit (Cmd+Q cascade), windows close one by one; skip saving
        // so they don't rewrite the session with an emptying list. A user
        // closing a single non-last window *does* update it.
        if !isTerminating { saveSession() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ s: NSApplication) -> NSApplication.TerminateReply {
        // Snapshot the open windows + projects before the close cascade. If
        // windowWillClose-on-last-window already saved, skip — saving again
        // here would happen *after* its remove and clobber the file empty.
        if !isTerminating {
            saveSession()
            isTerminating = true
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
}

setvbuf(stdout, nil, _IONBF, 0)   // unbuffered so logs survive a SIGTERM
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let controller = AppController()
app.delegate = controller
app.activate(ignoringOtherApps: true)
app.run()
