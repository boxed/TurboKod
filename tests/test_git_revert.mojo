"""``compute_revert_block`` and ``compute_deletion_revert_block``: reverting a
change from the gutter must restore exactly that change, wherever it is in the
file."""

from std.testing import TestSuite, assert_equal, assert_false, assert_true
from turbokod.git_changes import (
    GIT_CHANGE_ADDED, GIT_CHANGE_MODIFIED, GIT_CHANGE_NONE, compute_deletion_revert_block, compute_revert_block,
    diff_buffer_marks,
)
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


def _marks(head: String, buffer: String) -> String:
    """The gutter marks, one character a row: `.` unchanged, `+` added,
    `~` modified, followed by `_` when lines were deleted below it."""
    var marks = diff_buffer_marks(head, split_lines(buffer))
    var out = String("")
    for i in range(len(marks.statuses)):
        var m = marks.statuses[i]
        out += "~" if m == GIT_CHANGE_MODIFIED else ("+" if m == GIT_CHANGE_ADDED else ".")
        if marks.deleted_below[i]:
            out += "_"
    return out^


def test_deleted_lines_are_marked_on_the_row_above() raises:
    assert_equal(_marks("a\nb\nc\n", "a\nc\n"), "._..")
    assert_equal(_marks("a\nb\nc\nd\n", "a\nd\n"), "._..")
    assert_equal(_marks("a\nb\nc\n", "a\nb\n"), ".._.")
    # nothing above the first line to mark
    assert_equal(_marks("a\nb\nc\n", "b\nc\n"), "...")
    assert_equal(_marks("a\nb\nc\n", "c\n"), "..")


def test_changed_lines_pair_with_the_most_similar_old_line() raises:
    assert_equal(_marks("a\nfoo(1)\nb\n", "a\n# new\nfoo(1, 2)\nb\n"), ".+~..")
    # equally similar: the first is the modified one
    assert_equal(_marks("a\nxx\nb\n", "a\nyy\nzz\nb\n"), ".~+..")
    # more lines removed than added: every new line is a modified one
    assert_equal(_marks("a\nx\ny\nz\nb\n", "a\nX\nb\n"), ".~..")


def test_a_big_rewrite_still_pairs_each_line_with_its_old_version() raises:
    # too big to compare every new line with every old one
    var head = String("")
    var buffer = String("")
    for i in range(20):
        buffer += "# note " + String(i) + "\n"
    for i in range(1000):
        head += "value_" + String(i) + " = " + String(i) + "\n"
        buffer += "value_" + String(i) + " = " + String(i) + " + offset\n"
    var marks = _marks(head, buffer)
    var expected = String("")
    for _ in range(20):
        expected += "+"
    for _ in range(1000):
        expected += "~"
    assert_equal(marks, expected + ".")


def _word(mut seed: Int) -> String:
    var out = String("")
    for _ in range(8):
        seed = (seed * 1103515245 + 12345) % 2147483648
        out += chr(97 + (seed >> 16) % 26)
    return out^


def test_in_a_big_rewrite_only_lines_like_an_old_one_are_modified() raises:
    # 1000 old lines, each changed in the middle, with 500 unrelated lines
    # between them: too many to compare all with all, but each changed line
    # still finds its old version
    var seed = 7
    var head = String("")
    var buffer = String("")
    var expected = String("")
    for j in range(1000):
        var start = _word(seed)
        var end = _word(seed)
        head += start + " = " + end + "\n"
        buffer += start + " := " + end + "\n"
        expected += "~"
        if j % 2 == 0:
            buffer += _word(seed) + "\n"
            expected += "+"
    assert_equal(_marks(head, buffer), expected + ".")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
