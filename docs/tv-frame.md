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
│ cell.mojo  colors.mojo  theme.mojo                  │   in-grid tab bar
└─────────────────────────────────────────────────────┘   bottom border: the core's row
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
  three rows up. The row between it and the status bar is the frame's bottom
  border, painted by `_paint_frame_bottom`; the file tree stops above it
  (`FileTree.bottom`). `_frame_rows` gates all of it on a screen tall enough.
- `paint_frame` paints the rest of the frame on the window's **whole** grid:
  the top row (close box, the proxy icon's two blank cells, the title, the
  zoom box), the sides, the bottom corners, and the two cells beside the
  status bar. The host lays the Desktop's own grid over the inside, so only
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
- A borderless window doesn't close, zoom or minimize from the Window menu on
  its own; `MainWindow` covers that for both borderless looks.
