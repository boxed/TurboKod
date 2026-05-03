//! AppKit-level keyboard intercept for shortcuts AppKit normally swallows.
//!
//! macOS hands several Cmd-modified keys to NSApplication's built-in
//! handlers before the responder chain ever fires `keyDown:`. Cmd+` is the
//! big one — AppKit binds it to "Cycle through windows" application-wide,
//! and the event never reaches winit's keyDown hook regardless of whether
//! the app actually has multiple windows. Without an interception path the
//! shortcut is effectively unbindable in our embedded TUI.
//!
//! Solution: install an `+[NSEvent addLocalMonitorForEventsMatchingMask:handler:]`
//! block that runs *before* AppKit's built-in handling. When the event
//! matches Cmd+\` or Cmd+Shift+\`, we synthesise the same xterm
//! modifyOtherKeys envelope `App::on_key` would otherwise emit, push it
//! straight to the PTY, and return nil to consume the event. Any other
//! event passes through unchanged.
//!
//! The block is set up as a "global" block (no captures) so we don't have
//! to deal with copy/dispose helpers — the `EventLoopSender` lives in a
//! `OnceLock<Mutex<…>>` the invoke function reads on each call.

#![cfg(target_os = "macos")]

use std::ffi::{c_char, c_int, c_long, c_ulong, c_void, CStr};
use std::sync::{Mutex, OnceLock};

use alacritty_terminal::event_loop::{EventLoopSender, Msg};

// --- Objective-C runtime FFI -----------------------------------------------
type ObjcId = c_void;
type ObjcSel = c_void;
type ObjcClass = c_void;

#[link(name = "objc", kind = "dylib")]
unsafe extern "C" {
    fn objc_getClass(name: *const c_char) -> *mut ObjcClass;
    fn sel_registerName(name: *const c_char) -> *mut ObjcSel;
    fn objc_msgSend();
}

// --- Block runtime FFI -----------------------------------------------------
//
// We construct a "global" block — flags has BLOCK_IS_GLOBAL set, isa points
// at _NSConcreteGlobalBlock, no captured variables. AppKit treats global
// blocks as if they were already on the heap (no copy is performed), so
// the descriptor only needs `reserved` and `size`; the longer
// `BLOCK_HAS_COPY_DISPOSE`/`BLOCK_HAS_SIGNATURE` layout that stack blocks
// require is not needed here.
#[link(name = "System", kind = "dylib")]
unsafe extern "C" {
    static _NSConcreteGlobalBlock: c_void;
}

#[repr(C)]
struct BlockDescriptor {
    reserved: c_ulong,
    size: c_ulong,
}

#[repr(C)]
struct GlobalBlock {
    isa: *const c_void,
    flags: c_int,
    reserved: c_int,
    invoke: extern "C" fn(*const c_void, *const c_void) -> *const c_void,
    descriptor: *const BlockDescriptor,
}

// SAFETY: GlobalBlock is read-only after `install()` finishes constructing
// it, and the pointers it carries (isa, descriptor, invoke) all point at
// fully-initialised statics or extern symbols.
unsafe impl Sync for GlobalBlock {}
unsafe impl Send for GlobalBlock {}

const BLOCK_IS_GLOBAL: c_int = 1 << 28;

// NSEventMaskKeyDown = 1 << NSEventTypeKeyDown (= 10).
const NSEVENT_MASK_KEY_DOWN: c_long = 1 << 10;
// Modifier flag bits within NSEvent.modifierFlags.
const NSEVENT_FLAG_SHIFT: c_long = 1 << 17;
const NSEVENT_FLAG_COMMAND: c_long = 1 << 20;
// "Device-independent" modifier mask — strips the keyboard-layout-specific
// low 16 bits so we only see Cmd / Shift / Ctrl / Alt, not the raw key code
// flags AppKit folds in.
const NSEVENT_DEVICE_INDEPENDENT_MODIFIERS_MASK: c_long = 0xFFFF_0000;

static SENDER: OnceLock<Mutex<EventLoopSender>> = OnceLock::new();

static BLOCK_DESCRIPTOR: BlockDescriptor = BlockDescriptor {
    reserved: 0,
    size: std::mem::size_of::<GlobalBlock>() as c_ulong,
};

// `_NSConcreteGlobalBlock` is an extern static — its address isn't a const
// expression, so the block has to be assembled at runtime in `install()`
// and parked behind a `OnceLock`.
static MONITOR_BLOCK: OnceLock<&'static GlobalBlock> = OnceLock::new();

/// Install the local key-event monitor. Idempotent — calling more than
/// once just keeps the first sender; the AppKit-side monitor is only
/// added on the first invocation.
pub fn install(sender: EventLoopSender) {
    let _ = SENDER.set(Mutex::new(sender));
    let block = MONITOR_BLOCK.get_or_init(|| {
        let b = Box::new(GlobalBlock {
            isa: unsafe { &_NSConcreteGlobalBlock },
            flags: BLOCK_IS_GLOBAL,
            reserved: 0,
            invoke: monitor_invoke,
            descriptor: &BLOCK_DESCRIPTOR,
        });
        Box::leak(b)
    });
    // First-call-wins on the AppKit side too: a second call would re-register
    // a duplicate monitor that fires alongside the first.
    static INSTALLED: OnceLock<()> = OnceLock::new();
    if INSTALLED.set(()).is_err() {
        return;
    }
    unsafe {
        let nsevent_class = objc_getClass(c"NSEvent".as_ptr());
        if nsevent_class.is_null() {
            return;
        }
        let sel = sel_registerName(
            c"addLocalMonitorForEventsMatchingMask:handler:".as_ptr(),
        );
        let func: unsafe extern "C" fn(
            *mut ObjcClass,
            *mut ObjcSel,
            c_long,
            *const GlobalBlock,
        ) -> *mut ObjcId = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        let _monitor = func(nsevent_class, sel, NSEVENT_MASK_KEY_DOWN, *block);
    }
}

