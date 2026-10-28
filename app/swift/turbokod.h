#ifndef TURBOKOD_H
#define TURBOKOD_H
#include <stdint.h>

// C ABI exported by the Mojo shared-lib (src/turbokod/native_api.mojo).
// Mojo `Int` is 64-bit; handles and addresses cross as int64_t.

// From the Rust shim (linked into the dylib): SIGTERM every tracked child
// (run targets, LSP servers, pty shells). Must be called explicitly on
// quit — NSApp.terminate exits via _exit(), skipping the shim's
// dyld-terminator backstop.
void    tk_terminate_all(void);

int64_t tk_desktop_new(void);
void    tk_desktop_begin_close(int64_t h);
int64_t tk_desktop_close_poll(int64_t h);
void    tk_desktop_free(int64_t h);
// Recover the user's full interactive shell $PATH that a Dock launch strips
// (runs `$SHELL -l -i`, ~100 ms). Call once off the first runloop turn — not
// inside tk_desktop_new — so the first frame isn't blocked. Idempotent:
// spawns the login shell at most once.
void    tk_recover_user_shell_path(void);
void    tk_desktop_open_project(int64_t h, int64_t path_ptr, int64_t path_len);
void    tk_desktop_open_file(int64_t h, int64_t path_ptr, int64_t path_len,
                             int64_t cols, int64_t rows);
void    tk_desktop_open_file_at(int64_t h, int64_t path_ptr, int64_t path_len,
                                int64_t line, int64_t character,
                                int64_t cols, int64_t rows);
void    tk_desktop_tick(int64_t h, int64_t cols, int64_t rows);
int64_t tk_desktop_layout(int64_t h, int64_t cols, int64_t rows,
                          int64_t out_ptr, int64_t cap);
// Native smooth-scroll (macOS host), working in *visual-row* coordinates so
// it's uniform for wrapped and non-wrapped editors.
//   tk_editor_scroll_regions: N records of 9 int32 words
//     [win_idx, x, y, w, h, sub, frac_milli, n_sticky, right_gutter] —
//     interior rect in cells, the count of the top buffer line's wrapped
//     segments scrolled off the top (sub; 0 when not wrapping), the sub-row
//     pixel fraction x1000, the count of pinned sticky-scroll header rows the
//     host leaves fixed at the top, and the right-edge minimap gutter width
//     the host leaves fixed at the right. The host shifts the overdraw body
//     up by (sub + frac) rows, clipped between those fixed regions.
//   tk_editor_region_layout: render one editor's body at its current
//     scroll_y into a 0-origin grid region_rows visual rows tall (same
//     5-u32 cell format as tk_desktop_layout); composite it clipped to the
//     interior, translated up by (sub + frac) * CELL_H.
//   tk_editor_smooth_begin: writes [cur_vis_milli, max_vis_milli] (current
//     position + max, as visual-row coords x1000) to seed a gesture.
//   tk_editor_smooth_set: set position from a global visual-row coord x1000.
int64_t tk_editor_scroll_regions(int64_t h, int64_t cols, int64_t rows,
                                 int64_t out_ptr, int64_t cap);
int64_t tk_editor_region_layout(int64_t h, int64_t win_idx,
                                int64_t region_cols, int64_t region_rows,
                                int64_t out_ptr, int64_t cap);
//   tk_editor_overlay_bounds: screen-cell bounds [x, y, w, h] of the focused
//     editor's active screen-anchored overlay (minimap tooltip or LSP hover
//     popup). Returns 1 when one is up (and fills out_ptr), 0 otherwise.
//     Re-blit this rect from the main frame on top of the smooth-scroll
//     overdraw, which suppresses overlays. With host_owns_shadows set this is
//     the box only — draw the drop shadow as a translucent layer (see
//     drawPopupShadow); otherwise it includes the baked cell shadow.
int64_t tk_editor_overlay_bounds(int64_t h, int64_t cols, int64_t rows,
                                 int64_t out_ptr);
int64_t tk_editor_smooth_begin(int64_t h, int64_t win_idx,
                               int64_t cols, int64_t rows, int64_t out_ptr);
void    tk_editor_smooth_set(int64_t h, int64_t win_idx,
                             int64_t cols, int64_t rows, int64_t vis_milli);
