"""3-way merges: when a file changes on disk under unsaved edits, both
sides' changes have to end up in the result, at the end of the file too."""

from std.testing import TestSuite, assert_equal
from std.testing import assert_false, assert_true
from turbokod.events import (
    EVENT_PASTE, KEY_BACKSPACE, KEY_DOWN, KEY_END, KEY_ENTER, KEY_ESC, KEY_HOME, KEY_LEFT, KEY_PAGEDOWN, KEY_PAGEUP,
    KEY_RIGHT, KEY_TAB, KEY_UP, MOD_CTRL, MOD_NONE, MOD_SHIFT, Event,
)
from turbokod.diff import REGION_CONFLICT, REGION_STABLE, diff3_merge, diff3_regions
from turbokod.merge_view import CHOICE_BOTH, CHOICE_DISK, CHOICE_EDIT, CHOICE_LOCAL, MergeView


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


def test_a_single_line_after_the_last_conflict_is_kept() raises:
    var regions = diff3_regions(_l("a", "m"), _l("A", "m"), _l("Z", "m"))
    assert_equal(len(regions), 2)
    assert_equal(regions[1].kind, REGION_STABLE)
    assert_equal(_joined(regions[1].lines), "m")


def _view(base: List[String], ours: List[String], theirs: List[String]) -> MergeView:
    var mv = MergeView()
    mv.open(diff3_regions(base, ours, theirs), 0, "f.txt")
    return mv^


def test_each_conflict_resolves_to_its_own_choice() raises:
    var base = _l("a", "m", "b", "n", "c", "o", "d", "p", "e")
    var ours = _l("A1", "m", "B1", "n", "C1", "o", "D1", "p", "E1")
    var theirs = _l("A2", "m", "B2", "n", "C2", "o", "D2", "p", "E2")
    var mv = _view(base, ours, theirs)
    assert_equal(mv.conflict_count, 5)
    mv.states[0].choice = CHOICE_DISK
    mv.states[1].choice = CHOICE_LOCAL
    mv.states[2].choice = CHOICE_BOTH
    mv.states[3].choice = CHOICE_EDIT
    mv.states[3].edited_lines = _l("x", "y")
    # the last one is left unpicked: it keeps the local text
    assert_equal(mv.resolved_text(), "A2\nm\nB1\nn\nC1\nC2\no\nx\ny\np\nE1")


def test_resolving_keeps_the_agreed_text_between_conflicts() raises:
    var mv = _view(_l("a", "b", "c", "d"), _l("A", "b", "c", "D"), _l("Z", "b", "c", "Y", "t"))
    assert_equal(mv.conflict_count, 2)
    mv.states[0].choice = CHOICE_DISK
    mv.states[1].choice = CHOICE_DISK
    assert_equal(mv.resolved_text(), "Z\nb\nc\nY\nt")


def _press(mut mv: MergeView, k: UInt32, mods: UInt8 = MOD_NONE) raises:
    # the view takes every key while it's open
    assert_true(mv.handle_key(Event.key_event(k, mods)))


def _type(mut mv: MergeView, text: String) raises:
    for c in text.codepoint_slices():
        _press(mv, UInt32(ord(c)))


def _shown(mut mv: MergeView) -> String:
    """The rows the view paints, ``|``-joined (empty ones left out)."""
    mv._ensure_rows()
    var out = String("")
    for row in mv._rows_cache:
        if row.text:
            out += ("|" if out else "") + row.text
    return out^


def _three_conflicts() -> MergeView:
    return _view(_l("a", "m", "b", "n", "c"), _l("A1", "m", "B1", "n", "C1"), _l("A2", "m", "B2", "n", "C2"))


def test_keys_pick_a_side_for_each_conflict() raises:
    var mv = _three_conflicts()
    _type(mv, "d")
    _press(mv, KEY_TAB)
    _type(mv, "b")
    _press(mv, KEY_TAB)
    _type(mv, "L")
    _press(mv, KEY_TAB)
    assert_equal(mv.current, 0)
    _press(mv, KEY_TAB, MOD_SHIFT)
    assert_equal(mv.current, 2)
    _press(mv, KEY_TAB, MOD_SHIFT)
    assert_equal(mv.current, 1)
    _type(mv, "B")
    assert_equal(mv.resolved_text(), "A2\nm\nB1\nB2\nn\nC1")
    _press(mv, KEY_TAB)
    _type(mv, "D")
    assert_equal(mv.resolved_text(), "A2\nm\nB1\nB2\nn\nC2")
    _type(mv, "x")  # not a choice
    assert_equal(mv.states[2].choice, CHOICE_DISK)
    _type(mv, "l")
    assert_equal(mv.states[2].choice, CHOICE_LOCAL)


