"""Editor selection, mouse and word/line motion.

One of the per-topic suites split out of the former
``test_basic.mojo``; shared fixtures live in ``tests/support.mojo``
and ``scripts/run_tests.sh`` runs every suite.
"""

from std.ffi import external_call
from std.testing import assert_equal, assert_false, assert_true
from turbokod.canvas import Canvas
from turbokod.cell import Cell
from turbokod.colors import BLUE, default_attr
from turbokod.editor import Editor
from turbokod.file_io import write_file
from turbokod.git_changes import LineHistoryEntry
from turbokod.selection_history import SelectionHistory
from turbokod.text_view import Selection, smart_wrap_lines, wrap_lines
from turbokod.lsp_dispatch import DIAG_SEVERITY_ERROR, Diagnostic
from turbokod.highlight import GrammarRegistry
from turbokod.posix import which
from turbokod.events import (
    Event, KEY_BACKSPACE, KEY_DOWN, KEY_END, KEY_ENTER, KEY_ESC, KEY_LEFT,
    KEY_RIGHT, KEY_SPACE, KEY_TAB, KEY_UP, MOD_ALT, MOD_CTRL, MOD_META,
    MOD_NONE, MOD_SHIFT, MOUSE_BUTTON_LEFT, MOUSE_BUTTON_NONE
)
from turbokod.geometry import Point, Rect

from support import (
    _VIEW, _assert_layout_contiguous, _contains, _key, _spell_with_dict,
    _temp_path, setup_test_env
)


def test_editor_word_movement() raises:
    var ed = Editor(String("hello world foo"))
    # Ctrl+Right from start: lands at the END of "hello" (col 5).
    _ = ed.handle_key(_key(KEY_RIGHT, MOD_CTRL), _VIEW)
    assert_equal(ed.selections[0].col, 5)
    # Again: end of "world" (col 11) — leading space is skipped.
    _ = ed.handle_key(_key(KEY_RIGHT, MOD_CTRL), _VIEW)
    assert_equal(ed.selections[0].col, 11)
    # Again: end of buffer (col 15) — end of "foo".
    _ = ed.handle_key(_key(KEY_RIGHT, MOD_CTRL), _VIEW)
    assert_equal(ed.selections[0].col, 15)
    # Ctrl+Left walks back to start of each word.
    _ = ed.handle_key(_key(KEY_LEFT, MOD_CTRL), _VIEW)
    assert_equal(ed.selections[0].col, 12)
    _ = ed.handle_key(_key(KEY_LEFT, MOD_CTRL), _VIEW)
    assert_equal(ed.selections[0].col, 6)
    _ = ed.handle_key(_key(KEY_LEFT, MOD_CTRL), _VIEW)
    assert_equal(ed.selections[0].col, 0)


def test_editor_word_movement_punctuation() raises:
    # Word movement stops at the end of each token: a run of word chars,
    # or a run of one repeated punctuation char (``{{`` is one stop,
    # ``="`` is two). Regression for the HTML-attribute report.
    var line = String(
        '<span class="name">Lgh nr: {{  project.location.x }}</span>'
    )
    var ed = Editor(line)
    # Expected end-of-token columns walking Ctrl+Right from col 0:
    # after <, span, class, =, ", name, ", >, Lgh, nr, :, {{,
    # project, ., location, ., x.
    var expected = List[Int]()
    expected.append(1); expected.append(5); expected.append(11)
    expected.append(12); expected.append(13); expected.append(17)
    expected.append(18); expected.append(19); expected.append(22)
    expected.append(25); expected.append(26); expected.append(29)
    expected.append(38); expected.append(39); expected.append(47)
    expected.append(48); expected.append(49)
    for i in range(len(expected)):
        _ = ed.handle_key(_key(KEY_RIGHT, MOD_CTRL), _VIEW)
        assert_equal(ed.selections[0].col, expected[i])
    # Ctrl+Left mirrors: stops on the START of each token.
    ed.move_to(0, 13, False)   # start of "name"
    _ = ed.handle_key(_key(KEY_LEFT, MOD_CTRL), _VIEW)
    assert_equal(ed.selections[0].col, 12)   # start of the " token
    _ = ed.handle_key(_key(KEY_LEFT, MOD_CTRL), _VIEW)
    assert_equal(ed.selections[0].col, 11)   # start of the = token
    _ = ed.handle_key(_key(KEY_LEFT, MOD_CTRL), _VIEW)
    assert_equal(ed.selections[0].col, 6)    # start of "class"


def test_editor_word_movement_across_lines() raises:
    var ed = Editor(String("abc\ndef"))
    # Ctrl+Right from start: end of "abc" on line 0.
    _ = ed.handle_key(_key(KEY_RIGHT, MOD_CTRL), _VIEW)
    assert_equal(ed.selections[0].row, 0); assert_equal(ed.selections[0].col, 3)
    # Again: jumps to start of next line.
    _ = ed.handle_key(_key(KEY_RIGHT, MOD_CTRL), _VIEW)
    assert_equal(ed.selections[0].row, 1); assert_equal(ed.selections[0].col, 0)
    # Ctrl+Left from (1,0): end of previous line.
    _ = ed.handle_key(_key(KEY_LEFT, MOD_CTRL), _VIEW)
    assert_equal(ed.selections[0].row, 0); assert_equal(ed.selections[0].col, 3)


def test_editor_word_backspace() raises:
    # Alt+Backspace (macOS Option+Delete) deletes the word to the left.
    var ed = Editor(String("hello world foo"))
    _ = ed.handle_key(_key(KEY_END), _VIEW)
    _ = ed.handle_key(_key(KEY_BACKSPACE, MOD_ALT), _VIEW)
    assert_equal(ed.buffer.line(0), String("hello world "))
    assert_equal(ed.selections[0].col, 12)
    # Ctrl+Backspace does the same (Windows/Linux convention).
    _ = ed.handle_key(_key(KEY_BACKSPACE, MOD_CTRL), _VIEW)
    assert_equal(ed.buffer.line(0), String("hello "))
    # At column 0 it joins with the previous line.
    var ed2 = Editor(String("abc\ndef"))
    _ = ed2.handle_key(_key(KEY_DOWN), _VIEW)
    _ = ed2.handle_key(_key(KEY_BACKSPACE, MOD_ALT), _VIEW)
    assert_equal(ed2.buffer.line(0), String("abcdef"))
    assert_equal(ed2.selections[0].row, 0); assert_equal(ed2.selections[0].col, 3)


def test_editor_shift_arrow_extends_selection() raises:
    var ed = Editor(String("hello"))
    assert_false(ed.has_selection())
    _ = ed.handle_key(_key(KEY_RIGHT, MOD_SHIFT), _VIEW)
    assert_true(ed.has_selection())
    assert_equal(ed.selections[0].anchor_col, 0); assert_equal(ed.selections[0].col, 1)
    _ = ed.handle_key(_key(KEY_RIGHT, MOD_SHIFT), _VIEW)
    assert_equal(ed.selections[0].anchor_col, 0); assert_equal(ed.selections[0].col, 2)
    # Plain arrow collapses selection.
    _ = ed.handle_key(_key(KEY_RIGHT), _VIEW)
    assert_false(ed.has_selection())
    assert_equal(ed.selections[0].col, 3); assert_equal(ed.selections[0].anchor_col, 3)


