#ifndef TURBOKOD_H
#define TURBOKOD_H
#include <stdint.h>

// C ABI exported by the Mojo shared-lib (src/turbokod/native_api.mojo).
// Mojo `Int` is 64-bit; handles and addresses cross as int64_t.

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

#endif