def test_enter_applies_only_once_every_conflict_is_picked() raises:
    var mv = _three_conflicts()
    _press(mv, KEY_TAB)
    _type(mv, "d")
    _press(mv, KEY_TAB)
    _press(mv, KEY_ENTER)
    assert_false(mv.done)
    assert_equal(mv.current, 0)
    _type(mv, "l")
    _press(mv, KEY_ENTER)
    assert_false(mv.done)
    assert_equal(mv.current, 2)
    _type(mv, "d")
    _press(mv, KEY_ENTER)
    assert_true(mv.done)
    assert_false(mv.cancelled)


def test_escape_cancels_and_other_events_stay_in_the_view() raises:
    var mv = _three_conflicts()
    var paste = Event.key_event(UInt32(ord("d")))
    paste.kind = EVENT_PASTE
    assert_true(mv.handle_key(paste))
    assert_equal(mv.states[0].choice, 0)
    assert_true(mv.handle_key(Event.key_event(UInt32(ord("q")))))
    _press(mv, KEY_ESC)
    assert_true(mv.cancelled)
    assert_false(mv.done)
    mv.close()
    assert_false(mv.handle_key(Event.key_event(UInt32(ord("d")))))


def test_a_clean_merge_applies_and_ignores_choices() raises:
    var mv = _view(_l("a", "b"), _l("a", "b", "c"), _l("A", "b"))
    assert_equal(mv.conflict_count, 0)
    _type(mv, "d")
    _type(mv, "e")
    _press(mv, KEY_TAB)
    assert_false(mv.edit_mode)
    _press(mv, KEY_ENTER)
    assert_true(mv.done)
    assert_equal(mv.resolved_text(), "A\nb\nc")


def test_scrolling_stops_at_the_top() raises:
    var mv = _three_conflicts()
    _press(mv, KEY_UP)
    assert_equal(mv.scroll, 0)
    _press(mv, KEY_PAGEDOWN)
    _press(mv, KEY_DOWN)
    assert_equal(mv.scroll, 11)
    _press(mv, KEY_UP)
    assert_equal(mv.scroll, 10)
    _press(mv, KEY_PAGEUP)
    _press(mv, KEY_PAGEDOWN)
    _press(mv, KEY_PAGEUP)
    _press(mv, KEY_PAGEUP)
    assert_equal(mv.scroll, 0)


def test_editing_a_conflict_by_hand() raises:
    var mv = _view(_l("a", "b", "c"), _l("a", "OURS", "c"), _l("a", "THEIRS", "c"))
    assert_equal(_shown(mv), "a|── Conflict 1/1 ──|LOCAL (your edits):|OURS|ON DISK:|THEIRS|c")
    _type(mv, "b")
    assert_equal(_shown(mv), "a|── Conflict 1/1 ──  ✓|LOCAL (your edits):|OURS|ON DISK:|THEIRS|c")
    _type(mv, "e")
    assert_equal(_shown(mv), "a|── Conflict 1/1 ──  ✓|OURS|THEIRS|c")
    assert_true(mv.edit_mode)
    assert_equal(mv.states[0].choice, CHOICE_EDIT)
    assert_equal(_joined(mv.states[0].edited_lines), "OURS|THEIRS")
    _press(mv, KEY_END)
    _type(mv, "é")
    assert_equal(mv.edit_col, 6)
    _press(mv, KEY_LEFT)
    assert_equal(mv.edit_col, 4)
    assert_equal(_shown(mv), "a|── Conflict 1/1 ──  ✓|OURSé|THEIRS|c")
    _press(mv, KEY_ENTER)
    assert_equal(_joined(mv.states[0].edited_lines), "OURS|é|THEIRS")
    assert_equal(_shown(mv), "a|── Conflict 1/1 ──  ✓|OURS|é|THEIRS|c")
    assert_equal(mv.edit_row, 1)
    assert_equal(mv.edit_col, 0)
    _press(mv, KEY_RIGHT)
    assert_equal(mv.edit_col, 2)
    _press(mv, KEY_RIGHT)  # at the end already
    assert_equal(mv.edit_col, 2)
    _press(mv, KEY_DOWN)
    _press(mv, KEY_DOWN)  # on the last line already
    _type(mv, "x")
    assert_equal(_joined(mv.states[0].edited_lines), "OURS|é|THxEIRS")
    _press(mv, KEY_UP)
    assert_equal(mv.edit_row, 1)
    assert_equal(mv.edit_col, 2)  # pulled back to the end of `é`
    _press(mv, KEY_HOME)
    _press(mv, KEY_LEFT)  # at the start already
    assert_equal(mv.edit_col, 0)
    _press(mv, KEY_BACKSPACE)  # joins with the line above
    assert_equal(_joined(mv.states[0].edited_lines), "OURSé|THxEIRS")
    assert_equal(_shown(mv), "a|── Conflict 1/1 ──  ✓|OURSé|THxEIRS|c")
    assert_equal(mv.edit_row, 0)
    assert_equal(mv.edit_col, 4)
    _press(mv, KEY_BACKSPACE)
    assert_equal(mv.edit_col, 3)
    assert_equal(_shown(mv), "a|── Conflict 1/1 ──  ✓|OURé|THxEIRS|c")
    _press(mv, KEY_RIGHT)
    _type(mv, "!")
    _press(mv, UInt32(ord("z")), MOD_CTRL)  # not typed
    _press(mv, KEY_UP)  # on the first line already
    assert_equal(mv.edit_row, 0)
    # "l", "d", "b" and "e" are text while editing
    _type(mv, "ldbe")
    assert_equal(_joined(mv.states[0].edited_lines), "OURé!ldbe|THxEIRS")
    _press(mv, KEY_HOME)
    _press(mv, KEY_BACKSPACE)  # nothing before the first line
    assert_equal(_joined(mv.states[0].edited_lines), "OURé!ldbe|THxEIRS")
    _press(mv, KEY_ESC)
    assert_false(mv.edit_mode)
    assert_false(mv.cancelled)
    assert_equal(_shown(mv), "a|── Conflict 1/1 ──  ✓|OURé!ldbe|THxEIRS|c")
    assert_equal(mv.resolved_text(), "a\nOURé!ldbe\nTHxEIRS\nc")
    _type(mv, "l")
    assert_equal(mv.resolved_text(), "a\nOURS\nc")
    assert_equal(_shown(mv), "a|── Conflict 1/1 ──  ✓|LOCAL (your edits):|OURS|ON DISK:|THEIRS|c")


