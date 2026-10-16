# Spell checking and Project ▸ Spelling

## Spell checking is plain text processing

Spell checking doesn't look at syntax highlighting. `spell.find_misspelled_runs`
splits any text into words and checks each one, the same way for Python, C++,
Elm or a plain text file:

- A word is a run of letters (Unicode included — `Godkänn` is one word).
  Digits, underscores and punctuation separate words, so `foo_bar` and
  `utf8_decode` are checked as `foo`/`bar` and `utf`/`decode`.
- camelCase splits inside a run: `fooBar` → `foo` + `Bar`, `HTTPServer` →
  `HTTP` + `Server`, `parseJSON` → `parse` + `JSON`.
- An apostrophe between two ASCII letters stays in the word, so the speller's
  contraction strippers see `hasn't` whole.
- Pieces under 4 bytes and all-caps pieces (acronyms, `MAX_VALUE`) aren't
  checked.
- A line with an IntelliJ `noinspection` directive suppresses itself and the
  next line.

`spell_scan.misspelled_spans` applies that to a buffer's lines; the editor's
squiggles (`Editor._refresh_spell`) and Project ▸ Spelling both use those rules,
so the dialog lists exactly what the editor underlines. A squiggle is layered
onto whatever color the cell was painted (like LSP diagnostics), so a misspelled
identifier keeps its identifier color.

The editor re-checks only what an edit changed: per-line results are cached with
the line's text, the unchanged rows at the top and bottom are reused (matched
from both ends, so inserting a line doesn't invalidate everything below), and
`Speller.version` drops the cache when the dictionary changes. On a 16k-line
file that's 0.3 ms for a one-line edit against 21 ms for a full pass.
`test_editor_spell_incremental_matches_full_pass` pins the equivalence.

## Project ▸ Spelling

A dialog listing every flagged word across the project, grouped
case-insensitively and sorted by how often it occurs, with multi-select and
buttons to add the selection to the project (`.turbokod/dictionary.txt`) or
user dictionary.

Occurrences group by `spell_key` (the speller's case-folded lookup key) with a
trailing possessive `'s` dropped, since the speller strips that on lookup:
`Hubspot`, `hubspot` and `Hubspot's` are one row, fixed by one dictionary entry.

### Which files

`spell_scan_files`: the project's files as `walk_project_files` lists them
(`git ls-files -co --exclude-standard`, so gitignored files never appear), minus
binaries recognized by extension — including everything inside a bundle
directory with one (`Design.pxd/data/…`), checked only below the project root.
Reading a file then skips it if it has a NUL in its first 8 KB (git's own binary
test, which is why the scan doesn't ask git: `git ls-files --eol` has to read
every file to answer, 3.4 s on a 7k-file checkout), is over 2 MB, or has a line
over 5000 bytes — the editor's big-buffer rule, under which it isn't
spell-checked either.

### How it runs

`ProjectSpellScan` is stepped from the frame loop: each `step` checks whole
files (at most 2 MB, a few ms each) until a 40 ms budget is spent, so the UI
thread is never held longer than one slice. A 7k-file, 233 MB checkout takes
~2.5 s. Files are scanned largest first and progress is counted in bytes.

It is single-threaded on purpose. A `TaskGroup` version (a worker per core,
files claimed through an atomic counter) was 6× faster in a standalone
binary and crashed the app: Mojo's async runtime is set up by a Mojo `main`,
and the native app and `tk-tui` load the core as `libturbokod.dylib` from a
host that has none, so the first task dereferenced an uninitialized runtime
(SIGSEGV at 0x18 in `libKGENCompilerRTShared`). The test suites and benchmarks
are standalone Mojo binaries and can't catch this — drive the dylib from a
non-Mojo host (e.g. Python `ctypes`) to check anything that touches the async
runtime.

Both terminal loops normally wait up to 50 ms for input between frames.
`Desktop.has_background_work()` (C ABI: `tk_desktop_busy`) tells them not to
while a scan runs.

### History

The first version only checked comment and string highlights, like the editor
did then, so it had to syntax-highlight every file: ~100 s of CPU on that
checkout, nearly all TextMate. A byte-level comment/string lexer was prototyped
to replace it (it matched TextMate on 99–100% of occurrences per language, at
0.7 s), before spell checking stopped depending on the grammar at all.

### Follow-ups

- The scan reads files from disk, so unsaved buffer text isn't scanned.
