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
void    tk_desktop_open_project(int64_t h, int64_t path_ptr, int64_t path_len);
void    tk_desktop_open_file(int64_t h, int64_t path_ptr, int64_t path_len,
                             int64_t cols, int64_t rows);
void    tk_desktop_open_file_at(int64_t h, int64_t path_ptr, int64_t path_len,
                                int64_t line, int64_t character,
                                int64_t cols, int64_t rows);
void    tk_desktop_tick(int64_t h, int64_t cols, int64_t rows);
int64_t tk_desktop_layout(int64_t h, int64_t cols, int64_t rows,
                          int64_t out_ptr, int64_t cap);
int32_t tk_desktop_key(int64_t h, uint32_t key, uint8_t mods,
                       int64_t cols, int64_t rows);
int32_t tk_desktop_mouse(int64_t h, int64_t x, int64_t y, uint8_t button,
                         uint8_t pressed, uint8_t motion, uint8_t mods,
                         int64_t cols, int64_t rows);
int32_t tk_desktop_pointer_shape(int64_t h, int64_t x, int64_t y,
                                 int64_t cols, int64_t rows);
int32_t tk_desktop_has_project(int64_t h);
void    tk_desktop_set_host_owns_menu(int64_t h, int64_t on);
int64_t tk_desktop_menu_snapshot(int64_t h, int64_t out_ptr, int64_t cap);
int32_t tk_desktop_menu_invoke(int64_t h, int64_t action_ptr, int64_t action_len,
                               int64_t cols, int64_t rows);
int64_t tk_desktop_take_pending_new_window_project(int64_t h, int64_t out_ptr,
                                                   int64_t cap);

// Floating panels (native macOS) — see docs/floating-panels.md. The tool
// panels render on a separate host window via the _panels entry points; the
// main window keeps using the functions above.
void    tk_desktop_set_panels_detached(int64_t h, int64_t on);
int64_t tk_desktop_layout_panels(int64_t h, int64_t cols, int64_t rows,
                                 int64_t out_ptr, int64_t cap);
int32_t tk_desktop_panels_key(int64_t h, uint32_t key, uint8_t mods,
                              int64_t cols, int64_t rows);
int32_t tk_desktop_panels_mouse(int64_t h, int64_t x, int64_t y, uint8_t button,
                                uint8_t pressed, uint8_t motion, uint8_t mods,
                                int64_t cols, int64_t rows);
int32_t tk_desktop_panels_pointer_shape(int64_t h, int64_t x, int64_t y,
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
                                  int64_t cols, int64_t rows);

// Color theme: the host resolves cell color indices through the active
// theme's 256-entry RGB palette. tk_theme_version bumps whenever the user
// switches theme (Settings ▸ Theme); the host polls it and refetches the
// palette via tk_theme_palette only when it changes.
int64_t tk_theme_version(int64_t h);
int64_t tk_theme_palette(int64_t h, int64_t out_ptr, int64_t cap);

#endif
