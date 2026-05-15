"""Pure-data tests for the vt100-ish terminal emulator.

In its own file (and not folded into ``test_basic.mojo``) because the
test_basic.mojo translation unit is already so large that the Mojo
compiler crashes on macOS when we add another ~150 lines of imports
+ tests on top of it. Splitting per-module keeps each translation
unit small enough to compile reliably.

Run with::

    ./run.sh tests/test_vt_smoke.mojo
"""

from std.collections.list import List
from std.testing import assert_equal, assert_false, assert_true

from turbokod.vt import Vt


def test_vt_plain_text_paints_cells_left_to_right() raises:
    var vt = Vt(20, 5)
    vt.feed_string(String("hello"))
    assert_equal(vt.cell_at(0, 0).glyph, String("h"))
    assert_equal(vt.cell_at(0, 4).glyph, String("o"))
    assert_equal(vt.cur_r, 0)
    assert_equal(vt.cur_c, 5)


def test_vt_cr_and_lf_move_cursor() raises:
    var vt = Vt(20, 5)
    vt.feed_string(String("abc\r\ndef"))
    assert_equal(vt.cell_at(0, 0).glyph, String("a"))
    assert_equal(vt.cell_at(1, 0).glyph, String("d"))
    assert_equal(vt.cur_r, 1)
    assert_equal(vt.cur_c, 3)


def test_vt_cup_moves_cursor_one_indexed() raises:
    # CSI 3;7 H — row 3, column 7, 1-indexed in protocol.
    var vt = Vt(20, 10)
    vt.feed_string(String("\x1b[3;7HX"))
    assert_equal(vt.cur_r, 2)
    # After printing X at (2, 6), cursor advances to col 7.
    assert_equal(vt.cur_c, 7)
    assert_equal(vt.cell_at(2, 6).glyph, String("X"))


def test_vt_sgr_red_then_reset() raises:
    var vt = Vt(20, 5)
    # SGR 31 = red foreground.
    vt.feed_string(String("\x1b[31mR\x1b[0mG"))
    var r_cell = vt.cell_at(0, 0)
    var g_cell = vt.cell_at(0, 1)
    # ANSI 31 → our RED palette index (=1).
    assert_equal(Int(r_cell.attr.fg), Int(UInt8(1)))
    # Reset restores default fg (LIGHT_GRAY = 7).
    assert_equal(Int(g_cell.attr.fg), Int(UInt8(7)))


def test_vt_auto_wrap_delays_until_next_glyph() raises:
    # Filling the last column shouldn't immediately move the cursor —
    # only the next printable byte should trigger the wrap. xterm's
    # delayed-wrap semantics; vim relies on it.
    var vt = Vt(3, 4)
    vt.feed_string(String("abc"))
    # Cursor stays on the last column with wrap_pending latched.
    assert_equal(vt.cur_r, 0)
    assert_equal(vt.cur_c, 2)
    assert_true(vt.wrap_pending)
    vt.feed_string(String("d"))
    # Now we wrapped — 'd' is at (1, 0).
    assert_equal(vt.cell_at(1, 0).glyph, String("d"))
    assert_equal(vt.cur_r, 1)
    assert_equal(vt.cur_c, 1)


def test_vt_alt_screen_swap_and_restore() raises:
    var vt = Vt(10, 4)
    vt.feed_string(String("primary"))
    # Enter alt screen — primary content frozen, alt is blank.
    vt.feed_string(String("\x1b[?1049h"))
    assert_true(vt.using_alt)
    assert_equal(vt.cell_at(0, 0).glyph, String(" "))
    vt.feed_string(String("alt"))
    assert_equal(vt.cell_at(0, 0).glyph, String("a"))
    # Leave alt — primary content restored byte-for-byte.
    vt.feed_string(String("\x1b[?1049l"))
    assert_false(vt.using_alt)
    assert_equal(vt.cell_at(0, 0).glyph, String("p"))


def test_vt_osc_2_sets_title() raises:
    var vt = Vt(10, 4)
    vt.feed_string(String("\x1b]2;my title\x07"))
    assert_equal(vt.title, String("my title"))


def test_vt_erase_in_line_from_cursor() raises:
    var vt = Vt(8, 2)
    vt.feed_string(String("abcdef"))
    # Cursor at col 6 after printing 6 chars. Move back to col 2.
    vt.feed_string(String("\x1b[3G\x1b[K"))
    assert_equal(vt.cell_at(0, 0).glyph, String("a"))
    assert_equal(vt.cell_at(0, 1).glyph, String("b"))
    assert_equal(vt.cell_at(0, 2).glyph, String(" "))
    assert_equal(vt.cell_at(0, 5).glyph, String(" "))


