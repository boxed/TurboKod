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

/// Exported wrapper for the Swift host. AppKit's `NSApp.terminate`
/// ends the process via `_exit()`, which skips dyld static
/// terminators — so `AUTO_CLEANUP` below never runs on Cmd+Q and any
/// live children (run targets, LSP servers, pty shells) would be
/// orphaned. The app delegate calls this from
/// `applicationWillTerminate` instead.
#[no_mangle]
pub extern "C" fn tk_terminate_all() {
    terminate_all();
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
        // Strip the macOS malloc-debug env vars from the pty-child
        // environment. If our parent process happens to have any of
        // them set (debug builds, an outer wrapper that uses them as
        // a canary), passing them through to pty-spawned shells makes
        // those shells print stderr noise like ``__chkstk_darwin:
        // stack guard mismatch`` or ``MallocScribble: enabling
        // scribbling to detect mods to free blocks`` on every launch,
        // which clutters the terminal UI.
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

/// Hard cap on the size of any file opened via ``tk_debug_log_open``.
/// Sessions had been observed growing the log into the gigabytes.
const DEBUG_LOG_MAX_BYTES: i64 = 5 * 1024 * 1024;
/// When the cap is hit, keep this much of the tail so recent context
/// survives the rotation. Half-cap gives ~2.5MB of headroom before the
/// next rotation fires.
const DEBUG_LOG_KEEP_BYTES: i64 = DEBUG_LOG_MAX_BYTES / 2;

/// If ``path`` exceeds the cap, rewrite it in place to its last
/// ``DEBUG_LOG_KEEP_BYTES``. Best-effort: any libc failure aborts the
/// rotation silently and leaves the file as-is, because the caller is
/// the diagnostics path and must not fail noisily.
unsafe fn debug_log_rotate(path: *const c_char, size: i64) {
    let rfd = libc::open(path, libc::O_RDONLY);
    if rfd < 0 {
        return;
    }
    let offset = size - DEBUG_LOG_KEEP_BYTES;
    if libc::lseek(rfd, offset as libc::off_t, libc::SEEK_SET) < 0 {
        libc::close(rfd);
        return;
    }
    let mut buf = vec![0u8; DEBUG_LOG_KEEP_BYTES as usize];
    let mut total: usize = 0;
    while total < buf.len() {
        let n = libc::read(
            rfd,
            buf.as_mut_ptr().add(total) as *mut c_void,
            buf.len() - total,
        );
        if n <= 0 {
            break;
        }
        total += n as usize;
    }
    libc::close(rfd);
    if total == 0 {
        return;
    }
    let wfd = libc::open(path, libc::O_WRONLY | libc::O_TRUNC, 0o644);
    if wfd < 0 {
        return;
    }
    let _ = libc::write(wfd, buf.as_ptr() as *const c_void, total);
    libc::close(wfd);
}

/// Open ``path`` for write+append, creating it if absent. Used by the
/// Mojo ``debug_log`` helper. Wrapped here because Mojo's FFI rejects
/// a second binding of plain ``open`` with three arguments (the
/// codebase has an existing two-arg binding).
///
/// Before opening, the file is trimmed to its last
/// ``DEBUG_LOG_KEEP_BYTES`` if it has exceeded ``DEBUG_LOG_MAX_BYTES``,
/// so the log can never grow without bound across a long session.
#[no_mangle]
pub unsafe extern "C" fn tk_debug_log_open(path: *const c_char) -> c_int {
    if path.is_null() {
        return -1;
    }
    let mut st: libc::stat = std::mem::zeroed();
    if libc::stat(path, &mut st) == 0
        && (st.st_size as i64) >= DEBUG_LOG_MAX_BYTES
    {
        debug_log_rotate(path, st.st_size as i64);
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

// --- Login-shell PATH recovery -------------------------------------------
//
// macOS hands Dock/launchd-launched apps a stripped ``PATH`` (just the
// path_helper-derived ``/usr/bin:/bin:/usr/sbin:/sbin`` + ``/etc/paths.d``
// entries) that omits the per-user dirs a login shell sets up
// (``~/.cargo/bin``, ``~/.pyenv/shims``, homebrew, …). The Mojo backend
// forwards its own ``PATH`` verbatim to every child it ``posix_spawnp``s
// (LSP servers, ``rg``, ``git``), so a Dock launch can't find e.g.
// ``ty-semantic`` even though it's plainly on the user's interactive
// ``PATH``. We recover the way VS Code / exec-path-from-shell do: run
// the user's login shell once and read back the ``PATH=`` line.
//
// Shell-agnostic on purpose: rather than ``echo $PATH`` (fish joins its
// list var with spaces, not colons), we exec ``/usr/bin/env`` inside the
// login+interactive shell and parse the ``PATH=`` line — by then PATH is
// a normal colon-joined exported string regardless of shell. A hard
// timeout guards against an interactive rc-file that blocks on input.
//
// We use libc directly (no ``std::process::Command``) because Rust's
// ``std`` runtime has been observed to misbehave when called from a
// staticlib linked into a non-Rust (Mojo) binary — same reason
// ``tk_listdir`` avoids ``std::fs::read_dir``.

const LOGIN_SHELL_TIMEOUT_MS: i64 = 3000;

/// Run the user's login shell to recover the full interactive ``PATH``.
/// Output is written into ``out`` (NUL-terminated, ASCII bytes) and the
/// byte length is returned. Returns ``-1`` on any failure (no SHELL,
/// timeout, no ``PATH=`` line in output, output too long for ``out``).
///
/// # Safety
/// `out` must point to at least `cap` bytes writable. `cap` must be > 1.
#[no_mangle]
pub unsafe extern "C" fn tk_login_shell_path(out: *mut c_char, cap: c_int) -> c_int {
    if out.is_null() || cap <= 1 {
        return -1;
    }

    // Pick $SHELL; fall back to /bin/zsh which is the macOS default.
    let shell_buf: Vec<u8> = {
        let raw = libc::getenv(c"SHELL".as_ptr());
        if raw.is_null() {
            b"/bin/zsh\0".to_vec()
        } else {
            let s = CStr::from_ptr(raw).to_bytes();
            if s.is_empty() {
                b"/bin/zsh\0".to_vec()
            } else {
                let mut v = s.to_vec();
                v.push(0);
                v
            }
        }
    };

    // Build argv: [shell, "-l", "-i", "-c", "/usr/bin/env", NULL]
    // ``-l`` (login) sources profile files; ``-i`` (interactive) sources
    // the rc files where many users actually mutate PATH; ``-c`` runs the
    // single command and exits without waiting for stdin.
    let arg_l = b"-l\0";
    let arg_i = b"-i\0";
    let arg_c = b"-c\0";
    let arg_env = b"/usr/bin/env\0";
    let argv: [*mut c_char; 6] = [
        shell_buf.as_ptr() as *mut c_char,
        arg_l.as_ptr() as *mut c_char,
        arg_i.as_ptr() as *mut c_char,
        arg_c.as_ptr() as *mut c_char,
        arg_env.as_ptr() as *mut c_char,
        std::ptr::null_mut(),
    ];

    // Pipe for the child's stdout; stderr goes to /dev/null so an rc
    // file's "warning: ..." chatter doesn't get mixed into the PATH
    // line we parse.
    let mut fds: [c_int; 2] = [-1, -1];
    if libc::pipe(fds.as_mut_ptr()) < 0 {
        return -1;
    }
    let read_fd = fds[0];
    let write_fd = fds[1];

    let devnull = libc::open(c"/dev/null".as_ptr(), libc::O_RDWR);
    if devnull < 0 {
        libc::close(read_fd);
        libc::close(write_fd);
        return -1;
    }

    let pid = libc::fork();
    if pid < 0 {
        libc::close(read_fd);
        libc::close(write_fd);
        libc::close(devnull);
        return -1;
    }
    if pid == 0 {
        // Child. Wire stdin/stderr to /dev/null, stdout to the write end
        // of the pipe, then exec the shell. Bail with _exit(127) on any
        // setup failure — the parent will see EOF / nonzero exit.
        libc::dup2(devnull, 0);
        libc::dup2(write_fd, 1);
        libc::dup2(devnull, 2);
        libc::close(devnull);
        libc::close(read_fd);
        libc::close(write_fd);
        libc::execvp(argv[0], argv.as_ptr() as *const *const c_char);
        libc::_exit(127);
    }

    // Parent.
    libc::close(write_fd);
    libc::close(devnull);

    // Make the read end non-blocking so we can poll with a deadline.
    let flags = libc::fcntl(read_fd, libc::F_GETFL, 0);
    if flags >= 0 {
        let _ = libc::fcntl(read_fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
    }

    let deadline = monotonic_ms() + LOGIN_SHELL_TIMEOUT_MS;
    let mut captured: Vec<u8> = Vec::with_capacity(4096);
    let mut scratch = [0u8; 4096];
    let mut child_done = false;

    loop {
        // Try a non-blocking read first — drain whatever the child has
        // already written.
        loop {
            let n = libc::read(
                read_fd,
                scratch.as_mut_ptr() as *mut c_void,
                scratch.len() as libc::size_t,
            );
            if n > 0 {
                captured.extend_from_slice(&scratch[..n as usize]);
                // Cap the capture so a runaway child can't OOM us.
                if captured.len() > 1 << 20 {
                    break;
                }
                continue;
            }
            if n == 0 {
                // EOF — pipe write end has been closed (child exited or
                // closed its stdout).
                child_done = true;
                break;
            }
            // n < 0
            let e = errno();
            if e == libc::EAGAIN || e == libc::EWOULDBLOCK || e == libc::EINTR {
                break;
            }
            // Hard read error.
            child_done = true;
            break;
        }
        if child_done {
            break;
        }

        // Check whether the child has reaped on its own anyway (it may
        // exit before its stdout is fully drained).
        let mut status: c_int = 0;
        let r = libc::waitpid(pid, &mut status, libc::WNOHANG);
        if r == pid {
            // Drain any remaining bytes from the pipe before bailing.
            loop {
                let n = libc::read(
                    read_fd,
                    scratch.as_mut_ptr() as *mut c_void,
                    scratch.len() as libc::size_t,
                );
                if n <= 0 {
                    break;
                }
                captured.extend_from_slice(&scratch[..n as usize]);
                if captured.len() > 1 << 20 {
                    break;
                }
            }
            // Child reaped + pipe drained — we're done with the outer
            // loop too. ``child_done`` is no longer read after this
            // break, so we don't bother setting it.
            break;
        }

        if monotonic_ms() >= deadline {
            // Timeout. SIGKILL the child (SIGTERM may be caught by the
            // shell), drain whatever it managed to write, then bail.
            libc::kill(pid, libc::SIGKILL);
            let mut status: c_int = 0;
            libc::waitpid(pid, &mut status, 0);
            libc::close(read_fd);
            return -1;
        }

        // Sleep 10 ms, then poll again. Bounded by the deadline check
        // above so we never sleep past the timeout.
        let ts = libc::timespec {
            tv_sec: 0,
            tv_nsec: 10_000_000,
        };
        libc::nanosleep(&ts, std::ptr::null_mut());
    }

    libc::close(read_fd);
    // Reap the child if we didn't already (e.g. EOF before exit).
    let mut status: c_int = 0;
    libc::waitpid(pid, &mut status, 0);

    // Find a PATH=... line in the captured output. ``/usr/bin/env``
    // prints one VAR=value per line.
    let needle = b"PATH=";
    let mut path_bytes: Option<&[u8]> = None;
    let mut line_start = 0usize;
    for i in 0..captured.len() {
        if captured[i] == b'\n' {
            let line = &captured[line_start..i];
            if line.starts_with(needle) {
                path_bytes = Some(&line[needle.len()..]);
                break;
            }
            line_start = i + 1;
        }
    }
    if path_bytes.is_none() && line_start < captured.len() {
        let tail = &captured[line_start..];
        if tail.starts_with(needle) {
            path_bytes = Some(&tail[needle.len()..]);
        }
    }

    let path = match path_bytes {
        Some(p) if !p.is_empty() => p,
        _ => return -1,
    };

    if path.len() + 1 > cap as usize {
        return -1;
    }
    std::ptr::copy_nonoverlapping(path.as_ptr(), out as *mut u8, path.len());
    *out.add(path.len()) = 0;
    path.len() as c_int
}

fn monotonic_ms() -> i64 {
    unsafe {
        let mut ts: libc::timespec = std::mem::zeroed();
        // ``CLOCK_MONOTONIC`` is supported on both Darwin and Linux.
        if libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts) != 0 {
            return 0;
        }
        (ts.tv_sec as i64) * 1000 + (ts.tv_nsec as i64) / 1_000_000
    }
}

// --- helpers --------------------------------------------------------------

/// Append ``msg`` (no newline added) to ``/tmp/turbokod_debug.log``
/// using only libc syscalls — no Rust ``std`` allocator, no panic
/// handler, no TLS init. Lets us see where we are even if higher
/// layers of the Rust runtime are misbehaving. Kept around as a
/// dormant emergency-debugging utility — un-reference it for a
/// release build and the linker drops it.
#[allow(dead_code)]
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
/// (e.g. an incoming C-string the caller passed in). Same dormant
/// emergency-debugging status as ``raw_debug`` itself.
#[allow(dead_code)]
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