//   tk_editor_minimap_to: scroll proportionally from a minimap/scrollbar
//     drag — frac_micro is the pointer's fractional position down the
//     minimap x1,000,000 (0 = top, 1e6 = bottom). Computed host-side from
//     the raw sub-cell pointer Y. Micro (not milli) so the fraction isn't
//     the bottleneck on large files (1000 steps would read as ~10-row jumps).
void    tk_editor_minimap_to(int64_t h, int64_t win_idx, int64_t frac_micro);
// Window-border vertical scrollbar thumb drag, sub-cell precise. After a
// mouse-down, poll tk_desktop_vscroll_active; if 1, route motion through
// tk_desktop_vscroll_drag (mouse_y_milli = raw pointer Y / cell height x1000)
// so a long file scrolls line-by-line instead of ~150 lines per thumb cell.
int64_t tk_desktop_vscroll_active(int64_t h);
int64_t tk_desktop_vscroll_drag(int64_t h, int64_t mouse_y_milli);
// Scroll the focused editor horizontally by `cols` columns (negative = left).
// Used for a trackpad horizontal swipe / Shift+wheel. Returns 1 if it moved.
int64_t tk_desktop_hscroll_by(int64_t h, int64_t cols, int64_t screen_cols, int64_t screen_rows);
int32_t tk_desktop_key(int64_t h, uint32_t key, uint8_t mods,
                       int64_t cols, int64_t rows);
int32_t tk_desktop_mouse(int64_t h, int64_t x, int64_t y, uint8_t button,
                         uint8_t pressed, uint8_t motion, uint8_t mods,
                         int64_t cols, int64_t rows, uint8_t click_count);
// Bare modifier-key transition (e.g. Option/Alt press or release) from
// the AppKit host's flagsChanged. mod_id is a MOD_KEY_* value (2 = Alt).
// Drives the editor's Alt-tap and tap-then-hold multi-cursor gestures.
int32_t tk_desktop_mod_key(int64_t h, uint32_t mod_id, uint8_t pressed);
// Pointer shape at (x, y): 0 default, 1 text, 2 pointer, 3 ns-resize,
// 4 ew-resize (host_abi.mojo SHAPE_*).
int32_t tk_desktop_pointer_shape(int64_t h, int64_t x, int64_t y,
                                 int64_t cols, int64_t rows);
// Host drag-and-drop of file(s) onto the main window. paths is a
// newline-separated UTF-8 list of absolute paths. When a terminal pane sits
// under cell (x,y) the paths are shell-escaped + injected as a bracketed
// paste. Returns 1 when a pane consumed the drop, else 0.
int32_t tk_desktop_drop_paths(int64_t h, int64_t x, int64_t y,
                              int64_t paths_ptr, int64_t paths_len,
                              int64_t cols, int64_t rows);
// Classify a drop at cell (x,y) on the main window: 1 = terminal pane,
// 2 = editor body, 0 = nothing droppable. Polled during the drag (cursor)
// and on drop (terminal paste vs editor format-choice menu).
int32_t tk_desktop_drop_target(int64_t h, int64_t x, int64_t y,
                               int64_t cols, int64_t rows);
// Insert text verbatim into the editor under cell (x,y), caret at the drop
// point. The host formats the dropped path (full/filename/relative) first.
// Returns 1 when an editor consumed it.
int32_t tk_desktop_insert_text(int64_t h, int64_t x, int64_t y,
                               int64_t text_ptr, int64_t text_len,
                               int64_t cols, int64_t rows);
// 1 when a paste should go to an editor (editor focused, no terminal/file-tree
// dock focused). Host checks this before offering the file-path paste menu.
int32_t tk_desktop_paste_target_is_editor(int64_t h);
// Insert text verbatim at the focused editor's caret. Backs the file-path
// paste menu (Cmd+V of a file): host formats the path per the menu choice.
int32_t tk_desktop_paste_text(int64_t h, int64_t text_ptr, int64_t text_len);
// Paste host-supplied (NFC-normalized) text into whatever owns keyboard focus
// — the host-driven counterpart to in-core Cmd+V. Used for normal text paste
// so macOS's decomposed pasteboard text (a + U+030A) becomes precomposed (å).
int32_t tk_desktop_paste_clipboard_text(int64_t h, int64_t text_ptr, int64_t text_len);
void    tk_desktop_set_host_owns_menu(int64_t h, int64_t on);
// When on, the host draws the editor body popups' drop shadows as a real
// translucent layer over the live (smooth-scrolled) text; the core stops
// baking the cell shadow and tk_editor_overlay_bounds reports the box only.
void    tk_desktop_set_host_owns_shadows(int64_t h, int64_t on);
void    tk_desktop_set_host_focused(int64_t h, int64_t on);
void    tk_desktop_refresh_git(int64_t h);
int64_t tk_desktop_menu_snapshot(int64_t h, int64_t out_ptr, int64_t cap);
int32_t tk_desktop_menu_invoke(int64_t h, int64_t action_ptr, int64_t action_len,
                               int64_t cols, int64_t rows);
