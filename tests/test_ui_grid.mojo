"""Declarative UI (``ui_tree.mojo``) through the grid projector
(``ui_grid.mojo``): the shared layout rules, focus and keys, and the dialogs
built on it end to end through Desktop."""

from std.testing import TestSuite, assert_equal, assert_false, assert_true
from turbokod.canvas import Canvas
from turbokod.colors import default_attr
from turbokod.desktop import Desktop
from turbokod.events import (
    Event, KEY_BACKSPACE, KEY_ENTER, KEY_ESC, KEY_SPACE, KEY_TAB,
)
from turbokod.geometry import Rect
from turbokod.ui_grid import GridForm, UIEvent
from turbokod.ui_tree import (
    UI_CANCEL, UI_DEFAULT, UINode, ui_button, ui_buttons, ui_check,
    ui_dialog, ui_form, ui_label, ui_row, ui_table, ui_text, ui_vstack,
)
from turbokod.window import Window
from support import _SCREEN, setup_test_env


def _paint(mut form: GridForm, root: UINode) -> Canvas:
    var canvas = Canvas(_SCREEN.b.x, _SCREEN.b.y)
    canvas.clear(default_attr())
    form.paint(root, canvas, _SCREEN)
    return canvas^


def _row_text(c: Canvas, y: Int) -> String:
    var s = String("")
    for x in range(c.width):
        s += c.get(x, y).glyph
    return s^


def _find(c: Canvas, needle: String) -> Tuple[Int, Int]:
    """(x, y) of ``needle``'s first cell, or (-1, -1)."""
    for y in range(c.height):
        var row = _row_text(c, y)
        var at = row.find(needle)
        if at >= 0:
            # ``find`` is a byte offset; rows here are ASCII up to the needle.
            return (at, y)
    return (-1, -1)


def _demo() -> UINode:
    var rows = List[UINode]()
    rows.append(ui_row(String("Name"), ui_text(String("name"), String("ada"))))
    rows.append(ui_row(String("Working directory"), ui_text(String("cwd"), String(""))))
    rows.append(ui_row(String(""), ui_check(String("on"), String("Enabled"), False)))
    var buttons = List[UINode]()
    buttons.append(ui_button(String("cancel"), String("Cancel"), UI_CANCEL))
    buttons.append(ui_button(String("ok"), String("Save"), UI_DEFAULT))
    var body = List[UINode]()
    body.append(ui_form(rows^))
    body.append(ui_buttons(buttons^))
    return ui_dialog(String("Demo"), String("cancel"), ui_vstack(body^))


def test_form_labels_are_right_aligned_and_controls_share_an_edge() raises:
    var form = GridForm()
    var c = _paint(form, _demo())
    var name = _find(c, String("Name:"))
    var cwd = _find(c, String("Working directory:"))
    assert_true(name[1] >= 0 and cwd[1] >= 0)
    # Right-aligned: both labels end in the same column.
    assert_equal(name[0] + 5, cwd[0] + 18)
    # The title sits on the frame's top border.
    assert_true(_find(c, String(" Demo "))[1] < name[1])


def test_tab_walks_focus_and_typing_reports_edits() raises:
    var form = GridForm()
    var root = _demo()
    _ = _paint(form, root)
    assert_equal(form.focus_key, String("name"))   # first focusable
    var evs = form.handle_event(root, Event.key_event(UInt32(ord("x"))), _SCREEN)
    assert_equal(len(evs), 1)
    assert_false(evs[0].is_action)
    assert_equal(evs[0].key, String("name"))
    assert_equal(evs[0].value, String("adax"))
    _ = form.handle_event(root, Event.key_event(KEY_TAB), _SCREEN)
    assert_equal(form.focus_key, String("cwd"))
    _ = form.handle_event(root, Event.key_event(KEY_TAB), _SCREEN)
    assert_equal(form.focus_key, String("on"))
    evs = form.handle_event(root, Event.key_event(KEY_SPACE), _SCREEN)
    assert_equal(evs[0].key, String("on"))
    assert_equal(evs[0].value, String("1"))


def test_enter_in_a_field_runs_the_default_and_esc_cancels() raises:
    var form = GridForm()
    var root = _demo()
    _ = _paint(form, root)
    var evs = form.handle_event(root, Event.key_event(KEY_ENTER), _SCREEN)
    assert_true(evs[0].is_action)
    assert_equal(evs[0].key, String("ok"))
    evs = form.handle_event(root, Event.key_event(KEY_ESC), _SCREEN)
    assert_equal(evs[0].key, String("cancel"))


