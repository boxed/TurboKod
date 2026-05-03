use std::borrow::Cow;
use std::collections::HashMap;
use std::io::{Read, Write};
use std::num::NonZeroU32;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::thread;

use alacritty_terminal::event::{Event as TermEvent, EventListener, Notify, WindowSize};
use alacritty_terminal::event_loop::{EventLoop as PtyEventLoop, Msg, Notifier};
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::index::{Column, Line};
use alacritty_terminal::sync::FairMutex;
use alacritty_terminal::term::cell::Flags;
use alacritty_terminal::term::test::TermSize;
use alacritty_terminal::term::{Config as TermConfig, Term, TermMode};
use alacritty_terminal::tty::{self, Options as PtyOptions, Shell};
use alacritty_terminal::vte::ansi::{Color, NamedColor, Rgb};

use fontdue::{Font, FontSettings};

use winit::application::ApplicationHandler;
use winit::dpi::{PhysicalPosition, PhysicalSize};
use winit::event::{ElementState, KeyEvent, MouseButton, MouseScrollDelta, WindowEvent};
use winit::event_loop::{ActiveEventLoop, ControlFlow, EventLoop as WinitEventLoop, EventLoopProxy};
use winit::keyboard::{Key, ModifiersState, NamedKey};
use winit::window::{CursorIcon, Window, WindowAttributes, WindowId};

mod settings;
use settings::{monitor_fingerprint, Settings, WindowState};

#[cfg(target_os = "macos")]
mod macos_url_scheme;

#[cfg(target_os = "macos")]
mod macos_key_monitor;

const INIT_COLS: u32 = 80;
const INIT_ROWS: u32 = 25;
const MIN_COLS: u32 = 20;
const MIN_ROWS: u32 = 5;
// Px437_IBM_VGA_8x16.ttf is a pixel-perfect recreation of the IBM VGA ROM
// font with an 8 wide × 16 tall cell.
const CELL_W_BASE: u32 = 8;
const CELL_H_BASE: u32 = 16;
const RASTER_PX: f32 = 16.0;

const DEFAULT_SCALE: u32 = 1;
const MIN_SCALE: u32 = 1;
const MAX_SCALE: u32 = 8;

const PX437: &[u8] = include_bytes!("../assets/Px437_IBM_VGA_8x16.ttf");

// Px437 covers CP437 + a fair chunk of Unicode but no CJK/emoji/symbols
// outside the bitmap font's design scope. For anything it lacks, fall
// through to a system monospace and rasterize at FALLBACK_PX so the
// glyph fits in the 8×16 cell. Empirically 13 px puts Menlo/Monaco
// glyphs at ~7-8 px advance, which is the sweet spot.
const FALLBACK_PX: f32 = 13.0;
// Order matters: first hit wins. Menlo is the macOS default monospace
// and ships TTC, so we open it via fontdue's collection_index. The
// Monaco entry is a single TTF — easier to load — kept as a runner-up.
const FALLBACK_FONTS: &[(&str, u32)] = &[
    ("/System/Library/Fonts/Menlo.ttc", 0),
    ("/System/Library/Fonts/Monaco.ttf", 0),
    ("/System/Library/Fonts/Supplemental/Arial Unicode.ttf", 0),
];

const DEFAULT_FG: u32 = 0xC0_C0_C0;
const DEFAULT_BG: u32 = 0x00_00_00;
const DEFAULT_CURSOR: u32 = 0xFF_FF_FF;

// VGA-ish 16, plus xterm 6×6×6 cube, plus xterm 24-step grayscale ramp.
fn build_palette() -> [u32; 256] {
    let base16: [u32; 16] = [
        0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0021AA, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
        0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF,
    ];
    let cube: [u8; 6] = [0, 95, 135, 175, 215, 255];
    let mut p = [0u32; 256];
    p[..16].copy_from_slice(&base16);
    let mut i = 16;
    for r in 0..6 {
        for g in 0..6 {
            for b in 0..6 {
                p[i] = ((cube[r] as u32) << 16) | ((cube[g] as u32) << 8) | cube[b] as u32;
                i += 1;
            }
        }
    }
    for k in 0..24 {
        let v = 8 + 10 * k as u32;
        p[232 + k] = (v << 16) | (v << 8) | v;
    }
    p
}

fn resolve_color(c: Color, palette: &[u32; 256], bold: bool, default: u32) -> u32 {
    match c {
        Color::Spec(rgb) => ((rgb.r as u32) << 16) | ((rgb.g as u32) << 8) | rgb.b as u32,
        Color::Indexed(i) => palette[i as usize],
        Color::Named(n) => match n {
            NamedColor::Foreground | NamedColor::BrightForeground | NamedColor::DimForeground => DEFAULT_FG,
            NamedColor::Background => DEFAULT_BG,
            NamedColor::Cursor => DEFAULT_CURSOR,
            other => {
                let idx = if bold { other.to_bright() } else { other } as usize;
                if idx < 16 { palette[idx] } else { default }
            }
        },
    }
}

#[inline]
fn blend(fg: u32, bg: u32, cov: u32) -> u32 {
    if cov == 0 { return bg; }
    if cov == 255 { return fg; }
    let inv = 255 - cov;
    let fr = (fg >> 16) & 0xFF;
    let fg_ = (fg >> 8) & 0xFF;
    let fb = fg & 0xFF;
    let br = (bg >> 16) & 0xFF;
    let bg_ = (bg >> 8) & 0xFF;
    let bb = bg & 0xFF;
    let r = (fr * cov + br * inv) / 255;
    let g = (fg_ * cov + bg_ * inv) / 255;
    let b = (fb * cov + bb * inv) / 255;
    (r << 16) | (g << 8) | b
}

#[derive(Debug, Clone)]
enum UserEvent {
    Term(TermEvent),
    // Args delivered from a second invocation via the single-instance
    // Unix socket. Each entry is an absolute path the running primary
    // should open (file → editor window, dir → project root).
    OpenPaths(Vec<String>),
}

#[derive(Clone)]
struct EventProxy(EventLoopProxy<UserEvent>);

impl EventListener for EventProxy {
    fn send_event(&self, event: TermEvent) {
        let _ = self.0.send_event(UserEvent::Term(event));
    }
}

// ----------------------------------------------------------------------------
// Single-instance: behave like a macOS .app — running ``turbokod`` from the
// command line a second time forwards its argv to the already-running window
// instead of spawning a duplicate process. The wiring is a Unix domain
// socket at a per-user path; the primary listens, secondaries connect and
// send a length-prefixed JSON array of absolute paths and exit.
//
// Path resolution happens in the *secondary* (where ``cwd`` is meaningful) so
// a relative ``turbokod foo.txt`` from a different working directory still
// opens the right file. Length prefix is u32 BE; a 64 KiB cap rejects junk.
// ----------------------------------------------------------------------------

fn socket_path() -> PathBuf {
    let user = std::env::var("USER").unwrap_or_else(|_| "default".into());
    PathBuf::from(format!("/tmp/turbokod-{}.sock", user))
}

// Bundle layout discovery. When the rust binary lives at
// ``turbokod.app/Contents/MacOS/turbokod-app``, the build script also
// drops a ``turbokod-desktop`` next to it (the mojo backend) and a
// ``Resources/launch.env`` recording the project root + pixi env. We
// pick those up at startup so a URL-cold-launched .app can spawn the
// mojo backend instead of ``$SHELL``, which is what makes the
// ``__mvc_open:`` OSC actually open files.

#[derive(Default)]
struct BundleLaunchInfo {
    /// Path to the mojo backend living next to the rust binary. ``None``
    /// when the rust binary is being run outside a bundle (cargo run, etc.).
    mojo_program: Option<PathBuf>,
    /// CWD to set before spawning the mojo backend so its relative
    /// ``src/turbokod/grammars/`` paths still resolve.
    project_root: Option<PathBuf>,
    /// Final ``DYLD_FALLBACK_LIBRARY_PATH`` to merge into the spawned
    /// mojo backend's env. Built from ``<exe_dir>/../Frameworks`` (the
    /// bundled libonig) plus any ``EXTRA_DYLD_FALLBACK`` listed in
    /// ``launch.env`` (typically the pixi env's ``lib/`` for dev runs).
    dyld_fallback: Option<String>,
}

fn discover_bundle_launch_info() -> BundleLaunchInfo {
    let mut info = BundleLaunchInfo::default();
    let exe = match std::env::current_exe() {
        Ok(p) => p,
        Err(_) => return info,
    };
    let exe_dir = match exe.parent() {
        Some(p) => p.to_path_buf(),
        None => return info,
    };
    let candidate = exe_dir.join("turbokod-desktop");
    if candidate.is_file() {
        info.mojo_program = Some(candidate);
    }
    // ``Contents/MacOS/`` is the binary dir; ``Contents/`` is its parent.
    let contents = exe_dir.parent().map(|c| c.to_path_buf());
    let resources = contents.as_ref().map(|c| c.join("Resources"));
    let frameworks = contents.as_ref().map(|c| c.join("Frameworks"));
    let mut extra_fallback: Option<String> = None;
    if let Some(rdir) = &resources {
        let env_path = rdir.join("launch.env");
        if let Ok(text) = std::fs::read_to_string(&env_path) {
            for line in text.lines() {
                let line = line.trim();
                if line.is_empty() || line.starts_with('#') {
                    continue;
                }
                let (k, v) = match line.split_once('=') {
                    Some(p) => p,
                    None => continue,
                };
                match k {
                    "PROJECT_ROOT" => info.project_root = Some(PathBuf::from(v)),
                    "EXTRA_DYLD_FALLBACK" => extra_fallback = Some(v.to_string()),
                    _ => {}
                }
            }
        }
    }
    if info.mojo_program.is_some() {
        let mut parts: Vec<String> = Vec::new();
        if let Some(fw) = &frameworks {
            if fw.is_dir() {
                parts.push(fw.to_string_lossy().into_owned());
            }
        }
        if let Some(extra) = extra_fallback {
            if !extra.is_empty() {
                parts.push(extra);
            }
        }
        if !parts.is_empty() {
            info.dyld_fallback = Some(parts.join(":"));
        }
    }
    info
}

// ``turbokod://open?file=<path>&line=<n>`` — handler for the project's
// URL scheme. The single supported command for now is ``open``; ``file``
// (or its alias ``path``) is the target, ``line`` is an optional 1-based
// jump-to-line. Anything else is rejected — we don't want to silently
// swallow URLs whose effect we haven't defined yet.
fn parse_turbokod_url(s: &str) -> Option<(String, Option<u32>)> {
    let rest = s.strip_prefix("turbokod://")?;
    let (host_path, query) = match rest.split_once('?') {
        Some((h, q)) => (h, q),
        None => (rest, ""),
    };
    let cmd = host_path.trim_end_matches('/');
    if cmd != "open" {
        return None;
    }
    let mut file: Option<String> = None;
    let mut line: Option<u32> = None;
    for kv in query.split('&') {
        if kv.is_empty() {
            continue;
        }
        let (k, v) = match kv.split_once('=') {
            Some(p) => p,
            None => continue,
        };
        let decoded = percent_decode(v);
        match k {
            "file" | "path" => file = Some(decoded),
            "line" => line = decoded.parse::<u32>().ok(),
            _ => {}
        }
    }
    file.map(|f| (f, line))
}

