"""``Editor.apply_text_edits``: language-server edits (formatting, code
actions, auto-imports) must land exactly where and in the order the server
says."""

from std.testing import TestSuite, assert_equal, assert_false, assert_true
from turbokod.editor import Editor
from turbokod.events import Event
from turbokod.geometry import Rect
from turbokod.lsp_dispatch import TextEditEntry
from support import setup_test_env


def _edit(sl: Int, sc: Int, el: Int, ec: Int, text: String) -> TextEditEntry:
    return TextEditEntry(sl, sc, el, ec, text)


def test_inserts_at_the_same_place_keep_their_order() raises:
    # LSP: "if multiple inserts have the same position, the order in the
    # array defines the order in which the inserted strings appear"
    var ed = Editor(String("x\ny"))
    var edits = List[TextEditEntry]()
    edits.append(_edit(0, 0, 0, 0, "import a\n"))
    edits.append(_edit(0, 0, 0, 0, "import b\n"))
    assert_true(ed.apply_text_edits(edits^))
    assert_equal(ed.text_snapshot(), String("import a\nimport b\nx\ny"))


def test_edits_in_any_order_land_where_they_say() raises:
    var ed = Editor(String("one two three\nfour"))
    var edits = List[TextEditEntry]()
    edits.append(_edit(0, 4, 0, 7, "TWO"))
    edits.append(_edit(1, 0, 1, 4, "FOUR"))
    edits.append(_edit(0, 0, 0, 3, "ONE"))
    assert_true(ed.apply_text_edits(edits^))
    assert_equal(ed.text_snapshot(), String("ONE TWO three\nFOUR"))


def test_an_edit_across_lines() raises:
    var ed = Editor(String("a\nb\nc"))
    var edits = List[TextEditEntry]()
    edits.append(_edit(0, 1, 2, 0, "-"))
    assert_true(ed.apply_text_edits(edits^))
    assert_equal(ed.text_snapshot(), String("a-c"))


def test_an_edit_in_a_one_line_buffer() raises:
    var ed = Editor(String("abc"))
    var edits = List[TextEditEntry]()
    edits.append(_edit(0, 1, 0, 2, "X"))
    assert_true(ed.apply_text_edits(edits^))
    assert_equal(ed.text_snapshot(), String("aXc"))


def test_a_multi_line_edit_ending_left_of_where_it_starts() raises:
    var ed = Editor(String("hello\nab cd"))
    var edits = List[TextEditEntry]()
    edits.append(_edit(0, 3, 1, 1, ""))
    assert_true(ed.apply_text_edits(edits^))
    assert_equal(ed.text_snapshot(), String("helb cd"))


def test_an_end_past_the_buffer_is_its_end() raises:
    var ed = Editor(String("a\nb\nc"))
    var edits = List[TextEditEntry]()
    edits.append(_edit(0, 1, 99, 0, "!"))
    assert_true(ed.apply_text_edits(edits^))
    assert_equal(ed.text_snapshot(), String("a!"))


def test_an_insert_past_the_last_line_is_appended_not_dropped() raises:
    # a server appending to a file without a final newline
    var ed = Editor(String("x = 1"))
    var edits = List[TextEditEntry]()
    edits.append(_edit(1, 0, 1, 0, "\ny = 2\n"))
    assert_true(ed.apply_text_edits(edits^))
    assert_equal(ed.text_snapshot(), String("x = 1\ny = 2\n"))


def test_inserted_lines_go_in_order_and_keep_the_rest() raises:
    var ed = Editor(String("first\nlast"))
    var edits = List[TextEditEntry]()
    edits.append(_edit(0, 5, 0, 5, "\ntwo\nthree"))
    assert_true(ed.apply_text_edits(edits^))
    assert_equal(ed.text_snapshot(), String("first\ntwo\nthree\nlast"))


def test_several_edits_on_a_line_that_change_its_length() raises:
    # applied in the wrong order, the later ones land on stale columns
    var ed = Editor(String("one two three"))
    var edits = List[TextEditEntry]()
    edits.append(_edit(0, 0, 0, 3, "1"))
    edits.append(_edit(0, 4, 0, 7, "second"))
    edits.append(_edit(0, 8, 0, 13, "3"))
    assert_true(ed.apply_text_edits(edits^))
    assert_equal(ed.text_snapshot(), String("1 second 3"))


