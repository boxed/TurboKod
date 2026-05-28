//! Native macOS frontend for turbokod, exposed over a C ABI.
//!
//! One process, one winit event loop, **N windows**. The Mojo side owns the
//! loop: each frame it calls `tk_app_pump` (advance winit, drain native
//! input events — each tagged with the window it targets) and, per window,
//! `tk_window_present` (push a cell grid, blit it). There are no escape
//! sequences and no terminal emulator: a Cmd+S keypress arrives from the OS
//! as a native key event and becomes a turbokod `Event` directly.
//!
//! Windows are created with `tk_app_open_window`, which returns a small
//! integer id. winit only lets you create a window from inside an event-loop
//! callback (it needs `&ActiveEventLoop`), so the ABI call queues the
//! request and pumps until `about_to_wait` materializes it.

#[cfg(target_os = "macos")]
mod menu;
mod render;

use std::num::NonZeroU32;
use std::sync::Arc;
use std::time::Duration;

use winit::application::ApplicationHandler;
use winit::dpi::PhysicalSize;
use winit::event::{ElementState, MouseButton, MouseScrollDelta, WindowEvent};
use winit::event_loop::{ActiveEventLoop, ControlFlow, EventLoop};
use winit::keyboard::{Key, ModifiersState, NamedKey};
use winit::platform::pump_events::EventLoopExtPumpEvents;
use winit::window::{CursorIcon, Window, WindowId};

use render::{build_palette, Atlas, RenderCell, UnderlineKind, CELL_H_BASE, CELL_W_BASE};

// --- Event kinds (match events.mojo EVENT_* where applicable) ---------------
const EV_KEY: u32 = 1;
const EV_MOUSE: u32 = 2;
const EV_RESIZE: u32 = 3;
const EV_CLOSE: u32 = 4;
const EV_FOCUS_IN: u32 = 7;
const EV_FOCUS_OUT: u32 = 8;
const EV_MOD_KEY: u32 = 9;

// Each event is 8 u32 words: [kind, win_id, p0, p1, p2, p3, p4, p5].
const EV_WORDS: usize = 8;

// --- Named-key ids carried in a key event's p0 (0 == "use codepoint") -------
const NK_ENTER: u32 = 1;
const NK_TAB: u32 = 2;
const NK_BACKSPACE: u32 = 3;
const NK_ESC: u32 = 4;
const NK_UP: u32 = 10;
const NK_DOWN: u32 = 11;
const NK_LEFT: u32 = 12;
const NK_RIGHT: u32 = 13;
const NK_HOME: u32 = 14;
const NK_END: u32 = 15;
const NK_PAGEUP: u32 = 16;
const NK_PAGEDOWN: u32 = 17;
const NK_INSERT: u32 = 18;
const NK_DELETE: u32 = 19;
const NK_F1: u32 = 30; // F1..F12 == 30..41

// --- Modifier bitmask (match events.mojo MOD_*) -----------------------------
const MOD_SHIFT: u32 = 1;
const MOD_ALT: u32 = 2;
const MOD_CTRL: u32 = 4;
const MOD_META: u32 = 8;

// --- Mouse buttons (match events.mojo MOUSE_*) ------------------------------
const MB_NONE: u32 = 0;
const MB_LEFT: u32 = 1;
const MB_MIDDLE: u32 = 2;
const MB_RIGHT: u32 = 3;
const MB_WHEEL_UP: u32 = 4;
const MB_WHEEL_DOWN: u32 = 5;

// --- Mouse flags ------------------------------------------------------------
const MF_PRESSED: u32 = 1;
const MF_MOTION: u32 = 2;

// --- Style bits (match colors.mojo STYLE_*) ---------------------------------
const STYLE_UNDERLINE: u32 = 1 << 3;
const STYLE_REVERSE: u32 = 1 << 4;
const STYLE_UNDERLINE_CURLY: u32 = 1 << 6;

// --- Modifier-key ids carried in EV_MOD_KEY (match events.mojo MOD_KEY_*) ---
const MODK_SHIFT: u32 = 1;
const MODK_ALT: u32 = 2;
const MODK_CTRL: u32 = 3;
const MODK_META: u32 = 4;

