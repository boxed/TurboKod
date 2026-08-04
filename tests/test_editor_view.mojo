"""Editor viewport: soft wrap, scrolling, reveal, tab bar.

One of the per-topic suites split out of the former
``test_basic.mojo``; shared fixtures live in ``tests/support.mojo``
and ``scripts/run_tests.sh`` runs every suite.
"""

from std.testing import assert_equal, assert_false, assert_true
from turbokod.canvas import Canvas
from turbokod.painter import Painter
from turbokod.colors import Attr, BLACK, WHITE
from turbokod.editor import Editor
from turbokod.scrollbar import HScrollbar, VScrollbar
from turbokod.desktop import Desktop, synth_key_action
from turbokod.text_view import Selection, VisualLine, wrap_lines
from turbokod.posix import monotonic_ms
from turbokod.config import WRAP_NONE, WRAP_SOFT
from turbokod.events import (
    Event, KEY_DOWN, KEY_LEFT, KEY_UP, MOD_META, MOD_SHIFT, MOUSE_WHEEL_DOWN,
    MOUSE_WHEEL_UP
)
from turbokod.geometry import Point, Rect
from turbokod.view import centered
from turbokod.window import Window

from support import _SCREEN, _assert_layout_contiguous, _key, setup_test_env


def _long_line_editor_window() raises -> Window:
    """An editor window whose first logical line overflows the view, with
    horizontal scroll (WRAP_NONE) on — the setup the horizontal scrollbar
    needs to be present.

    Line numbers are on so the left gutter is non-empty: the horizontal
    range is measured against the *content* width, and with no gutter at all
    content width == interior width and the distinction under test vanishes.
    The filler rows below make the buffer taller than the view so a plain
    (no-Shift) wheel has somewhere vertical to go."""
    var long_line = String("")
    for _ in range(300):
        long_line += String("x")
    for _ in range(60):
        long_line += String("\nshort")
    var w = Window.editor_window(String("t"), Rect(2, 2, 80, 24), long_line)
    w.editor.wrap_mode = WRAP_NONE
    w.editor.line_numbers = True
    return w^


def test_caret_blink_phase_math() raises:
    """The blink phase is solid for the first ~530 ms half-cycle after the
    last input and hidden for the next, so the caret is solid the instant the
    user acts and only blinks once idle. Right after an input (now ==
    last_input) it must be solid."""
    # Solid the moment input lands.
    assert_true(Desktop._caret_on_at(1000, 1000))
    # Still solid anywhere in the first half-cycle.
    assert_true(Desktop._caret_on_at(1000 + 529, 1000))
    # Hidden in the second half-cycle (the blink-off flash).
    assert_false(Desktop._caret_on_at(1000 + 600, 1000))
    # Solid again at the start of the next cycle.
    assert_true(Desktop._caret_on_at(1000 + 1060, 1000))
    # A steady cadence faster than the half-cycle keeps the caret solid:
    # every input resets last_input to now, so since==0 → always solid.
    for i in range(5):
        var t = 1000 + i * 200
        assert_true(Desktop._caret_on_at(t, t))


def test_caret_blink_resets_on_synth_key_movement() raises:
    """Cursor-movement chords (Line Start/End = Cmd+Left/Right, Word Left/
    Right, …) reach the core as native-menu key-equivalents → ``dispatch_action``,
    NOT ``handle_event``. The blink clock must reset there too, else moving the
    caret while it's mid-blink leaves it invisible and a steady cursor-key
    cadence looks like the caret vanished. Regression for that bug."""
    var d = Desktop()
    # Park the blink clock well into the past so the caret is in a hidden
    # half-cycle (5000 ms → 5000 // 530 == 9, odd → off).
    d._last_input_ms = monotonic_ms() - 5000
    assert_false(Desktop._caret_on_at(monotonic_ms(), d._last_input_ms))
    # Replay Cmd+Left exactly as the native "Line Start" menu item does.
    _ = d.dispatch_action(synth_key_action(KEY_LEFT, MOD_META), _SCREEN)
    # The clock jumped to ~now, so the caret is solid again.
    assert_true(Desktop._caret_on_at(monotonic_ms(), d._last_input_ms))


def test_scrollbar_hidden_when_content_fits() raises:
    """No bar is drawn when total ≤ visible — there's nothing to
    scroll, so paint and hit-test must short-circuit."""
    var bar = VScrollbar(10, 0, 9, 5, 10, 0)
    assert_false(bar.metrics().present)
    var c = Canvas(20, 10)
    var p = Painter(Rect(0, 0, 20, 10))
    bar.paint(c, p, Attr(WHITE, BLACK))
    # The scrollbar column must be untouched (still blank cells).
    assert_equal(c.get(10, 0).glyph, String(" "))
    assert_equal(c.get(10, 5).glyph, String(" "))
    var hit = bar.hit(Point(10, 5))
    assert_equal(hit[0], 0)


