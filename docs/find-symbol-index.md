# Find Symbol: the identifier index

Why Find Symbol stopped shelling out to `rg` on every keystroke, what
replaced it, and — the part that actually needed designing — why the
replacement can't go stale.

Code: [`src/turbokod/symbol_index.mojo`](../src/turbokod/symbol_index.mojo),
wired up in `Desktop._pump_find_symbol` / `_run_find_symbol_query` /
`_prepare_symbol_index`. Tests:
[`tests/test_symbol_index.mojo`](../tests/test_symbol_index.mojo) plus the
three `test_find_symbol_*` wiring tests in `tests/test_desktop.mojo`.
Benchmark: `./run.sh tests/bench_symbol_index.mojo <repo>`.

## What the old implementation actually did

Every keystroke spawned:

```
rg --no-heading --line-number --column --color=never --smart-case \
   --max-columns 1024 --max-columns-preview \
   -e '\b[A-Za-z0-9_]*<query>[A-Za-z0-9_]*\b' -- <root>
```

Three things were wrong with that pattern, and none of them were
obvious from reading it.

**1. The regex was vacuous.** `sanitize_symbol_query` restricts the
query to `[A-Za-z0-9_.]` and only the member segment after the last `.`
reaches rg, so the interpolated text is pure identifier bytes. The
greedy `[A-Za-z0-9_]*` on either side then absorbs whatever the `\b`
was meant to anchor: for any position where the query occurs, the left
`*` can match back to a word start and the right `*` forward to a word
end, so both `\b`s are satisfied. The pattern selects exactly the lines
a literal substring search would.

Verified rather than argued. Comparing the regex against `rg -F <query>`
with case flags matched, as *sets* of `path:line:text`, over six queries
spanning 282 to 83,887 matching lines: identical, except for one line in
1,503:

```
./ruff/crates/ruff_python_parser/src/string.rs:1141:  let source = r"'\x1ó34'";
```

Rust's `\b` is Unicode-aware, so it refuses to fire between `1` and `ó`
and the regex rejects `x1ó`; a byte-literal search accepts it.
`_extract_identifier` walks ASCII-only bytes and yields `x1` either way,
so the divergence is invisible even in principle.

**2. `--smart-case` was inert.** rg switches to case-sensitive when the
*pattern* contains an uppercase letter — and `[A-Za-z0-9_]` contains
twenty-six of them. So every search ran case-sensitive regardless of
what the user typed:

| flags | matching lines for `self` |
|---|---|
| `--smart-case` (what shipped) | 71,052 |
| `--case-sensitive` | 71,052 |
| `-i` | 82,594 |

Case-sensitive is the behaviour we want for a symbol picker, but it was
an accident, not a choice. It is now the explicit
`SYMBOL_SEARCH_CASE_SENSITIVE`.

**3. The vacuous regex cost 25× the CPU of the literal it equalled.**
On a 10,844-file / 82 MB checkout, `rg --stats`:

| form | CPU "spent searching" | wall (5 warm runs) |
|---|---|---|
| the shipped pattern | **2.67 s** | 0.16 – 0.49 s |
| `-F` + bare query | **0.11 s** | 0.16 – 0.18 s |

rg's thread pool hid most of it in wall clock, so the picker felt
merely sluggish rather than obviously broken — while burning ~2.7
CPU-seconds per keypress.

## Why the fix is not "a faster matcher"

The tempting read of those numbers is "swap rg for our own SIMD scan."
`case_fold._find` already exists and is fast (16 GiB/s cache-resident,
see [case-folding.md](case-folding.md)), so it looks like free speed.

It isn't, because matching was never the bottleneck once the regex was
gone. `rg -F` was already down to 0.11 s of CPU, and the remaining wall
clock was the directory walk, ~10.8k open/read/close triples, and 82 MB
of reads. An in-process scan would have paid all of that too, minus
rg's parallelism and its gitignore and binary handling — a 2–3× win for
a meaningful pile of new code.

The actual waste was structural: **the cost scaled with the project on
every keystroke, when it only needed to scale with the project's
vocabulary.** 82 MB of source contains ~137k distinct identifiers
(2.1 MB of text). Scan once, keep the vocabulary, and a keystroke is a
sweep over a few MB instead of a subprocess over tens of MB.

## Layout: per-file segments

`blob` is a NUL-separated run of identifier names, grouped into
**per-file segments** and deduped only *within* a file. Parallel arrays
give each entry its blob offset, length, first-occurrence line/column,
and owning segment. A hit offset maps back to an entry by binary search
on `ent_off` (ascending, because segments only ever append).

The obvious alternative is one globally-deduped table. It is smaller —
2.1 MB against 4.2 MB measured by shell, before the code's own
filters — and it cannot be maintained. To retire a re-indexed file's
contribution you must know whether each of its names still occurs in
some *other* file, which needs a full inverted index. Without one you
either rebuild everything on every edit or leave ghost entries for
symbols that no longer exist.

Per-file segments make re-indexing a segment swap: one file changed, one
segment replaced, every other offset untouched. Cross-file dedupe moves
to query time, over the few hundred hits that survive the cap. That
costs roughly 2× the memory and ~0.5 ms a keystroke, against the
160–490 ms it is replacing.

Segments are append-only, so retiring one leaves its bytes in `blob`.
The SIMD pass still sweeps them (hits landing in a dead segment are
dropped on the `segments[seg].live` check) until `compact` rewrites the
blob, which it does when dead bytes cross 50%. `compact` rebuilds every
offset, so it runs only at the end of a revalidation sweep — never
while a query is in flight.