int64_t tk_desktop_take_pending_new_window_project(int64_t h, int64_t out_ptr,
                                                   int64_t cap);
// macOS-style UI (View ▸ macOS-style UI): the core hands dialogs to the host.
// _native_dialog writes a JSON description ({"kind": "confirm" | "prompt" |
// "save_as", …}) of the dialog to show as a sheet, 0 when none; a return
// larger than cap means grow the buffer and retry. The _answer calls resolve
// it through the same submit path the in-grid dialog uses.
int64_t tk_desktop_native_dialog(int64_t h, int64_t out_ptr, int64_t cap);
int32_t tk_desktop_native_confirm_answer(int64_t h, int64_t choice);
int32_t tk_desktop_native_prompt_answer(int64_t h, int64_t ptr, int64_t len,
                                        int64_t ok);
void tk_desktop_native_save_as_answer(int64_t h, int64_t ptr, int64_t len);
void tk_desktop_native_choice_answer(int64_t h, int64_t index);
void tk_desktop_native_form_answer(int64_t h, int64_t button, int64_t ptr, int64_t len);
void tk_desktop_native_color_answer(int64_t h, int64_t rgb, int64_t mode, int64_t ok);
// macOS-style UI tab strip: _native_ui is 1 while the mode is on; _tabs writes
// {"focused": i, "tabs": [{"title", "path", "dirty"}]} (same buffer contract
// as _native_dialog); _tab_select / _tab_close act on a window index.
int32_t tk_desktop_native_ui(int64_t h);
int64_t tk_desktop_tabs(int64_t h, int64_t out_ptr, int64_t cap);
int32_t tk_desktop_tab_select(int64_t h, int64_t idx, int64_t cols, int64_t rows);
void tk_desktop_tab_close(int64_t h, int64_t idx);
// macOS-style UI pickers (Quick Open / Find Symbol / Find in Project) as a
// native panel. _picker writes the JSON state (0 = none up), _picker_rows a
// page of rows, _picker_preview Find in Project's file preview. The setters
// behave as if the field had been typed / the row clicked.
int64_t tk_desktop_picker(int64_t h, int64_t out_ptr, int64_t cap);
int64_t tk_desktop_picker_rows(int64_t h, int64_t start, int64_t n,
                               int64_t out_ptr, int64_t cap);
int64_t tk_desktop_picker_preview(int64_t h, int64_t out_ptr, int64_t cap);
void tk_desktop_picker_set(int64_t h, int64_t fptr, int64_t flen,
                           int64_t tptr, int64_t tlen);
void tk_desktop_picker_option(int64_t h, int64_t nptr, int64_t nlen, int64_t on);
void tk_desktop_picker_select(int64_t h, int64_t idx, int64_t anchor);
int32_t tk_desktop_picker_activate(int64_t h, int64_t idx, int64_t anchor,
                                   int64_t cols, int64_t rows);
void tk_desktop_picker_action(int64_t h, int64_t nptr, int64_t nlen,
                              int64_t cols, int64_t rows);
