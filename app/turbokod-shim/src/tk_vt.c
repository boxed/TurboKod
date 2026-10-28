// Flat C ABI over libghostty-vt for ``vt.mojo``.
//
// libghostty-vt's API is built from sized structs, tagged unions and
// callbacks — fine from C, fragile to mirror field-by-field in Mojo, and
// explicitly unstable between Ghostty commits. So this file is the *only*
// code that sees Ghostty's headers. It exposes integers, pointers and byte
// buffers; a Ghostty bump that changes a struct is a compile error here, not
// silent memory corruption on the Mojo side.
//
// One ``TkVt`` owns a Ghostty terminal plus everything the panes need around
// it: the render state it reads cells through, key/mouse encoders, and the
// queues the terminal's callbacks fill (replies for the pty, OSC 52 clipboard
// writes). Callbacks only ever append to those queues; Mojo drains them after
// each ``tk_vt_write``.
//
// Ownership mirrors the libonig registry in ``lib.rs``: Mojo's ``Vt`` is a
// copyable value holding this pointer, so copies alias it, and no destructor
// can safely free it. ``tk_vt_free`` frees only a registered handle, so a
// second release through an aliasing copy is a no-op instead of a double free.

#include <ghostty/vt.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// Pixel size we report for a cell. Nothing renders through it: the mouse
// encoder converts surface pixels to cells, so we place each event in the
// middle of its cell, and XTWINOPS pixel queries see a plausible VGA cell.
#define TK_CELL_W 8
#define TK_CELL_H 16

// Words per cell in a snapshot (see ``tk_vt_cells``).
#define TK_CELL_WORDS 6

// ``tk_vt_peek`` / ``tk_vt_consume`` channels.
#define TK_CHAN_REPLY 0
#define TK_CHAN_CLIPBOARD 1
#define TK_CHAN_TITLE 2
#define TK_CHAN_SCRATCH 3

// Snapshot areas.
#define TK_AREA_VIEWPORT 0
#define TK_AREA_ACTIVE 1

typedef struct {
  uint8_t *p;
  size_t len, cap;
} TkBuf;

static void buf_reserve(TkBuf *b, size_t extra) {
  if (b->len + extra <= b->cap) return;
  size_t cap = b->cap ? b->cap : 256;
  while (cap < b->len + extra) cap *= 2;
  uint8_t *p = realloc(b->p, cap);
  if (!p) abort();
  b->p = p;
  b->cap = cap;
}

static void buf_append(TkBuf *b, const void *data, size_t n) {
  if (n == 0) return;
  buf_reserve(b, n);
  memcpy(b->p + b->len, data, n);
  b->len += n;
}

static void buf_free(TkBuf *b) {
  free(b->p);
  b->p = NULL;
  b->len = b->cap = 0;
}

static size_t utf8_encode(uint32_t cp, uint8_t out[4]) {
  if (cp < 0x80) {
    out[0] = (uint8_t)cp;
    return 1;
  }
  if (cp < 0x800) {
    out[0] = 0xC0 | (cp >> 6);
    out[1] = 0x80 | (cp & 0x3F);
    return 2;
  }
  if (cp < 0x10000) {
    out[0] = 0xE0 | (cp >> 12);
    out[1] = 0x80 | ((cp >> 6) & 0x3F);
    out[2] = 0x80 | (cp & 0x3F);
    return 3;
  }
  out[0] = 0xF0 | (cp >> 18);
  out[1] = 0x80 | ((cp >> 12) & 0x3F);
  out[2] = 0x80 | ((cp >> 6) & 0x3F);
  out[3] = 0x80 | (cp & 0x3F);
  return 4;
}

// A grid of cells read out of the terminal: ``TK_CELL_WORDS`` words per cell
// in ``words``, glyph bytes in ``text``. Rebuilt lazily when stale.
typedef struct {
  bool valid;
  uint16_t cols, rows;
  uint32_t *words;
  size_t words_cap;
  TkBuf text;
} TkSnapshot;

typedef struct TkVt {
  GhosttyTerminal term;
  GhosttyRenderState rs;
  GhosttyRenderStateRowIterator row_iter;
  GhosttyRenderStateRowCells row_cells;
  GhosttyKeyEncoder kenc;
  GhosttyKeyEvent kev;
  GhosttyMouseEncoder menc;
  GhosttyMouseEvent mev;
  TkBuf reply;
  TkBuf clipboard;
  TkBuf scratch;
  TkSnapshot view;
  TkSnapshot active;
} TkVt;

// --- registry ------------------------------------------------------------

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static TkVt **g_live;
static size_t g_live_len, g_live_cap;

static void registry_add(TkVt *v) {
  pthread_mutex_lock(&g_lock);
  if (g_live_len == g_live_cap) {
    size_t cap = g_live_cap ? g_live_cap * 2 : 16;
    TkVt **p = realloc(g_live, cap * sizeof(*p));
    if (!p) abort();
    g_live = p;
    g_live_cap = cap;
  }
  g_live[g_live_len++] = v;
  pthread_mutex_unlock(&g_lock);
}

