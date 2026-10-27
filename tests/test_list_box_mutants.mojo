"""``clamp_list_scroll``: when the selection snaps into view, and the clamp."""

from std.testing import TestSuite, assert_equal
from turbokod.list_box import clamp_list_scroll


def test_selecting_the_first_row_scrolls_to_the_top() raises:
    # scroll 5, the selection just changed to row 0
    assert_equal(clamp_list_scroll(5, 0, -1, 5, 20), 0)


def test_an_unchanged_selection_leaves_a_wheel_scroll_alone() raises:
    # row 2 was already snapped; the wheel moved the view to 10
    assert_equal(clamp_list_scroll(10, 2, 2, 5, 20), 10)


def test_a_changed_selection_snaps_into_view() raises:
    assert_equal(clamp_list_scroll(10, 2, 7, 5, 20), 2)


def test_no_selection_keeps_the_scroll() raises:
    assert_equal(clamp_list_scroll(3, -1, 0, 5, 20), 3)


def test_scroll_is_clamped_to_the_last_page() raises:
    assert_equal(clamp_list_scroll(30, -1, -1, 5, 20), 15)
    assert_equal(clamp_list_scroll(4, -1, -1, 5, 3), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
