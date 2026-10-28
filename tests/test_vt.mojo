"""Tests for the terminal emulator (``vt.mojo`` over libghostty-vt).

Ghostty does the parsing; what these pin is our side of it: the cell /
color / width translation into ``Cell`` and ``Attr``, the state the panes
read, the bytes that go back to the child (replies, key and mouse
encodings — the encoders take *our* key codes, so a drift between
``events.mojo`` and ``tk_vt.c`` shows up here), and handle ownership.

Run with::

    ./run.sh tests/test_vt.mojo
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from turbokod.colors import (
    BG_TRUECOLOR, FG_TRUECOLOR, RED, STYLE_BOLD, STYLE_REVERSE,
    STYLE_UNDERLINE, STYLE_UNDERLINE_CURLY, _rgb_to_256,
)
from turbokod.events import (
    KEY_BACKSPACE, KEY_DELETE, KEY_ENTER, KEY_ESC, KEY_F1, KEY_F5, KEY_F12,
    KEY_LEFT, KEY_PAGEUP, KEY_RIGHT, KEY_TAB, KEY_UP, MOD_ALT, MOD_CTRL,
    MOD_META, MOD_NONE, MOD_SHIFT, MOUSE_BUTTON_LEFT, MOUSE_WHEEL_DOWN,
    MOUSE_WHEEL_UP,
)
from turbokod.vt import (
    MOUSE_MOTION, MOUSE_PRESS, MOUSE_RELEASE, Vt, vt_live_count, xterm_256_rgb,
)

from support import setup_test_env


# --- screen ---------------------------------------------------------------


def test_vt_plain_text_paints_cells_left_to_right() raises:
    var vt = Vt(20, 5)
    vt.feed_string(String("hello"))
    assert_equal(vt.cell_at(0, 0).glyph, String("h"))
    assert_equal(vt.cell_at(0, 4).glyph, String("o"))
    assert_equal(vt.cursor_row(), 0)
    assert_equal(vt.cursor_col(), 5)


def test_vt_cr_and_lf_move_cursor() raises:
    var vt = Vt(20, 5)
    vt.feed_string(String("abc\r\ndef"))
    assert_equal(vt.cell_at(0, 0).glyph, String("a"))
    assert_equal(vt.cell_at(1, 0).glyph, String("d"))
    assert_equal(vt.cursor_row(), 1)
    assert_equal(vt.cursor_col(), 3)


def test_vt_cup_moves_cursor_one_indexed() raises:
    # CSI 3;7 H — row 3, column 7, 1-indexed in protocol.
    var vt = Vt(20, 10)
    vt.feed_string(String("\x1b[3;7HX"))
    assert_equal(vt.cursor_row(), 2)
    # After printing X at (2, 6), cursor advances to col 7.
    assert_equal(vt.cursor_col(), 7)
    assert_equal(vt.cell_at(2, 6).glyph, String("X"))


def test_vt_auto_wrap_delays_until_next_glyph() raises:
    # Filling the last column shouldn't immediately move the cursor —
    # only the next printable byte should trigger the wrap. xterm's
    # delayed-wrap semantics; vim relies on it.
    var vt = Vt(3, 4)
    vt.feed_string(String("abc"))
    assert_equal(vt.cursor_row(), 0)
    assert_equal(vt.cursor_col(), 2)
    assert_true(vt.wrap_pending())
    vt.feed_string(String("d"))
    assert_equal(vt.cell_at(1, 0).glyph, String("d"))
    assert_equal(vt.cursor_row(), 1)
    assert_equal(vt.cursor_col(), 1)


def test_vt_alt_screen_swap_and_restore() raises:
    var vt = Vt(10, 4)
    vt.feed_string(String("primary"))
    vt.feed_string(String("\x1b[?1049h"))
    assert_true(vt.using_alt())
    assert_equal(vt.cell_at(0, 0).glyph, String(" "))
    # 1049 keeps the cursor where it was (xterm); programs home it.
    vt.feed_string(String("\x1b[Halt"))
    assert_equal(vt.cell_at(0, 0).glyph, String("a"))
    vt.feed_string(String("\x1b[?1049l"))
    assert_false(vt.using_alt())
    assert_equal(vt.cell_at(0, 0).glyph, String("p"))


def test_vt_osc_2_sets_title() raises:
    var vt = Vt(10, 4)
    vt.feed_string(String("\x1b]2;my title\x07"))
    assert_equal(vt.title(), String("my title"))


def test_vt_erase_in_line_from_cursor() raises:
    var vt = Vt(8, 2)
    vt.feed_string(String("abcdef"))
    vt.feed_string(String("\x1b[3G\x1b[K"))
    assert_equal(vt.cell_at(0, 0).glyph, String("a"))
    assert_equal(vt.cell_at(0, 1).glyph, String("b"))
    assert_equal(vt.cell_at(0, 2).glyph, String(" "))
    assert_equal(vt.cell_at(0, 5).glyph, String(" "))


def test_vt_scroll_on_lf_at_bottom() raises:
    var vt = Vt(4, 3)
    vt.feed_string(String("A\r\nB\r\nC"))
    assert_equal(vt.cell_at(0, 0).glyph, String("A"))
    assert_equal(vt.cell_at(2, 0).glyph, String("C"))
    vt.feed_string(String("\r\nD"))
    assert_equal(vt.cell_at(0, 0).glyph, String("B"))
    assert_equal(vt.cell_at(2, 0).glyph, String("D"))


def test_vt_utf8_multi_byte_glyph_placed_in_one_cell() raises:
    # ``✻`` is U+273B, 3-byte UTF-8 and one cell wide.
    var vt = Vt(4, 2)
    vt.feed_string(String("✻"))
    assert_equal(vt.cell_at(0, 0).glyph, String("✻"))
    assert_equal(vt.cell_at(0, 0).width, 1)
    assert_equal(vt.cursor_col(), 1)


def test_vt_wide_glyph_is_a_two_cell_glyph_plus_continuation() raises:
    # CJK is two cells in a terminal. The grid hands it over in the same
    # shape ``Canvas.put_text`` produces: the glyph with width 2, then an
    # empty width-0 continuation the painter skips.
    var vt = Vt(10, 2)
    vt.feed_string(String("漢x"))
    var head = vt.cell_at(0, 0)
    assert_equal(head.glyph, String("漢"))
    assert_equal(head.width, 2)
    var tail = vt.cell_at(0, 1)
    assert_equal(tail.glyph, String(""))
    assert_equal(tail.width, 0)
    assert_equal(vt.cell_at(0, 2).glyph, String("x"))
    assert_equal(vt.cursor_col(), 3)
    assert_equal(vt.row_text(0), String("漢x"))


def test_vt_combining_mark_joins_its_base_cell() raises:
    # "e" + U+0301 is one grapheme: one cell holding both codepoints.
    var vt = Vt(10, 2)
    vt.feed_string(String("éz"))
    assert_equal(vt.cell_at(0, 0).glyph, String("é"))
    assert_equal(vt.cell_at(0, 1).glyph, String("z"))


def test_vt_resize_reflows_wrapped_lines() raises:
    # Shrinking wraps a long line; growing back unwraps it — nothing is
    # truncated, which is what lets a pane resize after its child exited.
    var vt = Vt(10, 4)
    vt.feed_string(String("abcdefgh"))
    vt.resize(4, 4)
    assert_equal(vt.cols(), 4)
    assert_equal(vt.row_text(0), String("abcd"))
    assert_equal(vt.row_text(1), String("efgh"))
    vt.resize(10, 4)
    assert_equal(vt.row_text(0), String("abcdefgh"))


def test_vt_resize_preserves_top_left_content() raises:
    var vt = Vt(10, 4)
    vt.feed_string(String("hello"))
    vt.resize(20, 6)
    assert_equal(vt.cols(), 20)
    assert_equal(vt.rows(), 6)
    assert_equal(vt.cell_at(0, 0).glyph, String("h"))
    assert_equal(vt.cell_at(0, 4).glyph, String("o"))


def test_vt_cursor_visibility_dec_25() raises:
    var vt = Vt(4, 2)
    assert_true(vt.cursor_visible())
    vt.feed_string(String("\x1b[?25l"))
    assert_false(vt.cursor_visible())
    vt.feed_string(String("\x1b[?25h"))
    assert_true(vt.cursor_visible())


def test_vt_save_restore_cursor_via_decsc() raises:
    var vt = Vt(20, 5)
    vt.feed_string(String("\x1b[3;5H"))  # move to (2, 4)
    vt.feed_string(String("\x1b7"))      # DECSC — save
    vt.feed_string(String("\x1b[1;1H"))  # move to (0, 0)
    vt.feed_string(String("\x1b8"))      # DECRC — restore
    assert_equal(vt.cursor_row(), 2)
    assert_equal(vt.cursor_col(), 4)


def test_vt_reset_wipes_screen_scrollback_and_title() raises:
    var vt = Vt(4, 2)
    vt.feed_string(String("\x1b]2;t\x07A\r\nB\r\nC"))
    assert_equal(vt.scrollback_rows(), 1)
    vt.reset()
    assert_equal(vt.cell_at(0, 0).glyph, String(" "))
    assert_equal(vt.scrollback_rows(), 0)
    assert_equal(vt.title(), String(""))
    assert_equal(vt.cols(), 4)


# --- colors and styles ----------------------------------------------------


def test_vt_sgr_red_then_reset() raises:
    var vt = Vt(20, 5)
    vt.feed_string(String("\x1b[31mR\x1b[0mG"))
    # ANSI 31 → palette index 1, so it follows the theme.
    assert_equal(Int(vt.cell_at(0, 0).attr.fg), 1)
    # Reset restores the default fg (LIGHT_GRAY = 7).
    assert_equal(Int(vt.cell_at(0, 1).attr.fg), 7)


def test_vt_bright_and_background_colors_stay_indices() raises:
    var vt = Vt(20, 5)
    vt.feed_string(String("\x1b[91;44mX"))
    var a = vt.cell_at(0, 0).attr
    assert_equal(Int(a.fg), 9)
    assert_equal(Int(a.bg), 4)
    assert_equal(Int(a.color_mode), 0)


def test_vt_256_color_above_15_resolves_to_xterm_rgb() raises:
    # Index 18 is a cube blue to the program, but in *our* palette 18 is
    # the theme's keyword color. It must arrive as the xterm RGB.
    var vt = Vt(20, 5)
    vt.feed_string(String("\x1b[38;5;18mX"))
    var a = vt.cell_at(0, 0).attr
    assert_true((a.color_mode & FG_TRUECOLOR) != 0)
    assert_equal(a.fg_rgb, UInt32(0x000087))
    assert_equal(xterm_256_rgb(232), UInt32(0x080808))
    assert_equal(xterm_256_rgb(231), UInt32(0xFFFFFF))


def test_vt_truecolor_passes_through() raises:
    var vt = Vt(20, 5)
    vt.feed_string(String("\x1b[38;2;255;128;0;48;2;1;2;3mX"))
    var a = vt.cell_at(0, 0).attr
    assert_true((a.color_mode & FG_TRUECOLOR) != 0)
    assert_true((a.color_mode & BG_TRUECOLOR) != 0)
    assert_equal(a.fg_rgb, UInt32(0xFF8000))
    assert_equal(a.bg_rgb, UInt32(0x010203))


def test_vt_styles_map_to_attr_bits() raises:
    var vt = Vt(20, 5)
    vt.feed_string(String("\x1b[1;7mA\x1b[0;4:3mB"))
    var a = vt.cell_at(0, 0).attr
    assert_true((a.style & STYLE_BOLD) != 0)
    assert_true((a.style & STYLE_REVERSE) != 0)
    var b = vt.cell_at(0, 1).attr
    assert_true((b.style & STYLE_UNDERLINE) != 0)
    assert_true((b.style & STYLE_UNDERLINE_CURLY) != 0)


def test_vt_erase_with_background_keeps_the_color() raises:
    # An erase under a set background fills with that background: what
    # full-screen programs (vim's colorscheme, htop) paint their panes with.
    var vt = Vt(6, 2)
    vt.feed_string(String("\x1b[44m\x1b[2J"))
    assert_equal(Int(vt.cell_at(1, 5).attr.bg), 4)


# --- scrollback -----------------------------------------------------------


def test_vt_scrollback_captures_rows_off_the_top() raises:
    var vt = Vt(4, 3)
    vt.feed_string(String("A\r\nB\r\nC"))
    assert_equal(vt.scrollback_rows(), 0)
    vt.feed_string(String("\r\nD"))
    assert_equal(vt.scrollback_rows(), 1)
    # The live grid now shows B/C/D; scrolled back, "A" is on top.
    assert_equal(vt.cell_at(0, 0).glyph, String("B"))
    assert_equal(vt.cell_at(2, 0).glyph, String("D"))
    vt.scroll_view_by(1)
    assert_equal(vt.view_cell_at(0, 0).glyph, String("A"))


def test_vt_view_offset_shows_scrollback_above_live() raises:
    var vt = Vt(2, 2)
    vt.feed_string(String("A\r\nB\r\nC"))
    assert_equal(vt.view_cell_at(0, 0).glyph, String("B"))
    assert_equal(vt.view_cell_at(1, 0).glyph, String("C"))
    vt.scroll_view_by(1)
    assert_equal(vt.view_offset(), 1)
    assert_equal(vt.view_cell_at(0, 0).glyph, String("A"))
    assert_equal(vt.view_cell_at(1, 0).glyph, String("B"))
    # ``cell_at`` / ``tail_rows`` read the live screen regardless.
    assert_equal(vt.cell_at(0, 0).glyph, String("B"))
    var tail = vt.tail_rows(1)
    assert_equal(tail[0], String("C"))


def test_vt_scroll_view_clamps_to_scrollback_extents() raises:
    var vt = Vt(2, 2)
    vt.feed_string(String("A\r\nB\r\nC\r\nD"))
    assert_equal(vt.scrollback_rows(), 2)
    vt.scroll_view_by(100)
    assert_equal(vt.view_offset(), 2)
    vt.scroll_view_by(-100)
    assert_equal(vt.view_offset(), 0)
    vt.scroll_view_by(1)
    vt.reset_view()
    assert_equal(vt.view_offset(), 0)


def test_vt_scrollback_does_not_fill_on_alt_screen() raises:
    var vt = Vt(2, 2)
    vt.feed_string(String("\x1b[?1049h"))
    assert_true(vt.using_alt())
    vt.feed_string(String("A\r\nB\r\nC\r\nD"))
    assert_equal(vt.scrollback_rows(), 0)


def test_vt_view_stays_on_its_rows_when_new_output_arrives() raises:
    # While the user reads history, new output must not drift the view.
    var vt = Vt(2, 2)
    vt.feed_string(String("A\r\nB\r\nC"))
    vt.scroll_view_by(1)
    assert_equal(vt.view_cell_at(0, 0).glyph, String("A"))
    vt.feed_string(String("\r\nD"))
    assert_equal(vt.view_offset(), 2)
    assert_equal(vt.view_cell_at(0, 0).glyph, String("A"))


# --- replies to the child -------------------------------------------------


def test_vt_answers_cursor_position_report() raises:
    var vt = Vt(10, 4)
    vt.feed_string(String("ab\x1b[6n"))
    assert_equal(vt.take_reply(), String("\x1b[1;3R"))


def test_vt_osc_52_clipboard_write() raises:
    var vt = Vt(10, 4)
    vt.feed_string(String("\x1b]52;c;aGVsbG8=\x07"))
    assert_equal(vt.take_clipboard(), String("hello"))
    assert_equal(vt.take_clipboard(), String(""))


def test_vt_focus_reports_only_when_enabled() raises:
    var vt = Vt(10, 4)
    vt.notify_focus_change(True)
    assert_equal(vt.take_reply(), String(""))
    vt.feed_string(String("\x1b[?1004h"))
    assert_true(vt.focus_events())
    vt.notify_focus_change(True)
    vt.notify_focus_change(False)
    assert_equal(vt.take_reply(), String("\x1b[I\x1b[O"))


def test_vt_bracketed_paste_mode() raises:
    var vt = Vt(10, 4)
    assert_false(vt.bracketed_paste())
    vt.feed_string(String("\x1b[?2004h"))
    assert_true(vt.bracketed_paste())


def test_vt_da1_reply_on_csi_c() raises:
    """``ESC[c`` (DA1) must enqueue a reply on the Vt's outbound
    queue. Real-world: starship / oh-my-zsh probe with this; without
    a reply the prompt stalls a beat on every redraw."""
    var vt = Vt(80, 24)
    vt.feed_string(String("\x1b[c"))
    var reply = vt.take_reply()
    # VT220-level with ANSI color — what the Ghostty app reports.
    assert_equal(reply, String("\x1b[?62;22c"))
    # Drained — second call is empty.
    assert_equal(vt.take_reply(), String(""))


def test_vt_dsr_6_reply_uses_1_based_cursor() raises:
    """``ESC[6n`` (DSR cursor position) must reply with 1-based
    coordinates. The cursor at (cur_r=2, cur_c=3) reports ``3;4R``."""
    var vt = Vt(80, 24)
    # Move cursor to row 3, col 4 (1-based via CUP).
    vt.feed_string(String("\x1b[3;4H"))
    vt.feed_string(String("\x1b[6n"))
    assert_equal(vt.take_reply(), String("\x1b[3;4R"))


def test_vt_decset_1_app_cursor_keys() raises:
    """DECCKM (``ESC[?1h``) flips arrow encoding from CSI to SS3 in
    the pane. We just verify the Vt tracks the flag."""
    var vt = Vt(80, 24)
    assert_false(vt.app_cursor_keys())
    vt.feed_string(String("\x1b[?1h"))
    assert_true(vt.app_cursor_keys())
    vt.feed_string(String("\x1b[?1l"))
    assert_false(vt.app_cursor_keys())


def test_vt_truecolor_fg_keeps_rgb_and_folds_index() raises:
    """``ESC[38;2;r;g;b m`` must preserve the exact 24-bit RGB on the
    cell's attr (``FG_TRUECOLOR`` set, ``fg_rgb`` = the packed value) so
    truecolor terminals / the native app render it faithfully — while
    still baking the nearest-256 fold into ``fg`` so 256-color terminals
    degrade without extra logic."""
    var vt = Vt(80, 24)
    vt.feed_string(String("\x1b[38;2;10;20;30mX"))
    var cell = vt.cell_at(0, 0)
    assert_equal(cell.glyph, String("X"))
    assert_true((cell.attr.color_mode & FG_TRUECOLOR) != 0)
    assert_equal(Int(cell.attr.fg_rgb), 0x0A141E)
    # Degrade path: the palette index is the rgb→256 fold, not raw RGB.
    assert_equal(cell.attr.fg, _rgb_to_256(10, 20, 30))
    # A subsequent indexed color clears the truecolor flag (no stale RGB).
    vt.feed_string(String("\x1b[31mY"))
    var cell2 = vt.cell_at(0, 1)
    assert_true((cell2.attr.color_mode & FG_TRUECOLOR) == 0)
    assert_equal(Int(cell2.attr.fg_rgb), 0)
    assert_equal(cell2.attr.fg, RED)


def test_vt_osc_52_query_does_not_leak_clipboard() raises:
    """A query (``?`` in place of base64) must not produce a
    clipboard payload — leaking host clipboard contents to whatever
    the child is would be a security regression."""
    var vt = Vt(80, 24)
    vt.feed_string(String("\x1b]52;c;?\x07"))
    assert_equal(vt.take_clipboard(), String(""))


def test_vt_ris_clears_mode_flags() raises:
    """``ESC c`` (RIS) is a hard reset. Mouse tracking, bracketed
    paste, focus events, app-cursor-keys all clear — otherwise a
    fresh shell coming up after vim crashed inherits the dead
    program's modes and routes events to the wrong handler."""
    var vt = Vt(80, 24)
    vt.feed_string(String("\x1b[?1000h\x1b[?2004h\x1b[?1004h\x1b[?1h"))
    assert_true(vt.tracks_mouse())
    assert_true(vt.bracketed_paste())
    assert_true(vt.focus_events())
    assert_true(vt.app_cursor_keys())
    vt.feed_string(String("\x1bc"))
    assert_false(vt.tracks_mouse())
    assert_false(vt.bracketed_paste())
    assert_false(vt.focus_events())
    assert_false(vt.app_cursor_keys())


# --- key encoding ---------------------------------------------------------


def test_vt_encodes_named_keys() raises:
    var vt = Vt(10, 4)
    assert_equal(vt.encode_key(KEY_ENTER, MOD_NONE), String("\r"))
    assert_equal(vt.encode_key(KEY_TAB, MOD_NONE), String("\t"))
    assert_equal(vt.encode_key(KEY_TAB, MOD_SHIFT), String("\x1b[Z"))
    assert_equal(vt.encode_key(KEY_BACKSPACE, MOD_NONE), String("\x7f"))
    assert_equal(vt.encode_key(KEY_ESC, MOD_NONE), String("\x1b"))
    assert_equal(vt.encode_key(KEY_UP, MOD_NONE), String("\x1b[A"))
    assert_equal(vt.encode_key(KEY_PAGEUP, MOD_NONE), String("\x1b[5~"))
    assert_equal(vt.encode_key(KEY_DELETE, MOD_NONE), String("\x1b[3~"))
    assert_equal(vt.encode_key(KEY_F1, MOD_NONE), String("\x1bOP"))
    assert_equal(vt.encode_key(KEY_F5, MOD_NONE), String("\x1b[15~"))
    assert_equal(vt.encode_key(KEY_F12, MOD_NONE), String("\x1b[24~"))


def test_vt_encodes_modified_keys() raises:
    var vt = Vt(10, 4)
    assert_equal(vt.encode_key(KEY_RIGHT, MOD_CTRL), String("\x1b[1;5C"))
    assert_equal(vt.encode_key(KEY_LEFT, MOD_ALT), String("\x1b[1;3D"))
    assert_equal(vt.encode_key(UInt32(ord("c")), MOD_CTRL), String("\x03"))
    assert_equal(vt.encode_key(UInt32(ord("b")), MOD_ALT), String("\x1bb"))


def test_vt_encodes_text() raises:
    var vt = Vt(10, 4)
    assert_equal(vt.encode_key(UInt32(ord("a")), MOD_NONE), String("a"))
    assert_equal(vt.encode_key(UInt32(ord("A")), MOD_SHIFT), String("A"))
    assert_equal(vt.encode_key(UInt32(ord("!")), MOD_SHIFT), String("!"))
    assert_equal(vt.encode_key(UInt32(0xE9), MOD_NONE), String("é"))
    # Cmd belongs to the host; a Cmd chord that reaches the pane sends the
    # bare key, as the hand-written encoder did.
    assert_equal(vt.encode_key(UInt32(ord("k")), MOD_META), String("k"))


def test_vt_cursor_keys_follow_decckm() raises:
    var vt = Vt(10, 4)
    vt.feed_string(String("\x1b[?1h"))
    assert_true(vt.app_cursor_keys())
    assert_equal(vt.encode_key(KEY_UP, MOD_NONE), String("\x1bOA"))


def test_vt_kitty_keyboard_protocol_when_the_program_asks() raises:
    # The program pushes kitty flags (CSI > 1 u: disambiguate); Escape is
    # then reported as a CSI u sequence instead of a bare ESC.
    var vt = Vt(10, 4)
    vt.feed_string(String("\x1b[>1u"))
    assert_equal(vt.encode_key(KEY_ESC, MOD_NONE), String("\x1b[27u"))


# --- mouse encoding -------------------------------------------------------


def test_vt_mouse_tracking_off_by_default() raises:
    var vt = Vt(20, 5)
    assert_false(vt.tracks_mouse())
    assert_equal(
        vt.encode_mouse(MOUSE_PRESS, MOUSE_BUTTON_LEFT, 5, 3, MOD_NONE),
        String(""),
    )


def test_vt_mouse_sgr_press_release_encoding() raises:
    var vt = Vt(80, 24)
    vt.feed_string(String("\x1b[?1000h\x1b[?1006h"))
    assert_true(vt.tracks_mouse())
    assert_true(vt.mouse_sgr())
    # Left-click at grid (col=10, row=4). SGR is 1-based.
    assert_equal(
        vt.encode_mouse(MOUSE_PRESS, MOUSE_BUTTON_LEFT, 10, 4, MOD_NONE),
        String("\x1b[<0;11;5M"),
    )
    assert_equal(
        vt.encode_mouse(MOUSE_RELEASE, MOUSE_BUTTON_LEFT, 10, 4, MOD_NONE),
        String("\x1b[<0;11;5m"),
    )


def test_vt_mouse_modifier_bits_encoded() raises:
    var vt = Vt(80, 24)
    vt.feed_string(String("\x1b[?1000h\x1b[?1006h"))
    # Ctrl-shift-left at (0, 0). Modifiers: shift=4, ctrl=16 → +20.
    assert_equal(
        vt.encode_mouse(
            MOUSE_PRESS, MOUSE_BUTTON_LEFT, 0, 0, MOD_SHIFT | MOD_CTRL,
        ),
        String("\x1b[<20;1;1M"),
    )


def test_vt_mouse_wheel_codes() raises:
    var vt = Vt(80, 24)
    vt.feed_string(String("\x1b[?1000h\x1b[?1006h"))
    assert_equal(
        vt.encode_mouse(MOUSE_PRESS, MOUSE_WHEEL_UP, 5, 3, MOD_NONE),
        String("\x1b[<64;6;4M"),
    )
    assert_equal(
        vt.encode_mouse(MOUSE_PRESS, MOUSE_WHEEL_DOWN, 5, 3, MOD_NONE),
        String("\x1b[<65;6;4M"),
    )


def test_vt_mouse_motion_bit_set_on_drag() raises:
    var vt = Vt(80, 24)
    vt.feed_string(String("\x1b[?1002h\x1b[?1006h"))
    assert_true(vt.mouse_button_motion())
    # Drag with left held: motion bit (+32) on top of button 0.
    assert_equal(
        vt.encode_mouse(MOUSE_MOTION, MOUSE_BUTTON_LEFT, 10, 4, MOD_NONE),
        String("\x1b[<32;11;5M"),
    )


# --- ownership ------------------------------------------------------------


def test_vt_release_frees_once_through_any_copy() raises:
    var before = vt_live_count()
    var vt = Vt(10, 4)
    assert_equal(vt_live_count(), before + 1)
    var alias = vt
    vt.release()
    assert_equal(vt_live_count(), before)
    # A second release through an aliasing copy finds nothing to free.
    alias.release()
    assert_equal(vt_live_count(), before)
    # A released Vt reads as empty instead of touching freed memory.
    vt.feed_string(String("x"))
    assert_equal(vt.cols(), 0)
    assert_equal(vt.row_text(0), String(""))


def main() raises:
    setup_test_env()
    TestSuite.discover_tests[__functions_in_module()]().run()