void tk_desktop_picker_close(int64_t h);
// First-launch welcome window: _needed is 1 until answered; _options writes
// {themes, builtin_fonts, native_ui, theme, font, font_size}; _apply takes
// {native_ui, theme, font, font_size} JSON (done = 1 marks it answered).
// macOS-style UI popups as NSMenu: _popup writes {kind, x, y, items: [{label,
// code, enabled}]} (anchor in cells; 0 = none up), _popup_choose answers it
// (code 0 = dismissed) and returns a host action code.
// macOS-style UI find bar: _take_find_request is a one-shot {mode, seed, case,
// word, regex} when Find / Replace was asked for; tk_desktop_find runs a bar
// button {op: next|prev|replace|replace_all|mark|unmark, find, replace, …}.
// macOS-style UI file tree: _tree writes {x, y, w, h (cells), root, selected,
// focused, entries: [[name, depth, is_dir, expanded, modified, path]]} (0 = not
// shown natively); _tree_act: op 0 select, 1 toggle, 2 open, 3 menu at (x, y).
// macOS-style UI Settings window over the same Settings state: _prefs writes the
// values + theme / font lists (0 = not open natively), _prefs_set takes a JSON
// {key: value}, _prefs_close closes it, _prefs_advanced hands over to the grid
// Settings window (every section).
// macOS-style UI Project ▸ Spelling sheet: _spelling state (0 = not up), _rows
// [[word, count, path, line]] in display order, _act 1 = add rows (JSON index
// array) to the project dictionary, 2 = to the user's, 0 = close.
// macOS-style UI Git history sheet: _history {title, selected, entries: [[sha,
// author, date, subject, pushed]]} (0 = not up), _history_patch one entry's
// patch, _history_act op 0 = select idx, 1 = close.
// macOS-style UI merge sheet (file changed on disk under unsaved edits):
// _merge {file, current, conflicts: [{ours, theirs, before, after, choice,
// edited}]} (0 = not up); _merge_choose conflict ci with 1 yours / 2 disk /
// 3 both / 4 edited (+ JSON lines); _merge_finish apply 1 / postpone 0
// (returns 0 when apply is refused: a conflict has no choice).
int64_t tk_desktop_merge(int64_t h, int64_t out_ptr, int64_t cap);
void tk_desktop_merge_choose(int64_t h, int64_t ci, int64_t choice, int64_t ptr, int64_t len);
int32_t tk_desktop_merge_finish(int64_t h, int64_t apply, int64_t cols, int64_t rows);
int64_t tk_desktop_history(int64_t h, int64_t out_ptr, int64_t cap);
int64_t tk_desktop_history_patch(int64_t h, int64_t idx, int64_t out_ptr, int64_t cap);
void tk_desktop_history_act(int64_t h, int64_t op, int64_t idx);
int64_t tk_desktop_spelling(int64_t h, int64_t out_ptr, int64_t cap);
int64_t tk_desktop_spelling_rows(int64_t h, int64_t out_ptr, int64_t cap);
void tk_desktop_spelling_act(int64_t h, int64_t action, int64_t ptr, int64_t len);
int64_t tk_desktop_prefs(int64_t h, int64_t out_ptr, int64_t cap);
void tk_desktop_prefs_set(int64_t h, int64_t ptr, int64_t len);
// The list sections (languages, dictionaries, projects) and their buttons.
int64_t tk_desktop_prefs_lists(int64_t h, int64_t out_ptr, int64_t cap);
void tk_desktop_prefs_list_act(int64_t h, int64_t op, int64_t idx, int64_t ptr, int64_t len);
void tk_desktop_prefs_close(int64_t h);
void tk_desktop_prefs_advanced(int64_t h);
int64_t tk_desktop_tree(int64_t h, int64_t cols, int64_t rows, int64_t out_ptr, int64_t cap);
// macOS-style UI review mode: _review {mode: picker {tab, labels, cursor} |
// reviewing {title, files, cur_file, change_index, change_total, num, den,
// editable, bar}} (0 = not up natively); _review_act op 0 tab, 1 pick row,
// 2 cancel / end, 3 next change, 4 previous change, 5 review file arg.
int64_t tk_desktop_review(int64_t h, int64_t cols, int64_t rows, int64_t out_ptr, int64_t cap);
// macOS-style UI tool-pane headers: _panes [{kind, idx, x, y, w, title, focused,
// state, hint, close, commands: [[label, id]]}] (0 = none native); _pane_act
// op 0 focus, 1 close, 2 minimize, 3 maximize, 4 run command id (string).
int64_t tk_desktop_panes(int64_t h, int64_t cols, int64_t rows, int64_t out_ptr, int64_t cap);
// macOS-style UI editor scroller: {win, x, y, w, h, cur, max} for the focused
// frameless editor (visual rows x 1000); drive it with tk_editor_minimap_to.
int64_t tk_desktop_editor_scroller(int64_t h, int64_t cols, int64_t rows, int64_t out_ptr, int64_t cap);
void tk_desktop_pane_act(int64_t h, int64_t kind, int64_t idx, int64_t op, int64_t ptr, int64_t len);
void tk_desktop_review_act(int64_t h, int64_t op, int64_t arg);
void tk_desktop_tree_act(int64_t h, int64_t op, int64_t idx, int64_t x, int64_t y);
int64_t tk_desktop_take_find_request(int64_t h, int64_t out_ptr, int64_t cap);
void tk_desktop_find(int64_t h, int64_t ptr, int64_t len);
int64_t tk_desktop_popup(int64_t h, int64_t out_ptr, int64_t cap);
int32_t tk_desktop_popup_choose(int64_t h, int64_t code);
// macOS-style UI git view (a native sheet over LocalChanges). _git writes the
// state JSON (0 = not up), _git_panels the right side. Panes: 0 files,
// 1 branches, 2 commits, 3 unstaged, 4 staged, 5 info. Operations reuse the
// view's keys (_git_key); overlays are answered with _git_answer.
int64_t tk_desktop_git(int64_t h, int64_t cols, int64_t rows, int64_t out_ptr, int64_t cap);
int64_t tk_desktop_git_panels(int64_t h, int64_t cols, int64_t rows,
                              int64_t out_ptr, int64_t cap);
