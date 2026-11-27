"""Tool panels docked to an edge of their own — left, right, top, bottom or
the floating panels' window — and auto-hide. See docs/dock-edges.md.

Shared fixtures live in ``tests/support.mojo`` and
``scripts/run_tests.sh`` runs every suite.
"""

from std.testing import (
    TestSuite, assert_equal, assert_false, assert_true,
)

from turbokod.canvas import Canvas
from turbokod.colors import default_attr
from turbokod.settings import SECTION_PANELS, Settings
from turbokod.ui_grid import GridForm
from turbokod.desktop import (
    DOCK_DEBUG_PANE, DOCK_NONE, DOCK_TEST_PANE, Desktop, PANEL_KIND_DEBUG,
    PANEL_KIND_TEST,
)
from turbokod.events import Event, MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT
from turbokod.geometry import Point, Rect
from turbokod.window import (
    EDGE_BOTTOM, EDGE_FLOAT, EDGE_LEFT, EDGE_RIGHT, EDGE_TOP,
    PANEL_STATE_MAXIMIZED, PANEL_STATE_MINIMIZED, PANEL_STATE_NONE,
    PANEL_STATE_NORMAL, Window, dock_spec, dock_spec_edge, dock_spec_home,
    DOCK_PREVIEW_EDITOR, dock_order_edges, dock_preview_regions,
)

from support import setup_test_env


comptime _WIDE = Rect(0, 0, 200, 30)
"""Wide enough for both side columns at their default width. Row 0 is the
in-grid menu bar and rows 28 and 29 the tab and status bars, so the docks
run 1..28."""


def _same(a: Rect, b: Rect) raises:
    assert_equal(
        String(a.a.x, ",", a.a.y, ",", a.b.x, ",", a.b.y),
        String(b.a.x, ",", b.a.y, ",", b.b.x, ",", b.b.y),
    )


def _press(p: Point, clicks: Int = 1) -> Event:
    var e = Event.mouse_event(p, MOUSE_BUTTON_LEFT, True, False)
    e.click_count = UInt8(clicks)
    return e


def _drag_to(p: Point) -> Event:
    return Event.mouse_event(p, MOUSE_BUTTON_LEFT, True, True)


def _release(p: Point) -> Event:
    return Event.mouse_event(p, MOUSE_BUTTON_LEFT, False, False)


def _click(mut d: Desktop, p: Point) raises:
    _ = d.handle_event(_press(p), _WIDE)
    _ = d.handle_event(_release(p), _WIDE)


def _paint(mut d: Desktop):
    var c = Canvas(_WIDE.b.x, _WIDE.b.y)
    d.paint(c, _WIDE)


def _two_panes() -> Desktop:
    var d = Desktop()
    d.debug_pane.visible = True
    d.test_pane.visible = True
    return d^


def test_dock_spec_round_trips() raises:
    assert_equal(dock_spec(EDGE_LEFT, EDGE_LEFT), String("left"))
    assert_equal(dock_spec(EDGE_FLOAT, EDGE_RIGHT), String("float:right"))
    assert_equal(Int(dock_spec_edge(String("float:right"))), Int(EDGE_FLOAT))
    assert_equal(Int(dock_spec_home(String("float:right"))), Int(EDGE_RIGHT))
    assert_equal(Int(dock_spec_edge(String("top"))), Int(EDGE_TOP))
    assert_equal(Int(dock_spec_home(String("top"))), Int(EDGE_TOP))
    # Anything unknown docks at the bottom, as everything used to.
    assert_equal(Int(dock_spec_edge(String("sideways"))), Int(EDGE_BOTTOM))


def test_side_columns_take_the_full_height_beside_the_workspace() raises:
    var d = _two_panes()
    d.debug_pane.dock.set_edge(EDGE_LEFT)
    d.test_pane.dock.set_edge(EDGE_RIGHT)
    # Each column is its default 50 cells, with a divider column between
    # it and the workspace.
    _same(d.debug_pane_rect(_WIDE), Rect(0, 1, 50, 28))
    _same(d.test_pane_rect(_WIDE), Rect(150, 1, 200, 28))
    _same(d.workspace_rect(_WIDE), Rect(51, 1, 149, 28))


