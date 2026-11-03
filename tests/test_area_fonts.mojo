"""Per-area fonts: code, terminal-like panes, debugger and UI each draw
their cells in a font slot, which the native host maps to a face.

Shared fixtures live in ``tests/support.mojo`` and
``scripts/run_tests.sh`` runs every suite.
"""

from std.testing import TestSuite, assert_equal, assert_true
from turbokod.canvas import Canvas
from turbokod.cell import Cell, FONT_CODE, FONT_DEBUGGER, FONT_TERMINAL, FONT_UI
from turbokod.colors import default_attr
from turbokod.config import (
    AREA_BUNDLED_FONT, CHICAGO_FONT, TurbokodConfig, _config_from_json,
    _config_to_json, chicago_font_label, default_font_label, same_as_font_label,
)
from turbokod.desktop import Desktop
from turbokod.geometry import Point, Rect
from turbokod.json import parse_json
from turbokod.host_abi import CELL_WORDS, pack_canvas
from turbokod.settings import Settings
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