def test_editor_shift_ctrl_arrow_composes() raises:
    """Selection and word movement compose: Shift+Ctrl+Right keeps the anchor
    while jumping by a whole word."""
    var ed = Editor(String("hello world foo"))
    var both: UInt8 = MOD_SHIFT | MOD_CTRL
    _ = ed.handle_key(_key(KEY_RIGHT, both), _VIEW)
    assert_true(ed.has_selection())
    assert_equal(ed.selections[0].anchor_col, 0); assert_equal(ed.selections[0].col, 5)
    _ = ed.handle_key(_key(KEY_RIGHT, both), _VIEW)
    assert_equal(ed.selections[0].anchor_col, 0); assert_equal(ed.selections[0].col, 11)
    # Now Shift+Ctrl+Left walks the cursor back through words; anchor stays.
    _ = ed.handle_key(_key(KEY_LEFT, both), _VIEW)
    assert_equal(ed.selections[0].anchor_col, 0); assert_equal(ed.selections[0].col, 6)


def test_editor_cmd_arrow_line_navigation() raises:
    """Cmd+Right jumps to end of line; Cmd+Left jumps to first non-space,
    then to col 0 on a second press. Shift extends the selection."""
    var ed = Editor(String("    hello world"))
    # Cmd+Right from col 0: end of line.
    _ = ed.handle_key(_key(KEY_RIGHT, MOD_META), _VIEW)
    assert_equal(ed.selections[0].col, 15)
    assert_false(ed.has_selection())
    # Cmd+Left from end: lands at first non-space (col 4).
    _ = ed.handle_key(_key(KEY_LEFT, MOD_META), _VIEW)
    assert_equal(ed.selections[0].col, 4)
    # Cmd+Left again: now at first non-space, falls to col 0.
    _ = ed.handle_key(_key(KEY_LEFT, MOD_META), _VIEW)
    assert_equal(ed.selections[0].col, 0)
    # Cmd+Left at col 0 stays at col 0.
    _ = ed.handle_key(_key(KEY_LEFT, MOD_META), _VIEW)
    assert_equal(ed.selections[0].col, 0)
    # Cmd+Shift+Right selects to end of line.
    var meta_shift: UInt8 = MOD_META | MOD_SHIFT
    _ = ed.handle_key(_key(KEY_RIGHT, meta_shift), _VIEW)
    assert_true(ed.has_selection())
    assert_equal(ed.selections[0].anchor_col, 0); assert_equal(ed.selections[0].col, 15)
    # Cmd+Shift+Left from end of line extends back to first non-space.
    _ = ed.handle_key(_key(KEY_LEFT, meta_shift), _VIEW)
    assert_equal(ed.selections[0].anchor_col, 0); assert_equal(ed.selections[0].col, 4)
    # No leading whitespace: Cmd+Left from end goes straight to col 0.
    var ed2 = Editor(String("hello"))
    _ = ed2.handle_key(_key(KEY_END), _VIEW)
    _ = ed2.handle_key(_key(KEY_LEFT, MOD_META), _VIEW)
    assert_equal(ed2.selections[0].col, 0)


def test_editor_cmd_letter_does_not_insert() raises:
    """Cmd+B (or any unbound Cmd chord) used to fall through the
    editor's modifier guard and insert ``b`` into the buffer — the
    check only excluded MOD_CTRL / MOD_ALT. The editor now reports
    the event as unconsumed so the desktop can beep instead, and the
    buffer is left untouched."""
    var ed = Editor(String("hello"))
    var consumed = ed.handle_key(_key(UInt32(ord("b")), MOD_META), _VIEW)
    assert_false(consumed)
    assert_equal(ed.buffer.line(0), String("hello"))


def test_editor_cmd_a_selects_all() raises:
    """Cmd+A should select the whole buffer — same as Ctrl+A on
    Linux/Windows. Without MOD_META in ``clipboard_chord`` only
    Ctrl+A worked, and Cmd+A inserted ``a`` instead."""
    var ed = Editor(String("line one\nline two"))
    var consumed = ed.handle_key(_key(UInt32(ord("a")), MOD_META), _VIEW)
    assert_true(consumed)
    assert_true(ed.has_selection())
    assert_equal(ed.selections[0].anchor_row, 0)
    assert_equal(ed.selections[0].anchor_col, 0)
    assert_equal(ed.selections[0].row, 1)
    assert_equal(ed.selections[0].col, 8)


def test_editor_mouse_click_sets_cursor() raises:
    var ed = Editor(String("hello"))
    _ = ed.handle_mouse(
        Event.mouse_event(Point(3, 0), MOUSE_BUTTON_LEFT, True, False),
        _VIEW,
    )
    assert_equal(ed.selections[0].col, 3)
    assert_false(ed.has_selection())


def test_editor_mouse_drag_extends_selection() raises:
    var ed = Editor(String("hello world"))
    _ = ed.handle_mouse(
        Event.mouse_event(Point(1, 0), MOUSE_BUTTON_LEFT, True, False),
        _VIEW,
    )
    assert_equal(ed.selections[0].col, 1)
    _ = ed.handle_mouse(
        Event.mouse_event(Point(7, 0), MOUSE_BUTTON_LEFT, True, True),
        _VIEW,
    )
    assert_true(ed.has_selection())
    assert_equal(ed.selections[0].anchor_col, 1); assert_equal(ed.selections[0].col, 7)


def test_editor_mouse_click_clamps_to_line() raises:
    var ed = Editor(String("hi"))
    _ = ed.handle_mouse(
        Event.mouse_event(Point(50, 0), MOUSE_BUTTON_LEFT, True, False),
        _VIEW,
    )
    # Past EOL → clamped to line length.
    assert_equal(ed.selections[0].col, 2)


def test_editor_double_click_selects_word() raises:
    var ed = Editor(String("hello world foo"))
    _ = ed.handle_mouse(
        Event.mouse_event(Point(8, 0), MOUSE_BUTTON_LEFT, True, False),
        _VIEW,
    )
    _ = ed.handle_mouse(
        Event.mouse_event(Point(8, 0), MOUSE_BUTTON_LEFT, True, False),
        _VIEW,
    )
    assert_true(ed.has_selection())
    assert_equal(ed.selection_text(), String("world"))


def test_editor_double_click_selects_unicode_word() raises:
    """Double-clicking inside a non-ASCII word selects the whole word.
    Pre-fix this would have selected only ``Godk`` (the ASCII prefix
    up to the first non-letter byte)."""
    # "Godkänn foo" — the cell column for the ``ä`` codepoint is index 4
    # (one cell per codepoint, regardless of UTF-8 byte width).
    var ed = Editor(String("Godkänn foo"))
    _ = ed.handle_mouse(
        Event.mouse_event(Point(4, 0), MOUSE_BUTTON_LEFT, True, False),
        _VIEW,
    )
    _ = ed.handle_mouse(
        Event.mouse_event(Point(4, 0), MOUSE_BUTTON_LEFT, True, False),
        _VIEW,
    )
    assert_true(ed.has_selection())
    assert_equal(ed.selection_text(), String("Godkänn"))


def test_editor_double_click_drag_extends_by_word_forward() raises:
    var ed = Editor(String("hello world foo bar"))
    _ = ed.handle_mouse(
        Event.mouse_event(Point(8, 0), MOUSE_BUTTON_LEFT, True, False),
        _VIEW,
    )
    _ = ed.handle_mouse(
        Event.mouse_event(Point(8, 0), MOUSE_BUTTON_LEFT, True, False),
        _VIEW,
    )
    _ = ed.handle_mouse(
        Event.mouse_event(Point(17, 0), MOUSE_BUTTON_LEFT, True, True),
        _VIEW,
    )
    assert_equal(ed.selection_text(), String("world foo bar"))


