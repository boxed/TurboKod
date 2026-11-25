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
the lower panel's chrome buttons), starts its
`dock.resizing`, and in-flight motion moves the splitter to the pointer
(`_panels_drag_splitter`).
`pointer_shape_panels` shows `ns-resize` over a splitter or during a drag. A lone
panel fills the window and has no splitter, so it's correctly non-resizable.

#### A drag rolls a panel up, and opens a rolled-up one

There is no height between a panel's header and `DOCK_MIN_HEIGHT`, so a resize
drag snaps to the nearer of the two (`BottomDockedPanel.drag_height`): dragged
below halfway the panel becomes `MINIMIZED`, and a rolled-up panel's header is
a drag handle that opens it again. A drag that ends rolled up puts
`preferred_height` back to what it was when the drag began (`resize_from`), so
the restore button brings back that size, not the minimum the drag passed
through. Docked, that is all of it: the panel's own header, `height = bottom -
cursor`.

In the floating stack the splitter sits between two panels, and
`_panels_drag_splitter` settles both:

- The **upper** panel takes the rows down to the pointer through `drag_height`,
  so dragging the splitter up to its header rolls it up, and dragging the
  bottom edge of a rolled-up panel down opens it.
- When nothing under the splitter can absorb the rows — the lower panel is the
  last one open, or it and everything after it is rolled up — the **lower**
  panel follows the room the drag leaves it: open with room for
  `DOCK_MIN_HEIGHT`, rolled up otherwise. That is what dragging a rolled-up
  panel's header up from the bottom of the window does: it becomes the absorber.
- When the upper panel is rolled up and the pointer goes above it, the nearest
  open panel above gives up the rows and the rolled-up ones ride along, so the
  splitter stays under the pointer.

#### Drags and the maximized panel

A resize drag moves the edge under the pointer and nothing else, so it never
restores a panel as a side effect:

- A panel rolled up beside a maximized one (`yielded`) drags open **beside**
  it. `drag_height` marks it `kept_open` and clears `yielded`, so
  `coalesce_dock_states` neither makes it yield again nor takes its opening as
  a restore: the maximized panel stays `MAXIMIZED` and fills what is left
  (`Desktop._dock_height` subtracts the others; in the floating stack the
  maximized panel is the absorber wherever it sits). `kept_open` lasts until
  another pane is maximized, the panel is rolled up, or nothing is maximized.
  Restoring a yielded pane with its *button* still ends the maximize.
- Docked, a maximized panel's own header drags it down to a height of its own
  (`NORMAL`): it stays `MAXIMIZED` until the drag asks for fewer rows than it
  has, so a press that doesn't move changes nothing. `drag_height` sets
  `max_dragged`, and `coalesce_dock_states` then leaves the panes that yielded
  to it rolled up instead of restoring them — a restored pane below would shift
  the dragged pane's bottom mid-drag.
- Floating, everything under a maximized panel hangs from the bottom of the
  window (the maximized panel absorbs above it), so there
  `_panels_drag_splitter` treats the splitter as the top of the *lower* panel,
  which takes the rows from the pointer down — the docked rule. Above a
  maximized panel the usual top-anchored rule holds.

Both marks are set by the drag itself rather than read off `dock.resizing` in
the next frame: a quick drag is over before a frame sees it.

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

#### Raising the window on a (re)start — without stealing focus

The auto-show poll only `orderFront`s on the empty→non-empty *transition*, so it
misses the common case where the window is already showing panels but is **buried
behind other windows** when a tool pane is (re)activated — restarting a target
(Cmd+R), re-running tests (Cmd+T), starting a debug session, run-to-cursor. Those
should surface the panel window so the user sees the output, but they must **not**
steal keyboard focus (you don't want Cmd+T to yank you out of the editor).

That's a one-shot `Desktop.panel_front_request`, raised wherever a run/test/debug
makes a bottom pane visible, drained by the host each tick via
`tk_desktop_take_window_requests` (bit 2) → `pair.window.orderFront(nil)` (note:
`orderFront`, **not** `makeKey`). It's the focus-less sibling of
`panel_focus_request` — which an *explicit new terminal pane* (incl. a new Claude
panel) raises to `makeKeyAndOrderFront` the window, because there you *do* want to
start typing immediately. So: new terminal/Claude pane → raise **and** focus;
target/test/debug (re)start → raise only.

#### Focusing the panels sends the other projects behind theirs

With several projects open, a click on one project's floating panels used to
leave another project's window showing in front of the one the panels belong
to. When a panel window becomes key (`didBecomeKeyNotification` →
`sendOtherProjectsBehind(panels:)`) the host takes each *other* project's
window that is in front of the panels' project window
(`NSWindow.windowNumbers`, front to back) and orders it directly **below** that
window, back to front so they keep their order among themselves.

The project's own window is deliberately **not** raised. Bringing it up under
the panels would put it over whatever other applications' windows sit between
the two, and focusing a panel must not reshuffle other programs' windows — the
only windows that move are ours, and they only move down. Nothing happens
while the project window is hidden, minimized or in another space (it isn't in
the list then).

#### The window's frame, per look

The panel window is an ordinary titled window in the macOS look. The other two
looks have no macOS title bar, so the tick swaps the window in and out of
theirs as the look changes (each poll waits for the other's to come off first),
and `showPanelWindow` runs both polls before the window first shows:

- **Mac OS 9**: `pollPlatinumPanelChrome` puts it in a `PlatinumMainFrame`
  (see [platinum-ui.md](platinum-ui.md)).
- **Turbo Vision**: `pollTVPanelChrome` makes it borderless, whole cells, under
  a `RetroShadow`, and the frame is **cells the core paints in the window's own
  grid** (as the look's Settings and git windows do), not a wrapper view:
  `Desktop.panels_framed(screen)` is `tv_frame()` on a grid of at least 12×6;
  `_paint_panels_frame` draws the box with `[■]`, `project — Panels`
  (`panels_title`) and `[▲]` on its top row, in the panes' colors
  (`PANE_FG` on `PANE_BG`, not the editor's the project frame wears: what it
  surrounds is panes), double lines while the window is
  key (`panels_host_focused`, from `tk_desktop_set_panels_focused` each tick);
  and `_panels_area` is the inside of it, which is where `_panel_window_slots`
  lays the stack out and what the splitter drag measures against. Everything
  that reads the slots (paint, hit-testing, pointer shapes, drops) follows.
  The host only hit-tests the ring (`CellView.onChromeMouse`): the close box
  docks the panels (`windowShouldClose`, as the red button does), the zoom box
  or a double click on the title row fills the screen and back, the title row
  drags the window, and the sides and bottom corners resize it in whole cells
  (`pointer_shape_panels` reports `ew-resize` there).

### Menu surface

A new **View ▸ Floating panels** item, checkable, action
`app.toggle_floating_panels`. Added in `app_menus.build_menus` (only with
`native=True`, since only a windowing host can act on it) so the frontends share the definition (per the menu-surface rule in
[native-menu.md](native-menu.md) — never hardcode NSMenu items in Swift). The
checkmark mirrors `panels_detached`, synced each tick in
`app_menus.refresh_menu_visibility`. The action is a **host action**: `dispatch_action`
returns it unhandled, `_action_code` maps it to `ACT_TOGGLE_FLOATING_PANELS`,
and Swift owns the actual window create/destroy and then calls
`tk_desktop_set_panels_detached` to update the flag (and thus the checkmark).

The terminal frontend doesn't surface a floating toggle; the item is harmless
there (it would just be a no-op host action), but to keep the in-grid menu
honest the item is only added when the host owns the menu.

## C ABI additions (`native_api.mojo` + `turbokod.h`)

```c
void    tk_desktop_set_panels_detached(int64_t h, int64_t on);
// The panel window is the key window (per tick): its Turbo Vision frame's
// lines are double then.
void    tk_desktop_set_panels_focused(int64_t h, int64_t on);
// surface = HOST_SURFACE_PANELS (1); the same three serve the host's other
// cell windows (Settings, the dialog and git windows).
int64_t tk_desktop_surface_layout(int64_t h, int64_t surface, int64_t cols,
                                  int64_t rows, int64_t out_ptr, int64_t cap);
