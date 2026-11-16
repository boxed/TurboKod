"""Framework chrome the host draws in its look (``Canvas.host_widgets``,
``HostItem``): scroll bars hand themselves to the host in the macOS-style
and Mac OS 9 looks, keep their hit-testing, and stay cells anywhere else.
The split divider's half lives in ``test_split_area.mojo``.

Shared fixtures live in ``tests/support.mojo`` and
``scripts/run_tests.sh`` runs every suite.
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from turbokod.canvas import (
    Canvas, HOST_HSCROLL, HOST_SURFACE_MAIN, HOST_SURFACE_SETTINGS,
    HOST_VSCROLL, SCALE_ONE,
)
from turbokod.cell import FONT_TERMINAL, FONT_UI
from turbokod.colors import Attr, BLACK, BLUE, WHITE, default_attr
from turbokod.grid_frame import GridFrame
from turbokod.desktop import Desktop
from turbokod.geometry import Point, Rect
from turbokod.painter import Painter
from turbokod.scrollbar import HScrollbar, ScrollBarArea, VScrollbar

from support import setup_test_env


def test_vertical_bar_becomes_a_host_item_where_the_host_draws() raises:
    var c = Canvas(20, 12)
    c.host_widgets = True
    # 100 rows, 10 visible, scrolled to 45: a bar down column 19.
    var bar = VScrollbar(19, 1, 10, 100, 10, 45)
    var attr = Attr(WHITE, BLACK)
    bar.paint(c, Painter(c.bounds()), attr)
    assert_equal(len(c.host_items), 1)
    ref it = c.host_items[0]
    assert_equal(it.kind, HOST_VSCROLL)
    assert_equal(it.x, 19000)
    assert_equal(it.y, 1000)
    assert_equal(it.h, 10000)
    # The thumb span is the core's, which hit-testing still answers from.
    var m = bar.metrics()
    assert_equal(it.knob_a, (2 + m.knob_off) * 1000)
    assert_equal(it.knob_b, it.knob_a + m.knob_size * 1000)
    assert_equal(c.get(19, 1).glyph, String(" "))
    assert_equal(c.get(19, 2 + m.knob_off).glyph, String(" "))
    assert_equal(bar.hit(Point(19, 1))[0], 1)
    assert_equal(bar.hit(Point(19, 2 + m.knob_off))[0], 3)


def test_horizontal_bar_becomes_a_host_item() raises:
    var c = Canvas(30, 5)
    c.host_widgets = True
    var bar = HScrollbar(4, 2, 21, 200, 20, 0)
    bar.paint(c, Painter(c.bounds()), Attr(WHITE, BLACK))
    assert_equal(len(c.host_items), 1)
    assert_equal(c.host_items[0].kind, HOST_HSCROLL)
    assert_equal(c.host_items[0].w, 20000)
    assert_equal(c.host_items[0].knob_a, 3000)


def test_bars_stay_cells_without_a_host_or_when_clipped() raises:
    var plain = Canvas(20, 12)
    var bar = VScrollbar(19, 1, 10, 100, 10, 0)
    bar.paint(plain, Painter(plain.bounds()), Attr(WHITE, BLACK))
    assert_equal(len(plain.host_items), 0)
    assert_equal(plain.get(19, 1).glyph, String("▲"))
    # Half the bar under another window: the host can't draw a part of a
    # bar, so the cells do.
    var c = Canvas(20, 12)
    c.host_widgets = True
    bar.paint(c, Painter(Rect(0, 0, 20, 6)), Attr(WHITE, BLACK))
    assert_equal(len(c.host_items), 0)
    assert_equal(c.get(19, 1).glyph, String("▲"))


def test_frame_canvas_hands_chrome_to_the_host_only_in_its_looks() raises:
    var d = Desktop()
    assert_false(d.frame_canvas(10, 10).host_widgets)
    # The terminal frontends never own the menu, whatever the setting.
    d.config.platinum_ui = True
    assert_false(d.frame_canvas(10, 10).host_widgets)
    d.host_owns_menu = True
    assert_true(d.frame_canvas(10, 10).host_widgets)
    d.config.platinum_ui = False
    d.config.native_ui = True
    assert_true(d.frame_canvas(10, 10).host_widgets)
    d.config.native_ui = False
    assert_false(d.frame_canvas(10, 10).host_widgets)


def test_platinum_bars_are_two_cells_and_hit_across_both() raises:
    """A Platinum scroll bar is 16 points, two cells: ``ScrollBarArea``
    puts it two columns in, the host item is two cells wide, and a press
    on either column is the bar's."""
    var d = Desktop()
    d.host_owns_menu = True
    d.config.platinum_ui = True
    var c = d.frame_canvas(20, 12)
    assert_equal(c.scroll_bar_cells, 2)
    d.config.platinum_ui = False
    d.config.native_ui = True
    assert_equal(d.frame_canvas(20, 12).scroll_bar_cells, 1)
    var area = ScrollBarArea()
    area.paint(c, Rect(0, 0, 20, 12), 100, 0, Attr(WHITE, BLACK))
    assert_equal(len(c.host_items), 1)
    assert_equal(c.host_items[0].x, 18000)
    assert_equal(c.host_items[0].w, 2000)
    for x in [18, 19]:
        assert_equal(area.bar.hit(Point(x, 0))[0], 1)
    assert_equal(area.bar.hit(Point(17, 0))[0], 0)
    # A sub-grid placed in it takes the thickness along.
    var g = Canvas(5, 5)
    g.inherit_chrome(c)
    assert_equal(g.scroll_bar_cells, 2)
    assert_true(g.host_widgets)


