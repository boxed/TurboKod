"""Smart-select (Cmd+Up / Cmd+Down) tests for the editor.

Run with:
    ./run.sh tests/test_smart_select.mojo
"""

from std.testing import assert_equal, assert_false, assert_true

from turbokod.editor import Editor
from turbokod.events import (
    Event, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_UP, MOD_META, MOD_NONE, MOD_SHIFT,
)
from turbokod.geometry import Rect


comptime _VIEW = Rect(0, 0, 80, 24)


def _key(k: UInt32, mods: UInt8 = MOD_NONE) -> Event:
    return Event.key_event(k, mods)


def _set_caret(mut ed: Editor, row: Int, col: Int):
    ed.move_to(row, col, False)


def _selection(ed: Editor) -> Tuple[Int, Int, Int, Int]:
    """Normalize selection to (start_row, start_col, end_row, end_col)."""
    var sr = ed.anchor_row
    var sc = ed.anchor_col
    var er = ed.cursor_row
    var ec = ed.cursor_col
    if (sr > er) or (sr == er and sc > ec):
        return (er, ec, sr, sc)
    return (sr, sc, er, ec)


def test_cmd_up_on_caret_selects_word() raises:
    var ed = Editor(String("hello world"))
    _set_caret(ed, 0, 2)  # in the middle of "hello"
    _ = ed.handle_key(_key(KEY_UP, MOD_META), _VIEW)
    var s = _selection(ed)
    assert_equal(s[0], 0); assert_equal(s[1], 0)
    assert_equal(s[2], 0); assert_equal(s[3], 5)


def test_cmd_up_after_word_extends_to_dotted_path() raises:
    var ed = Editor(String("foo.bar.baz()"))
    _set_caret(ed, 0, 5)  # in "bar"
    _ = ed.handle_key(_key(KEY_UP, MOD_META), _VIEW)
    var s = _selection(ed)
    assert_equal(s[1], 4); assert_equal(s[3], 7)  # "bar"
    _ = ed.handle_key(_key(KEY_UP, MOD_META), _VIEW)
    s = _selection(ed)
    assert_equal(s[1], 0); assert_equal(s[3], 11)  # "foo.bar.baz"


def test_cmd_up_inside_string_grows_to_quotes() raises:
    var ed = Editor(String("name = \"hello world\""))
    _set_caret(ed, 0, 9)  # inside "hello"
    _ = ed.handle_key(_key(KEY_UP, MOD_META), _VIEW)
    var s = _selection(ed)
    assert_equal(s[1], 8); assert_equal(s[3], 13)  # "hello"
    _ = ed.handle_key(_key(KEY_UP, MOD_META), _VIEW)
    s = _selection(ed)
    # "hello world" interior
    assert_equal(s[1], 8); assert_equal(s[3], 19)
    _ = ed.handle_key(_key(KEY_UP, MOD_META), _VIEW)
    s = _selection(ed)
    # include the quotes
    assert_equal(s[1], 7); assert_equal(s[3], 20)


def test_cmd_up_brackets_then_line_then_file() raises:
    var ed = Editor(String("a = [1, 2, 3]"))
    _set_caret(ed, 0, 8)  # on "2"
    _ = ed.handle_key(_key(KEY_UP, MOD_META), _VIEW)
    var s = _selection(ed)
    assert_equal(s[1], 8); assert_equal(s[3], 9)  # "2"
    _ = ed.handle_key(_key(KEY_UP, MOD_META), _VIEW)
    s = _selection(ed)
    # bracket interior "1, 2, 3"
    assert_equal(s[1], 5); assert_equal(s[3], 12)
    _ = ed.handle_key(_key(KEY_UP, MOD_META), _VIEW)
    s = _selection(ed)
    # bracket with brackets "[1, 2, 3]"
    assert_equal(s[1], 4); assert_equal(s[3], 13)
    _ = ed.handle_key(_key(KEY_UP, MOD_META), _VIEW)
    s = _selection(ed)
    # whole line
    assert_equal(s[1], 0); assert_equal(s[3], 13)


def test_cmd_up_grows_to_indent_block_and_file() raises:
    var ed = Editor(String("def f():\n    x = 1\n    y = 2\n\nz = 3\n"))
    _set_caret(ed, 1, 4)  # on "x"
    # word
    _ = ed.handle_key(_key(KEY_UP, MOD_META), _VIEW)
    var s = _selection(ed)
    assert_equal(s[0], 1); assert_equal(s[1], 4)
    assert_equal(s[2], 1); assert_equal(s[3], 5)
    # line content
    _ = ed.handle_key(_key(KEY_UP, MOD_META), _VIEW)
    s = _selection(ed)
    assert_equal(s[0], 1); assert_equal(s[1], 4)
    assert_equal(s[2], 1); assert_equal(s[3], 9)
    # whole line
    _ = ed.handle_key(_key(KEY_UP, MOD_META), _VIEW)
    s = _selection(ed)
    assert_equal(s[0], 1); assert_equal(s[1], 0)
    assert_equal(s[2], 1); assert_equal(s[3], 9)
    # body block (rows 1..2)
    _ = ed.handle_key(_key(KEY_UP, MOD_META), _VIEW)
    s = _selection(ed)
    assert_equal(s[0], 1); assert_equal(s[2], 2)
    # parent block (def f line introducer + body)
    _ = ed.handle_key(_key(KEY_UP, MOD_META), _VIEW)
    s = _selection(ed)
    assert_equal(s[0], 0); assert_equal(s[2], 2)


