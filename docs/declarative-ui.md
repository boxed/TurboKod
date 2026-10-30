# Declarative UI: one description, three projections

A dialog describes its UI **once**, as a tree of `UINode`s built from its
state each frame. Three projectors turn that same tree into a UI (the
third, Platinum, is in [platinum-ui.md](platinum-ui.md)):

- **Grid** (`ui_grid.mojo`, `GridForm`): lays it out in cells and paints it
  with the existing widgets (`TextField`, `Dropdown`, `Checkbox`,
  `ShadowButton`, `ListBox`). It also runs focus, keys and mouse. This is
  the terminal and the classic look.
- **Native** (`TurboKod.swift`, `DeclarativeController`): builds AppKit
  views from `ui_to_json` and shows them as a sheet. This is the macOS-style
  UI.

Both report what the user did the same way, as `UIEvent`s:

- `set(key, value)` for an edit;
- `act(id)` for a button or command.

The dialog applies them through its own `ui_set` / `ui_act`, the only code
that touches its state. Values cross as strings: a checkbox is `"1"` /
`"0"`, and a choice, table selection or tab is its index.

## Writing a dialog

```mojo
def ui(self) -> UINode:          # the whole UI, from current state
def ui_set(mut self, key: String, value: String)
def ui_act(mut self, id: String)
```

Then register it in `Desktop`'s `ui_surfaces` / `ui_tree` / `ui_apply`,
with the handler that runs when it submits. That is all the wiring there is:

- **Grid:** `paint` draws every open surface through its own `GridForm`
  (`ui_grids`), and `handle_event` routes to the top one.
- **Native:** the host polls `tk_desktop_ui` and answers with
  `tk_desktop_ui_event`.

### Windows of their own

Settings isn't modal on macOS: it opens in its own window so the workspace
stays usable and a theme change is visible as it happens. `settings_surfaces()`
is that window's stack, kept out of `ui_surfaces()` while
`settings_detached`. The classic look paints it through `settings_grids`
into the host's Settings cell window (`GridForm.fill` lays the dialog over
the whole window). The macOS-style UI gets it as `tk_desktop_ui`'s `window`
stack and shows level 0 as a window.

### Stacked dialogs

A dialog can open another on top of itself — Project Settings' On save tab
opens the action editor. `ui_surfaces()` lists the open ones bottom first,
and `ui_surface()` is the top one, which gets the input. The grid paints the
lower ones without focus. Natively each level is a sheet on the one below
it, and `tk_desktop_ui` sends the whole stack (`{stack: [{name, tree}]}`).
A confirm raised while a dialog is up goes on top of its sheet
(`sheetHost`), and in the grid it paints over the dialogs.

## The node set (`ui_tree.mojo`)

| Node | Notes |
| --- | --- |
| `ui_dialog(title, cancel, body)` | Root. Esc and the close box run `cancel`. |
| `ui_vstack` / `ui_hstack` / `ui_buttons` | Stacks; `ui_buttons` is a centered button row. |
| `ui_form(rows)` / `ui_row(label, control)` | Labels in one column, controls in the next. |
| `ui_tabs(key, selected, pages)` / `ui_page(label, body)` | Tabbed pages. |
| `ui_label(text, flags)` | `UI_SECONDARY` / `UI_HEADING` styles. |
| `ui_text` / `ui_check` / `ui_choice` | Bound to a `key`; `enabled=False` greys them. `ui_text(width=n)` sizes a field for `n` characters instead of stretching it. |
| `ui_path(key, value, placeholder, enabled)` | A text field with a Browse button: the grid's file dialog, natively an open panel. |
| `ui_table(key, columns, rows, selected, activate, height, checkable)` | Rows of cells. |
| `ui_button(id, label, flags)` | `UI_DEFAULT` answers Return, `UI_CANCEL` Esc; also `UI_DESTRUCTIVE`, `UI_HOTKEY`. |
| `ui_separator` / `ui_spacer` | Spacing. |
| `ui_preview(font, size, builtins, version)` | Sample code in the live theme's editor colors. |
| `ui_list(key, count, first, rows, selected, activate, height, flags, spans)` | A list too long to send whole; see below. |

