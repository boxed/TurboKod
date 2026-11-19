"""Edits that change the line count are tokenized incrementally: the cached
rows below the edit move with their text (``TextBuffer.take_edit_span`` →
``_move_cached_tail``) rather than the whole file being tokenized again,
and what comes out has to equal a full pass, whatever the edits were."""

from std.testing import TestSuite, assert_equal, assert_true
from turbokod.editor import Editor
from turbokod.events import KEY_BACKSPACE, KEY_DELETE, KEY_ENTER
from turbokod.highlight import (
    GrammarRegistry, HighlightCache, HighlightList, sync_highlights,
)
from turbokod.spell import Speller
from support import _VIEW, _key, setup_test_env


def _python_text() -> String:
    return String(
        "import os\n"
        + "\n"
        + "def first(a, b):\n"
        + "    \"\"\"Docstring over\n"
        + "    two lines.\"\"\"\n"
        + "    x = [1, 2, 3]  # trailing\n"
        + "    return 'text' + str(a)\n"
        + "\n"
        + "class Thing:\n"
        + "    name = \"thing\"\n"
        + "\n"
        + "    def method(self):\n"
        + "        if self.name:\n"
        + "            return {\"k\": (1, 2)}\n"
        + "        return None\n"
        + "\n"
        + "VALUE = '''triple\n"
        + "single'''\n"
        + "print(VALUE)\n"
    )


def _rust_text() -> String:
    return String(
        "use std::fmt;\n"
        + "\n"
        + "/* a block comment\n"
        + "   over two lines */\n"
        + "fn first(a: u32) -> u32 {\n"
        + "    let s = \"text\"; // trailing\n"
        + "    a + 1\n"
        + "}\n"
        + "\n"
        + "struct Thing {\n"
        + "    name: String,\n"
        + "}\n"
        + "\n"
        + "impl Thing {\n"
        + "    fn method(&self) -> Option<(u32, u32)> {\n"
        + "        if self.name.is_empty() { return None; }\n"
        + "        Some((1, 2))\n"
        + "    }\n"
        + "}\n"
    )


def _assert_matches_full_pass(
    ed: Editor, ext: String, mut registry: GrammarRegistry, step: Int,
) raises:
    """``ed.highlights`` against a tokenize of the same lines from nothing."""
    var cache = HighlightCache()
    var full = HighlightList()
    sync_highlights(ext, ed.buffer.lines, 0, registry, cache, full, -1)
    if len(ed.highlights) != len(full):
        print("step", step, "count", len(ed.highlights), "full", len(full))
    assert_equal(len(ed.highlights), len(full))
    for i in range(len(full)):
        var a = ed.highlights[i]
        var b = full[i]
        if a.row != b.row or a.col_start != b.col_start \
                or a.col_end != b.col_end or a.attr != b.attr:
            print("step", step, "highlight", i, "row", a.row, "full row", b.row)
        assert_equal(a.row, b.row)
        assert_equal(a.col_start, b.col_start)
        assert_equal(a.col_end, b.col_end)
        assert_true(a.attr == b.attr)


