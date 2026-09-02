# Native macOS menu surface

The Mojo `Desktop.menu_bar` is the single source of truth for menu structure across both frontends. The terminal frontend paints it in-grid; the Swift frontend hides the in-grid version and mirrors it as a native `NSMenu`.

## Flag: `Desktop.host_owns_menu`

`Bool`, default `False`. When `True`:

- `Desktop.paint` skips `menu_bar.paint`.
- `Desktop.handle_event` skips routing top-row mouse + Alt-letter mnemonic + Esc-prefix to the menu bar.
- `workspace_rect` reclaims row 0 for the workspace (no row reserved for the menu bar).
- `pointer_shape_at` no longer short-circuits to `"default"` on row 0.

Swift sets it via `tk_desktop_set_host_owns_menu(h, 1)` right after `tk_desktop_new` in `newWindow`.

## C ABI

### `tk_desktop_menu_snapshot(h, out_ptr, cap) -> n`

Serializes the menu tree as TSV (TAB-separated, NL-terminated rows):

```
M<TAB>label<TAB>visible<TAB>is_system<TAB>right_aligned
I<TAB>label<TAB>action<TAB>is_separator<TAB>checkable<TAB>checked<TAB>shortcut<TAB>mark
```

Items belong to the most-recently-emitted `M` row. Booleans render `0`/`1`.
`mark` is the decimal `MENU_MARK_*` code from `menu.mojo` — the alternate
glyph for the check column, consulted only when `checked` is `0`. The core
names the *meaning*, each frontend picks the rendering: the in-grid menu
paints a glyph, `installMenu` swaps `NSMenuItem.onStateImage`. Today the one
code is `MENU_MARK_OPEN` (1), which draws a diamond — what AppKit's own
Window menu uses for a window that's open but not frontmost.

Menus are emitted in **display order** via `MenuBar._display_order_indices()` — same rank-based sequence the terminal frontend's `_layout` uses:

1. System (`is_system=True`) menu first.
2. Left-aligned menus, rank-sorted via `_menu_rank` (File=0, Edit=10, others=50, Window=90, Help=100).
3. Right-aligned menus at the end.

The host just iterates the snapshot and appends to `NSApp.mainMenu` without re-sorting. Placement (File→Edit→…→Window second-to-last, Project rightmost) just falls out.

### `tk_desktop_menu_invoke(h, action_ptr, action_len, cols, rows) -> Int32`

Runs the action string through `Desktop.dispatch_action`. Returns the same host action code that `_action_code` returns for keyboard-driven actions:

| Code | Meaning                  |
|------|--------------------------|
| 0    | Handled entirely in Desktop |
| 1    | Quit                     |
| 2    | Open file                |
| 3    | Quick open               |
| 4    | Open project             |
| 5    | New window               |

Swift's `menuActionFired(_:)` handler routes the returned code through the existing `handleAction`.

### `tk_desktop_set_open_projects(h, ptr, n)`

Newline-separated, realpath-canonical project roots — one per host window,
including the receiving window's own. A `Desktop` *is* one window and can't
see its siblings, so this is the only channel that tells it a project is
already open elsewhere; it drives the `(open)` marker in the Project menu.
Swift pushes it from `pushOpenProjects(to:)` at the top of every
`refreshMenu()`; the Mojo side compares the list and early-outs when it
hasn't moved. The terminal frontend never calls it (one project per
process), which simply leaves the marker off there.

## The Project menu

The right-aligned Project menu is both the project switcher and the display
of what's open. `Desktop._rebuild_project_menu` builds it for both states:

```
Project Settings...        (only with a project open)
---
✓ turbokod                 (this window's project)
◆ dryft                    (open in another window)
  dryft-2                  (a plain recent)
---                        (only with a project open)
Close project              (only with a project open)
```

Both states live in the mark column, never the label — a suffix like
`dryft (open)` reads as part of the project's name.

Two invariants, both of which the menu got wrong before they were written
down:

1. **It rebuilds every frame, not at project-open time.** The recents list
   is shared state with N writers (see the settings section of
   [CLAUDE.md](../CLAUDE.md)): every window and every `tk-tui` process
   adopts the others' writes through `_poll_config_file`. A menu built once
   when the project opened went stale the moment any other window opened or
   closed one — which is how a project you closed failed to reappear here.
   `paint` and `process_external_changes` both call the rebuild (the latter
   because the window-less chrome Desktop that drives the macOS menu bar
   never paints), gated on `_project_menu_signature` so the steady state is
   one string compare.
2. **An entry's action carries the project path, not its slot in
   `config.recent_projects`.** Opening a project anywhere promotes it to
   the front of that shared list, renumbering every slot underneath an
   already-built menu — so an index-encoded pick resolved to a different
   project than its label named. Usually one that was already open, so the
   click read as "nothing happened". A path can only ever resolve to what
   the label said. Regression test:
   `test_project_menu_pick_follows_its_label_after_recents_reorder`.

Picking the active project is a no-op. Picking any other one returns
`ACT_NEW_WINDOW` with the path queued for
`tk_desktop_take_pending_new_window_project`, and the host focuses that
project's existing window when it has one rather than opening a duplicate.
The terminal frontend, having no multi-window story, swaps in place.

## Refresh cadence (Swift side)

Swift's 50 ms render timer calls `refreshMenu()`. The TSV is hashed (FNV-1a); rebuild happens only when the hash changes. `menuTracking` (set in `menuWillOpen` / `menuDidClose` via `NSMenuDelegate`) pauses rebuilds while a menu is open so a dropdown can't be yanked mid-click.

## macOS conventions

- **App menu slot**: Mojo's `≡` system menu (with Settings + Quit) lands in the macOS app-menu slot. `installMenu` prepends "About TurboKod" + a separator there, since macOS convention expects it.
- **Shortcuts**: Mojo emits `"Cmd+Shift+S"`-style display strings; `applyShortcut` parses them into `NSEvent.ModifierFlags` + `keyEquivalent`. Letters: lowercase by default, kept uppercase when Shift is in the mask. Special keys: Up/Down/Left/Right/Home/End/PgUp/PgDn/Tab/Enter/Esc/Space/BkSp/Del/F1-F12 → corresponding `NSEvent` function-key codepoints.
- **Help menu + search**: the Mojo core adds a `Help` menu in `_build_menus`, holding "Keyboard Shortcuts" → `HELP_HOTKEYS`. `_display_order_indices` pins a left-aligned `Help` menu dead last — *after* the right-aligned `Project` menu — so the NSMenu bar ends with `… Project, Help`, matching the macOS convention that Help is the rightmost menu. (`_menu_rank` still ranks Help at 100 so it's last in the terminal's left cluster, where `_layout` does the positioning.) When `installMenu` builds a submenu titled `Help` it assigns it to `NSApp.helpMenu`, which is what makes AppKit attach its built-in search field (searches every menu item across the bar). `helpMenu` is reset to `nil` at the top of each rebuild so a snapshot without a Help menu can't leave a dangling reference. The `HELP_HOTKEYS` action opens a read-only editor buffer (see `Desktop._open_hotkeys_help`) whose body is **generated**, not hardcoded: `_hotkeys_help_text` loops the global `_hotkeys` registry and prints every entry that carries a `group` + `help`, so the page can't drift from the bindings the app actually has. Each `Hotkey` now carries documentation metadata (`group`, `help`, `doc_shortcut`, `doc_only`); see the struct doc in `desktop.mojo`. Groups render in a fixed order (`HKG_*` constants), unknown groups are appended (never dropped), and entries that share one `help` string merge into a single row (`Ctrl+Space / Ctrl+J / F2`). Editor-level chords that `Editor.handle_key` owns directly (Cmd+Up/Down smart-select, Cmd+Left/Right, Ctrl+Alt+Up/Down multi-caret, …) appear as `doc_only` rows — listed on the page but skipped by the desktop dispatch loop so the editor keeps handling them. Adding a binding to the registry with a group + help is all it takes to document it.

## Adding a new menu item

Edit `_build_menus` in `native_api.mojo` (the shared menu builder both frontends consume). Don't hardcode NSMenuItems in `TurboKod.swift` — that diverges the frontends.

Related: [sequoia-close-crash](sequoia-close-crash.md) (workaround for an unrelated AppKit bug that affected window-close handling, not menus).