Both lookup tables are open-addressed with FNV-1a, and both replaced
loops that were quietly quadratic. The path roster was a linear scan per
path, i.e. O(files²) on a re-listing — 117M string compares on a
10.8k-file checkout, enough that the index build was by far the slowest
thing in the process. The within-file dedupe re-scanned the growing
segment with SIMD per token, O(unique² · len), which one large generated
file could stretch into seconds.

## Staleness

This is the part that matters. The index is a *cache*, never the
authority; five mechanisms, cheapest first.

1. **Unsaved edits are indexed from the buffer** (`reindex_from_text`,
   driven by `Desktop._overlay_dirty_buffers`). This is strictly *more*
   correct than the rg it replaces: rg read disk, so a symbol you had
   just typed and not saved was invisible to the old picker.

   Ordering is load-bearing and was a real bug during development: the
   build and the sweep both read from disk, so they retire any
   buffer-derived segment. The overlay must be applied *after* they
   finish. Applying it in `_prepare_symbol_index`, before the build
   runs, is silently undone.

2. **`reindex_file` patches one segment** in microseconds. The picker is
   modal, so nothing currently needs it — a save while the picker is
   closed is caught by (3) on the next open. It stays because (3) is
   built out of it, and because it is the path any future non-modal
   surface will want.

3. **A revalidation sweep on picker open.** `_prepare_symbol_index`
   refreshes the roster via `walk_project_files` (which catches adds,
   deletes and renames) and calls `begin_revalidation`;
   `revalidate_step` then re-`stat`s files in per-frame slices and
   re-indexes only those whose `(size, mtime_sec, mtime_nsec)` moved.
   Measured: 25 ms for 11,923 stats.

   Nanosecond precision is why `FileInfo` gained `mtime_nsec`. `st_mtime`
   has one-second granularity, so a rewrite landing in the same second
   *and* leaving the size unchanged was invisible — which is exactly
   what a `git checkout` of a same-size file produces.
   `test_revalidation_catches_a_same_second_rewrite` pins it. (The
   `tv_nsec` offsets — 56 on Darwin, 96 on Linux — were checked against
   `os.stat` rather than read off a header.)

4. **A cold or mid-sweep index falls back to `rg`.** `is_ready()` gates
   the fast path in `_run_find_symbol_query`, so a bug in any of the
   above costs latency, never results. When the index does become ready
   mid-session the pump sets `query_dirty` so the visible list is
   re-asked from the authoritative source.

5. **Submit-time verification.** `verify_occurrence_in` re-checks that
   the identifier really sits at the recorded `(line, column)` before
   the seed reaches `textDocument/definition`, relocating it within the
   file if it moved and reporting failure if it is gone. On failure
   `_submit_find_symbol` clears `_find_symbol_hit_path`, which the
   resolver already treats as "no textual fallback" — so it closes
   without jumping instead of navigating somewhere wrong. Note it
   verifies against the *live buffer* when one exists (via
   `_snapshot_or_read`), because a dirty file's segment came from the
   buffer; checking it against disk would report a spurious miss.

The residual gap, stated plainly: a file rewritten by an outside process
while the picker is *already open* is not noticed until the next sweep.
The old per-keystroke rg would have seen it. Mechanism 5 is what keeps
the consequence to a wasted text scan rather than a wrong jump.

## Measurements

`./run.sh tests/bench_symbol_index.mojo ~/some/large/repo`, on an
11,923-file checkout:

```
walk:                  109 ms
build (read+tokenize): 1591 ms   (cold page cache)
build, 1 MiB/frame:     377 ms   over 65 frames (warm)
  entries:            1174987
  blob bytes:         9883252

--- query (cap 500), x20 each ---
  as                     300 us   hits: 500
  get                    500 us   hits: 500
  self                  1150 us   hits: 219
  value                  700 us   hits: 500
  handle_key             400 us   hits: 2
  zzz_definitely_absent  350 us   hits: 0

revalidate, unchanged:  25 ms    stats: 11923
reindex one file:        <1 ms
```

So a keystroke went from 160–490 ms wall (and ~2.7 s CPU) to
0.30–1.15 ms single-threaded.

The worst case is the interesting one. `self` is *slowest* despite
returning the *fewest* hits of the common queries, because 219 < the
500 cap means it never short-circuits and sweeps the entire 9.9 MB blob:
1.15 ms, i.e. ~8.6 GB/s. That is the ceiling, and it is bounded by blob
size rather than by project size or match count.

Cap semantics improved incidentally. The old cap was "the first 500
unique names that happened to stream in from rg", so truncation was
decided by which files rg's thread pool reached first. The index answers
the whole query at once, so `FIND_SYMBOL_RESULT_CAP` now truncates a
*ranked* list and drops the worst matches.

## Known costs and follow-ups

- **Memory: ~33 MB per index** on that repo (9.9 MB blob plus 1.17M
  entries × 20 bytes of parallel arrays). Only paid when Find Symbol is
  actually used — the index is built lazily on first picker open, never
  on project open.
- **It is per-`Desktop`, so per-window.** Four windows on one project
  build four copies. Sharing would need process-global state, which cuts
  against the one-`Desktop`-per-window architecture and the
  `shutdown`-releases-what-it-owns discipline, so it hasn't been done.
- `ent_len` is bounded by `SYMBOL_MAX_LEN` (128) and could be a `UInt8`,
  saving ~3.5 MB. Not done: measured as noise against the blob.
- `bench_symbol_index.mojo` lives in `tests/`, not `bench/`. As a
  `bench/` entry point it took over ten minutes to compile — the query
  section, written as a loop over a `List[String]` of needles, tripped
  the same compile-time cliff that split `test_basic.mojo` into
  per-topic suites. Unrolled into a helper and moved next to
  `bench_draw.mojo`, it builds in 4 s. **If you add cases there, add
  them unrolled.**