int32_t tk_desktop_surface_key(int64_t h, int64_t surface, uint32_t key,
                               uint8_t mods, int64_t cols, int64_t rows);
int32_t tk_desktop_surface_mouse(int64_t h, int64_t surface, int64_t x,
                                 int64_t y, uint8_t button, uint8_t pressed,
                                 uint8_t motion, uint8_t mods, int64_t cols,
                                 int64_t rows, uint8_t click_count);
int32_t tk_desktop_surface_pointer_shape(int64_t h, int64_t surface, int64_t x,
                                         int64_t y, int64_t cols, int64_t rows);
```

The main window goes through the same calls with `HOST_SURFACE_MAIN` (0), and so
do drag-and-drop (`tk_desktop_surface_drop_target` / `_drop_paths`).

`tk_desktop_surface_layout` packs the same `[codepoint, fg|bg<<8|style<<16,
underline]` 3-word-per-cell buffer as `tk_desktop_layout` — the panel window's
`PanelCellView` rasterizes it with the identical Core Text path. The surface
key/mouse functions return the same `ACT_*` codes (so e.g. a link click in the
debug output can still bubble an open-file action to the host).

With the macOS-style UI on, the panel window gets the same native pane
headers and debug-pane tables as the docked panes (see
[native-ui.md](native-ui.md)); in the Mac OS 9 look, Platinum pane
headers and a Platinum window frame (see [platinum-ui.md](platinum-ui.md)). `tk_desktop_panels_panes` lists the headers at
the panes' rows in this window, and `tk_desktop_debug_inspect` takes a
`panels` flag. The host polls both for the panel view before its occlusion
check, so they stay in step while the window is covered.

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