static bool registry_remove(TkVt *v) {
  bool found = false;
  pthread_mutex_lock(&g_lock);
  for (size_t i = 0; i < g_live_len; i++) {
    if (g_live[i] == v) {
      g_live[i] = g_live[--g_live_len];
      found = true;
      break;
    }
  }
  pthread_mutex_unlock(&g_lock);
  return found;
}

// --- callbacks -----------------------------------------------------------

static void on_write_pty(GhosttyTerminal t, void *ud, const uint8_t *data,
                         size_t len) {
  (void)t;
  buf_append(&((TkVt *)ud)->reply, data, len);
}

// OSC 52 (and the iTerm2 / kitty equivalents): keep the text/plain
// representation, which is what the system clipboard gets. A later write
// before the pane drains replaces an earlier one — the clipboard only ever
// holds the latest value anyway.
static void on_clipboard_write(GhosttyTerminal t, void *ud,
                               const GhosttyClipboardWrite *w) {
  (void)t;
  TkVt *v = ud;
  const GhosttyClipboardContent *pick = NULL;
  for (size_t i = 0; i < w->contents_len; i++) {
    const GhosttyString *m = &w->contents[i].mime;
    if (m->len >= 10 && memcmp(m->ptr, "text/plain", 10) == 0) {
      pick = &w->contents[i];
      break;
    }
  }
  if (!pick && w->contents_len > 0) pick = &w->contents[0];
  if (pick) {
    v->clipboard.len = 0;
    buf_append(&v->clipboard, pick->data.ptr, pick->data.len);
  }
  GhosttyClipboardWriteReply reply = {
      .size = sizeof(reply),
      .result = GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS,
      .remember = false,
  };
  w->reply(w, &reply);
}

// Without this callback Ghostty ignores DA queries, and shells that probe
// with one (fish, starship) stall waiting for the answer. Same identity the
// Ghostty app reports: VT220-level with ANSI color.
static bool on_device_attributes(GhosttyTerminal t, void *ud,
                                 GhosttyDeviceAttributes *out) {
  (void)t;
  (void)ud;
  memset(out, 0, sizeof(*out));
  out->primary.conformance_level = 62;
  out->primary.features[0] = 22;
  out->primary.num_features = 1;
  out->secondary.device_type = 1;
  out->secondary.firmware_version = 10;
  return true;
}

static bool on_size(GhosttyTerminal t, void *ud, GhosttySizeReportSize *out) {
  (void)ud;
  uint16_t cols = 0, rows = 0;
  ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_COLS, &cols);
  ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_ROWS, &rows);
  out->rows = rows;
  out->columns = cols;
  out->cell_width = TK_CELL_W;
  out->cell_height = TK_CELL_H;
  return true;
}

// --- lifecycle -----------------------------------------------------------

void *tk_vt_new(int64_t cols, int64_t rows, int64_t scrollback_lines) {
  if (cols < 1) cols = 1;
  if (rows < 1) rows = 1;
  TkVt *v = calloc(1, sizeof(TkVt));
  if (!v) return NULL;
  if (ghostty_terminal_new(NULL, &v->term, (uint16_t)cols, (uint16_t)rows) !=
          GHOSTTY_SUCCESS ||
      ghostty_render_state_new(NULL, &v->rs) != GHOSTTY_SUCCESS ||
      ghostty_render_state_row_iterator_new(NULL, &v->row_iter) !=
          GHOSTTY_SUCCESS ||
      ghostty_render_state_row_cells_new(NULL, &v->row_cells) !=
          GHOSTTY_SUCCESS ||
      ghostty_key_encoder_new(NULL, &v->kenc) != GHOSTTY_SUCCESS ||
      ghostty_key_event_new(NULL, &v->kev) != GHOSTTY_SUCCESS ||
      ghostty_mouse_encoder_new(NULL, &v->menc) != GHOSTTY_SUCCESS ||
      ghostty_mouse_event_new(NULL, &v->mev) != GHOSTTY_SUCCESS) {
    abort();
  }
  ghostty_terminal_resize(v->term, (uint16_t)cols, (uint16_t)rows, TK_CELL_W,
                          TK_CELL_H);
  ghostty_terminal_set(v->term, GHOSTTY_TERMINAL_OPT_USERDATA, v);
  ghostty_terminal_set(v->term, GHOSTTY_TERMINAL_OPT_WRITE_PTY,
                       (const void *)on_write_pty);
  ghostty_terminal_set(v->term, GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE,
                       (const void *)on_clipboard_write);
  ghostty_terminal_set(v->term, GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES,
                       (const void *)on_device_attributes);
  ghostty_terminal_set(v->term, GHOSTTY_TERMINAL_OPT_SIZE,
                       (const void *)on_size);
  size_t lines = scrollback_lines < 0 ? 0 : (size_t)scrollback_lines;
  ghostty_terminal_set(v->term, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES,
                       &lines);
  // Alt sends an ESC prefix — what the hand-rolled encoder did, and what
  // readline / zsh word motions expect from the macOS Option key. It is a
  // terminal mode (1036) the key encoder copies from the terminal, so it is
  // set as the mode's default: a program can still turn it off.
  bool on = true;
  GhosttyTerminalModeConfig alt_esc = {.mode = GHOSTTY_MODE_ALT_ESC_PREFIX,
                                       .value = true};
  ghostty_terminal_set(v->term, GHOSTTY_TERMINAL_OPT_MODE_DEFAULT, &alt_esc);
  ghostty_mouse_encoder_setopt(v->menc,
                               GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL, &on);
  registry_add(v);
  return v;
}

