"""Staging, unstaging and discarding single lines (``build_minimal_patch``
and ``git apply``): only the chosen line may change in the index or the
working tree, the rest of the file must stay as it is."""

from std.testing import TestSuite, assert_equal, assert_true
from turbokod.file_io import read_file, write_file
from turbokod.git_changes import (
    apply_patch_to_index, apply_patch_to_worktree, compute_staged_diff,
    compute_unstaged_diff, parse_unified_diff_files,
)
from turbokod.local_changes import build_minimal_patch
from turbokod.lsp import capture_command
from turbokod.string_utils import split_lines_no_trailing, string_list
from support import _git_capture, _rm_rf, _run_git, _temp_path, setup_test_env


comptime _TWO_HUNKS = (
    "diff --git a/f b/f\n"
    "index 1111111..2222222 100644\n"
    "--- a/f\n"
    "+++ b/f\n"
    "@@ -1,3 +1,3 @@\n"
    " a\n"
    "-b\n"
    "+B\n"
    " c\n"
    "@@ -10,3 +10,4 @@\n"
    " j\n"
    "-k\n"
    "+K\n"
    "+L\n"
    " m\n"
)


def _patch(diff: String, line: String, reverse: Bool = False) -> String:
    """The patch for the first diff line that is exactly ``line``, after the
    file header."""
    var lines = split_lines_no_trailing(diff)
    for i in range(4, len(lines)):
        if lines[i] == line:
            return build_minimal_patch(diff, i, reverse)
    return String("no such line: ") + line


def _body(patch: String) -> String:
    """The patch without its four header lines, ``|``-joined."""
    var lines = split_lines_no_trailing(patch)
    var out = String("")
    for i in range(4, len(lines)):
        if i > 4:
            out += "|"
        out += lines[i]
    return out^


def test_staging_a_line_in_the_second_hunk() raises:
    assert_equal(_body(_patch(_TWO_HUNKS, "+K")), "@@ -10,3 +10,4 @@| j| k|+K| m")
    assert_equal(_body(_patch(_TWO_HUNKS, "-k")), "@@ -10,3 +10,4 @@| j|-k| m")
    assert_equal(_body(_patch(_TWO_HUNKS, "+B")), "@@ -1,3 +1,3 @@| a| b|+B| c")


def test_unstaging_keeps_the_other_new_lines_as_context() raises:
    assert_equal(_body(_patch(_TWO_HUNKS, "+K", True)), "@@ -10,3 +10,4 @@| j|+K| L| m")
    assert_equal(_body(_patch(_TWO_HUNKS, "-k", True)), "@@ -10,3 +10,4 @@| j|-k| K| L| m")


def test_the_file_header_is_kept() raises:
    var lines = split_lines_no_trailing(_patch(_TWO_HUNKS, "+L"))
    assert_equal(lines[0], "diff --git a/f b/f")
    assert_equal(lines[3], "+++ b/f")


def test_only_changed_lines_can_be_staged() raises:
    var lines = split_lines_no_trailing(_TWO_HUNKS)
    for i in [-1, 0, 1, 4, 5, 8, 9, 10, len(lines), len(lines) + 1]:
        assert_equal(build_minimal_patch(_TWO_HUNKS, i, False), "", String(i))
    # `--- a/f` starts with `-`, but it's the header
    assert_equal(build_minimal_patch(_TWO_HUNKS, 2, False), "")
    assert_equal(build_minimal_patch(_TWO_HUNKS, 3, False), "")
    assert_equal(build_minimal_patch("+x\n-y\n", 0, False), "")


def test_a_hunk_ends_where_the_next_files_diff_starts() raises:
    var diff = String(
        "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\n+A\n"
        "diff --git a/g b/g\n--- a/g\n+++ b/g\n@@ -1 +1 @@\n-x\n+X\n"
    )
    # the header is everything up to the first hunk (no `index` line here)
    assert_equal(_patch(diff, "+A"), "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n a\n+A\n")
    var patch = build_minimal_patch(diff, 5, False)
    assert_true(not ("diff --git a/g" in patch), patch)
    assert_true(patch.endswith(" a\n+A\n"), patch)


def test_no_newline_markers_and_blank_lines_stay_in_the_hunk() raises:
    var diff = String(
        "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,2 +1,3 @@\n a\n\n"
        "-b\n\\ No newline at end of file\n+B\n+C\n\\ No newline at end of file\n"
    )
    var patch = build_minimal_patch(diff, 8, False)  # +B
    assert_equal(
        patch,
        "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,2 +1,3 @@\n a\n\n b\n\\ No newline at end of file\n+B\n"
        "\\ No newline at end of file\n",
    )