def test_editor_double_click_drag_extends_by_word_backward() raises:
    var ed = Editor(String("hello world foo bar"))
    _ = ed.handle_mouse(
        Event.mouse_event(Point(13, 0), MOUSE_BUTTON_LEFT, True, False),
        _VIEW,
    )
    _ = ed.handle_mouse(
        Event.mouse_event(Point(13, 0), MOUSE_BUTTON_LEFT, True, False),
        _VIEW,
    )
    _ = ed.handle_mouse(
        Event.mouse_event(Point(2, 0), MOUSE_BUTTON_LEFT, True, True),
        _VIEW,
    )
    assert_equal(ed.selection_text(), String("hello world foo"))


def test_editor_triple_click_selects_line() raises:
    var ed = Editor(String("first line\nsecond line\nthird line"))
    # Three quick presses on row 1, col 4.
    for _ in range(3):
        _ = ed.handle_mouse(
            Event.mouse_event(Point(4, 1), MOUSE_BUTTON_LEFT, True, False),
            _VIEW,
        )
    # Whole line + trailing newline (since this isn't the last line).
    assert_equal(ed.selection_text(), String("second line\n"))


def test_editor_triple_click_last_line_no_newline() raises:
    var ed = Editor(String("first\nlast"))
    for _ in range(3):
        _ = ed.handle_mouse(
            Event.mouse_event(Point(2, 1), MOUSE_BUTTON_LEFT, True, False),
            _VIEW,
        )
    # Last line: no trailing newline available.
    assert_equal(ed.selection_text(), String("last"))


def test_editor_triple_click_drag_extends_by_line_forward() raises:
    var ed = Editor(String("alpha\nbeta\ngamma\ndelta"))
    for _ in range(3):
        _ = ed.handle_mouse(
            Event.mouse_event(Point(2, 1), MOUSE_BUTTON_LEFT, True, False),
            _VIEW,
        )
    _ = ed.handle_mouse(
        Event.mouse_event(Point(2, 2), MOUSE_BUTTON_LEFT, True, True),
        _VIEW,
    )
    assert_equal(ed.selection_text(), String("beta\ngamma\n"))


def test_editor_triple_click_drag_extends_by_line_backward() raises:
    var ed = Editor(String("alpha\nbeta\ngamma\ndelta"))
    for _ in range(3):
        _ = ed.handle_mouse(
            Event.mouse_event(Point(2, 2), MOUSE_BUTTON_LEFT, True, False),
            _VIEW,
        )
    _ = ed.handle_mouse(
        Event.mouse_event(Point(2, 0), MOUSE_BUTTON_LEFT, True, True),
        _VIEW,
    )
    assert_equal(ed.selection_text(), String("alpha\nbeta\ngamma\n"))


def test_editor_selection_text() raises:
    var ed = Editor(String("hello world"))
    # Select "hello "
    for _ in range(6):
        _ = ed.handle_key(_key(KEY_RIGHT, MOD_SHIFT), _VIEW)
    assert_equal(ed.selection_text(), String("hello "))


def test_editor_selection_text_multiline() raises:
    var ed = Editor(String("ab\ncd\nef"))
    # Select from (0,1) to (2,1) — i.e., "b\ncd\ne"
    ed.move_to(0, 1, False)
    ed.move_to(2, 1, True)
    assert_equal(ed.selection_text(), String("b\ncd\ne"))


def test_editor_alt_arrow_word_jump() raises:
    """MOD_ALT triggers word movement (macOS convention)."""
    var ed = Editor(String("hello world foo"))
    _ = ed.handle_key(_key(KEY_RIGHT, MOD_ALT), _VIEW)
    assert_equal(ed.selections[0].col, 5)   # end of "hello"
    _ = ed.handle_key(_key(KEY_RIGHT, MOD_ALT), _VIEW)
    assert_equal(ed.selections[0].col, 11)  # end of "world"
    _ = ed.handle_key(_key(KEY_LEFT, MOD_ALT), _VIEW)
    assert_equal(ed.selections[0].col, 6)   # start of "world"


def test_editor_word_jump_traverses_unicode_letters() raises:
    """Word-jump must skip a whole Unicode word in one press, not stop
    at every multi-byte boundary inside it. Pre-fix, ``Godkänn`` was
    three "words" and Alt+Right would stop at the byte after ``Godk``,
    inside the ``ä`` codepoint, then again after ``ä``."""
    # "Godkänn foo" — bytes: G(1) o(1) d(1) k(1) ä(2) n(1) n(1) ' '(1) f o o
    # = 8 bytes for Godkänn + space at byte 8 + "foo" at bytes 9-11.
    var ed = Editor(String("Godkänn foo"))
    # First Alt+Right lands at the END of "Godkänn" → byte 8 (the space),
    # proving it traversed the whole word in one press rather than
    # stopping inside the ``ä`` codepoint.
    _ = ed.handle_key(_key(KEY_RIGHT, MOD_ALT), _VIEW)
    assert_equal(ed.selections[0].col, 8)
    # Alt+Left walks back over the whole word to its start.
    _ = ed.handle_key(_key(KEY_LEFT, MOD_ALT), _VIEW)
    assert_equal(ed.selections[0].col, 0)


def test_selection_history_paint_and_keys() raises:
    """The paned history modal paints title + commit list + selected
    patch, and its keys drive selection / patch-scroll / close."""
    var entries = List[LineHistoryEntry]()
    entries.append(LineHistoryEntry(
        String("aaa1111"), String("Ada"), String("2026-05-09"),
        String("Tweak reveal"), String("@@ -1 +1 @@\n+new\n"), False,
    ))
    entries.append(LineHistoryEntry(
        String("bbb2222"), String("Bob"), String("2026-04-01"),
        String("Initial"), String("@@ -0,0 +1 @@\n+first\n"), True,
    ))
    var h = SelectionHistory()
    assert_false(h.active)
    h.open(String("x.mojo:1-3"), entries^)
    assert_true(h.active)
    assert_equal(h.list.selected, 0)

    var screen = Rect(0, 0, 80, 24)
    var c = Canvas(80, 24)
    h.paint(c, screen, 1)
    # Title bar (row 1) starts with "Git History …".
    assert_equal(c.get(1, 1).glyph, String("G"))
    # Left list row 0 is the unpushed commit: a leading "↑" marker (at the
    # 1-cell indent), then the short sha after the 2-cell marker column.
    assert_equal(c.get(1, 2).glyph, String("↑"))
    assert_equal(c.get(3, 2).glyph, String("a"))
    # Row 1 is pushed: no marker (space), sha still in the same column.
    assert_equal(c.get(1, 3).glyph, String(" "))
    assert_equal(c.get(3, 3).glyph, String("b"))
    # Right pane (divider at x=32 for an 80-wide screen) shows the
    # selected commit's patch, starting with its hunk header.
    assert_equal(c.get(33, 2).glyph, String("@"))

    # Down moves the selection and resets the patch scroll.
    h.patch_scroll = 5
    _ = h.handle_event(Event.key_event(KEY_DOWN), screen, 1)
    assert_equal(h.list.selected, 1)
    assert_equal(h.patch_scroll, 0)
    # A non-action key is still swallowed (fully modal).
    assert_true(h.handle_event(Event.key_event(KEY_SPACE), screen, 1))
    # Esc closes.
    _ = h.handle_event(Event.key_event(KEY_ESC), screen, 1)
    assert_false(h.active)