void tk_desktop_git_select(int64_t h, int64_t pane, int64_t idx, int64_t cols, int64_t rows);
void tk_desktop_git_cursor(int64_t h, int64_t pane, int64_t row);
int32_t tk_desktop_git_key(int64_t h, int64_t pane, int64_t key, int64_t mods,
                           int64_t cols, int64_t rows);
void tk_desktop_git_commit(int64_t h, int64_t ptr, int64_t len);
void tk_desktop_git_open(int64_t h, int64_t pane, int64_t row, int64_t cols, int64_t rows);
void tk_desktop_git_answer(int64_t h, int64_t cptr, int64_t clen, int64_t tptr, int64_t tlen);
int32_t tk_desktop_git_close(int64_t h);
int32_t tk_desktop_welcome_needed(int64_t h);
int64_t tk_desktop_welcome_options(int64_t h, int64_t out_ptr, int64_t cap);
void tk_desktop_welcome_apply(int64_t h, int64_t ptr, int64_t len, int64_t done);
// 1 while a DAP session is paused at a breakpoint. Polled by the scripted
// screenshot path (TK_CAPTURE_WHEN=debug-stopped) — see scripts/screenshots.sh.
int32_t tk_desktop_debug_stopped(int64_t h);
// Drain attention events (Claude turn finished in a terminal pane, debugger
// stop) accumulated since the last call. Polled per tick; while the app is
// in the background each batch bounces the Dock icon and bumps the badge.
int32_t tk_desktop_take_attention(int64_t h);

// One-shot: returns 1 once after the user explicitly opens a new terminal pane,
// 0 otherwise. With the tool panels floating on their own window, the host uses
// this to make that window key so the fresh shell is typeable without a click.
int32_t tk_desktop_take_panel_focus_request(int64_t h);

// One-shot: returns 1 once after a target run / test / debug (re)start, 0
// otherwise. With the tool panels floating on their own window, the host uses
// this to orderFront that window (NOT makeKey) so a restart surfaces the panels
// even when buried behind other windows, without stealing keyboard focus.
int32_t tk_desktop_take_panel_front_request(int64_t h);

// One-shot: returns 1 once after a deliberate open-at-line jump (an output-pane
// link click or a turbokod:// command-line open), 0 otherwise. The host uses it
// to makeKeyAndOrderFront the editor's main window so a link clicked in the
// floating panels window doesn't leave the jumped-to code behind the panels.
int32_t tk_desktop_take_main_focus_request(int64_t h);

// Floating panels (native macOS) — see docs/floating-panels.md. The tool
// panels render on a separate host window via the _panels entry points; the
// main window keeps using the functions above.
void    tk_desktop_set_panels_detached(int64_t h, int64_t on);
int64_t tk_desktop_panels_visible_count(int64_t h);
int64_t tk_desktop_layout_panels(int64_t h, int64_t cols, int64_t rows,
                                 int64_t out_ptr, int64_t cap);
int32_t tk_desktop_panels_key(int64_t h, uint32_t key, uint8_t mods,
                              int64_t cols, int64_t rows);
int32_t tk_desktop_panels_mouse(int64_t h, int64_t x, int64_t y, uint8_t button,
                                uint8_t pressed, uint8_t motion, uint8_t mods,
                                int64_t cols, int64_t rows, uint8_t click_count);
int32_t tk_desktop_panels_pointer_shape(int64_t h, int64_t x, int64_t y,
                                        int64_t cols, int64_t rows);
