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

## Library identifiers are learned from the language server

`shutil`, `rmtree`, `getstatusoutput` — names from a library or the standard
library aren't English but aren't misspellings either. Asking the LSP about
every flagged word on every check would be far too slow, so each answer is
asked for once and kept:

- **Library names** go in `~/.config/turbokod/library_words.txt` (next to the
  user dictionary, `spell.library_words_path`), loaded with the other word
  lists by `Speller.load_default` — global, since `shutil` is a library's in
  every project.
- **Ruled-out words** go in the project's
  `.turbokod/per_user/<user>/library_negatives.txt` (`library_words.mojo`,
  `LibraryNegatives`), one `word<TAB>day` line each. Per project because
  the answer depends on what the project has installed, and an entry expires
  after 30 days (`NEGATIVE_TTL_DAYS`) because installing a package can turn
  a "no" into a "yes". Written merged with the file (two windows on one
  project keep each other's entries) at most every 2 s and at teardown.

A lookup is a background `textDocument/definition` in slots of its own on
`LspManager` (`request_library_probe` / `take_library_probe`, tagged with who
asked, timed out after 10 s), so it never disturbs Cmd+click. The definition
decides (`Desktop._on_library_probe`):

- in a library (`spell.is_library_location`: outside the project root, or
  under `site-packages`, `node_modules`, `.venv`, `.pixi`, … inside it) —
  learned, and every editor re-checks;
- in the project — the project's own identifier: ruled out;
- nowhere (a comment, a string, a typo) — inconclusive on its own; ruled out
  once three occurrences (`_LIBPROBE_TRIES`) have come back empty, or every
  occurrence Project ▸ Spelling found;
- no answer — says nothing.

Two drivers feed it:

- **The editor** (`_maybe_probe_library_word`, from `lsp_tick`, focused
  editor only): one probe in flight per server, skipping ruled-out words, the
  word under the caret (probably still being typed) and occurrences already
  asked about; once every flagged word has been tried the sweep is skipped
  until the buffer, caret or dictionary changes.
- **Project ▸ Spelling** (`_library_check_step`): after the scan, each word
  not ruled out is looked up at up to three occurrences (kept by the scan,
  `ProjectSpellScan.occurrences`), eight in flight per server, starting the
  file's language server if it isn't running. Lookups are grouped by file; a
  file no editor has open is opened on the server for its lookups and closed
  when they move on. Words found to be library names drop off the list as the
  answers arrive. A second run asks only about words it hasn't settled: the
  learned ones aren't flagged any more and the ruled-out ones are skipped.

Words are learned as the spell checker sees them — pieces, so `copyfileobj`
is learned whole but `getElementById` needs nothing. Another window learns a
word when it looks it up itself, or on its next dictionary reload.

## Project ▸ Spelling

A dialog listing every flagged word across the project, grouped
case-insensitively and sorted by how often it occurs, with multi-select (Shift
for a range, Cmd-click for words one by one) and buttons to add the selection
to the project (`.turbokod/dictionary.txt`) or user dictionary. It is a
declarative dialog (`spelling_dialog.mojo`, see
[declarative-ui.md](declarative-ui.md)), so each look draws it its own way —
a movable window of its own in the Turbo Vision look, a Platinum dialog, a
macOS sheet — and its rows move as the list re-sorts, so the selection is
kept as words.

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