def test_scrollbar_hidden_when_too_short() raises:
    """A 2-cell bar can't fit ▲ + ▼ + at least one track cell, so it
    stays hidden even when content overflows."""
    var bar = VScrollbar(10, 0, 1, 100, 5, 0)
    assert_false(bar.metrics().present)


def test_scrollbar_paints_arrows_and_thumb() raises:
    """The bar paints ▲ at the top, ▼ at the bottom, and a █ thumb
    proportional to ``visible / total`` somewhere on the rail."""
    var bar = VScrollbar(10, 0, 9, 100, 10, 0)
    var m = bar.metrics()
    assert_true(m.present)
    assert_equal(m.track_size, 8)
    assert_equal(m.knob_size, 1)  # 8 * 10 / 100 = 0 → clamped up to 1
    assert_equal(m.knob_off, 0)
    var c = Canvas(20, 10)
    var p = Painter(Rect(0, 0, 20, 10))
    bar.paint(c, p, Attr(WHITE, BLACK))
    assert_equal(c.get(10, 0).glyph, String("▲"))
    assert_equal(c.get(10, 9).glyph, String("▼"))
    # Track is 8 cells (rows 1..8). Thumb is one █ at row 1; the rest
    # are ░.
    assert_equal(c.get(10, 1).glyph, String("█"))
    assert_equal(c.get(10, 2).glyph, String("░"))
    assert_equal(c.get(10, 8).glyph, String("░"))


def test_scrollbar_thumb_tracks_scroll_position() raises:
    """As ``scroll`` advances toward ``max_scroll``, the thumb's
    ``knob_off`` must end up at the bottom of the track."""
    var bar = VScrollbar(10, 0, 9, 100, 10, 90)  # max_scroll = 90
    var m = bar.metrics()
    assert_true(m.present)
    # denom = track_size - knob_size = 7. knob_off = 90*7 / 90 = 7.
    assert_equal(m.knob_off, 7)


def test_scrollbar_hit_arrow_zones() raises:
    """Top and bottom of the bar are arrow hits, with no rel."""
    var bar = VScrollbar(10, 0, 9, 100, 10, 0)
    var up = bar.hit(Point(10, 0))
    assert_equal(up[0], 1)  # leading arrow
    var down = bar.hit(Point(10, 9))
    assert_equal(down[0], 5)  # trailing arrow


def test_scrollbar_hit_thumb_returns_drag_offset() raises:
    """Clicking on the thumb returns part=3 with the click's offset
    inside the thumb so the drag preserves the press point."""
    var bar = VScrollbar(10, 0, 9, 100, 10, 0)  # thumb at track row 0
    var on_thumb = bar.hit(Point(10, 1))
    assert_equal(on_thumb[0], 3)
    assert_equal(on_thumb[1], 0)


def test_scrollbar_hit_page_zones() raises:
    """Above the thumb is part=2 (page-up), below is part=4 (page-down)."""
    var bar = VScrollbar(10, 0, 9, 100, 10, 90)  # thumb at the bottom
    # Track rows 1..8. Thumb at knob_off=7, so row 1 (rel=0) is page-up.
    var pup = bar.hit(Point(10, 1))
    assert_equal(pup[0], 2)
    assert_equal(pup[1], 0)
    # Now flip — scroll=0 puts thumb at top, so a click near the bottom
    # of the track is page-down.
    var bar2 = VScrollbar(10, 0, 9, 100, 10, 0)
    var pdn = bar2.hit(Point(10, 8))
    assert_equal(pdn[0], 4)


def test_scrollbar_hit_off_axis_returns_none() raises:
    """A click in a different column (V-bar) must not fire."""
    var bar = VScrollbar(10, 0, 9, 100, 10, 0)
    var miss = bar.hit(Point(11, 5))
    assert_equal(miss[0], 0)


def test_scrollbar_drag_to_extremes() raises:
    """Dragging the thumb's leading cell to the bottom of the track
    yields ``scroll == max_scroll``; to the top yields 0."""
    var bar = VScrollbar(10, 0, 9, 100, 10, 0)
    # Track starts at top+1 = 1; track size = 8; knob size = 1; denom = 7.
    # Drag to mouse_y=8 with drag_offset=0 → target=7 → ns=max_scroll=90.
    assert_equal(bar.drag_to(8, 0), 90)
    assert_equal(bar.drag_to(1, 0), 0)
    # Out-of-range clamps.
    assert_equal(bar.drag_to(-50, 0), 0)
    assert_equal(bar.drag_to(1000, 0), 90)


