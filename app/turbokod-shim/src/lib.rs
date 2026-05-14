//! C-ABI replacement for ``src/turbokod/process_shim.c``.
//!
//! The Mojo build links this crate's ``libturbokod_shim.a`` and the
//! Mojo source calls into it via the same ``external_call["tk_…", …]``
//! pattern as before. Symbol names and ABIs are preserved — Mojo can't
//! tell the difference.
//!
//! Why Rust instead of C: the previous C version was a workable but
//! unsafe choice. We chased a sequence of bundle-only crashes that
//! looked like heap corruption (sometimes inside `malloc`,
//! sometimes inside `listdir`); Rust's allocator + bounds checking
//! removes a large class of those bugs at compile time, and `nix`
//! gives type-checked wrappers around the POSIX surface we depend on.
//!
//! Concurrency: the Mojo side is single-threaded. The child-tracking
//! registry uses a `Mutex` anyway so accidental concurrent access from
//! a signal handler (`tk_terminate_all`) is safe; signal handlers
//! take a `try_lock` so they never deadlock.

use std::ffi::{c_char, c_int, c_long, c_uchar, c_uint, c_void, CStr};
use std::fs::File;
use std::io::Write;
use std::os::fd::IntoRawFd;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;
use std::sync::Mutex;

// --- Non-blocking write ---------------------------------------------------

/// ``write(2)`` that returns 0 on EAGAIN/EWOULDBLOCK/EINTR instead of
/// raising, and ``-1`` on any other failure.
///
/// Mojo's stdlib already binds ``write`` to a fixed signature, so we
/// re-export under a unique name to sidestep the FFI collision.
///
/// # Safety
/// `buf` must point to at least `count` bytes readable. The fd must
/// be open and writable. The caller is responsible for the buffer
/// lifetime. Failure modes (closed pipe, etc.) surface via the return
/// value, not via Rust panics.
#[no_mangle]
pub unsafe extern "C" fn tk_write_nb(
    fd: c_int,
    buf: *const c_void,
    count: c_uint,
) -> c_long {
    if fd < 0 || count == 0 {
        return 0;
    }
    let n = libc::write(fd, buf, count as libc::size_t);
    if n >= 0 {
        return n as c_long;
    }
    let err = errno();
    if err == libc::EAGAIN || err == libc::EWOULDBLOCK || err == libc::EINTR {
        return 0;
    }
    -1
}

/// Set ``O_NONBLOCK`` on ``fd`` while preserving the rest of the
/// file-status flags. Returns 1 on success, 0 on failure. Mojo calls
/// this instead of plain ``fcntl`` because the third (varargs)
/// argument to ``fcntl`` is passed on the stack on Darwin ARM64,
/// which Mojo's fixed-arity FFI can't express.
#[no_mangle]
pub extern "C" fn tk_set_nonblock(fd: c_int) -> c_int {
    if fd < 0 {
        return 0;
    }
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL, 0) };
    if flags == -1 {
        return 0;
    }
    if unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } == -1 {
        return 0;
    }
    1
}

// --- Child registry -------------------------------------------------------
//
// Spawned subprocesses (LSP, DAP, pty children) get their PIDs stamped
// into this list so a SIGHUP / SIGTERM / clean shutdown can kill them
// before we exit. Without that the macOS .app teardown would orphan
// children that we'd then leak as zombies.

static CHILD_PIDS: Mutex<Vec<libc::pid_t>> = Mutex::new(Vec::new());

#[no_mangle]
pub extern "C" fn tk_track_child_add(pid: c_int) {
    if pid <= 0 {
        return;
    }
    if let Ok(mut v) = CHILD_PIDS.lock() {
        v.push(pid as libc::pid_t);
    }
}

#[no_mangle]
pub extern "C" fn tk_track_child_remove(pid: c_int) {
    if pid <= 0 {
        return;
    }
    if let Ok(mut v) = CHILD_PIDS.lock() {
        if let Some(idx) = v.iter().position(|&p| p == pid as libc::pid_t) {
            // Swap-remove for O(1) — order is irrelevant.
            v.swap_remove(idx);
        }
    }
}