def test_editor_shift_tab_dedents_selected_lines() raises:
    """Shift+Tab on a selection removes one indent unit from each row.
    Lines without leading whitespace are left alone. The selection's
    cursor and anchor cols shrink by the bytes removed on their row."""
    var ed = Editor(String("    alpha\n  beta\ngamma"))
    ed.move_to(0, 4, False)        # cursor after the 4 leading spaces of row 0
    ed.move_to(2, 0, True)         # extend through row 2 (excluded by ec==0)
    _ = ed.handle_key(_key(KEY_TAB, MOD_SHIFT), _VIEW)
    assert_equal(ed.buffer.line(0), String("alpha"))
    assert_equal(ed.buffer.line(1), String("beta"))
    assert_equal(ed.buffer.line(2), String("gamma"))
    # The extend put the cursor on row 2 col 0, where nothing was removed, so
    # it stays put. The anchor is the end that moved: it sat at col 4 of row 0
    # and the 4 spaces in front of it are gone, so it slides to col 0.
    assert_equal(ed.selections[0].row, 2)
    assert_equal(ed.selections[0].col, 0)
    assert_equal(ed.selections[0].anchor_row, 0)
    assert_equal(ed.selections[0].anchor_col, 0)


def test_editor_shift_tab_dedents_cursor_line_without_selection() raises:
    """Shift+Tab with no selection dedents only the cursor's line."""
    var ed = Editor(String("    alpha\n    beta"))
    ed.move_to(1, 6, False)         # row 1, somewhere inside "beta"
    _ = ed.handle_key(_key(KEY_TAB, MOD_SHIFT), _VIEW)
    assert_equal(ed.buffer.line(0), String("    alpha"))
    assert_equal(ed.buffer.line(1), String("beta"))
    assert_equal(ed.selections[0].col, 2)


def test_editor_shift_tab_no_indent_is_noop() raises:
    """Shift+Tab on lines with no leading whitespace must not push an
    undo entry — otherwise undo would step through dead-no-op states."""
    var ed = Editor(String("alpha\nbeta"))
    ed.move_to(0, 0, False)
    ed.move_to(1, 4, True)
    var before = ed.buffer.line(0) + String("|") + ed.buffer.line(1)
    _ = ed.handle_key(_key(KEY_TAB, MOD_SHIFT), _VIEW)
    var after = ed.buffer.line(0) + String("|") + ed.buffer.line(1)
    assert_equal(before, after)


def test_editor_alt_click_adds_extra_caret() raises:
    # Alt+left-click stamps an extra caret at the click point without
    # disturbing the primary or moving the cursor away from where it was.
    var ed = Editor(String("alpha\nbeta\ngamma\n"))
    assert_equal(ed.caret_count(), 1)
    var ev = Event.mouse_event(
        Point(2, 1), MOUSE_BUTTON_LEFT,
        pressed=True, motion=False, mods=MOD_ALT,
    )
    _ = ed.handle_mouse(ev, Rect(0, 0, 40, 5))
    assert_equal(ed.caret_count(), 2)
    # No goto-definition was requested.
    var req = ed.consume_definition_request()
    assert_false(Bool(req))


def test_editor_multi_caret_col0_backspace_joins_rows() raises:
    # Carets on column 0 of several consecutive rows: backspace joins
    # each row into the row above, collapsing the run into one line.
    # The topmost caret (row 0) has nothing above it, so it stays put;
    # the others land at the join columns.
    var ed = Editor(String("a\nb\nc\nd"))
    ed.add_caret_below()
    ed.add_caret_below()
    ed.add_caret_below()
    assert_equal(ed.caret_count(), 4)
    _ = ed.handle_key(_key(KEY_BACKSPACE), _VIEW)
    assert_equal(ed.buffer.line_count(), 1)
    assert_equal(ed.buffer.line(0), String("abcd"))
    # One caret per original line break, plus the stranded row-0 caret.
    var carets = ed._all_carets_asc()
    assert_equal(len(carets), 4)
    assert_equal(carets[0].col, 0)
    assert_equal(carets[1].col, 1)
    assert_equal(carets[2].col, 2)
    assert_equal(carets[3].col, 3)
    # Undo restores the four separate rows and the multi-caret state.
    _ = ed.undo()
    assert_equal(ed.buffer.line_count(), 4)
    assert_equal(ed.caret_count(), 4)


def test_editor_alt_drag_inserts_column_of_cursors() raises:
    # Alt+press then drag-motion straight down: one caret per row from
    # the press row to the row under the pointer, all parked at the same
    # cell column, each clamped to its line's length.
    var ed = Editor(String("hello world\nhi\ngoodbye"))
    # Alt+press at row 0, cell column 3 (mods only sampled on press).
    _ = ed.handle_mouse(
        Event.mouse_event(
            Point(3, 0), MOUSE_BUTTON_LEFT,
            pressed=True, motion=False, mods=MOD_ALT,
        ),
        _VIEW,
    )
    # Drag-motion to row 2 at the same column. Motion events carry no
    # MOD_ALT bit — the box drag must persist via internal state.
    _ = ed.handle_mouse(
        Event.mouse_event(
            Point(3, 2), MOUSE_BUTTON_LEFT,
            pressed=True, motion=True, mods=MOD_NONE,
        ),
        _VIEW,
    )
    var carets = ed._all_carets_asc()
    assert_equal(len(carets), 3)
    # Row 0: cell 3 lands mid-word at byte 3.
    assert_equal(carets[0].row, 0)
    assert_equal(carets[0].col, 3)
    # Row 1 ("hi") is only 2 bytes — the caret clamps to end of line.
    assert_equal(carets[1].row, 1)
    assert_equal(carets[1].col, 2)
    # Row 2 ("goodbye") is long enough — back to byte 3.
    assert_equal(carets[2].row, 2)
    assert_equal(carets[2].col, 3)
    # Pure vertical drag → zero-width carets (cursors, no selection).
    assert_false(ed.has_selection())
    # Release clears the in-flight box-drag state.
    _ = ed.handle_mouse(
        Event.mouse_event(
            Point(3, 2), MOUSE_BUTTON_LEFT,
            pressed=False, motion=False, mods=MOD_NONE,
        ),
        _VIEW,
    )
    assert_false(ed._box_drag_active)


def test_editor_alt_tap_toggles_selection_to_column_and_back() raises:
    # Make a multi-line selection, then an Alt-tap (bare Alt press +
    # release with nothing in between) collapses it into a vertical
    # column of cursors at the selection's start column, clamped per
    # line. A second Alt-tap toggles the original selection back.
    from turbokod.events import MOD_KEY_ALT
    var ed = Editor(String("hello\nhi\nworld"))
    ed.move_to(0, 3, False)        # cursor + anchor at (0, 3)
    ed.move_to(2, 3, True)         # extend → selection (0,3)..(2,3)
    assert_true(ed.has_selection())
    # Alt-tap: press then release, no key in between.
    _ = ed.handle_mod_key(Event.mod_key_event(MOD_KEY_ALT, True))
    _ = ed.handle_mod_key(Event.mod_key_event(MOD_KEY_ALT, False))
    # → three zero-width carets, one per selected row, at cell col 3.
    assert_equal(ed.caret_count(), 3)
    assert_false(ed.has_selection())
    var carets = ed._all_carets_asc()
    assert_equal(carets[0].row, 0)
    assert_equal(carets[0].col, 3)
    # Row 1 ("hi") is too short — caret clamps to end of line.
    assert_equal(carets[1].row, 1)
    assert_equal(carets[1].col, 2)
    assert_equal(carets[2].row, 2)
    assert_equal(carets[2].col, 3)
    # Second Alt-tap toggles the selection back.
    _ = ed.handle_mod_key(Event.mod_key_event(MOD_KEY_ALT, True))
    _ = ed.handle_mod_key(Event.mod_key_event(MOD_KEY_ALT, False))
    assert_equal(ed.caret_count(), 1)
    assert_true(ed.has_selection())
    assert_equal(ed.selections[0].anchor_row, 0)
    assert_equal(ed.selections[0].anchor_col, 3)
    assert_equal(ed.selections[0].row, 2)
    assert_equal(ed.selections[0].col, 3)