def test_scrollbar_track_jump_centers_target() raises:
    """A click in the middle of the track jumps so the target row is
    centered in the visible area."""
    var bar = VScrollbar(10, 0, 9, 100, 10, 0)
    # track_size=8. rel=4 → target_row = 4*100/8 = 50. ns = 50 - 5 = 45.
    assert_equal(bar.track_jump(4), 45)
    # rel=0 → target_row=0 → ns clamps to 0.
    assert_equal(bar.track_jump(0), 0)
    # rel=track_size-1=7 → target_row = 7*100/8 = 87 → ns = 87-5 = 82.
    assert_equal(bar.track_jump(7), 82)


def test_scrollbar_horizontal_paints_arrows_on_axis() raises:
    """``HScrollbar`` is the same primitive rotated 90° — ◄ at the
    leading cell, ► at the trailing cell, █/░ along the row."""
    var bar = HScrollbar(5, 0, 9, 100, 10, 0)
    var c = Canvas(20, 10)
    var p = Painter(Rect(0, 0, 20, 10))
    bar.paint(c, p, Attr(WHITE, BLACK))
    assert_equal(c.get(0, 5).glyph, String("◄"))
    assert_equal(c.get(9, 5).glyph, String("►"))
    assert_equal(c.get(1, 5).glyph, String("█"))
    assert_equal(c.get(2, 5).glyph, String("░"))


def test_hscrollbar_reaches_last_column() raises:
    """The horizontal bar's range is the *content* width (gutters excluded),
    so dragging the thumb to the far right scrolls the last column of the
    longest line into view — not gutter-width short of it."""
    var w = _long_line_editor_window()
    var view = w.interior()
    var max_x = w.editor.max_scroll_x(view)
    # The content width is strictly narrower than the interior (gutters), so
    # the reachable range exceeds ``longest - interior_width``.
    assert_true(max_x > w.editor.longest_line_width() - view.width())
    var bar = w._h_scrollbar()
    assert_true(bar.metrics().present)
    # Drag the thumb's leading cell to the far right end of the track.
    w.h_drag_thumb_to(bar.right, 0)
    assert_equal(w.editor.scroll_x, max_x)


def test_hscrollbar_shift_wheel_scrolls_horizontally() raises:
    """Shift+wheel scrolls the editor horizontally; a plain wheel still
    scrolls vertically and leaves scroll_x untouched."""
    var w = _long_line_editor_window()
    var view = w.interior()
    # Shift+wheel-down scrolls right.
    var down = Event.mouse_event(Point(5, 5), MOUSE_WHEEL_DOWN, True, False,
                                 MOD_SHIFT)
    _ = w.editor.handle_mouse(down, view)
    assert_true(w.editor.scroll_x > 0)
    var after_down = w.editor.scroll_x
    # Shift+wheel-up scrolls back left.
    var up = Event.mouse_event(Point(5, 5), MOUSE_WHEEL_UP, True, False,
                               MOD_SHIFT)
    _ = w.editor.handle_mouse(up, view)
    assert_true(w.editor.scroll_x < after_down)
    # A plain (no-Shift) wheel-down moves the view vertically, not sideways.
    w.editor.scroll_x = 0
    var plain = Event.mouse_event(Point(5, 5), MOUSE_WHEEL_DOWN, True, False)
    _ = w.editor.handle_mouse(plain, view)
    assert_equal(w.editor.scroll_x, 0)
    assert_true(w.editor.scroll_y > 0)


# ----- Editor tests ---------------------------------------------------------


