"""Line bookmarks (Edit ▸ Bookmarks, the Find dialog's Mark all): a bookmark
belongs to its line's text, so it has to follow that text through every
kind of edit, undo included, and the bulk commands have to stay one pass
over the rows."""

from std.testing import TestSuite, assert_equal, assert_false, assert_true
from turbokod.canvas import Canvas
from turbokod.colors import LIGHT_MAGENTA
from turbokod.desktop import (
    Desktop, EDITOR_BOOKMARK_DELETE, EDITOR_BOOKMARK_INVERT,
    EDITOR_BOOKMARK_NEXT, EDITOR_BOOKMARK_TOGGLE, EDITOR_FIND,
)
from turbokod.editor import Editor, TextBuffer
from turbokod.events import (
    Event, KEY_BACKSPACE, KEY_DELETE, KEY_ENTER, KEY_F2, MOD_ALT, MOD_CTRL,
    MOD_SHIFT,
)
from turbokod.geometry import Rect
from turbokod.search_options import SearchOptions, default_search_options
from turbokod.terminal import parse_input
from turbokod.window import Window
from support import _SCREEN, setup_test_env


comptime _VIEW = Rect(0, 0, 60, 20)


def _marked(b: TextBuffer) -> String:
    """The bookmarked rows as ``"0,3"``."""
    var out = String("")
    for r in range(b.line_count()):
        if b.is_marked(r):
            if len(out.as_bytes()) > 0:
                out += ","
            out += String(r)
    return out^


def _text(b: TextBuffer) -> String:
    var out = String("")
    for i in range(b.line_count()):
        if i:
            out += "|"
        out += b.line(i)
    return out^


def _editor(text: String, *rows: Int) -> Editor:
    var ed = Editor(text)
    for r in rows:
        ed.buffer.set_mark(r, True)
    return ed^


def _press(mut ed: Editor, k: UInt32, mods: UInt8 = 0):
    _ = ed.handle_key(Event.key_event(k, mods), _VIEW)


# --- the buffer ---------------------------------------------------------


def test_marks_cost_nothing_until_set_and_drop_when_the_last_goes() raises:
    var b = TextBuffer("a\nb\nc")
    assert_equal(len(b.marks), 0)
    b.set_mark(1, True)
    assert_equal(len(b.marks), 3)
    assert_equal(b.mark_count, 1)
    b.set_mark(1, True)
    assert_equal(b.mark_count, 1)
    b.set_mark(1, False)
    assert_equal(b.mark_count, 0)
    assert_equal(len(b.marks), 0)
    b.set_mark(7, True)
    b.set_mark(-1, True)
    assert_equal(b.mark_count, 0)


def test_rows_inserted_or_deleted_above_move_the_mark() raises:
    var b = TextBuffer("a\nb\nc\nd")
    b.set_mark(2, True)
    var rows = List[String]()
    rows.append(String("x"))
    rows.append(String("y"))
    b.insert_rows(1, rows^)
    assert_equal(_marked(b), "4")
    b.delete_rows(0, 3)
    assert_equal(_text(b), "b|c|d")
    assert_equal(_marked(b), "1")
    b.delete_rows(1, 1)
    assert_equal(_marked(b), "")
    assert_equal(len(b.marks), 0)


def test_enter_moves_the_mark_only_when_it_pushes_the_text_down() raises:
    var b = TextBuffer("abc\ndef")
    b.set_mark(0, True)
    _ = b.split(0, 3)   # end of line: the new line below is empty
    assert_equal(_marked(b), "0")
    _ = b.split(0, 1)   # mid-line: the head keeps it
    assert_equal(_text(b), "a|bc||def")
    assert_equal(_marked(b), "0")
    _ = b.split(0, 0)   # start of line: the text moves down a row
    assert_equal(_text(b), "|a|bc||def")
    assert_equal(_marked(b), "1")


def test_joining_lines_keeps_the_mark_with_the_surviving_text() raises:
    var b = TextBuffer("one\ntwo\n\nfour")
    b.set_mark(1, True)
    # Backspace at the start of "two" joins it onto "one".
    _ = b.delete_before(1, 0)
    assert_equal(_text(b), "onetwo||four")
    assert_equal(_marked(b), "0")
    # A bookmarked empty line deleted from above takes its mark with it.
    var c = TextBuffer("x\n\ny")
    c.set_mark(1, True)
    c.delete_at(0, 1)
    assert_equal(_text(c), "x|y")
    assert_equal(_marked(c), "")


