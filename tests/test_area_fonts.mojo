"""Per-area fonts: code, terminal-like panes, debugger and UI each draw
their cells in a font slot, which the native host maps to a face.

Shared fixtures live in ``tests/support.mojo`` and
``scripts/run_tests.sh`` runs every suite.
"""

from std.testing import TestSuite, assert_equal, assert_true
from turbokod.canvas import Canvas, SCALE_ONE
from turbokod.cell import Cell, FONT_CODE, FONT_DEBUGGER, FONT_TERMINAL, FONT_UI
from turbokod.colors import default_attr
from turbokod.config import (
    AREA_BUNDLED_FONT, CHICAGO_FONT, TurbokodConfig, _config_from_json,
    _config_to_json, chicago_font_label, default_font_label, same_as_font_label,
)
from turbokod.debug_pane import DebugPane
from turbokod.desktop import Desktop
from turbokod.grid_frame import GridFrame
from turbokod.events import Event, MOUSE_BUTTON_LEFT
from turbokod.geometry import Point, Rect
from turbokod.json import parse_json
from turbokod.host_abi import CELL_WORDS, pack_canvas
from turbokod.settings import Settings
from turbokod.terminal_pane import TerminalPane
from turbokod.ui_tree import UINode
from turbokod.window import Window

from support import setup_test_env


def test_canvas_stamps_its_font_slot_on_what_it_writes() raises:
    var c = Canvas(10, 2)
    c.font = FONT_CODE
    _ = c.put_text(Point(0, 0), String("ab"), default_attr())
    c.set(5, 0, Cell(String("x"), default_attr(), 1))
    c.fill(Rect(0, 1, 2, 2), String("-"), default_attr())
    c.font = FONT_UI
    _ = c.put_text(Point(2, 0), String("c"), default_attr())
    assert_equal(Int(c.get(0, 0).font), Int(FONT_CODE))
    assert_equal(Int(c.get(1, 0).font), Int(FONT_CODE))
    assert_equal(Int(c.get(5, 0).font), Int(FONT_CODE))
    assert_equal(Int(c.get(0, 1).font), Int(FONT_CODE))
    assert_equal(Int(c.get(2, 0).font), Int(FONT_UI))
    # Recoloring keeps the slot of the glyph underneath.
    c.set_attr(0, 0, default_attr())
    c.darken_rect(Rect(1, 0, 2, 1))
    assert_equal(Int(c.get(0, 0).font), Int(FONT_CODE))
    assert_equal(Int(c.get(1, 0).font), Int(FONT_CODE))


def test_pack_canvas_carries_the_slot_beside_codepoint_and_width() raises:
    var c = Canvas(3, 1)
    c.font = FONT_DEBUGGER
    _ = c.put_text(Point(0, 0), String("é"), default_attr())
    var buf = List[UInt32](length=3 * CELL_WORDS, fill=UInt32(0))
    _ = pack_canvas(c, 3, 1, Int(buf.unsafe_ptr()), 3)
    assert_equal(Int(buf[0] & 0x1FFFFF), 0xE9)
    assert_equal(Int((buf[0] >> 21) & 0x7), Int(FONT_DEBUGGER))
    assert_equal(Int(buf[0] >> 24), 1)


def test_editor_text_paints_in_the_code_slot_inside_a_ui_frame() raises:
    var w = Window.editor_window(
        String("t"), Rect(0, 0, 20, 6), String("hello"),
    )
    var c = Canvas(20, 6)
    w.paint(c, String("t"), True, 1)
    assert_equal(Int(c.get(0, 0).font), Int(FONT_UI))   # border
    var interior = w.interior()
    var found = False
    for x in range(interior.a.x, interior.b.x):
        if c.get(x, interior.a.y).glyph == String("h"):
            assert_equal(Int(c.get(x, interior.a.y).font), Int(FONT_CODE))
            found = True
    assert_true(found)
    assert_equal(Int(c.font), Int(FONT_UI))   # restored


