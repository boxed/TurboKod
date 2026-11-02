# The Turbo Vision look's project frame (native macOS)

In the native app the Turbo Vision look (View ▸ Turbo Vision-style UI: neither
`config.native_ui` nor `config.platinum_ui`) works like the other two looks:
**one window per project, its documents as tabs**. Then nothing inside the
window overlaps, so the window itself wears the Turbo Vision chrome: it goes
borderless (square corners, no macOS title bar) and gets a Turbo Vision frame
of cells around the grid.

```
┌[■]────────── ▯ colors.mojo — turbokod ──────────[▲]┐   title row: window chrome
│ 1 """Color and text…             ▲ ▸ app            │
│ 2                                ░ ▸ docs           │   editor's own scroll bar
│ 3 We model an Attr…              ▼ ▸ src            │   in its gutter column
└─────────────────────────────────────────────────────┘   bottom border: the core's row
 cell.mojo  colors.mojo  theme.mojo                        in-grid tab bar, outside the frame
 main  ● uncommitted                         LSP: ready    status bar, outside the frame
```

The terminal frontends (`run.sh`, `tk-tui`) keep overlapping windows: they
never set `host_owns_menu`, which `Desktop.tv_frame()` requires.

## Core side

- `Desktop.tv_frame()` is `host_owns_menu and not native_ui() and not
  platinum_ui()`. It turns on the tabbed layout (`WindowManager.tabbed`, as
  in the other looks; see [native-ui.md](native-ui.md#tabs)) with a one-column
  gutter, and `grid_bar`: a frameless editor paints its own Turbo Vision
  scroll bar in that gutter (`Window._v_scrollbar` covers the window's full
  height there), with the usual hit-testing and drag.
- The in-grid tab bar is always on (it's the only way to switch windows),
  directly over the status bar, and like it outside the frame. The row above
  it is the frame's bottom border, painted by `_paint_frame_bottom`; the file
  tree stops above that (`FileTree.bottom`). `_frame_rows` gates all of it on a screen tall enough.
- `paint_frame` paints the rest of the frame on the window's **whole** grid:
  the top row (close box, the proxy icon's two blank cells, the title, the
  zoom box), the sides, the bottom corners, and the gray cells beside the
  tab bar and the status bar. The host lays the Desktop's own grid over the inside, so only
  that ring shows.
- The frame is the key window's: double lines while `host_focused`, single
  otherwise, like a focused window.
- The title is `file — project` (`frame_title`); the proxy icon stands for
  the focused file, else the project (`frame_path`). `frame_title_span`
  places both and is shared by the paint and the host's hit-testing.
- C ABI: `tk_desktop_tv_frame`, `tk_desktop_layout_frame` (the ring, packed
  like `tk_desktop_layout`), `tk_desktop_frame_info` (`{path, icon, title}`).

## Host side (`TurboKod.swift`)

- `pollTVChrome` swaps the window in and out of a `TVMainFrame` as the look
  changes, like `pollPlatinumChrome` (each waits for the other's frame to come
  off first). Installing snaps the window to whole cells, top-left fixed.
- `TVMainFrame` holds two `CellView`s on the same Desktop: `chrome`, a
  `.frame` surface that only draws the ring (its clicks go to
  `onFrameMouse`), and the window's own grid, one cell in at the sides and
  below the title row, down to the bottom edge. Everything the grid does
  stays in its own coordinates, so nothing else needed to change.
- The ring is the window chrome:
  - title row: drag moves the window; double-click follows the system's
    "double-click a window's title bar" setting;
  - `[■]` closes the window (the project), through `performClose`;
  - `[▲]` toggles full screen, and Option-click fills the screen instead
    (`MainWindow.performZoom`), as the green button does;
  - the sides and bottom corners resize, in whole cells;
  - the proxy icon (`TVProxyIcon`, the file's Finder icon over its two
    cells) drags the file, and ⌘-click on it or the title shows the path
    menu (picking an entry shows it in Finder).
- The window casts a Turbo Vision drop shadow instead of the system's soft
  one (`RetroShadow`): a click-through child window ordered below it, two
  cells right and one row down, translucent black in the L that shows past
  the window. Off in full screen. The dialog windows below get one too.
- A borderless window doesn't close, zoom or minimize from the Window menu on
  its own; `MainWindow` covers that for both borderless looks.

## Dialog windows

The git view gets a non-modal window of its own (`TVGitWindow`, a `.git`
`CellView`: `Desktop.git_window`, `paint_git_window`,
`handle_git_window_event`, `tk_desktop_layout_git` /
`tk_desktop_git_window_key` / `_mouse`), not the dialog window below; see
the git view section of [native-ui.md](native-ui.md).

As in the other two looks, the declarative dialogs (the
pickers — Quick Open, Find Symbol, Find in Project, … — Project Settings,
Fill, the breakpoint dialogs) don't cover the project window: each opens in
a window of its own, a borderless child window whose cells the core paints,
Turbo Vision frame included. Settings already had its own window
(`.settings`) and keeps it, borderless the same way: its grid keeps the title
on its frame (`own_title`), and `TVDialogWindow.chromeMouse` gives it the
same title-row drag and side resizing. Which window Settings is in follows
the look live (`Desktop.settings_native()`), so picking another look in
Settings moves it into that look's window.

- `Desktop.dialog_window()` names what's up: the bottom open
  declarative dialog; empty outside `tv_frame()`. While it's non-empty the
  project window's `paint` skips the dialog and everything that can open
  over it (prompt, confirm, message request, color picker, Save As), and
  `handle_event` swallows the project window's input — the dialog is modal,
  as it was in the grid.
- `paint_dialog_window` / `handle_dialog_window_event` are the window's
  surface. The event handler runs the ordinary `handle_event` chain with
  `_in_dialog_window` set, in the window's coordinates, so a prompt or
  confirm raised over the dialog opens (and answers) in that window.
- The bottom declarative dialog's `GridForm` fills the window (`fill`)
  but keeps its title on its frame (`own_title`); dialogs stacked on it
  stay centered inside.
- A chord the menu bar replays (⌘V into a picker's field) goes through
  `_replay_through_modal` to the dialog window at its last painted size.
- C ABI: `tk_desktop_dialog_window` (JSON `{kind, title, cols, rows,
  resizable}`: the size the dialog takes in the grid of a project window
  that size), `tk_desktop_layout_dialog`, `tk_desktop_dialog_key`,
  `tk_desktop_dialog_mouse` (both return host actions like
  `tk_desktop_key`).

Host side, `TVDialogWindow` (polled by `pollTVDialog`): a `.dialog`
`CellView` in a borderless `TVDialogNSWindow`, a child of the project
window, centered in its upper third. The title row drags it; the close box
is the core's. The large (`UI_LARGE`) dialogs resize from
their sides and bottom corners; the rest follow the size the core asks for.
A click on the project window hands the keyboard straight back. `keyView`
maps the dialog window to its project window's view for menu actions.