pub(crate) fn percent_decode(s: &str) -> String {
    // URL-form decoding for the query value: ``%xx`` → byte and
    // ``+`` → space. Falls back to a lossy UTF-8 conversion at the
    // end so an invalid sequence produces a printable Replacement
    // Character rather than panicking the URL parse.
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Some(h), Some(l)) = (hex_digit(bytes[i + 1]), hex_digit(bytes[i + 2])) {
                out.push((h << 4) | l);
                i += 3;
                continue;
            }
        }
        out.push(if bytes[i] == b'+' { b' ' } else { bytes[i] });
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn hex_digit(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

// Translate one CLI / forwarded argument into the wire format the Mojo
// layer accepts: a plain absolute path for the no-line case, or
// ``<abspath>\x1f<line>`` when a jump-to-line was requested. The
// ``\x1f`` (Unit Separator) byte is a valid OSC body byte and is
// guaranteed not to appear in a real path, so the receiver can split
// unambiguously. Returns ``None`` for ``turbokod://`` URLs whose
// command isn't ``open`` — caller drops them.
fn translate_open_arg(arg: &str, cwd: &Path) -> Option<String> {
    if let Some((file, line)) = parse_turbokod_url(arg) {
        let p = Path::new(&file);
        let abs = if p.is_absolute() {
            file
        } else {
            cwd.join(p).to_string_lossy().into_owned()
        };
        Some(match line {
            Some(n) => format!("{}\x1f{}", abs, n),
            None => abs,
        })
    } else if arg.starts_with("turbokod://") {
        // Recognised scheme, unsupported command — drop rather than
        // silently treat the URL string as a path.
        None
    } else {
        let p = Path::new(arg);
        Some(if p.is_absolute() {
            arg.to_string()
        } else {
            cwd.join(p).to_string_lossy().into_owned()
        })
    }
}

fn resolve_args(args: &[String]) -> Vec<String> {
    let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("/"));
    args.iter()
        .filter_map(|a| translate_open_arg(a, &cwd))
        .collect()
}

fn write_payload(s: &mut UnixStream, payload: &[u8]) -> std::io::Result<()> {
    let len = (payload.len() as u32).to_be_bytes();
    s.write_all(&len)?;
    s.write_all(payload)?;
    s.flush()
}

// Cleans up the socket file when the primary exits. On hard crash the file
// is left behind, but ``ensure_single_instance`` self-heals: a stale socket
// produces ``ConnectionRefused`` on connect, which we treat as "no primary,
// remove the file and bind fresh."
struct SingleInstanceGuard {
    path: PathBuf,
}

