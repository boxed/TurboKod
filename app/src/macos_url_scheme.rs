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

use std::ffi::{c_char, c_void, CStr};
use std::fs::OpenOptions;
use std::io::Write;
use std::path::PathBuf;
use std::sync::OnceLock;

use winit::event_loop::EventLoopProxy;

use crate::{translate_open_arg, UserEvent};

// Cold-launch debugging: every step that contributes to opening a path
// from ``open -a turbokod /path`` writes a line to this log so a failure
// to deliver leaves a trail. Cheap (one open+write per event), opt-out
// by removing the file (it'll be recreated on next launch).
fn dlog(msg: &str) {
    if let Ok(mut f) = OpenOptions::new()
        .create(true)
        .append(true)
        .open("/tmp/turbokod-debug.log")
    {
        let _ = writeln!(f, "[{}] url-scheme: {}", std::process::id(), msg);
    }
}

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
//
// ``kAEOpenDocuments`` (``aevt/odoc``) — the open-documents AE — is
// deliberately *not* claimed via Carbon here; see ``register`` for why
// we route it through ``application:openFiles:`` on the delegate
// instead.
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

// objc runtime FFI. We only need the three primitives ``objc_getClass``,
// ``sel_registerName`` and ``class_addMethod`` to graft an
// ``application:openFiles:`` selector onto winit's existing
// ``WinitApplicationDelegate`` class — implementing it from a fresh
// custom delegate would mean fighting winit for ownership of
// ``NSApplication.delegate``.
type ObjcClass = c_void;
type ObjcSel = c_void;
type ObjcId = c_void;

#[link(name = "objc", kind = "dylib")]
unsafe extern "C" {
    fn objc_getClass(name: *const c_char) -> *mut ObjcClass;
    fn sel_registerName(name: *const c_char) -> *mut ObjcSel;
    fn class_addMethod(
        cls: *mut ObjcClass,
        name: *mut ObjcSel,
        imp: extern "C" fn(),
        types: *const c_char,
    ) -> bool;
    // ``objc_msgSend`` is variadic at the ABI level. We cast it to a
    // concrete fn pointer per call site so the compiler emits the right
    // calling convention for each return-type / arg-type combination.
    fn objc_msgSend();
}

// The Apple Event handler is a plain C function pointer with no captures
// — it has to look up the proxy through a global slot. ``OnceLock``
// keeps the install side-effect-free until ``register`` is called and
// makes the handler a no-op if it ever fires before install (it can't
// in our flow, but defensive is cheap).
static PROXY: OnceLock<EventLoopProxy<UserEvent>> = OnceLock::new();