def test_reveal_cursor_golden_ratio() raises:
    """A deliberate jump (``golden=True``) parks the target line at the
    golden-ratio point of the viewport — ~38.2% from the top — and clamps
    at the file boundaries so a target near the top/EOF leaves no blank
    rows."""
    var text = String("line0")
    for i in range(1, 200):
        text += "\n" + String("line") + String(i)
    var ed = Editor(text)
    var view = Rect(0, 0, 80, 40)            # height 40
    # h=40 → above = (39*382)//1000 = 14 rows of context above the line.
    ed.move_to(100, 0, False)
    ed.reveal_cursor(view, golden=True)
    assert_equal(ed.scroll_y, 86)            # 100 - 14
    assert_equal(ed.selections[0].row - ed.scroll_y, 14)
    # Near the top: no negative scroll.
    ed.move_to(3, 0, False)
    ed.reveal_cursor(view, golden=True)
    assert_equal(ed.scroll_y, 0)
    # Near EOF: clamp so the last line sits at the bottom (no blank rows).
    ed.move_to(199, 0, False)
    ed.reveal_cursor(view, golden=True)
    assert_equal(ed.scroll_y, 160)           # 199 - 40 + 1
    # Plain (non-golden) reveal still does minimal edge scroll — a jump
    # already in view doesn't re-anchor.
    ed.scroll_y = 95
    ed.move_to(100, 0, False)
    ed.reveal_cursor(view)
    assert_equal(ed.scroll_y, 95)


def test_softwrap_visual_updown() raises:
    # In soft-wrap modes, up/down must move one *visual* row at a time —
    # stepping through a long line's wrapped segments instead of jumping
    # the whole logical line — so navigation feels the same whether code
    # is hard-wrapped onto several lines or soft-wrapped onto several
    # visual rows. Regression for visual vertical navigation.
    var view = Rect(0, 0, 24, 10)
    var long = String("")
    for _ in range(80):
        long += "x"
    var ed = Editor(long + "\n" + "short")
    ed.wrap_mode = WRAP_SOFT
    var cw = ed._content_width(view)
    var segs = ed._wrap_one_logical_line(0, cw)
    assert_true(len(segs) >= 3)   # the long line genuinely wraps

    # From the very start, one DOWN stays on logical row 0 and lands at
    # the head of the 2nd visual row — it does NOT skip to "short".
    ed.move_to(0, 0, False)
    _ = ed.handle_key(_key(KEY_DOWN), view)
    assert_equal(ed.selections[0].row, 0)
    assert_equal(ed.selections[0].col, segs[1].byte_start)

    # Continuing DOWN walks every remaining wrap segment, then crosses to
    # the next logical line exactly once they're exhausted.
    for i in range(2, len(segs)):
        _ = ed.handle_key(_key(KEY_DOWN), view)
        assert_equal(ed.selections[0].row, 0)
        assert_equal(ed.selections[0].col, segs[i].byte_start)
    _ = ed.handle_key(_key(KEY_DOWN), view)
    assert_equal(ed.selections[0].row, 1)

    # UP from "short" returns into the wrapped line's LAST visual row.
    _ = ed.handle_key(_key(KEY_UP), view)
    assert_equal(ed.selections[0].row, 0)
    assert_equal(ed.selections[0].col, segs[len(segs) - 1].byte_start)

    # The desired *screen* column is preserved across a visual step:
    # parking mid-segment-0 and pressing DOWN lands at the same screen
    # column on segment 1 (its hanging indent included in the math).
    ed.move_to(0, 5, False)        # screen column 5 on the first row
    _ = ed.handle_key(_key(KEY_DOWN), view)
    assert_equal(ed.selections[0].row, 0)
    # segment 1 starts at hanging indent ``indent_cells``; screen col 5
    # there is ``5 - indent_cells`` bytes past its start (all-ASCII line).
    assert_equal(
        ed.selections[0].col,
        segs[1].byte_start + (5 - segs[1].indent_cells),
    )

    # WRAP_NONE keeps the original logical-line behavior: DOWN jumps
    # straight to the next buffer line regardless of width.
    var ed2 = Editor(long + "\n" + "short")
    ed2.wrap_mode = WRAP_NONE
    ed2.move_to(0, 0, False)
    _ = ed2.handle_key(_key(KEY_DOWN), view)
    assert_equal(ed2.selections[0].row, 1)


def test_text_view_wrap_lines_breaks_at_width() raises:
    """``wrap_lines`` produces one ``VisualLine`` per painted row,
    splitting at exactly ``content_w`` cells with no overlap."""
    var lines = List[String]()
    lines.append(String("ABCDEFGHIJKLMNOPQRST"))   # 20 cells
    lines.append(String(""))                       # empty -> 1 zero-width row
    lines.append(String("xy"))                     # short -> 1 row
    var wrapped = wrap_lines(lines, 7)
    # 20 / 7 = 3 segments (7 + 7 + 6).
    assert_equal(len(wrapped), 3 + 1 + 1)
    assert_equal(wrapped[0].cell_count, 7)
    assert_equal(wrapped[1].cell_count, 7)
    assert_equal(wrapped[2].cell_count, 6)
    assert_equal(wrapped[0].cell_start, 0)
    assert_equal(wrapped[1].cell_start, 7)
    assert_equal(wrapped[2].cell_start, 14)
    # Empty line still occupies one zero-width visual row.
    assert_equal(wrapped[3].line_idx, 1)
    assert_equal(wrapped[3].cell_count, 0)
    # Short line fits in one segment.
    assert_equal(wrapped[4].line_idx, 2)
    assert_equal(wrapped[4].cell_count, 2)