impl Drop for SingleInstanceGuard {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

enum InstanceRole {
    /// We bound the socket — caller is the primary; spawn the listener
    /// thread, run the full UI.
    Primary(SingleInstanceGuard),
    /// Another primary exists. We forwarded ``cli_args`` (if any), but
    /// LaunchServices may still deliver a URL Apple Event to *this*
    /// process (it launched us by bundle ID and won't know about the
    /// dev primary's socket). Caller runs ``BridgeApp`` to wait briefly
    /// for the AE to fire, then forwards the URL via the same socket
    /// and exits.
    Secondary,
}

fn ensure_single_instance(
    args: &[String],
    proxy: EventLoopProxy<UserEvent>,
) -> InstanceRole {
    let path = socket_path();
    match UnixStream::connect(&path) {
        Ok(mut s) => {
            // Existing primary — forward absolute argv (which may be
            // empty for a URL-cold-launched .app, that's fine; the AE
            // handler will follow up with a URL forward of its own).
            let resolved = resolve_args(args);
            let payload = serde_json::to_vec(&resolved).expect("serialize argv");
            let _ = write_payload(&mut s, &payload);
            return InstanceRole::Secondary;
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(_) => {
            // Stale socket file or other error — remove and try to bind.
            // ``ConnectionRefused`` is the common case when the previous
            // primary crashed without unlinking. Permission/etc. errors
            // also fall through; if bind fails below the error surfaces.
            let _ = std::fs::remove_file(&path);
        }
    }
    let listener = UnixListener::bind(&path).expect("bind single-instance socket");
    let serve_proxy = proxy.clone();
    thread::spawn(move || serve_listener(listener, serve_proxy));
    InstanceRole::Primary(SingleInstanceGuard { path })
}

/// Forward an ``OpenPaths`` payload to the running primary via the
/// single-instance socket. Returns ``true`` if the bytes were handed
/// off (no guarantee the primary actually opened the file — that's
/// the primary's job once it sees the OSC). Used both by the cli-args
/// forward path and by the URL-AE bridge.
fn forward_open_paths(paths: &[String]) -> bool {
    let path = socket_path();
    let mut s = match UnixStream::connect(&path) {
        Ok(s) => s,
        Err(_) => return false,
    };
    let payload = match serde_json::to_vec(&paths.to_vec()) {
        Ok(p) => p,
        Err(_) => return false,
    };
    write_payload(&mut s, &payload).is_ok()
}

/// winit ``ApplicationHandler`` for secondary processes that exist
/// only to forward incoming URL Apple Events to the primary. We give
/// LaunchServices ~1.5 s to deliver any pending ``GURL`` AE — long
/// enough for cold launches where the OS is still settling, short
/// enough that a stray double-launch doesn't leave a phantom .app
/// process around.
struct BridgeApp {
    deadline: std::time::Instant,
}

impl BridgeApp {
    fn new() -> Self {
        Self {
            deadline: std::time::Instant::now() + std::time::Duration::from_millis(1500),
        }
    }
}

impl ApplicationHandler<UserEvent> for BridgeApp {
    fn resumed(&mut self, el: &ActiveEventLoop) {
        // Park on a wait until the AE either fires or we time out.
        // No window, no PTY — bridge processes are invisible to the
        // user except for a brief dock bounce on cold-launch.
        el.set_control_flow(ControlFlow::WaitUntil(self.deadline));
    }
    fn user_event(&mut self, el: &ActiveEventLoop, ev: UserEvent) {
        if let UserEvent::OpenPaths(paths) = ev {
            // Forward the URL on to the primary. The handler in
            // ``main.rs`` for the primary's ``OpenPaths`` event then
            // emits the ``__mvc_open:`` OSC into its PTY child.
            forward_open_paths(&paths);
            el.exit();
        }
    }
    fn about_to_wait(&mut self, el: &ActiveEventLoop) {
        if std::time::Instant::now() >= self.deadline {
            el.exit();
        }
    }
    fn window_event(
        &mut self,
        _: &ActiveEventLoop,
        _: WindowId,
        _: WindowEvent,
    ) {
    }
}

fn serve_listener(listener: UnixListener, proxy: EventLoopProxy<UserEvent>) {
    for incoming in listener.incoming() {
        let Ok(mut s) = incoming else { continue };
        // Bound the read so a hung peer can't wedge the listener thread.
        let _ = s.set_read_timeout(Some(std::time::Duration::from_millis(500)));
        let mut len_buf = [0u8; 4];
        if s.read_exact(&mut len_buf).is_err() {
            continue;
        }
        let len = u32::from_be_bytes(len_buf) as usize;
        // 64 KiB is plenty for an argv list; reject anything larger so a
        // bogus peer can't make us allocate arbitrary memory.
        if len > 64 * 1024 {
            continue;
        }
        let mut buf = vec![0u8; len];
        if s.read_exact(&mut buf).is_err() {
            continue;
        }
        let Ok(args) = serde_json::from_slice::<Vec<String>>(&buf) else {
            continue;
        };
        let _ = proxy.send_event(UserEvent::OpenPaths(args));
    }
}

// Coverage glyphs use a single byte per pixel and get blended against
// the cell's fg/bg colors at paint time. Color glyphs (currently emoji
// only) carry premultiplied ARGB so the original colors come through —
// otherwise a yellow smiley face over a blue cell would render as a
// blue-tinted silhouette.
enum AtlasGlyph {
    Coverage(Vec<u8>),
    Color(Vec<u32>),
}

struct Atlas {
    primary: Font,
    primary_baseline: i32,
    fallback: Option<Font>,
    fallback_baseline: i32,
    glyphs: HashMap<char, AtlasGlyph>,
    scale: u32,
}

impl Atlas {
    fn new(scale: u32) -> Self {
        let primary = Font::from_bytes(PX437, FontSettings::default()).unwrap();
        let primary_baseline = primary.horizontal_line_metrics(RASTER_PX).unwrap().ascent.round() as i32;
        let (fallback, fallback_baseline) = load_fallback_font();
        Self {
            primary,
            primary_baseline,
            fallback,
            fallback_baseline,
            glyphs: HashMap::new(),
            scale,
        }
    }

    // Lazy: rasterize on first encounter and cache. For characters Px437
    // doesn't carry, drop to fontdue's system-monospace fallback; if
    // that also lacks the glyph (emoji, Thai, CJK radicals, ...), fall
    // through to Core Text on macOS so the OS's own font-fallback chain
    // produces *something*.
    fn glyph(&mut self, ch: char) -> &AtlasGlyph {
        let scale = self.scale;
        let primary = &self.primary;
        let primary_baseline = self.primary_baseline;
        let fallback = self.fallback.as_ref();
        let fallback_baseline = self.fallback_baseline;
        self.glyphs.entry(ch).or_insert_with(|| {
            if primary.has_glyph(ch) {
                AtlasGlyph::Coverage(rasterize(primary, ch, scale, primary_baseline, RASTER_PX, false))
            } else if fallback.map_or(false, |f| f.has_glyph(ch)) {
                AtlasGlyph::Coverage(rasterize(fallback.unwrap(), ch, scale, fallback_baseline, FALLBACK_PX, true))
            } else if let Some(g) = os_fallback_rasterize(ch, scale) {
                g
            } else {
                AtlasGlyph::Coverage(vec![0u8; (CELL_W_BASE * scale * CELL_H_BASE * scale) as usize])
            }
        })
    }
}

fn load_fallback_font() -> (Option<Font>, i32) {
    for (path, idx) in FALLBACK_FONTS {
        let bytes = match std::fs::read(path) {
            Ok(b) => b,
            Err(_) => continue,
        };
        let mut settings = FontSettings::default();
        settings.collection_index = *idx;
        let Ok(font) = Font::from_bytes(bytes, settings) else { continue };
        let Some(metrics) = font.horizontal_line_metrics(FALLBACK_PX) else { continue };
        return (Some(font), metrics.ascent.round() as i32);
    }
    (None, 0)
}

#[cfg(not(target_os = "macos"))]
fn os_fallback_rasterize(_ch: char, _scale: u32) -> Option<AtlasGlyph> {
    None
}

// macOS Core Text fallback: hand the OS a one-character string and ask
// it to substitute whatever font can actually render the codepoint
// (Apple Color Emoji for emoji, PingFang for CJK, Thonburi for Thai,
// Apple Symbols for math, …), then draw into a grayscale bitmap that
// the atlas treats like any other rasterized glyph.
//
// We render at the cell's scaled height as the font size, because
// CTLine has no per-glyph downscale step — picking a too-small font
// makes every fallback glyph visually tiny next to the Px437 ones,
// while picking the cell height puts most glyphs at roughly the same
// visual weight as the IBM bitmap font.
#[cfg(target_os = "macos")]
fn os_fallback_rasterize(ch: char, scale: u32) -> Option<AtlasGlyph> {
    use core_foundation::attributed_string::CFMutableAttributedString;
    use core_foundation::base::{CFRange, TCFType};
    use core_foundation::string::{CFString, CFStringRef};
    use core_graphics::base::{kCGImageAlphaPremultipliedLast, kCGBitmapByteOrderDefault};
    use core_graphics::color_space::CGColorSpace;
    use core_graphics::context::CGContext;
    use core_text::font::{
        kCTFontSystemFontType, new_ui_font_for_language, CTFont, CTFontRef,
    };
    use core_text::line::CTLine;
    use core_text::string_attributes;

    let cell_w = (CELL_W_BASE * scale) as usize;
    let cell_h = (CELL_H_BASE * scale) as usize;

    let s = CFString::new(&ch.to_string());
    // Default pt-size is the cell's pixel height — that puts text glyphs
    // at the same perceptual weight as the IBM bitmap font.
    let mut pt_size = (CELL_H_BASE * scale) as f64;
    // The proportional system UI font ships with the OS's full cascade
    // list attached — Thai, CJK, math, emoji. CTLine substitutes the
    // right family during layout.
    let base_font = new_ui_font_for_language(kCTFontSystemFontType, pt_size, None);

    // Resolve which family Core Text would actually use for this codepoint
    // so we can shrink emoji to fit. Color-emoji glyphs have square
    // aspect ratios; rendering a 16x16 emoji into an 8-wide cell at the
    // default pt-size produces an unrecognizable solid block of alpha.
    extern "C" {
        fn CTFontCreateForString(
            f: CTFontRef, s: CFStringRef, r: CFRange,
        ) -> CTFontRef;
    }
    let full = CFRange::init(0, s.char_len());
    let resolved = unsafe {
        let raw = CTFontCreateForString(
            base_font.as_concrete_TypeRef(), s.as_concrete_TypeRef(), full,
        );
        if raw.is_null() {
            return None;
        }
        CTFont::wrap_under_create_rule(raw)
    };
    let family = resolved.family_name();
    let is_emoji = family.contains("Emoji");
    if is_emoji {
        // Emoji are designed at 1:1 aspect; sized to fit the cell's
        // *width* they produce a recognizable thumbnail in our 1:2 cell.
        pt_size = (CELL_W_BASE * scale) as f64;
    }
    let render_font = resolved.clone_with_font_size(pt_size);

    // RGBA premultiplied is the standard Core Graphics format that
    // CTLine and SBIX color emoji actually render into. The alpha
    // channel after drawing is our coverage map; for color emoji it's
    // the silhouette of the bitmap glyph.
    let cs = CGColorSpace::create_device_rgb();
    let bytes_per_row = cell_w * 4;
    let bitmap_info = kCGImageAlphaPremultipliedLast | kCGBitmapByteOrderDefault;
    let mut ctx = CGContext::create_bitmap_context(
        None, cell_w, cell_h, 8, bytes_per_row, &cs, bitmap_info,
    );
    ctx.set_rgb_fill_color(1.0, 1.0, 1.0, 1.0);
    ctx.set_should_antialias(true);
    ctx.set_should_smooth_fonts(true);

    let mut attr = CFMutableAttributedString::new();
    attr.replace_str(&s, CFRange::init(0, 0));
    unsafe {
        attr.set_attribute(full, string_attributes::kCTFontAttributeName, &render_font);
    }
    let line = CTLine::new_with_attributed_string(attr.as_concrete_TypeRef());

    // Centre the glyph's image bbox in the cell.
    let bbox = line.get_image_bounds(&ctx);
    let dx = ((cell_w as f64 - bbox.size.width) / 2.0) - bbox.origin.x;
    let dy = ((cell_h as f64 - bbox.size.height) / 2.0) - bbox.origin.y;
    ctx.set_text_position(dx, dy);
    line.draw(&ctx);

    let bpr = ctx.bytes_per_row();
    let data = ctx.data();
    if is_emoji {
        // Color glyph: keep RGBA so the renderer can alpha-composite the
        // actual emoji pixels over the cell background. We store packed
        // ARGB (alpha in the high byte) for parity with the wrapper's
        // existing pixel format.
        let mut out = vec![0u32; cell_w * cell_h];
        let mut nonzero = false;
        for y in 0..cell_h {
            let src_start = y * bpr;
            for x in 0..cell_w {
                let off = src_start + x * 4;
                let r = data[off] as u32;
                let g = data[off + 1] as u32;
                let b = data[off + 2] as u32;
                let a = data[off + 3] as u32;
                if a != 0 {
                    nonzero = true;
                }
                out[y * cell_w + x] = (a << 24) | (r << 16) | (g << 8) | b;
            }
        }
        if nonzero {
            Some(AtlasGlyph::Color(out))
        } else {
            None
        }
    } else {
        // Mono glyph: collapse RGBA to coverage by reading the alpha
        // channel — for white-on-clear text that's the only useful info,
        // and the renderer already knows how to colorize coverage maps.
        let mut out = vec![0u8; cell_w * cell_h];
        for y in 0..cell_h {
            let src_start = y * bpr;
            for x in 0..cell_w {
                out[y * cell_w + x] = data[src_start + x * 4 + 3];
            }
        }
        if out.iter().any(|&b| b != 0) {
            Some(AtlasGlyph::Coverage(out))
        } else {
            None
        }
    }
}

fn rasterize(font: &Font, ch: char, scale: u32, baseline: i32, px: f32, center: bool) -> Vec<u8> {
    let cell_w = CELL_W_BASE * scale;
    let cell_h = CELL_H_BASE * scale;
    let native = font_glyph(font, ch, baseline, px, center);
    if scale == 1 {
        return native;
    }
    let mut out = vec![0u8; (cell_w * cell_h) as usize];
    for y in 0..cell_h {
        let sy = y / scale;
        for x in 0..cell_w {
            let sx = x / scale;
            out[(y * cell_w + x) as usize] = native[(sy * CELL_W_BASE + sx) as usize];
        }
    }
    out
}

fn font_glyph(font: &Font, ch: char, baseline: i32, px: f32, center: bool) -> Vec<u8> {
    let mut native = vec![0u8; (CELL_W_BASE * CELL_H_BASE) as usize];
    // Skip rasterizing characters the font lacks — fontdue would otherwise
    // emit the .notdef glyph, which in Px437 is ``?``. Better to render a
    // blank cell so the caller (atlas) can substitute a fallback font.
    if !font.has_glyph(ch) {
        return native;
    }
    let (m, bm) = font.rasterize(ch, px);
    if m.width == 0 || m.height == 0 {
        return native;
    }
    let bw = m.width as i32;
    let bh = m.height as i32;
    let top = baseline - bh - m.ymin;
    // Px437 was designed for an 8-px advance and lays out via ``xmin``;
    // the system fallback fonts target a wider advance (Menlo at 13 px is
    // ~7-8 px wide), so center them in the cell instead of trusting xmin
    // — that way the glyph reads visually balanced even when narrower
    // than the cell.
    let left = if center {
        ((CELL_W_BASE as i32 - bw) / 2).max(0)
    } else {
        m.xmin.max(0)
    };
    for y in 0..bh {
        for x in 0..bw {
            let dx = left + x;
            let dy = top + y;
            if dx < 0 || dy < 0 || dx as u32 >= CELL_W_BASE || dy as u32 >= CELL_H_BASE {
                continue;
            }
            let src = bm[(y * bw + x) as usize];
            if src != 0 {
                native[(dy as u32 * CELL_W_BASE + dx as u32) as usize] = src;
            }
        }
    }
    native
}


struct App {
    window: Option<Arc<Window>>,
    surface: Option<softbuffer::Surface<Arc<Window>, Arc<Window>>>,
    context: Option<softbuffer::Context<Arc<Window>>>,
    atlas: Atlas,
    term: Arc<FairMutex<Term<EventProxy>>>,
    notifier: Notifier,
    cell_w: u32,
    cell_h: u32,
    scale: u32,
    cols: u32,
    rows: u32,
    palette: [u32; 256],
    modifiers: ModifiersState,
    mouse_col: u32,
    mouse_row: u32,
    mouse_buttons: u8, // bit 0 = left, 1 = middle, 2 = right
    settings: Settings,
    current_fingerprint: String,
    // Suppress save() while we're driving size/position/scale changes
    // ourselves (e.g. applying a saved config) — otherwise the Resized /
    // Moved events those calls trigger would echo back into the file
    // and overwrite the very state we just loaded.
    applying_config: bool,
    // Fingerprint of the last rendered frame: a hash of the cell grid +
    // window size. When alacritty fires Wakeup but the grid content is
    // unchanged (e.g. after parsing turbokod's per-frame cursor-query
    // sequence), we skip the softbuffer present — the CALayer commit
    // routes through CGContextDrawImage + vImage color conversion which
    // is the dominant cost on macOS even when no pixels change.
    last_render_hash: u64,
}

#[derive(Copy, Clone)]
struct RenderCell {
    c: char,
    fg: u32,
    bg: u32,
}

impl ApplicationHandler<UserEvent> for App {
    fn resumed(&mut self, el: &ActiveEventLoop) {
        if self.window.is_some() {
            return;
        }
        let fingerprint = monitor_fingerprint(el);
        let saved = self.settings.get(&fingerprint);

        // Apply saved scale before computing size, so the cell metrics
        // match what the saved width/height was measured against.
        if let Some(s) = saved {
            self.set_scale_internal(s.scale.clamp(MIN_SCALE, MAX_SCALE));
        }

        let inner = if let Some(s) = saved {
            // Round to whole-cell so the trailing column isn't a stripe of
            // background, mirroring the default-launch path below.
            let cols = (s.width / self.cell_w).max(MIN_COLS);
            let rows = (s.height / self.cell_h).max(MIN_ROWS);
            PhysicalSize::new(cols * self.cell_w, rows * self.cell_h)
        } else {
            // Open at ~2/3 of the primary monitor so the app feels like a real
            // workspace on first launch instead of an 80x25 postage stamp.
            // ``cell_w``/``cell_h`` and the monitor size are both physical
            // pixels, so no logical/physical conversion is needed. Snap to a
            // whole-cell boundary to avoid a partial trailing column at startup.
            // The first ``Resized`` event will drive ``on_resize`` and re-grid
            // the term, so the placeholder 80x25 it was initialised with only
            // exists for the millisecond before the window materialises.
            el.primary_monitor()
                .map(|m| {
                    let s = m.size();
                    let cols = ((s.width * 2 / 3) / self.cell_w).max(MIN_COLS);
                    let rows = ((s.height * 2 / 3) / self.cell_h).max(MIN_ROWS);
                    PhysicalSize::new(cols * self.cell_w, rows * self.cell_h)
                })
                .unwrap_or_else(|| PhysicalSize::new(
                    self.cell_w * self.cols,
                    self.cell_h * self.rows,
                ))
        };
        let mut attrs = WindowAttributes::default()
            .with_title("turbokod")
            .with_inner_size(inner);
        if let Some(s) = saved {
            attrs = attrs.with_position(PhysicalPosition::new(s.x, s.y));
        }
        let window = Arc::new(el.create_window(attrs).unwrap());
        let context = softbuffer::Context::new(window.clone()).unwrap();
        let surface = softbuffer::Surface::new(&context, window.clone()).unwrap();
        self.window = Some(window);
        self.context = Some(context);
        self.surface = Some(surface);
        self.current_fingerprint = fingerprint;
    }

    fn user_event(&mut self, el: &ActiveEventLoop, ev: UserEvent) {
        let te = match ev {
            UserEvent::Term(te) => te,
            UserEvent::OpenPaths(paths) => {
                #[cfg(target_os = "macos")]
                {
                    use std::io::Write as _;
                    if let Ok(mut f) = std::fs::OpenOptions::new()
                        .create(true)
                        .append(true)
                        .open("/tmp/turbokod-debug.log")
                    {
                        let _ = writeln!(
                            f,
                            "[{}] App::user_event OpenPaths: {:?} window={}",
                            std::process::id(),
                            paths,
                            self.window.is_some(),
                        );
                    }
                }
                // Forward each path to the embedded child as a private OSC
                // sequence — same channel turbokod uses outbound for cursor
                // shape hints. The Mojo terminal parses ``__mvc_open:<path>``
                // and emits an ``EVENT_OPEN_PATH`` the desktop reacts to.
                for p in &paths {
                    let seq = format!("\x1b]2;__mvc_open:{}\x07", p);
                    self.notifier.notify(seq.into_bytes());
                }
                // Bring the window forward so the user sees their newly
                // opened file — this is the macOS-app behavior the
                // single-instance forwarding is meant to mimic.
                if let Some(w) = &self.window {
                    w.set_minimized(false);
                    let _ = w.request_user_attention(None);
                    w.focus_window();
                    w.request_redraw();
                }
                return;
            }
        };
        // Whether the term grid may have changed and a redraw is
        // warranted. PTY-side query responses, title bar updates and
        // cursor-shape hints don't touch the cell grid, so we can
        // skip re-rendering the (expensive, dithered) desktop for
        // them. ``Wakeup`` and friends fall through to the catch-all
        // and DO request a redraw — that's alacritty's signal that
        // the parser actually consumed bytes.
        let mut needs_redraw = false;
        match te {
            // turbokod (and most TUIs) detect window size by writing CSI 6 n
            // and reading the cursor-position response. Alacritty parses that
            // request and emits PtyWrite with the response — we have to forward
            // it back to the child via the PTY writer.
            TermEvent::PtyWrite(text) => {
                self.notifier.notify(text.into_bytes());
            }
            TermEvent::TextAreaSizeRequest(formatter) => {
                let size = WindowSize {
                    num_lines: self.rows as u16,
                    num_cols: self.cols as u16,
                    cell_width: self.cell_w as u16,
                    cell_height: self.cell_h as u16,
                };
                let reply = formatter(size);
                self.notifier.notify(reply.into_bytes());
            }
            TermEvent::ColorRequest(idx, formatter) => {
                let argb = self.palette.get(idx).copied().unwrap_or(DEFAULT_FG);
                let rgb = Rgb {
                    r: ((argb >> 16) & 0xFF) as u8,
                    g: ((argb >> 8) & 0xFF) as u8,
                    b: (argb & 0xFF) as u8,
                };
                let reply = formatter(rgb);
                self.notifier.notify(reply.into_bytes());
            }
            TermEvent::Title(title) => {
                // turbokod piggy-backs on OSC 2 for cursor-shape hints —
                // ``__mvc_cursor:<shape>`` switches the platform pointer
                // instead of the window title. Generic terminals don't
                // know about it, so the same sequence is harmless there
                // (it just briefly flashes the prefix in their title bar).
                const CURSOR_PREFIX: &str = "__mvc_cursor:";
                if let Some(shape) = title.strip_prefix(CURSOR_PREFIX) {
                    if let Some(w) = &self.window {
                        let icon = match shape {
                            "text"    => CursorIcon::Text,
                            "pointer" => CursorIcon::Pointer,
                            _          => CursorIcon::Default,
                        };
                        w.set_cursor(icon);
                    }
                } else if let Some(w) = &self.window {
                    w.set_title(&title);
                }
            }
            TermEvent::ResetTitle => {
                if let Some(w) = &self.window {
                    w.set_title("turbokod");
                }
            }
            TermEvent::ChildExit(_) | TermEvent::Exit => {
                el.exit();
            }
            _ => {
                needs_redraw = true;
            }
        }
        if needs_redraw {
            if let Some(w) = &self.window {
                w.request_redraw();
            }
        }
    }

    fn window_event(&mut self, el: &ActiveEventLoop, _id: WindowId, event: WindowEvent) {
        self.check_monitor_change(el);
        match event {
            WindowEvent::CloseRequested => {
                let _ = self.notifier.0.send(Msg::Shutdown);
                el.exit();
            }
            WindowEvent::RedrawRequested => self.render(),
            WindowEvent::KeyboardInput { event, .. } => self.on_key(event),
            WindowEvent::Resized(new_size) => self.on_resize(new_size),
            WindowEvent::Moved(_) => self.save_window_state(),
            WindowEvent::ModifiersChanged(mods) => {
                self.modifiers = mods.state();
            }
            WindowEvent::CursorMoved { position, .. } => self.on_cursor_moved(position),
            WindowEvent::MouseInput { state, button, .. } => self.on_mouse_button(state, button),
            WindowEvent::MouseWheel { delta, .. } => self.on_mouse_wheel(delta),
            _ => {}
        }
    }
}

impl App {
    fn on_resize(&mut self, new_size: winit::dpi::PhysicalSize<u32>) {
        let cols = (new_size.width / self.cell_w).max(MIN_COLS);
        let rows = (new_size.height / self.cell_h).max(MIN_ROWS);
        if cols == self.cols && rows == self.rows {
            if let Some(w) = &self.window {
                w.request_redraw();
            }
            return;
        }
        self.cols = cols;
        self.rows = rows;

        let term_size = TermSize::new(cols as usize, rows as usize);
        self.term.lock().resize(term_size);

        let win_size = WindowSize {
            num_lines: rows as u16,
            num_cols: cols as u16,
            cell_width: self.cell_w as u16,
            cell_height: self.cell_h as u16,
        };
        let _ = self.notifier.0.send(Msg::Resize(win_size));
        // Push the standard xterm ``CSI 8 ; rows ; cols t`` window-size
        // report to the child's stdin so turbokod sees the new
        // dimensions on the next ``poll_event`` instead of waiting for
        // the cursor-query polling tick. This is the ``SIGWINCH``
        // analogue we couldn't get to fire reliably through Mojo's libc
        // bindings — same idea, routed through the byte stream that
        // turbokod's parser already consumes.
        let push = format!("\x1b[8;{};{}t", rows, cols);
        if std::env::var("TURBOKOD_DEBUG_RESIZE").is_ok() {
            eprintln!("[turbokod-app] resize push: {:?}", push);
        }
        self.notifier.notify(push.into_bytes());

        if let Some(w) = &self.window {
            w.request_redraw();
        }
        self.save_window_state();
    }

    fn on_key(&mut self, ev: KeyEvent) {
        if ev.state != ElementState::Pressed {
            return;
        }
        let mods = self.modifiers;
        // macOS Cmd is reported as SUPER. Cmd+=/+/-/0 control host font size
        // (matching iTerm/Terminal.app); other Cmd+<letter> are forwarded
        // to turbokod via the xterm modifyOtherKeys=2 envelope with the
        // meta bit set: ``CSI 27;<mod>;<codepoint>~``. The Mojo terminal
        // parser (``_csi_mods_from`` / ``_normalize_ctrl_letter``) folds
        // the meta bit onto the same canonical control-byte form Ctrl+
        // produces, so a hotkey table written against ``Ctrl+<letter>``
        // fires for both modifiers without any per-modifier branch.
        if mods.super_key() {
            if let Key::Character(s) = &ev.logical_key {
                match s.as_str() {
                    "=" | "+" => return self.change_scale(self.scale + 1),
                    "-" | "_" => return self.change_scale(self.scale.saturating_sub(1)),
                    "0" => return self.change_scale(DEFAULT_SCALE),
                    _ => {}
                }
                if let Some(ch) = s.chars().next() {
                    let cp = keycap_cp(ch);
                    let seq = format!("\x1b[27;{};{}~", mod_other_param(mods, true), cp);
                    self.notifier.notify(seq.into_bytes());
                    return;
                }
            }
        }
        let bytes: Cow<'static, [u8]> = match &ev.logical_key {
            Key::Named(NamedKey::Enter) => Cow::Borrowed(b"\r"),
            Key::Named(NamedKey::Backspace) => Cow::Borrowed(b"\x7f"),
            Key::Named(NamedKey::Tab) => {
                // Bare Tab: HT (0x09). With any modifier, emit CSI Z so the
                // embedded app sees Shift+Tab as the inverse of Tab — a bare
                // \t with the Shift bit dropped on the floor would land as
                // a plain Tab event and the dedent path would never fire.
                let m = modifier_param(mods);
                if m == 1 {
                    Cow::Borrowed(b"\t")
                } else {
                    Cow::Owned(format!("\x1b[1;{}Z", m).into_bytes())
                }
            }
            Key::Named(NamedKey::Escape) => Cow::Borrowed(b"\x1b"),
            Key::Named(NamedKey::Space) => Cow::Borrowed(b" "),
            Key::Named(NamedKey::ArrowUp) => Cow::Owned(csi_letter(b'A', mods)),
            Key::Named(NamedKey::ArrowDown) => Cow::Owned(csi_letter(b'B', mods)),
            Key::Named(NamedKey::ArrowRight) => Cow::Owned(csi_letter(b'C', mods)),
            Key::Named(NamedKey::ArrowLeft) => Cow::Owned(csi_letter(b'D', mods)),
            Key::Named(NamedKey::Home) => Cow::Owned(csi_letter(b'H', mods)),
            Key::Named(NamedKey::End) => Cow::Owned(csi_letter(b'F', mods)),
            Key::Named(NamedKey::Insert) => Cow::Owned(csi_tilde(2, mods)),
            Key::Named(NamedKey::Delete) => Cow::Owned(csi_tilde(3, mods)),
            Key::Named(NamedKey::PageUp) => Cow::Owned(csi_tilde(5, mods)),
            Key::Named(NamedKey::PageDown) => Cow::Owned(csi_tilde(6, mods)),
            // F1..F4 use SS3 (ESC O P/Q/R/S) when unmodified — what xterm
            // emits and what turbokod's terminal.mojo expects. With
            // modifiers they fall back to CSI 1;<mod>P (xterm convention).
            Key::Named(NamedKey::F1) => Cow::Owned(ss3_or_csi(b'P', mods)),
            Key::Named(NamedKey::F2) => Cow::Owned(ss3_or_csi(b'Q', mods)),
            Key::Named(NamedKey::F3) => Cow::Owned(ss3_or_csi(b'R', mods)),
            Key::Named(NamedKey::F4) => Cow::Owned(ss3_or_csi(b'S', mods)),
            Key::Named(NamedKey::F5) => Cow::Owned(csi_tilde(15, mods)),
            Key::Named(NamedKey::F6) => Cow::Owned(csi_tilde(17, mods)),
            Key::Named(NamedKey::F7) => Cow::Owned(csi_tilde(18, mods)),
            Key::Named(NamedKey::F8) => Cow::Owned(csi_tilde(19, mods)),
            Key::Named(NamedKey::F9) => Cow::Owned(csi_tilde(20, mods)),
            Key::Named(NamedKey::F10) => Cow::Owned(csi_tilde(21, mods)),
            Key::Named(NamedKey::F11) => Cow::Owned(csi_tilde(23, mods)),
            Key::Named(NamedKey::F12) => Cow::Owned(csi_tilde(24, mods)),
            Key::Character(s) => {
                if mods.control_key() {
                    if let Some(ch) = s.chars().next() {
                        let lower = ch.to_ascii_lowercase();
                        if ('a'..='z').contains(&lower) {
                            // Plain Ctrl+letter (no shift/alt/meta) → ASCII
                            // control byte. With any extra modifier, route
                            // through modifyOtherKeys so the embedded app
                            // sees the full ``Ctrl+Shift+F`` rather than a
                            // bare 0x06 with the Shift bit dropped on the
                            // floor.
                            if !mods.shift_key() && !mods.alt_key() && !mods.super_key() {
                                return self.notifier.notify(vec![lower as u8 - b'a' + 1]);
                            }
                            let seq = format!(
                                "\x1b[27;{};{}~", mod_other_param(mods, false), lower as u32,
                            );
                            return self.notifier.notify(seq.into_bytes());
                        }
                    }
                }
                Cow::Owned(s.as_str().as_bytes().to_vec())
            }
            _ => return,
        };
        self.notifier.notify(bytes);
    }

    fn set_scale_internal(&mut self, new_scale: u32) {
        self.scale = new_scale;
        self.cell_w = CELL_W_BASE * new_scale;
        self.cell_h = CELL_H_BASE * new_scale;
        self.atlas = Atlas::new(new_scale);
    }

    fn change_scale(&mut self, new_scale: u32) {
        let new_scale = new_scale.clamp(MIN_SCALE, MAX_SCALE);
        if new_scale == self.scale {
            return;
        }
        self.set_scale_internal(new_scale);

        let Some(window) = &self.window else { return };
        let size = window.inner_size();
        let cols = (size.width / self.cell_w).max(MIN_COLS);
        let rows = (size.height / self.cell_h).max(MIN_ROWS);
        self.cols = cols;
        self.rows = rows;

        let term_size = TermSize::new(cols as usize, rows as usize);
        self.term.lock().resize(term_size);

        let win_size = WindowSize {
            num_lines: rows as u16,
            num_cols: cols as u16,
            cell_width: self.cell_w as u16,
            cell_height: self.cell_h as u16,
        };
        let _ = self.notifier.0.send(Msg::Resize(win_size));
        // Synchronous push of the new size — see ``on_resize`` for the
        // reasoning. ``Cmd+=`` / ``Cmd+-`` re-grids the cell count too.
        self.notifier.notify(format!("\x1b[8;{};{}t", rows, cols).into_bytes());
        window.request_redraw();
        self.save_window_state();
    }

    fn save_window_state(&mut self) {
        if self.applying_config {
            return;
        }
        let Some(window) = &self.window else { return };
        let inner = window.inner_size();
        let pos = window
            .outer_position()
            .unwrap_or_else(|_| PhysicalPosition::new(0, 0));
        let state = WindowState {
            scale: self.scale,
            x: pos.x,
            y: pos.y,
            width: inner.width,
            height: inner.height,
        };
        self.settings.put(&self.current_fingerprint, state);
        self.settings.save();
    }

    // Re-evaluate window state when the monitor topology changes. Called
    // at the top of every window_event, so a hot-plug (or any layout
    // change in System Settings → Displays) is picked up on the very
    // next event the OS routes our way — typically the Moved/Resized
    // burst that the OS itself fires when arrangements shift.
    fn check_monitor_change(&mut self, el: &ActiveEventLoop) {
        let fingerprint = monitor_fingerprint(el);
        if fingerprint == self.current_fingerprint {
            return;
        }
        self.current_fingerprint = fingerprint.clone();
        self.applying_config = true;
        if let Some(state) = self.settings.get(&fingerprint) {
            self.apply_saved_state(state);
        } else {
            self.apply_default_state(el);
        }
        self.applying_config = false;
    }

    fn apply_saved_state(&mut self, state: WindowState) {
        let scale = state.scale.clamp(MIN_SCALE, MAX_SCALE);
        if scale != self.scale {
            self.change_scale_no_save(scale);
        }
        let Some(window) = self.window.clone() else { return };
        let cols = (state.width / self.cell_w).max(MIN_COLS);
        let rows = (state.height / self.cell_h).max(MIN_ROWS);
        let _ = window.request_inner_size(PhysicalSize::new(
            cols * self.cell_w,
            rows * self.cell_h,
        ));
        window.set_outer_position(PhysicalPosition::new(state.x, state.y));
    }

    fn apply_default_state(&mut self, el: &ActiveEventLoop) {
        if self.scale != DEFAULT_SCALE {
            self.change_scale_no_save(DEFAULT_SCALE);
        }
        let Some(monitor) = el.primary_monitor() else { return };
        let Some(window) = self.window.clone() else { return };
        let s = monitor.size();
        let cols = ((s.width * 2 / 3) / self.cell_w).max(MIN_COLS);
        let rows = ((s.height * 2 / 3) / self.cell_h).max(MIN_ROWS);
        let _ = window.request_inner_size(PhysicalSize::new(
            cols * self.cell_w,
            rows * self.cell_h,
        ));
        // Centre on the (now primary) monitor so the window doesn't end
        // up off-screen if the saved coords belonged to a different
        // arrangement that's no longer connected.
        let pos = monitor.position();
        let x = pos.x + ((s.width as i32 - (cols * self.cell_w) as i32) / 2);
        let y = pos.y + ((s.height as i32 - (rows * self.cell_h) as i32) / 2);
        window.set_outer_position(PhysicalPosition::new(x, y));
    }

    // Same as change_scale but skips the persistence write — used by
    // apply_saved_state / apply_default_state, which run with the
    // ``applying_config`` guard already raised on the caller's side.
    fn change_scale_no_save(&mut self, new_scale: u32) {
        let new_scale = new_scale.clamp(MIN_SCALE, MAX_SCALE);
        if new_scale == self.scale {
            return;
        }
        self.set_scale_internal(new_scale);
        let Some(window) = &self.window else { return };
        let size = window.inner_size();
        let cols = (size.width / self.cell_w).max(MIN_COLS);
        let rows = (size.height / self.cell_h).max(MIN_ROWS);
        self.cols = cols;
        self.rows = rows;
        let term_size = TermSize::new(cols as usize, rows as usize);
        self.term.lock().resize(term_size);
        let win_size = WindowSize {
            num_lines: rows as u16,
            num_cols: cols as u16,
            cell_width: self.cell_w as u16,
            cell_height: self.cell_h as u16,
        };
        let _ = self.notifier.0.send(Msg::Resize(win_size));
        self.notifier.notify(format!("\x1b[8;{};{}t", rows, cols).into_bytes());
        window.request_redraw();
    }

    fn on_cursor_moved(&mut self, position: PhysicalPosition<f64>) {
        let col = (position.x as i64 / self.cell_w as i64).clamp(0, self.cols as i64 - 1) as u32;
        let row = (position.y as i64 / self.cell_h as i64).clamp(0, self.rows as i64 - 1) as u32;
        if col == self.mouse_col && row == self.mouse_row {
            return;
        }
        self.mouse_col = col;
        self.mouse_row = row;
        if self.mouse_buttons != 0 {
            // Drag motion is meaningful in both ``?1002`` (button-event
            // tracking) and ``?1003`` (any-event tracking) — 1003 is a
            // superset of 1002 in the xterm spec. turbokod turns on
            // *both* (so a real terminal delivers hover and drag), but
            // alacritty's MouseMode handling treats them as mutually
            // exclusive: each new ``h`` sequence clears the others, so
            // we end up with only MOUSE_MOTION set even though the
            // embedded app expects drag too. Accept either flag here.
            let mode = *self.term.lock().mode();
            if mode.intersects(TermMode::MOUSE_DRAG | TermMode::MOUSE_MOTION) {
                let btn = lowest_set_bit(self.mouse_buttons);
                self.send_mouse(btn | 32, true);
            }
        } else {
            // Idle motion (only if MOUSE_MOTION mode set).
            let mode = *self.term.lock().mode();
            if mode.contains(TermMode::MOUSE_MOTION) {
                self.send_mouse(3 | 32, true);
            }
        }
    }

    fn on_mouse_button(&mut self, state: ElementState, button: MouseButton) {
        let btn_idx: u8 = match button {
            MouseButton::Left => 0,
            MouseButton::Middle => 1,
            MouseButton::Right => 2,
            _ => return,
        };
        let bit = 1u8 << btn_idx;
        match state {
            ElementState::Pressed => self.mouse_buttons |= bit,
            ElementState::Released => self.mouse_buttons &= !bit,
        }
        let mode = *self.term.lock().mode();
        if !mode.intersects(TermMode::MOUSE_MODE) {
            return;
        }
        self.send_mouse(btn_idx, state == ElementState::Pressed);
    }

    fn on_mouse_wheel(&mut self, delta: MouseScrollDelta) {
        let lines = match delta {
            MouseScrollDelta::LineDelta(_, y) => y as f64,
            MouseScrollDelta::PixelDelta(p) => p.y / self.cell_h as f64,
        };
        if lines.abs() < 0.01 {
            return;
        }
        let mode = *self.term.lock().mode();
        if !mode.intersects(TermMode::MOUSE_MODE) {
            return;
        }
        let btn = if lines > 0.0 { 64 } else { 65 };
        self.send_mouse(btn, true);
    }

    fn send_mouse(&self, button: u8, pressed: bool) {
        let mut b = button as u32;
        let mods = self.modifiers;
        if mods.shift_key() {
            b |= 4;
        }
        // Fold Cmd (super) onto the alt bit. The xterm SGR mouse encoding has
        // no Cmd bit, and Mojo's editor treats Alt+left-click as the goto-
        // definition gesture (matching what iTerm2 sends for Option+click);
        // folding super here makes Cmd+click — the natural macOS gesture —
        // trigger the same path through the native app.
        if mods.alt_key() || mods.super_key() {
            b |= 8;
        }
        if mods.control_key() {
            b |= 16;
        }
        let mode = *self.term.lock().mode();
        // SGR encoding (1006). Coordinates are 1-indexed.
        let bytes = if mode.contains(TermMode::SGR_MOUSE) {
            let suffix = if pressed { 'M' } else { 'm' };
            format!("\x1b[<{};{};{}{}", b, self.mouse_col + 1, self.mouse_row + 1, suffix)
                .into_bytes()
        } else {
            // X10 encoding (legacy). Caps at 223.
            let cb = if pressed { (b + 32) as u8 } else { (3 + 32) as u8 };
            let cx = (self.mouse_col + 33).min(255) as u8;
            let cy = (self.mouse_row + 33).min(255) as u8;
            vec![0x1b, b'[', b'M', cb, cx, cy]
        };
        self.notifier.notify(bytes);
    }

    fn render(&mut self) {
        let App { window, surface, atlas, term, cell_w, cell_h, scale, cols, rows, palette, last_render_hash, .. } = self;
        let Some(window) = window.as_ref() else { return };
        let Some(surface) = surface.as_mut() else { return };
        let size = window.inner_size();
        let (Some(w), Some(h)) = (NonZeroU32::new(size.width), NonZeroU32::new(size.height)) else {
            return;
        };

        let cols_u = *cols as usize;
        let rows_u = *rows as usize;
        // Build the cell grid first (cheap — just reads under a mutex)
        // and hash it together with the window size. If the result
        // matches the previous frame's hash, the visible output would
        // be identical, so we can skip the softbuffer commit. On macOS
        // that commit routes through CGContextDrawImage + vImage color
        // conversion and runs ~50 ms even when no pixels actually
        // changed; skipping it brings idle CPU from ~50 % to ~0 %.
        let mut cells: Vec<RenderCell> = Vec::with_capacity(cols_u * rows_u);
        {
            let term = term.lock();
            let grid = term.grid();
            let g_cols = grid.columns();
            let g_lines = grid.screen_lines();
            for line in 0..g_lines.min(rows_u) {
                let row = &grid[Line(line as i32)];
                for col in 0..g_cols.min(cols_u) {
                    let cell = &row[Column(col)];
                    let bold = cell.flags.contains(Flags::BOLD);
                    let mut fg = resolve_color(cell.fg, palette, bold, DEFAULT_FG);
                    let mut bg = resolve_color(cell.bg, palette, false, DEFAULT_BG);
                    if cell.flags.contains(Flags::INVERSE) {
                        std::mem::swap(&mut fg, &mut bg);
                    }
                    if cell.flags.contains(Flags::HIDDEN) {
                        fg = bg;
                    }
                    cells.push(RenderCell { c: cell.c, fg, bg });
                }
            }
        }

        // Cheap hash over the cell content + window dims. We use the
        // default ``DefaultHasher`` (SipHash) because it's already in
        // std and the cell count tops out around 30k for a typical
        // window — overhead is well under a millisecond. Match means
        // the visible output is identical to last frame.
        let frame_hash = {
            use std::hash::{Hash, Hasher};
            let mut h = std::collections::hash_map::DefaultHasher::new();
            (size.width, size.height, cols_u, rows_u, *cell_w, *cell_h, *scale).hash(&mut h);
            for c in &cells {
                c.c.hash(&mut h);
                c.fg.hash(&mut h);
                c.bg.hash(&mut h);
            }
            h.finish()
        };
        if frame_hash == *last_render_hash {
            return;
        }
        *last_render_hash = frame_hash;

        surface.resize(w, h).unwrap();
        let mut buf = surface.buffer_mut().unwrap();
        // The per-cell painter below writes every pixel of every cell, so
        // the upfront full-buffer clear is only needed when the window
        // has a margin strip outside the cell grid (right/bottom edges
        // when win_w / win_h aren't an integer multiple of cell size).
        // ``resumed`` opens cell-aligned, so on launch and through any
        // resize that lands on a multiple, we skip a 1.5M-pixel memset.
        let cells_w = cols_u * (*cell_w as usize);
        let cells_h = rows_u * (*cell_h as usize);
        if cells_w < size.width as usize || cells_h < size.height as usize {
            for px in buf.iter_mut() {
                *px = DEFAULT_BG;
            }
        }

        let win_w = size.width as usize;
        let cw = *cell_w as usize;
        let ch = *cell_h as usize;
        let s = *scale as i32;
        for line in 0..rows_u {
            for col in 0..cols_u {
                let cell = cells.get(line * cols_u + col).copied().unwrap_or(RenderCell {
                    c: ' ',
                    fg: DEFAULT_FG,
                    bg: DEFAULT_BG,
                });
                let x0 = col * cw;
                let y0 = line * ch;

                if let Some(dither) = shade_dither(cell.c) {
                    // Pixel-position-based halftone: tiles seamlessly across cells
                    // at any cell width because the on/off function operates on
                    // absolute screen coordinates.
                    for y in 0..ch {
                        let sy = (y0 + y) as i32 / s;
                        let row_base = (y0 + y) * win_w + x0;
                        for x in 0..cw {
                            let sx = (x0 + x) as i32 / s;
                            let px = if dither(sx, sy) { cell.fg } else { cell.bg };
                            let idx = row_base + x;
                            if idx < buf.len() {
                                buf[idx] = px;
                            }
                        }
                    }
                } else {
                    match atlas.glyph(cell.c) {
                        AtlasGlyph::Coverage(g) => {
                            for y in 0..ch {
                                let row_base = (y0 + y) * win_w + x0;
                                for x in 0..cw {
                                    let cov = g[y * cw + x] as u32;
                                    let px = blend(cell.fg, cell.bg, cov);
                                    let idx = row_base + x;
                                    if idx < buf.len() {
                                        buf[idx] = px;
                                    }
                                }
                            }
                        }
                        AtlasGlyph::Color(g) => {
                            // Premultiplied source over cell.bg destination.
                            // ``out = src + (1 - alpha) * bg`` works directly
                            // on premultiplied sources, which is what the
                            // ARGB packed in the atlas is.
                            for y in 0..ch {
                                let row_base = (y0 + y) * win_w + x0;
                                for x in 0..cw {
                                    let s = g[y * cw + x];
                                    let a = (s >> 24) & 0xFF;
                                    let idx = row_base + x;
                                    if idx >= buf.len() {
                                        continue;
                                    }
                                    if a == 0 {
                                        buf[idx] = cell.bg;
                                        continue;
                                    }
                                    let inv = 255 - a;
                                    let sr = (s >> 16) & 0xFF;
                                    let sg = (s >> 8) & 0xFF;
                                    let sb = s & 0xFF;
                                    let br = (cell.bg >> 16) & 0xFF;
                                    let bg_ = (cell.bg >> 8) & 0xFF;
                                    let bb = cell.bg & 0xFF;
                                    let r = (sr + (inv * br) / 255).min(255);
                                    let gr = (sg + (inv * bg_) / 255).min(255);
                                    let b = (sb + (inv * bb) / 255).min(255);
                                    buf[idx] = (r << 16) | (gr << 8) | b;
                                }
                            }
                        }
                    }
                }
            }
        }
        buf.present().unwrap();
    }
}

fn lowest_set_bit(b: u8) -> u8 {
    for i in 0..8 {
        if b & (1 << i) != 0 {
            return i;
        }
    }
    0
}

// xterm modifier param: 1 + Shift + 2*Alt + 4*Ctrl. 1 means "no modifier",
// in which case we omit the param entirely.
fn modifier_param(mods: ModifiersState) -> u8 {
    let mut m = 1u8;
    if mods.shift_key() { m += 1; }
    if mods.alt_key() { m += 2; }
    if mods.control_key() { m += 4; }
    m
}

fn csi_letter(letter: u8, mods: ModifiersState) -> Vec<u8> {
    let m = modifier_param(mods);
    if m == 1 {
        vec![0x1b, b'[', letter]
    } else {
        format!("\x1b[1;{}{}", m, letter as char).into_bytes()
    }
}

fn csi_tilde(num: u8, mods: ModifiersState) -> Vec<u8> {
    let m = modifier_param(mods);
    if m == 1 {
        format!("\x1b[{}~", num).into_bytes()
    } else {
        format!("\x1b[{};{}~", num, m).into_bytes()
    }
}

fn ss3_or_csi(letter: u8, mods: ModifiersState) -> Vec<u8> {
    let m = modifier_param(mods);
    if m == 1 {
        vec![0x1b, b'O', letter]
    } else {
        format!("\x1b[1;{}{}", m, letter as char).into_bytes()
    }
}

// modifyOtherKeys (xterm) modifier param: 1 + Shift + 2*Alt + 4*Ctrl + 8*Meta.
// The meta (Cmd) bit is non-standard but the Mojo terminal parser opts in to
// it, and including it lets the embedded app distinguish Cmd+X from Ctrl+X.
fn mod_other_param(mods: ModifiersState, force_meta: bool) -> u8 {
    let mut bits = 0u8;
    if mods.shift_key()   { bits |= 1; }
    if mods.alt_key()     { bits |= 2; }
    if mods.control_key() { bits |= 4; }
    if force_meta || mods.super_key() { bits |= 8; }
    1 + bits
}

// Codepoint that should appear inside the modifyOtherKeys envelope: the
// "key cap" rather than the produced character. Lowercasing ASCII letters
// keeps the envelope's codepoint stable across Shift state, so a hotkey
// table written against ``ord('f')`` matches both Ctrl+F and Ctrl+Shift+F
// once the modifier bits are decoded separately.
fn keycap_cp(ch: char) -> u32 {
    if ch.is_ascii_alphabetic() {
        ch.to_ascii_lowercase() as u32
    } else {
        ch as u32
    }
}

// Halftone screens for U+2591/2/3. Returning a function-of-absolute-coords lets
// the renderer produce a pattern that tiles cleanly across cells regardless of
// the font's bitmap width. Patterns mirror the IBM ROM's staggered halftones.
fn shade_dither(c: char) -> Option<fn(i32, i32) -> bool> {
    match c {
        // Period 4 in x, period 2 in y, 1 dot per 4×2 = 25% density. Each row
        // of dots is offset 2 px from the row above, giving the diagonal feel.
        '\u{2591}' => Some(|x, y| ((x + 2 * y) & 3) == 3),
        // Standard 50% checkerboard.
        '\u{2592}' => Some(|x, y| ((x + y) & 1) != 0),
        // Inverse of ░: 3 of every 4 pixels on, holes staggered diagonally.
        '\u{2593}' => Some(|x, y| ((x + 2 * y) & 3) != 2),
        _ => None,
    }
}

fn main() -> anyhow::Result<()> {
    let event_loop: WinitEventLoop<UserEvent> = WinitEventLoop::with_user_event().build()?;
    let proxy = event_loop.create_proxy();

    // macOS URL-scheme handler. Must be installed before ``NSApp.run()``
    // (i.e., before ``event_loop.run_app``) so the kAEGetURL event a
    // cold-launched-by-URL invocation fires gets caught instead of
    // landing on LaunchServices' default no-op.
    #[cfg(target_os = "macos")]
    macos_url_scheme::register(proxy.clone());

    // Single-instance check before we spawn the PTY child: if a primary
    // already owns the socket, forward our argv to it and exit clean.
    // The user typed ``turbokod foo.txt`` from a shell — the existing
    // window opens ``foo.txt`` and gets focus, no second window.
    let cli_args: Vec<String> = std::env::args().skip(1).collect();
    // ``turbokod://...`` URLs in argv are open-requests, never shell
    // programs — splitting them out here keeps them off the
    // ``Shell::new`` path (the cli_args[0]-as-program logic below) and
    // lets us route them through ``OpenPaths`` instead, which is the
    // same flow secondary instances use to forward args.
    let cwd_for_args = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("/"));
    let url_open_args: Vec<String> = cli_args
        .iter()
        .filter(|a| a.starts_with("turbokod://"))
        .filter_map(|a| translate_open_arg(a, &cwd_for_args))
        .collect();
    let shell_args: Vec<String> = cli_args
        .iter()
        .filter(|a| !a.starts_with("turbokod://"))
        .cloned()
        .collect();
    let _instance_guard = match ensure_single_instance(&cli_args, proxy.clone()) {
        InstanceRole::Primary(guard) => guard,
        InstanceRole::Secondary => {
            // Another primary owns the socket. We forwarded our
            // ``cli_args`` (which may have been empty), and we may
            // *also* have been launched specifically to receive a
            // ``turbokod://`` URL via Apple Event. The AE only fires
            // once we enter the event loop, so spin up a
            // ``BridgeApp``: it waits ~1.5 s for the AE to deliver,
            // forwards the URL through the same socket, and exits.
            // Without this the URL gets dropped because the secondary
            // process exits before ``NSApp.run`` ever pumps it.
            //
            // Anything in ``url_open_args`` came from our own argv
            // (e.g. ``turbokod 'turbokod://...'`` from the shell),
            // already-translated; forward it now so we don't depend
            // on the AE round-trip for that case.
            if !url_open_args.is_empty() {
                forward_open_paths(&url_open_args);
            }
            let mut bridge = BridgeApp::new();
            event_loop.run_app(&mut bridge)?;
            return Ok(());
        }
    };
    // Primary launch with URL args: queue them up so the event loop
    // delivers an ``OpenPaths`` once the Mojo child has come up. The
    // OSC bytes get buffered in the PTY in the meantime, so the
    // child sees them as soon as it starts reading input.
    if !url_open_args.is_empty() {
        let _ = proxy.send_event(UserEvent::OpenPaths(url_open_args));
    }