def _editor_desktop() -> Desktop:
    var d = Desktop()
    d.windows.add(Window.editor_window(String("buf"), Rect(0, 1, 60, 20), String("a\nb\nc\n")))
    return d^


def test_fill_dialog_end_to_end_through_the_grid() raises:
    var d = _editor_desktop()
    d.fill_dialog.open(3)
    var canvas = Canvas(_SCREEN.b.x, _SCREEN.b.y)
    canvas.clear(default_attr())
    d.paint(canvas, _SCREEN)
    assert_true(_find(canvas, String("Fill 3 cursors"))[1] >= 0)
    assert_true(_find(canvas, String("Initial number:"))[1] >= 0)
    # Focus starts on the mode choice; Tab skips the disabled text field.
    _ = d.handle_event(Event.key_event(KEY_TAB), _SCREEN)
    assert_equal(d.ui_grids[len(d.ui_grids) - 1].focus_key, String("initial"))
    _ = d.handle_event(Event.key_event(KEY_BACKSPACE), _SCREEN)
    _ = d.handle_event(Event.key_event(UInt32(ord("5"))), _SCREEN)
    assert_equal(d.fill_dialog.initial, String("5"))
    _ = d.handle_event(Event.key_event(KEY_ENTER), _SCREEN)
    assert_false(d.fill_dialog.active)   # filled and closed


def test_fill_dialog_refuses_a_bad_number_with_a_message() raises:
    var d = _editor_desktop()
    d.fill_dialog.open(2)
    var canvas = Canvas(_SCREEN.b.x, _SCREEN.b.y)
    canvas.clear(default_attr())
    d.paint(canvas, _SCREEN)
    _ = d.handle_event(Event.key_event(KEY_TAB), _SCREEN)
    _ = d.handle_event(Event.key_event(KEY_BACKSPACE), _SCREEN)
    _ = d.handle_event(Event.key_event(UInt32(ord("x"))), _SCREEN)
    _ = d.handle_event(Event.key_event(KEY_ENTER), _SCREEN)
    assert_true(d.fill_dialog.active)
    canvas.clear(default_attr())
    d.paint(canvas, _SCREEN)
    assert_true(_find(canvas, String("whole number"))[1] >= 0)


def test_breakpoint_dialog_end_to_end_through_the_grid() raises:
    var d = Desktop()
    d.breakpoint_menu.open(
        String("/p/a.py"), 9, True, String(""), String(""),
        [String("/p/b.py:3")],
    )
    var canvas = Canvas(_SCREEN.b.x, _SCREEN.b.y)
    canvas.clear(default_attr())
    d.paint(canvas, _SCREEN)
    assert_true(_find(canvas, String("a.py:10"))[1] >= 0)
    # enabled → wait_for → condition.
    _ = d.handle_event(Event.key_event(KEY_TAB), _SCREEN)
    _ = d.handle_event(Event.key_event(KEY_TAB), _SCREEN)
    assert_equal(d.ui_grids[len(d.ui_grids) - 1].focus_key, String("condition"))
    _ = d.handle_event(Event.key_event(UInt32(ord("x"))), _SCREEN)
    assert_equal(d.breakpoint_menu.condition, String("x"))
    assert_equal(d.breakpoint_menu.result().condition, String("x"))



def test_scrolled_table_paints_the_rows_in_view() raises:
    """A table scrolled to a selection far down paints the rows around it
    — not the first rows with the highlight moved onto one of them."""
    var rows = List[List[String]]()
    for i in range(40):
        rows.append([String("row") + String(i)])
    var body = List[UINode]()
    body.append(ui_table(String("t"), [String("Name")], rows^, 30, String(""), 5))
    var root = ui_dialog(String("T"), String("cancel"), ui_vstack(body^))
    var form = GridForm()
    var c = _paint(form, root)
    assert_true(_find(c, String("row30"))[1] >= 0)
    assert_equal(_find(c, String("row0 "))[1], -1)


def test_long_label_stays_inside_the_dialog() raises:
    """A label wider than the screen is cut with an ellipsis rather than
    painting over the dialog's border."""
    var body = List[UINode]()
    body.append(ui_label(String("x") * 300))
    var root = ui_dialog(String("T"), String("cancel"), ui_vstack(body^))
    var form = GridForm()
    var c = _paint(form, root)
    var at = _find(c, String("…"))
    assert_true(at[1] >= 0)
    assert_true(at[0] < form.frame().b.x - 1)

def main() raises:
    setup_test_env()
    TestSuite.discover_tests[__functions_in_module()]().run()