def test_editor_alt_tap_hold_arrows_build_cursor_column() raises:
    # Tap Alt, then tap-and-hold Alt (a second press inside the
    # tap-then-hold window) enters column-draw mode; while Alt stays
    # held, Up/Down stamps a fresh caret on the adjacent row.
    from turbokod.events import MOD_KEY_ALT
    var ed = Editor(String("alpha\nbeta\ngamma\ndelta"))
    assert_equal(ed.caret_count(), 1)
    # First tap: press + release (no selection → arms tap-then-hold).
    _ = ed.handle_mod_key(Event.mod_key_event(MOD_KEY_ALT, True))
    _ = ed.handle_mod_key(Event.mod_key_event(MOD_KEY_ALT, False))
    # Hold: second press lands inside the window → column-draw mode.
    _ = ed.handle_mod_key(Event.mod_key_event(MOD_KEY_ALT, True))
    # Alt+Down twice stamps a caret on each row below.
    _ = ed.handle_key(_key(KEY_DOWN, MOD_ALT), _VIEW)
    _ = ed.handle_key(_key(KEY_DOWN, MOD_ALT), _VIEW)
    assert_equal(ed.caret_count(), 3)
    var carets = ed._all_carets_asc()
    assert_equal(carets[0].row, 0)
    assert_equal(carets[1].row, 1)
    assert_equal(carets[2].row, 2)
    # Releasing Alt ends column-draw mode.
    _ = ed.handle_mod_key(Event.mod_key_event(MOD_KEY_ALT, False))
    assert_false(ed._column_mode)


def test_editor_vertical_movement_uses_cell_column() raises:
    """Down through a row of multi-byte characters preserves the visual
    column, not the byte offset. ``ééé`` is 6 bytes / 3 cells; landing
    column 2 (cells) on it must be byte 4, not byte 2 (mid-codepoint)."""
    # Line 0: "abcdef" (6 ASCII), line 1: "ééé" (3 codepoints, 6 bytes).
    var ed = Editor(String("abcdef\néééxyz"))
    _ = ed.handle_key(_key(KEY_RIGHT), _VIEW)
    _ = ed.handle_key(_key(KEY_RIGHT), _VIEW)        # cursor on 'c'
    assert_equal(ed.selections[0].col, 2)
    assert_equal(ed.selections[0].desired_col, 2)
    _ = ed.handle_key(_key(KEY_DOWN), _VIEW)
    # Cell 2 on "éééxyz" is the third é → byte 4, a codepoint boundary.
    assert_equal(ed.selections[0].row, 1)
    assert_equal(ed.selections[0].col, 4)
    assert_equal(ed.selections[0].desired_col, 2)
    _ = ed.handle_key(_key(KEY_UP), _VIEW)
    assert_equal(ed.selections[0].row, 0)
    assert_equal(ed.selections[0].col, 2)


def test_editor_mouse_click_lands_on_codepoint_boundary() raises:
    """A click at cell column N inside a multi-byte run must drop the cursor
    at the *codepoint* at column N, never mid-sequence."""
    var ed = Editor(String("ééé"))
    var view = Rect(0, 0, 40, 10)
    # Cell column 2 → third é → byte offset 4.
    _ = ed.handle_mouse(
        Event.mouse_event(Point(2, 0), MOUSE_BUTTON_LEFT, True, False),
        view,
    )
    assert_equal(ed.selections[0].row, 0)
    assert_equal(ed.selections[0].col, 4)
    # Far past EOL clamps to line end (a boundary).
    _ = ed.handle_mouse(
        Event.mouse_event(Point(20, 0), MOUSE_BUTTON_LEFT, True, False),
        view,
    )
    assert_equal(ed.selections[0].col, 6)


def test_editor_alt_enter_on_diagnostic_stamps_menu_request() raises:
    """Alt+Enter while the cursor sits on a diagnostic must stash a
    ``DiagnosticMenuRequest`` so the host can open the diagnostic menu
    (which then asks the LSP for quickfix code actions). Falls back to
    the spell-action path when both apply — spell is checked first
    because it's the more specific signal.

    A buffer that has *no* diagnostic and *no* misspelled word at the
    cursor must leave the request slot empty and let Alt+Enter pass
    through as an unbound hotkey (return value False)."""
    var ed = Editor(String("x = timedelta()"))
    ed.selections[0].row = 0
    ed.selections[0].col = 5  # inside "timedelta"
    var diags = List[Diagnostic]()
    diags.append(Diagnostic(
        0, 4, 0, 13, DIAG_SEVERITY_ERROR,
        String("Name `timedelta` used when not defined"),
        String("ty"),
    ))
    ed.set_diagnostics(diags^)
    var view = Rect(0, 0, 80, 24)
    var ev = Event.key_event(KEY_ENTER, MOD_ALT)
    var consumed = ed.handle_key(ev, view)
    assert_true(consumed)
    var req_opt = ed.consume_diagnostic_menu_request()
    assert_true(Bool(req_opt))
    var req = req_opt.value()
    # Source-prefixed label is what the menu copies on the Copy row.
    assert_true(req.message.find(String("[ty]")) >= 0)
    assert_true(
        req.message.find(String("timedelta")) >= 0,
    )
    # Underlying diagnostic is carried through so the host can echo it
    # in the codeAction request's ``context.diagnostics``.
    assert_equal(req.diag.severity, DIAG_SEVERITY_ERROR)
    assert_equal(req.diag.start_col, 4)
    # No diagnostic, no spell run, caret on blank space (not an
    # identifier) → Alt+Enter falls through as an unbound hotkey.
    var ed2 = Editor(String("   "))
    ed2.selections[0].row = 0
    ed2.selections[0].col = 1
    var consumed2 = ed2.handle_key(ev, view)
    assert_false(consumed2)


def test_editor_alt_enter_on_identifier_stamps_context_menu_request() raises:
    """Alt+Enter on a plain identifier (no diagnostic, no misspelling)
    opens the symbol-actions context menu — the keyboard counterpart to
    a right-click. It stamps a ``pending_context_menu`` request carrying
    the word + caret coordinates and consumes the key (no newline)."""
    var ed = Editor(String("value = other"))
    ed.selections[0].row = 0
    ed.selections[0].col = 2  # inside "value"
    var view = Rect(0, 0, 80, 24)
    var ev = Event.key_event(KEY_ENTER, MOD_ALT)
    var consumed = ed.handle_key(ev, view)
    assert_true(consumed)
    var req_opt = ed.consume_context_menu_request()
    assert_true(Bool(req_opt))
    var req = req_opt.value()
    assert_equal(req.word, String("value"))
    assert_equal(req.row, 0)
    assert_equal(req.col, 2)
    # The buffer is untouched — Alt+Enter must not split the line.
    assert_equal(ed.buffer.line_count(), 1)
    assert_equal(ed.buffer.line(0), String("value = other"))