    let scale = DEFAULT_SCALE;
    let cell_w = CELL_W_BASE * scale;
    let cell_h = CELL_H_BASE * scale;

    // Term + PTY start at 80x25; the window's actual dimensions get
    // chosen against the primary monitor inside ``resumed`` (winit 0.30
    // only exposes monitors via ``ActiveEventLoop``). The first
    // ``Resized`` event then re-grids the term through ``on_resize``.
    let term_size = TermSize::new(INIT_COLS as usize, INIT_ROWS as usize);
    let listener = EventProxy(proxy);
    let term = Arc::new(FairMutex::new(Term::new(
        TermConfig::default(),
        &term_size,
        listener.clone(),
    )));

    // Tag the PTY environment so the Mojo runtime can detect it's
    // hosted by the native app and unlock features the alacritty
    // wrapper supports but generic terminals don't (currently: the
    // OSC-encoded mouse-pointer shape hint).
    let mut env = HashMap::new();
    env.insert("TURBOKOD_HOST".to_string(), "1".to_string());
    // ``shell_args`` is ``cli_args`` with ``turbokod://`` URLs
    // removed; URLs are open-requests, not shell programs. Anything
    // remaining still follows the original "argv[0] is the program,
    // argv[1..] are its args" convention.
    let bundle = discover_bundle_launch_info();
    let shell = if shell_args.is_empty() {
        // No CLI shell program — if the bundle ships ``turbokod-desktop``
        // next to us, default to that so a URL-cold-launched .app
        // actually has the mojo backend running (and the
        // ``__mvc_open:`` OSC reaches a recipient who knows what to
        // do with it). Outside a bundle this is None and the PTY
        // falls back to ``$SHELL``, matching the cargo-run dev flow.
        bundle.mojo_program.clone().map(|p| {
            Shell::new(p.to_string_lossy().into_owned(), Vec::new())
        })
    } else {
        let mut iter = shell_args.iter().cloned();
        iter.next().map(|prog| Shell::new(prog, iter.collect()))
    };
    let working_dir = if shell.is_some() {
        bundle.project_root.clone()
    } else {
        None
    };
    if shell.is_some() {
        if let Some(fallback) = &bundle.dyld_fallback {
            // Merge with any inherited fallback path the user already
            // had set, so we don't trash their dev-env overrides.
            let combined = match std::env::var("DYLD_FALLBACK_LIBRARY_PATH") {
                Ok(existing) if !existing.is_empty() => format!("{}:{}", fallback, existing),
                _ => fallback.clone(),
            };
            env.insert("DYLD_FALLBACK_LIBRARY_PATH".to_string(), combined);
        }
    }
    let pty_opts = PtyOptions {
        shell,
        working_directory: working_dir,
        env,
        ..Default::default()
    };
    let win_size = WindowSize {
        num_lines: INIT_ROWS as u16,
        num_cols: INIT_COLS as u16,
        cell_width: cell_w as u16,
        cell_height: cell_h as u16,
    };
    let pty = tty::new(&pty_opts, win_size, 0)?;