/// Per-window state. Each window has its own surface, glyph atlas (scale can
/// differ per display), grid size, and mouse tracking.
struct Win {
    id: u64,
    window: Arc<Window>,
    #[allow(dead_code)]
    context: softbuffer::Context<Arc<Window>>,
    surface: softbuffer::Surface<Arc<Window>, Arc<Window>>,
    atlas: Atlas,
    scale: u32,
    phys_w: u32,
    phys_h: u32,
    cols: u32,
    rows: u32,
    mouse_col: u32,
    mouse_row: u32,
    button_down: u32,
    last_pixels: Vec<u32>,
    last_w: u32,
    last_h: u32,
    // Last cell grid presented from Mojo, kept so we can re-blit it at a new
    // size during a macOS live-resize (when the modal resize loop blocks the
    // Mojo loop and present() can't be called).
    last_cells: Vec<RenderCell>,
    last_cols: u32,
    last_rows: u32,
}

impl Win {
    fn cell_w(&self) -> u32 {
        CELL_W_BASE * self.scale
    }
    fn cell_h(&self) -> u32 {
        CELL_H_BASE * self.scale
    }
    fn recompute_grid(&mut self) {
        let cw = self.cell_w().max(1);
        let ch = self.cell_h().max(1);
        self.cols = (self.phys_w / cw).max(1);
        self.rows = (self.phys_h / ch).max(1);
    }

    /// Re-blit the last presented cell grid at the current physical size and
    /// present. Called from inside the event loop on `Resized` /
    /// `RedrawRequested` — including during a macOS live resize, where this
    /// is the only place we get to draw. The old grid is painted top-left;
    /// the rest is the margin fill, so the window tracks the drag live
    /// instead of freezing. Mojo does the full reflow on the next pump.
    fn repaint_from_last(&mut self) {
        if self.last_cells.is_empty() {
            return;
        }
        let (pw, ph) = (self.phys_w, self.phys_h);
        let (Some(nw), Some(nh)) = (NonZeroU32::new(pw), NonZeroU32::new(ph)) else {
            return;
        };
        if self.surface.resize(nw, nh).is_err() {
            return;
        }
        let mut buf = match self.surface.buffer_mut() {
            Ok(b) => b,
            Err(_) => return,
        };
        render::paint(
            &mut self.atlas,
            &mut buf,
            pw as usize,
            ph as usize,
            &self.last_cells,
            self.last_cols as usize,
            self.last_rows as usize,
        );
        let snapshot: Vec<u32> = buf.to_vec();
        let _ = buf.present();
        self.last_pixels = snapshot;
        self.last_w = pw;
        self.last_h = ph;
    }
}

struct App {
    palette: [u32; 256],
    mods: ModifiersState, // keyboard modifiers are loop-global
    wins: Vec<Win>,
    pending_open: Vec<u64>,
    events: Vec<[u32; EV_WORDS]>,
    next_id: u64,
    menu_installed: bool,
}

impl App {
    fn new() -> Self {
        Self {
            palette: build_palette(),
            mods: ModifiersState::empty(),
            wins: Vec::new(),
            pending_open: Vec::new(),
            events: Vec::new(),
            next_id: 1,
            menu_installed: false,
        }
    }

    fn mods_mask(&self) -> u32 {
        let mut m = 0;
        if self.mods.shift_key() {
            m |= MOD_SHIFT;
        }
        if self.mods.alt_key() {
            m |= MOD_ALT;
        }
        if self.mods.control_key() {
            m |= MOD_CTRL;
        }
        if self.mods.super_key() {
            m |= MOD_META;
        }
        m
    }

    fn win_index(&self, id: u64) -> Option<usize> {
        self.wins.iter().position(|w| w.id == id)
    }

    fn win_index_by_handle(&self, wid: WindowId) -> Option<usize> {
        self.wins.iter().position(|w| w.window.id() == wid)
    }

