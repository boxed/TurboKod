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

Every pane is a region of one cell grid, so the areas share the cell size,
and only the face differs. The cell comes from `Desktop.cell_font()` /
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
