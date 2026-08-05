# `docs/`

Project notes that go deeper than `CLAUDE.md`'s overview. Each file is a focused topic; read on demand.

| Topic | What it covers |
|---|---|
| [themes.md](themes.md) | Color themes (Settings ▸ Theme) that retint syntax + chrome together; a theme is a 256-entry RGB palette resolved at the frontend boundary (Swift palette / terminal truecolor SGR), so swapping it needs no change to the paint sites. |
| [native-menu.md](native-menu.md) | How the Swift frontend's `NSMenu` mirrors Mojo's `Desktop.menu_bar` via the snapshot/invoke C ABI, with the terminal in-grid menu unchanged. |
| [floating-panels.md](floating-panels.md) | Per-project toggle that floats the tool panels (terminal/debug/test) into a second native window; one Desktop, two render surfaces; display-config-keyed geometry with a docked fallback for roaming. |
| [sequoia-close-crash.md](sequoia-close-crash.md) | macOS Sequoia AppKit regression where `performClose` segfaults; workaround via `windowShouldClose` + `orderOut`. |
| [app-bundle.md](app-bundle.md) | How `TurboKod.app` is laid out so Dock launches find `libturbokod.dylib` regardless of CWD (`@rpath` + `Contents/Frameworks/`). |
| [baseline-transforms.md](baseline-transforms.md) | Pattern for reversible UI transforms (resize, etc.) — scale from a stored baseline so round-trips don't accumulate rounding error. |
| [case-folding.md](case-folding.md) | Branchless/SIMD ASCII case folding (`case_fold.mojo`) and the `LineSearcher` that decides per line whether a SIMD byte scan is equivalent to libonig's `(?i)`; why ASCII-only folding is safe on UTF-8, and the measurements. |
| [performance.md](performance.md) | Profiling the drawing path (headless Mojo bench + live `sample`), the per-frame cost model, the hot-path traps (deep-copying the Editor, O(rows×highlights) overlays, the immediate-mode redraw timer), and why LSP semantic highlighting was removed for performance. |

`CLAUDE.md` at the repo root remains the orientation document; it links here for anything that doesn't fit there.
