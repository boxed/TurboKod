# `docs/`

Project notes that go deeper than `CLAUDE.md`'s overview. Each file is a focused topic; read on demand.

| Topic | What it covers |
|---|---|
| [terminal-emulation.md](terminal-emulation.md) | The shell / test panes' emulator is libghostty-vt behind a flat C ABI (`tk_vt.c`) — how it is built and pinned, handle ownership (`release`, no destructor), cell snapshots, why program colors 16..255 become RGB, and the shared Ghostty width table behind `char_width`. |
| [themes.md](themes.md) | Color themes (Settings ▸ Theme) that retint syntax + chrome together; a theme is a 256-entry RGB palette resolved at the frontend boundary (Swift palette / terminal truecolor SGR), so swapping it needs no change to the paint sites. |
| [native-menu.md](native-menu.md) | How the Swift frontend's `NSMenu` mirrors Mojo's `Desktop.menu_bar` via the snapshot/invoke C ABI, with the terminal in-grid menu unchanged. |
| [declarative-ui.md](declarative-ui.md) | Declarative UI: a dialog describes itself once as a `UINode` tree; a grid projector (consistent cell layout, focus, keys) and a native AppKit projector both render it, and both report edits / actions back the same way. |
| [native-ui.md](native-ui.md) | View ▸ macOS-style UI: dialogs handed to the Swift host as real AppKit sheets (the core keeps state + submit path, the host polls a JSON description and reports the answer); phased plan toward native tabs and pickers. |
| [platinum-ui.md](platinum-ui.md) | View ▸ Mac OS 9-style UI: a third projector that lays out and draws the declarative dialogs and the confirm alert in pixels, Platinum-style (Chicago via Silom, whole-point glyph advances), with the menus left in the system menu bar. |
| [tv-frame.md](tv-frame.md) | The Turbo Vision look in the native app: windows as tabs, and the project window borderless inside a Turbo Vision frame of cells — close, zoom (full screen / Option: fill), drag, resize and a proxy icon — while the terminal keeps overlapping windows. |
| [floating-panels.md](floating-panels.md) | Per-project toggle that floats the tool panels (terminal/debug/test) into a second native window; one Desktop, two render surfaces; display-config-keyed geometry with a docked fallback for roaming. |
| [sequoia-close-crash.md](sequoia-close-crash.md) | macOS Sequoia AppKit regression where `performClose` segfaults; workaround via `windowShouldClose` + `orderOut`. |
| [app-bundle.md](app-bundle.md) | How `TurboKod.app` is laid out so Dock launches find `libturbokod.dylib` regardless of CWD (`@rpath` + `Contents/Frameworks/`). |
| [baseline-transforms.md](baseline-transforms.md) | Pattern for reversible UI transforms (resize, etc.) — scale from a stored baseline so round-trips don't accumulate rounding error. |
| [find-symbol-index.md](find-symbol-index.md) | Why Find Symbol stopped spawning `rg` per keystroke (the regex was vacuous, `--smart-case` was inert, and it cost 25× the CPU of the literal it equalled), the per-file-segment identifier index that replaced it, and the five mechanisms that keep it from going stale. |
| [project-spelling.md](project-spelling.md) | Spell checking as plain text processing — words split at underscores, digits and camelCase whatever the language, the editor's incremental per-line cache — and Project ▸ Spelling, the project-wide misspelling list it shares rules with. |
| [case-folding.md](case-folding.md) | Branchless/SIMD ASCII case folding (`case_fold.mojo`) and the `LineSearcher` that decides per line whether a SIMD byte scan is equivalent to libonig's `(?i)`; why ASCII-only folding is safe on UTF-8, and the measurements. |
| [lsp-conformance.md](lsp-conformance.md) | How the LSP client is verified when the spec ships no client conformance suite: a metaModel-driven coverage audit (`make lsp-coverage`, 63/95 methods), a scripted server (`tests/fixtures/mock_lsp.py`) driving spec-shape and adversarial fixture families through the real transport, and the position-encoding conversion — why byte columns are not `Position.character` unless the server negotiated utf-8, and why the fix is one blanket JSON walk at the transport boundary. |
| [performance.md](performance.md) | Profiling the drawing path (headless Mojo bench + live `sample`), the per-frame cost model, the git view's per-selection cost (the `git show` spawns behind each diff panel and the settle rule that keeps arrowing through a long file list cheap), the hot-path traps (deep-copying the Editor, O(rows×highlights) overlays, the immediate-mode redraw timer), and why LSP semantic highlighting was removed for performance. |

`CLAUDE.md` at the repo root remains the orientation document; it links here for anything that doesn't fit there.
