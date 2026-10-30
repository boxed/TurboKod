"""``ListBox`` selection: single-select, and the Windows extended-selection
rules for ``multi=True`` (click / Ctrl / Shift / drag / keyboard)."""

from std.testing import TestSuite, assert_equal, assert_false, assert_true
from turbokod.events import (
    Event, KEY_DOWN, KEY_END, KEY_HOME, KEY_PAGEDOWN, KEY_SPACE, KEY_UP,
    MOD_CTRL, MOD_META, MOD_NONE, MOD_SHIFT, MOUSE_BUTTON_LEFT,
    MOUSE_WHEEL_DOWN,
)
from turbokod.canvas import Canvas
from turbokod.colors import Attr, BLACK, CYAN
from turbokod.geometry import Point, Rect
from turbokod.list_box import ListBox


comptime _BOUNDS = Rect(0, 0, 20, 5)
comptime _N = 20


def _press(mut lb: ListBox, row: Int, mods: UInt8 = MOD_NONE):
    _ = lb.handle_mouse_press(
        Event.mouse_event(Point(3, row), MOUSE_BUTTON_LEFT, mods=mods),
        _BOUNDS, _N,
    )


def _drag_to(mut lb: ListBox, y: Int):
    _ = lb.handle_mouse_drag(
        Event.mouse_event(Point(3, y), MOUSE_BUTTON_LEFT, True, True),
        _BOUNDS, _N,
    )


def _release(mut lb: ListBox, y: Int):
    _ = lb.handle_mouse_drag(
        Event.mouse_event(Point(3, y), MOUSE_BUTTON_LEFT, False),
        _BOUNDS, _N,
    )


def _key(mut lb: ListBox, key: UInt32, mods: UInt8 = MOD_NONE):
    _ = lb.handle_nav_key(Event.key_event(key, mods), _N)


def _rows(lb: ListBox) -> String:
    var out = String("")
    var idx = lb.selected_indices()
    for i in range(len(idx)):
        if i > 0:
            out += String(",")
        out += String(idx[i])
    return out


def test_single_select_ignores_modifiers() raises:
    var lb = ListBox()
    _press(lb, 1)
    _press(lb, 3, MOD_SHIFT)
    assert_equal(_rows(lb), String("3"))
    _press(lb, 4, MOD_CTRL)
    assert_equal(_rows(lb), String("4"))
    _key(lb, KEY_DOWN, MOD_SHIFT)
    assert_equal(_rows(lb), String("5"))
    # Space isn't a list key in single mode: the host keeps it.
    assert_false(lb.handle_nav_key(Event.key_event(KEY_SPACE), _N))


def test_multi_click_ctrl_shift() raises:
    var lb = ListBox(multi=True)
    _press(lb, 1)
    assert_equal(_rows(lb), String("1"))
    _press(lb, 3, MOD_SHIFT)
    assert_equal(_rows(lb), String("1,2,3"))
    # Shrinking the range back drops what it added.
    _press(lb, 2, MOD_SHIFT)
    assert_equal(_rows(lb), String("1,2"))
    # Plain click collapses.
    _press(lb, 0)
    assert_equal(_rows(lb), String("0"))
    # Ctrl-click toggles and re-anchors.
    _press(lb, 2, MOD_CTRL)
    assert_equal(_rows(lb), String("0,2"))
    _press(lb, 0, MOD_META)
    assert_equal(_rows(lb), String("2"))
    _press(lb, 2, MOD_CTRL)
    assert_equal(_rows(lb), String(""))
    # Ctrl+Shift-click adds the range to what's already selected.
    _press(lb, 0)
    _press(lb, 2, MOD_CTRL)  # {0,2}, anchor 2
    _press(lb, 4, MOD_CTRL | MOD_SHIFT)  # + 2..4
    assert_equal(_rows(lb), String("0,2,3,4"))
    _press(lb, 3, MOD_CTRL | MOD_SHIFT)  # range shrinks, base stays
    assert_equal(_rows(lb), String("0,2,3"))


