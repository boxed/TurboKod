"""Standalone smoke test for multi-cursor support.

Lives separately from ``test_basic.mojo`` so it doesn't pull the giant
import graph (which currently has unrelated WIP issues in
``debug_pane.mojo``). Runs with ``./run.sh tests/test_multicursor.mojo``.
"""

from std.testing import assert_equal, assert_false, assert_true

from turbokod.editor import Caret, Editor
from turbokod.events import (
    Event, EVENT_KEY, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_UP,
    MOD_ALT, MOD_CTRL, MOD_KEY_ALT, MOD_META, MOD_NONE, MOD_SHIFT,
)
from turbokod.geometry import Point, Rect


def _view() -> Rect:
    return Rect(Point(0, 0), Point(80, 25))


def test_primary_only_by_default() raises:
    var ed = Editor(String("hello\nworld\n"))
    assert_equal(ed.caret_count(), 1)
    assert_false(ed.has_extra_carets())


def test_add_caret_below_then_above() raises:
    var ed = Editor(String("aaa\nbbb\nccc\nddd\n"))
    # Primary at (0, 0); desired_col = 0 → adding below should land
    # at (1, 0), then (2, 0), then (3, 0).
    ed.add_caret_below()
    ed.add_caret_below()
    assert_equal(ed.caret_count(), 3)
    # Primary is still at row 0; extras are normalized but the primary
    # position doesn't change.
    assert_equal(ed.selections[0].row, 0)
    var rows = List[Int]()
    rows.append(ed.selections[0].row)
    for i in range(1, len(ed.selections)):
        rows.append(ed.selections[i].row)
    # Sort rows for a stable assertion.
    var sorted_rows = List[Int]()
    sorted_rows.append(rows[0])
    for i in range(1, len(rows)):
        var v = rows[i]
        var j = len(sorted_rows)
        sorted_rows.append(v)
        while j > 0 and sorted_rows[j] < sorted_rows[j - 1]:
            var tmp = sorted_rows[j]
            sorted_rows[j] = sorted_rows[j - 1]
            sorted_rows[j - 1] = tmp
            j -= 1
    assert_equal(sorted_rows[0], 0)
    assert_equal(sorted_rows[1], 1)
    assert_equal(sorted_rows[2], 2)


def test_add_caret_above_at_row_zero_is_noop() raises:
    var ed = Editor(String("aaa\nbbb\n"))
    assert_equal(ed.selections[0].row, 0)
    ed.add_caret_above()
    assert_equal(ed.caret_count(), 1)


def test_add_caret_below_past_eof_is_noop() raises:
    var ed = Editor(String("only\n"))
    # Buffer has two lines: "only" and "" (trailing-newline empty line).
    ed.add_caret_below()
    assert_equal(ed.caret_count(), 2)
    ed.add_caret_below()
    # No more rows below — caret count stays at 2.
    assert_equal(ed.caret_count(), 2)


def test_movement_applies_to_every_caret() raises:
    var ed = Editor(String("hello\nworld\nthere\n"))
    ed.add_caret_below()
    ed.add_caret_below()
    var view = _view()
    # Move right twice — every caret should advance.
    _ = ed.handle_key(Event.key_event(KEY_RIGHT, MOD_NONE), view)
    _ = ed.handle_key(Event.key_event(KEY_RIGHT, MOD_NONE), view)
    assert_equal(ed.selections[0].col, 2)
    for i in range(1, len(ed.selections)):
        var c = ed.selections[i]
        assert_equal(c.col, 2)


def test_typing_inserts_at_every_caret() raises:
    var ed = Editor(String("aaa\nbbb\nccc\n"))
    ed.add_caret_below()
    ed.add_caret_below()
    var view = _view()
    # Type "X" at all three carets simultaneously.
    _ = ed.handle_key(Event.key_event(UInt32(0x58), MOD_NONE), view)
    assert_equal(ed.buffer.line(0), String("Xaaa"))
    assert_equal(ed.buffer.line(1), String("Xbbb"))
    assert_equal(ed.buffer.line(2), String("Xccc"))


