/*
 * process_shim.c — kill-on-parent-death registry for spawned children.
 *
 * Background: Run / Debug sessions, LSP servers, and DAP adapters are
 * spawned via ``posix_spawnp`` with ``POSIX_SPAWN_SETSID`` so they
 * run in their own session — that's required to keep them from
 * stealing the parent's controlling TTY (debugpy in particular). The
 * side effect: the children are *not* in the parent's process group,
 * so the kernel's PTY hangup (SIGHUP delivered to the foreground
 * group when the master closes) reaches mojo but not its children.
 * Quitting the macOS app would then orphan the spawned program — the
 * Mojo ``finally`` block that would normally call ``terminate()`` on
 * each child never runs because SIGHUP's default action is silent
 * termination.
 *
 * Fix: maintain a process-wide registry of every PID we spawn, and
 * intercept SIGHUP / SIGTERM so we SIGTERM every tracked child
 * before re-raising. A ``__attribute__((destructor))`` runs the same
 * cleanup on normal exit as a defensive backstop. The registry is
 * pruned by ``tk_track_child_remove`` whenever Mojo successfully
 * reaps a child — both to keep the list bounded and to avoid sending
 * SIGTERM to a recycled PID at shutdown.
 *
 * Concurrency: Mojo is single-threaded, so the only racing reader is
 * the signal handler itself. The worst case is a signal arriving
 * mid-update — observable as either a freshly tracked PID being
 * skipped (small orphan window) or a freshly untracked one getting a
 * redundant SIGTERM (no-op via ESRCH). Both are benign.
 *
 * SIGKILL is intentionally not handled: it can't be. If you need
 * robustness against SIGKILL of mojo itself, the only correct
 * mechanism is a pipe-watchdog inside the child — out of scope here.
 */

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <termios.h>
#include <unistd.h>

/* Non-blocking write helper for the LSP / DAP outbound queue.
 *
 * Mojo can't reach ``write(2)`` directly via ``external_call`` —
 * the stdlib registers a builtin named ``write`` with a fixed
 * signature, so the FFI declaration collides at compile time. The
 * shim sidesteps that by exposing the syscall under a unique name.
 *
 * Returns the byte count on success, 0 if the fd is non-blocking
 * and the kernel would have blocked (``EAGAIN`` / ``EWOULDBLOCK``)
 * — the caller treats this as "try again later". Returns -1 for
 * any other failure (e.g. ``EPIPE`` when the peer closed its read
 * end). The fd is expected to already be in ``O_NONBLOCK`` mode;
 * this helper does not set it. */
long tk_write_nb(int fd, const void *buf, unsigned long count) {
    if (fd < 0 || count == 0) return 0;
    ssize_t n = write(fd, buf, (size_t) count);
    if (n >= 0) return (long) n;
    if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return 0;
    return -1;
}

/* Set ``O_NONBLOCK`` on ``fd`` while preserving its other status flags.
 *
 * Why this exists: Mojo can call ``fcntl`` directly via ``external_call``,
 * but on Apple Silicon the third argument to a C variadic function is
 * passed on the stack, not in a register — that's the Darwin ARM64
 * deviation from generic AAPCS. Mojo's ``external_call`` declares a
 * fixed-arity call and puts the third arg in a register, so the kernel
 * reads garbage where the flag bitmask should be and silently leaves
 * the fd in blocking mode. The fault then surfaces a million write(2)
 * calls later as a hard hang of the UI thread inside a kernel ``write``
 * when the peer (LSP / DAP / etc.) stops draining its stdin.
 *
 * Fix: do the fcntl from C, where the compiler emits the correct
 * vararg convention for the platform. We also do the standard
 * ``F_GETFL | O_NONBLOCK`` two-step so existing flags survive (e.g.
 * ``O_APPEND`` if the caller ever passes one of those). Returns 1 on
 * success, 0 on any failure.
 */
int tk_set_nonblock(int fd) {
    if (fd < 0) return 0;
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags == -1) return 0;
    if (fcntl(fd, F_SETFL, flags | O_NONBLOCK) == -1) return 0;
    return 1;
}

/* Forward declarations for the kill-on-parent-death registry — defined
 * a few lines below. ``tk_pty_spawn`` needs to call ``tk_track_child_add``
 * from inside the parent post-fork, so we declare it here. */
void tk_track_child_add(int pid);

