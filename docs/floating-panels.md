# Floating panels (native macOS)

A per-project toggle that moves the **tool panels** (terminal panes, the
run/debug pane, and the test pane) out of the main project window and into a
**second native window** of their own. The file tree and editor windows stay in
the main window, which reclaims the bottom rows the panels used to occupy.

This is a **Swift-frontend-only presentation feature**, in the same sense the
[native menu](native-menu.md) is: the Mojo core gains a small, frontend-agnostic
notion of "the panels render on a separate surface," and the terminal frontend
simply never turns it on (so it always renders docked, exactly as before). All
panel *state* — pty processes, debug session, scrollback, focus — stays on the
one `Desktop`; only *where its cells are painted and which window feeds it
events* changes.

The motivating use case is roaming: dock the panels onto an external display,
keep editors on the laptop. Unplug, and the layout falls back to docked
automatically.

## Why this shape

The hard constraint is the existing model: **one `NSWindow` ↔ one Mojo
`Desktop`**, and `Desktop.paint` renders *everything* (file tree, editors,
panels, status bar) into a single cell grid via `tk_desktop_layout`. The tool
panels are bottom-docked; they consume vertical space through
`workspace_rect`'s bottom subtraction and paint in `Desktop.paint`.

Two surfaces, **one Desktop** is the right decomposition:

- A second `Desktop` would duplicate (and then have to re-sync) the project,
  LSP, DAP, terminal, and focus state the panels are wired into. Rejected.
- A second *render surface* over the same `Desktop` keeps a single source of
  truth. The main window asks the Desktop to paint *without* the panels; the
  panel window asks it to paint *only* the panels. Events from each window route
  to the matching half. This is the chosen design.

So `Desktop` gains one flag, `panels_detached`, and a parallel
paint/event entry point for the panel surface. When `panels_detached` is false
(the only state the terminal frontend ever uses) nothing changes.

## Mojo core changes

`Desktop.panels_detached: Bool` (default `False`), set by the host via
`tk_desktop_set_panels_detached`.

When `panels_detached` is **true**:

- `workspace_rect` stops subtracting `_terminal_stack_height`,
  `_debug_pane_height`, and `_test_pane_height` from the bottom — the editor
  area grows to fill the freed rows. The status/tab strip (`_bottom_chrome_height`)
  still belongs to the main window and is still reserved.
- `Desktop.paint` skips the `terminal_panes` / `debug_pane` / `test_pane` paint
  calls (the main grid no longer shows them).
- Mouse hit-tests and the resize-edge checks for those panels are skipped on the
  main surface (`handle_event`), since they're not painted there.

The panel surface gets its own entry points on `Desktop`:

- `paint_panels(mut canvas, screen)` — lays the visible tool panels out to
  **fill** the panel window and paints them.
- `handle_panels_event(event, screen)` — routes a key/mouse event using the
  panel-window-local rects.
- `pointer_shape_panels(pos, screen)` — pointer hint for the panel window.

### Panel-window layout

In the panel window there is no editor area, no file tree, and no status bar to
work around — the panels own the whole grid. `_panel_window_slots(screen)`
returns one `Rect` per visible panel in a fixed order:

```
terminal_panes[0]
terminal_panes[1]
...
debug_pane   (if visible)
test_pane    (if visible)
```

Each slot takes its `dock.effective_height` (with `bottom_chrome = 0` and
`screen` = the panel window), stacked top-to-bottom. The **last non-minimized
panel absorbs any remaining rows** so the window is always fully used; if the
heights overflow, later panels are clamped. The existing min/max state machine
still works — `MAXIMIZED` fills, `MINIMIZED` collapses to its one header row.
Both `paint_panels` and `handle_panels_event` walk this same slot list so paint
and hit-testing never disagree.