// Free ``h`` if it is still registered. Returns 1 when this call freed it,
// 0 when it was already freed (or never ours).
int64_t tk_vt_free(void *h) {
  TkVt *v = h;
  if (!v || !registry_remove(v)) return 0;
  ghostty_mouse_event_free(v->mev);
  ghostty_mouse_encoder_free(v->menc);
  ghostty_key_event_free(v->kev);
  ghostty_key_encoder_free(v->kenc);
  ghostty_render_state_row_cells_free(v->row_cells);
  ghostty_render_state_row_iterator_free(v->row_iter);
  ghostty_render_state_free(v->rs);
  ghostty_terminal_free(v->term);
  buf_free(&v->reply);
  buf_free(&v->clipboard);
  buf_free(&v->scratch);
  free(v->view.words);
  buf_free(&v->view.text);
  free(v->active.words);
  buf_free(&v->active.text);
  free(v);
  return 1;
}

int64_t tk_vt_live_count(void) {
  pthread_mutex_lock(&g_lock);
  int64_t n = (int64_t)g_live_len;
  pthread_mutex_unlock(&g_lock);
  return n;
}

static void invalidate(TkVt *v) {
  v->view.valid = false;
  v->active.valid = false;
}

// --- input ---------------------------------------------------------------

void tk_vt_write(void *h, const uint8_t *data, int64_t len) {
  TkVt *v = h;
  if (len <= 0) return;
  ghostty_terminal_vt_write(v->term, data, (size_t)len);
  invalidate(v);
}

void tk_vt_resize(void *h, int64_t cols, int64_t rows) {
  TkVt *v = h;
  if (cols < 1 || rows < 1) return;
  ghostty_terminal_resize(v->term, (uint16_t)cols, (uint16_t)rows, TK_CELL_W,
                          TK_CELL_H);
  invalidate(v);
}

// Full reset (RIS): screen, scrollback, modes, title. The size stays.
void tk_vt_reset(void *h) {
  TkVt *v = h;
  ghostty_terminal_reset(v->term);
  v->reply.len = 0;
  v->clipboard.len = 0;
  invalidate(v);
}

// Scroll the viewport ``older`` rows into history (negative: toward the
// live tail). Ghostty clamps at both ends.
void tk_vt_scroll(void *h, int64_t older) {
  TkVt *v = h;
  GhosttyTerminalScrollViewport s = {.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA};
  s.value.delta = (intptr_t)-older;
  ghostty_terminal_scroll_viewport(v->term, s);
  invalidate(v);
}

void tk_vt_scroll_to_bottom(void *h) {
  TkVt *v = h;
  GhosttyTerminalScrollViewport s = {.tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM};
  ghostty_terminal_scroll_viewport(v->term, s);
  invalidate(v);
}

// --- state ---------------------------------------------------------------

static bool mode_on(TkVt *v, GhosttyMode mode) {
  GhosttyTerminalModeConfig m = {.mode = mode, .value = false};
  if (ghostty_terminal_get(v->term, GHOSTTY_TERMINAL_DATA_MODE, &m) !=
      GHOSTTY_SUCCESS)
    return false;
  return m.value;
}

// Keys for ``tk_vt_get``. Keep in step with the ``_K_*`` constants in
// ``vt.mojo``.
enum {
  TK_GET_COLS = 0,
  TK_GET_ROWS = 1,
  TK_GET_CURSOR_X = 2,
  TK_GET_CURSOR_Y = 3,
  TK_GET_CURSOR_VISIBLE = 4,
  TK_GET_ALT_SCREEN = 5,
  TK_GET_SCROLLBACK_ROWS = 6,
  TK_GET_VIEW_OFFSET = 7,
  TK_GET_MOUSE_TRACKING = 8,
  TK_GET_MOUSE_BUTTON_MOTION = 9,
  TK_GET_MOUSE_ANY_MOTION = 10,
  TK_GET_CURSOR_KEYS_APP = 11,
  TK_GET_BRACKETED_PASTE = 12,
  TK_GET_FOCUS_EVENTS = 13,
  TK_GET_PENDING_WRAP = 14,
  TK_GET_MOUSE_SGR = 15,
};