def _random_edits(ext: String, text: String, seed: Int, steps: Int) raises:
    """Type, split, join, paste, delete selections and undo at random,
    comparing with a full pass after every flush — and flushing only after
    most edits, so several land in one."""
    var registry = GrammarRegistry()
    var speller = Speller()
    var ed = Editor(text)
    ed.file_path = String("fuzz.") + ext
    ed.flush_highlights(registry, speller)
    _assert_matches_full_pass(ed, ext, registry, -1)
    var chars = String("\"#()x '/*{}")
    var pastes = [
        String("a = \"\"\"x\ny\"\"\"\nz\n"), String("/* c\n d */\n"),
        String("one\ntwo\nthree"), String("\n\n"), String("# note"),
    ]
    var state = seed
    for step in range(steps):
        state = (state * 1103515245 + 12345) % 2147483648
        var roll = (state // 65536) % 100
        state = (state * 1103515245 + 12345) % 2147483648
        var pick = state // 65536
        var rows = ed.buffer.line_count()
        if roll < 22:
            var cb = chars.as_bytes()
            _ = ed.handle_key(_key(UInt32(Int(cb[pick % len(cb)]))), _VIEW)
        elif roll < 38:
            _ = ed.handle_key(_key(KEY_ENTER), _VIEW)
        elif roll < 50:
            _ = ed.handle_key(_key(KEY_BACKSPACE), _VIEW)
        elif roll < 58:
            _ = ed.handle_key(_key(KEY_DELETE), _VIEW)
        elif roll < 66:
            ed.paste_text(pastes[pick % len(pastes)])
        elif roll < 74:
            _ = ed.undo()
        elif roll < 78:
            _ = ed.redo()
        elif roll < 88:
            # A selection over a few rows, replaced or deleted next.
            var top = pick % rows
            var bottom = min(rows - 1, top + 1 + (pick // 7) % 3)
            ed.move_to(top, (pick // 3) % (ed.buffer.line_length(top) + 1), False)
            ed.move_to(bottom, (pick // 5) % (ed.buffer.line_length(bottom) + 1), True)
        else:
            var row = pick % rows
            ed.move_to(row, (pick // 11) % (ed.buffer.line_length(row) + 1), False)
        if (pick // 13) % 3 != 0:
            ed.flush_highlights(registry, speller)
            _assert_matches_full_pass(ed, ext, registry, step)
    ed.flush_highlights(registry, speller)
    _assert_matches_full_pass(ed, ext, registry, steps)
    registry.release()


def test_random_python_edits_match_a_full_pass() raises:
    _random_edits(String("py"), _python_text(), 7, 400)
    _random_edits(String("py"), _python_text(), 20261119, 400)


def test_random_rust_edits_match_a_full_pass() raises:
    _random_edits(String("rs"), _rust_text(), 3, 400)
    _random_edits(String("rs"), _rust_text(), 99991, 400)


def test_a_split_or_joined_line_is_not_a_full_pass() raises:
    # Every Enter used to tokenize the whole file again: the cache's rows
    # no longer lined up with the buffer's, and nothing said where the
    # edit was.
    var registry = GrammarRegistry()
    var speller = Speller()
    var ed = Editor(_python_text())
    ed.file_path = String("a.py")
    ed.flush_highlights(registry, speller)
    assert_equal(ed._hl_cache.full_passes, 1)
    ed.move_to(9, 4, False)
    _ = ed.handle_key(_key(KEY_ENTER), _VIEW)
    ed.flush_highlights(registry, speller)
    _ = ed.handle_key(_key(KEY_BACKSPACE), _VIEW)
    ed.flush_highlights(registry, speller)
    ed.paste_text(String("first = 1\nsecond = 2\nthird = 3\n"))
    ed.flush_highlights(registry, speller)
    assert_equal(ed._hl_cache.full_passes, 1)
    _assert_matches_full_pass(ed, String("py"), registry, 0)
    # …and undoing and redoing it.
    assert_true(ed.undo())
    ed.flush_highlights(registry, speller)
    assert_true(ed.redo())
    ed.flush_highlights(registry, speller)
    assert_equal(ed._hl_cache.full_passes, 1)
    _assert_matches_full_pass(ed, String("py"), registry, 1)
    registry.release()


def test_the_buffer_reports_the_rows_an_edit_left_alone() raises:
    var ed = Editor(String("a\nb\nc\nd\ne\nf"))
    _ = ed.buffer.take_edit_span()
    # Nothing since: more rows than there are, top and bottom.
    var none = ed.buffer.take_edit_span()
    assert_true(none[0] > 6 and none[1] > 6)
    # A split: the row and the new one below it are the edit.
    _ = ed.buffer.split(2, 1)
    var split = ed.buffer.take_edit_span()
    assert_equal(split[0], 2)
    assert_equal(split[1], 3)
    # Two edits before the next take: from the upper one to the lower.
    ed.buffer.delete_rows(5, 1)
    ed.buffer.insert(1, 0, String("x"))
    var both = ed.buffer.take_edit_span()
    assert_equal(both[0], 1)
    assert_equal(both[1], 1)
    # A whole new line list: what the two have in common at each end.
    var lines = ed.buffer.lines.copy()
    lines[3] = String("changed")
    ed.buffer.replace_lines(lines^, List[Bool]())
    var swapped = ed.buffer.take_edit_span()
    assert_equal(swapped[0], 3)
    assert_equal(swapped[1], ed.buffer.line_count() - 4)


def main() raises:
    setup_test_env()
    TestSuite.discover_tests[__functions_in_module()]().run()