    /// Materialize any windows requested via `tk_app_open_window`. Must run
    /// inside an event-loop callback (needs `&ActiveEventLoop`).
    fn create_pending(&mut self, el: &ActiveEventLoop) {
        if self.pending_open.is_empty() {
            return;
        }
        let ids: Vec<u64> = std::mem::take(&mut self.pending_open);
        for id in ids {
            let attrs = Window::default_attributes()
                .with_title("TurboKod")
                .with_inner_size(PhysicalSize::new(1000u32, 640u32));
            let window = match el.create_window(attrs) {
                Ok(w) => Arc::new(w),
                Err(_) => continue,
            };
            let scale = (window.scale_factor().round() as u32).clamp(1, 8);
            let atlas = Atlas::new(scale);
            let size = window.inner_size();
            let context = match softbuffer::Context::new(window.clone()) {
                Ok(c) => c,
                Err(_) => continue,
            };
            let surface = match softbuffer::Surface::new(&context, window.clone()) {
                Ok(s) => s,
                Err(_) => continue,
            };
            let mut w = Win {
                id,
                window,
                context,
                surface,
                atlas,
                scale,
                phys_w: size.width,
                phys_h: size.height,
                cols: 80,
                rows: 25,
                mouse_col: 0,
                mouse_row: 0,
                button_down: MB_NONE,
                last_pixels: Vec::new(),
                last_w: 0,
                last_h: 0,
                last_cells: Vec::new(),
                last_cols: 0,
                last_rows: 0,
            };
            w.recompute_grid();
            self.wins.push(w);
        }
    }
}

impl ApplicationHandler for App {
    fn resumed(&mut self, el: &ActiveEventLoop) {
        el.set_control_flow(ControlFlow::Wait);
        // Install the native menu bar once, now that winit has created NSApp.
        if !self.menu_installed {
            self.menu_installed = true;
            #[cfg(target_os = "macos")]
            menu::install_main_menu();
        }
        self.create_pending(el);
    }

    fn about_to_wait(&mut self, el: &ActiveEventLoop) {
        self.create_pending(el);
    }

