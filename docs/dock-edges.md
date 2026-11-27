# Dock edges and auto-hide

Each tool panel — every terminal pane, the run/debug pane, the test pane and
Find Results — docks to an edge of its own: **bottom** (where they all used to
be), **top**, **left**, **right**, or **floating** (the native app's floating
panels' window, [floating-panels.md](floating-panels.md)). Any panel can also
**auto-hide**: it rolls up when an editor gets the focus and comes back out
when the panel does.

All of it is core (`desktop.mojo`, `window.mojo`), so the terminal frontends
get it too; they just never offer Floating.

## The model

`BottomDockedPanel` (the name predates the other edges) carries:

- `edge`: an `EDGE_*` (`EDGE_BOTTOM` by default).
- `home_edge`: the docked edge a floating panel uses while it can't float.
  Every docked `set_edge` updates it.
- `auto_hide`, plus `hidden_from`: the state auto-hide rolled the panel up
  from, or `PANEL_STATE_NONE`.

`Desktop.effective_edge(dock)` is where a panel is laid out: its edge, except
that `EDGE_FLOAT` becomes `home_edge` while the host has no panel window for
this Desktop (`float_allowed` is False: the terminal frontends, a display
configuration without one, a capture run). So floating is a *choice* that
survives unplugging the display the window lived on.

Per kind, the config remembers where panels dock and whether they auto-hide:
`dock_terminal` / `dock_debug` / `dock_test` / `dock_find_results` (a
`dock_spec`: `bottom`, `top`, `left`, `right`, or `float:<home>`) and the
`auto_hide_*` flags. A new panel takes its kind's (`_adopt_dock_default`, called
at every terminal creation site and, for the others, when the config loads).
Moving a panel moves its kind (`_record_dock_default`).

## Layout: the edges cut the window in order

`Desktop._dock_layout(screen)` → `DockLayout`. The file tree is outermost.
After that, each edge with a panel on it cuts its region off what's left, in
the order `config.dock_order` ranks them (`dock_order_edges`: comma-separated
edge names; missing ones follow in the default order). The first edge in the
order takes the whole height (a side) or the whole width (top / bottom) of the
remaining window, the next fits beside it, and so on. Whatever is left is the
workspace (`DockLayout.mid`, which is `workspace_rect`).

The default, `left,right,top,bottom`, is the old layout extended: the side
columns run the full height, and the top region and bottom stack sit between
them. Putting `bottom` first gives a full-width bottom stack with the side
columns above it. You set the order in Settings ▸ Panels, which has a list you
reorder with Move Up / Move Down next to a miniature of the result.
`ui_dock_preview` is the `UI_DOCK_PREVIEW` node and `dock_preview_regions` is
its geometry: the grid draws boxes in cells, and the Swift host draws a
`DockPreview` (inside a Platinum well in the Mac OS 9 look, as
`PDockPreview`).

Two kinds of region:

- **The bottom stack** works as it always has. Each pane has its own height,
  its header is the drag handle, and the max / min / yield rules are those in
  [floating-panels.md](floating-panels.md). Its area is `DockLayout.bottom`:
  the x-span and the bottom edge the pane rects (`_bottom_*_rect`) are laid out
  against. `bottom_avail` is how many rows a maximized pane may fill, so when
  the top region comes first in the order, a maximized bottom pane fills up to
  the top region and no further.
