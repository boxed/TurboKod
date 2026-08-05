# Case folding and case-insensitive search

Every case-insensitive comparison in the codebase — the editor's Find, project-wide
find/replace, and the pickers (quick open, symbol search, type-ahead, the file tree,
dropdowns) — funnels through **`src/turbokod/case_fold.mojo`**. This note covers why
it exists, what its correctness argument is, and where the remaining headroom is.

The design follows GitHub's Blackbird write-up, [*Don't stop early: case-folding source
code at memory
speed*](https://github.blog/engineering/architecture-optimization/dont-stop-early-case-folding-source-code-at-memory-speed/).
Two of its ideas do all the work here; the third (a 1776-byte compressed Unicode fold
table with a paged bitmap and SWAR run search) is deliberately **not** ported — we have
libonig for the Unicode cases and they're rare enough that a table would be dead weight.

## The two ideas

**Branchless.** `(c - 0x41) <u 26` is an unsigned range test with no conditional, and
`c | (is_upper << 5)` applies the fold with no conditional store. Worth ~3× on its own,
but the real point is that a loop with no data-dependent control flow vectorizes.

**Don't stop early.** The tempting shape is "scan until the first non-ASCII byte, then
hand off to a Unicode path." That's a data-dependent loop exit and nothing vectorizes
around it. Instead, OR every byte into an accumulator and test it *once* at the end.

In this repo the second point is not merely a speed argument. Em dashes in comments are
everywhere: over a 1.7 MB corpus of ten real `src/turbokod/*.mojo` files, **the first
non-ASCII byte appears at offset 117.** An early-exiting fold would give up on
essentially every source file we have.

## Why ASCII-only folding is safe on UTF-8

The fold only ever rewrites bytes `0x41..0x5A`. Those bytes never occur inside a
multi-byte UTF-8 sequence (lead bytes are ≥ 0xC2, continuation bytes are 0x80..0xBF), so
folding a UTF-8 buffer:

* cannot corrupt it;
* is byte-length-preserving, so match offsets map 1:1 onto the original buffer — no
  offset translation, and the editor's selection columns stay correct;
* cannot produce a spurious match, since a folded needle byte is ASCII and therefore any
  byte it matches is ASCII too, so a hit never starts or ends mid-codepoint.

What it does **not** do is fold non-ASCII case pairs (`Ä`/`ä`, and the ASCII-adjacent
oddities like `ſ`→`s` or `K` U+212A→`k`). That's the entire correctness question, and
`LineSearcher` is where it's answered.

## `LineSearcher`: per-line fast/slow decision

`search_options.mojo`'s `LineSearcher` is the matcher every find/replace site goes
through. Per line it asks: *can a branchless SIMD byte scan answer this, or does it need
libonig?* The fast path applies when the search is a plain substring search (no `W`, no
`.*`) **and** either the search is case-sensitive, or both the needle and the line are
pure ASCII.

The gate is **per line, not per file** — the same "don't stop early" lesson one level up.
One em dash in a comment costs one slow line, not a slow file.

`case_fold.scan_folded` is what makes that cheap: it returns the match *and* whether the
region was pure ASCII, in one pass. The obvious two-pass version (`is_ascii(line)` then
search) reads every line twice.

The subtle part of `scan_folded` is that it **does not stop at the first match**. It keeps
accumulating high bits to the end of the haystack, because a hit is only trustworthy if
the *whole* region is ASCII: with non-ASCII in play, a Unicode fold could match something
starting *before* our hit and the right answer would be that earlier position. Only the
matching work is skipped after a hit; the OR keeps running, at one instruction per lane.

Regex mode never takes the fast path, and `replace_in_project` keeps the whole-file
libonig walk for it, because `^` / `$` and lookaround are defined against the whole text —
chunking by line would quietly change what the user's pattern means.

The regression test is `test_line_searcher_matches_libonig_exactly` in
`tests/test_case_fold.mojo`: both paths run against the same corpus of ASCII and
non-ASCII lines and must report identical spans. `test_scan_folded_reports_non_ascii_even_after_a_hit`
pins the no-early-exit contract, and `test_fold_and_search_cross_simd_lane_boundary`
covers off-by-ones in the 32-byte lane loop.

## Measurements

`bench/fold_bench.mojo`, 1.7 MB corpus, Apple Silicon. Rerun it with
`./run.sh bench/fold_bench.mojo`.

Raw fold throughput:

| | |
|---|---|
| branchy per-byte (the idiom this replaced) | 1173 MiB/s |
| scalar branchless (accumulator + bit-5 OR) | 3253 MiB/s |
| explicit 32-byte SIMD, same formula | **54766 MiB/s** |

Case-insensitive literal search, line by line (what ships):

| | |
|---|---|
| per-line libonig `(?i)` (what this replaced) | ~270 MiB/s |
| `LineSearcher`, case-insensitive | ~1.1 GiB/s |
| `LineSearcher`, `Cc` on (no ASCII check needed) | ~3 GiB/s |

Quick-open filtering, 20k candidates, per keystroke:

| | |
|---|---|
| before (query re-split per candidate) | 7.2 ms |
| after (`split_query_parts` hoisted, folded once) | 1.4 ms |

## Headroom left on the table

Two things are known-slower than they need to be:

* **Line granularity caps the search at ~4×.** The same folding scan over one flat blob
  runs at **16 GiB/s** versus 1.1 GiB/s line by line — at a typical ~46-byte source line
  the cost is per-call overhead, not bytes. Line granularity is what buys the per-line
  libonig fallback and the result line numbers. A two-tier scheme (scan the whole file
  blob; if `ascii_only`, trust it wholesale and only fall back to per-line when the file
  has non-ASCII) would recover most of that, at the cost of a second code path.
* **Pickers still search candidate-by-candidate.** Concatenating the candidate list into
  one folded blob and sweeping it in a single SIMD pass measured 1 ms vs 4 ms for 20k
  candidates, but needs an offset table to map hits back to rows.

Neither is currently a bottleneck a user would notice.

Note that folding *by itself* buys almost nothing: a scalar byte search over a pre-folded
buffer clocks 654 MiB/s, slower than the branchy fused version. The fold's value is that
it turns case-insensitive matching into plain byte matching, which then vectorizes. That
is why the search functions fold the haystack **in register** (two extra SIMD ops per 32
bytes) rather than materializing a folded copy.