/// SIGTERM every tracked PID. Called from signal handlers and the
/// destructor (process-exit hook). Uses `try_lock` so re-entering
/// from a signal during a registry update can't deadlock — the lock
/// is contended only momentarily and skipping a SIGTERM is much
/// better than hanging the shutdown path.
fn terminate_all() {
    if let Ok(v) = CHILD_PIDS.try_lock() {
        for &pid in v.iter() {
            if pid > 0 {
                unsafe { libc::kill(pid, libc::SIGTERM); }
            }
        }
    }
}

extern "C" fn on_signal(sig: c_int) {
    terminate_all();
    // Restore default disposition and re-raise so the process exits
    // with the same status it would have had without our handler.
    unsafe {
        let mut sa: libc::sigaction = std::mem::zeroed();
        sa.sa_sigaction = libc::SIG_DFL;
        libc::sigemptyset(&mut sa.sa_mask);
        libc::sigaction(sig, &sa, std::ptr::null_mut());
        libc::raise(sig);
    }
}

/// Constructor — runs at library load time. Installs SIGHUP / SIGTERM
/// handlers so the macOS .app teardown (which delivers SIGHUP via the
/// PTY hangup) reaps our children.
#[link_section = "__DATA,__mod_init_func"]
#[used]
static INSTALL_HANDLERS: extern "C" fn() = {
    extern "C" fn install() {
        unsafe {
            let mut sa: libc::sigaction = std::mem::zeroed();
            sa.sa_sigaction = on_signal as usize;
            libc::sigemptyset(&mut sa.sa_mask);
            libc::sigaction(libc::SIGHUP, &sa, std::ptr::null_mut());
            libc::sigaction(libc::SIGTERM, &sa, std::ptr::null_mut());
        }
    }
    install
};

/// Destructor — runs at process exit. Backstop for the signal handler
/// in case the process exits via a non-trapped path.
#[link_section = "__DATA,__mod_term_func"]
#[used]
static AUTO_CLEANUP: extern "C" fn() = {
    extern "C" fn cleanup() {
        terminate_all();
    }
    cleanup
};

// --- PTY spawn ------------------------------------------------------------