/* Spawn ``argv[0]`` with a fresh controlling pty.
 *
 * Returns 0 on success, -1 on failure (errno preserved). On success:
 *   *pid_out          = the child's pid
 *   *master_fd_out    = parent-side end of the pty (read child output,
 *                       write child input). Bidirectional. O_NONBLOCK
 *                       is set so the UI loop never stalls reading it.
 *
 * Why a fresh function rather than reusing the existing posix_spawn
 * path: a pty child must call ``setsid()`` *and* ``ioctl(TIOCSCTTY)``
 * on the slave fd before exec to acquire the slave as its controlling
 * terminal. ``posix_spawn`` doesn't expose ``setsid`` portably (Apple
 * has a private ``POSIX_SPAWN_SETSID`` extension that doesn't do
 * TIOCSCTTY) so we fall back to plain ``fork`` + ``execvp``. The
 * window between fork and exec is the danger zone the project
 * comment in posix.mojo warns about — we keep that window minimal
 * and stay inside C (no Mojo runtime calls).
 *
 * ``cwd`` (or NULL) is chdir'd into in the child before exec. ``term``
 * (or NULL) is set as ``TERM`` in the child's environment so programs
 * that key off it (``tput``, ``vim``, ``claude``) pick the right
 * terminfo entry. Initial window size is ``cols`` × ``rows``; pass 0/0
 * to leave it at the kernel default.
 */
int tk_pty_spawn(
    const char *file,
    char *const argv[],
    const char *cwd,
    int cols, int rows,
    const char *term,
    int *pid_out,
    int *master_fd_out
) {
    if (!file || !argv || !pid_out || !master_fd_out) {
        errno = EINVAL;
        return -1;
    }
    /* POSIX 1003.1-2008 pty opening — works on Linux + macOS without
     * linking libutil. ``O_NOCTTY`` on the master is critical: opening
     * the master fd shouldn't make this process the controlling
     * terminal owner. */
    int master = posix_openpt(O_RDWR | O_NOCTTY);
    if (master < 0) return -1;
    if (grantpt(master) < 0) { int e = errno; close(master); errno = e; return -1; }
    if (unlockpt(master) < 0) { int e = errno; close(master); errno = e; return -1; }
    const char *slave_name = ptsname(master);
    if (!slave_name) { int e = errno; close(master); errno = e; return -1; }
    int slave = open(slave_name, O_RDWR | O_NOCTTY);
    if (slave < 0) { int e = errno; close(master); errno = e; return -1; }

    /* Set the initial window size on the slave so the child's first
     * ``tcgetwinsize`` returns the right values. Without this, programs
     * that compute layout off ``$LINES``/``$COLUMNS`` first paint at
     * the kernel default of 0×0 then need a SIGWINCH to repaint. */
    if (cols > 0 && rows > 0) {
        struct winsize ws;
        ws.ws_col    = (unsigned short) cols;
        ws.ws_row    = (unsigned short) rows;
        ws.ws_xpixel = 0;
        ws.ws_ypixel = 0;
        /* Best-effort — ioctl failure on the slave isn't fatal, the
         * child will just see 0×0 and a later SIGWINCH can fix it. */
        (void) ioctl(slave, TIOCSWINSZ, &ws);
    }

    pid_t pid = fork();
    if (pid < 0) {
        int e = errno;
        close(slave); close(master);
        errno = e;
        return -1;
    }
    if (pid == 0) {
        /* Child. From here until execvp we must only use
         * async-signal-safe APIs in principle, but Mojo is
         * single-threaded so libc state isn't racy — we permit
         * ``setenv`` and ``chdir`` which need locking that's not
         * fork-safe in multi-threaded programs.
         *
         * 1) New session so the slave can become our controlling
         *    terminal. setsid drops any inherited controlling tty. */
        if (setsid() < 0) _exit(127);
        /* 2) Acquire the slave as our controlling terminal. On Linux
         *    + macOS this is the documented ioctl; arg ``0`` means
         *    "steal if necessary," which doesn't matter here because
         *    we just did setsid and have no controlling tty yet. */
        if (ioctl(slave, TIOCSCTTY, 0) < 0) {
            /* Some BSD-derived kernels (older macOS) deliver the
             * controlling-tty acquisition implicitly when the first
             * tty fd is opened in a session leader. Don't abort. */
        }
        /* 3) Wire stdin/stdout/stderr to the slave. */
        if (dup2(slave, 0) < 0) _exit(127);
        if (dup2(slave, 1) < 0) _exit(127);
        if (dup2(slave, 2) < 0) _exit(127);
        if (slave > 2) close(slave);
        close(master);
        /* 4) Optional chdir. Failure isn't fatal — the child can still
         *    run, just from the parent's cwd. */
        if (cwd && *cwd) (void) chdir(cwd);
        /* 5) Configure TERM. Setting it in the child means we don't
         *    have to rebuild a full envp array — the parent's environ
         *    is inherited verbatim, we just override one variable. */
        if (term && *term) (void) setenv("TERM", term, 1);
        execvp(file, argv);
        /* Only reached on exec failure. 127 is the conventional
         * "command not found" status used by ``sh``. */
        _exit(127);
    }
    /* Parent. */
    close(slave);
    /* Non-blocking master so the per-tick drain in the pane never
     * stalls. ``read(2)`` on a non-blocking pty returns ``EAGAIN`` when
     * empty, which the drain loop interprets as "no more for now." */
    int flags = fcntl(master, F_GETFL, 0);
    if (flags >= 0) (void) fcntl(master, F_SETFL, flags | O_NONBLOCK);
    /* Register the child with the kill-on-parent-death registry so
     * quitting the host while ``claude`` (or any pty child) is alive
     * doesn't orphan it. */
    tk_track_child_add(pid);
    *pid_out       = pid;
    *master_fd_out = master;
    return 0;
}