def test_side_column_sits_inside_the_file_tree() raises:
    var d = _two_panes()
    d.file_tree.visible = True
    d.file_tree.dock_left = True
    d.debug_pane.dock.set_edge(EDGE_LEFT)
    d.test_pane.visible = False
    var tree = d.file_tree.width
    _same(d.debug_pane_rect(_WIDE), Rect(tree, 1, tree + 50, 28))
    assert_equal(d.workspace_rect(_WIDE).a.x, tree + 51)


def test_top_region_and_bottom_stack_share_the_middle() raises:
    var d = _two_panes()
    d.debug_pane.dock.set_edge(EDGE_TOP)
    # The top region is its default 12 rows, then a divider row.
    _same(d.debug_pane_rect(_WIDE), Rect(0, 1, 200, 13))
    # The test pane keeps the bottom: 10 rows above the tab bar.
    d.test_pane.dock.preferred_height = 10
    _same(d.test_pane_rect(_WIDE), Rect(0, 18, 200, 28))
    _same(d.workspace_rect(_WIDE), Rect(0, 14, 200, 18))
    # Maximized at the bottom, it fills up to the top region, not over it.
    d.test_pane.dock.set_state(PANEL_STATE_MAXIMIZED)
    _same(d.test_pane_rect(_WIDE), Rect(0, 14, 200, 28))


def test_bottom_stack_spans_between_the_side_columns() raises:
    var d = _two_panes()
    d.debug_pane.dock.set_edge(EDGE_LEFT)
    _same(d.test_pane_rect(_WIDE), Rect(51, 14, 200, 28))
    _same(d.workspace_rect(_WIDE), Rect(51, 1, 200, 14))


def test_panels_on_one_side_stack_and_fill_it() raises:
    var d = _two_panes()
    d.debug_pane.dock.set_edge(EDGE_LEFT)
    d.test_pane.dock.set_edge(EDGE_LEFT)
    # The first keeps its height; the last absorbs the rest.
    _same(d.debug_pane_rect(_WIDE), Rect(0, 1, 50, 15))
    _same(d.test_pane_rect(_WIDE), Rect(0, 15, 50, 28))
    # Maximized, a panel fills its column; the other rolls up beside it.
    d.test_pane.dock.set_state(PANEL_STATE_MAXIMIZED)
    _paint(d)
    assert_equal(Int(d.debug_pane.dock.state), Int(PANEL_STATE_MINIMIZED))
    _same(d.debug_pane_rect(_WIDE), Rect(0, 1, 50, 2))
    _same(d.test_pane_rect(_WIDE), Rect(0, 2, 50, 28))
    # The bottom stack is untouched by a maximize on another edge.
    assert_equal(d.workspace_rect(_WIDE).b.y, 28)


def test_side_column_divider_drags_in_cells() raises:
    var d = _two_panes()
    d.test_pane.visible = False
    d.debug_pane.dock.set_edge(EDGE_LEFT)
    _paint(d)
    assert_equal(d.pointer_shape_at(Point(50, 10), _WIDE), String("ew-resize"))
    _ = d.handle_event(_press(Point(50, 10)), _WIDE)
    _ = d.handle_event(_drag_to(Point(70, 10)), _WIDE)
    _ = d.handle_event(_release(Point(70, 10)), _WIDE)
    assert_equal(d.config.dock_left_cols, 70)
    _paint(d)
    _same(d.debug_pane_rect(_WIDE), Rect(0, 1, 70, 28))
    # The width is cells, not a share: a wider window keeps it.
    _same(d.debug_pane_rect(Rect(0, 0, 300, 30)), Rect(0, 1, 70, 28))


def test_splitter_inside_a_side_column_resizes_the_panel_above() raises:
    var d = _two_panes()
    d.debug_pane.dock.set_edge(EDGE_RIGHT)
    d.test_pane.dock.set_edge(EDGE_RIGHT)
    _paint(d)
    # The test pane's header row is the splitter under the debug pane
    # (on its title: its close box and title commands are buttons).
    assert_equal(
        d.pointer_shape_at(Point(157, 15), _WIDE), String("ns-resize"),
    )
    _ = d.handle_event(_press(Point(157, 15)), _WIDE)
    _ = d.handle_event(_drag_to(Point(157, 20)), _WIDE)
    _ = d.handle_event(_release(Point(157, 20)), _WIDE)
    assert_equal(d.debug_pane.dock.preferred_height, 19)
    _same(d.test_pane_rect(_WIDE), Rect(150, 20, 200, 28))