The absorber is the last *non-minimized* panel, not simply the last one. If the
last panel absorbed unconditionally, minimizing the bottom panel would do
nothing — it would re-absorb every row it just gave up. So a minimized panel
always keeps its single header row wherever it sits, and the rows it frees go to
the nearest non-minimized panel above it. When *every* panel is minimized the
last one absorbs (there's no non-minimized panel to hand the space to).

#### Resize is top-anchored, driven by the host

The docked stack is **bottom-anchored**: a panel grows upward from a fixed
bottom, so its own top border is the drag handle and `height = bottom - cursor`.
The floating stack is the opposite — **top-anchored**, stacking downward — so a
panel's top is pinned by the panels above it and the boundary between two panels
is the *lower* panel's top border. Dragging that splitter must resize the panel
**above** it (whose top stays put), via `preferred_height = cursor.y - top`.

So the panel's own chrome must *not* self-resize in the panel window: panes are
routed through `handle_mouse(..., allow_resize=False)`, which makes
`handle_bottom_dock_chrome_mouse` treat a bare top-border press as focus-only.
The actual resize is owned by `Desktop._panels_drive_resize` —
`_panel_splitter_upper` maps a press to the panel above the splitter (excluding
the lower panel's chrome buttons; the upper must be `NORMAL`), starts its
`dock.resizing`, and in-flight motion sets that upper panel's `preferred_height`
(clamped to keep `DOCK_MIN_HEIGHT` rows for the lower panel(s)).
`pointer_shape_panels` shows `ns-resize` over a splitter or during a drag. A lone
panel fills the window and has no splitter, so it's correctly non-resizable.

If **no** tool panels are visible, the host **orders the panel window out**
(hides it) while leaving floating mode on — `panels_detached` stays true and the
window object lives on in `panels[id]`, it's just not on screen. The moment a
panel reopens (a terminal, the debug pane, the test pane) the window is ordered
front again. This is driven by polling `tk_desktop_panels_visible_count` once per
tick: `count == 0` → `orderOut`, `count > 0` while hidden → `orderFront` (not
`makeKey`, so reopening a panel doesn't yank focus off the editor). The
toggle/restore paths skip the initial `orderFront` when the count is zero so an
empty window never flashes for a tick before the auto-hide catches it.

`paint_panels` still has its empty-state hint ("No panels open — open a terminal
with Cmd+Shift+T") as a defensive fallback, but with auto-hide the floating
window is never on screen while empty, so the hint isn't normally seen.

### Menu surface

A new **View ▸ Floating panels** item, checkable, action
`app.toggle_floating_panels`. Added in `native_api._build_menus` so both
frontends share the definition (per the menu-surface rule in
[native-menu.md](native-menu.md) — never hardcode NSMenu items in Swift). The
checkmark mirrors `panels_detached`, synced each tick in
`_refresh_menu_visibility`. The action is a **host action**: `dispatch_action`
returns it unhandled, `_action_code` maps it to `ACT_TOGGLE_FLOATING_PANELS`,
and Swift owns the actual window create/destroy and then calls
`tk_desktop_set_panels_detached` to update the flag (and thus the checkmark).

The terminal frontend doesn't surface a floating toggle; the item is harmless
there (it would just be a no-op host action), but to keep the in-grid menu
honest the item is only added when the host owns the menu.

## C ABI additions (`native_api.mojo` + `turbokod.h`)

```c
void    tk_desktop_set_panels_detached(int64_t h, int64_t on);
int64_t tk_desktop_layout_panels(int64_t h, int64_t cols, int64_t rows,
                                 int64_t out_ptr, int64_t cap);
int32_t tk_desktop_panels_key(int64_t h, uint32_t key, uint8_t mods,
                              int64_t cols, int64_t rows);
int32_t tk_desktop_panels_mouse(int64_t h, int64_t x, int64_t y,
                                uint8_t button, uint8_t pressed, uint8_t motion,
                                uint8_t mods, int64_t cols, int64_t rows);
int32_t tk_desktop_panels_pointer_shape(int64_t h, int64_t x, int64_t y,
                                        int64_t cols, int64_t rows);
```

`tk_desktop_layout_panels` packs the same `[codepoint, fg|bg<<8|style<<16,
underline]` 3-word-per-cell buffer as `tk_desktop_layout` — the panel window's
`PanelCellView` rasterizes it with the identical Core Text path. The `_panels`
key/mouse functions return the same `ACT_*` codes (so e.g. a link click in the
debug output can still bubble an open-file action to the host).

New action code: `ACT_TOGGLE_FLOATING_PANELS = 7`.

`tk_desktop_tick` already runs all the per-frame housekeeping (LSP/DAP/terminal
ticks) for the whole Desktop, so the panel window does **not** run its own tick —
it only lays out and presents. The main window's tick drives both surfaces.

## Display-configuration identity

macOS gives each attached display a `CGDirectDisplayID`; `CGDisplayCreateUUID
FromDisplayID` maps that to a UUID that is **stable across disconnect/reconnect
and reboot** for the same physical monitor. The configuration key is:

```
sorted( "<display-uuid>@<pixelW>x<pixelH>" for each NSScreen )  joined by "|"
```

Sorting makes the key order-independent. Including the resolution distinguishes
e.g. the same monitor at a different scaled resolution. Examples:

- Laptop only: `37D8832A-...@2560x1600`
- Laptop + office 4K: `37D8832A-...@2560x1600|A1B2...@3840x2160`
- Laptop + home ultrawide: `37D8832A-...@2560x1600|C3D4...@3440x1440`

Each is a distinct key, so each roaming setup remembers its own layout. The key
is recomputed on launch and whenever `NSApplication.didChangeScreenParameters
Notification` fires.

## Persistence

Per-project geometry already lives at
`<project>/.turbokod/per_user/<user>/native_window.json`. Today that file is
`{"frame": [x,y,w,h]}` — a single frame. It becomes **keyed by display
configuration**, with the old single-frame form still read as a fallback:

```json
{
  "last": [1035, 50, 1266, 1247],
  "configs": {
    "37D8832A@2560x1600": {
      "main": [0, 0, 1266, 1247],
      "floating": false
    },
    "37D8832A@2560x1600|A1B2@3840x2160": {
      "main": [0, 0, 900, 1400],
      "floating": true,
      "panel": [2560, 100, 1280, 1000]
    }
  }
}
```

- `configs[<key>].main` — the main project window frame for that display config.
- `configs[<key>].floating` — whether floating panels was on under that config.
- `configs[<key>].panel` — the panel window frame (only present when `floating`).
- `last` — the most recently saved main frame, used as the fallback size when a
  brand-new (never-seen) config opens the project, so the window still opens at a
  reasonable size rather than the 1000×640 default.

Reading the legacy `{"frame": [...]}` form yields `last = frame` and no
per-config entries — so existing projects open at their remembered size, docked,
and start recording per-config state from there.

Writes are debounced exactly as the current frame-save is (150 ms after the last
resize/move), and now stamp the *current* config key. Both windows' frames and
the floating flag are written together.

## Restore / fallback rule

On opening a project (launch, CLI, Open Project…, recent pick) and on every
screen-parameter change while it's open:

1. Compute the current config key `K`.
2. Look up `configs[K]`.
3. If `configs[K]` exists **and** `floating == true` **and** the panel frame is
   visible on the current screens → enter floating mode: size the main window to
   `configs[K].main`, create/show the panel window at `configs[K].panel`, and
   call `tk_desktop_set_panels_detached(h, 1)`.
4. Otherwise → **docked**: size the main window to `configs[K].main` if present
   else `last` else default; ensure the panel window is closed and
   `panels_detached` is 0.

So the requested roaming behavior falls straight out of step 3 → 4:

- **Unplug the external display** the panels lived on → config key changes to one
  with no `floating: true` entry (or whose `panel` frame is now off-screen) →
  step 4 → docked. The panels snap back into the main window; nothing is lost.
- **Replug** → key returns to the floating entry → step 3 → panels float back to
  the external display at their remembered size.

A config never seen before always starts docked (no `configs[K]` → step 4),
which is the only mode available before this feature, so first contact with any
new setup is conservative.

### Restoring across screens (the constrain gotcha)

AppKit's `NSWindow.constrainFrameRect(_:to:)` keeps a window's title bar on the
"current" screen, and it runs during `setFrame`/`orderFront`. When we restore a
panel window saved on a *secondary* display at launch, that constraint yanks it
back onto the primary screen. The panel window is therefore an
`UnconstrainedWindow` (a tiny `NSWindow` subclass that returns the proposed rect
unchanged). This is safe specifically because step 3 only floats when
`frameIsVisible(panel)` is true — we never restore onto a display that isn't
attached, so opting out of the constraint can't strand the window off-screen.
The main project window keeps the default constraint as a safety net (its frame
isn't visibility-checked).

## What lives where

| Concern | Location |
| --- | --- |
| `panels_detached` flag, `paint_panels`, `handle_panels_event`, panel-window layout, View menu item | `src/turbokod/desktop.mojo` |
| `_panels` C ABI, `ACT_TOGGLE_FLOATING_PANELS`, menu-checkmark sync | `src/turbokod/native_api.mojo` |
| C ABI declarations | `app/swift/turbokod.h` |
| Display-config key, config-keyed `native_window.json`, screen-change observer, panel `NSWindow` + `PanelCellView`, toggle/restore/fallback logic | `app/swift/TurboKod.swift` |

The Mojo half is unit-testable and TTY-free (the panel layout is pure geometry);
the Swift half is the windowing/persistence/display-config machinery and is
verified by building + manual GUI testing (`./run_swift.sh <project>`), since the
display-config and multi-window behavior can't be exercised headlessly.