    let pty_loop = PtyEventLoop::new(term.clone(), listener, pty, false, false)?;
    let notifier = Notifier(pty_loop.channel());
    // AppKit swallows Cmd+` for "Cycle through windows" before keyDown:
    // ever fires. Install a local NSEvent monitor that consumes the
    // event and forwards a synthetic xterm modifyOtherKeys envelope to
    // the PTY, so the embedded app can bind it.
    #[cfg(target_os = "macos")]
    macos_key_monitor::install(pty_loop.channel());
    let _ = pty_loop.spawn();

    let mut app = App {
        window: None,
        surface: None,
        context: None,
        atlas: Atlas::new(scale),
        term,
        notifier,
        cell_w,
        cell_h,
        scale,
        cols: INIT_COLS,
        rows: INIT_ROWS,
        palette: build_palette(),
        modifiers: ModifiersState::empty(),
        mouse_col: 0,
        mouse_row: 0,
        mouse_buttons: 0,
        settings: Settings::load(),
        current_fingerprint: String::new(),
        applying_config: false,
        last_render_hash: 0,
    };
    event_loop.run_app(&mut app)?;
    Ok(())
}

#[cfg(test)]
mod url_tests {
    use super::*;

    #[test]
    fn open_url_with_file_and_line() {
        let r = parse_turbokod_url(
            "turbokod://open?file=/Users/x/foo.py&line=42",
        );
        assert_eq!(r.as_ref().map(|p| p.0.as_str()), Some("/Users/x/foo.py"));
        assert_eq!(r.and_then(|p| p.1), Some(42));
    }

