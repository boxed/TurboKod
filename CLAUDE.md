# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A port of Turbo Vision to Mojo. Two distinct trees:

- **`src/turbokod/`** — the Mojo port. **This is the product.** All new work goes here.
- **`tvision/`** — a vendored snapshot of the upstream C++ reference (`magiblot/tvision`, its own `.git` inside). **Read-only reference.** Do not edit unless explicitly asked. When porting behavior, mirror it in Mojo rather than touching this tree.

`examples/` and `tests/` are Mojo. `pixi.toml` and `run.sh` drive the toolchain. `docs/` holds longer-form notes referenced from here ([docs/README.md](docs/README.md) is the index).

## Two frontends — both must always work

The Mojo core (`src/turbokod/`) is the model; it has **two supported frontends** sitting on top of it, and both are first-class — neither may be broken by changes to the core:

1. **Terminal** — `./run.sh <entry>.mojo` builds a standalone Mojo binary that drives the user's terminal in raw mode via `terminal.mojo` (ANSI output, escape-sequence input). This is the simplest path and what `examples/` and ad-hoc demos use.
2. **Native macOS (Swift)** — `./run_swift.sh [project]` builds the Mojo core as a shared library (`libturbokod.dylib`) exposing the C ABI in `native_api.mojo`, and runs it under a Swift/AppKit host (`app/swift/TurboKod.swift`) that owns the window, menu bar, font rendering (Px437 bitmap, 8×16 cells), and input. This is the shipped desktop app (`TurboKod.app`).

Both consume the same `Desktop` / `Canvas` / `Event` machinery. New core features should reach both surfaces — terminal-only or Swift-only changes to anything below the frontend boundary are a smell. Concretely: if you touch `desktop.mojo`, `editor.mojo`, anything in `src/turbokod/` other than `terminal.mojo` or `native_api.mojo`, verify both paths still build and run.

Frontend-specific code lives only in:
- **Terminal**: `src/turbokod/terminal.mojo` (raw mode, ANSI, Python interop for `termios`/`select`) and `src/turbokod/app.mojo` (the loop).
- **Native macOS**: `src/turbokod/native_api.mojo` (`@export`-ed C ABI), `app/swift/TurboKod.swift` (AppKit host), and `app/turbokod-shim/` (Rust shim for pty / onig handle registry / listdir).

Everything else — widgets, Editor, Desktop, syntax highlighting, LSP/DAP, file tree, dialogs — is shared and must stay frontend-agnostic.

### CLI launcher (`tk`) + bundled terminal frontend

`TurboKod.app` ships a **second terminal frontend binary**, `Contents/MacOS/tk-tui`
(source: `app/tui/main.mojo`), and self-installs a `tk` CLI helper to
`~/.local/bin/tk` on first launch (`installCliHelperIfNeeded` in `TurboKod.swift`).
`tk <path>` opens the native app; `tk --tui <path>` or any SSH session
(`$SSH_CONNECTION`/`$SSH_TTY`/`$SSH_CLIENT`) runs `tk-tui` instead.

Unlike the `run.sh` terminal build (which compiles the whole core into a ~4.6 MB
standalone binary), `tk-tui` is the **C-ABI counterpart of the Swift host**: it
reaches the `Desktop` *only* through the `tk_desktop_*` C ABI in `native_api.mojo`
and rpath-loads the same bundled `libturbokod.dylib` — so it stays ~190 KB and the
bundle carries one copy of the core, not two. It reuses `terminal.mojo`'s raw-mode /
`parse_input` / diff-`present` verbatim; the only host code is the frame glue
(layout-buffer → `Canvas` unpack, `Event` → `tk_desktop_key`/`mouse`/`mod_key`/`paste`).
It imports **only** the light frontend modules + `file_dialog` — never `desktop`/
`editor`/`highlight` (that's what keeps it small; check the binary size if you add
imports). The in-grid `FileDialog` is the only frontend-owned UI (the Swift host uses
a native `NSOpenPanel` for the same Open / Quick-Open / Open-Project actions).
`run_swift.sh` builds, bundles, and ad-hoc-signs it alongside the Swift binary.

### Menu surface

`Desktop.menu_bar` holds the menu definitions for both frontends; how it's *displayed* depends on the frontend. The terminal frontend paints it in-grid; the Swift frontend hides the in-grid version and mirrors it as a native `NSMenu` via `Desktop.host_owns_menu` + the snapshot/invoke C ABI. Both surfaces share the menu data, so any change to `_build_menus` (in `native_api.mojo`) / project menu / Window menu / Edit-menu-extras logic shows up in both immediately. Don't bypass `menu_bar` by hardcoding NSMenu items in `TurboKod.swift`.