def test_typing_two_carets_same_row_shifts_correctly() raises:
    var ed = Editor(String("hello\n"))
    # Place primary at col 0 and an extra at col 5 (end of "hello").
    ed.selections[0].col = 0
    ed.selections[0].anchor_col = 0
    ed._add_caret(Caret(0, 5, 5, 0, 5))
    var view = _view()
    _ = ed.handle_key(Event.key_event(UInt32(0x58), MOD_NONE), view)
    # After inserting "X" at col 0 and col 5 (in original positions):
    #   "hello" → "Xhello" → "XhelloX"
    assert_equal(ed.buffer.line(0), String("XhelloX"))


def test_backspace_at_every_caret() raises:
    var ed = Editor(String("aaa\nbbb\nccc\n"))
    ed.add_caret_below()
    ed.add_caret_below()
    var view = _view()
    # Move all carets to col 1 first.
    _ = ed.handle_key(Event.key_event(KEY_RIGHT, MOD_NONE), view)
    # Backspace at every caret.
    _ = ed.handle_key(Event.key_event(UInt32(0xE003), MOD_NONE), view)
    # Each line lost its first byte.
    assert_equal(ed.buffer.line(0), String("aa"))
    assert_equal(ed.buffer.line(1), String("bb"))
    assert_equal(ed.buffer.line(2), String("cc"))


def test_collapse_extras_on_enter() raises:
    var ed = Editor(String("aaa\nbbb\n"))
    ed.add_caret_below()
    assert_equal(ed.caret_count(), 2)
    var view = _view()
    # Enter collapses extras down to the primary. After Enter, only one
    # caret remains.
    _ = ed.handle_key(Event.key_event(UInt32(0xE001), MOD_NONE), view)
    assert_equal(ed.caret_count(), 1)


def test_undo_restores_extras() raises:
    var ed = Editor(String("aaa\nbbb\nccc\n"))
    ed.add_caret_below()
    ed.add_caret_below()
    assert_equal(ed.caret_count(), 3)
    var view = _view()
    # Type into all carets — pushes an undo entry capturing the
    # multi-caret state.
    _ = ed.handle_key(Event.key_event(UInt32(0x58), MOD_NONE), view)
    assert_equal(ed.buffer.line(0), String("Xaaa"))
    # Now collapse to single caret somehow (Enter does it).
    _ = ed.handle_key(Event.key_event(UInt32(0xE001), MOD_NONE), view)
    assert_equal(ed.caret_count(), 1)
    # Undo the Enter → extras come back.
    _ = ed.undo()
    assert_equal(ed.caret_count(), 3)
    # Undo the typing → buffer is restored too.
    _ = ed.undo()
    assert_equal(ed.buffer.line(0), String("aaa"))
    assert_equal(ed.buffer.line(1), String("bbb"))
    assert_equal(ed.buffer.line(2), String("ccc"))


def test_clear_extra_carets() raises:
    var ed = Editor(String("aaa\nbbb\n"))
    ed.add_caret_below()
    assert_equal(ed.caret_count(), 2)
    ed.clear_extra_carets()
    assert_equal(ed.caret_count(), 1)


def test_carets_merge_when_movement_collides() raises:
    var ed = Editor(String("hello\n"))
    # Place primary at col 0; add an extra at col 2.
    ed._add_caret(Caret(0, 2, 2, 0, 2))
    assert_equal(ed.caret_count(), 2)
    var view = _view()
    # Home on both → both land at col 0 → dedupe to one.
    _ = ed.handle_key(Event.key_event(UInt32(0xE014), MOD_NONE), view)
    assert_equal(ed.caret_count(), 1)


def test_three_carets_delete_inline() raises:
    var ed = Editor(String("aaa\nbbb\nccc\n"))
    ed.add_caret_below()
    ed.add_caret_below()
    var view = _view()
    # Carets at col 0 of rows 0/1/2. Delete deletes one byte forward
    # from each. After: "aa\nbb\ncc\n".
    _ = ed.handle_key(Event.key_event(UInt32(0xE019), MOD_NONE), view)
    assert_equal(ed.buffer.line(0), String("aa"))
    assert_equal(ed.buffer.line(1), String("bb"))
    assert_equal(ed.buffer.line(2), String("cc"))


def test_backspace_at_col_zero_collapses_to_primary() raises:
    var ed = Editor(String("aaa\nbbb\n"))
    ed.add_caret_below()
    # Primary at (0, 0), extra at (1, 0). Backspace at (0, 0) is a
    # no-op (top of buffer); inline_safe=False because col == 0.
    # Expected: extras collapse, primary fields unchanged.
    var view = _view()
    _ = ed.handle_key(Event.key_event(UInt32(0xE003), MOD_NONE), view)
    assert_equal(ed.caret_count(), 1)