def test_area_fonts_round_trip_and_default_to_the_font() raises:
    var cfg = TurbokodConfig()
    cfg.font = String("Menlo")
    cfg.area_fonts[Int(FONT_TERMINAL)] = String(AREA_BUNDLED_FONT)
    var back = _config_from_json(_config_to_json(cfg))
    assert_equal(back.area_fonts[Int(FONT_TERMINAL)], String(AREA_BUNDLED_FONT))
    assert_equal(back.area_fonts[Int(FONT_DEBUGGER)], String(""))
    var d = Desktop()
    d.config = back.copy()
    assert_equal(d.area_font(Int(FONT_CODE)), String("Menlo"))   # the Font
    assert_equal(d.area_font(Int(FONT_TERMINAL)), String(""))   # bundled VGA
    assert_equal(d.area_font(Int(FONT_DEBUGGER)), String("Menlo"))
    assert_equal(d.area_font_label(Int(FONT_TERMINAL)), default_font_label())
    assert_equal(d.area_font_label(Int(FONT_DEBUGGER)), same_as_font_label())
    var v = d.font_version
    d.set_area_font(Int(FONT_DEBUGGER), chicago_font_label())
    assert_equal(d.config.area_fonts[Int(FONT_DEBUGGER)], String(CHICAGO_FONT))
    assert_true(d.font_version > v)
    d.set_area_font(Int(FONT_DEBUGGER), same_as_font_label())
    assert_equal(d.config.area_fonts[Int(FONT_DEBUGGER)], String(""))
    d.shutdown()


def test_the_retired_classic_font_reads_as_the_vga_font() raises:
    var cfg = _config_from_json(parse_json(String(
        '{"font": "Px437 IBM VGA 8x16", "font_terminal": "Px437 IBM VGA 8x16"}'
    )))
    assert_equal(cfg.font, String(""))
    assert_equal(cfg.area_fonts[Int(FONT_TERMINAL)], String(AREA_BUNDLED_FONT))


def test_turbo_vision_look_draws_its_ui_in_the_vga_font_at_its_ideal_size() raises:
    var d = Desktop()
    d.host_owns_menu = True             # the native app, Turbo Vision look
    d.config.font = String("Menlo")
    d.config.font_size = 20
    d.config.area_fonts[Int(FONT_UI)] = String("Monaco")
    assert_equal(d.cell_font(), String(""))
    assert_equal(d.cell_font_size(), 0)
    assert_equal(d.area_font(Int(FONT_UI)), String(""))
    assert_equal(d.area_font(Int(FONT_CODE)), String("Menlo"))
    d.config.native_ui = True           # the macOS look: the Font sets the cell
    assert_equal(d.cell_font(), String("Menlo"))
    assert_equal(d.cell_font_size(), 20)
    assert_equal(d.area_font(Int(FONT_UI)), String("Monaco"))
    d.shutdown()


def test_settings_chooses_fonts_by_searching() raises:
    var s = Settings()
    s.offer_native_ui = True
    var names = List[String]()
    names.append(default_font_label())
    names.append(String("Menlo"))
    names.append(String("Monaco"))
    names.append(String("Helvetica"))
    s._font_names = names^
    # Turbo Vision look: no size, no UI font.
    assert_true(_has_key(s._appearance_ui(), String("pick_font_2")))
    assert_true(not _has_key(s._appearance_ui(), String("pick_font_0")))
    assert_true(not _has_key(s._appearance_ui(), String("font_larger")))
    s.native_ui = True
    assert_true(_has_key(s._appearance_ui(), String("pick_font_0")))
    assert_true(_has_key(s._appearance_ui(), String("font_larger")))
    s.ui_act(String("pick_font_2"))
    assert_true(s.font_chooser.active)
    assert_equal(len(s.font_chooser.matched), 5)    # "Same as Font" + 4
    s.font_chooser.ui_set(String("query"), String("mon"))
    assert_equal(len(s.font_chooser.matched), 1)    # Monaco, any case
    s.font_chooser.ui_act(String("choose"))
    s.consume_font_chooser()
    assert_true(not s.font_chooser.active)
    assert_equal(s.area_font_choices[2], String("Monaco"))
    assert_true(s.dirty)
    s.ui_act(String("pick_font"))
    s.font_chooser.ui_set(String("query"), String("helv"))
    s.font_chooser.ui_act(String("choose"))
    s.consume_font_chooser()
    assert_equal(s.font_choice, String("Helvetica"))


