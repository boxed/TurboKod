"""Standalone smoke test for multi-cursor support.

Lives separately from ``test_basic.mojo`` so it doesn't pull the giant
import graph (which currently has unrelated WIP issues in
``debug_pane.mojo``). Runs with ``./run.sh tests/test_multicursor.mojo``.
"""

from std.testing import assert_equal, assert_false, assert_true

from turbokod.editor import Caret, Editor
from turbokod.events import (
    Event, EVENT_KEY, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_UP,
    MOD_ALT, MOD_CTRL, MOD_NONE, MOD_SHIFT,
)
from turbokod.geometry import Point, Rect


fn _view() -> Rect:
    return Rect(Point(0, 0), Point(80, 25))


fn test_primary_only_by_default() raises:
    var ed = Editor(String("hello\nworld\n"))
    assert_equal(ed.caret_count(), 1)
    assert_false(ed.has_extra_carets())


fn test_add_caret_below_then_above() raises:
    var ed = Editor(String("aaa\nbbb\nccc\nddd\n"))
    # Primary at (0, 0); desired_col = 0 → adding below should land
    # at (1, 0), then (2, 0), then (3, 0).
    ed.add_caret_below()
    ed.add_caret_below()
    assert_equal(ed.caret_count(), 3)
    # Primary is still at row 0; extras are normalized but the primary
    # position doesn't change.
    assert_equal(ed.cursor_row, 0)
    var rows = List[Int]()
    rows.append(ed.cursor_row)
    for i in range(len(ed.extra_carets)):
        rows.append(ed.extra_carets[i].row)
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


fn test_add_caret_above_at_row_zero_is_noop() raises:
    var ed = Editor(String("aaa\nbbb\n"))
    assert_equal(ed.cursor_row, 0)
    ed.add_caret_above()
    assert_equal(ed.caret_count(), 1)


fn test_add_caret_below_past_eof_is_noop() raises:
    var ed = Editor(String("only\n"))
    # Buffer has two lines: "only" and "" (trailing-newline empty line).
    ed.add_caret_below()
    assert_equal(ed.caret_count(), 2)
    ed.add_caret_below()
    # No more rows below — caret count stays at 2.
    assert_equal(ed.caret_count(), 2)


fn test_movement_applies_to_every_caret() raises:
    var ed = Editor(String("hello\nworld\nthere\n"))
    ed.add_caret_below()
    ed.add_caret_below()
    var view = _view()
    # Move right twice — every caret should advance.
    _ = ed.handle_key(Event.key_event(KEY_RIGHT, MOD_NONE), view)
    _ = ed.handle_key(Event.key_event(KEY_RIGHT, MOD_NONE), view)
    assert_equal(ed.cursor_col, 2)
    for i in range(len(ed.extra_carets)):
        var c = ed.extra_carets[i]
        assert_equal(c.col, 2)


fn test_typing_inserts_at_every_caret() raises:
    var ed = Editor(String("aaa\nbbb\nccc\n"))
    ed.add_caret_below()
    ed.add_caret_below()
    var view = _view()
    # Type "X" at all three carets simultaneously.
    _ = ed.handle_key(Event.key_event(UInt32(0x58), MOD_NONE), view)
    assert_equal(ed.buffer.line(0), String("Xaaa"))
    assert_equal(ed.buffer.line(1), String("Xbbb"))
    assert_equal(ed.buffer.line(2), String("Xccc"))


fn test_typing_two_carets_same_row_shifts_correctly() raises:
    var ed = Editor(String("hello\n"))
    # Place primary at col 0 and an extra at col 5 (end of "hello").
    ed.cursor_col = 0
    ed.anchor_col = 0
    ed._add_caret(Caret(0, 5, 5, 0, 5))
    var view = _view()
    _ = ed.handle_key(Event.key_event(UInt32(0x58), MOD_NONE), view)
    # After inserting "X" at col 0 and col 5 (in original positions):
    #   "hello" → "Xhello" → "XhelloX"
    assert_equal(ed.buffer.line(0), String("XhelloX"))


fn test_backspace_at_every_caret() raises:
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


fn test_collapse_extras_on_enter() raises:
    var ed = Editor(String("aaa\nbbb\n"))
    ed.add_caret_below()
    assert_equal(ed.caret_count(), 2)
    var view = _view()
    # Enter collapses extras down to the primary. After Enter, only one
    # caret remains.
    _ = ed.handle_key(Event.key_event(UInt32(0xE001), MOD_NONE), view)
    assert_equal(ed.caret_count(), 1)


fn test_undo_restores_extras() raises:
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


fn test_clear_extra_carets() raises:
    var ed = Editor(String("aaa\nbbb\n"))
    ed.add_caret_below()
    assert_equal(ed.caret_count(), 2)
    ed.clear_extra_carets()
    assert_equal(ed.caret_count(), 1)


fn test_carets_merge_when_movement_collides() raises:
    var ed = Editor(String("hello\n"))
    # Place primary at col 0; add an extra at col 2.
    ed._add_caret(Caret(0, 2, 2, 0, 2))
    assert_equal(ed.caret_count(), 2)
    var view = _view()
    # Home on both → both land at col 0 → dedupe to one.
    _ = ed.handle_key(Event.key_event(UInt32(0xE014), MOD_NONE), view)
    assert_equal(ed.caret_count(), 1)


fn test_three_carets_delete_inline() raises:
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


fn test_backspace_at_col_zero_collapses_to_primary() raises:
    var ed = Editor(String("aaa\nbbb\n"))
    ed.add_caret_below()
    # Primary at (0, 0), extra at (1, 0). Backspace at (0, 0) is a
    # no-op (top of buffer); inline_safe=False because col == 0.
    # Expected: extras collapse, primary fields unchanged.
    var view = _view()
    _ = ed.handle_key(Event.key_event(UInt32(0xE003), MOD_NONE), view)
    assert_equal(ed.caret_count(), 1)


fn test_typing_three_carets_same_row() raises:
    var ed = Editor(String("hello\n"))
    ed.cursor_col = 0
    ed.anchor_col = 0
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


fn test_ctrl_alt_down_adds_caret() raises:
    var ed = Editor(String("aaa\nbbb\nccc\n"))
    var view = _view()
    # Ctrl+Alt+Down should stamp a caret one row below the primary.
    _ = ed.handle_key(
        Event.key_event(UInt32(0xE011), MOD_CTRL | MOD_ALT), view,
    )
    assert_equal(ed.caret_count(), 2)


fn main() raises:
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
    print("All multi-cursor tests passed.")
