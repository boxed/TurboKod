# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A port of Turbo Vision to Mojo. Two distinct trees:

- **`src/turbokod/`** — the Mojo port. **This is the product.** All new work goes here.
- **`tvision/`** — a vendored snapshot of the upstream C++ reference (`magiblot/tvision`, its own `.git` inside). **Read-only reference.** Do not edit unless explicitly asked. When porting behavior, mirror it in Mojo rather than touching this tree.

`examples/` and `tests/` are Mojo. `pixi.toml` and `run.sh` drive the toolchain.

## Running the Mojo code

```sh
./run.sh examples/hello.mojo     # demo: windowed greeting
./run.sh examples/boxes.mojo     # demo: arrow-key navigation
./run.sh tests/test_basic.mojo   # pure-data tests, no TTY required
```

`run.sh` does `mojo build -I src` and runs the resulting native binary. We use `mojo build` (not `mojo run`) because `mojo run` is JIT-only and silently ignores `-Xlinker` — the build step is what makes linking C deps (e.g. libonig for TextMate-grammar highlighting) actually work. Built binaries are cached under `.build/` keyed by source path; the script skips the build when no `.mojo` file in `src/` (or the entry point itself) is newer than the cached binary, so repeat runs are essentially free. Pixi tasks (`pixi run hello`, `pixi run test`, `pixi run boxes`) all route through `run.sh`.

First build of a fresh entry point is ~8–12 s; cached re-runs are ~0.5 s.

`tests/test_basic.mojo` exercises everything that doesn't need a TTY — run it via `./run.sh tests/test_basic.mojo` to verify package changes.

## Mojo port architecture

Single-pass dataflow per frame: widgets paint into the back `Canvas` → `Terminal.present` diffs against the front canvas → only changed cells are written as ANSI sequences. This is the same idea as TurboVision's `TDisplayBuffer` but expressed as plain `List[Cell]` rather than a packed 16-bit attribute buffer.

Layer boundaries (lower depends on upper, never the reverse):

```
app.py        Application: owns Terminal + back Canvas, runs the loop
  └─ terminal.mojo   Raw-mode + ANSI output + escape parser (Python interop)
       └─ canvas.mojo    2D Cell grid + draw primitives (pure Mojo)
            └─ cell.mojo, colors.mojo, geometry.mojo, events.mojo
view.mojo     Drawable trait + Label/Frame/Fill widgets — sits beside app
```

Pure-data modules (everything except `terminal.mojo` and `app.mojo`) are TTY-free and unit-testable directly.

## Syntax highlighting

Two tiers, picked by file extension in `highlight_for_extension`:

1. **TextMate grammars** for languages with a JSON file under `src/turbokod/grammars/<lang>.tmLanguage.json` and an entry in `_grammar_path_for_ext` (in `highlight.mojo`). The grammars are parsed by `tm_grammar.mojo` and tokenized by `tm_tokenizer.mojo` against `libonig` via the FFI in `onig.mojo`.
2. **Generic per-language config** (`LangSpec` registry in `highlight.mojo`) is the fallback for languages without a grammar — keyword set + comment markers + string quotes drives a small hand-rolled tokenizer.

Mojo and Python used to have a third "bespoke tokenizer" path (`_highlight_mojo_python`) for docstring-aware triple-quote handling. That's gone — both languages now go through TextMate grammars (`grammars/{python,mojo}.tmLanguage.json`). The Python grammar is hand-rolled rather than vendored MagicPython because MagicPython relies on `\1`-style end-regex backreferences that our runtime doesn't fully resolve, which made the triple-quoted string scope leak across lines.

Adding a new TextMate grammar: drop the `.tmLanguage.json` under `src/turbokod/grammars/`, add the extension → path mapping in `_grammar_path_for_ext`, and tokens with scopes the runtime recognizes (`keyword.*`, `string.*`, `comment.*`, `constant.numeric.*`, etc. — see `_scope_attr` in `tm_tokenizer.mojo`) get colored automatically. Grammars are loaded relative to cwd; `run.sh` cd's to project root before exec, so the relative paths Just Work for the bundled toolchain. The currently-shipped vendored grammars (sourced from `microsoft/vscode/extensions/<lang>/syntaxes/`, all MIT) cover Rust, Go, TypeScript/JavaScript, JSON, C/C++, Shell, HTML, CSS. Ruby, YAML, and Markdown are *bundled but unmapped* — their vscode grammars rely heavily on `while`-rules and external-grammar includes that the runtime doesn't implement yet, so they fall through to the generic per-language config tokenizer (which has Ruby + YAML specs).