def test_typing_three_carets_same_row() raises:
    var ed = Editor(String("hello\n"))
    ed.selections[0].col = 0
    ed.selections[0].anchor_col = 0
    # Three carets at cols 0, 3, 5 — type "X" at all of them.
    ed._add_caret(Caret(0, 3, 3, 0, 3))
    ed._add_caret(Caret(0, 5, 5, 0, 5))
    var view = _view()
    _ = ed.handle_key(Event.key_event(UInt32(0x58), MOD_NONE), view)
    # "hello" → "Xhel" at col 0 → "XhelXlo" at col 3 (now 4 after first
    # X) → "XhelXloX" at col 5 (now 7 after two X's). Each caret was
    # processed at its original byte position; after all three inserts
    # the line has three Xs interleaved.
    assert_equal(ed.buffer.line(0), String("XhelXloX"))


def test_ctrl_alt_down_adds_caret() raises:
    var ed = Editor(String("aaa\nbbb\nccc\n"))
    var view = _view()
    # Ctrl+Alt+Down should stamp a caret one row below the primary.
    _ = ed.handle_key(
        Event.key_event(UInt32(0xE011), MOD_CTRL | MOD_ALT), view,
    )
    assert_equal(ed.caret_count(), 2)


def test_alt_tap_converts_multiline_selection_to_block_edit() raises:
    # Selection from (0, 1) to (2, 2) covers three lines. An Alt tap
    # (press + release with no other input) should collapse the
    # selection into one caret per line at col 0 — three carets total.
    var ed = Editor(String("alpha\nbeta\ngamma\ndelta\n"))
    ed.selections[0].row = 0
    ed.selections[0].col = 1
    ed.selections[0].anchor_row = 2
    ed.selections[0].anchor_col = 2
    # Alt press, then release: tap with no intervening input.
    _ = ed.handle_mod_key(Event.mod_key_event(MOD_KEY_ALT, True))
    _ = ed.handle_mod_key(Event.mod_key_event(MOD_KEY_ALT, False))
    assert_equal(ed.caret_count(), 3)
    # All carets at col 0.
    assert_equal(ed.selections[0].col, 0)
    assert_equal(ed.selections[0].row, 0)
    for i in range(1, len(ed.selections)):
        assert_equal(ed.selections[i].col, 0)
    # The selection collapsed (anchor == cursor).
    assert_false(ed.has_selection())


def test_alt_tap_excludes_trailing_row_when_selection_ends_at_col_zero() raises:
    # Whole-line selection: anchor at (0, 0), cursor at (2, 0) — three
    # rows are "highlighted" visually but row 2 has nothing actually
    # selected on it. Expect carets only on rows 0 and 1.
    var ed = Editor(String("alpha\nbeta\ngamma\n"))
    ed.selections[0].anchor_row = 0
    ed.selections[0].anchor_col = 0
    ed.selections[0].row = 2
    ed.selections[0].col = 0
    _ = ed.handle_mod_key(Event.mod_key_event(MOD_KEY_ALT, True))
    _ = ed.handle_mod_key(Event.mod_key_event(MOD_KEY_ALT, False))
    assert_equal(ed.caret_count(), 2)


def test_alt_tap_with_no_selection_is_silent() raises:
    # A tap without any selection just arms column mode; the caret
    # count stays at one.
    var ed = Editor(String("alpha\nbeta\n"))
    assert_equal(ed.caret_count(), 1)
    _ = ed.handle_mod_key(Event.mod_key_event(MOD_KEY_ALT, True))
    _ = ed.handle_mod_key(Event.mod_key_event(MOD_KEY_ALT, False))
    assert_equal(ed.caret_count(), 1)


def test_alt_press_with_intervening_key_is_not_a_tap() raises:
    # Alt down → user types something → Alt up: not a tap, even if a
    # multi-line selection is live, because input arrived in between.
    var ed = Editor(String("alpha\nbeta\ngamma\n"))
    ed.selections[0].row = 0
    ed.selections[0].col = 0
    ed.selections[0].anchor_row = 2
    ed.selections[0].anchor_col = 0
    var view = _view()
    _ = ed.handle_mod_key(Event.mod_key_event(MOD_KEY_ALT, True))
    # Right-arrow during Alt-down disarms the tap.
    _ = ed.handle_key(Event.key_event(UInt32(0xE013), MOD_ALT), view)
    _ = ed.handle_mod_key(Event.mod_key_event(MOD_KEY_ALT, False))
    # Selection got modified by the arrow, but no block-edit happened —
    # so we still have just one caret (the multi-line selection wasn't
    # converted).
    assert_equal(ed.caret_count(), 1)