def test_vt_scroll_on_lf_at_bottom() raises:
    # rows=3, scroll region is full screen by default. The fourth LF
    # at the bottom should scroll the first row off the top.
    var vt = Vt(4, 3)
    vt.feed_string(String("A\r\nB\r\nC"))
    assert_equal(vt.cell_at(0, 0).glyph, String("A"))
    assert_equal(vt.cell_at(2, 0).glyph, String("C"))
    vt.feed_string(String("\r\nD"))
    assert_equal(vt.cell_at(0, 0).glyph, String("B"))
    assert_equal(vt.cell_at(2, 0).glyph, String("D"))


def test_vt_utf8_multi_byte_glyph_placed_in_one_cell() raises:
    # ``✻`` is U+273B, 3-byte UTF-8. After feed, the cell at (0,0)
    # should hold the whole codepoint, not just the first byte.
    var vt = Vt(4, 2)
    vt.feed_string(String("✻"))
    assert_equal(vt.cell_at(0, 0).glyph, String("✻"))
    assert_equal(vt.cur_c, 1)


def test_vt_resize_preserves_top_left_content() raises:
    var vt = Vt(10, 4)
    vt.feed_string(String("hello"))
    vt.resize(20, 6)
    assert_equal(vt.cols, 20)
    assert_equal(vt.rows, 6)
    assert_equal(vt.cell_at(0, 0).glyph, String("h"))
    assert_equal(vt.cell_at(0, 4).glyph, String("o"))


def test_vt_cursor_visibility_dec_25() raises:
    var vt = Vt(4, 2)
    assert_true(vt.cursor_visible)
    vt.feed_string(String("\x1b[?25l"))
    assert_false(vt.cursor_visible)
    vt.feed_string(String("\x1b[?25h"))
    assert_true(vt.cursor_visible)


def test_vt_scrollback_captures_rows_off_the_top() raises:
    # rows=3, cols=4. Fill the screen, then scroll once more: the top
    # row should land in scrollback verbatim.
    var vt = Vt(4, 3)
    vt.feed_string(String("A\r\nB\r\nC"))
    assert_equal(len(vt.scrollback), 0)
    vt.feed_string(String("\r\nD"))
    assert_equal(len(vt.scrollback), 1)
    # The captured row is the one that scrolled off: "A" + padding.
    var row0 = vt.scrollback[0].copy()
    assert_equal(row0[0].glyph, String("A"))
    assert_equal(row0[1].glyph, String(" "))
    # The live grid now shows B/C/D.
    assert_equal(vt.cell_at(0, 0).glyph, String("B"))
    assert_equal(vt.cell_at(2, 0).glyph, String("D"))


def test_vt_view_offset_shows_scrollback_above_live() raises:
    var vt = Vt(2, 2)
    vt.feed_string(String("A\r\nB"))
    # Push one more row to fill the scrollback. After: scrollback=["A"],
    # live grid = ["B", "C"].
    vt.feed_string(String("\r\nC"))
    assert_equal(len(vt.scrollback), 1)
    # Live view (offset 0): row 0 = "B", row 1 = "C".
    assert_equal(vt.view_cell_at(0, 0).glyph, String("B"))
    assert_equal(vt.view_cell_at(1, 0).glyph, String("C"))
    # Scrolled back by 1: row 0 = "A", row 1 = "B".
    vt.scroll_view_by(1)
    assert_equal(vt.view_offset, 1)
    assert_equal(vt.view_cell_at(0, 0).glyph, String("A"))
    assert_equal(vt.view_cell_at(1, 0).glyph, String("B"))


def test_vt_scroll_view_clamps_to_scrollback_extents() raises:
    var vt = Vt(2, 2)
    vt.feed_string(String("A\r\nB\r\nC\r\nD"))  # scrollback grows to 2
    assert_equal(len(vt.scrollback), 2)
    vt.scroll_view_by(100)
    assert_equal(vt.view_offset, 2)
    vt.scroll_view_by(-100)
    assert_equal(vt.view_offset, 0)


def test_vt_scrollback_does_not_fill_on_alt_screen() raises:
    var vt = Vt(2, 2)
    vt.feed_string(String("\x1b[?1049h"))  # enter alt
    assert_true(vt.using_alt)
    vt.feed_string(String("A\r\nB\r\nC\r\nD"))
    # Alt-screen scrolls don't push history.
    assert_equal(len(vt.scrollback), 0)