int64_t tk_vt_get(void *h, int64_t key) {
  TkVt *v = h;
  switch (key) {
  case TK_GET_COLS: {
    uint16_t n = 0;
    ghostty_terminal_get(v->term, GHOSTTY_TERMINAL_DATA_COLS, &n);
    return n;
  }
  case TK_GET_ROWS: {
    uint16_t n = 0;
    ghostty_terminal_get(v->term, GHOSTTY_TERMINAL_DATA_ROWS, &n);
    return n;
  }
  case TK_GET_CURSOR_X: {
    uint16_t n = 0;
    ghostty_terminal_get(v->term, GHOSTTY_TERMINAL_DATA_CURSOR_X, &n);
    return n;
  }
  case TK_GET_CURSOR_Y: {
    uint16_t n = 0;
    ghostty_terminal_get(v->term, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &n);
    return n;
  }
  case TK_GET_CURSOR_VISIBLE: {
    bool b = false;
    ghostty_terminal_get(v->term, GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE, &b);
    return b;
  }
  case TK_GET_ALT_SCREEN: {
    GhosttyTerminalScreen s = GHOSTTY_TERMINAL_SCREEN_PRIMARY;
    ghostty_terminal_get(v->term, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &s);
    return s != GHOSTTY_TERMINAL_SCREEN_PRIMARY;
  }
  case TK_GET_SCROLLBACK_ROWS: {
    size_t n = 0;
    ghostty_terminal_get(v->term, GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, &n);
    return (int64_t)n;
  }
  case TK_GET_VIEW_OFFSET: {
    // Rows of history above the live tail the viewport has scrolled up by.
    GhosttyTerminalScrollbar sb = {0};
    ghostty_terminal_get(v->term, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &sb);
    uint64_t bottom = sb.offset + sb.len;
    return bottom >= sb.total ? 0 : (int64_t)(sb.total - bottom);
  }
  case TK_GET_MOUSE_TRACKING: {
    bool b = false;
    ghostty_terminal_get(v->term, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &b);
    return b;
  }
  case TK_GET_MOUSE_BUTTON_MOTION:
    return mode_on(v, GHOSTTY_MODE_BUTTON_MOUSE);
  case TK_GET_MOUSE_ANY_MOTION:
    return mode_on(v, GHOSTTY_MODE_ANY_MOUSE);
  case TK_GET_CURSOR_KEYS_APP:
    return mode_on(v, GHOSTTY_MODE_DECCKM);
  case TK_GET_BRACKETED_PASTE:
    return mode_on(v, GHOSTTY_MODE_BRACKETED_PASTE);
  case TK_GET_FOCUS_EVENTS:
    return mode_on(v, GHOSTTY_MODE_FOCUS_EVENT);
  case TK_GET_PENDING_WRAP: {
    bool b = false;
    ghostty_terminal_get(v->term, GHOSTTY_TERMINAL_DATA_CURSOR_PENDING_WRAP,
                         &b);
    return b;
  }
  case TK_GET_MOUSE_SGR:
    return mode_on(v, GHOSTTY_MODE_SGR_MOUSE);
  }
  return 0;
}

// Byte channels: returns the length and stores a pointer to the bytes in
// ``*out``, valid until the next call on this handle. ``tk_vt_consume``
// empties a queue once Mojo has copied it.
int64_t tk_vt_peek(void *h, int64_t chan, const uint8_t **out) {
  TkVt *v = h;
  switch (chan) {
  case TK_CHAN_REPLY:
    *out = v->reply.p;
    return (int64_t)v->reply.len;
  case TK_CHAN_CLIPBOARD:
    *out = v->clipboard.p;
    return (int64_t)v->clipboard.len;
  case TK_CHAN_TITLE: {
    GhosttyString s = {0};
    ghostty_terminal_get(v->term, GHOSTTY_TERMINAL_DATA_TITLE, &s);
    *out = s.ptr;
    return (int64_t)s.len;
  }
  case TK_CHAN_SCRATCH:
    *out = v->scratch.p;
    return (int64_t)v->scratch.len;
  }
  *out = NULL;
  return 0;
}

void tk_vt_consume(void *h, int64_t chan) {
  TkVt *v = h;
  if (chan == TK_CHAN_REPLY) v->reply.len = 0;
  if (chan == TK_CHAN_CLIPBOARD) v->clipboard.len = 0;
}

// --- cells ---------------------------------------------------------------
//
// A snapshot cell is six words:
//   0  byte offset of the glyph in the snapshot's text
//   1  glyph length in bytes (0: empty cell)
//   2  foreground color   (tag << 24 | value; tag 0 = default, 1 = palette
//   3  background color    index, 2 = 0xRRGGBB)
//   4  flags: bit 0 bold, 1 italic, 2 faint, 3 blink, 4 inverse,
//      5 invisible, 6 strikethrough, 7 overline; bits 8..10 underline
//      (GHOSTTY_SGR_UNDERLINE_*); bits 12..13 width (GHOSTTY_CELL_WIDE_*)
//   5  underline color    (same encoding as 2/3)

static uint32_t enc_color(const GhosttyStyleColor *c) {
  switch (c->tag) {
  case GHOSTTY_STYLE_COLOR_PALETTE:
    return (1u << 24) | c->value.palette;
  case GHOSTTY_STYLE_COLOR_RGB:
    return (2u << 24) | ((uint32_t)c->value.rgb.r << 16) |
           ((uint32_t)c->value.rgb.g << 8) | c->value.rgb.b;
  default:
    return 0;
  }
}