def test_edits_given_last_first_and_across_lines() raises:
    var ed = Editor(String("one two three\nab"))
    var edits = List[TextEditEntry]()
    edits.append(_edit(1, 1, 1, 2, "B"))
    edits.append(_edit(0, 8, 0, 13, "3"))
    edits.append(_edit(0, 4, 0, 7, "second"))
    edits.append(_edit(0, 0, 0, 3, "1"))
    assert_true(ed.apply_text_edits(edits^))
    assert_equal(ed.text_snapshot(), String("1 second 3\naB"))
    # four on one line, last first: the sort has to move each to the front
    var ed4 = Editor(String("a b c d"))
    var edits4 = List[TextEditEntry]()
    edits4.append(_edit(0, 6, 0, 7, "DDDD"))
    edits4.append(_edit(0, 4, 0, 5, "CCC"))
    edits4.append(_edit(0, 2, 0, 3, "BB"))
    edits4.append(_edit(0, 0, 0, 1, ""))
    assert_true(ed4.apply_text_edits(edits4^))
    assert_equal(ed4.text_snapshot(), String(" BB CCC DDDD"))
    # a later line at a smaller column than an earlier one
    var ed2 = Editor(String("abcdef\nxy"))
    var edits2 = List[TextEditEntry]()
    edits2.append(_edit(0, 5, 0, 6, "F!"))
    edits2.append(_edit(1, 0, 1, 1, "X!"))
    assert_true(ed2.apply_text_edits(edits2^))
    assert_equal(ed2.text_snapshot(), String("abcdeF!\nX!y"))


def test_a_new_line_at_the_start_of_the_text_is_a_line() raises:
    var ed = Editor(String("ab"))
    var edits = List[TextEditEntry]()
    edits.append(_edit(0, 1, 0, 1, "\nX"))
    assert_true(ed.apply_text_edits(edits^))
    assert_equal(ed.buffer.line_count(), 2)
    assert_equal(ed.buffer.line(1), String("Xb"))


def test_an_edit_before_the_first_line_is_ignored() raises:
    var ed = Editor(String("ab\ncd"))
    ed.selections[0].row = 1
    ed.selections[0].col = 1
    ed.selections[0].anchor_row = 1
    ed.selections[0].anchor_col = 1
    var edits = List[TextEditEntry]()
    edits.append(_edit(-1, 0, -1, 0, "X\n"))
    _ = ed.apply_text_edits(edits^)
    assert_equal(ed.text_snapshot(), String("ab\ncd"))
    assert_equal(ed.selections[0].row, 1)
    assert_equal(ed.selections[0].col, 1)


def test_edits_that_add_lines_above_others() raises:
    var ed = Editor(String("x\ny\nz"))
    var edits = List[TextEditEntry]()
    edits.append(_edit(0, 0, 0, 0, "a\nb\n"))
    edits.append(_edit(1, 0, 1, 1, "Y"))
    edits.append(_edit(2, 0, 2, 1, "Z"))
    assert_true(ed.apply_text_edits(edits^))
    assert_equal(ed.text_snapshot(), String("a\nb\nx\nY\nZ"))


def test_the_caret_and_its_anchor_move_with_the_text() raises:
    var ed = Editor(String("aa\nbb\ncc"))
    ed.selections[0].row = 2
    ed.selections[0].col = 2
    ed.selections[0].anchor_row = 2
    ed.selections[0].anchor_col = 1
    var edits = List[TextEditEntry]()
    edits.append(_edit(0, 0, 0, 0, "new\n"))
    edits.append(_edit(2, 0, 2, 0, "XY"))
    assert_true(ed.apply_text_edits(edits^))
    assert_equal(ed.text_snapshot(), String("new\naa\nbb\nXYcc"))
    assert_equal(ed.selections[0].row, 3)
    assert_equal(ed.selections[0].col, 4)
    assert_equal(ed.selections[0].anchor_row, 3)
    assert_equal(ed.selections[0].anchor_col, 3)


def test_a_read_only_buffer_isnt_edited() raises:
    var ed = Editor(String("abc"))
    ed.read_only = True
    var edits = List[TextEditEntry]()
    edits.append(_edit(0, 0, 0, 1, "X"))
    assert_false(ed.apply_text_edits(edits^))
    assert_equal(ed.text_snapshot(), String("abc"))
    assert_false(ed.apply_text_edits(List[TextEditEntry]()))


def test_typing_after_edits_is_its_own_undo_step() raises:
    var ed = Editor(String("abc"))
    var view = Rect(0, 0, 80, 24)
    ed.selections[0].col = 3
    ed.selections[0].anchor_col = 3
    _ = ed.handle_key(Event.key_event(UInt32(ord("x"))), view)
    var edits = List[TextEditEntry]()
    edits.append(_edit(0, 0, 0, 1, "A"))
    assert_true(ed.apply_text_edits(edits^))
    _ = ed.handle_key(Event.key_event(UInt32(ord("y"))), view)
    assert_equal(ed.text_snapshot(), String("Abcxy"))
    _ = ed.undo()
    assert_equal(ed.text_snapshot(), String("Abcx"))
    _ = ed.undo()
    assert_equal(ed.text_snapshot(), String("abcx"))


def main() raises:
    setup_test_env()
    TestSuite.discover_tests[__functions_in_module()]().run()