    #[test]
    fn open_url_without_line() {
        let r = parse_turbokod_url("turbokod://open?file=/tmp/a.txt");
        assert_eq!(r.as_ref().map(|p| p.0.as_str()), Some("/tmp/a.txt"));
        assert_eq!(r.and_then(|p| p.1), None);
    }

    #[test]
    fn open_url_percent_decoded_path() {
        let r = parse_turbokod_url(
            "turbokod://open?file=/tmp/space%20name.txt&line=7",
        );
        assert_eq!(r.as_ref().map(|p| p.0.as_str()), Some("/tmp/space name.txt"));
        assert_eq!(r.and_then(|p| p.1), Some(7));
    }

    #[test]
    fn unknown_command_rejected() {
        assert!(parse_turbokod_url("turbokod://search?q=foo").is_none());
    }

    #[test]
    fn translate_appends_unit_separator_for_line() {
        let cwd = PathBuf::from("/cwd");
        let s = translate_open_arg(
            "turbokod://open?file=/abs/path.rs&line=99",
            &cwd,
        );
        assert_eq!(s.as_deref(), Some("/abs/path.rs\x1f99"));
    }

    #[test]
    fn translate_unknown_url_dropped() {
        let cwd = PathBuf::from("/cwd");
        // ``turbokod://`` recognized but ``search`` isn't ``open`` —
        // ``filter_map`` drops the entry rather than passing the URL
        // through as a path.
        assert!(translate_open_arg("turbokod://search?q=x", &cwd).is_none());
    }