def test_a_two_byte_line_isnt_a_hunk_header_unless_it_starts_with_two_ats() raises:
    var diff = String("--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n @\n-a\n+@a\n")
    assert_equal(build_minimal_patch(diff, 5, False), "--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n @\n a\n+@a\n")


def test_added_blank_lines() raises:
    var diff = String("--- a/f\n+++ b/f\n@@ -1,2 +1,4 @@\n a\n+\n+x\n b\n")
    # staging the blank line itself
    assert_equal(_patch(diff, "+"), "--- a/f\n+++ b/f\n@@ -1,2 +1,4 @@\n a\n+\n b\n")
    # unstaging or discarding the other line: the blank one stays, as context
    assert_equal(_patch(diff, "+x", True), "--- a/f\n+++ b/f\n@@ -1,2 +1,4 @@\n a\n \n+x\n b\n")


def test_nothing_to_stage_on_blank_or_hunkless_diffs() raises:
    var diff = String("--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n a\n\n-b\n+B\n")
    assert_equal(build_minimal_patch(diff, 4, False), "")
    assert_equal(build_minimal_patch("--- a/f\n+++ b/f\n", 0, False), "")


def test_a_blank_line_before_the_next_hunk_ends_it() raises:
    var diff = String("--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n-a\n+A\n\n@@ -9 +9 @@\n-x\n+X\n")
    assert_equal(_patch(diff, "+X"), "--- a/f\n+++ b/f\n@@ -9 +9 @@\n x\n+X\n")
    assert_equal(_patch(diff, "+A"), "--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n a\n+A\n\n")


# ---- against git --------------------------------------------------------------


def _repo(name: String, committed: String, changed: String) raises -> String:
    var dir = _temp_path(name)
    _rm_rf(dir)
    _ = capture_command(string_list("git", "init", "-q", "-b", "main", dir))
    assert_true(write_file(dir + "/f", committed))
    _ = _run_git(dir, string_list("add", "f"))
    _ = _run_git(dir, string_list(
        "-c", "user.name=T", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false",
        "commit", "-q", "-m", "init",
    ))
    assert_true(write_file(dir + "/f", changed))
    return dir^


def _file_diff(diff: String) raises -> String:
    var files = parse_unified_diff_files(diff)
    assert_equal(len(files), 1)
    return files[0].diff


def _index(dir: String) raises -> String:
    return _git_capture(dir, string_list("show", ":f"))


def test_staging_one_line_stages_only_that_line() raises:
    var dir = _repo("_stage_one", "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\n", "a\nB\nc\nd\ne\nf\ng\nh\ni\nj\nK\nL\nl\n")
    var diff = _file_diff(compute_unstaged_diff(dir))
    assert_true(apply_patch_to_index(dir, _patch(diff, "+L")))
    assert_equal(_index(dir), "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nL\nl\n")
    assert_true(apply_patch_to_index(dir, _patch(_file_diff(compute_unstaged_diff(dir)), "-b")))
    assert_equal(_index(dir), "a\nc\nd\ne\nf\ng\nh\ni\nj\nk\nL\nl\n")
    # and back
    var staged = _file_diff(compute_staged_diff(dir))
    assert_true(apply_patch_to_index(dir, _patch(staged, "+L", True), True))
    assert_equal(_index(dir), "a\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\n")
    assert_equal(read_file(dir + "/f"), "a\nB\nc\nd\ne\nf\ng\nh\ni\nj\nK\nL\nl\n")
    _rm_rf(dir)


def test_discarding_one_line_leaves_the_rest_of_the_work() raises:
    var dir = _repo("_discard_one", "a\nb\nc\nd\n", "a\nB\nX\nc\nD\n")
    var diff = _file_diff(compute_unstaged_diff(dir))
    assert_true(apply_patch_to_worktree(dir, _patch(diff, "+X", True), True))
    assert_equal(read_file(dir + "/f"), "a\nB\nc\nD\n")
    diff = _file_diff(compute_unstaged_diff(dir))
    assert_true(apply_patch_to_worktree(dir, _patch(diff, "-d", True), True))
    assert_equal(read_file(dir + "/f"), "a\nB\nc\nd\nD\n")
    assert_equal(_index(dir), "a\nb\nc\nd\n")
    _rm_rf(dir)


def test_staging_the_last_line_of_a_file_without_a_final_newline() raises:
    var dir = _repo("_stage_nonl", "a\nb", "a\nB")
    var diff = _file_diff(compute_unstaged_diff(dir))
    assert_true(apply_patch_to_index(dir, _patch(diff, "-b")))
    assert_equal(_index(dir), "a\n")
    assert_true(apply_patch_to_index(dir, _patch(_file_diff(compute_unstaged_diff(dir)), "+B")))
    assert_equal(_index(dir), "a\nB")
    _rm_rf(dir)


def main() raises:
    setup_test_env()
    TestSuite.discover_tests[__functions_in_module()]().run()