Full details in [docs/native-menu.md](docs/native-menu.md).

### Floating panels (native macOS)

A per-project toggle (View ▸ Floating panels) floats the tool panels (terminal /
debug / test) into a second native window, leaving editors + file tree in the
main window. It's a Swift-only *presentation* feature like the native menu: the
Mojo core keeps one `Desktop` and gains a `panels_detached` flag plus a parallel
`paint_panels` / `handle_panels_event` surface; the terminal frontend never turns
it on. Window geometry and the floating-vs-docked choice are remembered **per
display configuration** (keyed by `CGDisplay` UUIDs + resolutions), so unplugging
the external display the panels lived on falls back to docked automatically.

Full details in [docs/floating-panels.md](docs/floating-panels.md).

## Running the Mojo code

**Always run `make` after making a change** (build-only, no launch) so the user can test immediately. Don't leave a change unbuilt.

Two entry points: `make` (build-only, no launch) and the `./run.sh` / `./run_swift.sh` wrappers (build + launch).

Build-only (use after editing Mojo source — keeps both frontends compilable *and* refreshes the bundled dylib so a Dock relaunch of `.app` picks up the new code):

```sh
make            # build both frontends, no launch
make app        # build .build/TurboKod.app
make tui        # build examples/desktop.mojo (canonical terminal entry)
make test       # build + run every tests/test_*.mojo suite
```

Terminal path (build + launch):

```sh
./run.sh examples/hello.mojo     # demo: windowed greeting
./run.sh examples/boxes.mojo     # demo: arrow-key navigation
scripts/run_tests.sh             # pure-data test suites, no TTY required
```

Native macOS path (build + launch):

```sh
./run_swift.sh                       # restore previous session
./run_swift.sh /path/to/project      # open a project
./run_swift.sh path/to/file.mojo     # open a single file
TK_CAPTURE=/tmp/shot.png ./run_swift.sh   # headless render then quit
```

`run.sh` does `mojo build -I src` and runs the resulting native binary. We use `mojo build` (not `mojo run`) because `mojo run` is JIT-only and silently ignores `-Xlinker` — the build step is what makes linking C deps (e.g. libonig for TextMate-grammar highlighting) actually work. Built binaries are cached under `.build/` keyed by source path; the script skips the build when no `.mojo` file in `src/` (or the entry point itself) is newer than the cached binary, so repeat runs are essentially free. Pixi tasks (`pixi run hello`, `pixi run test`, `pixi run boxes`) all route through `run.sh`.

