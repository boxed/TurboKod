"""``compute_revert_block``: reverting a change from the gutter must restore
exactly that change, wherever it is in the file."""

from std.testing import TestSuite, assert_equal, assert_false, assert_true
from turbokod.git_changes import compute_revert_block
from turbokod.string_utils import split_lines


def _block(head: String, buffer: String, row: Int) raises -> String:
    """`start-end:restored|lines`, or "none"."""
    var b = compute_revert_block(head, split_lines(buffer), row)
    if not b:
        return "none"
    var out = String(b.value().buf_start) + "-" + String(b.value().buf_end_excl) + ":"
    for i in range(len(b.value().head_lines)):
        if i:
            out += "|"
        out += b.value().head_lines[i]
    return out^


def test_a_change_on_the_first_line() raises:
    assert_equal(_block("a\nb\nc\n", "A\nb\nc\n", 0), "0-1:a")


def test_a_change_further_down() raises:
    assert_equal(_block("a\nb\nc\nd\ne\n", "a\nb\nc\nD\ne\n", 3), "3-4:d")
    assert_equal(_block("a\nb\nc\nd\ne\n", "a\nb\nc\nD\ne\n", 2), "none")


def test_a_change_on_the_last_line() raises:
    assert_equal(_block("a\nb", "a\nB", 1), "1-2:b")


def test_added_lines_revert_to_nothing() raises:
    assert_equal(_block("a\nc\n", "a\nb1\nb2\nc\n", 2), "1-3:")


def test_a_deletion_elsewhere_doesnt_get_in_the_way() raises:
    # `b` was deleted, `d` changed: only the change can be clicked
    assert_equal(_block("a\nb\nc\nd\n", "a\nc\nD\n", 2), "2-3:d")
    assert_equal(_block("a\nb\nc\nd\n", "a\nc\nD\n", 1), "none")


def test_rows_outside_the_buffer() raises:
    assert_equal(_block("a\n", "A\n", -1), "none")
    assert_equal(_block("a\n", "A\n", 5), "none")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