def test_ctrl_shift_range_deselects_when_anchor_toggled_off() raises:
    var lb = ListBox(multi=True)
    _press(lb, 0)
    _press(lb, 4, MOD_SHIFT)
    assert_equal(lb.selected_count(), 5)
    # Toggle a row off inside the block, then Ctrl+Shift a range from it.
    _press(lb, 1, MOD_CTRL)
    _press(lb, 3, MOD_CTRL | MOD_SHIFT)
    assert_equal(_rows(lb), String("0,4"))
    # Shrinking the range gives the rows back.
    _press(lb, 2, MOD_CTRL | MOD_SHIFT)
    assert_equal(_rows(lb), String("0,3,4"))
    # Toggling a row back on makes the next Ctrl+Shift range select.
    _press(lb, 2, MOD_CTRL)
    assert_equal(_rows(lb), String("0,2,3,4"))
    _press(lb, 1, MOD_CTRL | MOD_SHIFT)
    assert_equal(_rows(lb), String("0,1,2,3,4"))


def test_multi_click_on_empty_area_changes_nothing() raises:
    var lb = ListBox(multi=True)
    _press(lb, 1)
    _ = lb.handle_mouse_press(
        Event.mouse_event(Point(3, 4), MOUSE_BUTTON_LEFT), _BOUNDS, 3,
    )
    assert_equal(_rows(lb), String("1"))


def test_multi_keyboard_arrows() raises:
    var lb = ListBox(multi=True)
    _key(lb, KEY_DOWN)  # no caret yet: lands on the first row
    assert_equal(_rows(lb), String("0"))
    _key(lb, KEY_DOWN)
    assert_equal(_rows(lb), String("1"))
    _key(lb, KEY_DOWN, MOD_SHIFT)
    _key(lb, KEY_DOWN, MOD_SHIFT)
    assert_equal(_rows(lb), String("1,2,3"))
    _key(lb, KEY_UP, MOD_SHIFT)
    assert_equal(_rows(lb), String("1,2"))
    # Ctrl+arrow moves the caret alone.
    _key(lb, KEY_DOWN, MOD_CTRL)
    _key(lb, KEY_DOWN, MOD_CTRL)
    assert_equal(_rows(lb), String("1,2"))
    assert_equal(lb.selected, 4)
    # Ctrl+Space toggles the caret row; Space then selects only it.
    _key(lb, KEY_SPACE, MOD_CTRL)
    assert_equal(_rows(lb), String("1,2,4"))
    _key(lb, KEY_SPACE)
    assert_equal(_rows(lb), String("4"))
    # A plain arrow collapses again.
    _key(lb, KEY_UP)
    assert_equal(_rows(lb), String("3"))


def test_multi_home_end_page() raises:
    var lb = ListBox(multi=True)
    _press(lb, 2)
    _key(lb, KEY_END, MOD_SHIFT)
    assert_equal(len(lb.selected_indices()), _N - 2)
    _key(lb, KEY_HOME, MOD_SHIFT)
    assert_equal(_rows(lb), String("0,1,2"))
    _key(lb, KEY_HOME)
    assert_equal(_rows(lb), String("0"))
    _ = lb.handle_nav_key(Event.key_event(KEY_PAGEDOWN), _N, 4)
    assert_equal(_rows(lb), String("4"))
    _key(lb, KEY_END)
    assert_equal(_rows(lb), String("19"))


def test_multi_select_all() raises:
    var lb = ListBox(multi=True)
    _press(lb, 1)
    _key(lb, UInt32(0x61), MOD_CTRL)
    assert_equal(lb.selected_count(), _N)
    # Cmd+A too, and Shift-extend afterwards replaces it with a range.
    _press(lb, 2)
    _key(lb, UInt32(0x41), MOD_META)
    assert_equal(lb.selected_count(), _N)
    _key(lb, KEY_DOWN)
    assert_equal(lb.selected_count(), 1)


def test_multi_drag_selects_range_and_autoscrolls() raises:
    var lb = ListBox(multi=True)
    _press(lb, 1)
    _drag_to(lb, 3)
    assert_equal(_rows(lb), String("1,2,3"))
    _drag_to(lb, 0)
    assert_equal(_rows(lb), String("0,1"))
    # Past the bottom edge scrolls a row per event and keeps extending.
    _drag_to(lb, 5)
    _drag_to(lb, 6)
    assert_equal(lb._scroll, 2)
    assert_equal(lb.selected, 6)
    assert_equal(len(lb.selected_indices()), 6)
    _release(lb, 6)
    # After the release, motion is not ours any more.
    assert_false(lb.handle_mouse_drag(
        Event.mouse_event(Point(3, 0), MOUSE_BUTTON_LEFT, True, True),
        _BOUNDS, _N,
    ))


def test_press_after_lost_release_is_still_a_press() raises:
    """A drag whose release never arrived must not swallow the next click."""
    var lb = ListBox(multi=True)
    _press(lb, 1)
    _press(lb, 3, MOD_SHIFT)
    assert_equal(_rows(lb), String("1,2,3"))