def test_rolled_up_side_column_collapses_to_a_strip() raises:
    var d = _two_panes()
    d.debug_pane.dock.set_edge(EDGE_LEFT)
    d.test_pane.dock.set_edge(EDGE_LEFT)
    d.debug_pane.dock.set_state(PANEL_STATE_MINIMIZED)
    d.test_pane.dock.set_state(PANEL_STATE_MINIMIZED)
    # The editors get the width back, all but the strip's two columns.
    assert_equal(d.workspace_rect(_WIDE).a.x, 2)
    assert_true(d.debug_pane_rect(_WIDE).is_empty())
    var tabs = d._strip_tabs(_WIDE)
    assert_equal(len(tabs), 2)
    assert_equal(tabs[0].kind, PANEL_KIND_DEBUG)
    assert_equal(tabs[1].kind, PANEL_KIND_TEST)
    assert_true(tabs[0].rect.b.y < tabs[1].rect.a.y)
    _paint(d)
    # A click on a tab opens its panel, focused.
    _click(d, Point(0, tabs[1].rect.a.y + 1))
    assert_equal(Int(d.test_pane.dock.state), Int(PANEL_STATE_NORMAL))
    assert_true(d.test_pane.focused)
    assert_equal(d.workspace_rect(_WIDE).a.x, 51)


def test_auto_hide_rolls_up_when_an_editor_is_clicked() raises:
    var d = _two_panes()
    d.debug_pane.visible = False
    d.test_pane.dock.auto_hide = True
    d.windows.add(Window.editor_window(
        String("a"), Rect(0, 1, 100, 10), String("x = 1\n"),
    ))
    _paint(d)
    _click(d, Point(10, 5))
    assert_equal(Int(d.test_pane.dock.state), Int(PANEL_STATE_MINIMIZED))
    assert_equal(Int(d.test_pane.dock.hidden_from), Int(PANEL_STATE_NORMAL))
    # Rolled up to its header on the status bar; a click on it brings it
    # back to where it was.
    _paint(d)
    var header = d.test_pane_rect(_WIDE)
    assert_equal(header.height(), 1)
    _click(d, Point(10, header.a.y))
    assert_true(d.test_pane.focused)
    assert_equal(Int(d.test_pane.dock.state), Int(PANEL_STATE_NORMAL))
    assert_equal(Int(d.test_pane.dock.hidden_from), Int(PANEL_STATE_NONE))
    assert_equal(d.test_pane_rect(_WIDE).height(), 14)


def test_auto_hide_follows_keyboard_focus_moving_to_the_editors() raises:
    var d = _two_panes()
    d.debug_pane.dock.auto_hide = True
    d.debug_pane.dock.set_edge(EDGE_RIGHT)
    d.test_pane.dock.auto_hide = False
    d._focus_dock(DOCK_DEBUG_PANE)
    d._on_focus_change()
    assert_equal(Int(d.debug_pane.dock.state), Int(PANEL_STATE_NORMAL))
    d._focus_dock(DOCK_NONE)
    d._on_focus_change()
    # Only the auto-hide panel rolls up.
    assert_equal(Int(d.debug_pane.dock.state), Int(PANEL_STATE_MINIMIZED))
    assert_equal(Int(d.test_pane.dock.state), Int(PANEL_STATE_NORMAL))
    # Alone on its side, it rolls the column up into a strip.
    assert_equal(d.workspace_rect(_WIDE).b.x, 198)
    # Focusing it any way at all (here: Ctrl+9's path) brings it back.
    d._focus_dock(DOCK_DEBUG_PANE)
    assert_equal(Int(d.debug_pane.dock.state), Int(PANEL_STATE_NORMAL))


def test_auto_hide_restores_a_maximized_panel_and_keeps_its_neighbors() raises:
    var d = _two_panes()
    d.debug_pane.dock.auto_hide = True
    d.test_pane.dock.auto_hide = True
    d.debug_pane.dock.set_state(PANEL_STATE_MAXIMIZED)
    _paint(d)
    assert_equal(Int(d.test_pane.dock.state), Int(PANEL_STATE_MINIMIZED))
    d._focus_dock(DOCK_DEBUG_PANE)
    d._on_focus_change()
    d._focus_dock(DOCK_NONE)
    d._on_focus_change()
    _paint(d)
    # Both stay rolled up: the one that yielded doesn't pop back open now
    # that nothing is maximized.
    assert_equal(Int(d.debug_pane.dock.state), Int(PANEL_STATE_MINIMIZED))
    assert_equal(Int(d.test_pane.dock.state), Int(PANEL_STATE_MINIMIZED))
    d._focus_dock(DOCK_DEBUG_PANE)
    _paint(d)
    assert_equal(Int(d.debug_pane.dock.state), Int(PANEL_STATE_MAXIMIZED))