def test_column_mode_tap_then_hold_draws_cursors() raises:
    # Phase 1: Alt tap arms column mode.
    # Phase 2: Alt down (the hold) within the window enters column mode.
    # Phase 3: Alt+Down stamps a caret on the row below.
    var ed = Editor(String("aaa\nbbb\nccc\nddd\n"))
    var view = _view()
    # Tap.
    _ = ed.handle_mod_key(Event.mod_key_event(MOD_KEY_ALT, True))
    _ = ed.handle_mod_key(Event.mod_key_event(MOD_KEY_ALT, False))
    # Hold begins (column mode armed).
    _ = ed.handle_mod_key(Event.mod_key_event(MOD_KEY_ALT, True))
    # Alt+Down: stamps a caret on the row below.
    _ = ed.handle_key(Event.key_event(UInt32(0xE011), MOD_ALT), view)
    assert_equal(ed.caret_count(), 2)
    _ = ed.handle_key(Event.key_event(UInt32(0xE011), MOD_ALT), view)
    assert_equal(ed.caret_count(), 3)
    # Releasing Alt exits column mode but keeps the carets.
    _ = ed.handle_mod_key(Event.mod_key_event(MOD_KEY_ALT, False))
    assert_equal(ed.caret_count(), 3)


def test_alt_hold_without_prior_tap_does_not_enter_column_mode() raises:
    # Just holding Alt + arrow without a prior tap should NOT stamp a
    # caret — that's still the regular word-jump / line-jump path.
    var ed = Editor(String("aaa\nbbb\nccc\n"))
    var view = _view()
    _ = ed.handle_mod_key(Event.mod_key_event(MOD_KEY_ALT, True))
    _ = ed.handle_key(Event.key_event(UInt32(0xE011), MOD_ALT), view)
    # Caret count still one — no column-mode stamping.
    assert_equal(ed.caret_count(), 1)


def test_shift_right_extends_each_selection_on_separate_rows() raises:
    # Three carets on different rows, each Shift+Right extends its own
    # selection by one column. No merging — selections are on different
    # rows so they can't overlap.
    var ed = Editor(String("hello\nworld\nthere\n"))
    ed.add_caret_below()
    ed.add_caret_below()
    var view = _view()
    _ = ed.handle_key(Event.key_event(KEY_RIGHT, MOD_SHIFT), view)
    _ = ed.handle_key(Event.key_event(KEY_RIGHT, MOD_SHIFT), view)
    assert_equal(ed.caret_count(), 3)
    assert_equal(ed.selections[0].col, 2)
    assert_equal(ed.selections[0].anchor_col, 0)
    for i in range(1, len(ed.selections)):
        var c = ed.selections[i]
        assert_equal(c.col, 2)
        assert_equal(c.anchor_col, 0)


def test_two_adjacent_carets_merge_when_selections_touch() raises:
    # Empty carets at cols 1 and 2, both Shift+Right once. Selections
    # become (0,1)-(0,2) and (0,2)-(0,3) — they touch at col 2 and
    # should merge into a single selection (0,1)-(0,3).
    var ed = Editor(String("hello\n"))
    ed.selections[0].col = 1
    ed.selections[0].anchor_col = 1
    ed._add_caret(Caret(0, 2, 2, 0, 2))
    var view = _view()
    _ = ed.handle_key(Event.key_event(KEY_RIGHT, MOD_SHIFT), view)
    assert_equal(ed.caret_count(), 1)
    # Forward direction: cursor at the union end.
    assert_equal(ed.selections[0].col, 3)
    assert_equal(ed.selections[0].anchor_col, 1)