    fn window_event(&mut self, _el: &ActiveEventLoop, wid: WindowId, event: WindowEvent) {
        let idx = match self.win_index_by_handle(wid) {
            Some(i) => i,
            None => return,
        };
        let win_id = self.wins[idx].id as u32;
        match event {
            WindowEvent::CloseRequested => {
                self.events.push([EV_CLOSE, win_id, 0, 0, 0, 0, 0, 0]);
            }
            WindowEvent::Resized(size) => {
                let w = &mut self.wins[idx];
                w.phys_w = size.width;
                w.phys_h = size.height;
                let old = (w.cols, w.rows);
                w.recompute_grid();
                let new = (w.cols, w.rows);
                // Draw immediately at the new size — during a live resize this
                // is the only chance we get, since the modal resize loop keeps
                // the Mojo pump from running until the drag ends.
                w.repaint_from_last();
                if new != old {
                    self.events
                        .push([EV_RESIZE, win_id, new.0, new.1, 0, 0, 0, 0]);
                }
            }
            WindowEvent::RedrawRequested => {
                self.wins[idx].repaint_from_last();
            }
            WindowEvent::ScaleFactorChanged { scale_factor, .. } => {
                let new_scale = (scale_factor.round() as u32).clamp(1, 8);
                let w = &mut self.wins[idx];
                if new_scale != w.scale {
                    w.scale = new_scale;
                    w.atlas = Atlas::new(new_scale);
                    w.recompute_grid();
                    self.events
                        .push([EV_RESIZE, win_id, w.cols, w.rows, 0, 0, 0, 0]);
                }
            }
            WindowEvent::Focused(focused) => {
                self.events.push([
                    if focused { EV_FOCUS_IN } else { EV_FOCUS_OUT },
                    win_id,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                ]);
            }
            WindowEvent::ModifiersChanged(m) => {
                self.mods = m.state();
            }
            WindowEvent::KeyboardInput { event, .. } => {
                let pressed = event.state == ElementState::Pressed;
                let mods = self.mods_mask();
                if let Key::Named(nk) = event.logical_key {
                    let modk = match nk {
                        NamedKey::Shift => Some(MODK_SHIFT),
                        NamedKey::Alt => Some(MODK_ALT),
                        NamedKey::Control => Some(MODK_CTRL),
                        NamedKey::Super => Some(MODK_META),
                        _ => None,
                    };
                    if let Some(id) = modk {
                        self.events
                            .push([EV_MOD_KEY, win_id, id, pressed as u32, 0, 0, 0, 0]);
                        return;
                    }
                }
                if !pressed {
                    return;
                }
                match event.logical_key {
                    Key::Named(nk) => {
                        let named = match nk {
                            NamedKey::Enter => NK_ENTER,
                            NamedKey::Tab => NK_TAB,
                            NamedKey::Backspace => NK_BACKSPACE,
                            NamedKey::Escape => NK_ESC,
                            NamedKey::ArrowUp => NK_UP,
                            NamedKey::ArrowDown => NK_DOWN,
                            NamedKey::ArrowLeft => NK_LEFT,
                            NamedKey::ArrowRight => NK_RIGHT,
                            NamedKey::Home => NK_HOME,
                            NamedKey::End => NK_END,
                            NamedKey::PageUp => NK_PAGEUP,
                            NamedKey::PageDown => NK_PAGEDOWN,
                            NamedKey::Insert => NK_INSERT,
                            NamedKey::Delete => NK_DELETE,
                            NamedKey::Space => {
                                self.events
                                    .push([EV_KEY, win_id, 0, 0x20, mods, 0, 0, 0]);
                                return;
                            }
                            NamedKey::F1 => NK_F1,
                            NamedKey::F2 => NK_F1 + 1,
                            NamedKey::F3 => NK_F1 + 2,
                            NamedKey::F4 => NK_F1 + 3,
                            NamedKey::F5 => NK_F1 + 4,
                            NamedKey::F6 => NK_F1 + 5,
                            NamedKey::F7 => NK_F1 + 6,
                            NamedKey::F8 => NK_F1 + 7,
                            NamedKey::F9 => NK_F1 + 8,
                            NamedKey::F10 => NK_F1 + 9,
                            NamedKey::F11 => NK_F1 + 10,
                            NamedKey::F12 => NK_F1 + 11,
                            _ => return,
                        };
                        self.events
                            .push([EV_KEY, win_id, named, 0, mods, 0, 0, 0]);
                    }
                    Key::Character(s) => {
                        if let Some(c) = s.chars().next() {
                            self.events
                                .push([EV_KEY, win_id, 0, c as u32, mods, 0, 0, 0]);
                        }
                    }
                    _ => {}
                }
            }
            WindowEvent::CursorMoved { position, .. } => {
                let mods = self.mods_mask();
                let w = &mut self.wins[idx];
                let cw = w.cell_w().max(1);
                let ch = w.cell_h().max(1);
                let col = (position.x.max(0.0) as u32) / cw;
                let row = (position.y.max(0.0) as u32) / ch;
                if col == w.mouse_col && row == w.mouse_row {
                    return;
                }
                w.mouse_col = col;
                w.mouse_row = row;
                let (button, flags) = if w.button_down != MB_NONE {
                    (w.button_down, MF_MOTION | MF_PRESSED)
                } else {
                    (MB_NONE, MF_MOTION)
                };
                self.events
                    .push([EV_MOUSE, win_id, col, row, button, flags, mods, 0]);
            }
            WindowEvent::MouseInput { state, button, .. } => {
                let b = match button {
                    MouseButton::Left => MB_LEFT,
                    MouseButton::Middle => MB_MIDDLE,
                    MouseButton::Right => MB_RIGHT,
                    _ => return,
                };
                let mods = self.mods_mask();
                let pressed = state == ElementState::Pressed;
                let flags = if pressed { MF_PRESSED } else { 0 };
                let w = &mut self.wins[idx];
                w.button_down = if pressed { b } else { MB_NONE };
                let (mc, mr) = (w.mouse_col, w.mouse_row);
                self.events
                    .push([EV_MOUSE, win_id, mc, mr, b, flags, mods, 0]);
            }
            WindowEvent::MouseWheel { delta, .. } => {
                let up = match delta {
                    MouseScrollDelta::LineDelta(_, y) => y > 0.0,
                    MouseScrollDelta::PixelDelta(p) => p.y > 0.0,
                };
                let button = if up { MB_WHEEL_UP } else { MB_WHEEL_DOWN };
                let mods = self.mods_mask();
                let w = &self.wins[idx];
                let (mc, mr) = (w.mouse_col, w.mouse_row);
                self.events
                    .push([EV_MOUSE, win_id, mc, mr, button, MF_PRESSED, mods, 0]);
            }
            _ => {}
        }
    }
}

