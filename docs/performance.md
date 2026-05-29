# Rendering performance: profiling + the per-frame cost model

How to profile the drawing path, what a frame actually costs, and the
hot-path traps that have bitten us (don't reintroduce them).

## Profiling tools

The drawing cost has two halves, profiled with two tools:

- **Mojo side (headless, runs anywhere):** [`tests/bench_draw.mojo`](../tests/bench_draw.mojo)
  builds a `Desktop` with a real file open and times the per-frame
  sequence — `Desktop.paint`, the fresh-`Canvas` allocation, the
  cell-pack, and `tk_desktop_tick` — separately. Run it with
  `./run.sh tests/bench_draw.mojo`. Set `TK_BENCH_SPIN=1` to loop
  `Desktop.paint` for ~25 s so a sampling profiler can attach:
  `sample <pid> 10 1 -file out.txt`, then symbolicate stripped
  addresses with `atos -o <bin> -l <load> <addr>`.
- **Swift side (live GUI only):** [`scripts/profile_app.sh`](../scripts/profile_app.sh)
  `pgrep`s the running app and runs macOS `sample` against it, printing
  a per-function breakdown across all libraries. Core Text rasterization
  in `CellView.draw` only exists in the live process, so this is the only
  way to see it. Run it once while moving the mouse and once idle to
  compare.

**Reading `sample` output:** it samples every thread whether running or
not, so `__workq_kernreturn` and `mach_msg2_trap` (threads parked in the
kernel) dominate the flat list and are *not* CPU — ignore them. Look at
the call graph under the main thread (`-[NSApplication run]`) for the
real work: the redraw timer (`__NSFireTimer` → `CellView.pollFrame`),
the event path (`CellView.mouseMoved`), and `CellView.draw`.

## Per-frame cost model

The Swift redraw timer fires at up to 20 Hz; each tick runs
`tk_desktop_tick` (async housekeeping) then `tk_desktop_layout` (a fresh
`Canvas` + `Desktop.paint` + cell-pack into a `[codepoint, attr, underline]`
buffer), hashes the result, and only repaints (`CellView.draw`, Core
Text) when the hash changed. Measured on a 120×40 view over a large file:

| Phase | cost | notes |
|---|---|---|
| `Desktop.paint` | the whole budget | almost all of it is `Editor::paint` |
| fresh `Canvas` alloc + clear | ~negligible | not a bottleneck, despite the per-cell `String` |
| cell-pack loop | ~negligible | |
| `tk_desktop_tick` | ~negligible | LSP/DAP/terminal/external-change/git ticks are cheap when idle |

So per-frame cost lives in `Desktop.paint`, and nearly all of *that* is
`Editor.paint`. The fresh-`Canvas`-per-frame allocation looks scary
(every `Cell.glyph` is a `String`) but measured cheap — don't optimize it
without a measurement.

## Hot-path traps (do not reintroduce)

1. **`.copy()` / `var x = bigStruct` in a hot path deep-copies the whole
   Editor.** A `Window`/`Editor` copy clones the buffer, *every* syntax
   highlight, the undo stack, and the tokenizer cache. `pointer_shape_at`
   once did `self.windows.windows[i].copy()` just to read two rects — on
   *every mouse move* — and it was the single largest CPU cost while
   moving the pointer. Bind a `ref` instead, and compute small derived
   values inline (`Window.interior()` itself takes `self` by value, so
   calling it on a hovered window also copies). A bare `def m(self)`
   *borrows* (does not copy); the explicit `.copy()` is what hurts.

2. **`Editor.paint`'s overlay passes must be O(visible), not
   O(rows × all_highlights).** `self.highlights` covers the entire buffer
   (30k+ entries on a large file). Scanning the full list once per visible
   screen row was ~95% of paint time. The fix (in `Editor.paint`) buckets
   highlights by visible buffer row in one pass, so each row touches only
   its own. Any new per-row overlay (spell, diagnostics, …) should reuse
   that bucketing rather than rescanning a buffer-wide list.

3. **No ungated per-frame logging.** `debug_log` (in `posix.mojo`) is
   gated behind the `TURBOKOD_DEBUG` env var precisely because it sits in
   the paint path; ungated it fired an `open`/`write`/`close` syscall
   burst every frame. Keep diagnostics gated.

4. **The redraw timer is immediate-mode change-detection — keep it
   backed off.** With no cursor blink, a steady frame lays out identically,
   so the timer lays out + hashes only to discover nothing changed. The
   three-tier backoff in `AppController` (`idleTicks`: 0–20 full 20 Hz /
   21–60 ~10 Hz / >60 ~4 Hz) keeps that cheap. Bare mouse motion
   (`noteActivity`) clamps into the *medium* tier rather than forcing full
   rate — hover hints are dwell-based and the cursor shape is set
   synchronously in `sendMouse`, so 20 Hz during motion buys nothing.
   A frame that genuinely changes still resets to full rate.

## The floor

After the above, fast continuous mouse movement sits around ~8% CPU, and
the profile shows almost no work in our code — it's the OS delivering a
flood of mouse-move events (WindowServer → app wakeups, visible as the
main thread parked in `mach_msg2_trap` between events). A do-nothing app
pays the same. That's the OS event-delivery floor, not the renderer; the
remaining lever would be throttling how often passive moves are forwarded
to Mojo, which only helps if per-event work (not kernel delivery) is the
cost. Idle is effectively zero.
