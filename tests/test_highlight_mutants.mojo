"""``_md_fence_info``: the language word of a Markdown code fence."""

from std.testing import TestSuite, assert_equal
from turbokod.highlight import _md_fence_info, _md_find_tick_close


def test_the_language_right_after_the_fence() raises:
    assert_equal(_md_fence_info("```python", 3), "python")


def test_whitespace_before_the_language_is_skipped() raises:
    assert_equal(_md_fence_info("``` python", 3), "python")
    assert_equal(_md_fence_info("```\tpython", 3), "python")


def test_only_the_first_word_counts() raises:
    assert_equal(_md_fence_info("```python title", 3), "python")
    assert_equal(_md_fence_info("```python\ttitle", 3), "python")
    assert_equal(_md_fence_info("```lua rest", 3), "lua")


def test_a_bare_fence_has_no_language() raises:
    assert_equal(_md_fence_info("```", 3), "")


def test_the_closer_is_a_run_of_exactly_that_many_ticks() raises:
    assert_equal(_md_find_tick_close("a``b", 0, 2), 1)
    assert_equal(_md_find_tick_close("a```b`", 0, 1), 5)


def test_a_closer_right_after_one_character() raises:
    assert_equal(_md_find_tick_close("a`", 0, 1), 1)


def test_no_closer() raises:
    assert_equal(_md_find_tick_close("abc", 0, 1), -1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