// Block invoke function. Called by AppKit on the main thread for every
// keyDown event before the responder chain dispatches it. Return the
// event to let it propagate, or null to consume it.
extern "C" fn monitor_invoke(_block: *const c_void, event: *const c_void) -> *const c_void {
    if event.is_null() {
        return event;
    }
    // SAFETY: AppKit only calls this with valid NSEvent objects on the
    // main thread; we never store the pointer past this call.
    unsafe {
        if !should_intercept(event) {
            return event;
        }
        if let Some((cp, mod_param)) = match_backtick_event(event) {
            let envelope = format!("\x1b[27;{};{}~", mod_param, cp);
            if let Some(lock) = SENDER.get() {
                if let Ok(sender) = lock.lock() {
                    let _ = sender.send(Msg::Input(envelope.into_bytes().into()));
                }
            }
            return std::ptr::null();
        }
        event
    }
}

/// Quick filter: do the modifiers say this event might be one we want to
/// claim? Cheap pre-check that avoids the NSString allocation cost of
/// reading `charactersIgnoringModifiers` for every keystroke.
unsafe fn should_intercept(event: *const c_void) -> bool {
    let sel = unsafe { sel_registerName(c"modifierFlags".as_ptr()) };
    let func: unsafe extern "C" fn(*const c_void, *mut ObjcSel) -> c_long =
        unsafe { std::mem::transmute(objc_msgSend as unsafe extern "C" fn()) };
    let raw = unsafe { func(event, sel) };
    let masked = raw & NSEVENT_DEVICE_INDEPENDENT_MODIFIERS_MASK;
    if masked & NSEVENT_FLAG_COMMAND == 0 {
        return false;
    }
    // We accept Cmd alone or Cmd+Shift; reject events that also carry
    // Ctrl or Alt so plain Cmd+Ctrl+\` etc still flow through unchanged.
    let allowed = NSEVENT_FLAG_COMMAND | NSEVENT_FLAG_SHIFT;
    masked & !allowed == 0
}

/// Read `charactersIgnoringModifiers` and return `(codepoint, mod_param)`
/// if this is Cmd+\` or Cmd+Shift+\`. The codepoint is what we tell the
/// embedded turbokod the key cap was — backtick (0x60) for the unshifted
/// form, tilde (0x7E) for the shifted one — and `mod_param` matches the
/// xterm modifyOtherKeys=2 numbering Mojo's terminal parser expects
/// (`1 + Shift + 8*Meta`).
unsafe fn match_backtick_event(event: *const c_void) -> Option<(u32, u32)> {
    let sel_chars = unsafe {
        sel_registerName(c"charactersIgnoringModifiers".as_ptr())
    };
    let chars_fn: unsafe extern "C" fn(*const c_void, *mut ObjcSel) -> *const c_void =
        unsafe { std::mem::transmute(objc_msgSend as unsafe extern "C" fn()) };
    let nsstring = unsafe { chars_fn(event, sel_chars) };
    if nsstring.is_null() {
        return None;
    }
    let sel_utf8 = unsafe { sel_registerName(c"UTF8String".as_ptr()) };
    let utf8_fn: unsafe extern "C" fn(*const c_void, *mut ObjcSel) -> *const c_char =
        unsafe { std::mem::transmute(objc_msgSend as unsafe extern "C" fn()) };
    let utf8 = unsafe { utf8_fn(nsstring, sel_utf8) };
    if utf8.is_null() {
        return None;
    }
    let bytes = unsafe { CStr::from_ptr(utf8) }.to_bytes();
    // Single-byte ASCII match. `charactersIgnoringModifiers` reports the
    // Shift-applied character (~ on US layout for Cmd+Shift+\`), so we
    // accept both glyphs and let the embedded app key its hotkey table
    // off whichever codepoint matches its layout.
    let cp: u32 = match bytes {
        b"`" => 0x60,
        b"~" => 0x7E,
        _ => return None,
    };
    let sel_flags = unsafe { sel_registerName(c"modifierFlags".as_ptr()) };
    let flags_fn: unsafe extern "C" fn(*const c_void, *mut ObjcSel) -> c_long =
        unsafe { std::mem::transmute(objc_msgSend as unsafe extern "C" fn()) };
    let flags = unsafe { flags_fn(event, sel_flags) }
        & NSEVENT_DEVICE_INDEPENDENT_MODIFIERS_MASK;
    let shift = (flags & NSEVENT_FLAG_SHIFT) != 0;
    // 1 + (shift ? 1 : 0) + 8 (meta).
    let mod_param = 1 + if shift { 1 } else { 0 } + 8;
    Some((cp, mod_param))
}
