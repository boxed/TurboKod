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

## Panes in tmux (surviving a restart)

With Settings ▸ General ▸ Terminal panes ("Keep running in tmux across
restarts", `config.terminal_tmux`, on by default) a terminal or Claude pane
opened *in a project* runs a tmux client on its pty instead of `$SHELL`
(`tmux_session.mojo`). The shell lives in the tmux server, so quitting or
rebuilding the app only detaches: `PtyProcess.terminate` SIGTERMs the client,
which tmux treats as a detach. Without tmux on `$PATH`, or without a project,
the pane is a plain shell as before.

- **The default server** — the one a bare `tmux` (or an SSH app like
  ShellFish) talks to, so `tmux attach -t turbokod-claude` works from
  anywhere. The socket is still passed with `-S`, resolved as tmux does
  (`${TMUX_TMPDIR:-/tmp}/tmux-<uid>/default`, directory made `0700`), because
  `capture_command` hands children an allowlisted environment. Sharing the
  server splits the options (`tmux_session.mojo`):
  - *per turbokod session*, re-applied on every attach: no status line, no
    prefix key, mouse on (for programs that ask for mouse reports — see
    below), `allow-passthrough`, `window-size latest`. The user's own sessions keep theirs.
  - *server-wide*, because tmux has no other scope for them, and harmless to
    other sessions: `escape-time 0` (ESC reaches Claude at once),
    `focus-events`, `extended-keys`, `set-clipboard`, and truecolor/CSI-u in
    `terminal-features[247]` — a fixed slot, so re-applying replaces rather
    than appends.
  - nothing `-g`, no `-f`: `~/.tmux.conf` loads as usual if turbokod is what
    starts the server. `COLORTERM=truecolor` goes in the session's own
    environment (`new-session -e`).

  Every tmux command gets `-u` (UTF-8 whatever the locale): an app launched
  from the Dock has no `LANG`, and tmux then prints the tabs in
  `list-sessions -F` output as `_` (so no session was ever found to
  re-attach) and draws non-ASCII as `_` in the pane. Sessions created without
  a locale get `LANG=en_US.UTF-8` for their shells.
  The client runs under `env -u TMUX`, so `tk-tui` inside the user's tmux
  doesn't trip the nesting guard.
- **Scrolling and selection stay turbokod's, not tmux's copy mode** (which
  copies on mouse release and draws a `[0/123]` indicator instead of a bar).
  tmux tracks the mouse itself, so `vt.tracks_mouse()` is always true in a
  tmux pane; the pane asks tmux whether the *program* wants the mouse
  (`tmux_pane_modes`: `#{mouse_any_flag}` / `#{alternate_on}`, on a press or
  wheel step, cached 300 ms) and forwards only then. Otherwise a drag is the
  pane's own `GridSelection`, and since tmux draws on the alternate screen
  the `Vt` has no scrollback: the first wheel step (or Shift+PgUp) captures
  tmux's history plus screen (`tmux_history`, `capture-pane -e`) into a
  second `Vt`, `TerminalPane.history`, whose bottom rows are the screen. The
  pane paints, selects in and scrolls that, with a `ScrollBarArea` while
  scrolled back (in plain panes too); back at the bottom, a key, a paste or a
  resize drops it and the live grid returns. The capture is a snapshot —
  output arriving meanwhile shows on return, as in a terminal's scrollback.
- **tmux is the record of which pane belongs to which project.** A session is
  tagged with `@tk_project` (canonical root) and `@tk_cmd` (startup command —
  `claude` for a Claude pane, which Restart reuses). `Desktop._set_project` →
  `_attach_tmux_panes` lists the project's sessions and re-attaches a pane to
  each, unfocused, in creation order; `close_project` → `_detach_tmux_panes`
  detaches them. No file to drift: a session that died is simply not found,
  and one whose window crashed is.
- **Names are for people** (`new_tmux_session_name`): `<project dir>-<kind>`,
  numbered from `-2` on a clash — `turbokod-claude`, `turbokod-shell`,
  `turbokod-claude-2`. The kind is `shell` or the startup command's first
  word; anything outside `[A-Za-z0-9_-]` becomes `-`. Matching never goes by
  name (that's `@tk_project`), so same-named project directories can't swap
  panes. Over SSH it's just `tmux attach -t turbokod-claude`; with no prefix
  key in these sessions, detach by closing the connection. With
  `window-size latest` the session takes the size of whichever client typed
  last.
- **Only the pane's close button (or Cmd+W on it) ends a session**
  (`TerminalPane.kill_session`). Restart kills and recreates it under the same
  name. Typing `exit` ends it the usual way.
- The test suites never touch the user's server: `setup_test_env` points
  `TMUX_TMPDIR` at the scratch `$HOME`, and `tmux_project_sessions` spawns
  nothing unless that socket exists. `test_tmux_panes_reattach`
  and the rest of `tests/test_tmux.mojo` drive a real server end to end.

### Run panes

With tmux, Cmd+R doesn't use the pipe-backed `RunSession` / `DebugPane`: it
runs the target in a `TerminalPane` with `run_target` set
(`Desktop._target_run_in_tmux`), in a session named `<project>-run-<target>`
and tagged `@tk_run`. A dev server keeps serving through an app restart, and
the pane re-attaches with the others. Debugging (Cmd+D) still goes through
DAP and the debug pane — the adapter launches the debuggee.

- The session's process is `/bin/sh -c` around the target's command line
  (`_run_wrapper`; program and args shell-quoted, env as `new-session -e`).
  It prints `[<target> exited with N]` when the command ends and then idles,
  so the output stays. Not `remain-on-exit`: tmux paints its dead-pane line
  after a linefeed on the bottom row, scrolling the top row of the output
  away — all of it, for a one-line run.
- The pane reads that line off its grid (`_scan_run_exit`, on new output) for
  the header (`Run - <target> (exited: N)`), the status bar message and the
  status-bar tab's running flag. A re-attached pane reads it back the same
  way. For `_RUN_EXIT_GRACE_MS` after a (re)start the old line doesn't count.
- **Stop** (the pane's button, Shift+F5) is a Ctrl-C (`send-keys C-c`); the
  wrapper's `trap : INT` lets it print the exit line (130). **Restart** is
  `respawn-pane -k` — same command and env, even after a re-attach. **Cmd+R**
  replaces the session, so an edited `targets.json` applies, and stops any
  other target's run (one at a time, as without tmux). Closing the pane kills
  the session.

### Test runs

Cmd+T (and a gutter Run) works the same way with tmux: pytest runs as the
process of a session named `<project>-tests` in a run pane, so a long test
run keeps going through an app restart and the pane comes back with the
others (`Desktop._target_test_in_tmux`). Without tmux, or without a project,
the pty-backed `TestPane` runs them as before; debugging tests stays on DAP.

- The session is tagged `@tk_tests` and the pane's `tests` flag set. Its
  `run_target` is `tests` (`TESTS_RUN_TARGET`) for the title, the exit line
  and the session name, but which pane runs tests goes by the flag: a target
  named `tests` stays a target.
- Tests run *alongside* a target's run, as with the test pane: Cmd+R doesn't
  stop them, and Stop (Shift+F5) is the target's. Their own pane's Stop
  button is.
- The header reads as the test pane's: `Tests — running`, `Tests — passed`,
  `Tests — failed (N)`.
- A new run replaces the session, so a single test from the gutter gets its
  own command line; the pane's Restart re-runs the same one.
- Run panes underline `File "...", line N`, `path:N` and URLs like the test
  and debug panes (`output_links.mojo`), and a click opens them.