def test_deleting_a_whole_line_drops_its_mark_not_the_next_ones() raises:
    var ed = _editor(String("a\nb\nc\nd"), 1)
    ed.buffer.set_mark(3, True)
    # Select "b\n" — column 0 of row 1 to column 0 of row 2 — and delete.
    ed.move_to(1, 0, False)
    ed.move_to(2, 0, True)
    _press(ed, KEY_DELETE)
    assert_equal(_text(ed.buffer), "a|c|d")
    assert_equal(_marked(ed.buffer), "2")


def test_pasting_lines_at_the_start_of_a_line_pushes_its_mark_down() raises:
    var ed = _editor(String("a\nb\nc"), 1)
    ed.move_to(1, 0, False)
    ed.paste_text(String("x\ny\n"))
    assert_equal(_text(ed.buffer), "a|x|y|b|c")
    assert_equal(_marked(ed.buffer), "3")


def test_typing_and_enter_through_the_editor() raises:
    var ed = _editor(String("first\nsecond"), 1)
    ed.move_to(0, 5, False)
    _press(ed, KEY_ENTER)
    assert_equal(_marked(ed.buffer), "2")
    ed.move_to(2, 0, False)
    _press(ed, KEY_BACKSPACE)
    assert_equal(_text(ed.buffer), "first|second")
    assert_equal(_marked(ed.buffer), "1")


# --- the commands -------------------------------------------------------


def test_toggle_marks_every_caret_line_once() raises:
    var ed = Editor(String("a\nb\nc\nd"))
    ed.move_to(1, 0, False)
    ed.add_caret_below()
    ed.toggle_bookmark()
    assert_equal(_marked(ed.buffer), "1,2")
    ed.toggle_bookmark()
    assert_equal(_marked(ed.buffer), "")


def test_mark_and_unmark_matching_lines() raises:
    var ed = Editor(String("Foo\nbar\nfoo bar\n\nbaz"))
    assert_equal(ed.mark_matching_lines(String("foo"), default_search_options(), True), 2)
    assert_equal(_marked(ed.buffer), "0,2")
    # Already-marked lines don't count again.
    assert_equal(ed.mark_matching_lines(String("bar"), default_search_options(), True), 1)
    assert_equal(_marked(ed.buffer), "0,1,2")
    assert_equal(ed.mark_matching_lines(String("bar"), default_search_options(), False), 2)
    assert_equal(_marked(ed.buffer), "0")
    # A zero-width regex match counts: ``^$`` marks the blank lines.
    var re = SearchOptions(False, False, True)
    assert_equal(ed.mark_matching_lines(String("^$"), re, True), 1)
    assert_equal(_marked(ed.buffer), "0,3")
    assert_equal(ed.mark_matching_lines(String(""), re, True), 0)


def test_invert_and_clear() raises:
    var ed = _editor(String("a\nb\nc"), 1)
    ed.invert_bookmarks()
    assert_equal(_marked(ed.buffer), "0,2")
    assert_equal(ed.bookmark_count(), 2)
    ed.invert_bookmarks()
    ed.invert_bookmarks()
    ed.clear_bookmarks()
    assert_equal(ed.bookmark_count(), 0)
    ed.invert_bookmarks()
    assert_equal(_marked(ed.buffer), "0,1,2")


def test_next_and_previous_wrap_around() raises:
    var ed = _editor(String("a\nb\nc\nd\ne"), 1, 3)
    ed.move_to(3, 0, False)
    assert_true(ed.goto_bookmark(True, _VIEW))
    assert_equal(ed.primary_caret().row, 1)
    assert_true(ed.goto_bookmark(True, _VIEW))
    assert_equal(ed.primary_caret().row, 3)
    assert_true(ed.goto_bookmark(False, _VIEW))
    assert_equal(ed.primary_caret().row, 1)
    assert_true(ed.goto_bookmark(False, _VIEW))
    assert_equal(ed.primary_caret().row, 3)
    ed.clear_bookmarks()
    assert_false(ed.goto_bookmark(True, _VIEW))


