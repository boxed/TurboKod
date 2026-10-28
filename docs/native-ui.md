# macOS-style UI

**View ▸ macOS-style UI** (native app only; global, persisted as
`config.native_ui`) replaces the Turbo Vision chrome with real AppKit UI. The
editor text itself stays on the cell grid.

It is being built in phases:

1. **Dialogs as sheets** — done for the confirm dialog (`NSAlert`), the
   single-field prompts (go to line, rename symbol / file, duplicate file,
   breakpoint condition, add watch — an `NSAlert` with a text field) and
   Save As (`NSSavePanel`).
2. **Tabs** — done: editors fill the workspace under a native tab strip
   instead of overlapping in-grid windows (see below).
3. **Pickers** — done for Quick Open, Find Symbol, Find / Replace in
   Project, document symbols, references and DevDocs: one native sheet (see
   below). LSP message requests are a native alert (`choice`).
4. **Popup menus** as `NSMenu`, a **first-launch** look chooser, and the
   **git view** as a native sheet: all done (see below).
5. **In-file Find / Replace** is a find bar under the tabs (see below).
6. Still in-grid: Fill, Breakpoint, the color picker, Settings' content,
   review mode, merge view, history, the file tree and status bar.

## How a dialog becomes native

The core keeps owning the dialog. Openers (`confirm_dialog.open`,
`prompt.open`, `_open_save_as_dialog`) and submit handlers
(`_on_confirm_submit`, `_on_prompt_submit`, …) are unchanged. Only
*display* and *input* move to the host:

- `Desktop.native_ui()` is `host_owns_menu and config.native_ui`, so the
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

## Tabs

`WindowManager.tabbed` (set from `native_ui()` by `Desktop._fit_windows`, the
one path to `fit_into`) turns every window into a **frameless** one:

- `Window.frameless` makes `interior()` the whole rect.
- Paint skips the border, title, shadow and scroll bars.
- Every border hit zone (close, maximize, title drag, resize edges, scroll
  bars) reports a miss, so the top and right rows are plain editor text.
- `fit_into` pins each window to the workspace, and only the top of the
  z-order paints.
- Entering the mode maximizes the windows that weren't already, and marks
  them `_tab_maximized`. Leaving it restores exactly those, so the framed
  layout comes back.
- The session snapshot saves a `_tab_maximized` window as its framed
  `_restore_rect`, so turning the mode off after a restart doesn't leave
  every window maximized.
- The in-grid `TabBar` row is dropped (`tab_bar_rect` is empty).

The Swift host draws the strip as a titlebar accessory (`TabStripView`, at
the bottom of `TurboKod.swift`):

- `pollTabStrip` reads `tk_desktop_tabs`, which returns
  `{"focused", "tabs": [{"title", "path", "dirty"}]}` in window-index order,
  and only redraws when the bytes change.
- The strip is shown only while `tk_desktop_native_ui` is 1 and at least one
  window is open.
- A click calls `tk_desktop_tab_select` (= `window:focus:<i>`).
- The close button (on the left, where an unsaved tab shows a dot) and a
  middle-click call `tk_desktop_tab_close`. That goes through the same path
  as Cmd+W, so unsaved work raises the Cancel / Delete / Save sheet.
- Right-click offers Close Tab, Copy Path and Reveal in Finder.

## Pickers

Quick Open, Find Symbol and Find in Project keep all their search machinery
in the core: the file indexer, the symbol index with its `rg` fallback, and
the streaming `rg` runner. The host shows them as one sheet,
`PickerController` in `TurboKod.swift`:

- **State:** `tk_desktop_picker` reports `{kind, title, query, count,
  selected, status, …}`, plus Find in Project's fields and toggles. It's
  empty when no picker is up or `native_ui()` is off.
- **Rows** are fetched lazily, a page at a time, with
  `tk_desktop_picker_rows`. Only what the table shows ever crosses the
  boundary. The visible rows are re-fetched every tick so a re-ranked list
  (Find Symbol) redraws.
- **Typing** goes through `tk_desktop_picker_set` into each picker's
  `set_query` / `set_field`. Those methods share code with the in-grid
  key path (debounce, sanitizing, refilter).
- **Return and double-click** call `tk_desktop_picker_activate`, which runs
  the same `_after_quick_open` / `_submit_find_symbol` /
  `_after_project_find` the in-grid Enter does.
- **Return with nothing selected yet** opens the first row: results that
  landed after the last poll are still openable, and the core clamps the
  index.
- **Never call `clickCount` on `NSApp.currentEvent` without checking it's a
  mouse event.** It raises on the key event Return produces, which once
  made Return do nothing.
- **Find in Project's preview** (`tk_desktop_picker_preview`) is the whole
  file with the core's syntax spans, as `[row, byte_start, byte_end, rgb]`
  in the active theme. It's scrolled so the match sits at the golden-ratio
  line.

Tab titles size to their text; only when they don't all fit do the widest
shrink, down to a shared cap. A squeezed title drops its extension first,
then the end of its stem (`project_api.py` → `project_api` → `project_…`).

## Find bar

