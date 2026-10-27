"""Replacing across the project rewrites files on disk: exactly the matches
change, binary files are left alone, and no character is ever split."""

from std.testing import TestSuite, assert_equal, assert_true
from turbokod.file_io import read_file, write_file
from turbokod.onig import onig_global_init
from turbokod.project import replace_in_project
from turbokod.search_options import LineSearcher, SearchOptions
from support import _ensure_dir, _rm_rf, _temp_path, setup_test_env


comptime _REGEX = SearchOptions(True, False, True)


def _project(name: String) raises -> String:
    onig_global_init()
    var root = _temp_path(name)
    _rm_rf(root)
    _ensure_dir(root)
    return root^


def test_regex_replace_across_files() raises:
    var root = _project("_proj_regex")
    assert_true(write_file(root + "/a.txt", "a1 b22\nc333\n"))
    assert_true(write_file(root + "/b.txt", "none here\n"))
    assert_true(write_file(root + "/c.txt", "9"))
    var summary = replace_in_project(root, "[0-9]+", "#", _REGEX)
    assert_equal(summary[0], 2)
    assert_equal(summary[1], 4)
    assert_equal(read_file(root + "/a.txt"), "a# b#\nc#\n")
    assert_equal(read_file(root + "/b.txt"), "none here\n")
    assert_equal(read_file(root + "/c.txt"), "#")
    _rm_rf(root)


def test_regex_lines_and_empty_matches() raises:
    var root = _project("_proj_regex_empty")
    assert_true(write_file(root + "/a.txt", "a\nb\n"))
    assert_true(write_file(root + "/u.txt", "é😀\n"))
    assert_equal(replace_in_project(root, "^", ">", _REGEX)[1], 3)
    assert_equal(read_file(root + "/a.txt"), ">a\n>b\n")
    assert_equal(read_file(root + "/u.txt"), ">é😀\n")
    # an empty match is followed by a step past a whole character
    assert_true(write_file(root + "/a.txt", "x"))
    assert_true(write_file(root + "/u.txt", "é😀\n"))
    var summary = replace_in_project(root, "y*", "-", _REGEX)
    assert_equal(read_file(root + "/u.txt"), "-é-😀-\n-")
    assert_equal(read_file(root + "/a.txt"), "-x-")
    assert_equal(summary[1], 6)
    _rm_rf(root)


def test_binary_files_are_left_alone() raises:
    var root = _project("_proj_binary")
    var nul = String(chr(0))
    assert_true(write_file(root + "/bin.dat", "foo" + nul + "foo"))
    # only the first 4 KiB are looked at
    var late = String("")
    for _ in range(4096):
        late += "a"
    assert_true(write_file(root + "/late.txt", late + nul + "foo"))
    var summary = replace_in_project(root, "foo", "bar")
    assert_equal(summary[0], 1)
    assert_equal(read_file(root + "/bin.dat"), "foo" + nul + "foo")
    assert_equal(read_file(root + "/late.txt"), late + nul + "bar")
    _rm_rf(root)


def test_nothing_to_find_changes_nothing() raises:
    var root = _project("_proj_nothing")
    assert_true(write_file(root + "/a.txt", "foo\n"))
    assert_equal(replace_in_project(root, "", "x")[1], 0)
    assert_equal(replace_in_project(root, "(foo", "x", _REGEX)[1], 0)
    assert_equal(read_file(root + "/a.txt"), "foo\n")
    _rm_rf(root)


def test_searching_backwards_never_stops_inside_a_character() raises:
    var s = LineSearcher("x*", _REGEX)
    assert_equal(s.rsearch("é😀b", 5).value().start, 2)
    assert_equal(s.rsearch("é😀b", 6).value().start, 6)
    s.release()


def main() raises:
    setup_test_env()
    TestSuite.discover_tests[__functions_in_module()]().run()