def test_bookmarked_text_is_whole_lines() raises:
    var ed = _editor(String("a\nb\nc"), 0, 2)
    assert_equal(ed.bookmarked_text(), String("a\nc\n"))
    ed.clear_bookmarks()
    assert_equal(ed.bookmarked_text(), String(""))


def test_delete_bookmarked_lines_and_undo_brings_them_back() raises:
    var ed = _editor(String("a\nb\nc\nd\ne"), 1, 2, 4)
    ed.move_to(3, 0, False)
    assert_equal(ed.delete_bookmarked_lines(), 3)
    assert_equal(_text(ed.buffer), "a|d")
    assert_equal(ed.bookmark_count(), 0)
    # The caret stayed on its line ("d").
    assert_equal(ed.primary_caret().row, 1)
    assert_true(ed.undo())
    assert_equal(_text(ed.buffer), "a|b|c|d|e")
    assert_equal(_marked(ed.buffer), "1,2,4")
    assert_true(ed.redo())
    assert_equal(_text(ed.buffer), "a|d")
    assert_equal(ed.bookmark_count(), 0)


def test_deleting_every_line_leaves_one_empty_line() raises:
    var ed = _editor(String("a\nb"), 0, 1)
    assert_equal(ed.cut_bookmarked_lines(), 2)
    assert_equal(ed.buffer.line_count(), 1)
    assert_equal(ed.buffer.line(0), String(""))


def test_read_only_buffers_copy_but_never_delete() raises:
    var ed = _editor(String("a\nb"), 0)
    ed.read_only = True
    assert_equal(ed.delete_bookmarked_lines(), 0)
    assert_equal(ed.cut_bookmarked_lines(), 1)
    assert_equal(_text(ed.buffer), "a|b")


def test_undo_keeps_bookmarks_set_after_the_edit_on_unchanged_lines() raises:
    var ed = Editor(String("a\nb\nc\nd"))
    ed.move_to(0, 1, False)
    _press(ed, KEY_ENTER)
    # Bookmarked after the edit, on a line the undo doesn't touch.
    ed.buffer.set_mark(4, True)
    assert_true(ed.undo())
    assert_equal(_text(ed.buffer), "a|b|c|d")
    assert_equal(_marked(ed.buffer), "3")


def test_bulk_commands_are_linear_on_a_big_file() raises:
    # Quadratic row shuffling would take minutes here.
    var text = String("")
    for i in range(200000):
        text += String("keep\n") if i % 2 == 0 else String("drop me\n")
    var ed = Editor(text)
    assert_equal(ed.mark_matching_lines(String("drop"), default_search_options(), True), 100000)
    ed.invert_bookmarks()
    ed.invert_bookmarks()
    assert_equal(len(ed.bookmarked_text().as_bytes()), 100000 * 8)
    assert_equal(ed.delete_bookmarked_lines(), 100000)
    assert_equal(ed.buffer.line_count(), 100001)
    assert_true(ed.undo())
    assert_equal(ed.bookmark_count(), 100000)


# --- painting -----------------------------------------------------------


def test_a_bookmarked_line_number_is_highlighted() raises:
    var ed = _editor(String("a\nb\nc"), 1)
    ed.line_numbers = True
    var canvas = Canvas(60, 20)
    ed.paint(canvas, _VIEW, True)
    assert_equal(canvas.get(0, 1).attr.bg, LIGHT_MAGENTA)
    assert_equal(canvas.get(0, 1).glyph, String("2"))
    assert_true(canvas.get(0, 0).attr.bg != LIGHT_MAGENTA)


def test_without_line_numbers_a_marker_column_appears_while_marked() raises:
    var ed = Editor(String("a\nb\nc"))
    ed.line_numbers = False
    var canvas = Canvas(60, 20)
    ed.paint(canvas, _VIEW, True)
    assert_equal(canvas.get(0, 1).glyph, String("b"))
    ed.buffer.set_mark(1, True)
    canvas = Canvas(60, 20)
    ed.paint(canvas, _VIEW, True)
    assert_equal(canvas.get(0, 1).attr.bg, LIGHT_MAGENTA)
    assert_equal(canvas.get(1, 1).glyph, String("b"))


