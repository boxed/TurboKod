# Memory: where it goes and how to measure it

What an open project costs, the structures that were worth shrinking, and
the measuring method — the allocator makes the obvious one lie.

## Measuring

Three instruments, for three questions.

- **What does the app use?** `footprint <pid>`, `vmmap -summary <pid>` and
  `heap -s <pid>` on the running app. `untagged (VM_ALLOCATE)` is the Mojo
  heap; the `MALLOC_*` zones are the Swift host and libonig's compiled
  regexes. Launch it isolated (scratch `HOME`, `TMUX_TMPDIR`, a
  `git init`ed project) with `TK_OPEN=a,b,c` to open files and a long
  `TK_CAPTURE_DELAY` to hold it open while you look.
- **What does one structure keep alive?** Not footprint. The Mojo runtime
  allocates through a bundled tcmalloc, which keeps freed memory in a pool
  (around 10 MB after a project opens), so a short run's allocations land
  in the pool and the process doesn't grow — four more editors on a 900 KB
  file showed "+0 KB". Its exit statistics are exact: with `MALLOCSTATS=1`
  it prints "Bytes in use by application" when the process exits.
  [`bench/mem_bench.mojo`](../bench/mem_bench.mojo) runs to a chosen stop
  point and exits there with everything alive; the difference between two
  stop points is what the step between them kept.
- **Is it live or just retained?** `TCMALLOC_AGGRESSIVE_DECOMMIT=true`
  makes the allocator hand freed spans back at once; the footprint then
  tracks live data much more closely.

Two things that follow from the allocator, both learned the hard way:

- **Capacity a large list never writes to is free.** A 5 MB allocation
  with 3 MB written is 3 MB of memory. Trimming such a list to fit *costs*
  memory: the exact-size copy is written in full, and the old block goes
  to the pool, not back to the system.
- **Garbage is not free.** A list that doubles its way to 80k entries
  leaves as much again behind in outgrown blocks, and so does a 40-byte
  temporary that is compacted afterwards. Size it up front, or build the
  final form directly.

## What an open project costs

A 1000x656 window on a project with six large files open (2.9 MB of text,
60k lines):

| | Before | After |
|---|---|---|
| App footprint | 120 MB | 92 MB |
| Mojo heap | 64 MB | 41 MB |
| System heap (host + libonig) | 21 MB | 10 MB |

An empty project is 43 MB, nearly all of it the AppKit host. Launch peaks
about 120 MB above the steady state for under a second: GPU-side window
memory (`IOAccelerator (graphics)`) the system marks reclaimable straight
after. Not traced to a view.

Live bytes for one open 913 KB, 19k-line source file (`desktop.mojo`):

| | Before | After |
|---|---|---|
| Lines + the on-disk baseline | 2.8 MB | 2.8 MB |
| Highlights | 9.2 MB | 2.0 MB |
| Highlight row index | 0.8 MB | 0.2 MB |
| Spell cache | 1.0 MB | 1.0 MB |
| HEAD copy for the git gutter | 1.9 MB | 0.4 MB |
| LSP text snapshot | 0.9 MB | 0.9 MB |

## The structures

- **Spelling dictionary — `WordSet` (`word_set.mojo`).** One byte blob of
  NUL-terminated words plus an open-addressing table of 32-bit offsets:
  the word's bytes and about six more. As 8192 `List[String]` buckets it
  was 81 bytes a word, 23.6 MB for the bundled 292k words (61 MB with a
  few installed language dictionaries); now about 10 and 28, and it loads
  in 30 ms instead of 146. `load_default` sizes the set from the files'
  sizes and parses words straight from their bytes. An empty set holds
  nothing, so a `Speller` that reads the shared base costs nothing.
- **Highlights — `HighlightList` (`highlight.mojo`).** 16 bytes each
  (32-bit positions, the `Attr` as an index into a per-list table) instead
  of a 40-byte `Highlight`. It is what the tokenizers write, the cache
  keeps and an `Editor` holds. `Highlight` is still the value type:
  `hls[i]` gives one, and `to_list()` serves the callers that render a
  short text once. A source file has a highlight per dozen bytes, so keep
  anything that lives as long as a buffer in the compact form.
- **Highlights are held once.** `sync_highlights` lends the cache's list
  to the editor. The overlay path (a `language=` marker, Markdown, Django)
  needs the grammar's own output kept as well — but only when the overlay
  changed something; a file that merely mentions `language=` is lent like
  any other.
- **Row index.** `Editor._hl_order` is empty when the highlights are
  already in row order (a tokenizer's output always is); `_hl_at(k)` is
  then `k`.
- **HEAD copy.** `_split_lines_sharing` reuses the buffer's `String` for
  every line the two have in the same place, from the top or the bottom.
  A `String` copy shares its bytes, so an unmodified file's HEAD copy is a
  list of headers.
- **Grammar regexes compile on first use** (`Grammar.regex`), a `begin`
  together with its `end`. Across eight ordinary files a quarter of the
  loaded grammars' regexes are ever compiled; a Markdown file compiles 166
  of the 1,093 it pulls in for fenced code.
- **Undo.** Each editor's history is capped at 64 MB of deltas; a
  `Desktop` holds all of its editors' to 256 MB together
  (`trim_undo_history`), taking the excess from the least recently focused
  first.

## Left alone

- `Editor.disk_baseline` and `_lsp_text` are a whole-file `String` each.
  The baseline has to stay byte-exact for the three-way merge; not worth
  the risk for under a megabyte a file.
- `Cell` is 56 bytes, but a window-sized canvas is under 300 KB and the
  frame canvases are reused.
- The allocator's pool. `TCMALLOC_RELEASE_RATE` / `AGGRESSIVE_DECOMMIT`
  are read at load from the environment, before any of our code runs, so
  turning them on for the app means an `LSEnvironment` entry or a re-exec.