def test_smart_wrap_lines_breaks_call_one_item_per_line() raises:
    """A long bracketed call overflowing the width breaks one item per
    line: head ends after the opener at indent 0, each item hangs at
    leading-indent + indent_size, the close rides the last item, and no
    item line starts with whitespace."""
    var line = String(
        "    img = Field(upload='a', default='b', null=True, blank=True)"
    )
    var lines = List[String]()
    lines.append(line)
    var layout = smart_wrap_lines(lines, 30, 4)
    # head + four items (close rides the last item).
    assert_equal(len(layout), 5)
    _assert_layout_contiguous(line, layout)
    # Head sits at the original column; items hang at 4 + 4 = 8.
    assert_equal(layout[0].indent_cells, 0)
    for i in range(1, 5):
        assert_equal(layout[i].indent_cells, 8)
    var bytes = line.as_bytes()
    # Head ends right after the '(' (so the opener is the head's last cell).
    assert_equal(Int(bytes[layout[0].byte_end - 1]), Int(ord("(")))
    # Each item begins on a non-space byte at its expected first char.
    assert_true(Int(bytes[layout[1].byte_start]) != 0x20)
    assert_equal(Int(bytes[layout[1].byte_start]), Int(ord("u")))  # upload
    assert_equal(Int(bytes[layout[2].byte_start]), Int(ord("d")))  # default
    assert_equal(Int(bytes[layout[3].byte_start]), Int(ord("n")))  # null
    assert_equal(Int(bytes[layout[4].byte_start]), Int(ord("b")))  # blank
    # The close bracket lands on the last segment.
    assert_equal(Int(bytes[layout[4].byte_end - 1]), Int(ord(")")))


def test_smart_wrap_lines_short_line_not_broken() raises:
    """A line that already fits the width is one segment even when it
    has bracket/comma structure — smart wrap only breaks overflow."""
    var line = String("f(a, b, c)")
    var lines = List[String]()
    lines.append(line)
    var layout = smart_wrap_lines(lines, 40, 4)
    assert_equal(len(layout), 1)
    assert_equal(layout[0].byte_start, 0)
    assert_equal(layout[0].byte_end, len(line.as_bytes()))
    assert_equal(layout[0].indent_cells, 0)


def test_smart_wrap_lines_comma_threshold_breaks_fitting_line() raises:
    """With a comma threshold set, a line that fits the width is still
    broken one-item-per-line when it has more than ``comma_threshold``
    top-level commas. ``-1`` (default) leaves a fitting line whole."""
    var line = String("f(a, b, c, d)")  # 3 top-level commas
    var lines = List[String]()
    lines.append(line)
    # Default (-1): fits at width 40, stays one segment.
    var off = smart_wrap_lines(lines, 40, 4)
    assert_equal(len(off), 1)
    # Threshold 2: 3 commas > 2 -> break even though it fits. head + 4 items.
    var broken = smart_wrap_lines(lines, 40, 4, comma_threshold=2)
    assert_equal(len(broken), 5)
    _assert_layout_contiguous(line, broken)
    # Threshold 3: 3 commas is NOT > 3 -> stays one segment.
    var at = smart_wrap_lines(lines, 40, 4, comma_threshold=3)
    assert_equal(len(at), 1)
    # Threshold 0: any call with a comma breaks.
    var zero = smart_wrap_lines(lines, 40, 4, comma_threshold=0)
    assert_equal(len(zero), 5)


def test_smart_wrap_lines_comma_threshold_no_structure_stays_whole() raises:
    """The comma trigger only fires on real bracketed structure: a fitting
    line with no breakable call is left whole even with a low threshold,
    rather than being force-fed to the soft-wrap fallback."""
    var line = String("a = b + c")  # no bracket group, no commas
    var lines = List[String]()
    lines.append(line)
    var layout = smart_wrap_lines(lines, 40, 4, comma_threshold=0)
    assert_equal(len(layout), 1)
    assert_equal(layout[0].byte_start, 0)
    assert_equal(layout[0].byte_end, len(line.as_bytes()))


def test_smart_wrap_lines_falls_back_to_soft_wrap() raises:
    """A long line with no breakable bracket structure degrades to the
    exact word-aware soft-wrap layout (``wrap_lines``)."""
    var line = String(
        "the quick brown fox jumps over the lazy dog and keeps running"
    )
    var lines = List[String]()
    lines.append(line)
    var smart = smart_wrap_lines(lines, 20, 4)
    var soft = wrap_lines(lines, 20, indent_size=4, word_aware=True)
    assert_equal(len(smart), len(soft))
    for i in range(len(smart)):
        assert_equal(smart[i].byte_start, soft[i].byte_start)
        assert_equal(smart[i].byte_end, soft[i].byte_end)
        assert_equal(smart[i].indent_cells, soft[i].indent_cells)


def test_smart_wrap_lines_ignores_commas_in_strings_and_nesting() raises:
    """Only depth-1 commas outside strings are item boundaries: commas
    inside a string literal and inside a nested call stay put."""
    var line = String(
        "    g(x=\"a, b\", inner(c, d), e=1, pad_here=2)"
    )
    var lines = List[String]()
    lines.append(line)
    var layout = smart_wrap_lines(lines, 28, 4)
    _assert_layout_contiguous(line, layout)
    # head + 4 items: x=..., inner(...), e=1, padding...
    assert_equal(len(layout), 5)
    var bytes = line.as_bytes()
    assert_equal(Int(bytes[layout[1].byte_start]), Int(ord("x")))      # x=
    assert_equal(Int(bytes[layout[2].byte_start]), Int(ord("i")))      # inner
    assert_equal(Int(bytes[layout[3].byte_start]), Int(ord("e")))      # e=1
    assert_equal(Int(bytes[layout[4].byte_start]), Int(ord("p")))      # padding


def test_smart_wrap_lines_comment_stops_structural_scan() raises:
    """A line whose only brackets/commas live inside a trailing comment
    has no real structure — it falls back to soft wrap (one segment when
    it fits)."""
    var line = String("x = 1  # call(a, b, c) mentioned in a comment here")
    var lines = List[String]()
    lines.append(line)
    # Width that the line fits within -> single segment regardless.
    var layout = smart_wrap_lines(lines, 80, 4, line_comment=String("#"))
    assert_equal(len(layout), 1)
    # Narrow width -> soft-wrap fallback (not a delimiter break at the
    # comment's commas), so continuations carry the hanging indent.
    var narrow = smart_wrap_lines(lines, 18, 4, line_comment=String("#"))
    var soft = wrap_lines(lines, 18, indent_size=4, word_aware=True)
    assert_equal(len(narrow), len(soft))
    for i in range(len(narrow)):
        assert_equal(narrow[i].byte_start, soft[i].byte_start)
        assert_equal(narrow[i].byte_end, soft[i].byte_end)