def test_vt_view_offset_pinned_when_new_output_arrives() raises:
    # While the user is scrolled back, new output should keep their
    # viewport pinned to the same absolute scrollback row. Without
    # this, every newline during a scrollback review would drift the
    # view forward and the user couldn't read.
    var vt = Vt(2, 2)
    vt.feed_string(String("A\r\nB\r\nC"))  # scrollback=["A"], grid=["B","C"]
    vt.scroll_view_by(1)
    assert_equal(vt.view_cell_at(0, 0).glyph, String("A"))
    vt.feed_string(String("\r\nD"))  # pushes "B" into scrollback
    # View offset bumped by 1 — still showing "A" at the top.
    assert_equal(vt.view_offset, 2)
    assert_equal(vt.view_cell_at(0, 0).glyph, String("A"))


def test_vt_mouse_tracking_off_by_default() raises:
    var vt = Vt(20, 5)
    assert_false(vt.tracks_mouse())
    assert_equal(vt.encode_mouse(0, 5, 3, False, False, False, False, False),
                 String(""))


def test_vt_mouse_sgr_press_release_encoding() raises:
    # Enable 1000 + 1006 (standard combo).
    var vt = Vt(80, 24)
    vt.feed_string(String("\x1b[?1000h\x1b[?1006h"))
    assert_true(vt.tracks_mouse())
    assert_true(vt.mouse_sgr)
    # Left-click at grid (col=10, row=4). SGR is 1-based.
    var press = vt.encode_mouse(0, 10, 4, False, False, False, False, False)
    assert_equal(press, String("\x1b[<0;11;5M"))
    var release = vt.encode_mouse(0, 10, 4, False, True, False, False, False)
    assert_equal(release, String("\x1b[<0;11;5m"))


def test_vt_mouse_modifier_bits_encoded() raises:
    var vt = Vt(80, 24)
    vt.feed_string(String("\x1b[?1000h\x1b[?1006h"))
    # Ctrl-shift-left at (0, 0). Modifiers: shift=4, ctrl=16 → +20.
    var press = vt.encode_mouse(0, 0, 0, False, False, True, False, True)
    assert_equal(press, String("\x1b[<20;1;1M"))


def test_vt_mouse_wheel_codes() raises:
    var vt = Vt(80, 24)
    vt.feed_string(String("\x1b[?1000h\x1b[?1006h"))
    var up = vt.encode_mouse(4, 5, 3, False, False, False, False, False)
    assert_equal(up, String("\x1b[<64;6;4M"))
    var down = vt.encode_mouse(5, 5, 3, False, False, False, False, False)
    assert_equal(down, String("\x1b[<65;6;4M"))


def test_vt_mouse_motion_bit_set_on_drag() raises:
    var vt = Vt(80, 24)
    vt.feed_string(String("\x1b[?1002h\x1b[?1006h"))
    # Drag with left held: motion bit (+32) on top of button 0.
    var drag = vt.encode_mouse(0, 10, 4, True, False, False, False, False)
    assert_equal(drag, String("\x1b[<32;11;5M"))


def test_vt_save_restore_cursor_via_decsc() raises:
    var vt = Vt(20, 5)
    vt.feed_string(String("\x1b[3;5H"))  # move to (2, 4)
    vt.feed_string(String("\x1b7"))      # DECSC — save
    vt.feed_string(String("\x1b[1;1H"))  # move to (0, 0)
    vt.feed_string(String("\x1b8"))      # DECRC — restore
    assert_equal(vt.cur_r, 2)
    assert_equal(vt.cur_c, 4)


def main() raises:
    test_vt_plain_text_paints_cells_left_to_right()
    test_vt_cr_and_lf_move_cursor()
    test_vt_cup_moves_cursor_one_indexed()
    test_vt_sgr_red_then_reset()
    test_vt_auto_wrap_delays_until_next_glyph()
    test_vt_alt_screen_swap_and_restore()
    test_vt_osc_2_sets_title()
    test_vt_erase_in_line_from_cursor()
    test_vt_scroll_on_lf_at_bottom()
    test_vt_utf8_multi_byte_glyph_placed_in_one_cell()
    test_vt_resize_preserves_top_left_content()
    test_vt_cursor_visibility_dec_25()
    test_vt_scrollback_captures_rows_off_the_top()
    test_vt_view_offset_shows_scrollback_above_live()
    test_vt_scroll_view_clamps_to_scrollback_extents()
    test_vt_scrollback_does_not_fill_on_alt_screen()
    test_vt_view_offset_pinned_when_new_output_arrives()
    test_vt_mouse_tracking_off_by_default()
    test_vt_mouse_sgr_press_release_encoding()
    test_vt_mouse_modifier_bits_encoded()
    test_vt_mouse_wheel_codes()
    test_vt_mouse_motion_bit_set_on_drag()
    test_vt_save_restore_cursor_via_decsc()
    print("all vt tests passed")
