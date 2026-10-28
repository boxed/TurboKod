# macOS-style UI

**View ▸ macOS-style UI** (native app only; global, persisted as
`config.native_ui`) replaces the Turbo Vision chrome with real AppKit UI. The
editor text itself stays on the cell grid.

It is being built in phases:

1. **Dialogs as sheets** — done for the confirm dialog (`NSAlert`), the
   single-field prompts (go to line, rename symbol / file, duplicate file,
   breakpoint condition, add watch — an `NSAlert` with a text field) and
   Save As (`NSSavePanel`).
2. **Tabs** — editors fill the workspace under a native tab strip instead of
   overlapping in-grid windows.
3. Pickers (Quick Open, Find Symbol, …) as native panels, popup menus as
   `NSMenu`, then Find / Replace, Fill and Breakpoint sheets, then splits.

## How a dialog becomes native

The core keeps owning the dialog. Openers (`confirm_dialog.open`,
`prompt.open`, `_open_save_as_dialog`) and submit handlers
(`_on_confirm_submit`, `_on_prompt_submit`, …) are unchanged. Only
*display* and *input* move to the host:

- `Desktop.native_dialogs()` is `host_owns_menu and config.native_ui`, so the
  terminal frontends (`run.sh`, `tk-tui`) always stay in-grid.
- `native_dialog_active()` covers the dialogs that have a native form. While
  it's true, `paint` skips them and `handle_event` swallows input before the
  modal chain. A replayed menu chord can't answer a dialog behind its sheet.
- The host polls `tk_desktop_native_dialog` every tick. It returns JSON
  `{"kind": "confirm" | "prompt" | "save_as", …}`, built by
  `_native_dialog_json` in `native_api.mojo`. When a new dialog appears, the
  host shows it as a sheet.
- The sheet's answer goes back through `tk_desktop_native_confirm_answer` /
  `_prompt_answer` / `_save_as_answer`. Those call `Desktop.native_*_answer`,
  which runs the same submit handler as the in-grid button and returns the
  usual host action code.
- If the core drops the dialog itself while the sheet is up, the poll sees
  "none" and ends the sheet with `.abort`, which is never answered.
- A submit handler that opens the next dialog (close-unsaved ▸ Save ▸ Save As)
  just works: the next tick shows the new sheet.

Button naming follows the project rule (confirmations name their action):

- Confirm buttons keep the core's labels.
- A prompt's button comes from `Desktop.native_prompt_action` ("Go",
  "Rename", …), never a bare OK.
- The in-grid first-letter hotkeys become ⌘-letter equivalents. `Cancel`
  answers Esc and the default button answers Return.
- Find and Replace deliberately stay in-grid for now. They remain open across
  matches and carry option toggles, so they need a non-modal panel, not an
  alert.

While a native text field is first responder, the Edit menu's key equivalents
(⌘V, ⌘C, …) are sent to it (`textFieldEditActions` in `menuActionFired`)
instead of to the editor behind the sheet.

## Adding a dialog

1. Add its `active` condition to `native_dialog_active`.
2. Skip its `paint` under `native_dialogs()`.
3. Describe it in `_native_dialog_json`.
4. Add a `native_<x>_answer` that feeds the result into its existing submit
   handler, and export it.
5. Add a `show…` case to `pollNativeDialog` in `TurboKod.swift`.

Tests live in `tests/test_native_ui.mojo`.
