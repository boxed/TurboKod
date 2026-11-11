"""``SplitArea``, the framework's resizable split: layout, minimums,
dragging the divider, the double-click reset and the resize cursor.

Shared fixtures live in ``tests/support.mojo`` and
``scripts/run_tests.sh`` runs every suite.
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from turbokod.canvas import Canvas, HOST_SPLIT
from turbokod.cell import FONT_TERMINAL
from turbokod.events import Event, MOUSE_BUTTON_LEFT
from turbokod.geometry import Point, Rect
from turbokod.split_area import SplitArea

from support import setup_test_env


def _same(a: Rect, b: Rect) raises:
    assert_equal(
        String(a.a.x, ",", a.a.y, ",", a.b.x, ",", a.b.y),
        String(b.a.x, ",", b.a.y, ",", b.b.x, ",", b.b.y),
    )


def _press(x: Int, y: Int, clicks: Int = 1) -> Event:
    var e = Event.mouse_event(Point(x, y), MOUSE_BUTTON_LEFT, True, False)
    e.click_count = UInt8(clicks)
    return e


def _drag(x: Int, y: Int) -> Event:
    return Event.mouse_event(Point(x, y), MOUSE_BUTTON_LEFT, True, True)


def _release(x: Int, y: Int) -> Event:
    return Event.mouse_event(Point(x, y), MOUSE_BUTTON_LEFT, False, False)


def test_split_lays_out_two_halves_and_a_divider() raises:
    var s = SplitArea(400)
    var h = s.layout(Rect(0, 2, 81, 10), True)
    # 80 cells for the halves: 32 + divider + 48.
    _same(h[0], Rect(0, 2, 32, 10))
    _same(h[1], Rect(33, 2, 81, 10))
    _same(s.divider_rect(), Rect(32, 2, 33, 10))
    var v = s.layout(Rect(0, 0, 40, 11), False)
    _same(v[0], Rect(0, 0, 40, 4))
    _same(v[1], Rect(0, 5, 40, 11))


def test_split_keeps_each_halfs_minimum() raises:
    var s = SplitArea(50, min_first=10, min_second=20)
    var h = s.layout(Rect(0, 0, 61, 5), True)
    assert_equal(h[0].width(), 10)
    s.fraction = 990
    h = s.layout(Rect(0, 0, 61, 5), True)
    assert_equal(h[1].width(), 20)
    # Too small for both: still two halves, the second giving way first.
    h = s.layout(Rect(0, 0, 8, 5), True)
    assert_true(h[0].width() >= 1 and h[1].width() >= 1)
    assert_equal(h[0].width() + h[1].width() + 1, 8)


def test_split_drags_its_divider_and_reports_the_change() raises:
    var s = SplitArea(400)
    _ = s.layout(Rect(0, 0, 101, 10), True)
    assert_equal(s.divider_rect().a.x, 40)
    assert_false(s.handle_mouse(_press(20, 3)))
    assert_true(s.handle_mouse(_press(40, 3)))
    assert_true(s.dragging)
    assert_equal(s.pointer_shape(Point(90, 9)), String("ew-resize"))
    # Every event of the drag is the divider's, wherever the pointer is.
    assert_true(s.handle_mouse(_drag(60, 30)))
    assert_false(s.take_changed())
    assert_true(s.handle_mouse(_release(60, 30)))
    assert_false(s.dragging)
    assert_true(s.take_changed())
    assert_false(s.take_changed())
    assert_equal(s.fraction, 600)
    _ = s.layout(Rect(0, 0, 101, 10), True)
    assert_equal(s.divider_rect().a.x, 60)
    # A double click puts it back.
    assert_true(s.handle_mouse(_press(60, 3, 2)))
    assert_equal(s.fraction, 400)
    assert_true(s.take_changed())


def test_split_cursor_shows_over_the_divider_only() raises:
    var s = SplitArea(500)
    _ = s.layout(Rect(0, 0, 21, 10), False)
    var div = s.divider_rect().a.y
    assert_equal(s.pointer_shape(Point(3, div)), String("ns-resize"))
    assert_equal(s.pointer_shape(Point(3, div - 1)), String(""))
    s.hide()
    assert_equal(s.pointer_shape(Point(3, div)), String(""))


def test_split_paints_its_divider() raises:
    var s = SplitArea(500)
    _ = s.layout(Rect(0, 0, 11, 3), True)
    var c = Canvas(11, 3)
    s.paint(c)
    for y in range(3):
        assert_equal(c.get(5, y).glyph, String("│"))


def test_split_leaves_its_divider_to_a_host_that_draws_chrome() raises:
    """In the macOS-style and Mac OS 9 looks the divider is a host item
    over blank cells — and placing a sub-grid at another cell size carries
    the item into the parent in the parent's cells."""
    var s = SplitArea(500)
    _ = s.layout(Rect(0, 0, 11, 4), True)
    var grid = Canvas(11, 4)
    grid.host_widgets = True
    s.paint(grid)
    assert_equal(grid.get(5, 1).glyph, String(" "))
    assert_equal(len(grid.host_items), 1)
    ref it = grid.host_items[0]
    assert_equal(it.kind, HOST_SPLIT)
    assert_equal(it.x, 5000)
    assert_equal(it.w, 1000)
    assert_equal(it.h, 4000)
    assert_true(it.side_by_side)
    # The grid's cells are half a screen cell wide, placed at (10, 20).
    var screen = Canvas(40, 30)
    screen.area_scale[2 * Int(FONT_TERMINAL)] = 500
    screen.place_sub_grid(FONT_TERMINAL, Rect(10, 20, 16, 24), grid^)
    assert_equal(len(screen.host_items), 1)
    assert_equal(screen.host_items[0].x, 12500)
    assert_equal(screen.host_items[0].w, 500)
    assert_equal(screen.host_items[0].y, 20000)
    # Without a host for it, it's cells.
    var plain = Canvas(11, 4)
    s.paint(plain)
    assert_equal(len(plain.host_items), 0)
    assert_equal(plain.get(5, 1).glyph, String("│"))


def main() raises:
    setup_test_env()
    TestSuite.discover_tests[__functions_in_module()]().run()