/// Install the kAEGetURL and kAEOpenDocuments handlers. Call once at
/// startup, before ``NSApp.run()`` (i.e., before ``EventLoop::run_app``).
/// Subsequent calls overwrite the proxy slot but
/// ``AEInstallEventHandler`` itself only registers each C function once
/// with the OS.
pub fn register(proxy: EventLoopProxy<UserEvent>) {
    dlog(&format!(
        "register called; argv={:?}",
        std::env::args().collect::<Vec<_>>(),
    ));
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
    // ``kAEOpenDocuments`` (``aevt/odoc``) is the AE LaunchServices
    // sends for ``open -a turbokod /path``. We *can't* claim it via
    // ``AEInstallEventHandler`` here: NSApplication installs its own
    // ``kAEOpenDocuments`` handler later (during
    // ``applicationDidFinishLaunching``) that routes the event to
    // ``application:openFiles:`` / ``application:openURLs:`` on the
    // delegate — and that registration happens *after* ours, so
    // NSApp's wins. winit's ``WinitApplicationDelegate`` doesn't
    // implement ``openFiles``/``openURLs``, so NSApp's default fallback
    // shows the macOS popup ``"the document <X> could not be opened.
    // turbokod cannot open files in the 'Folder' format"`` and silently
    // drops the path. Instead we add ``application:openFiles:`` to
    // winit's delegate class at runtime via the objc runtime — the
    // standard Cocoa entry point for opening docs/folders, which then
    // forwards into our ``OpenPaths`` channel like the URL handler does.
    install_open_files_method();
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

// Add ``application:openFiles:`` AND ``application:openURLs:`` to
// ``WinitApplicationDelegate`` at runtime. NSApplication routes the
// ``aevt/odoc`` AE to ``application:openURLs:`` first when the delegate
// responds to it (modern Cocoa, 10.13+), falling back to
// ``application:openFiles:``. We install both so the path lands the
// same way regardless of which selector NSApplication picks for this
// macOS version. winit's delegate class is named
// ``WinitApplicationDelegate`` and only implements
// ``applicationDidFinishLaunching:`` / ``applicationWillTerminate:``,
// so neither addition collides with anything winit cares about.
//
// Returns the install status so the caller can log it. Cold-launch
// regressions on this path are silent otherwise — the OS just shows
// the "cannot open files in the 'Folder' format" popup and drops the
// path.
fn install_open_files_method() {
    unsafe {
        let cls_name = c"WinitApplicationDelegate";
        let cls = objc_getClass(cls_name.as_ptr());
        if cls.is_null() {
            dlog("install: WinitApplicationDelegate class not found — both openFiles and openURLs handlers skipped");
            return;
        }
        // ObjC type-encoding string: ``v`` (void return), ``@`` (id self),
        // ``:`` (SEL _cmd), ``@`` (NSApplication* sender), ``@`` (NSArray*).
        // See <https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ObjCRuntimeGuide/Articles/ocrtTypeEncodings.html>.
        let files_sel = sel_registerName(c"application:openFiles:".as_ptr());
        let files_ok = class_addMethod(
            cls,
            files_sel,
            std::mem::transmute::<
                unsafe extern "C" fn(*mut ObjcId, *mut ObjcSel, *mut ObjcId, *mut ObjcId),
                extern "C" fn(),
            >(application_open_files),
            c"v@:@@".as_ptr(),
        );
        // ``application:openURLs:`` (NSApplicationDelegate, 10.13+) is the
        // method NSApplication prefers on modern macOS — when the
        // delegate responds to it, the openFiles fallback is never
        // called. Same signature as openFiles (NSArray of NSURL instead
        // of NSString); we extract ``-[NSURL path]`` for each entry.
        let urls_sel = sel_registerName(c"application:openURLs:".as_ptr());
        let urls_ok = class_addMethod(
            cls,
            urls_sel,
            std::mem::transmute::<
                unsafe extern "C" fn(*mut ObjcId, *mut ObjcSel, *mut ObjcId, *mut ObjcId),
                extern "C" fn(),
            >(application_open_urls),
            c"v@:@@".as_ptr(),
        );
        dlog(&format!(
            "install: openFiles={} openURLs={}",
            files_ok, urls_ok,
        ));
    }
}

// IMP for ``-[WinitApplicationDelegate application:openFiles:]``. macOS
// hands us the resolved absolute paths as an ``NSArray<NSString*>``;
// pull them out via raw ``objc_msgSend`` and forward through the same
// ``OpenPaths`` channel the URL handler uses, so the rest of the app
// can't tell whether a path arrived via ``open -a`` or
// ``turbokod://open?file=…``.
unsafe extern "C" fn application_open_files(
    _self: *mut ObjcId,
    _sel: *mut ObjcSel,
    _sender: *mut ObjcId,
    filenames: *mut ObjcId,
) {
    dlog("application:openFiles: invoked");
    if filenames.is_null() {
        dlog("application:openFiles: filenames is null");
        return;
    }
    unsafe {
        let sel_count = sel_registerName(c"count".as_ptr());
        let sel_obj_at_index = sel_registerName(c"objectAtIndex:".as_ptr());
        let sel_utf8 = sel_registerName(c"UTF8String".as_ptr());

        // ``objc_msgSend`` is variadic at the linker level but the actual
        // calling convention depends on the called method's return / arg
        // types. We re-cast it per call site so each invocation uses the
        // right ABI.
        let count_fn: unsafe extern "C" fn(*mut ObjcId, *mut ObjcSel) -> usize =
            std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        let obj_at_fn: unsafe extern "C" fn(*mut ObjcId, *mut ObjcSel, usize) -> *mut ObjcId =
            std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        let utf8_fn: unsafe extern "C" fn(*mut ObjcId, *mut ObjcSel) -> *const c_char =
            std::mem::transmute(objc_msgSend as unsafe extern "C" fn());

        let count = count_fn(filenames, sel_count);
        dlog(&format!("application:openFiles: count={}", count));
        let mut paths: Vec<String> = Vec::with_capacity(count);
        let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("/"));
        for i in 0..count {
            let ns_string = obj_at_fn(filenames, sel_obj_at_index, i);
            if ns_string.is_null() {
                continue;
            }
            let utf8 = utf8_fn(ns_string, sel_utf8);
            if utf8.is_null() {
                continue;
            }
            let raw = match CStr::from_ptr(utf8).to_str() {
                Ok(s) => s,
                Err(_) => continue,
            };
            // ``application:openFiles:`` already hands us a plain
            // POSIX path (no ``file://`` prefix, no percent-encoding),
            // so we just route it through ``translate_open_arg`` for
            // CWD resolution / consistency with the URL path.
            if let Some(t) = translate_open_arg(raw, &cwd) {
                paths.push(t);
            }
        }
        dlog(&format!("application:openFiles: forwarding {:?}", paths));
        if !paths.is_empty() {
            if let Some(proxy) = PROXY.get() {
                let res = proxy.send_event(UserEvent::OpenPaths(paths));
                dlog(&format!("application:openFiles: send_event ok={}", res.is_ok()));
            } else {
                dlog("application:openFiles: PROXY not set");
            }
        }
    }
}