/// Fork+exec a child under a fresh controlling pty. Returns 0 on
/// success and writes the child's pid + the parent-side master fd
/// through the out-params; returns -1 on failure.
///
/// `argv` is a NUL-terminated array of NUL-terminated C strings
/// (standard `execvp` convention). `cwd` may be NULL or empty —
/// chdir is skipped. `term` may be NULL or empty — TERM is left at
/// whatever the parent has.
///
/// # Safety
/// All pointer arguments must be valid for the duration of the call.
/// `argv` must be NUL-terminated and each entry NUL-terminated.
/// `pid_out` and `master_fd_out` must point to writable `c_int`.
#[no_mangle]
pub unsafe extern "C" fn tk_pty_spawn(
    file: *const c_char,
    argv: *const *const c_char,
    cwd: *const c_char,
    cols: c_int,
    rows: c_int,
    term: *const c_char,
    pid_out: *mut c_int,
    master_fd_out: *mut c_int,
) -> c_int {
    if file.is_null() || argv.is_null() || pid_out.is_null() || master_fd_out.is_null() {
        *errno_location() = libc::EINVAL;
        return -1;
    }

    // POSIX pty open — works on Linux + macOS without libutil.
    let master = libc::posix_openpt(libc::O_RDWR | libc::O_NOCTTY);
    if master < 0 {
        return -1;
    }
    if libc::grantpt(master) < 0 {
        let e = errno();
        libc::close(master);
        *errno_location() = e;
        return -1;
    }
    if libc::unlockpt(master) < 0 {
        let e = errno();
        libc::close(master);
        *errno_location() = e;
        return -1;
    }
    let slave_name = libc::ptsname(master);
    if slave_name.is_null() {
        let e = errno();
        libc::close(master);
        *errno_location() = e;
        return -1;
    }
    let slave = libc::open(slave_name, libc::O_RDWR | libc::O_NOCTTY);
    if slave < 0 {
        let e = errno();
        libc::close(master);
        *errno_location() = e;
        return -1;
    }

    // Initial window size so the child's first tcgetwinsize returns
    // the right values — saves a SIGWINCH redraw.
    if cols > 0 && rows > 0 {
        let ws = libc::winsize {
            ws_row: rows as c_uchar as u16,
            ws_col: cols as c_uchar as u16,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        let _ = libc::ioctl(slave, libc::TIOCSWINSZ, &ws);
    }

    let pid = libc::fork();
    if pid < 0 {
        let e = errno();
        libc::close(slave);
        libc::close(master);
        *errno_location() = e;
        return -1;
    }
    if pid == 0 {
        // Child. Must use only async-signal-safe APIs in principle,
        // but Mojo is single-threaded so libc state isn't racy. We
        // permit setenv / chdir.
        if libc::setsid() < 0 {
            libc::_exit(127);
        }
        // Acquire the slave as controlling terminal. The macro for
        // TIOCSCTTY isn't exposed via libc on macOS, so we use the
        // raw value; it's stable across Linux + Darwin.
        let _ = libc::ioctl(slave, TIOCSCTTY, 0 as c_int);
        if libc::dup2(slave, 0) < 0
            || libc::dup2(slave, 1) < 0
            || libc::dup2(slave, 2) < 0
        {
            libc::_exit(127);
        }
        if slave > 2 {
            libc::close(slave);
        }
        libc::close(master);
        if !cwd.is_null() && *cwd != 0 {
            let _ = libc::chdir(cwd);
        }
        if !term.is_null() && *term != 0 {
            let term_var = c"TERM".as_ptr();
            let _ = libc::setenv(term_var, term, 1);
        }
        // Strip the macOS malloc-debug env vars the Rust front-end
        // sets on us — we want those active for the Mojo backend's
        // own malloc (where they suppress a heap-corruption canary,
        // see app/src/main.rs) but NOT for the shells we spawn from
        // the docked terminal panes. Programs run from those shells
        // see ``MallocScribble`` and print stderr noise like
        // ``__chkstk_darwin: stack guard mismatch`` or
        // ``MallocScribble: …`` on every launch, which clutters the
        // terminal UI.
        let _ = libc::unsetenv(c"MallocScribble".as_ptr());
        let _ = libc::unsetenv(c"MallocPreScribble".as_ptr());
        let _ = libc::unsetenv(c"MallocGuardEdges".as_ptr());
        libc::execvp(file, argv);
        // Only reached on exec failure. 127 is "command not found".
        libc::_exit(127);
    }

    // Parent.
    libc::close(slave);
    let flags = libc::fcntl(master, libc::F_GETFL, 0);
    if flags >= 0 {
        let _ = libc::fcntl(master, libc::F_SETFL, flags | libc::O_NONBLOCK);
    }
    tk_track_child_add(pid as c_int);
    *pid_out = pid as c_int;
    *master_fd_out = master;
    0
}

/// On Linux this is in `linux/termios.h`; on Darwin it's in `sys/ttycom.h`.
/// libc 0.2 exposes it only on Linux, so we hand-roll the macOS value.
#[cfg(target_os = "macos")]
const TIOCSCTTY: libc::c_ulong = 0x20007461;
#[cfg(target_os = "linux")]
const TIOCSCTTY: libc::c_ulong = 0x540E;

/// Update the pty's window size and send SIGWINCH to the foreground
/// process group. Returns 0 on success, -1 on failure.
#[no_mangle]
pub extern "C" fn tk_pty_set_winsize(fd: c_int, cols: c_int, rows: c_int) -> c_int {
    if fd < 0 {
        return -1;
    }
    let ws = libc::winsize {
        ws_row: rows as u16,
        ws_col: cols as u16,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    if unsafe { libc::ioctl(fd, libc::TIOCSWINSZ, &ws) } < 0 {
        -1
    } else {
        0
    }
}

// --- Debug log open -------------------------------------------------------

/// Open ``path`` for write+append, creating it if absent. Used by the
/// Mojo ``debug_log`` helper. Wrapped here because Mojo's FFI rejects
/// a second binding of plain ``open`` with three arguments (the
/// codebase has an existing two-arg binding).
#[no_mangle]
pub unsafe extern "C" fn tk_debug_log_open(path: *const c_char) -> c_int {
    if path.is_null() {
        return -1;
    }
    // Direct libc call — std::fs::OpenOptions has been observed to
    // crash in the bundle launch context, presumably because the
    // Rust std runtime that path needs (allocator init / panic hook /
    // TLS) hasn't been wired up when called from a Mojo binary.
    libc::open(path, libc::O_WRONLY | libc::O_CREAT | libc::O_APPEND, 0o644)
}

// --- Directory listing ----------------------------------------------------
//
// The Mojo side calls these in three steps: ``tk_listdir(path)``
// loads, ``tk_listdir_get_name(i, buf, cap)`` retrieves the i-th
// name, ``tk_listdir_done()`` releases. Storage is process-global —
// single-threaded by the contract Mojo enforces.

struct ListdirState {
    names: Vec<Vec<u8>>,
}

static LISTDIR: Mutex<Option<ListdirState>> = Mutex::new(None);

/// Open ``path`` and stash its entries (excluding ``.`` and ``..``)
/// in process-global state. Returns the entry count, or -1 on error.
///
/// Implemented via raw ``opendir`` / ``readdir`` rather than
/// ``std::fs::read_dir`` because the latter has crashed under the
/// macOS .app bundle launch context. The Rust std path goes through
/// allocator hooks at directory open time; bypassing them in favour
/// of a thin libc wrapper avoids whatever interaction was breaking
/// the bundle launch.
#[no_mangle]
pub unsafe extern "C" fn tk_listdir(path: *const c_char) -> c_int {
    if path.is_null() {
        return -1;
    }
    let dir = libc::opendir(path);
    if dir.is_null() {
        return -1;
    }
    let mut names: Vec<Vec<u8>> = Vec::new();
    loop {
        // ``readdir`` returns a pointer into the DIR's internal
        // buffer; valid until the next ``readdir`` or ``closedir``.
        // We must NOT free the returned struct.
        let entry = libc::readdir(dir);
        if entry.is_null() {
            break;
        }
        let raw_name_ptr = (*entry).d_name.as_ptr();
        let name_cstr = CStr::from_ptr(raw_name_ptr);
        let nb = name_cstr.to_bytes();
        if nb == b"." || nb == b".." {
            continue;
        }
        names.push(nb.to_vec());
    }
    libc::closedir(dir);
    let count = names.len() as c_int;
    if let Ok(mut g) = LISTDIR.lock() {
        *g = Some(ListdirState { names });
    }
    count
}

/// Copy the ``idx``-th name into ``out`` (NUL-terminated). Returns
/// the byte length on success, -1 on out-of-range or insufficient
/// buffer.
///
/// # Safety
/// `out` must point to at least `cap` bytes writable.
#[no_mangle]
pub unsafe extern "C" fn tk_listdir_get_name(
    idx: c_int,
    out: *mut c_char,
    cap: c_int,
) -> c_int {
    if out.is_null() || cap <= 1 {
        return -1;
    }
    let guard = match LISTDIR.lock() {
        Ok(g) => g,
        Err(_) => return -1,
    };
    let state = match guard.as_ref() {
        Some(s) => s,
        None => return -1,
    };
    if idx < 0 || (idx as usize) >= state.names.len() {
        return -1;
    }
    let name = &state.names[idx as usize];
    let needed = name.len() + 1;
    if needed > cap as usize {
        return -1;
    }
    std::ptr::copy_nonoverlapping(name.as_ptr(), out as *mut u8, name.len());
    *out.add(name.len()) = 0;
    name.len() as c_int
}

/// Drop the cached listing. Idempotent.
#[no_mangle]
pub extern "C" fn tk_listdir_done() {
    if let Ok(mut g) = LISTDIR.lock() {
        *g = None;
    }
}

// --- libonig handle registry ---------------------------------------------
//
// Mojo's destructor lifecycle interacted badly with libonig's region
// scratch when we tried to call ``onig_free`` / ``onig_region_free``
// from ``OnigRegex.__del__`` — the destructor sequencing under
// ``ArcPointer`` hung the next ``onig_search``. So per-instance
// reclamation is disabled; ``OnigRegex.__init__`` registers each
// fresh ``(regex_t*, OnigRegion*)`` pair via ``tk_onig_track`` and
// the destructor (`__mod_term_func` below) walks the list at exit.
//
// Cost: handles outlive their wrapping ``OnigRegex`` for the rest
// of the session — bounded by (#grammars × patterns per grammar).
// Empirically tens of MB on a multi-language session, all reclaimed
// cleanly at shutdown so leak detectors stay quiet.

extern "C" {
    fn onig_free(reg: *mut c_void) -> c_int;
    fn onig_region_free(region: *mut c_void, free_self: c_int);
}

#[derive(Clone, Copy)]
struct OnigHandle {
    reg: *mut c_void,
    region: *mut c_void,
}

// Raw pointers aren't Send by default; the registry is only mutated
// from the Mojo thread and read from process-exit context where Mojo
// has stopped. The Mutex serialises both; manually asserting Send
// just informs the compiler of the invariant we already enforce.
unsafe impl Send for OnigHandle {}

static ONIG_HANDLES: Mutex<Vec<OnigHandle>> = Mutex::new(Vec::new());

/// Track a freshly-allocated ``(regex_t*, OnigRegion*)`` pair. The
/// list lives until ``tk_onig_free_all`` or the process-exit hook
/// claims them.
#[no_mangle]
pub extern "C" fn tk_onig_track(reg: *mut c_void, region: *mut c_void) {
    if let Ok(mut v) = ONIG_HANDLES.lock() {
        v.push(OnigHandle { reg, region });
    }
}

/// Free every tracked handle and clear the registry. Idempotent — a
/// second call is a no-op. Exposed so a host that wants deterministic
/// teardown before exit can call it directly.
#[no_mangle]
pub extern "C" fn tk_onig_free_all() {
    let handles = if let Ok(mut v) = ONIG_HANDLES.lock() {
        std::mem::take(&mut *v)
    } else {
        return;
    };
    unsafe {
        for h in &handles {
            if !h.region.is_null() {
                onig_region_free(h.region, 1);
            }
            if !h.reg.is_null() {
                onig_free(h.reg);
            }
        }
    }
}

/// Run libonig cleanup on normal process exit. Fires after main
/// returns but while libonig is still loaded.
#[link_section = "__DATA,__mod_term_func"]
#[used]
static ONIG_AUTO_CLEANUP: extern "C" fn() = {
    extern "C" fn cleanup() {
        tk_onig_free_all();
    }
    cleanup
};

// --- helpers --------------------------------------------------------------

/// Append ``msg`` (no newline added) to ``/tmp/turbokod_debug.log``
/// using only libc syscalls — no Rust ``std`` allocator, no panic
/// handler, no TLS init. Lets us see where we are even if higher
/// layers of the Rust runtime are misbehaving.
fn raw_debug(msg: &[u8]) {
    unsafe {
        let path = b"/tmp/turbokod_debug.log\0";
        let fd = libc::open(
            path.as_ptr() as *const c_char,
            libc::O_WRONLY | libc::O_CREAT | libc::O_APPEND,
            0o644,
        );
        if fd < 0 { return; }
        libc::write(fd, msg.as_ptr() as *const c_void, msg.len());
        libc::close(fd);
    }
}

/// `raw_debug(prefix)` then `raw_debug(payload)` then a newline. Used
/// to log a bytestring whose length isn't known at compile time
/// (e.g. an incoming C-string the caller passed in).
fn raw_debug_pfx(prefix: &[u8], payload: &[u8]) {
    raw_debug(prefix);
    raw_debug(payload);
    raw_debug(b"\n");
}

fn errno() -> c_int {
    unsafe { *errno_location() }
}

#[cfg(target_os = "macos")]
unsafe fn errno_location() -> *mut c_int {
    libc::__error()
}

#[cfg(target_os = "linux")]
unsafe fn errno_location() -> *mut c_int {
    libc::__errno_location()
}

// Silence "unused" warnings for items referenced only via the link
// sections above.
#[allow(dead_code)]
fn _force_links() {
    let _ = INSTALL_HANDLERS;
    let _ = AUTO_CLEANUP;
    let _ = ONIG_AUTO_CLEANUP;
    // Reference Write and File so the imports don't get flagged when
    // a future trim removes a direct use.
    let _: fn() -> Option<()> = || {
        let mut f = File::create("/dev/null").ok()?;
        let _ = f.write_all(b"");
        Some(())
    };
}
