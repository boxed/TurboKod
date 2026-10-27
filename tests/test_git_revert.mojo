"""``compute_revert_block`` and ``compute_deletion_revert_block``: reverting a
change from the gutter must restore exactly that change, wherever it is in the
file."""

from std.testing import TestSuite, assert_equal, assert_false, assert_true
from turbokod.git_changes import compute_deletion_revert_block, compute_revert_block
from turbokod.string_utils import split_lines


def _block(head: String, buffer: String, row: Int, deletion: Bool = False) raises -> String:
    """`start-end:restored|lines`, or "none"."""
    var b = (
        compute_deletion_revert_block(head, split_lines(buffer), row) if deletion
        else compute_revert_block(head, split_lines(buffer), row)
    )
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
    assert_equal(_block("a\nb\nc\nd\ne\n", "a\nb\nc\nD\ne\n", 4), "none")


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


def _deleted(head: String, buffer: String, marker_row: Int) raises -> String:
    return _block(head, buffer, marker_row, deletion=True)


def test_a_deletion_is_restored_below_its_marker() raises:
    assert_equal(_deleted("a\nb\nc\nd\ne\nf\n", "a\nb\nc\nf\n", 2), "3-3:d|e")
    assert_equal(_deleted("a\nb\nc\nd\ne\nf\n", "a\nb\nc\nf\n", 1), "none")
    assert_equal(_deleted("a\nb\nc\nd\ne\nf\n", "a\nb\nc\nf\n", 3), "none")


def test_a_deletion_at_the_end_of_the_file() raises:
    assert_equal(_deleted("a\nb\nc", "a", 0), "1-1:b|c")


def test_of_two_deletions_only_the_marked_one_is_restored() raises:
    var head = "a\nb\nc\nd\ne\n"
    assert_equal(_deleted(head, "a\nc\ne\n", 0), "1-1:b")
    assert_equal(_deleted(head, "a\nc\ne\n", 1), "2-2:d")


def test_a_changed_line_below_the_marker_isnt_a_deletion() raises:
    # `b` became `B`: the change bar reverts it, not the deletion marker
    assert_equal(_deleted("a\nb\nc\n", "a\nB\nc\n", 0), "none")
    assert_equal(_deleted("a\nb\nc\nd\n", "a\nB\nd\n", 0), "none")


def test_a_deletion_at_the_top_of_the_file_has_no_marker_row() raises:
    assert_equal(_deleted("a\nb\nc\n", "b\nc\n", 0), "none")
    assert_equal(_deleted("a\nb\nc\n", "b\nc\n", 1), "none")
    assert_equal(_deleted("a\nb\n", "a\n", -1), "none")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