def test_smart_wrap_lines_style_attr_breaks_one_decl_per_line() raises:
    """``html_attr`` mode breaks an inline ``style="..."`` one CSS
    declaration per line, with the closing quote (+ trailing markup) on
    its own line at the outer indent. The 3-declaration example breaks at
    a threshold of 3 or lower and stays whole at 4."""
    var line = String(
        "<div style=\"position: relative; width: 100%; overflow: hidden;\">"
        "</div>"
    )
    var lines = List[String]()
    lines.append(line)
    var bytes = line.as_bytes()
    # Threshold 3, fits the width: still breaks (3 declarations >= 3).
    var layout = smart_wrap_lines(
        lines, 200, 4, comma_threshold=3, html_attr=True,
    )
    _assert_layout_contiguous(line, layout)
    # head + 3 declarations + closing-quote row.
    assert_equal(len(layout), 5)
    # Head ends right after the opening quote.
    assert_equal(Int(bytes[layout[0].byte_end - 1]), Int(ord("\"")))
    assert_equal(layout[0].indent_cells, 0)
    # Declarations hang at leading-indent (0) + indent_size (4).
    assert_equal(Int(bytes[layout[1].byte_start]), Int(ord("p")))  # position
    assert_equal(Int(bytes[layout[2].byte_start]), Int(ord("w")))  # width
    assert_equal(Int(bytes[layout[3].byte_start]), Int(ord("o")))  # overflow
    for i in range(1, 4):
        assert_equal(layout[i].indent_cells, 4)
    # The closing quote opens the last row, back at indent 0.
    assert_equal(Int(bytes[layout[4].byte_start]), Int(ord("\"")))
    assert_equal(layout[4].indent_cells, 0)

    # Threshold 4: 3 declarations is below 4 and it fits -> stays whole.
    var whole = smart_wrap_lines(
        lines, 200, 4, comma_threshold=4, html_attr=True,
    )
    assert_equal(len(whole), 1)

    # Off by default (-1) when it fits: one segment.
    var off = smart_wrap_lines(lines, 200, 4, html_attr=True)
    assert_equal(len(off), 1)


def test_smart_wrap_lines_style_attr_semicolons_in_url_and_string() raises:
    """Top-level ``;`` split declarations, but a ``;`` inside ``url(...)``
    or an inner quoted string is not a separator."""
    var line = String(
        "<span style=\"background: url(a;b.png); content: ';';\"></span>"
    )
    var lines = List[String]()
    lines.append(line)
    var layout = smart_wrap_lines(
        lines, 300, 4, comma_threshold=0, html_attr=True,
    )
    _assert_layout_contiguous(line, layout)
    var bytes = line.as_bytes()
    # head + 2 declarations (background, content) + closing-quote row.
    assert_equal(len(layout), 4)
    assert_equal(Int(bytes[layout[1].byte_start]), Int(ord("b")))  # background
    assert_equal(Int(bytes[layout[2].byte_start]), Int(ord("c")))  # content
    assert_equal(Int(bytes[layout[3].byte_start]), Int(ord("\"")))


def test_smart_wrap_lines_html_attr_generalizes_to_onclick() raises:
    """``html_attr`` mode is not style-specific: an ``onclick`` (or any
    other) handler with semicolon-separated statements breaks one statement
    per line. A plain ``class`` attribute before it has no top-level ``;``,
    so it's skipped in favor of the handler. JS ``;`` inside ``(...)`` (a
    ``for(;;)``) or an inner string don't count as separators."""
    var line = String(
        "<button class=\"btn\" onclick=\"open(); track('a;b'); close();\">"
        "Go</button>"
    )
    var lines = List[String]()
    lines.append(line)
    var layout = smart_wrap_lines(
        lines, 300, 4, comma_threshold=0, html_attr=True,
    )
    _assert_layout_contiguous(line, layout)
    var bytes = line.as_bytes()
    # head ends right after the onclick opening quote (class is skipped).
    assert_equal(Int(bytes[layout[0].byte_end - 1]), Int(ord("\"")))
    var ho = layout[0].byte_end - 1
    # The selected quote is the onclick value's, not class's: the bytes just
    # before it spell `onclick=`.
    assert_equal(Int(bytes[ho - 1]), Int(ord("=")))
    assert_equal(Int(bytes[ho - 2]), Int(ord("k")))  # onclic[k]
    # head + 3 statements (open/track/close) + closing-quote row.
    assert_equal(len(layout), 5)
    assert_equal(Int(bytes[layout[1].byte_start]), Int(ord("o")))  # open()
    assert_equal(Int(bytes[layout[2].byte_start]), Int(ord("t")))  # track(...)
    assert_equal(Int(bytes[layout[3].byte_start]), Int(ord("c")))  # close()
    assert_equal(Int(bytes[layout[4].byte_start]), Int(ord("\"")))
    for i in range(1, 4):
        assert_equal(layout[i].indent_cells, 4)


def test_smart_wrap_lines_html_attr_breaks_all_attributes() raises:
    """Every semicolon-delimited attribute on the line breaks, not just the
    first: an ``onclick`` and a ``style`` on the same tag both go one item
    per line, the bridge between them (closing quote of one + opening of the
    next) is a structural indent-0 row, and the trailing tail closes flush."""
    var line = String(
        "<button onclick=\"open(); close();\" "
        "style=\"color: red; width: 100%;\">Go</button>"
    )
    var lines = List[String]()
    lines.append(line)
    var layout = smart_wrap_lines(
        lines, 400, 4, comma_threshold=0, html_attr=True,
    )
    _assert_layout_contiguous(line, layout)
    var bytes = line.as_bytes()
    # head, open(), close(), bridge ("/style="), color, width, tail.
    assert_equal(len(layout), 7)
    assert_equal(layout[0].indent_cells, 0)                       # head
    assert_equal(Int(bytes[layout[1].byte_start]), Int(ord("o")))  # open()
    assert_equal(Int(bytes[layout[2].byte_start]), Int(ord("c")))  # close()
    assert_equal(layout[1].indent_cells, 4)
    assert_equal(layout[2].indent_cells, 4)
    # Bridge row: closing quote of onclick, back at indent 0.
    assert_equal(Int(bytes[layout[3].byte_start]), Int(ord("\"")))
    assert_equal(layout[3].indent_cells, 0)
    assert_equal(Int(bytes[layout[4].byte_start]), Int(ord("c")))  # color
    assert_equal(Int(bytes[layout[5].byte_start]), Int(ord("w")))  # width
    assert_equal(layout[4].indent_cells, 4)
    assert_equal(layout[5].indent_cells, 4)
    # Tail row: closing quote of style + ">Go</button>", at indent 0.
    assert_equal(Int(bytes[layout[6].byte_start]), Int(ord("\"")))
    assert_equal(layout[6].indent_cells, 0)