static void put_cell(uint32_t *w, GhosttyCell raw, const GhosttyStyle *st) {
  uint32_t flags = 0;
  if (st->bold) flags |= 1u << 0;
  if (st->italic) flags |= 1u << 1;
  if (st->faint) flags |= 1u << 2;
  if (st->blink) flags |= 1u << 3;
  if (st->inverse) flags |= 1u << 4;
  if (st->invisible) flags |= 1u << 5;
  if (st->strikethrough) flags |= 1u << 6;
  if (st->overline) flags |= 1u << 7;
  flags |= ((uint32_t)st->underline & 0x7) << 8;
  GhosttyCellWide wide = GHOSTTY_CELL_WIDE_NARROW;
  ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide);
  flags |= ((uint32_t)wide & 0x3) << 12;
  w[2] = enc_color(&st->fg_color);
  w[3] = enc_color(&st->bg_color);
  // An erase with a background color leaves a text-less cell whose
  // content *is* that color, not a styled blank.
  GhosttyCellContentTag tag = GHOSTTY_CELL_CONTENT_CODEPOINT;
  ghostty_cell_get(raw, GHOSTTY_CELL_DATA_CONTENT_TAG, &tag);
  if (tag == GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE) {
    GhosttyColorPaletteIndex idx = 0;
    ghostty_cell_get(raw, GHOSTTY_CELL_DATA_COLOR_PALETTE, &idx);
    w[3] = (1u << 24) | idx;
  } else if (tag == GHOSTTY_CELL_CONTENT_BG_COLOR_RGB) {
    GhosttyColorRgb rgb = {0};
    ghostty_cell_get(raw, GHOSTTY_CELL_DATA_COLOR_RGB, &rgb);
    w[3] = (2u << 24) | ((uint32_t)rgb.r << 16) | ((uint32_t)rgb.g << 8) |
           rgb.b;
  }
  w[4] = flags;
  w[5] = enc_color(&st->underline_color);
}

static void snapshot_reset(TkSnapshot *s, uint16_t cols, uint16_t rows) {
  size_t need = (size_t)cols * rows * TK_CELL_WORDS;
  if (need > s->words_cap) {
    uint32_t *p = realloc(s->words, need * sizeof(uint32_t));
    if (!p) abort();
    s->words = p;
    s->words_cap = need;
  }
  memset(s->words, 0, need * sizeof(uint32_t));
  s->cols = cols;
  s->rows = rows;
  s->text.len = 0;
}

// The viewport, through the render state — Ghostty's fast path for reading a
// whole screen.
static void build_view(TkVt *v) {
  TkSnapshot *s = &v->view;
  ghostty_render_state_update(v->rs, v->term);
  uint16_t cols = 0, rows = 0;
  ghostty_render_state_get(v->rs, GHOSTTY_RENDER_STATE_DATA_COLS, &cols);
  ghostty_render_state_get(v->rs, GHOSTTY_RENDER_STATE_DATA_ROWS, &rows);
  snapshot_reset(s, cols, rows);
  ghostty_render_state_get(v->rs, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,
                           &v->row_iter);
  uint16_t y = 0;
  while (y < rows && ghostty_render_state_row_iterator_next(v->row_iter)) {
    ghostty_render_state_row_get(v->row_iter,
                                 GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
                                 &v->row_cells);
    uint16_t x = 0;
    while (x < cols && ghostty_render_state_row_cells_next(v->row_cells)) {
      uint32_t *w = s->words + ((size_t)y * cols + x) * TK_CELL_WORDS;
      GhosttyCell raw = 0;
      ghostty_render_state_row_cells_get(
          v->row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw);
      GhosttyStyle st = GHOSTTY_INIT_SIZED(GhosttyStyle);
      bool styled = false;
      ghostty_render_state_row_cells_get(
          v->row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING,
          &styled);
      if (styled) {
        ghostty_render_state_row_cells_get(
            v->row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &st);
      } else {
        ghostty_style_default(&st);
      }
      put_cell(w, raw, &st);
      buf_reserve(&s->text, 64);
      GhosttyBuffer gb = {.ptr = s->text.p + s->text.len,
                          .cap = s->text.cap - s->text.len,
                          .len = 0};
      GhosttyResult r = ghostty_render_state_row_cells_get(
          v->row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8,
          &gb);
      if (r == GHOSTTY_OUT_OF_SPACE) {
        buf_reserve(&s->text, gb.len);
        gb.ptr = s->text.p + s->text.len;
        gb.cap = s->text.cap - s->text.len;
        gb.len = 0;
        r = ghostty_render_state_row_cells_get(
            v->row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8,
            &gb);
      }
      if (r == GHOSTTY_SUCCESS && gb.len > 0) {
        w[0] = (uint32_t)s->text.len;
        w[1] = (uint32_t)gb.len;
        s->text.len += gb.len;
      }
      x++;
    }
    y++;
  }
  ghostty_render_state_clean(v->rs);
  s->valid = true;
}