def test_two_carets_merge_when_selections_overlap() raises:
    # Carets at cols 1 and 3, both Shift+Right twice. After two presses:
    # caret 1 selection (0,1)-(0,3), caret 2 selection (0,3)-(0,5).
    # They touch at col 3 → merge to (0,1)-(0,5).
    var ed = Editor(String("hello world\n"))
    ed.selections[0].col = 1
    ed.selections[0].anchor_col = 1
    ed._add_caret(Caret(0, 3, 3, 0, 3))
    var view = _view()
    _ = ed.handle_key(Event.key_event(KEY_RIGHT, MOD_SHIFT), view)
    _ = ed.handle_key(Event.key_event(KEY_RIGHT, MOD_SHIFT), view)
    assert_equal(ed.caret_count(), 1)
    assert_equal(ed.selections[0].col, 5)
    assert_equal(ed.selections[0].anchor_col, 1)


def test_backward_selection_merge_keeps_direction() raises:
    # Two carets at cols 4 and 6 with Shift+Left — both extend leftward.
    # After enough presses the selections overlap; merged caret keeps
    # the backward direction (cursor at union start).
    var ed = Editor(String("hello world\n"))
    ed.selections[0].col = 4
    ed.selections[0].anchor_col = 4
    ed._add_caret(Caret(0, 6, 6, 0, 6))
    var view = _view()
    # Shift+Left once: caret 1 (0,3) anchor (0,4); caret 2 (0,5) anchor (0,6).
    _ = ed.handle_key(Event.key_event(KEY_LEFT, MOD_SHIFT), view)
    # Shift+Left twice: (0,2)-(0,4) and (0,4)-(0,6) — touch at col 4.
    _ = ed.handle_key(Event.key_event(KEY_LEFT, MOD_SHIFT), view)
    assert_equal(ed.caret_count(), 1)
    assert_equal(ed.selections[0].col, 2)
    assert_equal(ed.selections[0].anchor_col, 6)


def test_cmd_right_jumps_each_caret_to_line_end() raises:
    # Three carets at col 1 on different-length lines. Cmd+Right should
    # send each caret to the end of its own line, not collapse to one.
    var ed = Editor(String("aa\nbbbb\nccc\n"))
    ed.selections[0].col = 1
    ed.selections[0].anchor_col = 1
    ed._add_caret(Caret(1, 1, 1, 1, 1))
    ed._add_caret(Caret(2, 1, 1, 2, 1))
    var view = _view()
    _ = ed.handle_key(Event.key_event(KEY_RIGHT, MOD_META), view)
    assert_equal(ed.caret_count(), 3)
    # Primary is the topmost caret (row 0) → end of "aa" is col 2.
    assert_equal(ed.selections[0].row, 0)
    assert_equal(ed.selections[0].col, 2)
    # Walk extras: rows 1 and 2 end at cols 4 and 3.
    var per_row = List[Int]()
    per_row.append(-1)
    per_row.append(-1)
    per_row.append(-1)
    per_row[ed.selections[0].row] = ed.selections[0].col
    for i in range(1, len(ed.selections)):
        var c = ed.selections[i]
        per_row[c.row] = c.col
    assert_equal(per_row[0], 2)
    assert_equal(per_row[1], 4)
    assert_equal(per_row[2], 3)


def test_cmd_left_smart_home_each_caret() raises:
    # Three carets at col 6 on lines with varying indentation:
    #   row 0: no indent
    #   row 1: 4-space indent
    #   row 2: 2-space indent
    # First Cmd+Left lands each at its line's first-non-space (or 0).
    var ed = Editor(String("hello\n    world\n  there\n"))
    ed.selections[0].row = 0
    ed.selections[0].col = 4
    ed.selections[0].anchor_row = 0
    ed.selections[0].anchor_col = 4
    ed._add_caret(Caret(1, 6, 6, 1, 6))
    ed._add_caret(Caret(2, 4, 4, 2, 4))
    var view = _view()
    _ = ed.handle_key(Event.key_event(KEY_LEFT, MOD_META), view)
    assert_equal(ed.caret_count(), 3)
    var per_row = List[Int]()
    per_row.append(-1)
    per_row.append(-1)
    per_row.append(-1)
    per_row[ed.selections[0].row] = ed.selections[0].col
    for i in range(1, len(ed.selections)):
        var c = ed.selections[i]
        per_row[c.row] = c.col
    # Row 0: no indent, cursor was at 4 > 0 (the first-ns), so it
    # lands at 0.
    assert_equal(per_row[0], 0)
    # Row 1: 4-space indent, cursor was at 6 > 4, so it lands at 4.
    assert_equal(per_row[1], 4)
    # Row 2: 2-space indent, cursor was at 4 > 2, so it lands at 2.
    assert_equal(per_row[2], 2)


