# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A port of Turbo Vision to Mojo. Two distinct trees:

- **`src/mojovision/`** — the Mojo port. **This is the product.** All new work goes here.
- **`tvision/`** — a vendored snapshot of the upstream C++ reference (`magiblot/tvision`, its own `.git` inside). **Read-only reference.** Do not edit unless explicitly asked. When porting behavior, mirror it in Mojo rather than touching this tree.

`examples/` and `tests/` are Mojo. `pixi.toml` and `run.sh` drive the toolchain.

## Running the Mojo code

```sh
./run.sh examples/hello.mojo     # demo: windowed greeting
./run.sh examples/boxes.mojo     # demo: arrow-key navigation
./run.sh tests/test_basic.mojo   # pure-data tests, no TTY required
```

`run.sh` is just `mojo run -I src "$@"` from the repo root. The `-I src` flag makes `from mojovision import ...` resolve. Pixi tasks (`pixi run hello`, `pixi run test`, `pixi run boxes`) wrap the same.

The Mojo toolchain is not installed in this checkout's environment — assume the user runs the commands. If you change the package, rely on a careful read of the diff plus `tests/test_basic.mojo` (which exercises everything that doesn't need a TTY) for confidence.

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