- **Top, left, right and floating** are *filling stacks*: `_edge_slots(edge,
  area)`, the algorithm the floating window always used. The panels stack top
  to bottom, the maximized one (else the last open one) absorbs the leftover
  rows, and a splitter (the lower panel's header row) resizes the panel above
  it. `_panels_drive_resize(event, slots, area)` drives that drag in all four;
  the panes' own chrome gets `allow_resize=False` there. `PanelSlot.edge` tells
  the routing code which kind of region a slot is in.

A region's size against the workspace is a `SplitArea` in **fixed-cells mode**
(`dock_split_left` / `_right` / `_top`; `fixed_cells`, with `fixed_second` for
the right column). That gives the divider, its drag, the cursor and the native
`HostItem` divider in the macOS and Mac OS 9 looks. A column keeps its width
when the window grows. Sizes are `config.dock_left_cols` / `dock_right_cols` /
`dock_top_rows`, written back on release (`_dock_edges_mouse`) and pushed into
the splits each paint (`_sync_dock_sizes`).

`coalesce_dock_states` runs once per edge, so each edge has at most one
maximized panel.

`_dock_slots` is every docked panel's slot: the bottom stack, then the top,
left and right stacks. Everything that walks it follows automatically: paint,
hit-testing, pointer shapes, drops, the native pane headers
(`tk_desktop_panes`) and attention flashes. `debug_pane_rect` & co. look the
panel up there, wherever it docks.

### Side strips

When every panel on a side is rolled up, minimized or auto-hidden, the column
shrinks to a `DOCK_STRIP_COLS`-wide strip, so the editors get the width back.
The strip has one vertical tab per panel (`_strip_tabs`) with the title running
down it, and its panels have empty slot rects. Clicking a tab opens the panel
and focuses it (`_reveal_panel`); right-clicking it opens the dock menu. The
grid draws the title a glyph per row. The macOS and Mac OS 9 looks get a
`HOST_DOCK_TAB` host item (`HostItem.label` carries the title), which the
Swift `DockTab` draws as rotated text: bottom to top on the left edge, top to
bottom on the right. The cells underneath keep the mouse.

A top region whose panels are all rolled up is just their header rows.

## Auto-hide

- **Hiding.** `_auto_hide_panels()` rolls up every open, unfocused,
  auto-hide panel that isn't floating (an editor can't cover the floating
  window). It runs:
  - when the keyboard target turns to the editors: `_on_focus_change` tracks
    `_last_key_kind`, which also covers paths that don't go through
    `_focus_dock`, such as an output-pane link opening a file;
  - on every left press that lands in an editor window, even one that was
    already focused, so a panel a run brought out goes away on your next click
    into the code.
- **Restoring.** `_focus_dock` restores an auto-hidden pane it focuses. That
  covers a click on its header, a strip tab, Ctrl+9, the Window menu and
  anything else that focuses a pane. A run, test or debug (re)start brings its
  pane out without the keyboard (`_reveal_panel(…, focus=False)`, next to
  `panel_front_request`).
- **Maximize and yield.** A pane minimized because a sibling is maximized
  (`yielded`) is recorded as hidden *from the state it yielded*, and its
  `yielded` mark is cleared. When the maximized pane rolls up too, nothing pops
  back open.
- Turning auto-hide off brings a hidden panel back.

## Choosing an edge

- **A right-click on a pane's header** (in the grid, or on a native header,
  which passes non-control clicks to the cells) or on a strip tab opens the
  dock menu: Dock Left / Right / Top / Bottom (the current edge greyed out),
  Float (native app only), and Auto-hide / Stop Auto-hiding. It shares the
  `tab_context_menu` popup (`_dock_menu_kind` marks it), so it's an `NSMenu`
  in the native looks.
- **View ▸ Dock Panel Left / Right / Top / Bottom, Float Panel, Auto-hide
  Panel** act on the focused tool pane, or the last one focused
  (`_menu_panel`). The checkmarks follow it (`dock_menu_state`).
- **Settings ▸ Panels** sets each kind's edge and auto-hide (open panels
  move: `_adopt_dock_defaults`) and the cut order.

Floating a panel while the host has no panel window raises
`panels_float_request` (window request bit 16). The host opens the window at
the frame saved for this display configuration and allows floating
(`tk_desktop_set_float_allowed`). Closing the panel window docks its panels
on their home edges (`tk_desktop_dock_floating_home`), as do their kinds.

## Tests

`tests/test_dock_edges.mojo`: geometry per edge, the file tree beside the
columns, the cut order, divider and splitter drags, maximize within an edge,
strips, auto-hide (click, focus change, maximize / yield, a run), the floating
fallback, the dock menu, the View menu, Settings ▸ Panels and the config
defaults. The bottom-stack behavior is still covered by `tests/test_chrome.mojo`.
