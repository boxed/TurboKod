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
I<TAB>label<TAB>action<TAB>is_separator<TAB>checkable<TAB>checked<TAB>shortcut
```

Items belong to the most-recently-emitted `M` row. Booleans render `0`/`1`.

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

## Refresh cadence (Swift side)

Swift's 50 ms render timer calls `refreshMenu()`. The TSV is hashed (FNV-1a); rebuild happens only when the hash changes. `menuTracking` (set in `menuWillOpen` / `menuDidClose` via `NSMenuDelegate`) pauses rebuilds while a menu is open so a dropdown can't be yanked mid-click.

## macOS conventions

- **App menu slot**: Mojo's `≡` system menu (with Settings + Quit) lands in the macOS app-menu slot. `installMenu` prepends "About TurboKod" + a separator there, since macOS convention expects it.
- **Shortcuts**: Mojo emits `"Cmd+Shift+S"`-style display strings; `applyShortcut` parses them into `NSEvent.ModifierFlags` + `keyEquivalent`. Letters: lowercase by default, kept uppercase when Shift is in the mask. Special keys: Up/Down/Left/Right/Home/End/PgUp/PgDn/Tab/Enter/Esc/Space/BkSp/Del/F1-F12 → corresponding `NSEvent` function-key codepoints.

## Adding a new menu item

Edit `_build_menus` in `native_api.mojo` (the shared menu builder both frontends consume). Don't hardcode NSMenuItems in `TurboKod.swift` — that diverges the frontends.

Related: [sequoia-close-crash](sequoia-close-crash.md) (workaround for an unrelated AppKit bug that affected window-close handling, not menus).