def _half_size_terminal(mut c: Canvas):
    """A terminal font whose cells are half the screen's each way."""
    c.area_scale[2 * Int(FONT_TERMINAL)] = 500
    c.area_scale[2 * Int(FONT_TERMINAL) + 1] = 500


def test_a_grid_at_the_screens_cell_size_is_copied_in() raises:
    var c = Canvas(10, 4)
    var g = Canvas(3, 2)
    g.font = FONT_TERMINAL
    _ = g.put_text(Point(0, 1), String("abc"), default_attr())
    assert_equal(c.sub_grid_size(FONT_TERMINAL, Rect(2, 1, 5, 3))[0], 3)
    c.place_sub_grid(FONT_TERMINAL, Rect(2, 1, 5, 3), g^)
    assert_equal(len(c.sub_grids), 0)
    assert_equal(c.get(2, 2).glyph, String("a"))
    assert_equal(c.get(4, 2).glyph, String("c"))
    assert_equal(Int(c.get(2, 2).font), Int(FONT_TERMINAL))
    assert_equal(Int(c.get(2, 2).sub), 0)


def test_an_area_with_a_size_of_its_own_gets_a_sub_grid() raises:
    var c = Canvas(10, 4)
    _half_size_terminal(c)
    var r = Rect(1, 1, 6, 3)
    var dims = c.sub_grid_size(FONT_TERMINAL, r)
    assert_equal(dims[0], 10)    # twice as many, half the size
    assert_equal(dims[1], 4)
    assert_equal(c.sub_grid_size(FONT_CODE, r)[0], 5)
    var g = Canvas(dims[0], dims[1])
    _ = g.put_text(Point(9, 3), String("z"), default_attr())
    c.place_sub_grid(FONT_TERMINAL, r, g^)
    assert_equal(len(c.sub_grids), 1)
    assert_equal(c.sub_grids[0].cols, 10)
    assert_equal(c.sub_grids[0].cells[3 * 10 + 9].glyph, String("z"))
    assert_equal(Int(c.get(1, 1).sub), 1)
    assert_equal(Int(c.get(5, 2).sub), 1)
    assert_equal(Int(c.get(6, 2).sub), 0)
    # Whatever is painted over it later (a popup) stays on top.
    c.set(2, 1, Cell(String("x"), default_attr(), 1))
    assert_equal(Int(c.get(2, 1).sub), 0)
    var buf = List[UInt32](length=10 * 4 * CELL_WORDS, fill=UInt32(0))
    _ = pack_canvas(c, 10, 4, Int(buf.unsafe_ptr()), 40)
    var w0 = buf[(1 * 10 + 1) * CELL_WORDS]
    assert_equal(Int((w0 >> 26) & 0x3F), 1)
    assert_equal(Int((w0 >> 24) & 0x3), 1)
    c.clear()
    assert_equal(len(c.sub_grids), 0)


def test_a_terminal_pane_lays_out_its_grid_in_the_terminal_fonts_cells() raises:
    var pane = TerminalPane()
    pane.visible = True
    var panel = Rect(0, 0, 40, 12)
    var c = Canvas(40, 12)
    _half_size_terminal(c)
    pane.paint(c, panel)
    assert_equal(len(c.sub_grids), 1)
    var g = c.sub_grids[0].copy()
    assert_equal(pane.vt.cols(), g.cols)
    assert_equal(pane.vt.rows(), g.rows)
    assert_equal(g.cols, 2 * g.rect.width())
    assert_equal(g.rows, 2 * g.rect.height())
    # A click two-thirds into a screen cell is in that cell's second grid
    # column; the selection starts there.
    var at = Point(g.rect.a.x + 1, g.rect.a.y + 1)
    var e = Event.mouse_event(at, MOUSE_BUTTON_LEFT, True, False, 0, 1)
    e.fine = Point(at.x * 1000 + 700, at.y * 1000 + 200)
    assert_true(pane.handle_mouse(e, panel))
    assert_equal(pane.sel.sel_anchor_c, 3)
    var ge = pane.sel.grid_event(e)
    assert_equal(ge.pos.x, g.rect.a.x + 3)
    assert_equal(ge.pos.y, g.rect.a.y + 2)
    # A pos rewritten without its fine position maps from the cell's middle.
    var moved = e
    moved.pos = Point(at.x + 1, at.y)
    assert_equal(pane.sel.grid_event(moved).pos.x, g.rect.a.x + 5)