/// Owns the winit event loop and the application handler. Opaque to Mojo.
pub struct RenderState {
    event_loop: EventLoop<()>,
    app: App,
}

impl RenderState {
    fn pump(&mut self, timeout_ms: u32) {
        let RenderState { event_loop, app } = self;
        let _ = event_loop.pump_app_events(Some(Duration::from_millis(timeout_ms as u64)), app);
    }
}

// --- C ABI ------------------------------------------------------------------

/// Create the app (event loop), with no windows yet. Pump once so the loop
/// resumes and is ready to create windows.
#[no_mangle]
pub extern "C" fn tk_app_create() -> *mut RenderState {
    let event_loop = match EventLoop::new() {
        Ok(el) => el,
        Err(_) => return std::ptr::null_mut(),
    };
    let mut state = Box::new(RenderState {
        event_loop,
        app: App::new(),
    });
    state.pump(8);
    Box::into_raw(state)
}

/// Open a new window; returns its id (>= 1), or 0 on failure.
#[no_mangle]
pub extern "C" fn tk_app_open_window(state: *mut RenderState) -> u32 {
    if state.is_null() {
        return 0;
    }
    let st = unsafe { &mut *state };
    let id = st.app.next_id;
    st.app.next_id += 1;
    st.app.pending_open.push(id);
    for _ in 0..32 {
        st.pump(8);
        if st.app.win_index(id).is_some() {
            return id as u32;
        }
    }
    0
}

/// Advance the loop by up to `timeout_ms`, then copy up to `max_events`
/// pending events into `out` (8 u32 words each). Returns the count.
#[no_mangle]
pub extern "C" fn tk_app_pump(
    state: *mut RenderState,
    timeout_ms: u32,
    out: *mut u32,
    max_events: u32,
) -> u32 {
    if state.is_null() {
        return 0;
    }
    let st = unsafe { &mut *state };
    st.pump(timeout_ms);
    // Native "File ▸ New Window" menu clicks (and ⌘N, which the menu now
    // owns) arrive as a counter; replay each as the same Cmd+N key event the
    // Mojo loop already handles (win 0 = "not a specific window"). 110 = 'n'.
    #[cfg(target_os = "macos")]
    {
        let new_windows = menu::pending_new_windows();
        for _ in 0..new_windows {
            st.app.events.push([EV_KEY, 0, 0, 110, MOD_META, 0, 0, 0]);
        }
    }
    let n = st.app.events.len().min(max_events as usize);
    if n == 0 {
        return 0;
    }
    if out.is_null() {
        st.app.events.drain(..n);
        return 0;
    }
    let slice = unsafe { std::slice::from_raw_parts_mut(out, n * EV_WORDS) };
    for (i, ev) in st.app.events.drain(..n).enumerate() {
        slice[i * EV_WORDS..i * EV_WORDS + EV_WORDS].copy_from_slice(&ev);
    }
    n as u32
}