def test_cmd_shift_right_extends_each_caret_to_line_end() raises:
    # Cmd+Shift+Right should extend every caret's selection to its
    # own line's end, not collapse to one selection.
    var ed = Editor(String("aaa\nbbbbb\n"))
    ed.selections[0].col = 1
    ed.selections[0].anchor_col = 1
    ed._add_caret(Caret(1, 2, 2, 1, 2))
    var view = _view()
    _ = ed.handle_key(
        Event.key_event(KEY_RIGHT, MOD_META | MOD_SHIFT), view,
    )
    assert_equal(ed.caret_count(), 2)
    # Each caret's anchor stayed where it was, cursor moved to line end.
    # Row 0: anchor col 1, cursor col 3.
    # Row 1: anchor col 2, cursor col 5.
    # Primary is the topmost caret (row 0).
    assert_equal(ed.selections[0].row, 0)
    assert_equal(ed.selections[0].col, 3)
    assert_equal(ed.selections[0].anchor_col, 1)
    var c = ed.selections[1]
    assert_equal(c.row, 1)
    assert_equal(c.col, 5)
    assert_equal(c.anchor_col, 2)


def test_typing_replaces_each_carets_selection() raises:
    # Three carets, each with a same-row selection (3-char run on each
    # row). Typing replaces every selection with the new char.
    var ed = Editor(String("foo bar\nbaz qux\none two\n"))
    # Primary on row 0: select cols 0..3 ("foo").
    ed.selections[0].anchor_row = 0
    ed.selections[0].anchor_col = 0
    ed.selections[0].row = 0
    ed.selections[0].col = 3
    # Extra on row 1: select cols 0..3 ("baz").
    ed._add_caret(Caret(1, 3, 3, 1, 0))
    # Extra on row 2: select cols 0..3 ("one").
    ed._add_caret(Caret(2, 3, 3, 2, 0))
    var view = _view()
    _ = ed.handle_key(Event.key_event(UInt32(0x58), MOD_NONE), view)
    # Each selection ("foo" / "baz" / "one") replaced by "X".
    assert_equal(ed.buffer.line(0), String("X bar"))
    assert_equal(ed.buffer.line(1), String("X qux"))
    assert_equal(ed.buffer.line(2), String("X two"))
    # Each caret collapses to a single position one past the inserted char.
    assert_equal(ed.selections[0].col, 1)
    assert_false(ed.has_selection())


def test_backspace_deletes_selection_at_each_caret() raises:
    # Backspace on a caret carrying a selection deletes the selection
    # (not just one char). With multiple selection-carrying carets,
    # each selection vanishes independently.
    var ed = Editor(String("hello world\nhello world\n"))
    # Primary: select "hello" on row 0.
    ed.selections[0].anchor_row = 0
    ed.selections[0].anchor_col = 0
    ed.selections[0].row = 0
    ed.selections[0].col = 5
    # Extra: select "world" on row 1.
    ed._add_caret(Caret(1, 11, 11, 1, 6))
    var view = _view()
    _ = ed.handle_key(Event.key_event(UInt32(0xE003), MOD_NONE), view)
    assert_equal(ed.buffer.line(0), String(" world"))
    assert_equal(ed.buffer.line(1), String("hello "))


def test_delete_replaces_selection_at_each_caret() raises:
    # Same idea as backspace but using forward Delete.
    var ed = Editor(String("abc\ndef\n"))
    ed.selections[0].anchor_row = 0
    ed.selections[0].anchor_col = 0
    ed.selections[0].row = 0
    ed.selections[0].col = 2  # selects "ab"
    ed._add_caret(Caret(1, 2, 2, 1, 0))  # selects "de"
    var view = _view()
    _ = ed.handle_key(Event.key_event(UInt32(0xE019), MOD_NONE), view)
    assert_equal(ed.buffer.line(0), String("c"))
    assert_equal(ed.buffer.line(1), String("f"))