def test_paint_marks_caret_and_anchor() raises:
    var lb = ListBox(multi=True)
    var items = List[String]()
    for _ in range(6):
        items.append(String("row"))
    _press(lb, 1)
    _press(lb, 3, MOD_SHIFT)  # anchor 1, caret 3
    var canvas = Canvas(20, 5)
    var attr = Attr(BLACK, CYAN)
    lb.paint(canvas, _BOUNDS, items, True, attr)
    assert_equal(canvas.get(0, 1).glyph, String("◆"))
    assert_equal(canvas.get(0, 3).glyph, String("►"))
    assert_equal(canvas.get(0, 2).glyph, String(" "))
    # Same row: only the caret shows.
    _press(lb, 2)
    lb.paint(canvas, _BOUNDS, items, True, attr)
    assert_equal(canvas.get(0, 2).glyph, String("►"))
    # Unfocused: neither.
    lb.paint(canvas, _BOUNDS, items, False, attr)
    assert_equal(canvas.get(0, 2).glyph, String(" "))


def test_single_drag_follows_pointer() raises:
    var lb = ListBox()
    _press(lb, 0)
    _drag_to(lb, 2)
    assert_equal(_rows(lb), String("2"))


def test_wheel_scrolls_three_rows_and_leaves_selection() raises:
    var lb = ListBox(multi=True)
    _press(lb, 1)
    var down = Event.mouse_event(Point(3, 1), MOUSE_WHEEL_DOWN, True, False)
    _ = lb.handle_mouse_press(down, _BOUNDS, _N)
    assert_equal(lb._scroll, 3)
    assert_equal(_rows(lb), String("1"))


def test_set_selection_remaps_after_rows_move() raises:
    var lb = ListBox(multi=True)
    var rows = List[Int]()
    rows.append(7)
    rows.append(2)
    rows.append(99)  # out of range: dropped
    lb.set_selection(rows, 2, 7, 10)
    assert_equal(_rows(lb), String("2,7"))
    assert_equal(lb.selected, 2)
    assert_equal(lb.anchor(), 7)
    # Shift from the restored anchor.
    _ = lb.handle_nav_key(Event.key_event(KEY_UP, MOD_SHIFT), 10)
    assert_equal(_rows(lb), String("1,2,3,4,5,6,7"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()


def _items(n: Int) -> List[String]:
    var out = List[String]()
    for i in range(n):
        out.append(String("item ") + String(i))
    return out^


def test_an_overflowing_list_draws_a_scroll_bar_that_scrolls() raises:
    """The framework's lists get a scroll bar with no code in the host:
    drawn on the right column when the items don't fit, and its arrows
    and thumb move the view."""
    var c = Canvas(20, 5)
    var lb = ListBox()
    var items = _items(_N)
    lb.paint(c, _BOUNDS, items, True, Attr(BLACK, CYAN))
    assert_equal(c.get(19, 0).glyph, String("▲"))
    assert_equal(c.get(19, 4).glyph, String("▼"))
    assert_equal(c.get(19, 1).glyph, String("█"))
    # The down arrow scrolls a row; the selection doesn't move.
    _ = lb.handle_mouse_press(
        Event.mouse_event(Point(19, 4), MOUSE_BUTTON_LEFT), _BOUNDS, _N,
    )
    assert_equal(lb.prepare(_BOUNDS, _N), 1)
    assert_equal(lb.selected, -1)
    # Dragging the thumb to the bottom shows the last rows.
    _ = lb.handle_mouse_press(
        Event.mouse_event(Point(19, 1), MOUSE_BUTTON_LEFT), _BOUNDS, _N,
    )
    _ = lb.handle_mouse_drag(
        Event.mouse_event(Point(19, 3), MOUSE_BUTTON_LEFT, True, True),
        _BOUNDS, _N,
    )
    _ = lb.handle_mouse_drag(
        Event.mouse_event(Point(19, 3), MOUSE_BUTTON_LEFT, False),
        _BOUNDS, _N,
    )
    assert_equal(lb.prepare(_BOUNDS, _N), _N - 5)


def test_a_list_that_fits_has_no_scroll_bar() raises:
    var c = Canvas(20, 5)
    var lb = ListBox()
    var items = _items(3)
    lb.paint(c, _BOUNDS, items, True, Attr(BLACK, CYAN))
    for y in range(5):
        assert_false(c.get(19, y).glyph == String("▲"))
        assert_false(c.get(19, y).glyph == String("█"))