fn unpack_cells(words: &[u32], palette: &[u32; 256], cols: u32, rows: u32) -> Vec<RenderCell> {
    let n = (cols as usize) * (rows as usize);
    let mut grid: Vec<RenderCell> = Vec::with_capacity(n);
    for i in 0..n {
        let base = i * 3;
        if base + 2 >= words.len() {
            break;
        }
        let cp = words[base];
        let packed = words[base + 1];
        let uc = words[base + 2];
        let fg_idx = (packed & 0xFF) as usize;
        let bg_idx = ((packed >> 8) & 0xFF) as usize;
        let style = (packed >> 16) & 0xFF;
        let mut fg = palette[fg_idx];
        let mut bg = palette[bg_idx];
        if style & STYLE_REVERSE != 0 {
            std::mem::swap(&mut fg, &mut bg);
        }
        let underline = if style & STYLE_UNDERLINE != 0 {
            if style & STYLE_UNDERLINE_CURLY != 0 {
                UnderlineKind::Curly
            } else {
                UnderlineKind::Plain
            }
        } else {
            UnderlineKind::None
        };
        let underline_color = if uc == 0xFFFF_FFFF {
            fg
        } else {
            palette[(uc & 0xFF) as usize]
        };
        grid.push(RenderCell {
            c: char::from_u32(cp).unwrap_or(' '),
            fg,
            bg,
            underline,
            underline_color,
        });
    }
    grid
}

/// Push a `cols`×`rows` cell grid to window `win_id` and present it.
#[no_mangle]
pub extern "C" fn tk_window_present(
    state: *mut RenderState,
    win_id: u32,
    cells: *const u32,
    word_count: u32,
    cols: u32,
    rows: u32,
) {
    if state.is_null() || cells.is_null() {
        return;
    }
    let st = unsafe { &mut *state };
    let idx = match st.app.win_index(win_id as u64) {
        Some(i) => i,
        None => return,
    };
    let words = unsafe { std::slice::from_raw_parts(cells, word_count as usize) };
    let grid = unpack_cells(words, &st.app.palette, cols, rows);

    let w = &mut st.app.wins[idx];
    let (pw, ph) = (w.phys_w, w.phys_h);
    if pw == 0 || ph == 0 {
        return;
    }
    // Stash the grid first so a live-resize re-blit (Win::repaint_from_last)
    // has the freshest layout to fit to the new size.
    w.last_cells = grid;
    w.last_cols = cols;
    w.last_rows = rows;
    let (Some(nw), Some(nh)) = (NonZeroU32::new(pw), NonZeroU32::new(ph)) else {
        return;
    };
    if w.surface.resize(nw, nh).is_err() {
        return;
    }
    let mut buf = match w.surface.buffer_mut() {
        Ok(b) => b,
        Err(_) => return,
    };
    render::paint(
        &mut w.atlas,
        &mut buf,
        pw as usize,
        ph as usize,
        &w.last_cells,
        cols as usize,
        rows as usize,
    );
    let snapshot: Vec<u32> = buf.to_vec();
    let _ = buf.present();
    w.last_pixels = snapshot;
    w.last_w = pw;
    w.last_h = ph;
}

/// Current grid dimensions of `win_id`.
#[no_mangle]
pub extern "C" fn tk_window_size(
    state: *mut RenderState,
    win_id: u32,
    out_cols: *mut u32,
    out_rows: *mut u32,
) {
    if state.is_null() {
        return;
    }
    let st = unsafe { &mut *state };
    if let Some(i) = st.app.win_index(win_id as u64) {
        let w = &st.app.wins[i];
        if !out_cols.is_null() {
            unsafe { *out_cols = w.cols };
        }
        if !out_rows.is_null() {
            unsafe { *out_rows = w.rows };
        }
    }
}

/// Set `win_id`'s title from a UTF-8 byte buffer.
#[no_mangle]
pub extern "C" fn tk_window_set_title(
    state: *mut RenderState,
    win_id: u32,
    ptr: *const u8,
    len: u32,
) {
    if state.is_null() || ptr.is_null() {
        return;
    }
    let st = unsafe { &mut *state };
    if let Some(i) = st.app.win_index(win_id as u64) {
        let bytes = unsafe { std::slice::from_raw_parts(ptr, len as usize) };
        if let Ok(title) = std::str::from_utf8(bytes) {
            st.app.wins[i].window.set_title(title);
        }
    }
}