/* Apply a new window size to ``fd`` (the parent-side master). Sends
 * SIGWINCH to the foreground process group of the pty as a side effect
 * — that's how programs (vim, less, claude) learn to repaint. Returns
 * 0 on success, -1 on failure (errno preserved). */
int tk_pty_set_winsize(int fd, int cols, int rows) {
    if (fd < 0 || cols <= 0 || rows <= 0) {
        errno = EINVAL;
        return -1;
    }
    struct winsize ws;
    ws.ws_col    = (unsigned short) cols;
    ws.ws_row    = (unsigned short) rows;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;
    if (ioctl(fd, TIOCSWINSZ, &ws) < 0) return -1;
    return 0;
}

static int *g_pids = NULL;
static size_t g_count = 0;
static size_t g_cap = 0;

/* Add ``pid`` to the registry. Best-effort under OOM — a failed
 * realloc just means this PID won't be killed at parent exit, no
 * worse than the prior leak-and-orphan behavior. */
void tk_track_child_add(int pid) {
    if (pid <= 0) return;
    if (g_count >= g_cap) {
        size_t new_cap = g_cap == 0 ? 16 : g_cap * 2;
        int *next = (int *) realloc(g_pids, new_cap * sizeof(int));
        if (!next) return;
        g_pids = next;
        g_cap = new_cap;
    }
    g_pids[g_count++] = pid;
}

/* Remove ``pid`` from the registry. Idempotent — a no-op if the
 * pid was never tracked or has already been removed. Swap-remove
 * (replace with last entry) so removal is O(1). */
void tk_track_child_remove(int pid) {
    if (pid <= 0) return;
    for (size_t i = 0; i < g_count; i++) {
        if (g_pids[i] == pid) {
            g_pids[i] = g_pids[--g_count];
            return;
        }
    }
}

/* Snapshot-and-signal: walks the registry as it stands and SIGTERMs
 * every tracked PID. Safe to call from a signal handler — kill(2) is
 * async-signal-safe and we touch only the array, no allocator calls. */
static void tk_terminate_all(void) {
    for (size_t i = 0; i < g_count; i++) {
        if (g_pids[i] > 0) {
            kill(g_pids[i], SIGTERM);
        }
    }
}

static void tk_on_signal(int sig) {
    tk_terminate_all();
    /* Restore the default disposition for ``sig`` and re-raise so the
     * process exits with the same status it would have had without
     * our handler in the loop (e.g. shells display "Hangup" for an
     * uncaught SIGHUP). Without this dance we'd return from the
     * handler and the program would resume, which is exactly the
     * opposite of what the signal asked for. */
    struct sigaction sa;
    sa.sa_handler = SIG_DFL;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(sig, &sa, NULL);
    raise(sig);
}

__attribute__((constructor))
static void tk_install_handlers(void) {
    struct sigaction sa;
    sa.sa_handler = tk_on_signal;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    /* SIGHUP fires on PTY hangup — the macOS app's PTY teardown path.
     * SIGTERM is the conventional polite-shutdown signal anyone might
     * send (``kill <pid>``, supervisord, etc.). SIGINT is *not*
     * handled here because the terminal driver is in raw mode for
     * the editor's lifetime, so Ctrl+C doesn't generate a SIGINT
     * anyway, and we don't want to interpose on whatever upstream
     * tooling relies on default SIGINT semantics. */
    sigaction(SIGHUP, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
}

__attribute__((destructor))
static void tk_auto_cleanup(void) {
    tk_terminate_all();
}
