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

Then register it in `Desktop`'s `ui_surface` / `ui_tree` / `ui_apply`, with
the handler that runs when it submits. That is all the wiring there is:

- **Grid:** `handle_event` and `paint` route through `ui_grid` for whatever
  `ui_surface()` names.
- **Native:** the host polls `tk_desktop_ui` and answers with
  `tk_desktop_ui_event`.

## The node set (`ui_tree.mojo`)

| Node | Notes |
| --- | --- |
| `ui_dialog(title, cancel, body)` | Root. Esc and the close box run `cancel`. |
| `ui_vstack` / `ui_hstack` / `ui_buttons` | Stacks; `ui_buttons` is a centered button row. |
| `ui_form(rows)` / `ui_row(label, control)` | Labels in one column, controls in the next. |
| `ui_tabs(key, selected, pages)` / `ui_page(label, body)` | Tabbed pages. |
| `ui_label(text, flags)` | `UI_SECONDARY` / `UI_HEADING` styles. |
| `ui_text` / `ui_check` / `ui_choice` | Bound to a `key`; `enabled=False` greys them. |
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

## Native projector

`DeclarativeController` rebuilds its views only when the tree's *shape*
changes (node kinds, keys, choice options). Otherwise it pushes values into
the existing views, and never overwrites a text field that is being typed
in, so focus and the cursor survive every frame.

## Converted so far

Fill (Edit ▸ Fill…), the breakpoint dialog, and the failed-condition
dialog. Their hand-placed grid code and the old native `form` sheet are
gone. Validation is part of the dialog: Fill's "must be a whole number"
shows as a label in both projections.