/// Set the mouse cursor icon for `win_id`. shape: 0=default, 1=text,
/// 2=pointer (matches Desktop.pointer_shape_at's string vocabulary).
#[no_mangle]
pub extern "C" fn tk_window_set_cursor(state: *mut RenderState, win_id: u32, shape: u32) {
    if state.is_null() {
        return;
    }
    let st = unsafe { &mut *state };
    if let Some(i) = st.app.win_index(win_id as u64) {
        let icon = match shape {
            1 => CursorIcon::Text,
            2 => CursorIcon::Pointer,
            _ => CursorIcon::Default,
        };
        st.app.wins[i].window.set_cursor(icon);
    }
}

/// Write the last presented frame of `win_id` as a 24-bit BMP. Returns 0 on
/// success, -1 on failure. Lets tests verify rendering without the Screen
/// Recording grant `screencapture` needs.
#[no_mangle]
pub extern "C" fn tk_window_capture_bmp(
    state: *mut RenderState,
    win_id: u32,
    path: *const u8,
    len: u32,
) -> i32 {
    if state.is_null() || path.is_null() {
        return -1;
    }
    let st = unsafe { &mut *state };
    let idx = match st.app.win_index(win_id as u64) {
        Some(i) => i,
        None => return -1,
    };
    let w = &st.app.wins[idx];
    let (width, height) = (w.last_w as usize, w.last_h as usize);
    if width == 0 || height == 0 || w.last_pixels.len() < width * height {
        return -1;
    }
    let path_bytes = unsafe { std::slice::from_raw_parts(path, len as usize) };
    let path = match std::str::from_utf8(path_bytes) {
        Ok(p) => p,
        Err(_) => return -1,
    };

    let row_stride = width * 3;
    let pad = (4 - (row_stride % 4)) % 4;
    let padded = row_stride + pad;
    let pixel_data = padded * height;
    let file_size = 54 + pixel_data;

    let mut out: Vec<u8> = Vec::with_capacity(file_size);
    out.extend_from_slice(b"BM");
    out.extend_from_slice(&(file_size as u32).to_le_bytes());
    out.extend_from_slice(&0u32.to_le_bytes());
    out.extend_from_slice(&54u32.to_le_bytes());
    out.extend_from_slice(&40u32.to_le_bytes());
    out.extend_from_slice(&(width as i32).to_le_bytes());
    out.extend_from_slice(&(height as i32).to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&24u16.to_le_bytes());
    out.extend_from_slice(&0u32.to_le_bytes());
    out.extend_from_slice(&(pixel_data as u32).to_le_bytes());
    out.extend_from_slice(&2835i32.to_le_bytes());
    out.extend_from_slice(&2835i32.to_le_bytes());
    out.extend_from_slice(&0u32.to_le_bytes());
    out.extend_from_slice(&0u32.to_le_bytes());

    for y in (0..height).rev() {
        let base = y * width;
        for x in 0..width {
            let px = w.last_pixels[base + x];
            out.push((px & 0xFF) as u8);
            out.push(((px >> 8) & 0xFF) as u8);
            out.push(((px >> 16) & 0xFF) as u8);
        }
        for _ in 0..pad {
            out.push(0);
        }
    }

    match std::fs::write(path, &out) {
        Ok(_) => 0,
        Err(_) => -1,
    }
}

/// Close and drop window `win_id`. The window vanishes from the screen.
#[no_mangle]
pub extern "C" fn tk_window_close(state: *mut RenderState, win_id: u32) {
    if state.is_null() {
        return;
    }
    let st = unsafe { &mut *state };
    if let Some(i) = st.app.win_index(win_id as u64) {
        st.app.wins.remove(i);
    }
}

/// Number of currently-open windows.
#[no_mangle]
pub extern "C" fn tk_app_window_count(state: *mut RenderState) -> u32 {
    if state.is_null() {
        return 0;
    }
    let st = unsafe { &mut *state };
    st.app.wins.len() as u32
}

/// Destroy the app, closing all windows and freeing the handle.
#[no_mangle]
pub extern "C" fn tk_app_destroy(state: *mut RenderState) {
    if state.is_null() {
        return;
    }
    unsafe {
        drop(Box::from_raw(state));
    }
}

#[allow(dead_code)]
const _ABI_PARITY: u32 = MB_NONE + MODK_SHIFT + MODK_ALT + MODK_CTRL + MODK_META;
