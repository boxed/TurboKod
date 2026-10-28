# Terminal emulation (libghostty-vt)

The shell terminal and the test runner run their child on a real pty and
render it through a terminal emulator. That emulator is
[libghostty-vt](https://github.com/ghostty-org/ghostty), the VT core of the
Ghostty terminal, built as a C library. It replaced a ~1,700-line hand-rolled
`Vt` that implemented the subset of xterm that `claude`, `vim` and `less`
happened to need.

What it gets us over the old emulator: complete xterm parsing (tab stops,
character sets, origin mode, DCS, every SGR form), reflow of soft-wrapped
lines on resize, grapheme clustering, East-Asian wide characters, the kitty
keyboard protocol, focus / bracketed-paste / mouse modes as Ghostty's own
renderer implements them, and replies to every query it understands
(DA1/2/3, DSR, DECRQM, XTVERSION, XTWINOPS size, OSC color queries).

## Layers

```
terminal_pane.mojo / test_pane.mojo     pane chrome, pty pumping
        │
terminal_view.mojo                       paint_grid, selection, key/mouse forward
        │
vt.mojo  (Vt, VtGrid)                    Mojo handle; colors → Attr, cells → Cell
        │  external_call, integers + pointers only
app/turbokod-shim/src/tk_vt.c            flat C ABI; the ONLY code that sees Ghostty
        │
libghostty-vt.a                          pinned Ghostty commit
```

`tk_vt.c` exists because Ghostty's API is sized structs, tagged unions,
callbacks and enums — and is explicitly unstable ("definitely going to
change", per its header). Mirroring that in Mojo would turn a Ghostty bump
into silent memory corruption; behind a C file it is a compile error. The
glue also translates *our* input vocabulary (`KEY_*`, `MOD_*`,
`MOUSE_BUTTON_*` from `events.mojo`, mirrored at the top of the encoder
section) into Ghostty's, so no Ghostty enum value appears in Mojo.
`tests/test_vt.mojo` pins the encodings, so a drift fails a test.

## Building

`scripts/build_ghostty.sh` clones Ghostty at `GHOSTTY_COMMIT` into
`.build/ghostty-src` and builds `.build/ghostty/lib/libghostty-vt.a` with the
pixi env's Zig (`zig` in `pixi.toml`). Its caches go under `.build/zig-cache`.
A cold build is ~1.5 minutes and runs once per pin.

The shim's `build.rs` compiles `tk_vt.c` with the `cc` crate and links
`libghostty-vt.a` as a `static=` native library. A Rust staticlib bundles
those into `libturbokod_shim.a`, so every Mojo link line that already takes
the shim — tests, `run.sh` entry points, the dylib — gets the emulator with
no change. `tk-tui` links the dylib, which exports the symbols it needs.

`ensure_shim` (`scripts/lib.sh`) runs `build_ghostty.sh` first and treats a
newer `libghostty-vt.a` as a reason to rebuild the shim. `run_tests.sh` and
`check_all.sh` call it once, serially, before their parallel builds.

**Bumping Ghostty:** change `GHOSTTY_COMMIT`, run any build, fix what
`tk_vt.c` no longer compiles against, run `scripts/run_tests.sh vt panes dap
pty`. Read the diff of `include/ghostty/vt/` between the two commits —
semantic changes (a default that flipped, a callback that now has to answer)
don't show up as compile errors. Two examples already handled:
`ghostty_key_encoder_setopt_from_terminal` resets `macos_option_as_alt`, so
the glue re-applies it after every sync; and with no `DEVICE_ATTRIBUTES`
callback Ghostty silently ignores DA queries, which stalls fish and starship.

## Ownership

`Vt` is a handle (`_h`, the `TkVt*`). Copies alias it — like `PtyProcess`
copies alias one fd — and there is no destructor, for the same reasons as
`OnigRegex` (see CLAUDE.md). The owner calls `release()`:

- `TerminalPane.release()` when its close button removes it
  (`Desktop.terminal_tick`), and from `Desktop._shutdown_non_lsp`.
- `TestPane.release()` from `Desktop._shutdown_non_lsp`.

`close()` deliberately does *not* release: a closed pane keeps its screen
so re-opening shows it. Clear / Re-run / Restart use `Vt.reset()` (RIS)
rather than building a new `Vt`, so no copy is ever left holding a replaced
handle.

`tk_vt_free` frees only a handle still in the shim's registry, so a second
release through a copy is a no-op; a released copy has `_h == 0` and every
method on it is a no-op. The real hazard is a *different* copy using the
handle after release. `vt_live_count()` is the leak gauge.

All emulator state lives on the C side. Nothing is cached in Mojo fields, so
two copies can't disagree about the cursor or the size.

## Reading cells

`Vt.grid(view=True)` returns a `VtGrid`, a view of a snapshot the glue builds
through Ghostty's render state (its fast whole-screen path) and caches until
the next `feed` / `resize` / scroll / reset. A snapshot cell is six `u32`
words — glyph offset and length into a byte arena, fg, bg, flags (style bits,
underline kind, Ghostty's wide flag) and underline color; the layout is
documented above `enc_color` in `tk_vt.c`. Paint takes one grid per frame.

`grid(view=False)` is the live screen regardless of scrolling, used by
`tail_rows` (the Claude-state detector) and `cell_at`. While the view is at
the live tail it is the same snapshot; while scrolled back the glue builds it
cell by cell through grid refs, which is slower but only happens then.

Wide characters arrive in the canvas's own shape — a `width=2` glyph cell and
an empty `width=0` continuation — so the painter needs no special case.

## Colors

Program palette colors 0..15 stay palette indices, so ANSI colors follow the
active theme like the rest of the UI. **16..255 are resolved to their xterm
RGB** (`xterm_256_rgb`) and carried as truecolor `Attr`s: our palette reserves
16..33 for editor / syntax / chrome roles (`colors.mojo`), and an index there
would paint the theme's keyword color where a program asked for the cube's
dark blue. The old emulator passed those indices through, which was a bug.
24-bit colors pass through unchanged. Default fg/bg stay `Attr()`'s.

## Character width

`char_width` (`string_utils.mojo`) uses `ghostty_unicode_codepoint_width`, the
table the terminal itself lays out with, so editors and terminal panes agree
on where a glyph lands — CJK is two cells now, not just emoji. Two departures,
both because the editor gives every codepoint a cell of its own: Ghostty's
zero-width codepoints count as 1, and regional indicators stay 1 so a flag is
two cells.

The packed layout (`host_abi.pack_canvas`) carries each cell's width in the
top byte of word 0, so the Swift renderer and `tk-tui` never recompute it.
The Swift copy of the emoji table (`charWidth`) is gone.