`run_swift.sh` does four builds in dependency order, each cached by mtime: the Rust shim (`app/turbokod-shim/`), the Mojo shared library (`.build/libturbokod.dylib` from `native_api.mojo`), the Swift binary (linked against the dylib + AppKit), and the `tk-tui` terminal binary (`app/tui/main.mojo`, also linked against the dylib — see the CLI-launcher section above). It then assembles `.build/TurboKod.app` and `exec`s it. The bundle layout (dylib in `Contents/Frameworks/`, `@rpath` resolution, resource chdir for Mojo's relative paths) is detailed in [docs/app-bundle.md](docs/app-bundle.md) — including the stale-bundle-dylib gotcha that `make app` exists to solve.

Both scripts honor `TURBOKOD_BUILD_ONLY=1` to skip the launch — that's how the make targets reuse them without spawning processes.

First build of a fresh entry point is ~8–12 s; cached re-runs are ~0.5 s.

### The test suites

`tests/` holds one entry point per topic — `tests/test_editor_edit.mojo`, `tests/test_git.mojo`, `tests/test_lsp.mojo` and so on — each with its own `main()` that calls every test in the file. Shared fixtures (`_key`, `_SCREEN`, `_temp_path`, `_run_git`, …) live in `tests/support.mojo`, which the suites import as a sibling module (no extra `-I` needed). Together they exercise everything that doesn't need a TTY.

```sh
scripts/run_tests.sh              # all suites: build concurrently, run serially
scripts/run_tests.sh git editor   # only suites whose filename matches a filter
```

The runner builds all suites in parallel and then runs them **one at a time** — they share a scratch `$HOME` (`/tmp/turbokod_test_home`, set up by `setup_test_env`) and a couple of tests write config files into it, so concurrent runs would race. It fails the run on any compiler warning.

When you add a test, put it in the topic file it belongs to **and add the call to that file's `main()`** — nothing auto-discovers tests. (The monolith this replaced had 43 tests that were defined but never called, which is how three of them came to encode behaviour the product had long since changed.)

This was one 23k-line `tests/test_basic.mojo` until it crossed a compile-time cliff in this Mojo version: a full `mojo build` went from ~5 minutes to over two hours, so it stopped being run at all. Same tests, 16 files, ~2m40s cold and seconds warm. Keep the files roughly under ~2.5k lines and this stays true.

None of it exercises the Swift frontend; for that, smoke-test with `TK_CAPTURE=/tmp/shot.png ./run_swift.sh` (renders one frame to PNG and quits).

### Keep the build warning-free

**Zero compiler warnings is a hard rule.** A clean build must emit *no* warnings — not "no new warnings." If you touch a file, fix any warning it emits, including pre-existing ones you happen to surface. Don't let warnings accumulate; a noisy build trains everyone to ignore the one warning that actually matters.

Mojo only reports warnings for files in the *current* build's import graph, so no single build sees all of them. **`make check` is the sweep** — it builds every entry point in the repo, runs every suite, and fails on a single warning:

```sh
make check                      # everything: all entry points + suites + warning gate
scripts/check_all.sh --quick    # same minus the test run (build + warning gate only)
```

Use it before committing. The narrower commands are still there for a fast inner loop (`make` / `scripts/run_tests.sh`), but neither is a complete sweep on its own:

- `native_api.mojo` is compiled **only** by the dylib build, so its warnings never appear in the test or TUI builds — that's where `@export` / C-ABI diagnostics live.
- `bench/*.mojo` and most of `examples/*.mojo` are compiled by **no** other target. `make` builds two entry points and `run_tests.sh` builds the suites; everything else went unchecked, which is exactly where warnings rotted unnoticed until the Mojo 1.0 bump surfaced eight of them in `bench/fold_bench.mojo`.

`make check` costs a few minutes cold (each standalone entry point is a full core compile) and is near-instant warm, which is why it's a separate target rather than part of `make`.

## Mojo port architecture

Single-pass dataflow per frame: widgets paint into the back `Canvas` → the frontend presents it. For the terminal frontend, `Terminal.present` diffs against the front canvas and writes only changed cells as ANSI sequences. For the Swift frontend, `tk_desktop_layout` packs the back canvas into a `[codepoint, fg|bg<<8|style<<16, underline]` buffer that Swift rasterizes with Core Text. Either way, the source of truth is the same `Canvas`.

Layer boundaries (lower depends on upper, never the reverse):

```
Terminal frontend                Native macOS frontend
─────────────────                ────────────────────
app.mojo                         TurboKod.swift (AppKit host)
 └─ terminal.mojo                 └─ native_api.mojo (@export C ABI)
                                       │
                ┌──────────────────────┘
                ▼
         desktop.mojo  (Desktop: windows, editors, LSP/DAP, menus)
              │
              ▼
         canvas.mojo  (2D Cell grid + draw primitives, pure Mojo)
              │
              ▼
         cell.mojo, colors.mojo, geometry.mojo, events.mojo
view.mojo   Drawable trait + Label/Frame/Fill widgets — sits beside app/desktop
```

Pure-data modules (everything except `terminal.mojo`, `app.mojo`, `native_api.mojo`, and the Swift host) are TTY-free *and* AppKit-free and unit-testable directly. The frontend boundary is `Canvas` going out and `Event` coming in — nothing below it should know whether it's running under a terminal or under AppKit.

### Bottom-docked tool panes — two transports

The bottom dock hosts three kinds of output pane, split by how the child process is wired:

- **Pipe-backed (`DebugPane`).** The **run/debug pane** (`run_manager.mojo`'s `RunSession` + `DebugPane`, pipe stdin/stdout/stderr) and the DAP "test under debugger" path. Output is a `TextLog` that decodes SGR color only. Because the child sees `isatty()==false`, the run path exports `COLUMNS`/`LINES` (sized to the pane via `Desktop._bottom_pane_term_size`) so well-behaved tools wrap to the pane width.
- **pty + `Vt`-backed (`TerminalPane`, `TestPane`).** The **shell terminal** and the **test runner** (`pytest`) run on a real controlling pty (`PtyProcess` → `tk_pty_spawn`), so the child sees `isatty()==true`: it auto-detects color, sizes from the kernel, reflows on a SIGWINCH when the pane is resized, and its `\r`/erase-driven progress line renders correctly (the `Vt` emulator interprets what `TextLog`'s `parse_sgr` would mangle). `TestPane` owns its child + grid (no separate session slot); `Desktop.test_tick` just pumps it and mirrors the exit code to the status bar.

The Vt-grid behavior shared by both pty panes — grid paint, scrollback view, selection (cell/word/line drag) + copy, and the key→pty / mouse→pty wire encodings — lives in **`terminal_view.mojo`** (`GridSelection` + `paint_grid` + `encode_key`). Each pane keeps its own `Vt` + `PtyProcess` and the chrome/title/command-strip concerns specific to it. Clickable `File "...", line N` / `path:N` traceback links are detected by **`output_links.mojo`** (shared by `DebugPane` and `TestPane`); a pane scans its visible rows each paint, underlines the spans, and turns a click into an `open_file_at`. When you add a tool pane, decide pipe vs pty by whether the child wants a TTY, and reuse `terminal_view` / `output_links` rather than reimplementing.

## Case-insensitive search

Anything that compares bytes ignoring case goes through **`case_fold.mojo`** — branchless ASCII folding (`(c - 0x41) <u 26`, `c | is_upper << 5`) with explicit 32-byte SIMD. Don't hand-inline `if 0x41 <= c and c <= 0x5A: c += 0x20` again; that idiom used to be copy-pasted in half a dozen places and each copy sat *inside* an innermost compare loop.

Find and Replace (in-file and project-wide) go through **`LineSearcher`** in `search_options.mojo`, which decides **per line** whether the SIMD scan is provably equivalent to libonig's `(?i)` (needle and line both pure ASCII) or whether that line needs the regex for Unicode case pairs. Never bypass it by calling `build_search_regex` for a find/replace loop — that's the slow path with none of the gating. Adding a new search site means constructing a `LineSearcher` and looping on `search` / `rsearch` / `search_span`.

Full details, the correctness argument for folding UTF-8 in place, and the benchmarks (`bench/fold_bench.mojo`) in [docs/case-folding.md](docs/case-folding.md).

## Settings are global, and the config file has many writers

`~/.config/turbokod/config.json` (`config.mojo`) is one file with N writers: the native app builds **one `Desktop` per window** plus an always-alive chrome Desktop for the menu bar, and every `tk-tui` process adds another. Each holds its own `TurbokodConfig`, loaded when it was created, and each `_persist_config` writes the **whole** file. Saves are frequent and mostly invisible — merely switching files persists the recents list.

So two rules:

1. **Never write the config from a snapshot.** `Desktop._persist_config` goes through `save_config_merged`, which takes an exclusive `flock` on `config.lock`, re-reads the file, three-way merges (`merge_config`: a field differing from `_config_baseline` is one *we* changed and wins; every other field keeps the on-disk value), writes, and hands back the merged config to adopt. The bare `save_config` is the unconditional overwrite — only for a holder with no baseline, i.e. a test-constructed `Desktop` that never called `load_config_from_disk`.
2. **Settings are global, so changes have to propagate.** `Desktop._poll_config_file` (from `process_external_changes`, the one per-frame hook both frontends run) re-stats the file every `_CONFIG_POLL_MS` and adopts a change made by another window or another process. An occluded window doesn't tick, but the tick precedes its next frame, so nothing stale is ever drawn. Skipped while a Settings window is open — the merge on save covers that window.

`merge_config` is driven off the **serialized keys**, not a hand-written field list, and it must stay that way. A field-by-field merge is only correct while everyone remembers to extend it; a field left out reads as "unchanged" on every save, so the setting gets reverted the instant it's written — silently. `test_merge_covers_every_persisted_field` walks the serialization and fails if that ever regresses. Adding a config field therefore means touching `_config_to_json` + `_config_from_json` and nothing else.

## Themes

A color theme (Settings ▸ Theme, default "Turbo C++ 3.0") retints **both**
syntax highlighting and the UI chrome. A `Theme` (`theme.mojo`) is just a
256-entry RGB palette; every widget paints through *palette indices* (the named
constants in `colors.mojo`) and both frontends resolve indices→RGB at the edge —
Swift via `tk_theme_palette`/`tk_theme_version`, the terminal via truecolor
`attr_to_sgr_rgb`. So swapping the palette retints everything with no change to
the ~450 `Attr(...)` paint sites. Reserved indices `16..29` (`EDITOR_BG/FG`, the
7 `SYN_*` token roles, `PANE_BG/FG`, `CARET_FG/BG`, `BORDER_FOCUS`) decouple editor + syntax +
tool-pane + caret + border colors from the ANSI-16 chrome slots. `Desktop.active_theme` owns the palette;
`set_theme` bumps `theme_version` so both frontends refetch. Theme switching is a
pure palette swap — no re-tokenize. Settings itself doesn't cover the workspace
(so the preview is live): on macOS it's a separate native window (same
second-surface pattern as floating panels, `tk_desktop_*_settings`), in the
terminal a movable/resizable in-grid dialog. Full details in
[docs/themes.md](docs/themes.md).

## Syntax highlighting

Two tiers, picked by file extension in `highlight_for_extension`:

1. **TextMate grammars** for languages with a JSON file under `src/turbokod/grammars/<lang>.tmLanguage.json` and an entry in `_grammar_path_for_ext` (in `highlight.mojo`). The grammars are parsed by `tm_grammar.mojo` and tokenized by `tm_tokenizer.mojo` against `libonig` via the FFI in `onig.mojo`.
2. **Generic per-language config** (`LangSpec` registry in `highlight.mojo`) is the fallback for languages without a grammar — keyword set + comment markers + string quotes drives a small hand-rolled tokenizer.

Mojo and Python used to have a third "bespoke tokenizer" path (`_highlight_mojo_python`) for docstring-aware triple-quote handling. That's gone — both languages now go through TextMate grammars (`grammars/{python,mojo}.tmLanguage.json`). The Python grammar is hand-rolled rather than vendored MagicPython because MagicPython relies on `\1`-style end-regex backreferences that our runtime doesn't fully resolve, which made the triple-quoted string scope leak across lines.

Adding a new TextMate grammar: drop the `.tmLanguage.json` under `src/turbokod/grammars/`, add the extension → path mapping in `_grammar_path_for_ext`, and tokens with scopes the runtime recognizes (`keyword.*`, `string.*`, `comment.*`, `constant.numeric.*`, etc. — see `_scope_attr` in `tm_tokenizer.mojo`) get colored automatically. Grammars are loaded relative to cwd; `run.sh` cd's to project root before exec, so the relative paths Just Work for the bundled toolchain. The currently-shipped vendored grammars (sourced from `microsoft/vscode/extensions/<lang>/syntaxes/`, all MIT) cover Rust, Go, TypeScript/JavaScript, JSON, C/C++, Shell, SQL, HTML, CSS. Ruby, YAML, and Markdown are *bundled but unmapped* — their vscode grammars rely heavily on `while`-rules and external-grammar includes that the runtime doesn't implement yet, so they fall through to the generic per-language config tokenizer (which has Ruby + YAML specs).

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

`test_textmate_incremental_matches_full_retokenize` in `tests/test_highlight.mojo` is the regression test: after a token-level and a scope-changing edit, the incremental output must equal a fresh full pass.

`_try_textmate` falls back to the generic tokenizer in three cases: no grammar bundled for the extension, the loader/runtime raised, or the grammar produced zero highlights for non-empty input. The last is the tripwire for grammars that "load fine" but rely on unimplemented features — better degrade to colored-but-cruder than a blank screen.

The runtime supports: `match`, `begin`/`end`, `begin`/`while` (per-line scope continuation), `include` (repo `#name`, `$self`, and external scope names like `source.css`), repository-group containers, `captures`/`beginCaptures`/`endCaptures`/`whileCaptures` (with optional nested `patterns` for mini-tokenize inside a capture). Defensive regex compile: patterns whose regex libonig rejects degrade to no-ops rather than crashing the load. External grammar references trigger recursive load of the embedded grammar via `_path_for_scope` (mapping scope names like `source.css` to bundled JSON paths); the embedded grammar's patterns merge into the host's flat tables and its roots register in `external_scopes` for the tokenizer to route through.

`\G` anchor handling is wired so `(?!\G)`-gated embeds (HTML's `<style>` / `<script>` blocks) actually fire. The tokenizer tracks `g_pos` per line — initialized to `-1` (sentinel: no match has fired on this line yet) and updated to each successful match's `onig_search`-reported end position. When the next search's `pos != g_pos` we pass `ONIG_OPTION_NOT_BEGIN_POSITION` so libonig's `\G` anchor refuses to match; when `pos == g_pos` we pass no flag and `\G` matches at that position. Pair that with the empty-match guard skipping the byte-bump for begin pushes (so a zero-width `(?!\G)` begin pushes its frame and body-tokenization starts *at* the matched position rather than one byte past), and HTML+CSS embedding produces real CSS highlights inside `<style>`. Embedded grammar repo entries register under `"<scope>#<name>"` with refs rewritten at compile time, so embedded `#name` references resolve to the embedded's own repo entries instead of colliding with the host's.

### Compiled regexes are not garbage — read this before compiling one

`OnigRegex` has no destructor, and it can't have one: copies are bitwise-aliasing (they share the `regex_t*`), so a per-instance free double-frees. Two attempts are on record — plain destructor, then refcounting via `ArcPointer`, retested under Mojo 1.0 with a manual heap refcount — and all of them broke, the later ones as heap corruption in the *next* `onig_new`. Don't re-litigate without a new experiment.

Instead, a handle registry in the Rust shim (`app/turbokod-shim/src/lib.rs`, not the long-gone `onig_shim.c`) owns every `(regex_t*, OnigRegion*)` pair: `OnigRegex.__init__` registers via `tk_onig_track`, and a `__mod_term_func` destructor frees the lot at process exit. So `leaks(1)` stays quiet — but **inside** a session, a compiled regex is retained until you explicitly release it. That makes every compile site a potential leak, and these were:

- `GrammarRegistry.set_overrides` used to drop the grammar cache, so every project open/close reloaded and stranded each language's pattern set (~8 MB with a TypeScript buffer open, per switch). It no longer evicts: cache entries are keyed by `(cache_key, path)`, which already encodes the override resolution, so a changed mapping resolves to a *different* key and misses.
- A `GitOutputMatcher` per git operation stranded ~25 KB per commit / push / pull / checkout / merge / rebase. `GitOutputMatchers` now compiles each kind once per session, and `LocalChanges.release` hands the set back at window teardown.
- `LineSearcher` per Find / F3 / Replace stranded ~1 KB a keystroke (the default search options are case-*insensitive*, so the regex path is the common one). `Editor._search_cache` (a `SearcherCache`) reuses it for a repeated needle **and releases the one it evicts**, so a *changing* needle costs one live regex rather than one per needle ever typed. Caching alone only ever fixed the repeat half.
- `highlight_for_extension` — the uncached convenience entry point — used to load a grammar, tokenize, and drop it, plus build a second throwaway registry for the injection pass: ~500 handles per call on a TypeScript buffer, ~900 with a `# language=html` marker. It's now a thin wrapper over `highlight_incremental` with a private registry it releases. **Anything that highlights the same buffer twice still wants `highlight_incremental` with a registry it keeps** — that's what makes a grammar load once per language per process.
- `find_in_project` / `replace_in_project` build a `LineSearcher` per call and release it at the end.

To hand memory back, call `release()` — explicit, never a destructor, and available on `OnigRegex` / `Grammar` / `GrammarRegistry` / `LineSearcher` / `SearcherCache` / `GitOutputMatcher(s)` / `LocalChanges`. It's safe against the aliasing problem because `tk_onig_free_one` frees only if the pair is still registered, so a second release through a copy is a no-op rather than a double free. The precondition it *can't* check is that nothing tokenizes through the released grammar afterwards, so releases belong at teardown points: `Desktop.shutdown` (see below) releases the closing window's registry, its git matchers and every editor's search cache, and `_tokenize_line` releases the back-reference end regexes it compiled for that line. `onig_tracked_count()` reports how many handles are live — that, not RSS, is what a leak regression should assert on (`test_grammar_registry_release_frees_and_leaves_the_engine_usable`, `test_desktop_shutdown_releases_its_libonig_handles`).

### Closing a window must release what it owns

`Desktop.shutdown()` is the teardown path, and `tk_desktop_free` is its only caller. It terminates the window's child processes (LSP managers, DAP, pty terminal/test panes, run + install children, the `rg` behind Find in Project / Find Symbol, and any in-flight on-save formatter) and then releases the libonig handles. Both halves are load-bearing: **no type in `src/turbokod/` can carry a destructor that does this** — `LspProcess` / `PtyProcess` copies alias fd + pid ownership, so a per-instance `__deinit__` would double-close — and the macOS app deliberately outlives its windows (`applicationShouldTerminateAfterLastWindowClosed` is False). Before it existed, closing a project window left its language servers *running* with their pipes held until the user quit the app.

If you add anything to `Desktop` that owns a child process, an fd, or a compiled regex, give it a `terminate`/`close`/`release` and call it from `shutdown`. The terminal frontend gets this for free at process exit; the native one does not. Watch for the two shapes that hide from a `shutdown` audit: a resource reclaimed *only* by a per-frame tick (a closed window gets no more frames — that's how the on-save formatters leaked), and a second instance of a type `shutdown` already handles (`LocalChanges.git_runner` is an `InstallRunner` too, and terminating `Desktop.install_runner` never touched it).

Window removal is the same story one level down. `WindowManager.close_by_index` / `close_focused` call `Window.release`; `Desktop._close_all_editor_windows` is a *third* removal path (Window ▸ Close All, and `close_project`, so every project switch) that rebuilds the list by assignment, and it has to release each dropped editor itself. `shutdown` can only reach windows that are still open, so anything a close path forgets is stranded for the life of the process.

### Reaping: `waitpid_nohang` right after `kill` never works

A `waitpid_nohang` issued immediately after a `kill` essentially always reports nothing — the signal is *delivered*, but the child hasn't been scheduled to die yet — and a tight retry loop burns its attempts in nanoseconds without giving it that chance. Every site that did this left one zombie per terminated child for the life of the process (`PtyProcess.terminate` was one per terminal-pane close and per test run). Use **`reap_child(pid)`** from `posix.mojo`: it polls with a 1 ms sleep up to a bounded budget and returns `(reaped, status)` — the status is returned because the reap *consumes* it, so a caller wanting the exit code can't go back and ask again. Don't use `waitpid_blocking` on the UI thread; a wedged child would hang the editor.

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

## Text width is codepoints, not bytes

`Canvas.put_text` paints one cell per UTF-8 codepoint. Layout code that asks "how many cells does this label take?" must do the same. Use `display_columns(s)` from `string_utils.mojo` — never `len(s.as_bytes())` — for any of:

- Dropdown / popup / dialog width that has to fit a label.
- `put_text` start positions computed by subtracting label width from a right edge (status bar right-alignment, shortcut alignment in menus).
- Title-bar offsets, tab widths, anywhere a label is centered or right-aligned.
- Loops that paint a string cell-by-cell to apply per-character styling (hotkey-first coloring, etc.) — walk codepoints, not bytes, advancing by `char_width(cp)` per glyph (see the emoji section below). See `MenuBar._paint_label_hotkey` for the canonical pattern.

`len(s.as_bytes())` is still correct for byte-level work: parsing, slicing into byte buffers, hashing, JSON encoding, `as_bytes()`-keyed comparisons. The distinction is *display column count vs. byte count*. If your `len(...as_bytes())` result is fed into a column index or a width reservation, it's wrong for any multi-byte glyph (an em dash counts as 3, ``ä`` as 2). The bug usually hides on ASCII-only test inputs and only shows up when a non-ASCII label slides in.

### Emoji are two cells; CJK is still one

`char_width(cp)` in `string_utils.mojo` is the **single source of truth** for how many cells a codepoint occupies: `2` for emoji (the standard `wcwidth` wide-emoji ranges), `1` for everything else. Every loop that converts between a byte/codepoint position and a screen column funnels through it — `Canvas.put_text`, `display_columns`, `utf8_byte_to_cell`/`utf8_codepoint_count`, the soft-wrap segmenter and `_row_cell_offset` (`text_view.mojo`), the editor's `_utf8_cell_of_byte`/`_utf8_byte_of_cell`, the `text_field` single-line equivalents, `kwarg_conceal`'s display map, the debug-pane link offsets, and the Swift renderer (which **ports the same ranges verbatim** in `charWidth` — the two MUST stay in sync). Because the editor already reasons in cells via those converters, making them width-aware keeps cursor movement, selection, soft-wrap, click hit-testing, and horizontal scroll aligned for free.

A wide glyph occupies two cells: `put_text` writes the glyph cell with `width=2` followed by an **empty `width=0` continuation cell**. The terminal `present` skips continuation cells (the terminal advanced its own cursor across the glyph) and advances by `cell.width`; the Swift host packs the continuation as a space and draws the emoji across `2·CELL_W` (two-pass render: all backgrounds, then glyphs, so the next cell's bg fill can't erase the wide glyph's right half). A wide glyph that won't fit before the right edge isn't painted.

When a cell column lands on the **right half** of a wide glyph, the cell→byte converters snap to the glyph's start — you can't park a cursor inside an emoji.

East-Asian fullwidth (CJK) and zero-width combining marks are **still not modeled** — only emoji widen. Regional-indicator letters (flags) deliberately stay width 1 so a two-codepoint flag reserves two cells total, matching most terminals. If CJK ever needs real wide handling, extend `char_width` (and its Swift twin) — everything downstream already respects it. The regression test is `test_emoji_double_width` in `tests/test_misc.mojo`.

## Jump-to commands center at the golden ratio

**Every deliberate "jump to a location" parks the target at the golden-ratio line (~38% down the viewport), not at the top or a screen edge.** Use `Editor.reveal_cursor(view, golden=True)` after a `move_to`. This applies to *all* of them — go-to-definition / references / type-def / implementation / declaration, go-to-line, go-to-symbol, find-symbol, nav-history back/forward, output-pane / `turbokod://` link opens, next/previous git-change (`goto_change_chunk`) including the review-mode changeset reviewer, and clicking a stack frame in the debug pane (`consume_frame_click`). When you add a new navigation command, golden-reveal it too. (Debugger *single-stepping* is the one navigation that deliberately stays edge-scroll — the stop-event jump in `dap_tick` uses `golden=False` so stepping line-by-line doesn't yank the view.)

The deliberate exceptions: **iterative search** (Find Next/Prev, Replace's step-to-next) uses a large symmetric margin (`margin_below=10, margin_above=10`) so stepping through matches doesn't yank the view on every hit; and **non-jumps** (typing, paste, fold toggle — anything that just keeps the existing caret visible) use the plain edge-scroll `_scroll_to_cursor`. The single source of truth for the golden line is the `golden` path in `reveal_cursor` (`editor.mojo`).

## Mojo-version sensitivity

**The code targets Mojo 1.0.0**, pinned via `modular = ">=26.5"` in `pixi.toml`
(that's the `modular` release whose `mojo` is 1.0.0 — check with `pixi run mojo --version`).
Mojo's syntax churned a lot pre-1.0; 1.0 is the stable baseline. The idioms in use:

- `@fieldwise_init` + explicit trait conformance (`Copyable, Movable`) on value-type structs — *not* the old `@value`.
- Every function is `def`. There is no `fn` in this codebase, including `@export def` for the C ABI.
- `var` on every declaration — implicit declarations are deprecated.
- Argument conventions: `mut self` / `out self` / `var` (owned) / `imm` (the old `read`). No `inout`.
- `__deinit__(deinit self)` — *not* `__del__`.
- Optional via `from std.collections.optional import Optional`; truthiness `if maybe_x:`, value `.value()`, move-construct `Optional[T](x^)`.
- `from python import Python, PythonObject` for interop (only in `terminal.mojo`).

Pointers and unsafe operations carry an explicit `unsafe_` marker in 1.0:

| use | spelling |
| --- | --- |
| pointer type | `Pointer` / `MutPointer` (not `UnsafePointer`) |
| untracked origin | `MutUntrackedOrigin` (not `MutExternalOrigin`) |
| subscript | `p[unsafe_offset=i]` (not `p[i]`) |
| offset | `p.unsafe_offset(i)` (not `p + i`) |
| load / store | `unsafe_load` / `unsafe_store` / `unsafe_bitcast` |
| init / destroy | `p.unsafe_write(v)` / `p.unsafe_deinit_pointee()` |

Strings and spans:

- `StringSpan`, not `StringSlice` (the old name is a deprecated alias).
- `Span` is in the prelude — don't import it (`from std.memory.span import Span` no longer resolves).
- Building a `String` from a raw byte pointer is
  `String(StringSpan(unsafe_from_utf8=Span(unsafe_ptr=p, length=n)))`. This
  incantation appears ~100 times; it replaced `StringSlice(ptr=…, length=…)`.
- `len()` on a `String`/`StringSpan` is a hard error (byte/codepoint/grapheme is
  ambiguous). This codebase says `len(s.as_bytes())` for bytes — see
  "Text width is codepoints, not bytes" above for when that's the wrong question.

Three things bite when porting older code, all of which the 1.0 compiler catches:

1. **`@export` needs an explicit `abi("C")` effect**, in the same slot as `raises`:
   `def tk_desktop_new() abi("C") -> Int:`. Without it you get a warning, not an
   error — but every C-ABI entry point in `native_api.mojo` has it.
2. **The borrow checker is stricter about self-assignment through a span.**
   `s = String(StringSpan(unsafe_from_utf8=s.as_bytes()[…]))` is rejected —
   the `as_bytes()` span borrows `s` while the assignment overwrites it. Build
   into a temporary and move: `var t = …; s = t^`. Same for calling
   `Optional.value()` twice when the first result's interior reference is still
   live (see `lsp.mojo`'s trace paths).
3. **Recursive types need an explicit `__deinit__`.** `List[T]`'s conditional
   `Deinitable` conformance can't be proven for `T` while `T`'s own conformance
   is still being computed, so a struct holding a `List[Self]` reports
   `field has non-'Deinitable' type`. Declaring `__deinit__` breaks the cycle;
   fields are still destroyed automatically. `JsonValue` in `json.mojo` is the
   worked example, with the reasoning in a comment.

The context-manager protocol is still deliberately avoided — use explicit
`start()`/`stop()` instead.

## C++ reference build (only when comparing to the original)

```sh
cd tvision
cmake . -B ./build -DCMAKE_BUILD_TYPE=Release
cmake --build ./build
# tests are off by default; opt in with -DTV_BUILD_TESTS=ON
./build/tvision-test --gtest_filter=Suite.Case   # single test
```

See `tvision/README.md` for the full set of CMake options. The C++ build has no role in CI for the Mojo port — its only purpose is as a behavioral reference.