// IMP for ``-[WinitApplicationDelegate application:openURLs:]``. Same
// shape as openFiles but the array members are NSURL, not NSString.
// We ask each NSURL for ``-[NSURL path]`` to get the POSIX path back,
// then route it through the same ``OpenPaths`` channel as everything
// else. NSApplication on 10.13+ prefers this selector over openFiles
// when both exist, so for cold-launch ``open -a turbokod /path`` this
// is the entry point that actually fires.
unsafe extern "C" fn application_open_urls(
    _self: *mut ObjcId,
    _sel: *mut ObjcSel,
    _sender: *mut ObjcId,
    urls: *mut ObjcId,
) {
    dlog("application:openURLs: invoked");
    if urls.is_null() {
        dlog("application:openURLs: urls is null");
        return;
    }
    unsafe {
        let sel_count = sel_registerName(c"count".as_ptr());
        let sel_obj_at_index = sel_registerName(c"objectAtIndex:".as_ptr());
        let sel_path = sel_registerName(c"path".as_ptr());
        let sel_utf8 = sel_registerName(c"UTF8String".as_ptr());

        let count_fn: unsafe extern "C" fn(*mut ObjcId, *mut ObjcSel) -> usize =
            std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        let obj_at_fn: unsafe extern "C" fn(*mut ObjcId, *mut ObjcSel, usize) -> *mut ObjcId =
            std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        let url_path_fn: unsafe extern "C" fn(*mut ObjcId, *mut ObjcSel) -> *mut ObjcId =
            std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        let utf8_fn: unsafe extern "C" fn(*mut ObjcId, *mut ObjcSel) -> *const c_char =
            std::mem::transmute(objc_msgSend as unsafe extern "C" fn());

        let count = count_fn(urls, sel_count);
        dlog(&format!("application:openURLs: count={}", count));
        let mut paths: Vec<String> = Vec::with_capacity(count);
        let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("/"));
        for i in 0..count {
            let url = obj_at_fn(urls, sel_obj_at_index, i);
            if url.is_null() {
                continue;
            }
            let ns_path = url_path_fn(url, sel_path);
            if ns_path.is_null() {
                continue;
            }
            let utf8 = utf8_fn(ns_path, sel_utf8);
            if utf8.is_null() {
                continue;
            }
            let raw = match CStr::from_ptr(utf8).to_str() {
                Ok(s) => s,
                Err(_) => continue,
            };
            if let Some(t) = translate_open_arg(raw, &cwd) {
                paths.push(t);
            }
        }
        dlog(&format!("application:openURLs: forwarding {:?}", paths));
        if !paths.is_empty() {
            if let Some(proxy) = PROXY.get() {
                let res = proxy.send_event(UserEvent::OpenPaths(paths));
                dlog(&format!("application:openURLs: send_event ok={}", res.is_ok()));
            } else {
                dlog("application:openURLs: PROXY not set");
            }
        }
    }
}