# --- the desktop --------------------------------------------------------


def _desktop(text: String) -> Desktop:
    var d = Desktop()
    d.windows.add(Window.editor_window(
        String("buf"), Rect(0, 1, 60, 20), text,
    ))
    return d^


def test_find_dialog_mark_all_and_unmark_all() raises:
    var d = _desktop(String("foo\nbar\nfoo bar\n"))
    _ = d.dispatch_action(EDITOR_FIND, _SCREEN)
    assert_true(d.prompt.show_mark_buttons)
    d.prompt.input.set_text(String("foo"))
    _ = d.handle_event(Event.key_event(KEY_ENTER, MOD_ALT), _SCREEN)
    assert_false(d.prompt.active)
    assert_equal(_marked(d.windows.windows[0].editor.buffer), "0,2")
    assert_equal(d.status_bar.message, String("Bookmarked 2 lines"))
    _ = d.dispatch_action(EDITOR_FIND, _SCREEN)
    d.prompt.input.set_text(String("bar"))
    _ = d.handle_event(Event.key_event(KEY_ENTER, MOD_ALT | MOD_SHIFT), _SCREEN)
    assert_equal(_marked(d.windows.windows[0].editor.buffer), "0")
    # Plain Enter is still Find next.
    _ = d.dispatch_action(EDITOR_FIND, _SCREEN)
    d.prompt.input.set_text(String("bar"))
    _ = d.handle_event(Event.key_event(KEY_ENTER), _SCREEN)
    assert_equal(_marked(d.windows.windows[0].editor.buffer), "0")
    assert_equal(d.windows.windows[0].editor.selection_text(), String("bar"))


def test_hotkeys_and_menu_actions_reach_the_editor() raises:
    var d = _desktop(String("a\nb\nc\nd\n"))
    d.windows.windows[0].editor.move_to(2, 0, False)
    _ = d.handle_event(Event.key_event(KEY_F2, MOD_CTRL), _SCREEN)
    assert_equal(_marked(d.windows.windows[0].editor.buffer), "2")
    d.windows.windows[0].editor.move_to(0, 0, False)
    _ = d.handle_event(Event.key_event(KEY_F2, MOD_ALT), _SCREEN)
    assert_equal(d.windows.windows[0].editor.primary_caret().row, 2)
    _ = d.dispatch_action(EDITOR_BOOKMARK_TOGGLE, _SCREEN)
    assert_equal(d.windows.windows[0].editor.bookmark_count(), 0)
    _ = d.dispatch_action(EDITOR_BOOKMARK_NEXT, _SCREEN)
    assert_equal(d.status_bar.message, String("No bookmarks"))
    _ = d.dispatch_action(EDITOR_BOOKMARK_INVERT, _SCREEN)
    assert_equal(d.status_bar.message, String("5 bookmarked lines"))
    _ = d.dispatch_action(EDITOR_BOOKMARK_DELETE, _SCREEN)
    assert_equal(d.status_bar.message, String("Deleted 5 bookmarked lines"))
    assert_equal(d.windows.windows[0].editor.buffer.line_count(), 1)


# --- the terminal -------------------------------------------------------


def test_terminal_parses_modified_function_keys() raises:
    var ev = parse_input(String("\x1b[12;5~"))[0]
    assert_equal(ev.key, KEY_F2)
    assert_equal(ev.mods, MOD_CTRL)
    ev = parse_input(String("\x1b[1;3Q"))[0]
    assert_equal(ev.key, KEY_F2)
    assert_equal(ev.mods, MOD_ALT)
    ev = parse_input(String("\x1b[1;4Q"))[0]
    assert_equal(ev.mods, MOD_ALT | MOD_SHIFT)
    ev = parse_input(String("\x1b[12~"))[0]
    assert_equal(ev.key, KEY_F2)
    assert_equal(ev.mods, UInt8(0))
    ev = parse_input(String("\x1b[3;5~"))[0]
    assert_equal(ev.key, KEY_DELETE)
    assert_equal(ev.mods, MOD_CTRL)


def main() raises:
    setup_test_env()
    TestSuite.discover_tests[__functions_in_module()]().run()