def test_a_run_brings_an_auto_hidden_panel_out_without_the_keyboard() raises:
    var d = _two_panes()
    d.test_pane.dock.auto_hide = True
    _ = d.test_pane.dock.auto_hide_now()
    d._reveal_panel(PANEL_KIND_TEST, 0, focus=False)
    assert_equal(Int(d.test_pane.dock.state), Int(PANEL_STATE_NORMAL))
    assert_false(d.test_pane.focused)


def test_floating_panels_dock_home_without_a_panel_window() raises:
    var d = _two_panes()
    d.debug_pane.dock.set_edge(EDGE_LEFT)
    d.debug_pane.dock.set_edge(EDGE_FLOAT)
    assert_equal(Int(d.debug_pane.dock.home_edge), Int(EDGE_LEFT))
    # No panel window: it docks on its home edge.
    assert_equal(d.panels_visible_count(), 0)
    _same(d.debug_pane_rect(_WIDE), Rect(0, 1, 50, 28))
    # With one, it's there and nowhere in the project window.
    d.float_allowed = True
    assert_equal(d.panels_visible_count(), 1)
    assert_true(d.debug_pane_rect(_WIDE).is_empty())
    assert_equal(d.workspace_rect(_WIDE).a.x, 0)
    var slots = d._panel_window_slots(Rect(0, 0, 80, 40))
    assert_equal(len(slots), 1)
    _same(slots[0].rect, Rect(0, 0, 80, 40))
    # Closing the window docks it home.
    d.dock_floating_panels_home()
    assert_equal(Int(d.debug_pane.dock.edge), Int(EDGE_LEFT))
    assert_equal(d.panels_visible_count(), 0)


def test_floating_a_panel_asks_the_host_for_a_window() raises:
    var d = _two_panes()
    d._dock_panel(PANEL_KIND_TEST, 0, EDGE_FLOAT)
    assert_true(d.take_panels_float_request())
    assert_false(d.take_panels_float_request())
    assert_equal(d.config.dock_test, String("float:bottom"))


def test_header_right_click_opens_the_dock_menu() raises:
    var d = _two_panes()
    d.debug_pane.visible = False
    _paint(d)
    var header = d.test_pane_rect(_WIDE).a
    _ = d.handle_event(
        Event.mouse_event(
            Point(30, header.y), MOUSE_BUTTON_RIGHT, True, False,
        ),
        _WIDE,
    )
    assert_true(d.tab_context_menu.active)
    var code = -1
    for ref item in d.tab_context_menu.items:
        if item.label == String("Dock Left"):
            code = item.code
        if item.label == String("Dock Bottom"):
            assert_false(item.enabled)
    d.tab_context_menu.choose(code)
    _ = d._on_tab_context_menu_submit()
    assert_equal(Int(d.test_pane.dock.edge), Int(EDGE_LEFT))
    assert_equal(d.config.dock_test, String("left"))
    assert_true(d.test_pane.focused)


def test_view_menu_docks_the_focused_panel_and_toggles_auto_hide() raises:
    var d = _two_panes()
    _ = d.dispatch_action(String("view:dock_top"), _WIDE)
    # Nothing focused yet: nothing moves.
    assert_equal(Int(d.debug_pane.dock.edge), Int(EDGE_BOTTOM))
    d._focus_dock(DOCK_TEST_PANE)
    _ = d.dispatch_action(String("view:dock_top"), _WIDE)
    assert_equal(Int(d.test_pane.dock.edge), Int(EDGE_TOP))
    _ = d.dispatch_action(String("view:dock_auto_hide"), _WIDE)
    assert_true(d.test_pane.dock.auto_hide)
    assert_true(d.config.auto_hide_test)
    var state = d.dock_menu_state()
    assert_equal(state[0], Int(EDGE_TOP))
    assert_true(state[1])
    # The editor taking the keyboard leaves it as the menu's panel.
    d._focus_dock(DOCK_NONE)
    assert_equal(d.dock_menu_state()[0], Int(EDGE_TOP))