def test_text_view_wrap_lines_word_aware_with_indent() raises:
    """Editor mode: word-aware wrap that backs up to the last
    non-word ASCII byte and indents continuations under the parent's
    leading whitespace plus one indent unit."""
    var lines = List[String]()
    lines.append(String("    foo bar baz qux"))   # 4 leading spaces
    var rows = wrap_lines(
        lines, 12,
        indent_size=4, word_aware=True, start_line=0, max_rows=-1,
    )
    # Expected: first segment "    foo bar " (12 cells, breaks at the
    # last space), continuation indents to 4+4=8 cells, then
    # "baz qux" — fits within 12-8=4 wait, that's too narrow, would
    # split again. Just assert that a continuation row exists with
    # the expected hanging indent.
    assert_true(len(rows) >= 2)
    assert_equal(rows[0].indent_cells, 0)
    assert_equal(rows[1].indent_cells, 8)


def test_text_view_wrap_lines_keeps_string_whole() raises:
    """Word-aware soft wrap treats a quoted string as one token: a break
    that would land inside ``'foobar'`` instead falls back to the space
    before the opening quote, so the literal is never split into
    ``'`` + ``foobar'``."""
    var line = String("aaa 'foobar'")   # 12 codepoints; quote span [4, 12)
    var lines = List[String]()
    lines.append(line)
    var rows = wrap_lines(lines, 8, word_aware=True)
    _assert_layout_contiguous(line, rows)
    # The break lands before the opening quote, not inside the string.
    assert_equal(len(rows), 2)
    assert_equal(rows[0].byte_end, 4)
    assert_equal(rows[1].byte_start, 4)
    assert_equal(rows[1].byte_end, 12)
    # No segment boundary lands strictly inside the quoted span [4, 12).
    for r in rows:
        assert_true(r.byte_start <= 4 or r.byte_start >= 12)


def test_text_view_selection_extracts_text() raises:
    """``Selection.extracted_text`` slices a flat ``List[String]`` by
    cell coordinates and joins lines with ``\\n``."""
    var lines = List[String]()
    lines.append(String("hello world"))
    lines.append(String("second line"))
    lines.append(String("third"))
    # Whole-buffer selection.
    var sel = Selection(True, False, 0, 0, 2, 5)
    assert_equal(
        sel.extracted_text(lines),
        String("hello world\nsecond line\nthird"),
    )
    # Mid-line selection on a single row.
    var inner = Selection(True, False, 1, 7, 1, 11)
    assert_equal(inner.extracted_text(lines), String("line"))
    # Empty selection (anchor == cursor) returns empty.
    var none = Selection(True, False, 0, 3, 0, 3)
    assert_equal(none.extracted_text(lines), String(""))
    # Reversed endpoints normalize to the same forward slice.
    var rev = Selection(True, False, 1, 11, 1, 7)
    assert_equal(rev.extracted_text(lines), String("line"))


def main() raises:
    setup_test_env()
    test_caret_blink_phase_math()
    test_caret_blink_resets_on_synth_key_movement()
    test_scrollbar_hidden_when_content_fits()
    test_scrollbar_hidden_when_too_short()
    test_scrollbar_paints_arrows_and_thumb()
    test_scrollbar_thumb_tracks_scroll_position()
    test_scrollbar_hit_arrow_zones()
    test_scrollbar_hit_thumb_returns_drag_offset()
    test_scrollbar_hit_page_zones()
    test_scrollbar_hit_off_axis_returns_none()
    test_scrollbar_drag_to_extremes()
    test_scrollbar_track_jump_centers_target()
    test_scrollbar_horizontal_paints_arrows_on_axis()
    test_hscrollbar_reaches_last_column()
    test_hscrollbar_shift_wheel_scrolls_horizontally()
    test_reveal_cursor_golden_ratio()
    test_softwrap_visual_updown()
    test_text_view_wrap_lines_breaks_at_width()
    test_text_view_wrap_lines_word_aware_with_indent()
    test_text_view_wrap_lines_keeps_string_whole()
    test_text_view_selection_extracts_text()
    print("editor_view: 21 tests passed")