def test_editor_alt_enter_on_misspelling_emits_pending_action() raises:
    """Alt+Enter while the cursor is parked inside a misspelled-word
    underline should stamp ``pending_spell_action`` with that word
    rather than splitting the line. The editor must NOT touch the
    buffer (no row split) — the host opens the popup over the still-
    intact text."""
    var words = List[String]()
    words.append(String("hello"))
    var speller = _spell_with_dict(words)
    var path = _temp_path(String("_spell_alt_enter.py"))
    assert_true(write_file(path, String("# helo\n")))
    var ed = Editor.from_file(path)
    var registry = GrammarRegistry()
    ed.flush_highlights(registry, speller)
    assert_equal(len(ed.spell_highlights), 1)
    # Park the cursor in the middle of "helo".
    ed.selections[0].row = 0
    ed.selections[0].col = 3
    var line_count_before = ed.buffer.line_count()
    var alt_enter = Event.key_event(KEY_ENTER, MOD_ALT)
    var consumed = ed.handle_key(alt_enter, Rect(0, 0, 40, 5))
    assert_true(consumed)
    # Buffer must be unchanged: Alt+Enter on a misspelling is a
    # menu-open gesture, not an Enter.
    assert_equal(ed.buffer.line_count(), line_count_before)
    var sa_opt = ed.consume_spell_action_request()
    assert_true(Bool(sa_opt))
    var sa = sa_opt.value()
    assert_equal(sa.word, String("helo"))
    assert_equal(sa.row, 0)
    assert_equal(sa.col_start, 2)
    assert_equal(sa.col_end, 6)
    # The slot is one-shot.
    assert_false(Bool(ed.consume_spell_action_request()))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_alt_enter_outside_misspelling_does_not_consume() raises:
    """Alt+Enter on a row without any misspelling must fall through —
    the editor returns False so the host's hotkey table can bind it
    to something else. No buffer mutation either way."""
    var words = List[String]()
    words.append(String("hello"))
    words.append(String("world"))
    var speller = _spell_with_dict(words)
    var path = _temp_path(String("_spell_alt_outside.py"))
    assert_true(write_file(path, String("# hello world\n")))
    var ed = Editor.from_file(path)
    var registry = GrammarRegistry()
    ed.flush_highlights(registry, speller)
    assert_equal(len(ed.spell_highlights), 0)
    var line_count_before = ed.buffer.line_count()
    var alt_enter = Event.key_event(KEY_ENTER, MOD_ALT)
    var consumed = ed.handle_key(alt_enter, Rect(0, 0, 40, 5))
    assert_false(consumed)
    assert_equal(ed.buffer.line_count(), line_count_before)
    assert_false(Bool(ed.consume_spell_action_request()))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_multiline_diagnostic_tooltip_renders_each_line() raises:
    """Pyright (and other LSPs) often emit diagnostics with literal
    newlines inside the message — an explanation block, an offending
    snippet, then a conclusion. Rendering must honour those breaks
    rather than writing the ``\\n`` as a cell glyph and leaving holes
    of editor blue inside the popup."""
    var ed = Editor(String("alpha beta gamma\nlambda omega\n"))
    var diags = List[Diagnostic]()
    diags.append(Diagnostic(
        0, 6, 0, 10, DIAG_SEVERITY_ERROR,
        # Real-shape pyright diagnostic: header line, indented
        # snippet of the code under review, conclusion line.
        String(
            "\"Meta\" overrides symbol of same name in class \"Table\"\n"
            "  \"myapp.iommi.Table.Meta\" = [\n"
            "  ] is not assignable to "
            "\"myapp.prospects.views.StartProjectQueue.Meta\""
        ),
        String("pyright"),
    ))
    ed.set_diagnostics(diags^)
    var view = Rect(0, 0, 80, 20)
    _ = ed.handle_mouse(
        Event.mouse_event(Point(7, 0), MOUSE_BUTTON_NONE, True, True),
        view,
    )
    assert_equal(ed._minimap_hover_kind, 3)
    var canvas = Canvas(80, 20)
    canvas.fill(view, String(" "), default_attr())
    ed.paint(canvas, view, False)
    # Locate popup interior.
    var top_y = -1
    var left_x = -1
    var right_x = -1
    for y in range(view.b.y):
        for x in range(view.b.x):
            if canvas.get(x, y).glyph == String("┌"):
                top_y = y
                left_x = x
                var xi = x + 1
                while xi < view.b.x:
                    if canvas.get(xi, y).glyph == String("┐"):
                        right_x = xi
                        break
                    xi += 1
                break
        if top_y >= 0:
            break
    assert_true(top_y >= 0)
    var bottom_y = -1
    var by = top_y + 1
    while by < view.b.y:
        if canvas.get(left_x, by).glyph == String("└"):
            bottom_y = by
            break
        by += 1
    assert_true(bottom_y > top_y)
    # Every cell in the popup interior must (a) carry the popup's
    # gray background — the fill must not have left any cells on the
    # editor's blue — and (b) carry a printable glyph, not a stray
    # control char (``\n``, ``\r``, ``\t``) that would render as a
    # weird gap.
    for y in range(top_y + 1, bottom_y):
        for x in range(left_x + 1, right_x):
            var cell = canvas.get(x, y)
            assert_true(cell.attr.bg != BLUE)
            var g = cell.glyph
            assert_true(g != String("\n"))
            assert_true(g != String("\r"))
            assert_true(g != String("\t"))
    # The header line must appear verbatim in some popup row.
    var found_header = False
    for y in range(top_y + 1, bottom_y):
        var row_text = String("")
        for x in range(left_x + 1, right_x):
            row_text = row_text + canvas.get(x, y).glyph
        if _contains(row_text, String("\"Meta\" overrides symbol")):
            found_header = True
            break
    assert_true(found_header)


def main() raises:
    setup_test_env()
    test_editor_word_movement()
    test_editor_word_movement_punctuation()
    test_editor_word_movement_across_lines()
    test_editor_word_backspace()
    test_editor_shift_arrow_extends_selection()
    test_editor_shift_ctrl_arrow_composes()
    test_editor_cmd_arrow_line_navigation()
    test_editor_cmd_letter_does_not_insert()
    test_editor_cmd_a_selects_all()
    test_editor_mouse_click_sets_cursor()
    test_editor_mouse_drag_extends_selection()
    test_editor_mouse_click_clamps_to_line()
    test_editor_double_click_selects_word()
    test_editor_double_click_selects_unicode_word()
    test_editor_double_click_drag_extends_by_word_forward()
    test_editor_double_click_drag_extends_by_word_backward()
    test_editor_triple_click_selects_line()
    test_editor_triple_click_last_line_no_newline()
    test_editor_triple_click_drag_extends_by_line_forward()
    test_editor_triple_click_drag_extends_by_line_backward()
    test_editor_selection_text()
    test_editor_selection_text_multiline()
    test_editor_alt_arrow_word_jump()
    test_editor_word_jump_traverses_unicode_letters()
    test_selection_history_paint_and_keys()
    test_editor_shift_tab_dedents_selected_lines()
    test_editor_shift_tab_dedents_cursor_line_without_selection()
    test_editor_shift_tab_no_indent_is_noop()
    test_editor_alt_click_adds_extra_caret()
    test_editor_multi_caret_col0_backspace_joins_rows()
    test_editor_alt_drag_inserts_column_of_cursors()
    test_editor_alt_tap_toggles_selection_to_column_and_back()
    test_editor_alt_tap_hold_arrows_build_cursor_column()
    test_editor_vertical_movement_uses_cell_column()
    test_editor_mouse_click_lands_on_codepoint_boundary()
    test_editor_alt_enter_on_diagnostic_stamps_menu_request()
    test_editor_alt_enter_on_identifier_stamps_context_menu_request()
    test_smart_wrap_lines_breaks_call_one_item_per_line()
    test_smart_wrap_lines_short_line_not_broken()
    test_smart_wrap_lines_comma_threshold_breaks_fitting_line()
    test_smart_wrap_lines_comma_threshold_no_structure_stays_whole()
    test_smart_wrap_lines_falls_back_to_soft_wrap()
    test_smart_wrap_lines_ignores_commas_in_strings_and_nesting()
    test_smart_wrap_lines_comment_stops_structural_scan()
    test_smart_wrap_lines_style_attr_breaks_one_decl_per_line()
    test_smart_wrap_lines_style_attr_semicolons_in_url_and_string()
    test_smart_wrap_lines_html_attr_generalizes_to_onclick()
    test_smart_wrap_lines_html_attr_breaks_all_attributes()
    test_editor_alt_enter_on_misspelling_emits_pending_action()
    test_editor_alt_enter_outside_misspelling_does_not_consume()
    test_editor_multiline_diagnostic_tooltip_renders_each_line()
    print("editor_select: 51 tests passed")