// The active area (the live screen, ignoring any scrollback the user has
// scrolled to), cell by cell through grid refs. Only needed while scrolled
// back — otherwise the viewport *is* the active area.
static void build_active(TkVt *v) {
  TkSnapshot *s = &v->active;
  uint16_t cols = 0, rows = 0;
  ghostty_terminal_get(v->term, GHOSTTY_TERMINAL_DATA_COLS, &cols);
  ghostty_terminal_get(v->term, GHOSTTY_TERMINAL_DATA_ROWS, &rows);
  snapshot_reset(s, cols, rows);
  uint32_t cps[32];
  for (uint16_t y = 0; y < rows; y++) {
    for (uint16_t x = 0; x < cols; x++) {
      uint32_t *w = s->words + ((size_t)y * cols + x) * TK_CELL_WORDS;
      GhosttyPoint pt = {.tag = GHOSTTY_POINT_TAG_ACTIVE};
      pt.value.coordinate.x = x;
      pt.value.coordinate.y = y;
      GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
      if (ghostty_terminal_grid_ref(v->term, pt, &ref) != GHOSTTY_SUCCESS)
        continue;
      GhosttyCell raw = 0;
      ghostty_grid_ref_cell(&ref, &raw);
      GhosttyStyle st = GHOSTTY_INIT_SIZED(GhosttyStyle);
      if (ghostty_grid_ref_style(&ref, &st) != GHOSTTY_SUCCESS)
        ghostty_style_default(&st);
      put_cell(w, raw, &st);
      size_t n = 0;
      if (ghostty_grid_ref_graphemes(&ref, cps, 32, &n) != GHOSTTY_SUCCESS)
        n = 0;
      if (n > 32) n = 32;
      size_t start = s->text.len;
      for (size_t i = 0; i < n; i++) {
        uint8_t u[4];
        buf_append(&s->text, u, utf8_encode(cps[i], u));
      }
      if (s->text.len > start) {
        w[0] = (uint32_t)start;
        w[1] = (uint32_t)(s->text.len - start);
      }
    }
  }
  s->valid = true;
}

static TkSnapshot *snapshot(TkVt *v, int64_t area) {
  if (area == TK_AREA_ACTIVE && tk_vt_get(v, TK_GET_VIEW_OFFSET) != 0) {
    if (!v->active.valid) build_active(v);
    return &v->active;
  }
  if (!v->view.valid) build_view(v);
  return &v->view;
}

// The cell words of ``area``, rebuilt if the terminal changed since the last
// read. ``out`` receives the address of the glyph bytes the words index
// into, then the grid's cols and rows. Valid until the next mutating call.
const uint32_t *tk_vt_cells(void *h, int64_t area, int64_t out[3]) {
  TkSnapshot *s = snapshot(h, area);
  out[0] = (int64_t)(uintptr_t)s->text.p;
  out[1] = s->cols;
  out[2] = s->rows;
  return s->words;
}

// --- encoders ------------------------------------------------------------

static int64_t encode_result(TkVt *v, GhosttyResult r, size_t n) {
  if (r != GHOSTTY_SUCCESS) {
    v->scratch.len = 0;
    return 0;
  }
  v->scratch.len = n;
  return (int64_t)n;
}

// turbokod's input vocabulary, mirrored from ``events.mojo`` (``KEY_*``,
// ``MOD_*``, ``MOUSE_*``). Translating it here keeps Ghostty's enums out of
// Mojo entirely; ``tests/test_vt.mojo`` pins the encodings, so a drift on
// either side fails a test rather than sending the wrong bytes.
#define TK_MOD_SHIFT (1 << 0)
#define TK_MOD_ALT (1 << 1)
#define TK_MOD_CTRL (1 << 2)
#define TK_MOD_META (1 << 3)

static GhosttyMods ghostty_mods(int64_t mods) {
  GhosttyMods m = 0;
  if (mods & TK_MOD_SHIFT) m |= GHOSTTY_MODS_SHIFT;
  if (mods & TK_MOD_ALT) m |= GHOSTTY_MODS_ALT;
  if (mods & TK_MOD_CTRL) m |= GHOSTTY_MODS_CTRL;
  if (mods & TK_MOD_META) m |= GHOSTTY_MODS_SUPER;
  return m;
}

