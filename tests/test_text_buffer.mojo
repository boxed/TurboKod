"""``TextBuffer``: every edit goes through it, so it must never drop or
duplicate text."""

from std.testing import TestSuite, assert_equal
from turbokod.editor import TextBuffer


def _text(b: TextBuffer) -> String:
    var out = String("")
    for i in range(b.line_count()):
        if i:
            out += "|"
        out += b.line(i)
    return out^


def test_a_new_buffer_has_one_empty_line() raises:
    var b = TextBuffer()
    assert_equal(b.line_count(), 1)
    assert_equal(b.line(0), "")


def test_reading_out_of_range_gives_nothing() raises:
    var b = TextBuffer("ab\ncd")
    assert_equal(b.line(-1), "")
    assert_equal(b.line(2), "")
    assert_equal(b.line(1), "cd")
    assert_equal(b.line_length(-1), 0)
    assert_equal(b.line_length(2), 0)
    assert_equal(b.line_length(1), 2)


def test_insert() raises:
    var b = TextBuffer("ab\ncd")
    b.insert(0, 1, "X")
    b.insert(1, 99, "Y")
    b.insert(1, -3, "Z")
    assert_equal(_text(b), "aXb|ZcdY")
    b.insert(2, 0, "nope")
    b.insert(-1, 0, "nope")
    assert_equal(_text(b), "aXb|ZcdY")


def test_delete_at_removes_one_character() raises:
    var b = TextBuffer("aéb")
    b.delete_at(0, 1)
    assert_equal(_text(b), "ab")


def test_delete_at_the_end_of_a_line_joins_the_next() raises:
    var b = TextBuffer("ab\ncd\nef")
    b.delete_at(0, 2)
    assert_equal(_text(b), "abcd|ef")
    b.delete_at(0, 4)
    assert_equal(_text(b), "abcdef")
    # the last line has nothing to join
    b.delete_at(0, 6)
    assert_equal(_text(b), "abcdef")


def test_delete_at_outside_the_buffer_does_nothing() raises:
    var b = TextBuffer("ab\ncd")
    b.delete_at(2, 0)
    b.delete_at(-1, 0)
    assert_equal(_text(b), "ab|cd")


def test_delete_before_removes_one_character() raises:
    var b = TextBuffer("aéb")
    var cursor = b.delete_before(0, 3)
    assert_equal(_text(b), "ab")
    assert_equal(cursor[0], 0)
    assert_equal(cursor[1], 1)


def test_delete_before_at_the_start_of_a_line_joins_it_to_the_previous() raises:
    var b = TextBuffer("ab\ncd\nef")
    var cursor = b.delete_before(1, 0)
    assert_equal(_text(b), "abcd|ef")
    assert_equal(cursor[0], 0)
    assert_equal(cursor[1], 2)
    cursor = b.delete_before(0, 0)
    assert_equal(_text(b), "abcd|ef")
    assert_equal(cursor[0], 0)
    assert_equal(cursor[1], 0)


def test_split() raises:
    var b = TextBuffer("abc\nlast")
    var cursor = b.split(0, 1)
    assert_equal(_text(b), "a|bc|last")
    assert_equal(cursor[0], 1)
    assert_equal(cursor[1], 0)
    _ = b.split(1, 0)
    assert_equal(_text(b), "a||bc|last")
    _ = b.split(3, 99)
    assert_equal(_text(b), "a||bc|last|")
    _ = b.split(0, -2)
    assert_equal(_text(b), "|a||bc|last|")


def test_split_outside_the_buffer_does_nothing() raises:
    var b = TextBuffer("ab")
    var cursor = b.split(1, 0)
    assert_equal(_text(b), "ab")
    assert_equal(cursor[0], 1)
    cursor = b.split(-1, 0)
    assert_equal(_text(b), "ab")
    assert_equal(cursor[0], -1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