def test_typing_two_selections_same_row_shifts_correctly() raises:
    # Two non-overlapping same-row selections.
    # "[fo]o [ba]r" — selections "fo" (cols 0-2) and "ba" (cols 4-6).
    # Type "X" — should yield "Xo Xr".
    var ed = Editor(String("foo bar\n"))
    ed.selections[0].anchor_row = 0
    ed.selections[0].anchor_col = 0
    ed.selections[0].row = 0
    ed.selections[0].col = 2
    ed._add_caret(Caret(0, 6, 6, 0, 4))
    var view = _view()
    _ = ed.handle_key(Event.key_event(UInt32(0x58), MOD_NONE), view)
    assert_equal(ed.buffer.line(0), String("Xo Xr"))


def test_typing_falls_back_when_selection_crosses_rows() raises:
    # An extra caret with a cross-row selection forces collapse to the
    # single-caret path. The primary's edit happens; the extras are
    # dropped.
    var ed = Editor(String("aaa\nbbb\nccc\n"))
    # Primary at (0, 0).
    # Extra with a cross-row selection (row 1 col 0 → row 2 col 0).
    ed._add_caret(Caret(2, 0, 0, 1, 0))
    var view = _view()
    _ = ed.handle_key(Event.key_event(UInt32(0x58), MOD_NONE), view)
    # Primary insertion happened on row 0. Extras were collapsed.
    assert_equal(ed.buffer.line(0), String("Xaaa"))
    assert_equal(ed.caret_count(), 1)


def test_cross_row_selections_merge_when_they_touch() raises:
    # Caret 1 on row 0, Shift+Down to select to row 1. Caret 2 starts
    # on row 1, Shift+Down to select to row 2. The two selections meet
    # at row 1 col 0 → merge to a single selection from row 0 to row 2.
    var ed = Editor(String("aaa\nbbb\nccc\nddd\n"))
    ed.selections[0].row = 0
    ed.selections[0].col = 0
    ed.selections[0].anchor_row = 0
    ed.selections[0].anchor_col = 0
    ed._add_caret(Caret(1, 0, 0, 1, 0))
    var view = _view()
    # Shift+Down on both: c1 (1,0) anchor (0,0); c2 (2,0) anchor (1,0).
    _ = ed.handle_key(Event.key_event(KEY_DOWN, MOD_SHIFT), view)
    # Touch at (1,0) → merge.
    assert_equal(ed.caret_count(), 1)
    assert_equal(ed.selections[0].row, 2)
    assert_equal(ed.selections[0].col, 0)
    assert_equal(ed.selections[0].anchor_row, 0)
    assert_equal(ed.selections[0].anchor_col, 0)


def main() raises:
    test_primary_only_by_default()
    test_add_caret_below_then_above()
    test_add_caret_above_at_row_zero_is_noop()
    test_add_caret_below_past_eof_is_noop()
    test_movement_applies_to_every_caret()
    test_typing_inserts_at_every_caret()
    test_typing_two_carets_same_row_shifts_correctly()
    test_backspace_at_every_caret()
    test_collapse_extras_on_enter()
    test_undo_restores_extras()
    test_clear_extra_carets()
    test_carets_merge_when_movement_collides()
    test_three_carets_delete_inline()
    test_backspace_at_col_zero_collapses_to_primary()
    test_typing_three_carets_same_row()
    test_ctrl_alt_down_adds_caret()
    test_alt_tap_converts_multiline_selection_to_block_edit()
    test_alt_tap_excludes_trailing_row_when_selection_ends_at_col_zero()
    test_alt_tap_with_no_selection_is_silent()
    test_alt_press_with_intervening_key_is_not_a_tap()
    test_column_mode_tap_then_hold_draws_cursors()
    test_alt_hold_without_prior_tap_does_not_enter_column_mode()
    test_shift_right_extends_each_selection_on_separate_rows()
    test_two_adjacent_carets_merge_when_selections_touch()
    test_two_carets_merge_when_selections_overlap()
    test_backward_selection_merge_keeps_direction()
    test_cmd_right_jumps_each_caret_to_line_end()
    test_cmd_left_smart_home_each_caret()
    test_cmd_shift_right_extends_each_caret_to_line_end()
    test_typing_replaces_each_carets_selection()
    test_backspace_deletes_selection_at_each_caret()
    test_delete_replaces_selection_at_each_caret()
    test_typing_two_selections_same_row_shifts_correctly()
    test_typing_falls_back_when_selection_crosses_rows()
    test_cross_row_selections_merge_when_they_touch()
    print("All multi-cursor tests passed.")
