# Turbokod

A port of [Turbo Vision](https://en.wikipedia.org/wiki/Turbo_Vision) to [Mojo](https://www.modular.com/mojo). The C++ reference implementation (the [`magiblot/tvision`](https://github.com/magiblot/tvision) snapshot) lives under `tvision/` for reference; the Mojo port lives under `src/turbokod/`.

## Status

Early. The current slice is enough to draw windowed UIs, handle basic keyboard input, and run a paint/poll/handle loop. Implemented:

- Geometry (`Point`, `Rect`) and colors (`Attr`, ANSI 256 palette + style bits)
- Cell-based double-buffered `Canvas` with diff-based screen updates
- Terminal driver (raw mode, alt-screen, ANSI output, escape-sequence parsing) via Python interop
- Tagged-union `Event` covering keys, mouse, resize, paste, quit
- `Drawable` trait with `Label`, `Frame`, `Fill` widgets
- `Application` driving the loop

Not yet ported: deep view hierarchy (TGroup/TWindow/TDialog), menus, dialogs, scroll bars, the editor, the help system, the streaming framework, mouse parsing, bracketed paste. See "Roadmap" below.

## Quickstart

```sh
./run.sh examples/hello.mojo     # windowed greeting, q/ESC to quit
./run.sh examples/boxes.mojo     # arrow keys move a draggable frame
./run.sh tests/test_basic.mojo   # pure-data tests (no TTY needed)
```

`run.sh` is a one-line wrapper for `mojo run -I src ...`. If you use [pixi](https://pixi.sh):

```sh
pixi run hello
pixi run test
```

## Layout

```
turbokod/
├── src/turbokod/        # the Mojo port (the actual product)
│   ├── geometry.mojo      # Point, Rect
│   ├── colors.mojo        # Attr, named colors, SGR encoding
│   ├── cell.mojo          # Cell, blank_cell, cell_width
│   ├── canvas.mojo        # 2D Cell grid + draw primitives
│   ├── events.mojo        # Event tagged-union, key/mouse codes
│   ├── terminal.mojo      # Raw-mode driver + diff renderer + input parser
│   ├── view.mojo          # Drawable trait + Label / Frame / Fill widgets
│   └── app.mojo           # Application: terminal + back canvas + loop
├── examples/              # runnable demos
├── tests/                 # pure-data tests
└── tvision/               # vendored C++ reference (read-only)
```

## Design choices vs. C++ Turbo Vision

The C++ codebase is a faithful update of a 1990s Borland design — single-inheritance hierarchies, packed 16-bit attribute words, the Borland RTL emulated for source compatibility, and the `Uses_XXXX` preprocessor mechanism for selective compilation. Most of that is a means to an end (running on DOS, fitting in 640K, compiling under Borland C++) and would be needless complexity in Mojo. Where the port deviates:

- **Composition over inheritance.** Mojo structs don't inherit, so the deep TView → TGroup → TWindow chain becomes a `Drawable` trait + concrete widget structs. Widget composition is by ownership, not by virtual dispatch up a class chain.
- **Tagged-union events instead of mode-flag + union.** Borland's `TEvent` packs four mutually-exclusive `evXxx` flags into a bitmask and switches on a union; we use one `kind: UInt8` discriminant, which is friendlier in pattern-matching-style code.
- **Cell carries a `String` glyph, not a 16-bit char.** This makes Unicode and grapheme clusters expressible at the Cell level. Width-aware paint is still a TODO but the data layout is ready.
- **256-color attributes by default.** No 4-bit BIOS attribute byte. Truecolor support is planned via an enum tag in `Attr`.
- **Python interop for the OS layer.** termios, select, ioctl-via-`os.get_terminal_size` — using Python's stdlib is cleaner than bringing up FFI shims for each platform, and is one of Mojo's headline features. Pure-Mojo FFI replacements can be slotted in later if needed.
- **No `Uses_XXXX` mechanism.** Mojo modules give us proper, fast incremental compilation. Imports are explicit per file.
- **Snake_case methods** (`put_text`, `next_event`) instead of Borland-Pascal-style camelCase (`putString`, `getEvent`). T-prefixed names are dropped: `Point` not `TPoint`, `Window` not `TWindow`.
- **No Borland-RTL shim.** The whole `compat/borland` layer that lets legacy C++ Turbo Vision sources compile is moot — we're writing Mojo from scratch.

## Roadmap

Rough order of value:

1. View tree with parent/child dispatch (the actual TGroup analogue).
2. Mouse parsing (X10/SGR mouse modes) and bracketed paste.
3. Grapheme-cluster-aware text drawing and East-Asian width handling.
4. Built-in widgets: `Button`, `InputLine`, `CheckBox`, `RadioGroup`, `ListBox`, `ScrollBar`, `MenuBar`.
5. Dialog runner (modal event loop on a sub-tree).
6. Truecolor support in `Attr`.
7. Pure-Mojo FFI termios/poll backend (drop the Python interop on the hot path).
8. Windows console backend.

## License

The Mojo port is intended to be MIT-licensed (see `LICENSE` once added). The vendored `tvision/` carries its own original license — see `tvision/COPYRIGHT`.