def test_a_reused_frame_canvas_starts_blank() raises:
    """The host surfaces' canvases are kept between frames: the next one
    must start exactly as a fresh canvas would — blank cells in the UI
    font, no host items, origin at the corner — and track the size."""
    var d = Desktop()
    d.host_owns_menu = True
    d.config.native_ui = True
    d.set_area_scale(Int(FONT_TERMINAL), 1500, 2000)
    var c = d.take_frame_canvas(HOST_SURFACE_MAIN, 20, 6, True)
    assert_true(c.host_widgets)
    assert_equal(c.scale_of(FONT_TERMINAL)[0], 1500)
    c.font = FONT_TERMINAL
    _ = c.put_text(Point(0, 0), String("dirty"), Attr(WHITE, BLUE), 20)
    VScrollbar(19, 1, 4, 100, 4, 0).paint(c, Painter(c.bounds()), Attr(WHITE, BLACK))
    assert_true(len(c.host_items) > 0)
    d.return_frame_canvas(HOST_SURFACE_MAIN, c^)
    d.config.native_ui = False
    var again = d.take_frame_canvas(HOST_SURFACE_MAIN, 20, 6, True)
    assert_equal(again.get(0, 0).glyph, String(" "))
    assert_true(again.get(0, 0).attr == default_attr())
    assert_equal(again.get(0, 0).font, FONT_UI)
    assert_equal(again.font, FONT_UI)
    assert_equal(len(again.host_items), 0)
    assert_false(again.host_widgets)
    d.return_frame_canvas(HOST_SURFACE_MAIN, again^)
    var bigger = d.take_frame_canvas(HOST_SURFACE_MAIN, 30, 8, True)
    assert_equal(bigger.width, 30)
    assert_equal(bigger.height, 8)
    assert_equal(len(bigger.cells), 240)
    # A surface without area fonts keeps every scale at one.
    var chrome = d.take_frame_canvas(HOST_SURFACE_SETTINGS, 10, 4, False)
    assert_equal(chrome.scale_of(FONT_TERMINAL)[0], SCALE_ONE)


def test_grid_frame_begins_cleared_to_the_background() raises:
    var parent = Canvas(20, 10)
    parent.scroll_bar_cells = 2
    var f = GridFrame.empty(FONT_TERMINAL)
    var bg = Attr(WHITE, BLUE)
    var g = f.begin(parent, Rect(2, 3, 12, 7), bg)
    assert_equal(g.width, 10)
    assert_equal(g.height, 4)
    assert_equal(len(g.cells), 40)
    assert_equal(g.origin.x, 2)
    assert_equal(g.origin.y, 3)
    assert_equal(g.font, FONT_TERMINAL)
    assert_equal(g.scroll_bar_cells, 2)
    for i in range(len(g.cells)):
        assert_equal(g.cells[i].glyph, String(" "))
        assert_true(g.cells[i].attr == bg)
        assert_equal(g.cells[i].font, FONT_TERMINAL)


def main() raises:
    setup_test_env()
    TestSuite.discover_tests[__functions_in_module()]().run()