def test_moving_up_or_down_never_lands_inside_a_character() raises:
    var mv = _view(_l("a", "b", "c"), _l("a", "é", "c"), _l("a", "xy", "c"))
    _type(mv, "b")
    _type(mv, "e")
    _press(mv, KEY_DOWN)
    _press(mv, KEY_RIGHT)
    _press(mv, KEY_UP)
    assert_equal(mv.edit_col, 0)
    _type(mv, "z")
    assert_equal(_joined(mv.states[0].edited_lines), "zé|xy")


def test_editing_a_deletion_starts_from_one_empty_line() raises:
    # ours deleted the line, theirs changed it
    var mv = _view(_l("a", "b", "c"), _l("a", "c"), _l("a", "B", "c"))
    _press(mv, KEY_ENTER)
    assert_false(mv.done)
    _type(mv, "e")
    assert_equal(len(mv.states[0].edited_lines), 1)
    _type(mv, "z")
    _press(mv, KEY_ESC)
    _press(mv, KEY_ENTER)
    assert_true(mv.done)
    assert_equal(mv.resolved_text(), "a\nz\nc")


def test_editing_the_second_conflict() raises:
    var mv = _three_conflicts()
    _press(mv, KEY_TAB)
    _type(mv, "d")
    _type(mv, "e")
    _type(mv, "!")
    _press(mv, KEY_ESC)
    _press(mv, KEY_TAB)
    _press(mv, KEY_TAB)
    _type(mv, "e")
    _type(mv, "?")
    assert_equal(mv.resolved_text(), "?A1\nm\n!B2\nn\nC1")


def test_reopening_starts_over() raises:
    var mv = _three_conflicts()
    _press(mv, KEY_TAB)
    _type(mv, "e")
    _press(mv, KEY_DOWN)
    _press(mv, KEY_END)
    _press(mv, KEY_ESC)
    _press(mv, KEY_PAGEDOWN)
    _press(mv, KEY_ESC)
    mv.done = True
    mv.open(diff3_regions(_l("a", "m", "b"), _l("A", "m", "B"), _l("Z", "m", "Y")), 3, "g.txt")
    assert_true(mv.active)
    assert_false(mv.done)
    assert_false(mv.cancelled)
    assert_false(mv.edit_mode)
    assert_equal(mv.conflict_count, 2)
    assert_equal(len(mv.states), 2)
    assert_equal(mv.current, 0)
    assert_equal(mv.scroll, 0)
    assert_equal(mv.target_idx, 3)
    assert_equal(mv.file_path, "g.txt")
    _type(mv, "e")
    _type(mv, "!")
    assert_equal(mv.edit_row, 0)
    assert_equal(mv.edit_col, 1)
    assert_equal(mv.resolved_text(), "!A\nm\nB")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