Flags beyond the obvious: `UI_NAV` on a text field makes it the search
field of the dialog's list (the arrows move the list, typing stays in the
field), `UI_MULTI` lets a list's selection be a range (`"<anchor>:<row>"`),
`UI_CODE` makes a list a code view, and `UI_LARGE` gives a dialog most of
the window.

### Long lists (`ui_list`)

Quick Open's files or a whole source file can't be sent every frame, so a
list carries `count` and only the rows from `first` on, the window around
what's on screen. Each projector reports where its view starts with
`set("<key>@top", row)`, and the dialog's `ListWindow` sends the rows
around that (and around the selection) next frame. A row is a primary text
and an optional detail, drawn de-emphasized in a second column, the same in
every look: the primary column as wide as the widest primary text in the
rows sent, at most half the list (`_paint_list` in cells, `ListColumns` in
the Swift projectors); `UISpan`s color byte ranges of
a cell with a palette index (so they follow the theme) or `UI_RGB | rgb`.
With `UI_CODE` it's a code view: monospace on the editor colors, no
selection, its `number` the line to mark and reveal at the golden ratio.

Keys are unique per dialog. The grid projector keeps the widget state that
isn't the dialog's business (a field's cursor, a pop-up being open, a
table's scroll) keyed by them.

## Layout rules (grid)

One set of rules replaces per-dialog hand placement, so every grid dialog
lines up the same way:

- **Frame:** the title sits on the frame's top border, with a margin of two
  columns and one row inside.
- **Forms:** labels are right-aligned with a trailing `:`, and their
  controls share one left edge two columns further.
- **Stacks:** one blank row between a stack's children.
- **Buttons:** button rows are centered, with buttons two columns apart.
- **Sizing:** text fields and tables stretch to the width they're given; a
  stack's spare height goes to a spacer, else to its last table.
- **Short screens:** the dialog never outgrows the screen. A stack takes
  the rows it's short from its last table (down to a header and one row),
  then closes up the gaps between its children.
- **Tables:** typing a letter jumps to the first row whose first text column
  starts with it.

## Native projector

`DeclarativeController` rebuilds its views only when the tree's *shape*
changes (node kinds, keys, choice options). Otherwise it pushes values into
the existing views, and never overwrites a text field that is being typed
in, so focus and the cursor survive every frame. Keep a dialog's shape
stable: disable a control rather than leaving it out, so the views aren't
rebuilt under the user.

An `NSTabView` doesn't size itself to its pages, so each page is pinned
into its item's view and the tab view is given the largest page's fitting
size.

For scripted screenshots, `TK_CAPTURE_UI='{"<name>": [[is_action, key,
value], …]}'` sends events to a dialog as soon as its sheet is up.

## Converted so far

The pickers: Quick Open, Go to Symbol, references, Find Symbol, docs and
Find in Project are one surface, `picker` (`picker_ui.mojo` lays it out,
`Desktop.picker_ui` / `picker_apply` connect it to whichever picker is
open), replacing three per-look implementations: the hand-painted grid
pickers, the AppKit `PickerController` and its `tk_desktop_picker*` C ABI.
An action that hands the host something to do (a project opening in a new
window) comes back from `ui_apply` / `tk_desktop_ui_event` as a host action
code.

Fill (Edit ▸ Fill…), the breakpoint dialog, the failed-condition dialog,
Project Settings and its on-save action editor, Settings and its language
editor. Their hand-placed grid code,
the old native `form` sheet, the separate Project Settings cell window and
its hand-built native twin are gone. Project Settings applies each edit as
it's made. Close runs `_sync_project_settings` before it resets the working
state. Validation is part of the dialog: Fill's "must be a whole number"
shows as a label in both projections.
