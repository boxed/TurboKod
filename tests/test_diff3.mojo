"""3-way merges: when a file changes on disk under unsaved edits, both
sides' changes have to end up in the result, at the end of the file too."""

from std.testing import TestSuite, assert_equal
from turbokod.diff import REGION_CONFLICT, REGION_STABLE, diff3_merge, diff3_regions


def _l(*items: String) -> List[String]:
    var out = List[String]()
    for s in items:
        out.append(s)
    return out^


def _joined(lines: List[String]) -> String:
    var out = String("")
    for i in range(len(lines)):
        if i:
            out += "|"
        out += lines[i]
    return out^


def test_an_append_on_one_side_survives_an_edit_on_the_other() raises:
    var r = diff3_merge(_l("a", "b"), _l("a", "b", "c"), _l("A", "b"))
    assert_equal(_joined(r.lines), "A|b|c")
    assert_equal(r.conflicts, 0)
    assert_equal(r.first_conflict_row, -1)


def test_a_deletion_at_the_end_is_kept() raises:
    var r = diff3_merge(_l("a", "b"), _l("a", "b"), _l("a"))
    assert_equal(_joined(r.lines), "a")


def test_different_appends_at_the_end_conflict() raises:
    var r = diff3_merge(_l("a"), _l("a", "x"), _l("a", "y"))
    assert_equal(_joined(r.lines), "a|<<<<<<< ours|x|=======|y|>>>>>>> theirs")
    assert_equal(r.conflicts, 1)
    assert_equal(r.first_conflict_row, 1)


def test_an_empty_base() raises:
    assert_equal(_joined(diff3_merge(_l(), _l("x"), _l()).lines), "x")
    assert_equal(diff3_merge(_l(), _l("x"), _l("y")).conflicts, 1)


def test_every_conflict_counts_and_the_first_is_found() raises:
    var r = diff3_merge(_l("a", "m", "b"), _l("A", "m", "B"), _l("Z", "m", "Y"))
    assert_equal(r.conflicts, 2)
    assert_equal(r.first_conflict_row, 0)


def test_multi_line_changes_on_both_sides() raises:
    var r = diff3_merge(
        _l("a", "b", "c", "d", "e"), _l("a", "B", "C", "d", "e"), _l("a", "b", "c", "d", "E", "F"),
    )
    assert_equal(_joined(r.lines), "a|B|C|d|E|F")
    assert_equal(r.conflicts, 0)


def test_the_same_change_on_both_sides_is_taken_once() raises:
    var r = diff3_merge(_l("a", "b", "c"), _l("a", "X", "Y", "c"), _l("a", "X", "Y", "c"))
    assert_equal(_joined(r.lines), "a|X|Y|c")
    assert_equal(r.conflicts, 0)


def test_regions_around_conflicts_at_both_ends() raises:
    var regions = diff3_regions(_l("a", "m", "b"), _l("A", "m", "B"), _l("Z", "m", "Y"))
    assert_equal(len(regions), 3)
    assert_equal(regions[0].kind, REGION_CONFLICT)
    assert_equal(_joined(regions[0].ours_lines), "A")
    assert_equal(_joined(regions[0].theirs_lines), "Z")
    assert_equal(_joined(regions[0].base_lines), "a")
    assert_equal(regions[1].kind, REGION_STABLE)
    assert_equal(_joined(regions[1].lines), "m")
    assert_equal(regions[2].kind, REGION_CONFLICT)
    assert_equal(_joined(regions[2].ours_lines), "B")


def test_regions_of_a_clean_merge_are_one_stable_run() raises:
    var regions = diff3_regions(_l("a", "b"), _l("a", "b", "c"), _l("A", "b"))
    assert_equal(len(regions), 1)
    assert_equal(regions[0].kind, REGION_STABLE)
    assert_equal(_joined(regions[0].lines), "A|b|c")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