Capture-group → scope mapping is implemented: a pattern with `captures: { "1": { "name": "..." } }` emits an additional Highlight per group (overlaid on the outer match's color, so the more specific scope wins). `beginCaptures` / `endCaptures` on `begin`/`end` patterns are also honored; bare `captures` on a begin/end means "applies to both sides."

Cache layering splits process-wide and per-Editor state:

* **`GrammarRegistry`** lives on `Desktop` as `grammar_registry`. Multi-grammar (parallel `keys`/`grammars` arrays). Loading a grammar happens *once per language per process*: closing one buffer and opening another in the same language reuses the already-compiled grammar instead of re-parsing the JSON and re-allocating ~125 KB-12 MB of libonig handles.
* **`HighlightCache`** still lives on `Editor` as `_hl_cache`, now stripped down to per-buffer incremental state — last `highlights` and `post_stacks` for the splice-and-early-exit logic. No grammar field. The dirty-row marker (`_hl_dirty_row`) sits next to it.

Edit handlers don't tokenize inline anymore — they only update `_highlights_dirty` / `_hl_dirty_row` via `_mark_hl_dirty`. The actual tokenization happens in `Editor.flush_highlights(mut registry)`, which `Desktop.paint` calls on every editor before drawing. Tests that need synchronous highlights call `flush_highlights(local_registry)` directly. This keeps the registry parameter from invading every public Editor method (handle_key, paste_text, replace_all, …).

The incremental path:

1. The cache stores the tokenizer's post-stack at the end of each row (`post_stacks: List[List[Frame]]`) plus the previous pass's `highlights`.
2. `_mark_hl_dirty(row)` (called from edit handlers — `handle_key`, `cut_to_clipboard`, `cut_selection`, `toggle_comment`, `toggle_case`) lowers the dirty-row marker. The marker only ever moves up toward 0 between refreshes; full retokenize is signaled by passing 0.
3. The tokenizer (`tokenize_lines_from`) starts at `dirty_row` using the cached post-stack at row `dirty_row - 1`. After each row, it compares the new post-stack against the cached one — when they match, the rest of the buffer is unchanged and we stop.
4. `highlight_incremental` splices new highlights for `[dirty_row, stable_row)` onto cached highlights for `< dirty_row` and `>= stable_row`.

Edit handlers track pre-edit row state at the top of the function (`pre_dirty_row = min(cursor_row, anchor_row)`) so the dirty marker is correct even after edits move the cursor (e.g. Enter splits a row and lands cursor on the new line below). When the lowest changed row isn't trackable (undo / redo / `replace_all`), we set dirty_row=0 (full retokenize) — correct but not faster than the non-incremental path.

Measured perf on a 1380-line Rust file with the vscode rust grammar: cold full tokenize ~180 ms; subsequent token-level edits ~180 μs (1000× faster). Scope-changing edits (e.g. opening a block comment) re-tokenize until state stabilizes; in the worst case (edit at row 0, scope never matches cached) the cost reverts to a full retokenize.

`test_textmate_incremental_matches_full_retokenize` in `test_basic.mojo` is the regression test: after a token-level and a scope-changing edit, the incremental output must equal a fresh full pass.

`_try_textmate` falls back to the generic tokenizer in three cases: no grammar bundled for the extension, the loader/runtime raised, or the grammar produced zero highlights for non-empty input. The last is the tripwire for grammars that "load fine" but rely on unimplemented features — better degrade to colored-but-cruder than a blank screen.

The runtime supports: `match`, `begin`/`end`, `begin`/`while` (per-line scope continuation), `include` (repo `#name`, `$self`, and external scope names like `source.css`), repository-group containers, `captures`/`beginCaptures`/`endCaptures`/`whileCaptures` (with optional nested `patterns` for mini-tokenize inside a capture). Defensive regex compile: patterns whose regex libonig rejects degrade to no-ops rather than crashing the load. External grammar references trigger recursive load of the embedded grammar via `_path_for_scope` (mapping scope names like `source.css` to bundled JSON paths); the embedded grammar's patterns merge into the host's flat tables and its roots register in `external_scopes` for the tokenizer to route through.

`\G` anchor handling is wired so `(?!\G)`-gated embeds (HTML's `<style>` / `<script>` blocks) actually fire. The tokenizer tracks `g_pos` per line — initialized to `-1` (sentinel: no match has fired on this line yet) and updated to each successful match's `onig_search`-reported end position. When the next search's `pos != g_pos` we pass `ONIG_OPTION_NOT_BEGIN_POSITION` so libonig's `\G` anchor refuses to match; when `pos == g_pos` we pass no flag and `\G` matches at that position. Pair that with the empty-match guard skipping the byte-bump for begin pushes (so a zero-width `(?!\G)` begin pushes its frame and body-tokenization starts *at* the matched position rather than one byte past), and HTML+CSS embedding produces real CSS highlights inside `<style>`. Embedded grammar repo entries register under `"<scope>#<name>"` with refs rewritten at compile time, so embedded `#name` references resolve to the embedded's own repo entries instead of colliding with the host's.

`OnigRegex` skips per-instance `__del__` (two attempts — plain destructor and refcounted via `ArcPointer` — both interacted badly with Mojo's destructor sequencing in this version, the second one hanging the next `onig_search` call). Cleanup runs at process exit instead: `src/turbokod/onig_shim.c` keeps a flat array of every allocated `(regex_t*, OnigRegion*)` pair, `OnigRegex.__init__` calls `tk_onig_track` to register, and a `__attribute__((destructor))` walks the registry on exit and frees them. `run.sh` compiles the C shim once and links it in alongside the Mojo binary. Verified with `leaks(1)` on macOS: a process that compiles 50 regexes and exits reports `0 leaks for 0 total leaked bytes`.

The libonig dep ships through pixi (`pixi.toml` deps), and `run.sh` plumbs `-Xlinker -lonig` and `DYLD/LD_LIBRARY_PATH` so build + exec resolve it. We use `mojo build` (not `mojo run`) specifically so `-Xlinker` actually fires — `mojo run` is JIT and silently ignores it.

## Key design decisions to preserve

These are deliberate departures from C++ Turbo Vision. Don't "fix" them by reverting:

1. **Composition, not inheritance.** Mojo structs can't inherit. Widgets are concrete structs implementing the `Drawable` trait. The deep `TView → TGroup → TWindow` chain is replaced by trait conformance and ownership.
2. **Tagged-union `Event`** with one `kind: UInt8` discriminant. Don't introduce an `evXxx` bitfield per the C++ original.
3. **`Cell.glyph` is `String`**, not a packed int. This is what makes Unicode/grapheme handling possible later. Don't compress to UInt32 to save memory unless you have a measured need.
4. **256-color `Attr`** by default, with style bits in a separate field. Truecolor goes in by adding an enum tag to `Attr` — don't pack everything into a single int.
5. **Python interop is allowed in `terminal.mojo`** (and only there). `termios`, `select`, `tty`, `os.read`, `os.get_terminal_size` — all via the Python stdlib. Pure-Mojo FFI replacement is a future optimization, not a requirement.
6. **No `Uses_XXXX` macro mechanism.** Each `.mojo` file does normal `from .module import Name` imports.
7. **Snake_case methods, no T-prefix on types.** `put_text`, `next_event`, `Point`, `Frame` — not `putText`, `getEvent`, `TPoint`, `TFrame`.

## Mojo-version sensitivity

Mojo's syntax has churned. The code targets a recent (~25.x) release and relies on:

- `@value` decorator + explicit `Copyable, Movable` trait conformance on every value-type struct.
- `mut self` / `out self` / `owned` argument conventions (no `inout`).
- `from python import Python, PythonObject` for interop.
- `String` indexed via `as_bytes()`; no `len(string)` on `String` for character count.
- Optional via `from collections import Optional`; truthiness via `if maybe_x:`, value via `.value()`.

If a Mojo version mismatch breaks compilation, the most likely culprits are: the `@value` decorator (replaced by `@fieldwise_init` in newer versions), context-manager protocol (deliberately avoided here for that reason — use explicit `start()`/`stop()` instead), and Python interop helpers (`Python.none()` vs `builtins.None`).

## C++ reference build (only when comparing to the original)

```sh
cd tvision
cmake . -B ./build -DCMAKE_BUILD_TYPE=Release
cmake --build ./build
# tests are off by default; opt in with -DTV_BUILD_TESTS=ON
./build/tvision-test --gtest_filter=Suite.Case   # single test
```

See `tvision/README.md` for the full set of CMake options. The C++ build has no role in CI for the Mojo port — its only purpose is as a behavioral reference.
