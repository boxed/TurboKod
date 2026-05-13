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
#include <sys/types.h>
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