def test_a_grid_frame_paints_and_maps_in_its_own_coordinates() raises:
    var c = Canvas(20, 10)
    _half_size_terminal(c)
    var f = GridFrame.empty(FONT_TERMINAL)
    var g = f.begin(c, Rect(4, 2, 8, 5), default_attr())
    assert_true(f.grid == Rect(4, 2, 12, 8))    # 8 x 6 cells from (4, 2)
    _ = g.put_text(Point(11, 7), String("q"), default_attr())
    f.end(c, g^)
    assert_equal(c.sub_grids[0].cells[5 * 8 + 7].glyph, String("q"))
    var e = Event.mouse_event(Point(5, 3), MOUSE_BUTTON_LEFT)
    e.fine = Point(5900, 3100)
    assert_true(f.map(e).pos == Point(4 + 3, 2 + 2))
    assert_true(f.contains(e))


def test_the_debug_panes_log_wraps_to_the_terminal_fonts_grid() raises:
    var pane = DebugPane()
    pane.visible = True
    var line = String("")
    for i in range(110):
        line += String(i % 10)
    pane.append_output(line + String("\n"))
    var c = Canvas(80, 20)
    pane.paint(c, Rect(0, 0, 80, 20))
    var narrow = len(pane.output.last_visual)
    var h = Canvas(80, 20)
    _half_size_terminal(h)
    pane.paint(h, Rect(0, 0, 80, 20))
    assert_equal(len(h.sub_grids), 1)
    assert_equal(Int(h.sub_grids[0].slot), Int(FONT_TERMINAL))
    assert_equal(narrow, 2)
    assert_equal(len(pane.output.last_visual), 1)


def test_area_font_sizes_round_trip_clamped() raises:
    var cfg = TurbokodConfig()
    cfg.area_font_sizes[Int(FONT_TERMINAL)] = 12
    cfg.area_font_sizes[Int(FONT_DEBUGGER)] = 2
    var back = _config_from_json(_config_to_json(cfg))
    assert_equal(back.area_font_sizes[Int(FONT_TERMINAL)], 12)
    assert_equal(back.area_font_sizes[Int(FONT_DEBUGGER)], 6)
    assert_equal(back.area_font_sizes[Int(FONT_UI)], 0)
    var d = Desktop()
    d.config = back.copy()
    assert_equal(d.area_font_size(Int(FONT_TERMINAL)), 12)
    assert_equal(d.area_font_size(Int(FONT_CODE)), 0)
    var v = d.font_version
    d.set_area_font_size(Int(FONT_TERMINAL), 0)
    assert_equal(d.config.area_font_sizes[Int(FONT_TERMINAL)], 0)
    assert_true(d.font_version > v)
    d.shutdown()


def test_settings_steps_an_areas_font_size_from_the_fonts() raises:
    var s = Settings()
    s.offer_native_ui = True
    var names = List[String]()
    names.append(default_font_label())
    s._font_names = names^
    assert_true(_has_key(s._appearance_ui(), String("area_larger_2")))
    assert_true(_has_key(s._appearance_ui(), String("area_larger_3")))
    s._font_effective_size = 16
    s.ui_act(String("area_smaller_2"))
    assert_equal(s.area_font_sizes[2], 15)
    assert_true(s.dirty)
    s.ui_act(String("area_larger_2"))
    s.ui_act(String("area_larger_2"))
    assert_equal(s.area_font_sizes[2], 17)
    s.ui_act(String("area_same_2"))
    assert_equal(s.area_font_sizes[2], 0)


def _has_key(n: UINode, key: String) -> Bool:
    if n.key == key:
        return True
    for i in range(len(n.children)):
        if _has_key(n.children[i], key):
            return True
    return False


def main() raises:
    setup_test_env()
    TestSuite.discover_tests[__functions_in_module()]().run()