def test_cmd_down_rewinds_through_history() raises:
    var ed = Editor(String("hello world"))
    _set_caret(ed, 0, 2)
    _ = ed.handle_key(_key(KEY_UP, MOD_META), _VIEW)  # word
    _ = ed.handle_key(_key(KEY_UP, MOD_META), _VIEW)  # line / file
    var grew = _selection(ed)
    _ = ed.handle_key(_key(KEY_DOWN, MOD_META), _VIEW)  # back to word
    var word = _selection(ed)
    assert_true(word[1] != grew[1] or word[3] != grew[3])
    assert_equal(word[1], 0); assert_equal(word[3], 5)
    _ = ed.handle_key(_key(KEY_DOWN, MOD_META), _VIEW)  # back to caret
    assert_false(ed.has_selection())
    assert_equal(ed.cursor_col, 2)


def test_other_key_resets_smart_select_history() raises:
    var ed = Editor(String("hello world"))
    _set_caret(ed, 0, 2)
    _ = ed.handle_key(_key(KEY_UP, MOD_META), _VIEW)
    _ = ed.handle_key(_key(KEY_UP, MOD_META), _VIEW)
    # Pressing Right collapses the selection and breaks the smart-select run.
    _ = ed.handle_key(_key(KEY_RIGHT), _VIEW)
    # Cmd+Down should now be a no-op rather than rewinding back.
    var before_col = ed.cursor_col
    _ = ed.handle_key(_key(KEY_DOWN, MOD_META), _VIEW)
    assert_equal(ed.cursor_col, before_col)


def test_cmd_down_with_empty_history_is_noop() raises:
    var ed = Editor(String("abc"))
    _set_caret(ed, 0, 1)
    _ = ed.handle_key(_key(KEY_DOWN, MOD_META), _VIEW)
    assert_equal(ed.cursor_col, 1)
    assert_false(ed.has_selection())


def test_cmd_up_grows_through_nested_brackets() raises:
    var ed = Editor(String("foo(bar(x, y), z)"))
    _set_caret(ed, 0, 8)  # on "x"
    _ = ed.handle_key(_key(KEY_UP, MOD_META), _VIEW)
    var s = _selection(ed)
    assert_equal(s[1], 8); assert_equal(s[3], 9)  # "x"
    _ = ed.handle_key(_key(KEY_UP, MOD_META), _VIEW)
    s = _selection(ed)
    # inner bracket interior "x, y"
    assert_equal(s[1], 8); assert_equal(s[3], 12)
    _ = ed.handle_key(_key(KEY_UP, MOD_META), _VIEW)
    s = _selection(ed)
    # inner with brackets "(x, y)"
    assert_equal(s[1], 7); assert_equal(s[3], 13)
    _ = ed.handle_key(_key(KEY_UP, MOD_META), _VIEW)
    s = _selection(ed)
    # outer interior "bar(x, y), z"
    assert_equal(s[1], 4); assert_equal(s[3], 16)


def test_cmd_up_grows_across_multiline_brackets() raises:
    var ed = Editor(String("foo(\n    a,\n    b,\n)"))
    _set_caret(ed, 1, 4)  # on "a"
    _ = ed.handle_key(_key(KEY_UP, MOD_META), _VIEW)
    var s = _selection(ed)
    assert_equal(s[0], 1); assert_equal(s[1], 4)
    assert_equal(s[2], 1); assert_equal(s[3], 5)  # "a"
    # Skip line / line-content steps until expansion crosses rows.
    var crossed = False
    for _ in range(10):
        _ = ed.handle_key(_key(KEY_UP, MOD_META), _VIEW)
        s = _selection(ed)
        if s[0] == 0 and s[2] == 3:
            crossed = True
            break
    assert_true(crossed)


def test_cmd_up_grows_existing_user_selection() raises:
    var ed = Editor(String("hello world"))
    # Manual selection of just "ell" via shift+right.
    _set_caret(ed, 0, 1)
    _ = ed.handle_key(_key(KEY_RIGHT, MOD_SHIFT), _VIEW)
    _ = ed.handle_key(_key(KEY_RIGHT, MOD_SHIFT), _VIEW)
    _ = ed.handle_key(_key(KEY_RIGHT, MOD_SHIFT), _VIEW)
    var pre = _selection(ed)
    assert_equal(pre[1], 1); assert_equal(pre[3], 4)  # "ell"
    # Cmd+Up grows to surround the word "hello".
    _ = ed.handle_key(_key(KEY_UP, MOD_META), _VIEW)
    var s = _selection(ed)
    # First grow level expands to whole "hello" via the strict-contains
    # check at the line-content / whole-line ladder. Either way it must
    # contain the original "ell".
    assert_true(s[1] <= 1 and s[3] >= 4)


def test_cmd_up_at_whole_file_is_noop() raises:
    var ed = Editor(String("only"))
    _set_caret(ed, 0, 0)
    # Repeatedly press Cmd+Up; eventually we hit whole file.
    for _ in range(10):
        _ = ed.handle_key(_key(KEY_UP, MOD_META), _VIEW)
    var s = _selection(ed)
    assert_equal(s[0], 0); assert_equal(s[1], 0)
    assert_equal(s[2], 0); assert_equal(s[3], 4)


def main() raises:
    test_cmd_up_on_caret_selects_word()
    test_cmd_up_after_word_extends_to_dotted_path()
    test_cmd_up_inside_string_grows_to_quotes()
    test_cmd_up_brackets_then_line_then_file()
    test_cmd_up_grows_to_indent_block_and_file()
    test_cmd_down_rewinds_through_history()
    test_other_key_resets_smart_select_history()
    test_cmd_down_with_empty_history_is_noop()
    test_cmd_up_at_whole_file_is_noop()
    test_cmd_up_grows_through_nested_brackets()
    test_cmd_up_grows_across_multiline_brackets()
    test_cmd_up_grows_existing_user_selection()
    print("all smart-select tests passed")
