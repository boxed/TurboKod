# Mac OS 9 look (Platinum)

**View ▸ Mac OS 9-style UI** (native app only; global, persisted as
`config.platinum_ui`) is the third look, next to the classic Turbo Vision
grid and the macOS-style UI. Settings ▸ Appearance shows the three as one
**Look** choice, the welcome window as three cards, and the View menu as
three checked items in a section of their own (Turbo Vision-style UI,
`VIEW_CLASSIC_UI`, is the grid); picking one turns the others off.

It is a third *projector*, not a skin. The macOS-style UI hands the
declarative dialogs to AppKit; this one hands the same data to the Swift
host, which lays it out and draws it in pixels, Platinum-style. AppKit
controls can't be made to look like Mac OS 8/9 (the system menu bar and
`NSMenu` can't be restyled at all), and drawing over the cell grid can't
either: Platinum's chrome is 1–2 point outlines and bevels, and cells only
come in 8×16 steps.

## What it covers

- **Declarative dialogs** (`tk_desktop_ui`, see
  [declarative-ui.md](declarative-ui.md)): Fill, the breakpoint dialogs,
  Project Settings and its action editor, Settings and its language editor.
  A modal dialog is a movable-modal child window centered over its window in
  the upper third. Settings is a window of its own with a close box.
- **The confirm dialog** (`tk_desktop_native_dialog`, `kind: confirm`), as a
  Platinum alert with a Caution icon when a button is destructive, otherwise a
  Note icon. It has to be the host's: a confirm can be raised over a dialog
  the host is drawing, and in the grid it would paint (and take its input)
  underneath that dialog's window.
- **The project window's chrome.** The windows become tabs, as in the
  macOS-style UI (`WindowManager.tabbed`), and the `NSWindow` goes
  borderless (`MainWindow`) inside a `PlatinumMainFrame`: the Settings
  window's frame and pinstriped title bar, with close, zoom and collapse
  boxes (collapse minimizes), a tab strip drawn with the Settings tabs'
  shape (`Platinum.tab`), and a grow box, which is the only way to resize
  it, as on Mac OS 9. The focused editor gets a Platinum scroll bar
  (`PlatinumScroller`, fed by `tk_desktop_editor_scroller`) in two columns
  the core keeps clear at its right (`Window.gutter`), and the grow box sits
  at its foot. Switching the look off puts the window back in the system
  frame.
- **The status bar**, as a window information bar: Platinum face under a
  black rule, Geneva, the run targets as bevel buttons (the chosen one
  pushed in) and the message flush right. Like the macOS-style bar it is
  presentation only, each part kept in the cell columns
  `tk_desktop_status_layout` reports, so clicks land where the core
  expects them.
- **The git view** (`PlatinumGitView`): the macOS sheet's layout in a
  Platinum window over the project window. The lists and diffs are
  `PGitRows` (rows of colored runs in a well, a Platinum scroll bar; a list
  selects in lavender, a diff frames the core's cursor so its add/remove
  color shows), headings are Chicago with an etched rule (black for the
  focused pane), the focused pane's operations are push buttons, right-click
  pops a Platinum contextual menu, and the overlays (commit, reword, merge
  or rebase, remote choice, typed delete, confirms, output) are Platinum
  alerts. The commit message and the output use `PTextArea`, a host-only
  multi-line node. It drives the core through the same `tk_desktop_git*`
  calls as `GitController`; `tk_desktop_git` carries `look`, and `pollGit`
  rebuilds the view in the other projector when the look changes under it.
  The focused pane's letters work as in the grid (`c` commits, `p` pulls).
- **The pickers** (Quick Open, Find in Project, …), being declarative:
  `PListView` draws a `ui_list` with the git window's rows view, and a
  search field's arrows move it.
- **Not covered:** the menus, which stay the system menu bar. Everything
  else (prompts, pickers, the editor text, the panes) stays the classic
  grid.

## Core side

- `Desktop.platinum_ui()` is `host_owns_menu and config.platinum_ui and not
  config.native_ui`, so the terminal frontends never see it.
- `host_tabs()` (`native_ui() or platinum_ui()`) gates the tabbed layout,
  hides the in-grid tab bar and turns on `tk_desktop_editor_scroller`;
  `_fit_windows` sets the 2-column gutter in this look only.
- `host_draws_dialogs()` (`native_ui() or platinum_ui()`) is what gates the
  git view (`native_git_active`) and the declarative dialogs: it decides whether they leave the grid, whether
  `native_ui_surface_active` swallows grid input, and whether Settings
  opens in the host's window (`settings_native`).
- `native_dialog_active()` covers only the confirm in this look, and
  `host_draws_confirm()` keeps the grid from painting it.
- `tk_desktop_ui` carries `look: "platinum" | "macos"`, and
  `tk_desktop_platinum_ui` reports the look per window.

## Host side (`TurboKod.swift`, "Mac OS 9 ("Platinum") look")