static GhosttyKey named_key(int64_t key) {
  switch (key) {
  case 0xE001: return GHOSTTY_KEY_ENTER;
  case 0xE002: return GHOSTTY_KEY_TAB;
  case 0xE003: return GHOSTTY_KEY_BACKSPACE;
  case 0xE004: return GHOSTTY_KEY_ESCAPE;
  case 0xE010: return GHOSTTY_KEY_ARROW_UP;
  case 0xE011: return GHOSTTY_KEY_ARROW_DOWN;
  case 0xE012: return GHOSTTY_KEY_ARROW_LEFT;
  case 0xE013: return GHOSTTY_KEY_ARROW_RIGHT;
  case 0xE014: return GHOSTTY_KEY_HOME;
  case 0xE015: return GHOSTTY_KEY_END;
  case 0xE016: return GHOSTTY_KEY_PAGE_UP;
  case 0xE017: return GHOSTTY_KEY_PAGE_DOWN;
  case 0xE018: return GHOSTTY_KEY_INSERT;
  case 0xE019: return GHOSTTY_KEY_DELETE;
  case 0xE020: return GHOSTTY_KEY_F1;
  case 0xE021: return GHOSTTY_KEY_F2;
  case 0xE022: return GHOSTTY_KEY_F3;
  case 0xE023: return GHOSTTY_KEY_F4;
  case 0xE024: return GHOSTTY_KEY_F5;
  case 0xE025: return GHOSTTY_KEY_F6;
  case 0xE026: return GHOSTTY_KEY_F7;
  case 0xE027: return GHOSTTY_KEY_F8;
  case 0xE028: return GHOSTTY_KEY_F9;
  case 0xE029: return GHOSTTY_KEY_F10;
  case 0xE02A: return GHOSTTY_KEY_F11;
  case 0xE02B: return GHOSTTY_KEY_F12;
  }
  return GHOSTTY_KEY_UNIDENTIFIED;
}

// The physical key a US layout types ``cp`` with, and the unshifted
// codepoint on that key. Characters with no key of their own (shifted
// symbols, non-ASCII) stay UNIDENTIFIED and travel as text.
_Static_assert(GHOSTTY_KEY_Z - GHOSTTY_KEY_A == 25 &&
                   GHOSTTY_KEY_DIGIT_9 - GHOSTTY_KEY_DIGIT_0 == 9,
               "printable_key indexes letters and digits by offset");

static GhosttyKey printable_key(uint32_t cp, uint32_t *unshifted) {
  *unshifted = cp;
  if (cp >= 'a' && cp <= 'z') return GHOSTTY_KEY_A + (cp - 'a');
  if (cp >= 'A' && cp <= 'Z') {
    *unshifted = cp - 'A' + 'a';
    return GHOSTTY_KEY_A + (cp - 'A');
  }
  if (cp >= '0' && cp <= '9') return GHOSTTY_KEY_DIGIT_0 + (cp - '0');
  switch (cp) {
  case ' ': return GHOSTTY_KEY_SPACE;
  case '`': return GHOSTTY_KEY_BACKQUOTE;
  case '\\': return GHOSTTY_KEY_BACKSLASH;
  case '[': return GHOSTTY_KEY_BRACKET_LEFT;
  case ']': return GHOSTTY_KEY_BRACKET_RIGHT;
  case ',': return GHOSTTY_KEY_COMMA;
  case '=': return GHOSTTY_KEY_EQUAL;
  case '-': return GHOSTTY_KEY_MINUS;
  case '.': return GHOSTTY_KEY_PERIOD;
  case '\'': return GHOSTTY_KEY_QUOTE;
  case ';': return GHOSTTY_KEY_SEMICOLON;
  case '/': return GHOSTTY_KEY_SLASH;
  }
  return GHOSTTY_KEY_UNIDENTIFIED;
}

// Encode a key press into ``scratch`` (read it with ``TK_CHAN_SCRATCH``).
// ``key`` is a turbokod key code — a ``KEY_*`` constant or a codepoint —
// and ``mods`` a ``MOD_*`` mask. Honors whatever the program enabled
// (DECCKM, modifyOtherKeys, the kitty keyboard protocol). Returns the
// encoded length; 0 for a key that sends nothing.
int64_t tk_vt_encode_key(void *h, int64_t key, int64_t mods) {
  TkVt *v = h;
  uint8_t text[4];
  size_t text_len = 0;
  uint32_t unshifted = 0;
  GhosttyKey gk = named_key(key);
  if (gk == GHOSTTY_KEY_UNIDENTIFIED && key >= 0x20 && key != 0x7F &&
      key <= 0x10FFFF && !(key >= 0xE000 && key <= 0xF8FF)) {
    gk = printable_key((uint32_t)key, &unshifted);
    text_len = utf8_encode((uint32_t)key, text);
  }
  if (gk == GHOSTTY_KEY_UNIDENTIFIED && text_len == 0) {
    v->scratch.len = 0;
    return 0;
  }
  GhosttyMods gm = ghostty_mods(mods);
  // An uppercase letter arrives without SHIFT in its mods when the host
  // resolved the shift itself; the encoder wants to know it was shifted.
  if (key >= 'A' && key <= 'Z') gm |= GHOSTTY_MODS_SHIFT;
  ghostty_key_encoder_setopt_from_terminal(v->kenc, v->term);
  // Not terminal state, so the sync above resets it: Option is Alt (our
  // hosts resolve Option-composed text themselves).
  GhosttyOptionAsAlt as_alt = GHOSTTY_OPTION_AS_ALT_TRUE;
  ghostty_key_encoder_setopt(v->kenc,
                             GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT,
                             &as_alt);
  ghostty_key_event_set_action(v->kev, GHOSTTY_KEY_ACTION_PRESS);
  ghostty_key_event_set_key(v->kev, gk);
  ghostty_key_event_set_mods(v->kev, gm);
  ghostty_key_event_set_consumed_mods(v->kev, 0);
  ghostty_key_event_set_composing(v->kev, false);
  ghostty_key_event_set_utf8(v->kev, text_len ? (const char *)text : NULL,
                             text_len);
  ghostty_key_event_set_unshifted_codepoint(v->kev, unshifted);
  buf_reserve(&v->scratch, 128);
  size_t n = 0;
  GhosttyResult r = ghostty_key_encoder_encode(
      v->kenc, v->kev, (char *)v->scratch.p, v->scratch.cap, &n);
  if (r == GHOSTTY_OUT_OF_SPACE) {
    buf_reserve(&v->scratch, n);
    r = ghostty_key_encoder_encode(v->kenc, v->kev, (char *)v->scratch.p,
                                   v->scratch.cap, &n);
  }
  return encode_result(v, r, n);
}

