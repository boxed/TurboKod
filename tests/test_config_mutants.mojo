"""``_promote_recent``: the most-recently-used list behind recent projects."""

from std.testing import TestSuite, assert_equal, assert_false, assert_true
from turbokod.config import _promote_recent


def _list(*items: String) -> List[String]:
    var out = List[String]()
    for s in items:
        out.append(s)
    return out^


def test_an_empty_path_changes_nothing() raises:
    var entries = _list("a")
    assert_false(_promote_recent(entries, "", 5))
    assert_equal(entries, _list("a"))


def test_a_path_already_first_changes_nothing() raises:
    var only = _list("x")
    assert_false(_promote_recent(only, "x", 5))
    assert_equal(only, _list("x"))
    var first = _list("x", "a")
    assert_false(_promote_recent(first, "x", 5))
    assert_equal(first, _list("x", "a"))


def test_a_new_path_goes_first() raises:
    var entries = _list("a")
    assert_true(_promote_recent(entries, "x", 5))
    assert_equal(entries, _list("x", "a"))


def test_promoting_drops_the_other_copy() raises:
    var entries = _list("a", "x", "b")
    assert_true(_promote_recent(entries, "x", 5))
    assert_equal(entries, _list("x", "a", "b"))


def test_the_list_is_trimmed_to_the_cap() raises:
    var entries = _list("a", "b", "c")
    assert_true(_promote_recent(entries, "x", 2))
    assert_equal(entries, _list("x", "a"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