    #[test]
    fn translate_relative_path_is_canonicalized() {
        let cwd = PathBuf::from("/work/proj");
        let s = translate_open_arg("foo.txt", &cwd);
        assert_eq!(s.as_deref(), Some("/work/proj/foo.txt"));
    }
}

#[cfg(test)]
#[cfg(target_os = "macos")]
mod tests {
    use super::*;

    fn ink(g: &[u8]) -> usize {
        g.iter().filter(|&&b| b != 0).count()
    }

    /// Helper for tests that just want a coverage byte buffer back from
    /// the atlas. For ``Color`` glyphs we collapse to alpha so the ink
    /// counts comparable across mono/color glyphs.
    fn glyph_as_coverage(atlas: &mut Atlas, ch: char) -> Vec<u8> {
        match atlas.glyph(ch) {
            AtlasGlyph::Coverage(b) => b.clone(),
            AtlasGlyph::Color(p) => p.iter().map(|px| (px >> 24) as u8).collect(),
        }
    }

    // The test we actually want: render the SAME char three ways — IBM
    // alone, fallback alone, and via the Atlas — and prove the Atlas
    // bytes exactly equal one of the two. That way the routing decision
    // (does the Atlas pick the right font for this codepoint?) is what's
    // being checked, not just "did some pixels come out".
    #[test]
    fn atlas_routes_to_ibm_for_a_and_to_fallback_for_a_unicode_symbol() {
        let primary = Font::from_bytes(PX437, FontSettings::default()).unwrap();
        let primary_baseline = primary
            .horizontal_line_metrics(RASTER_PX)
            .unwrap()
            .ascent
            .round() as i32;
        let (fallback, fallback_baseline) = load_fallback_font();
        let fallback = fallback.expect(
            "test environment lacks a system monospace fallback — \
             tests assume macOS with Menlo / Monaco / Arial Unicode",
        );

        // Probe characters: 'A' is in Px437 (and in basically every font);
        // 'ƥ' (U+01A5, Latin small p with hook) sits in Latin Extended-B,
        // which is outside Px437's CP437-derived coverage but present in
        // Menlo. We assert these premises so a future font swap fails the
        // test loudly at the precondition rather than producing confusing
        // byte-mismatch output.
        assert!(primary.has_glyph('A'), "premise: Px437 has 'A'");
        assert!(!primary.has_glyph('ƥ'), "premise: Px437 lacks ƥ");
        assert!(fallback.has_glyph('ƥ'), "premise: fallback has ƥ");

        let ibm_a = rasterize(&primary, 'A', 1, primary_baseline, RASTER_PX, false);
        let fb_a = rasterize(&fallback, 'A', 1, fallback_baseline, FALLBACK_PX, true);
        let ibm_p = rasterize(&primary, 'ƥ', 1, primary_baseline, RASTER_PX, false);
        let fb_p = rasterize(&fallback, 'ƥ', 1, fallback_baseline, FALLBACK_PX, true);
        // Sanity on premises: the two fonts disagree visually on 'A',
        // so byte-equality below isn't accidentally satisfied by both
        // bitmaps being identical.
        assert_ne!(ibm_a, fb_a, "Px437 'A' shouldn't match fallback 'A' byte-for-byte");
        assert!(ink(&ibm_a) > 0 && ink(&fb_p) > 0, "both probes should ink");
        assert_eq!(ink(&ibm_p), 0, "Px437 has no ƥ — direct rasterize is blank");

        let mut atlas = Atlas::new(1);
        match atlas.glyph('A') {
            AtlasGlyph::Coverage(b) => assert_eq!(b, &ibm_a, "Atlas 'A' must use Px437"),
            AtlasGlyph::Color(_) => panic!("Atlas 'A' should be a Coverage glyph"),
        }
        match atlas.glyph('ƥ') {
            AtlasGlyph::Coverage(b) => assert_eq!(b, &fb_p, "Atlas 'ƥ' must use fallback"),
            AtlasGlyph::Color(_) => panic!("Atlas 'ƥ' should be a Coverage glyph"),
        }
    }