def test_panels_open_where_their_kind_docks() raises:
    var d = _two_panes()
    d.config.dock_debug = String("right")
    d.config.auto_hide_debug = True
    d.config.dock_test = String("float:top")
    d._adopt_dock_defaults()
    assert_equal(Int(d.debug_pane.dock.edge), Int(EDGE_RIGHT))
    assert_true(d.debug_pane.dock.auto_hide)
    assert_equal(Int(d.test_pane.dock.edge), Int(EDGE_FLOAT))
    assert_equal(Int(d.test_pane.dock.home_edge), Int(EDGE_TOP))


def test_dock_order_parses_to_all_four_edges_once() raises:
    var o = dock_order_edges(String("bottom, top,bogus,top"))
    assert_equal(len(o), 4)
    assert_equal(Int(o[0]), Int(EDGE_BOTTOM))
    assert_equal(Int(o[1]), Int(EDGE_TOP))
    # The ones left out follow in the default order.
    assert_equal(Int(o[2]), Int(EDGE_LEFT))
    assert_equal(Int(o[3]), Int(EDGE_RIGHT))


def test_the_first_edge_in_the_order_takes_its_whole_side() raises:
    var d = _two_panes()
    d.debug_pane.dock.set_edge(EDGE_LEFT)
    # Default order: the left column runs the full height, the bottom
    # stack fits beside it.
    _same(d.debug_pane_rect(_WIDE), Rect(0, 1, 50, 28))
    _same(d.test_pane_rect(_WIDE), Rect(51, 14, 200, 28))
    # Bottom first: the bottom stack runs the full width, the left column
    # stops above it.
    d.config.dock_order = String("bottom,left,right,top")
    _same(d.test_pane_rect(_WIDE), Rect(0, 14, 200, 28))
    _same(d.debug_pane_rect(_WIDE), Rect(0, 1, 50, 14))
    _same(d.workspace_rect(_WIDE), Rect(51, 1, 200, 14))


def test_top_before_the_sides_spans_the_window() raises:
    var d = _two_panes()
    d.debug_pane.dock.set_edge(EDGE_TOP)
    d.test_pane.dock.set_edge(EDGE_RIGHT)
    d.config.dock_order = String("top,left,right,bottom")
    _same(d.debug_pane_rect(_WIDE), Rect(0, 1, 200, 13))
    _same(d.test_pane_rect(_WIDE), Rect(150, 14, 200, 28))


def test_dock_preview_cuts_in_order() raises:
    var regs = dock_preview_regions(String("left,top"), Rect(0, 0, 40, 20))
    assert_equal(len(regs), 5)
    assert_equal(Int(regs[0][0]), Int(EDGE_LEFT))
    _same(regs[0][1], Rect(0, 0, 10, 20))
    assert_equal(Int(regs[1][0]), Int(EDGE_TOP))
    _same(regs[1][1], Rect(10, 0, 40, 5))
    assert_equal(Int(regs[4][0]), Int(DOCK_PREVIEW_EDITOR))


def test_settings_panels_page_reorders_and_docks() raises:
    var st = Settings()
    st.open(Desktop().config)
    st.section = SECTION_PANELS
    st.ui_set(String("dock_order"), String("3"))
    st.ui_act(String("dock_up"))
    assert_equal(st.cfg.dock_order, String("left,right,bottom,top"))
    assert_equal(st.dock_order_sel, 2)
    st.ui_set(String("dock_test"), String("2"))
    assert_equal(st.cfg.dock_test, String("left"))
    st.ui_set(String("auto_hide_test"), String("1"))
    assert_true(st.cfg.auto_hide_test)
    assert_true(st.dirty)
    # The grid draws the page, preview and all.
    var form = GridForm()
    var c = Canvas(100, 40)
    c.fill(Rect(0, 0, 100, 40), String(" "), default_attr())
    form.paint(st.ui(), c, Rect(0, 0, 100, 40))
    var found = False
    for y in range(40):
        var row = String("")
        for x in range(100):
            row += c.get(x, y).glyph
        if String("Editor") in row:
            found = True
    assert_true(found)


def test_settings_dock_changes_move_the_open_panels() raises:
    var d = _two_panes()
    d.settings.open(d.config)
    d.settings.ui_set(String("dock_test"), String("3"))
    d._sync_settings()
    assert_equal(d.config.dock_test, String("right"))
    assert_equal(Int(d.test_pane.dock.edge), Int(EDGE_RIGHT))


def main() raises:
    setup_test_env()
    TestSuite.discover_tests[__functions_in_module()]().run()