With the macOS-style UI on, Find and Replace don't open the modal prompt.
`_open_find_prompt` / `_open_replace_prompt` leave a one-shot
`native_find_request` (mode + seed), which the host takes with
`tk_desktop_take_find_request` to show `FindBar`, a titlebar accessory
under the tabs.

- The editor stays live while the bar is open, which is the point.
- Each button is one `tk_desktop_find` op through `Desktop.native_find`:
  `next` / `prev` / `replace` / `replace_all` / `mark` / `unmark`. It reuses
  `_find_step`, the Replace dialog's replace-under-caret and
  `_mark_matching_lines`.
- It stores `_last_search`, so F3 keeps repeating the needle.

## Git view

`LocalChanges` (the lazygit-style view) keeps every git operation. The
native sheet, `GitController`, follows the Mac source-control layout:

- Changes / Branches / History lists, with a stage checkbox per file and a
  commit box under Changes.
- A themed, syntax-colored diff on the right.
- Pull / Push / Push To… in the top bar, next to the busy spinner and the
  flash line.

It never re-implements an operation:

- **Selection and focus** go in with `tk_desktop_git_select` and
  `tk_desktop_git_cursor`. The cursor is the diff line clicked.
- **An operation is the view's own key** (`tk_desktop_git_key`): Space
  stages / unstages / checks out, `d` discards / deletes, `M` / `r` merge /
  rebase, `o` compare, `e` reword, `A` amend, `p` / `P` / Ctrl+P pull, push,
  push to.
- **Commit** is `native_commit`: the `c` prompt answered in one call.
- **Overlays become alerts on the sheet.** Every in-grid overlay (confirm,
  merge-or-rebase, reword editor, remote chooser, typed remote delete,
  status, output) is answered through `tk_desktop_git_answer` →
  `LocalChanges.native_answer`, which calls the method its Enter calls.
- **State** is `tk_desktop_git`. The right side is `tk_desktop_git_panels`,
  which builds the panels itself (in-grid, `paint` does it) and sends rows
  as `[kind, text]` with `LocalChanges`' `_LINE_*` kinds plus syntax spans.
- **Opening a file** (double-click, Return) runs `_after_local_changes`,
  the same post-input step the in-grid path takes.

**Swift gotcha found here:** `TurboKod.swift` is the app's main file, and
in a main file a top-level `let` is initialized only when execution reaches
its declaration. Constants declared below `app.run()` read 0 forever. Put
them in an `enum` as `static let`s (lazily initialized), as `GitPane` /
`GitLine` do.

## Popup menus

The anchored popups become a real `NSMenu` at their anchor cell: the
editor and tab context menus, spelling, the test gutter, diagnostics and
LSP status. Each menu struct has `native_items()`, the same rows its
`paint` draws, as `NativeMenuItem(label, code, enabled)`, and `choose(code)`.

- `tk_desktop_popup` exports the open popup.
- `tk_desktop_popup_choose` answers it: the picked code, or 0 when it was
  dismissed. Either way it goes through the menu's own `_on_*_submit`
  handler, exactly like an in-grid pick or Esc.
- Diagnostic quick fixes answer `NATIVE_FIX_BASE + i`. They can arrive
  while the menu is open, and the host rebuilds the open `NSMenu` in place
  when the export changes.
- The git gutter's hunk peek stays in-grid: it's an inline diff with a
  Revert bar, not a menu.

## First-launch welcome window

On the native app's first launch (`config.welcome_done` false), the host
shows `WelcomeController` after the first frame. It offers two look cards,
Modern macOS (`native_ui`) and Retro, plus theme, font and size popups.

- Each choice applies live to the window behind it through
  `tk_desktop_welcome_apply` → `Desktop.apply_welcome`, which persists, so
  every other window follows via the config poll.
- Picking a look also picks its natural theme, font and size: One Dark /
  GitHub Light (by system appearance) with SF Mono 13, or Turbo C++ 3.0 with
  the VGA font. The popups stay editable afterwards.
- Closing the window, by Get Started or the close button, sends the final
  apply with `done`, which sets `welcome_done`.
- The options come from `tk_desktop_welcome_options`: the theme names and
  the built-in font labels. The host appends the system's monospace
  families.
- Scripted captures skip the window unless `TK_WELCOME=1`, which also makes
  `TK_CAPTURE` grab it.
- TurboKod ▸ Welcome to TurboKod… reopens it at any time.
- A preview pane under the popups paints a code sample through the theme's
  actual editor and syntax slots (re-read from the core after every apply),
  in the chosen font and size.

## Scripted captures

`TK_CAPTURE_WINDOW=1` renders the whole window offscreen (titlebar, tab
strip, an attached sheet), so it works with the display asleep, unlike
`screencapture`. `TK_OPEN` takes a comma-separated list of files, and
`TK_CAPTURE_PICKER_QUERY` types a query into a picker the actions opened.

## Adding a dialog

1. Add its `active` condition to `native_dialog_active`.
2. Skip its `paint` under `native_ui()`.
3. Describe it in `_native_dialog_json`.
4. Add a `native_<x>_answer` that feeds the result into its existing submit
   handler, and export it.
5. Add a `show…` case to `pollNativeDialog` in `TurboKod.swift`.

Tests live in `tests/test_native_ui.mojo`.
