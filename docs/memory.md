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
| Highlights | 9.2 MB | 1.4 MB |
| Highlight row index | 0.8 MB | 0.1 MB |
| Spell cache | 1.0 MB | 0.6 MB |
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
- **Highlights — `HighlightList` (`highlight.mojo`).** 12 bytes each
  (a 32-bit row and start, a 16-bit width, the `Attr` as a 16-bit index
  into a per-list table; a span past 64 KB is stored in pieces) instead
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

- **Spell cache.** The misspelled ranges of every row are one flat list
  with a per-row offset table (`Editor._spell_run_start` /
  `_spell_run_cols`), not a list per row: those were 24 bytes a line for
  lists nearly all empty. `_spell_text` stays a `String` per row — it is
  what makes "this row is unchanged" a pointer compare, and holding the
  string is what keeps a reused address from reading as unchanged.
- **The language server's copy of a document** shares the editor's cached
  snapshot (`Editor.lsp_text()`): opening, saving and the pre-save
  requests pass that rather than a fresh `text_snapshot()`, and a
  document found unchanged adopts the caller's string. A request slot
  drops the text it was asked about when its answer is taken. Before, a
  file merely opened was held twice until its first edit.
- **Docsets — `DocStore` (`doc_store.mojo`).** `load` parses the index and
  scans `db.json` a chunk at a time for where each body is; `html_for`
  reads and decodes the one asked for. The bodies are 5 to 45 MB a docset
  (Python 18) and were all kept, per window, from the first Ctrl+K or
  empty Cmd+click.
- **Terminal scrollback** is capped in bytes as well as lines
  (`TK_SCROLLBACK_MAX_BYTES`, 12 MB): 10,000 rows measure 8.5 MB at 80
  columns but 26 MB at 300, so the line limit alone bounded nothing.

- **Blame — `BlameTable` (`git_blame.mojo`).** One record per distinct
  commit and a 32-bit index per line. A `BlameLine` per line was 152
  bytes of string headers each: 2.9 MB for a 19k-line file, kept after
  the gutter was hidden.
- **Symbol index.** An entry's name length and owning segment are derived
  (`_ent_len` from the next entry's offset, `_ent_seg` by binary search
  over the segments) rather than stored: 13 bytes of bookkeeping an
  entry instead of 21. The lists are reserved from the file count when a
  build starts and sized from the live count in `compact`, so they don't
  double their way up leaving the outgrown blocks behind.
- **Per-row indexes are 32-bit**: `Editor._hl_row_start` and the
  tokenizer's `HighlightCache.post_stacks`.

Bounds on input that had none:

- An untracked file over 4 MB isn't diffed in the git view
  (`_UNTRACKED_DIFF_MAX_BYTES`); the panel gives its size. Its diff is
  the whole file as additions, read into a string, a diff and per-line
  lists.
- A streamed line in a `TextLog` stops at 64 KB and continues on a new
  row (`_MAX_OPEN_LINE_BYTES`): a `\r` progress bar under Cmd+R is one
  line that never ends, and `max_lines` counts lines.

Two more allocator lessons, from a crash:

- **`+=` on a `String` that a copy shares doubles its capacity** every
  time (a stdlib bug in this Mojo version). A capture that a reader
  copies after each chunk grew exponentially — tens of GB from a 5 KB
  log. Use `append_in_place` for any long-lived string that is appended
  to; see CLAUDE.md.
- **Join buffers are sized up front** (`text_snapshot`, `_disk_text`): a
  doubling `List[UInt8]` left as much again in outgrown blocks on every
  snapshot of a large file.

## Left alone

- `Editor.disk_baseline` and `_lsp_text` are a whole-file `String` each.
  The baseline has to stay byte-exact for the three-way merge; not worth
  the risk for under a megabyte a file.
- The document text the language-server session keeps (shared with
  `Editor._lsp_text`, so once per file). A `change_count` stamp could
  replace it for UTF-8 servers, but UTF-16 servers need the text for
  column conversion, and it is about thirty call sites.
- `Editor.git_change_lines` is 8 bytes a row for values 0 to 3. An empty
  list means "no git data" to the gutter's width, so it can't simply be
  dropped for unmodified files.
- `Cell` is 56 bytes, but a window-sized canvas is under 300 KB and the
  frame canvases are reused.
- The allocator's pool. `TCMALLOC_RELEASE_RATE` / `AGGRESSIVE_DECOMMIT`
  are read at load from the environment, before any of our code runs, so
  turning them on for the app means an `LSEnvironment` entry or a re-exec.
