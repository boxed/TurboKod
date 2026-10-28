"""``Editor.apply_text_edits``: language-server edits (formatting, code
actions, auto-imports) must land exactly where and in the order the server
says."""

from std.testing import TestSuite, assert_equal, assert_false, assert_true
from turbokod.editor import Caret, Editor
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


def test_a_formatters_many_edits_to_a_long_file() raises:
    # every 10th line split after 4 bytes, the line after it dropped, and
    # two lines put in front of every 10th + 5
    var text = String("")
    var want = String("")
    var edits = List[TextEditEntry]()
    for i in range(2000):
        var line = String("line ") + String(i)
        if i > 0:
            text += "\n"
        text += line
        if i % 10 == 0:
            want += "line\n" + String(i) + "\n"
            edits.append(_edit(i, 4, i, 5, "\n"))
        elif i % 10 == 1:
            edits.append(_edit(i, 0, i + 1, 0, ""))
        elif i % 10 == 5:
            want += "a\nb\n" + line + "\n"
            edits.append(_edit(i, 0, i, 0, "a\nb\n"))
        else:
            want += line + "\n"
    var ed = Editor(text)
    assert_true(ed.apply_text_edits(edits^))
    assert_equal(ed.text_snapshot(), String(want[byte=0:want.byte_length() - 1]))


def test_an_edit_inside_a_character_starts_at_its_start() raises:
    # a stale or wrong column must not split "é" into invalid UTF-8
    var ed = Editor(String("aéb\ncd"))
    var edits = List[TextEditEntry]()
    edits.append(_edit(0, 2, 0, 2, "X"))
    assert_true(ed.apply_text_edits(edits^))
    assert_equal(ed.text_snapshot(), String("aXéb\ncd"))
    var ed2 = Editor(String("aéb\ncd"))
    var edits2 = List[TextEditEntry]()
    edits2.append(_edit(0, 0, 0, 2, ""))
    edits2.append(_edit(1, 0, 1, 1, "é"))
    assert_true(ed2.apply_text_edits(edits2^))
    assert_equal(ed2.text_snapshot(), String("éb\néd"))


def _rand(mut seed: Int, n: Int) -> Int:
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed % n


def _random_text(mut seed: Int) -> String:
    """A few short lines from a small alphabet, so lines repeat."""
    var out = String("")
    var n = _rand(seed, 6)
    for k in range(n + 1):
        if k:
            out += "\n"
        for _ in range(_rand(seed, 3)):
            out += String(chr(97 + _rand(seed, 3)))
    return out^


def _offset(text: String, row: Int, col: Int) -> Int:
    var b = text.as_bytes()
    var r = 0
    var i = 0
    while r < row:
        if b[i] == 0x0A:
            r += 1
        i += 1
    return i + col


def test_a_big_edit_lands_as_the_same_text_however_it_is_split() raises:
    # Applied as one edit per changed run of lines; the text has to come
    # out exactly as the whole edit says
    var seed = 4242
    for _ in range(500):
        var before = _random_text(seed)
        var ed = Editor(before)
        var n = ed.buffer.line_count()
        var sl = _rand(seed, n)
        var el = sl + _rand(seed, n - sl)
        var sc = _rand(seed, ed.buffer.line_length(sl) + 1)
        var ec = _rand(seed, ed.buffer.line_length(el) + 1)
        if sl == el and ec < sc:
            ec = sc
        var text = _random_text(seed)
        var want = String(before[byte=0:_offset(before, sl, sc)]) + text \
            + String(before[byte=_offset(before, el, ec):])
        var edits = List[TextEditEntry]()
        if el == n - 1 and ec == ed.buffer.line_length(el) and _rand(seed, 2) == 0:
            # how servers say "to the end": the line past the last
            edits.append(_edit(sl, sc, n, 0, text))
        else:
            edits.append(_edit(sl, sc, el, ec, text))
        _ = ed.apply_text_edits(edits^)
        assert_equal(ed.text_snapshot(), want)


def test_a_whole_file_format_keeps_bookmarks_and_the_caret_line() raises:
    var ed = Editor(String("a = 1\nb  = 2\nc = 3\nd = 4\ne  = 5"))
    ed.buffer.set_mark(2, True)
    ed.move_to(3, 3, False)
    var edits = List[TextEditEntry]()
    edits.append(_edit(0, 0, 5, 0, "a = 1\nb = 2\nc = 3\nd = 4\ne = 5\n"))
    assert_true(ed.apply_text_edits(edits^))
    assert_equal(ed.text_snapshot(), String("a = 1\nb = 2\nc = 3\nd = 4\ne = 5\n"))
    assert_true(ed.buffer.is_marked(2))
    assert_equal(ed.buffer.mark_count, 1)
    assert_equal(ed.primary_caret().row, 3)
    assert_equal(ed.primary_caret().col, 3)
    assert_true(ed.undo())
    assert_equal(ed.text_snapshot(), String("a = 1\nb  = 2\nc = 3\nd = 4\ne  = 5"))


def test_every_caret_moves_with_the_text() raises:
    var ed = Editor(String("a\nb\nc\nd\ne\nf"))
    ed.selections = List[Caret]()
    # (row, col, desired col, anchor row, anchor col)
    ed.selections.append(Caret(1, 1, 1, 1, 1))
    ed.selections.append(Caret(3, 0, 0, 3, 0))
    ed.selections.append(Caret(5, 1, 1, 5, 1))
    var edits = List[TextEditEntry]()
    edits.append(_edit(2, 0, 5, 0, ""))
    assert_true(ed.apply_text_edits(edits^))
    assert_equal(ed.text_snapshot(), String("a\nb\nf"))
    # the one in the removed lines lands on the buffer's text
    assert_equal(len(ed.selections), 3)
    assert_equal(ed.selections[2].row, 2)
    assert_equal(ed.selections[2].col, 1)
    for c in ed.selections:
        assert_true(c.row < ed.buffer.line_count())


def main() raises:
    setup_test_env()
    TestSuite.discover_tests[__functions_in_module()]().run()