// Drag-and-drop onto the detached floating-panels window. Mirrors
// tk_desktop_drop_paths but routes through the panel-window layout.
int32_t tk_desktop_panels_drop_paths(int64_t h, int64_t x, int64_t y,
                                     int64_t paths_ptr, int64_t paths_len,
                                     int64_t cols, int64_t rows);
// Classify a drop on the detached panels window: 1 = terminal pane, 0 = none
// (no editors there). Companion to tk_desktop_drop_target.
int32_t tk_desktop_panels_drop_target(int64_t h, int64_t x, int64_t y,
                                      int64_t cols, int64_t rows);

// Settings window: like the floating panels, the macOS host renders the
// Settings view in its own native window. The host sets _set_settings_detached
// once per Desktop, polls _settings_active each tick to open/close the
// NSWindow, and drives the surface with _layout_settings + _settings_key/mouse.
// _settings_close handles the native red-button close.
void    tk_desktop_set_settings_detached(int64_t h, int64_t on);
int32_t tk_desktop_settings_active(int64_t h);
void    tk_desktop_settings_close(int64_t h);
int64_t tk_desktop_layout_settings(int64_t h, int64_t cols, int64_t rows,
                                   int64_t out_ptr, int64_t cap);
int32_t tk_desktop_settings_key(int64_t h, uint32_t key, uint8_t mods,
                                int64_t cols, int64_t rows);
int32_t tk_desktop_settings_mouse(int64_t h, int64_t x, int64_t y, uint8_t button,
                                  uint8_t pressed, uint8_t motion, uint8_t mods,
                                  int64_t cols, int64_t rows, uint8_t click_count);

// Project Settings view in its own native window — twin of the Settings
// surface above (On save / Targets / Grammars). Same host protocol:
// _set_project_settings_detached once, poll _project_settings_active each tick,
// drive with _layout_project_settings + _project_settings_key/mouse,
// _project_settings_close for the native red-button close.
void    tk_desktop_set_project_settings_detached(int64_t h, int64_t on);
int32_t tk_desktop_project_settings_active(int64_t h);
void    tk_desktop_project_settings_close(int64_t h);
int64_t tk_desktop_layout_project_settings(int64_t h, int64_t cols, int64_t rows,
                                           int64_t out_ptr, int64_t cap);
int32_t tk_desktop_project_settings_key(int64_t h, uint32_t key, uint8_t mods,
                                        int64_t cols, int64_t rows);
int32_t tk_desktop_project_settings_mouse(int64_t h, int64_t x, int64_t y, uint8_t button,
                                          uint8_t pressed, uint8_t motion, uint8_t mods,
                                          int64_t cols, int64_t rows, uint8_t click_count);

// Color theme: the host resolves cell color indices through the active
// theme's 256-entry RGB palette. tk_theme_version bumps whenever the user
// switches theme (Settings ▸ Theme); the host polls it and refetches the
// palette via tk_theme_palette only when it changes.
int64_t tk_theme_version(int64_t h);
int64_t tk_theme_palette(int64_t h, int64_t out_ptr, int64_t cap);

// Which project roots are open across the whole app (newline-separated,
// realpath-canonical UTF-8, one per host window including this one). A
// Desktop is one window and can't see its siblings; this is what lets the
// Project menu mark an entry as already open elsewhere. Pushed every frame;
// the core early-outs on an unchanged list.
void    tk_desktop_set_open_projects(int64_t h, int64_t ptr, int64_t n);

// Cell font (Settings ▸ Font): the host registers the system's monospace
// font families once per Desktop (newline-separated UTF-8), which is what
// makes the Font section appear. tk_font_version bumps whenever the user
// switches font; the host polls it and refetches the family name via
// tk_font_name (0 bytes = the built-in bitmap font) only when it changes.
void    tk_desktop_set_font_options(int64_t h, int64_t ptr, int64_t n);
int64_t tk_font_version(int64_t h);
int64_t tk_font_name(int64_t h, int64_t out_ptr, int64_t cap);
// Configured point size (0 = the font's default: 16 bitmap / 13 vector).
// Fetched alongside tk_font_name on a version bump.
int64_t tk_font_size(int64_t h);
// Host -> core report after every font apply: the point size actually
// rendering and the font's design ("ideal") size — 16 for the bundled
// bitmap font, the embedded bitmap-strike ppem for true bitmap fonts,
// 0 when unknown. Drives the Settings size stepper + "Restore ideal".
void    tk_desktop_set_font_size_info(int64_t h, int64_t effective,
                                      int64_t ideal);

#endif
