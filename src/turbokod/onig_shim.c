/*
 * onig_shim.c — process-wide registry for libonig handles.
 *
 * Mojo's destructor lifecycle interacted badly with libonig's
 * region scratch when we tried to call ``onig_free`` /
 * ``onig_region_free`` from ``OnigRegex.__del__``: the destructor
 * sequencing under ``ArcPointer`` hung the next ``onig_search``
 * call on the same instance. Per-instance reclamation is therefore
 * disabled; instead, ``OnigRegex.__init__`` registers each fresh
 * ``regex_t*`` / ``OnigRegion*`` pair here, and the
 * ``__attribute__((destructor))`` below walks the list at process
 * exit and frees them in one shot.
 *
 * The cost: handles outlive their wrapping ``OnigRegex`` for the
 * remainder of the session — bounded by (#unique grammars
 * loaded) × (patterns per grammar). Empirically that's tens of
 * MB on a multi-language editor session, all reclaimed cleanly
 * at shutdown so leak detectors stay quiet.
 *
 * The C side here is deliberately minimal and self-contained:
 * forward-declares the two libonig functions it calls so we don't
 * need an oniguruma.h include path during compilation.
 */

#include <stdlib.h>

extern int  onig_free(void *reg);
extern void onig_region_free(void *region, int free_self);

typedef struct {
    void *reg;
    void *region;
} TkRegexHandle;

static TkRegexHandle *g_handles = NULL;
static size_t g_count = 0;
static size_t g_cap   = 0;

/* Track a freshly-allocated (regex_t*, OnigRegion*) pair. The
 * caller owns the lifetime contract: ``tk_onig_free_all`` (or the
 * ``__attribute__((destructor))`` auto-cleanup below) is the only
 * legitimate path that frees these. Best-effort under OOM — a
 * failed realloc means the new handle just won't be freed at exit,
 * which is no worse than the prior leak-and-let-OS-reclaim
 * behavior. */
void tk_onig_track(void *reg, void *region) {
    if (g_count >= g_cap) {
        size_t new_cap = g_cap == 0 ? 64 : g_cap * 2;
        TkRegexHandle *next = (TkRegexHandle *) realloc(
            g_handles, new_cap * sizeof(TkRegexHandle));
        if (!next) return;
        g_handles = next;
        g_cap = new_cap;
    }
    g_handles[g_count].reg = reg;
    g_handles[g_count].region = region;
    g_count++;
}

/* Free every tracked handle and drop the registry. Idempotent; a
 * second call is a no-op. Exposed (rather than only run via the
 * destructor attribute) so a host that wants deterministic
 * teardown before exit can call it explicitly. */
void tk_onig_free_all(void) {
    for (size_t i = 0; i < g_count; i++) {
        if (g_handles[i].region) {
            onig_region_free(g_handles[i].region, 1);
        }
        if (g_handles[i].reg) {
            onig_free(g_handles[i].reg);
        }
    }
    free(g_handles);
    g_handles = NULL;
    g_count = 0;
    g_cap = 0;
}

/* Run cleanup on normal process exit. ``__attribute__((destructor))``
 * is honored by both Mach-O and ELF; the function fires after
 * ``main`` returns but while libonig is still loaded, so its
 * ``onig_free`` symbol is still resolvable. */
__attribute__((destructor))
static void tk_onig_auto_cleanup(void) {
    tk_onig_free_all();
}