- `DeclarativeSurface` is the protocol both projectors implement.
  `reconcile` builds a `PlatinumDialog` or a `DeclarativeController` by
  `look`, and retires a level whose look changed.
- `PNode` subclasses (stack, form, tabs, label, text, check, pop-up, list,
  button, separator, preview, plus the alert-only icon) do their own layout:
  `fit()` is the size a node asks for, and `place(_:)` gives it its rect.
  The layout rules follow the grid's: right-aligned form labels, spare
  height to spacers and then the last list, centered button rows. Like the
  AppKit projector, views are rebuilt only when the tree's shape changes.
  Otherwise `apply` pushes the values in, and a text field being typed in is
  never overwritten.
- Only the text fields use AppKit (a borderless `NSTextField` in a Platinum
  well). Pop-ups track a Platinum menu (`PlatinumMenuSession`: press-drag-
  release or click-to-open, arrows and Return), lists have Platinum scroll
  bars (fixed 16-point lavender thumb, arrow and page repeat).
- Keys: Return presses the default button, Esc and ⌘. cancel, Tab cycles
  the fields and lists. A one-letter hotkey works without ⌘ outside a text
  field, and with ⌘ inside one.

## Push buttons are pixel tables

`PlatinumButtonArt` draws push buttons from gray-level tables read off
Apple's own figures in the Mac OS 8 Human Interface Guidelines (Push Buttons,
Default Buttons). A button is 20 points tall, and the default ring adds 3 on
each side. The bevel is asymmetric (a face-colored gap before the top-left
highlight, the dark shadow right against the outline at the bottom-right),
and every corner is blended pixel by pixel. Vector approximations of it
never looked right.

The standard normal button and the pressed default button were checked
pixel for pixel against the 1× figure. The other states come from a
1.5×-scaled figure, read with its doubled rows and columns undone. The
dialog background is `E3`, as in those figures.

## Scroll bars

Every Platinum scroll bar sizes its thumb by `Platinum.thumb`: as long as
the visible share of the content (at least Mac OS 9's own 17-point thumb),
the grid's rule (`scrollbar.mojo`). Mac OS 8's fixed thumb told you nothing
about how much there was.

`Platinum.scrollBar` draws it pixel for pixel from a Mac OS 9 screenshot,
not with the generic bevels: arrow boxes whose white highlight stops short
of the top-right and bottom-left corners (face gray there) over a light
`C7` shadow; a `B8` track sunk by two steps along its top and left (`89`,
`99`) and lit on the right (`C7`, `D5`), the steps starting again under the
thumb as if it cast them; and the thumb's lavenders (`D6D4FE` / `ADA5FE` /
`7D73D7`, an `F1` corner, a `4A38AB` grip centered on any length). The
arrows are drawn as rows of points (2, 4, 6, 8 wide), never a path, which
antialiased into gray edges.

## Text

Chicago comes from **Silom**, which ships with macOS: its Latin glyphs are
Chicago's, drawn on an exact 12-pixels-per-em grid. At 12 pt every stem and
advance lands on a whole point. Geneva (shipped too) is the application font
for fields and list rows.

Two things are needed for the bitmap look, both in `Platinum.text`:

- **No kerning.** Silom's kerning pairs aren't whole pixels and visibly
  break the even Chicago spacing.
- **Spacing by ink, not advances.** Geneva's outlines have fractional
  advances and side bearings, and unantialiased a glyph covers fewer whole
  points than its advance suggests: rounding each advance left three blank
  points between K and I but one between I and L. So `Platinum.layout`
  measures each glyph's rasterized ink once and starts the next glyph's ink
  the font's own gap (its side bearings, rounded down, at least a point)
  after it, the way the bitmap fonts were set. Monospace fonts keep their
  columns. Before that, advances were rounded to whole points; Geneva's
  are fractional, which smears unantialiased. Text is laid out in CoreText (for glyphs and
  fallback fonts), then each advance is rounded and the glyphs are drawn at
  those positions, antialiasing off. Truncation ("…") and wrapping are done
  on the same measurements. `NSString` drawing squeezes glyphs together
  before it truncates.

## Chicago in the editor

Settings ▸ Font has **Chicago (built-in)** next to the VGA fonts, for any
look (`config.font` = `CHICAGO_FONT`; the Mac OS 9 card in the welcome
window picks it). The host draws it with the same Silom, at 12 pt by
default: digits and most letters there are 8 points wide and a line fits
16, so the cell is the VGA font's 8×16. It is crisp (no anti-aliasing) at
multiples of 12 pt.

Chicago is proportional, and the grid isn't, so `drawFitted` puts each
glyph in its cell: a narrow one (`i`, `l`, `.`) centered on whole points,
a wider one (`m`, `w`, `M`, `W`, `@`, `%`, `#`, `&`, `K`, `N`) squeezed
to the cell's width, so they don't run into their neighbors.

## Screenshots

`captureWindowPNG` composites child windows, so `TK_CAPTURE_WINDOW=1` shows
a Platinum dialog over its window. `TK_CAPTURE_TITLE=Settings` grabs the
Settings window.
