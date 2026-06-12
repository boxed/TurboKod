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
int64_t tk_editor_smooth_begin(int64_t h, int64_t win_idx,
                               int64_t cols, int64_t rows, int64_t out_ptr);
void    tk_editor_smooth_set(int64_t h, int64_t win_idx,
                             int64_t cols, int64_t rows, int64_t vis_milli);
int32_t tk_desktop_key(int64_t h, uint32_t key, uint8_t mods,
                       int64_t cols, int64_t rows);
int32_t tk_desktop_mouse(int64_t h, int64_t x, int64_t y, uint8_t button,
                         uint8_t pressed, uint8_t motion, uint8_t mods,
                         int64_t cols, int64_t rows, uint8_t click_count);
// Bare modifier-key transition (e.g. Option/Alt press or release) from
// the AppKit host's flagsChanged. mod_id is a MOD_KEY_* value (2 = Alt).
// Drives the editor's Alt-tap and tap-then-hold multi-cursor gestures.
int32_t tk_desktop_mod_key(int64_t h, uint32_t mod_id, uint8_t pressed);
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
int32_t tk_desktop_has_project(int64_t h);
void    tk_desktop_set_host_owns_menu(int64_t h, int64_t on);
void    tk_desktop_set_host_focused(int64_t h, int64_t on);
void    tk_desktop_refresh_git(int64_t h);
int64_t tk_desktop_menu_snapshot(int64_t h, int64_t out_ptr, int64_t cap);
int32_t tk_desktop_menu_invoke(int64_t h, int64_t action_ptr, int64_t action_len,
                               int64_t cols, int64_t rows);
int64_t tk_desktop_take_pending_new_window_project(int64_t h, int64_t out_ptr,
                                                   int64_t cap);
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