    #[test]
    fn dump_emoji_bitmap() {
        // cargo test -- --nocapture dump_emoji_bitmap
        for &(probe, label) in &[('😀', "U+1F600"), ('฿', "U+0E3F"), ('⽊', "U+2F4A")] {
            println!("\n{} {} (8x16):", probe, label);
            let cw = CELL_W_BASE as usize;
            let ch = CELL_H_BASE as usize;
            match os_fallback_rasterize(probe, 1) {
                None => println!("  (empty)"),
                Some(AtlasGlyph::Coverage(pixels)) => {
                    for y in 0..ch {
                        print!("  ");
                        for x in 0..cw {
                            let v = pixels[y * cw + x];
                            print!("{}", if v == 0 { '.' } else if v < 64 { ',' } else if v < 192 { '+' } else { '#' });
                        }
                        println!();
                    }
                }
                Some(AtlasGlyph::Color(pixels)) => {
                    for y in 0..ch {
                        print!("  ");
                        for x in 0..cw {
                            let argb = pixels[y * cw + x];
                            let a = (argb >> 24) & 0xFF;
                            let r = (argb >> 16) & 0xFF;
                            let g = (argb >> 8) & 0xFF;
                            let b = argb & 0xFF;
                            // Show alpha intensity + a hint of the dominant channel
                            // (R/G/B) so we can sanity-check we got *colored* pixels
                            // rather than a grayscale silhouette.
                            let glyph_char = if a == 0 { '.' }
                            else if r > g && r > b { 'R' }
                            else if g > r && g > b { 'G' }
                            else if b > r && b > g { 'B' }
                            else { if a < 128 { '+' } else { '#' } };
                            print!("{}", glyph_char);
                        }
                        println!();
                    }
                }
            }
        }
    }

    // The OS-fallback path: ฿ (Thai), ⊱ (math), ⽊ (Kangxi radical) —
    // all outside Px437 *and* Menlo. Core Text picks Thonburi /
    // Apple Symbols / PingFang respectively and produces a glyph.
    #[test]
    fn atlas_routes_to_core_text_for_chars_no_fontdue_font_carries() {
        let mut atlas = Atlas::new(1);
        for &probe in &['฿', '⊱', '⽊'] {
            assert!(!atlas.primary.has_glyph(probe), "premise: Px437 lacks {}", probe);
            let fb_has = atlas.fallback.as_ref().map_or(false, |f| f.has_glyph(probe));
            assert!(!fb_has, "premise: fontdue fallback lacks {} (is OS-only)", probe);
            let pixels = glyph_as_coverage(&mut atlas, probe);
            let ink_count = ink(&pixels);
            assert!(
                ink_count > 0,
                "Core Text fallback produced blank cell for {} (codepoint U+{:04X})",
                probe,
                probe as u32,
            );
        }
    }

    // 😀 lives only in Apple Color Emoji (SBIX). Drawing into the RGBA
    // bitmap context above lets Core Text rasterize the SBIX bitmaps —
    // we keep the *full* color data so the renderer paints the actual
    // smiley face rather than a coloured silhouette.
    #[test]
    fn atlas_renders_color_emoji_as_silhouette() {
        let mut atlas = Atlas::new(1);
        let glyph = atlas.glyph('😀');
        let pixels: Vec<u8> = match glyph {
            AtlasGlyph::Coverage(b) => b.clone(),
            AtlasGlyph::Color(p) => {
                // Color glyphs should have at least one pixel where R != G
                // or G != B — otherwise the renderer is silently emitting
                // a grayscale silhouette and the whole point of the Color
                // variant is moot.
                let any_color = p.iter().any(|&px| {
                    let r = (px >> 16) & 0xFF;
                    let g = (px >> 8) & 0xFF;
                    let b = px & 0xFF;
                    r != g || g != b
                });
                assert!(any_color, "expected color emoji to carry chromatic pixels");
                p.iter().map(|&px| (px >> 24) as u8).collect()
            }
        };
        assert_eq!(pixels.len(), (CELL_W_BASE * CELL_H_BASE) as usize);
        assert!(
            ink(&pixels) > 0,
            "Core Text should rasterize 😀's color emoji into a non-empty alpha silhouette",
        );
    }

    #[test]
    fn dump_a_bitmap_from_atlas() {
        // Visual sanity: stringify the bitmap so a regression that turns
        // 'A' into '?' or a blank cell is obvious from the test output.
        // Run with `cargo test -- --nocapture dump_a_bitmap_from_atlas`.
        let mut atlas = Atlas::new(1);
        let pixels = glyph_as_coverage(&mut atlas, 'A');
        let cw = CELL_W_BASE as usize;
        let ch = CELL_H_BASE as usize;
        println!("\nAtlas 'A' bitmap ({}x{}):", cw, ch);
        for y in 0..ch {
            print!("  ");
            for x in 0..cw {
                let v = pixels[y * cw + x];
                print!("{}", if v == 0 { '.' } else if v < 128 { '+' } else { '#' });
            }
            println!();
        }
        // Compute the row-by-row ink to be doubly sure 'A' has the
        // expected hourglass-ish profile (wider at bottom, narrow at top).
        let inked_rows: Vec<usize> = (0..ch)
            .map(|y| (0..cw).filter(|&x| pixels[y * cw + x] != 0).count())
            .collect();
        println!("inked-pixels-per-row: {:?}", inked_rows);
        assert!(inked_rows.iter().sum::<usize>() > 8, "'A' should have substantial ink");
    }

    #[test]
    fn wide_codepoints_take_one_grid_cell_not_two() {
        // The unicode-width shim forces width=1 for every printable codepoint;
        // alacritty's WIDE_CHAR / WIDE_CHAR_SPACER pair therefore never gets
        // emitted, which is what keeps the wrapper grid aligned with
        // turbokod's one-codepoint-per-column canvas. If anyone removes the
        // [patch.crates-io] in Cargo.toml, this test will fail loudly.
        use alacritty_terminal::event::VoidListener;
        use alacritty_terminal::term::cell::Flags;
        use alacritty_terminal::vte::ansi::Processor;

        let term_size = TermSize::new(20, 4);
        let mut term = Term::new(TermConfig::default(), &term_size, VoidListener);
        let mut parser = Processor::<alacritty_terminal::vte::ansi::StdSyncHandler>::new();
        // Emoji + CJK are the codepoints UAX #11 calls "Wide". With the shim
        // applied alacritty should treat them as 1 column.
        parser.advance(&mut term, "😀⽊X".as_bytes());
        let row = &term.grid()[Line(0)];
        assert_eq!(row[Column(0)].c, '😀');
        assert_eq!(row[Column(1)].c, '⽊');
        assert_eq!(row[Column(2)].c, 'X');
        for col in 0..3 {
            assert!(
                !row[Column(col)].flags.intersects(Flags::WIDE_CHAR | Flags::WIDE_CHAR_SPACER),
                "col {} unexpectedly carries a WIDE_CHAR/SPACER flag",
                col,
            );
        }
    }

    // Drive the same path render() takes: a Term parses bytes, cells go
    // into the grid, the renderer reads ``cell.c`` and asks the atlas for
    // a glyph. If the running app shows ``?`` for everything but this
    // test still produces ink, the divergence is somewhere we don't yet
    // suspect. If this test reproduces the bug, we've got it caged.
    #[test]
    fn end_to_end_term_to_atlas_for_ascii() {
        use alacritty_terminal::event::VoidListener;
        use alacritty_terminal::vte::ansi::Processor;

        let term_size = TermSize::new(20, 4);
        let mut term = Term::new(TermConfig::default(), &term_size, VoidListener);
        let mut parser = Processor::<alacritty_terminal::vte::ansi::StdSyncHandler>::new();
        let bytes = b"Hello, world!";
        parser.advance(&mut term, bytes);

        let grid = term.grid();
        let mut atlas = Atlas::new(1);
        let probes: &[(usize, char)] = &[
            (0, 'H'), (1, 'e'), (2, 'l'), (3, 'l'), (4, 'o'),
            (5, ','), (6, ' '), (7, 'w'), (8, 'o'), (9, 'r'),
            (10, 'l'), (11, 'd'), (12, '!'),
        ];
        for &(col, expected) in probes {
            let cell = &grid[Line(0)][Column(col)];
            assert_eq!(cell.c, expected, "term parser dropped char at col {}", col);
            let pixels = glyph_as_coverage(&mut atlas, cell.c);
            // Spaces are intentionally blank — skip the ink check there.
            if cell.c != ' ' {
                let ink_count = ink(&pixels);
                assert!(
                    ink_count > 0,
                    "atlas returned blank for '{}' (col {}) — running app would show empty",
                    cell.c,
                    col,
                );
            }
        }
    }

    #[test]
    fn scale_doubling_doubles_cell_bytes() {
        let mut atlas1 = Atlas::new(1);
        let mut atlas2 = Atlas::new(2);
        assert_eq!(
            glyph_as_coverage(&mut atlas1, 'A').len(),
            (CELL_W_BASE * CELL_H_BASE) as usize,
        );
        assert_eq!(
            glyph_as_coverage(&mut atlas2, 'A').len(),
            (CELL_W_BASE * 2 * CELL_H_BASE * 2) as usize,
        );
    }
}
