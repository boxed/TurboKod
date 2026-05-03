//! macOS URL-scheme glue.
//!
//! When the app is bundled as a ``.app`` and its ``Info.plist`` declares
//! ``CFBundleURLTypes`` with ``CFBundleURLSchemes = ["turbokod"]``,
//! LaunchServices routes ``turbokod://...`` URLs (clicked in a browser,
//! pasted in Slack, opened by Finder, ...) to the registered app
//! through an Apple Event of class/id ``GURL/GURL`` (kAEGetURL).
//!
//! Cocoa apps usually catch the event via
//! ``NSAppleEventManager.setEventHandler:andSelector:forEventClass:andEventID:``
//! installed from the application delegate. winit owns the
//! ``NSApplicationDelegate`` here, so we install the handler directly
//! through Carbon's ``AEInstallEventHandler`` — same underlying hook,
//! no objc dance — *before* ``NSApp.run()`` starts pumping events.
//!
//! When a URL arrives, the handler reads the ``keyDirectObject`` as
//! UTF-8, runs it through ``parse_turbokod_url`` / ``translate_open_arg``
//! (defined in ``main.rs``), and routes the result through the same
//! ``UserEvent::OpenPaths`` channel the single-instance socket uses.
//! That makes "URL clicked in a browser" and "``turbokod foo.txt`` from
//! a shell" arrive at exactly the same code path on the Mojo side.
//!
//! Cold-launch URLs (the OS launched the app *because* of a URL) work
//! because the AE arrives shortly after ``NSApp.run`` starts; the
//! winit ``EventLoopProxy`` queues the ``OpenPaths`` event until the
//! event loop is ready to deliver it.

#![cfg(target_os = "macos")]

use std::ffi::c_void;
use std::path::PathBuf;
use std::sync::OnceLock;

use winit::event_loop::EventLoopProxy;

use crate::{translate_open_arg, UserEvent};

// FourCharCode constants. These are big-endian-packed ASCII tetragrams
// that Carbon uses for event class / event ID / type tags.
type FourCharCode = u32;
type OSErr = i16;
type DescType = FourCharCode;
type AEEventClass = FourCharCode;
type AEEventID = FourCharCode;
type AEKeyword = FourCharCode;
type SRefCon = isize;

const fn fcc(s: &[u8; 4]) -> u32 {
    ((s[0] as u32) << 24) | ((s[1] as u32) << 16) | ((s[2] as u32) << 8) | (s[3] as u32)
}

// Apple Events vocabulary.
//   kInternetEventClass = 'GURL' — Internet-related events.
//   kAEGetURL           = 'GURL' — "Get URL" (yes, same fourcc).
//   keyDirectObject     = '----' — the event's main argument slot.
//   typeUTF8Text        = 'utf8' — request payload as UTF-8 bytes.
const K_INTERNET_EVENT_CLASS: AEEventClass = fcc(b"GURL");
const K_AE_GET_URL: AEEventID = fcc(b"GURL");
const KEY_DIRECT_OBJECT: AEKeyword = fcc(b"----");
const TYPE_UTF8_TEXT: DescType = fcc(b"utf8");

#[repr(C)]
#[allow(non_snake_case)]
struct AEDesc {
    descriptorType: DescType,
    dataHandle: *mut c_void,
}

type AppleEvent = AEDesc;

type AEEventHandlerProcPtr =
    unsafe extern "C" fn(*const AppleEvent, *mut AppleEvent, SRefCon) -> OSErr;

#[link(name = "CoreServices", kind = "framework")]
unsafe extern "C" {
    fn AEInstallEventHandler(
        eventClass: AEEventClass,
        eventID: AEEventID,
        handler: AEEventHandlerProcPtr,
        handlerRefcon: SRefCon,
        isSysHandler: u8,
    ) -> OSErr;

    fn AEGetParamPtr(
        ae: *const AppleEvent,
        keyword: AEKeyword,
        desiredType: DescType,
        actualType: *mut DescType,
        dataPtr: *mut c_void,
        maximumSize: isize,
        actualSize: *mut isize,
    ) -> OSErr;
}

// The Apple Event handler is a plain C function pointer with no captures
// — it has to look up the proxy through a global slot. ``OnceLock``
// keeps the install side-effect-free until ``register`` is called and
// makes the handler a no-op if it ever fires before install (it can't
// in our flow, but defensive is cheap).
static PROXY: OnceLock<EventLoopProxy<UserEvent>> = OnceLock::new();

/// Install the kAEGetURL handler. Call once at startup, before
/// ``NSApp.run()`` (i.e., before ``EventLoop::run_app``). Subsequent
/// calls overwrite the proxy slot but ``AEInstallEventHandler`` itself
/// only registers the C function once with the OS.
pub fn register(proxy: EventLoopProxy<UserEvent>) {
    // ``set`` returns ``Err`` if already initialized — silently keep
    // the first proxy. In practice ``register`` is called from
    // ``main`` exactly once.
    let _ = PROXY.set(proxy);
    unsafe {
        // ``isSysHandler = 0`` → app-scoped handler. Returning a
        // negative OSErr would fall through to LaunchServices' default
        // behavior; we accept (return ``noErr``) regardless of how
        // the URL handling itself went.
        AEInstallEventHandler(
            K_INTERNET_EVENT_CLASS,
            K_AE_GET_URL,
            handle_get_url,
            0,
            0,
        );
    }
}

unsafe extern "C" fn handle_get_url(
    event: *const AppleEvent,
    _reply: *mut AppleEvent,
    _refcon: SRefCon,
) -> OSErr {
    // Pull the URL string out of the direct-object parameter as UTF-8.
    // 4 KiB is plenty — we're decoding URLs, not file payloads.
    let mut buf = [0u8; 4096];
    let mut actual_type: DescType = 0;
    let mut actual_size: isize = 0;
    let rc = unsafe {
        AEGetParamPtr(
            event,
            KEY_DIRECT_OBJECT,
            TYPE_UTF8_TEXT,
            &mut actual_type,
            buf.as_mut_ptr() as *mut c_void,
            buf.len() as isize,
            &mut actual_size,
        )
    };
    if rc != 0 || actual_size <= 0 {
        return 0;
    }
    let n = actual_size as usize;
    let n = n.min(buf.len());
    let url = match std::str::from_utf8(&buf[..n]) {
        Ok(s) => s,
        Err(_) => return 0,
    };
    let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("/"));
    let translated = match translate_open_arg(url, &cwd) {
        Some(t) => t,
        None => return 0,    // recognized scheme, unsupported command
    };
    if let Some(proxy) = PROXY.get() {
        // ``send_event`` may fail if the loop has already exited; in
        // that case there's nothing actionable to do, so swallow.
        let _ = proxy.send_event(UserEvent::OpenPaths(vec![translated]));
    }
    0
}
