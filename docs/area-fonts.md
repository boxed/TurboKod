# Per-area fonts

Settings ▸ Appearance has a **Font**: the code's font, and the default for
every other area. There's also a **Terminal font** (shell / Claude /
test panes and the run / debug output) and a **Debugger font** (the debug
pane's stack and variables), plus a **UI font** outside the Turbo Vision
look. Each of those defaults to "Same as Font". All of this is native macOS
only: in the terminal frontends the terminal emulator owns the font.

Every font row shows its font and a **Choose…** button. That opens a
`FontChooser` (`font_chooser.mojo`) over Settings, like its language editor:
a search field over every font family on the system (`FontCatalog.families`
in `TurboKod.swift`), matched case-insensitively as you type.

## One cell size, several faces

Every pane is a region of one cell grid, so by default the areas share the
cell size, and only the face differs (an area can opt out with a **Size** of
its own; see the next section). The cell comes from `Desktop.cell_font()` /
`cell_font_size()`:

- **Turbo Vision look:** always the built-in VGA font at its ideal 16pt,
  an 8×16 cell, and the UI is drawn in it. Frames, borders and shadows are
  box drawing, which only joins up cell to cell in a font made for the
  cell. So there's no Size and no UI font in Settings there. The Font
  (code) is fitted to that cell.
- **macOS / Mac OS 9 looks:** `config.font` / `font_size` set the cell, as
  before.

The host fits each area's face to the cell (`SlotFace` in `TurboKod.swift`):

- The bundled VGA font is stretched to fill the cell exactly.
- Any other family is sized so its line fits the cell's height and its
  advance fits the width, then centered.
- A proportional one (Chicago, or any non-monospace family) is fitted
  glyph by glyph.

## An area's own size: sub-grids

The Terminal and Debugger fonts each have a **Size** row (Smaller / Larger /
Same as Font) under their font. `config.area_font_sizes` holds them by slot
(serialized `font_terminal_size` / `font_debugger_size`, 0 = the cell's).
An area with a size of its own gets a *grid of its own*: a smaller terminal
font really gives the shell more columns and rows, and the pty is told so.

- **Measuring.** The host works out the area's cell from its font at that
  size, with the same arithmetic as the cell font (`naturalCell`), and builds
  a face fitted to it (`AreaGrid`). It reports the cell to the core in
  thousandths of the screen cell (`tk_desktop_set_area_scale`, rounded up so a
  grid never overruns its rect). `Desktop.frame_canvas` copies those onto
  every frame's `Canvas.area_scale`.
- **Laying out.** A view that paints an area's content asks the canvas how
  many of the area's cells fit in its rect (`sub_grid_size`), paints a
  canvas of that size, and places it (`place_sub_grid`). At scale 1, which
  is always the case in the terminal frontends, placing just copies the cells
  in, so nothing below the frontend boundary needs to know. Otherwise the
  canvas keeps the grid as a `SubGrid`, and the rect's cells are tagged
  `Cell.sub` = its index + 1.
- **`GridFrame`** (`grid_frame.mojo`) is a region's bookkeeping. Its grid's
  coordinates are anchored at the rect's top-left, and the grid canvas has
  that `origin`. So a view paints the grid, and hit-tests what it painted,
  in the coordinates it would use on the screen. `map` turns a mouse event
  into those coordinates. The debug pane uses three frames (Stack, Locals /
  Watches, output log); the shell and test panes use `GridSelection`'s
  equivalent (`set_frame` / `grid_event`, `terminal_view.mojo`).
- **Mouse.** A cell position isn't fine enough to say which of a smaller
  grid's cells the pointer is over, so the host sends the pointer in
  thousandths of a cell before each mouse call (`tk_desktop_set_mouse_fine`
  → `Event.fine`). `Event.fine_pos` falls back to the middle of `pos`'s cell
  when something rewrote `pos` without it.
- **Drawing.** `pack_canvas` puts `sub` in bits 26..31 of word 0 (the width
  is bits 24..25: mask it). After the frame, the host draws each sub-grid
  (`tk_desktop_sub_grid_info` / `_layout`) over its rect, in the area's
  cell size and face (`withCellMetrics`). It then redraws on top the rect's
  cells whose tag isn't that grid's: any write clears a cell's tag, so a
  popup or a menu painted over the pane stays in front. The sub-grids are
  part of the host's change detection (`subGridsHash`); the frame's own
  cells under them are blank and don't change.

## Font slots

`Cell.font` holds a slot (`FONT_UI` / `FONT_CODE` / `FONT_TERMINAL` /
`FONT_DEBUGGER`, in `cell.mojo`). `Canvas.font` is the current slot, and
every write through `Canvas` (`set`, `put_text`, `fill`, `clear`) stamps it,
while recoloring (`set_attr`, `darken_rect`) keeps the cell's slot. A view
paints in a slot by switching `canvas.font` around its content and restoring
it after:

- `Window._paint_editor`: the editor's interior is code; its frame is UI.
- `terminal_view.paint_grid`: the shell / Claude / test pane grids are
  terminal.
- `DebugPane.paint`: the stack / variables columns are debugger, the
  output log is terminal, and the dividers and headers are UI.

Since anything painted later (popups, menus, dialogs) goes back to UI, this
gets z-order right for free. A new view that wants a slot does the same
switch, scoped to its content and not its chrome.

On the wire, `pack_canvas` puts the slot in bits 21..23 of word 0, between
the codepoint (bits 0..20) and the width byte. The host refetches the cell
font (`tk_font_name` / `tk_font_size`, which are the *cell* font's) and each
area's (`tk_font_area_name` → `Desktop.area_font`) when `tk_font_version`
moves or the look changes. The cell font and the faces are globals in the
host, so any change bumps `fontGeneration` and every view redraws every
cell: each window, the floating panels, and the dialog windows.

## Config

`config.font` is the Font (code). `config.area_fonts` is indexed by slot,
and its entries are serialized as `font_ui`, `font_terminal` and
`font_debugger`; the code slot's entry is unused. An entry of `""` means
"same as `font`". `AREA_BUNDLED_FONT` means the bundled VGA font, which
`font` itself spells as `""`. Every other value is spelled the same way
`font` spells it.

The original Px437 8×16 font is no longer bundled. The 16×32 VGA font
embeds the same pixels for 16px cells, and a config naming the old font
reads as the VGA font.