#define TK_MOUSE_PRESS 0
#define TK_MOUSE_RELEASE 1
#define TK_MOUSE_MOTION 2

static GhosttyMouseButton ghostty_button(int64_t button) {
  switch (button) {
  case 1: return GHOSTTY_MOUSE_BUTTON_LEFT;
  case 2: return GHOSTTY_MOUSE_BUTTON_MIDDLE;
  case 3: return GHOSTTY_MOUSE_BUTTON_RIGHT;
  case 4: return GHOSTTY_MOUSE_BUTTON_FOUR;  // wheel up
  case 5: return GHOSTTY_MOUSE_BUTTON_FIVE;  // wheel down
  }
  return GHOSTTY_MOUSE_BUTTON_UNKNOWN;
}

// Encode a mouse event at grid cell (``col``, ``row``) into ``scratch``.
// ``action`` is ``TK_MOUSE_*``; ``button`` a ``MOUSE_*`` value (none, for
// motion with no button held). Uses the tracking mode and wire format the
// program last enabled; returns 0 when it asked for none.
int64_t tk_vt_encode_mouse(void *h, int64_t action, int64_t button,
                           int64_t col, int64_t row, int64_t mods) {
  TkVt *v = h;
  uint16_t cols = 0, rows = 0;
  ghostty_terminal_get(v->term, GHOSTTY_TERMINAL_DATA_COLS, &cols);
  ghostty_terminal_get(v->term, GHOSTTY_TERMINAL_DATA_ROWS, &rows);
  ghostty_mouse_encoder_setopt_from_terminal(v->menc, v->term);
  GhosttyMouseEncoderSize size = {
      .size = sizeof(GhosttyMouseEncoderSize),
      .screen_width = (uint32_t)cols * TK_CELL_W,
      .screen_height = (uint32_t)rows * TK_CELL_H,
      .cell_width = TK_CELL_W,
      .cell_height = TK_CELL_H,
  };
  ghostty_mouse_encoder_setopt(v->menc, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size);
  GhosttyMouseButton gb = ghostty_button(button);
  bool pressed = gb != GHOSTTY_MOUSE_BUTTON_UNKNOWN &&
                 action != TK_MOUSE_RELEASE;
  ghostty_mouse_encoder_setopt(
      v->menc, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &pressed);
  GhosttyMouseAction ga = GHOSTTY_MOUSE_ACTION_PRESS;
  if (action == TK_MOUSE_RELEASE) ga = GHOSTTY_MOUSE_ACTION_RELEASE;
  if (action == TK_MOUSE_MOTION) ga = GHOSTTY_MOUSE_ACTION_MOTION;
  ghostty_mouse_event_set_action(v->mev, ga);
  if (gb == GHOSTTY_MOUSE_BUTTON_UNKNOWN)
    ghostty_mouse_event_clear_button(v->mev);
  else
    ghostty_mouse_event_set_button(v->mev, gb);
  ghostty_mouse_event_set_mods(v->mev, ghostty_mods(mods));
  GhosttyMousePosition pos = {
      .x = (float)(col * TK_CELL_W + TK_CELL_W / 2),
      .y = (float)(row * TK_CELL_H + TK_CELL_H / 2),
  };
  ghostty_mouse_event_set_position(v->mev, pos);
  buf_reserve(&v->scratch, 64);
  size_t n = 0;
  GhosttyResult r = ghostty_mouse_encoder_encode(
      v->menc, v->mev, (char *)v->scratch.p, v->scratch.cap, &n);
  if (r == GHOSTTY_OUT_OF_SPACE) {
    buf_reserve(&v->scratch, n);
    r = ghostty_mouse_encoder_encode(v->menc, v->mev, (char *)v->scratch.p,
                                     v->scratch.cap, &n);
  }
  return encode_result(v, r, n);
}

// Queue a focus-in / focus-out report for the program, if it asked for them
// (DECSET 1004).
void tk_vt_notify_focus(void *h, int64_t focused) {
  TkVt *v = h;
  if (!mode_on(v, GHOSTTY_MODE_FOCUS_EVENT)) return;
  char buf[8];
  size_t n = 0;
  if (ghostty_focus_encode(focused ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST,
                           buf, sizeof(buf), &n) == GHOSTTY_SUCCESS)
    buf_append(&v->reply, buf, n);
}
