# Declarative UI: one description, two projections

A dialog describes its UI **once**, as a tree of `UINode`s built from its
state each frame. Two projectors turn that same tree into a UI:

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
| `ui_text` / `ui_check` / `ui_choice` | Bound to a `key`; `enabled=False` greys them. |
| `ui_path(key, value, placeholder, enabled)` | A text field with a Browse button: the grid's file dialog, natively an open panel. |
| `ui_table(key, columns, rows, selected, activate, height, checkable)` | Rows of cells. |
| `ui_button(id, label, flags)` | `UI_DEFAULT` answers Return, `UI_CANCEL` Esc; also `UI_DESTRUCTIVE`, `UI_HOTKEY`. |
| `ui_separator` / `ui_spacer` | Spacing. |

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

Fill (Edit ▸ Fill…), the breakpoint dialog, the failed-condition dialog,
Project Settings and its on-save action editor. Their hand-placed grid code,
the old native `form` sheet, the separate Project Settings cell window and
its hand-built native twin are gone. Project Settings applies each edit as
it's made. Close runs `_sync_project_settings` before it resets the working
state. Validation is part of the dialog: Fill's "must be a whole number"
shows as a label in both projections.
