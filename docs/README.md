# `docs/`

Project notes that go deeper than `CLAUDE.md`'s overview. Each file is a focused topic; read on demand.

| Topic | What it covers |
|---|---|
| [native-menu.md](native-menu.md) | How the Swift frontend's `NSMenu` mirrors Mojo's `Desktop.menu_bar` via the snapshot/invoke C ABI, with the terminal in-grid menu unchanged. |
| [sequoia-close-crash.md](sequoia-close-crash.md) | macOS Sequoia AppKit regression where `performClose` segfaults; workaround via `windowShouldClose` + `orderOut`. |
| [app-bundle.md](app-bundle.md) | How `TurboKod.app` is laid out so Dock launches find `libturbokod.dylib` regardless of CWD (`@rpath` + `Contents/Frameworks/`). |
| [baseline-transforms.md](baseline-transforms.md) | Pattern for reversible UI transforms (resize, etc.) — scale from a stored baseline so round-trips don't accumulate rounding error. |

`CLAUDE.md` at the repo root remains the orientation document; it links here for anything that doesn't fit there.
