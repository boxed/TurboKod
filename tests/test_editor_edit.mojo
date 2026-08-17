"""Editor text mutation: typing, cut/paste, brackets, folds.

One of the per-topic suites split out of the former
``test_basic.mojo``; shared fixtures live in ``tests/support.mojo``
and ``scripts/run_tests.sh`` runs every suite.
"""

from std.ffi import external_call
from std.testing import assert_equal, assert_false, assert_true
from turbokod.canvas import Canvas
from turbokod.cell import Cell
from turbokod.colors import (
    BLUE, LIGHT_GREEN, LIGHT_RED, STYLE_UNDERLINE, STYLE_UNDERLINE_CURLY,
    YELLOW, CARET_BG, CARET_FG, EDITOR_BG, EDITOR_FG, SYN_IDENT, default_attr
)
from turbokod.editor import (
    Editor, _UNDO_STACK_BYTE_BUDGET, _UNDO_STACK_LIMIT,
    _UNDO_STACK_MIN_ENTRIES
)
from turbokod.kwarg_conceal import (
    build_concealed_segment, kwarg_conceal_ranges,
    kwarg_separator_for_extension
)
from turbokod.save_as_dialog import SaveAsDialog
from turbokod.desktop import Desktop
from turbokod.file_io import basename, read_file, write_file
from turbokod.git_changes import (
    GIT_CHANGE_ADDED, GIT_CHANGE_MODIFIED, GIT_CHANGE_NONE
)
from turbokod.search_options import SearchOptions
from turbokod.text_view import wrap_lines
from turbokod.lsp_dispatch import (
    CompletionItem, DIAG_SEVERITY_ERROR, DIAG_SEVERITY_HINT,
    DIAG_SEVERITY_WARNING, Diagnostic, TextEditEntry
)
from turbokod.highlight import (
    GrammarRegistry, Highlight, highlight_for_extension,
    highlight_keyword_attr, highlight_string_attr
)
from turbokod.posix import which
from turbokod.spell import Speller, user_dict_path
from turbokod.config import WRAP_NONE, WRAP_SOFT
from turbokod.events import (
    Event, KEY_BACKSPACE, KEY_DELETE, KEY_DOWN, KEY_END, KEY_ENTER, KEY_HOME,
    KEY_LEFT, KEY_PAGEDOWN, KEY_PAGEUP, KEY_RIGHT, KEY_TAB, KEY_UP, MOD_ALT,
    MOD_CTRL, MOD_NONE, MOD_SHIFT, MOUSE_BUTTON_LEFT, MOUSE_BUTTON_NONE,
    MOUSE_BUTTON_RIGHT
)
from turbokod.geometry import Point, Rect
from turbokod.window import Window

from support import (
    _VIEW, _contains, _hl_set, _key, _spell_with_dict, _temp_path,
    setup_test_env
)


def test_editor_fold_collapse() raises:
    """Collapsing a fold region hides its inner rows from the layout, makes
    vertical movement step over them, and snaps move_to off them; expanding
    restores. The start line stays visible."""
    var ed = Editor(String("a\nb\nc\nd\ne\nf"))  # lines 0..5
    var regions = List[TextEditEntry]()
    regions.append(TextEditEntry(1, 0, 3, 0, String("")))  # fold lines 1..3
    ed.set_fold_regions(regions^)
    assert_true(not ed._is_row_hidden(2))      # not folded yet
    ed.toggle_fold_at(1)                        # collapse
    assert_true(not ed._is_row_hidden(1))      # start stays visible
    assert_true(ed._is_row_hidden(2))
    assert_true(ed._is_row_hidden(3))
    assert_true(not ed._is_row_hidden(4))
    # move_to onto a hidden row snaps up to the fold start.
    ed.move_to(2, 0, False)
    assert_equal(ed.selections[0].row, 1)
    # Down-arrow from the start steps over the collapsed body to line 4.
    ed.move_to(1, 0, False)
    ed._move_down(False, 80)
    assert_equal(ed.selections[0].row, 4)
    # Up-arrow from line 4 steps back over the body to the start (1).
    ed._move_up(False, 80)
    assert_equal(ed.selections[0].row, 1)
    # The layout omits hidden rows 2 and 3.
    var layout = ed._layout_lines(10, 80)
    var saw2 = False
    var saw3 = False
    for i in range(len(layout)):
        if layout[i].line_idx == 2:
            saw2 = True
        if layout[i].line_idx == 3:
            saw3 = True
    assert_true(not saw2)
    assert_true(not saw3)
    # Expanding restores visibility.
    ed.toggle_fold_at(1)
    assert_true(not ed._is_row_hidden(2))


def test_editor_sticky_rows() raises:
    """Sticky scroll pins the enclosing-scope header chain (the lines whose
    leading indentation decreases step by step above the viewport top),
    outermost first. Pure indentation — no language parsing."""
    #  0 class A:
    #  1     def f():
    #  2         x = 1
    #  3         y = 2
    #  4
    #  5     def g():
    #  6         z = 3
    var ed = Editor(
        String("class A:\n    def f():\n        x = 1\n        y = 2\n")
        + String("\n    def g():\n        z = 3")
    )
    # Inside f(): both the class and def headers stick, class first.
    var s3 = ed._sticky_rows(3, 5)
    assert_equal(len(s3), 2)
    assert_equal(s3[0], 0)
    assert_equal(s3[1], 1)
    # On the def line itself only the class encloses it.
    var s1 = ed._sticky_rows(1, 5)
    assert_equal(len(s1), 1)
    assert_equal(s1[0], 0)
    # Top-level line has nothing above it.
    assert_equal(len(ed._sticky_rows(0, 5)), 0)
    # A blank top line borrows the indent of the first real line below it.
    # Row 4 sits above ``def g`` (indent 4), so only the class encloses
    # that level — ``def f`` has already scrolled out of context.
    var s4 = ed._sticky_rows(4, 5)
    assert_equal(len(s4), 1)
    assert_equal(s4[0], 0)
    # Inside g(): class + g header, not the sibling f.
    var s6 = ed._sticky_rows(6, 5)
    assert_equal(len(s6), 2)
    assert_equal(s6[0], 0)
    assert_equal(s6[1], 5)
    # Budget caps the depth.
    assert_equal(len(ed._sticky_rows(3, 1)), 1)


def test_editor_sticky_rows_multiline() raises:
    """A multi-line logical line is grabbed in full: a ``def`` signature
    broken across rows, and an opener like ``target = (`` whose body sits
    below it. A dedented continuation (``):``) snaps back to its opener
    rather than being pinned on its own."""
    #  0 def f(
    #  1     a,
    #  2     b,
    #  3 ):
    #  4     x = (
    #  5         a
    #  6         + b
    #  7     )
    #  8     return x
    var ed = Editor(
        String("def f(\n    a,\n    b,\n):\n    x = (\n        a\n")
        + String("        + b\n    )\n    return x")
    )
    # Top at the body line ``return x`` (row 8): the whole broken
    # signature sticks — its picked dedent ``):`` snaps to ``def f(`` and
    # expands back down through ``):``.
    var s8 = ed._sticky_rows(8, 8)
    assert_equal(len(s8), 4)
    assert_equal(s8[0], 0)  # def f(
    assert_equal(s8[1], 1)  # a,
    assert_equal(s8[2], 2)  # b,
    assert_equal(s8[3], 3)  # ):
    # Top inside the ``x = (`` expression (row 6, ``+ b``): the signature
    # plus the full assignment expression stick.
    var s6 = ed._sticky_rows(6, 8)
    assert_equal(len(s6), 8)
    assert_equal(s6[0], 0)  # def f(
    assert_equal(s6[3], 3)  # ):
    assert_equal(s6[4], 4)  # x = (
    assert_equal(s6[5], 5)  # a
    assert_equal(s6[6], 6)  # + b
    assert_equal(s6[7], 7)  # )


def test_editor_sticky_scroll_paints_headers() raises:
    """Scrolled into a nested body, the sticky band overlays the top rows
    with the enclosing-scope headers and underlines the bottom row as a
    divider. Headless paint pass — guards the overlay against crashes /
    off-by-ones the pure ``_sticky_rows`` test can't reach."""
    var ed = Editor(
        String("class A:\n    def f():\n        x = 1\n        y = 2\n")
        + String("\n    def g():\n        z = 3")
    )
    ed.scroll_y = 3  # top visible buffer row is "        y = 2"
    var c = Canvas(40, 10)
    ed.paint(c, Rect(0, 0, 40, 10), False)
    # Row 0: "class A:" (outermost), row 1: "    def f():".
    assert_equal(c.get(0, 0).glyph, String("c"))
    assert_equal(c.get(6, 0).glyph, String("A"))  # "class " then A
    assert_equal(c.get(4, 1).glyph, String("d"))  # def, after 4-space indent
    # Bottom sticky row (y=1) carries the underline divider.
    assert_true((c.get(0, 1).attr.style & STYLE_UNDERLINE) != 0)
    # The row above the divider is not underlined.
    assert_true((c.get(0, 0).attr.style & STYLE_UNDERLINE) == 0)
    # Toggling sticky off leaves the scrolled content unobscured: row 0
    # shows the real top line "        y = 2", not the class header.
    ed.sticky_scroll = False
    var c2 = Canvas(40, 10)
    ed.paint(c2, Rect(0, 0, 40, 10), False)
    assert_equal(c2.get(8, 0).glyph, String("y"))


def test_editor_typing_and_arrows() raises:
    var ed = Editor(String("hello"))
    assert_equal(ed.selections[0].col, 0)
    _ = ed.handle_key(_key(KEY_END), _VIEW)
    assert_equal(ed.selections[0].col, 5)
    _ = ed.handle_key(_key(UInt32(ord("!"))), _VIEW)
    assert_equal(ed.buffer.line(0), String("hello!"))
    assert_equal(ed.selections[0].col, 6)
    _ = ed.handle_key(_key(KEY_LEFT), _VIEW)
    assert_equal(ed.selections[0].col, 5)
    _ = ed.handle_key(_key(KEY_HOME), _VIEW)
    assert_equal(ed.selections[0].col, 0)


def test_editor_typing_non_ascii() raises:
    # Swedish å/ä/ö encode to 2 UTF-8 bytes each. Cursor columns are byte
    # offsets, so typing one must advance the cursor by 2 — a bare +1 left
    # the caret mid-codepoint and the next keystroke spliced bytes inside the
    # glyph. Regression for the macOS Swedish-keyboard report.
    var ed = Editor(String(""))
    _ = ed.handle_key(_key(UInt32(0xF6)), _VIEW)   # ö
    assert_equal(ed.buffer.line(0), String("ö"))
    assert_equal(ed.selections[0].col, 2)          # 2 bytes, not 1
    _ = ed.handle_key(_key(UInt32(ord("x"))), _VIEW)
    # x lands after the ö, not inside it.
    assert_equal(ed.buffer.line(0), String("öx"))
    assert_equal(ed.selections[0].col, 3)
    # Consecutive multi-byte inserts chain correctly.
    _ = ed.handle_key(_key(UInt32(0xE5)), _VIEW)   # å
    _ = ed.handle_key(_key(UInt32(0xE4)), _VIEW)   # ä
    assert_equal(ed.buffer.line(0), String("öxåä"))
    assert_equal(ed.selections[0].col, 7)
    # Emoji (U+1F600) is above the BMP Private Use Area and 4 UTF-8 bytes;
    # it must insert whole and advance the cursor by 4 (emoji-palette path).
    _ = ed.handle_key(_key(UInt32(0x1F600)), _VIEW)
    assert_equal(ed.buffer.line(0), String("öxåä😀"))
    assert_equal(ed.selections[0].col, 11)


def test_editor_typing_replaces_selection() raises:
    var ed = Editor(String("hello"))
    # Select first 4 chars
    for _ in range(4):
        _ = ed.handle_key(_key(KEY_RIGHT, MOD_SHIFT), _VIEW)
    assert_equal(ed.selections[0].col, 4)
    _ = ed.handle_key(_key(UInt32(ord("X"))), _VIEW)
    assert_equal(ed.buffer.line(0), String("Xo"))
    assert_false(ed.has_selection())
    assert_equal(ed.selections[0].col, 1)


def test_editor_backspace_deletes_selection() raises:
    var ed = Editor(String("hello"))
    _ = ed.handle_key(_key(KEY_RIGHT), _VIEW)         # cursor at 1
    for _ in range(3):
        _ = ed.handle_key(_key(KEY_RIGHT, MOD_SHIFT), _VIEW)
    # selection covers "ell"
    _ = ed.handle_key(_key(KEY_BACKSPACE), _VIEW)
    assert_equal(ed.buffer.line(0), String("ho"))
    assert_false(ed.has_selection())


def test_editor_diff_selection_copies_phantom_rows() raises:
    """In an inline-diff view, a selection spanning a change copies the
    removed (phantom) lines interleaved with the kept lines exactly as
    they're shown — so Cmd+C in review mode grabs the deleted code too."""
    # After-file: two kept rows. Two removed lines render between them as
    # phantoms anchored before row 1 (``diff_phantom_buckets[1]``).
    var ed = Editor(String("kept line\nkept line"))
    ed.diff_active = True
    ed.diff_phantom_text = List[String]()
    ed.diff_phantom_text.append(String("old deleted line"))
    ed.diff_phantom_text.append(String("another deleted"))
    ed.diff_phantom_buckets = List[List[Int]]()
    ed.diff_phantom_buckets.append(List[Int]())          # before row 0: none
    var bucket1 = List[Int]()
    bucket1.append(0)
    bucket1.append(1)
    ed.diff_phantom_buckets.append(bucket1^)             # before row 1
    ed.diff_phantom_buckets.append(List[Int]())          # at EOF: none
    # Select from the top of row 0 through the end of row 1.
    ed.move_to(0, 0, False)
    ed.move_to(1, len(ed.buffer.line(1).as_bytes()), True)
    assert_true(ed.has_selection())
    assert_equal(
        ed.selection_text(),
        String("kept line\nold deleted line\nanother deleted\nkept line"),
    )
    # Same buffer/selection without the diff view: only the real rows.
    ed.diff_active = False
    assert_equal(ed.selection_text(), String("kept line\nkept line"))


def test_editor_cut_whole_line_when_no_selection() raises:
    var ed = Editor(String("first\nsecond\nthird"))
    ed.move_to(1, 3, False)
    ed.cut_to_clipboard()
    assert_equal(ed.buffer.line_count(), 2)
    assert_equal(ed.buffer.line(0), String("first"))
    assert_equal(ed.buffer.line(1), String("third"))
    assert_equal(ed.selections[0].row, 1); assert_equal(ed.selections[0].col, 0)


def test_editor_cut_whole_line_only_line() raises:
    var ed = Editor(String("only line"))
    ed.move_to(0, 4, False)
    ed.cut_to_clipboard()
    assert_equal(ed.buffer.line_count(), 1)
    assert_equal(ed.buffer.line(0), String(""))
    assert_equal(ed.selections[0].row, 0); assert_equal(ed.selections[0].col, 0)


def test_editor_smart_indent_mirrors_previous_line() raises:
    var ed = Editor(String("    hello"))
    ed.move_to(0, 9, False)
    _ = ed.handle_key(_key(KEY_ENTER), _VIEW)
    assert_equal(ed.buffer.line_count(), 2)
    assert_equal(ed.buffer.line(1), String("    "))
    assert_equal(ed.selections[0].row, 1); assert_equal(ed.selections[0].col, 4)


def test_editor_smart_indent_after_open_brace() raises:
    var ed = Editor(String("if (x) {"))
    ed.move_to(0, 8, False)
    _ = ed.handle_key(_key(KEY_ENTER), _VIEW)
    assert_equal(ed.buffer.line(1), String("    "))
    assert_equal(ed.selections[0].col, 4)


def test_editor_smart_indent_after_colon() raises:
    var ed = Editor(String("    def foo():"))
    ed.move_to(0, 14, False)
    _ = ed.handle_key(_key(KEY_ENTER), _VIEW)
    assert_equal(ed.buffer.line(1), String("        "))
    assert_equal(ed.selections[0].col, 8)


def test_editor_cut_selection() raises:
    var ed = Editor(String("hello world"))
    for _ in range(5):
        _ = ed.handle_key(_key(KEY_RIGHT, MOD_SHIFT), _VIEW)
    var cut = ed.cut_selection()
    assert_equal(cut, String("hello"))
    assert_equal(ed.buffer.line(0), String(" world"))
    assert_false(ed.has_selection())


def test_editor_paste_text_single_line() raises:
    var ed = Editor(String("hello"))
    ed.move_to(0, 5, False)
    ed.paste_text(String(" world"))
    assert_equal(ed.buffer.line(0), String("hello world"))
    assert_equal(ed.selections[0].col, 11)


def test_editor_paste_text_multiline() raises:
    var ed = Editor(String("hello"))
    ed.move_to(0, 5, False)
    ed.paste_text(String("\nworld\nfoo"))
    assert_equal(ed.buffer.line_count(), 3)
    assert_equal(ed.buffer.line(0), String("hello"))
    assert_equal(ed.buffer.line(1), String("world"))
    assert_equal(ed.buffer.line(2), String("foo"))
    assert_equal(ed.selections[0].row, 2)
    assert_equal(ed.selections[0].col, 3)


def test_editor_paste_replaces_selection() raises:
    var ed = Editor(String("hello world"))
    for _ in range(5):
        _ = ed.handle_key(_key(KEY_RIGHT, MOD_SHIFT), _VIEW)
    ed.paste_text(String("HEY"))
    assert_equal(ed.buffer.line(0), String("HEY world"))
    assert_false(ed.has_selection())


def test_editor_goto_line() raises:
    var ed = Editor(String("a\nb\nc\nd\ne"))
    ed.goto_line(3)
    assert_equal(ed.selections[0].row, 2)
    assert_equal(ed.selections[0].col, 0)
    # Out-of-range clamps.
    ed.goto_line(99)
    assert_equal(ed.selections[0].row, 4)
    ed.goto_line(0)
    assert_equal(ed.selections[0].row, 0)


def test_editor_find_next() raises:
    var ed = Editor(String("foo bar foo baz"))
    var hit1 = ed.find_next(String("foo"))
    assert_true(hit1)
    # First hit at col 0 — but find_next searches *after* the cursor; with
    # cursor initially at (0,0) the implementation skips one column. So the
    # first hit is at col 8 ("foo baz").
    assert_equal(ed.selections[0].row, 0); assert_equal(ed.selections[0].col, 11)
    assert_true(ed.has_selection())
    assert_equal(ed.selection_text(), String("foo"))
    # Wrap to the earlier match.
    var hit2 = ed.find_next(String("foo"))
    assert_true(hit2)
    assert_equal(ed.selections[0].col, 3)


def test_editor_find_next_case_insensitive() raises:
    """Cc OFF (case_sensitive=False, the default) should match
    across letter case; Cc ON should require an exact byte match."""
    var ed = Editor(String("Foo bar FOO baz"))
    # Cc ON: case-sensitive — no lowercase "foo" exists, so miss.
    var sensitive = SearchOptions(True, False, False)
    var hit_sensitive = ed.find_next(String("foo"), sensitive)
    assert_true(not hit_sensitive)
    ed.move_to(0, 0, False)
    # Cc OFF: case-insensitive — should hit "Foo" first, then wrap.
    var insensitive = SearchOptions(False, False, False)
    var hit_first = ed.find_next(String("foo"), insensitive)
    assert_true(hit_first)
    assert_equal(ed.selection_text(), String("FOO"))
    var hit_second = ed.find_next(String("foo"), insensitive)
    assert_true(hit_second)
    assert_equal(ed.selection_text(), String("Foo"))


def test_editor_find_next_whole_word() raises:
    """Whole-word toggle should reject substring matches."""
    var ed = Editor(String("foobar foo bar"))
    var opts = SearchOptions(True, True, False)  # case-sensitive + whole-word
    var hit = ed.find_next(String("foo"), opts)
    assert_true(hit)
    # The substring at col 0 ("foobar") is not a whole word; the
    # whole-word "foo" sits at col 7.
    assert_equal(ed.selections[0].col, 10)


def test_editor_find_next_regex() raises:
    """Regex toggle should let the user write a real pattern.
    ``find_next`` skips the byte at the cursor (so a repeated press
    walks forward), so the first hit from cursor=(0,0) is the
    second token, not the first."""
    var ed = Editor(String("a1 b2 c3"))
    var opts = SearchOptions(True, False, True)  # case-sensitive regex
    var hit = ed.find_next(String("[a-c][0-9]"), opts)
    assert_true(hit)
    assert_equal(ed.selection_text(), String("b2"))


def test_editor_replace_all_case_insensitive() raises:
    var ed = Editor(String("Foo foo FOO"))
    var opts = SearchOptions(False, False, False)  # ci, no-word, no-regex
    var n = ed.replace_all(String("foo"), String("bar"), opts)
    assert_equal(n, 3)
    assert_equal(ed.buffer.line(0), String("bar bar bar"))


def test_editor_toggle_comment_single_line() raises:
    var ed = Editor(String("hello"))
    ed.toggle_comment()
    assert_equal(ed.buffer.line(0), String("// hello"))
    ed.toggle_comment()
    assert_equal(ed.buffer.line(0), String("hello"))


def test_editor_toggle_comment_selection() raises:
    var ed = Editor(String("a\nb\nc"))
    ed.move_to(0, 0, False)
    ed.move_to(2, 1, True)
    ed.toggle_comment()
    assert_equal(ed.buffer.line(0), String("// a"))
    assert_equal(ed.buffer.line(1), String("// b"))
    assert_equal(ed.buffer.line(2), String("// c"))
    ed.toggle_comment()
    assert_equal(ed.buffer.line(0), String("a"))
    assert_equal(ed.buffer.line(2), String("c"))


def test_editor_toggle_comment_language_aware() raises:
    # Python: `# ` prefix derived from .py extension.
    var py = Editor(String("hello"))
    py.file_path = String("foo.py")
    py.toggle_comment()
    assert_equal(py.buffer.line(0), String("# hello"))
    py.toggle_comment()
    assert_equal(py.buffer.line(0), String("hello"))

    # SQL: `-- ` prefix.
    var sql = Editor(String("select 1"))
    sql.file_path = String("query.sql")
    sql.toggle_comment()
    assert_equal(sql.buffer.line(0), String("-- select 1"))
    sql.toggle_comment()
    assert_equal(sql.buffer.line(0), String("select 1"))

    # Rust: `// ` prefix — confirms the C-family path.
    var rs = Editor(String("let x = 1;"))
    rs.file_path = String("lib.rs")
    rs.toggle_comment()
    assert_equal(rs.buffer.line(0), String("// let x = 1;"))

    # Unknown extension falls back to `// `.
    var unknown = Editor(String("data"))
    unknown.file_path = String("file.xyz")
    unknown.toggle_comment()
    assert_equal(unknown.buffer.line(0), String("// data"))


def test_editor_toggle_comment_indented() raises:
    # Single line: prefix lands at the first non-whitespace column,
    # preserving the line's leading indent.
    var py = Editor(String("    foo()"))
    py.file_path = String("snippet.py")
    py.toggle_comment()
    assert_equal(py.buffer.line(0), String("    # foo()"))
    py.toggle_comment()
    assert_equal(py.buffer.line(0), String("    foo()"))


def test_editor_toggle_comment_common_indent() raises:
    # Multi-line: prefix uses the shared leading whitespace, so the
    # deeper inner line keeps its extra indent visible after the marker.
    var py = Editor(String("    foo()\n        bar()\n    baz()"))
    py.file_path = String("snippet.py")
    py.move_to(0, 0, False)
    py.move_to(2, 1, True)
    py.toggle_comment()
    assert_equal(py.buffer.line(0), String("    # foo()"))
    assert_equal(py.buffer.line(1), String("    #     bar()"))
    assert_equal(py.buffer.line(2), String("    # baz()"))
    py.toggle_comment()
    assert_equal(py.buffer.line(0), String("    foo()"))
    assert_equal(py.buffer.line(1), String("        bar()"))
    assert_equal(py.buffer.line(2), String("    baz()"))


def test_editor_toggle_comment_skips_blank_lines() raises:
    # Blank lines in the range are left untouched and don't block the
    # "all commented" vote — uncommenting still works around them.
    var py = Editor(String("    foo()\n\n    bar()"))
    py.file_path = String("snippet.py")
    py.move_to(0, 0, False)
    py.move_to(2, 1, True)
    py.toggle_comment()
    assert_equal(py.buffer.line(0), String("    # foo()"))
    assert_equal(py.buffer.line(1), String(""))
    assert_equal(py.buffer.line(2), String("    # bar()"))
    py.toggle_comment()
    assert_equal(py.buffer.line(0), String("    foo()"))
    assert_equal(py.buffer.line(1), String(""))
    assert_equal(py.buffer.line(2), String("    bar()"))


def test_editor_toggle_case() raises:
    var ed = Editor(String("Hello World"))
    ed.move_to(0, 0, False)
    ed.move_to(0, 5, True)         # select "Hello"
    ed.toggle_case()
    assert_equal(ed.buffer.line(0), String("hELLO World"))


def test_editor_replace_all() raises:
    var ed = Editor(String("foo bar foo\nfoo\nbaz\n"))
    var n = ed.replace_all(String("foo"), String("XX"))
    assert_equal(n, 3)
    assert_true(ed.dirty)
    assert_equal(ed.buffer.line(0), String("XX bar XX"))
    assert_equal(ed.buffer.line(1), String("XX"))
    assert_equal(ed.buffer.line(2), String("baz"))
    # Replacing something absent reports zero.
    var ed2 = Editor(String("nothing to do"))
    assert_equal(ed2.replace_all(String("xxx"), String("yyy")), 0)
    assert_false(ed2.dirty)
    # Empty needle is a no-op (avoids infinite-loop semantics).
    assert_equal(ed.replace_all(String(""), String("Q")), 0)


def test_editor_uses_editorconfig_indent() raises:
    """Tab key respects ``indent_style`` / ``indent_size`` from editorconfig.
    The fixture sets ``[*.{c,h}]`` to ``indent_style=tab``, so opening a
    .c file under that tree should make Tab insert a literal tab."""
    var path = String("tests/fixtures/editorconfig/test_indent.c")
    assert_true(write_file(path, String("")))
    var ed = Editor.from_file(path)
    assert_equal(ed.editorconfig.indent_style, String("tab"))
    _ = ed.handle_key(_key(KEY_TAB), _VIEW)
    assert_equal(ed.buffer.line(0), String("\t"))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_tab_indents_selected_lines() raises:
    """With a selection, Tab prepends one indent unit to every spanned
    line. A selection ending at column 0 of the next line excludes that
    trailing line — only the visibly-selected rows are touched."""
    var ed = Editor(String("alpha\nbeta\ngamma"))
    # Select from (0, 0) → (2, 0): rows 0 and 1, but not row 2.
    ed.move_to(0, 0, False)
    ed.move_to(2, 0, True)
    _ = ed.handle_key(_key(KEY_TAB), _VIEW)
    assert_equal(ed.buffer.line(0), String("    alpha"))
    assert_equal(ed.buffer.line(1), String("    beta"))
    assert_equal(ed.buffer.line(2), String("gamma"))


def test_editor_preserves_crlf_round_trip() raises:
    """Opening a CRLF file with no editorconfig and saving it again must
    produce the original bytes verbatim — otherwise every CRLF file we
    open would show a full-file diff on the next save."""
    var dir = String("/tmp/turbokod_crlf_") + String(
        Int(external_call["getpid", Int32]())
    )
    _ = external_call["mkdir", Int32](
        (dir + String("\0")).unsafe_ptr(), UInt32(0o755),
    )
    var f_path = dir + String("/x.txt")
    var original = String("alpha\r\nbeta\r\ngamma\r\n")
    assert_true(write_file(f_path, original))
    var ed = Editor.from_file(f_path)
    # Detection: no editorconfig in this dir, so end_of_line should be
    # filled in from the file's actual bytes.
    assert_equal(ed.editorconfig.end_of_line, String("crlf"))
    # Buffer holds clean lines (no trailing '\r').
    assert_equal(ed.buffer.line(0), String("alpha"))
    assert_equal(ed.buffer.line(1), String("beta"))
    assert_equal(ed.buffer.line(2), String("gamma"))
    assert_true(ed.save())
    var got = read_file(f_path)
    assert_equal(got, original)
    _ = external_call["unlink", Int32]((f_path + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((dir + String("\0")).unsafe_ptr())


def test_editor_rejects_modified_letter_typing() raises:
    """Alt+Q and Ctrl+Q (when delivered as printable letter + mod) must
    not be inserted into the buffer — they're commands, not text."""
    var ed = Editor(String("hello"))
    _ = ed.handle_key(Event.key_event(KEY_END), _VIEW)
    _ = ed.handle_key(_key(UInt32(ord("q")), MOD_ALT), _VIEW)
    assert_equal(ed.buffer.line(0), String("hello"))
    _ = ed.handle_key(_key(UInt32(ord("q")), MOD_CTRL), _VIEW)
    assert_equal(ed.buffer.line(0), String("hello"))
    # Plain shifted letters still work (they arrive pre-folded as 'Q').
    _ = ed.handle_key(_key(UInt32(ord("Q")), MOD_SHIFT), _VIEW)
    assert_equal(ed.buffer.line(0), String("helloQ"))


def test_editor_rename_multirow_refreshes_all_highlights() raises:
    """A rename that rewrites the symbol on several rows in place (no
    line-count change) must re-color *every* touched row, not just the
    topmost one.

    Regression: ``apply_text_edits`` (the code path LSP rename +
    formatting flow through) used to mark only the lowest edited row
    dirty with no high-water mark, so ``flush_highlights`` early-exited
    at the first edited row — whose post-stack rejoins the base
    trajectory immediately — and spliced stale, column-misaligned
    highlights over the renamed rows below it. The fix passes the
    highest edited row as the dirty high-water mark. After the rename
    the editor's highlights must equal a full retokenize of the buffer.
    """
    var path = _temp_path(String("_rename_hl.rs"))
    var src = String("fn main() {\n")
    src = src + String("    let a = 0;\n")
    src = src + String("    let foo = 1;\n")      # row 2
    src = src + String("    let b = 2;\n")
    src = src + String("    let c = foo + 42;\n")  # row 4
    src = src + String("}\n")
    assert_true(write_file(path, src))
    var ed = Editor.from_file(path)
    var registry = GrammarRegistry()
    var speller = Speller()
    # Warm the per-editor incremental cache with a full pass.
    ed.flush_highlights(registry, speller)

    # Rename ``foo`` -> ``foobar`` (longer, so trailing highlights on the
    # lower row shift) at both occurrences: row 2 cols 8..11 and row 4
    # cols 12..15.
    var edits = List[TextEditEntry]()
    edits.append(TextEditEntry(2, 8, 2, 11, String("foobar")))
    edits.append(TextEditEntry(4, 12, 4, 15, String("foobar")))
    assert_true(ed.apply_text_edits(edits^))
    ed.flush_highlights(registry, speller)

    var s_incr = _hl_set(ed.highlights)
    var s_full = _hl_set(highlight_for_extension(String("rs"), ed.buffer.lines))
    assert_equal(len(s_incr), len(s_full))
    for i in range(len(s_incr)):
        assert_equal(s_incr[i].row, s_full[i].row)
        assert_equal(s_incr[i].col_start, s_full[i].col_start)
        assert_equal(s_incr[i].col_end, s_full[i].col_end)
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_default_text_is_light_green() raises:
    """Cells that no scope claims must paint LIGHT_GREEN on BLUE —
    that's the "identifier" baseline. Variables and bare names in
    languages whose grammar doesn't tag every token (e.g. Python's
    ``def f(x): pass`` — neither ``f`` nor ``x`` get a scope) read
    as green identifiers instead of inheriting the brighter
    ``YELLOW`` baseline they used to.

    Regression: when the default was ``YELLOW`` everything not
    keyword / string / comment / number / operator looked like it
    was meant to stand out, which made unrecognized identifiers
    visually pop more than the keywords surrounding them.
    """
    var ed = Editor(String("hello world"))
    var c = Canvas(20, 3)
    # ``focused=False`` so the cursor block (CARET_FG on CARET_BG at
    # the cursor position) doesn't fight the default-attr probe.
    ed.paint(c, Rect(0, 0, 20, 3), False)
    # Column 0 of an unhighlighted, plain-text buffer must carry the
    # editor baseline: the reserved ``SYN_IDENT`` fg on ``EDITOR_BG``.
    # Under the default "Turbo C++ 3.0" theme these slots resolve to the
    # classic LIGHT_GREEN-on-BLUE RGB, so the look is unchanged; the
    # indices differ because a theme can now retint them independently.
    assert_equal(c.get(0, 0).attr.fg, SYN_IDENT)
    assert_equal(c.get(0, 0).attr.bg, EDITOR_BG)
    # Past EOL the trailing fill cells must also be the new default.
    assert_equal(c.get(15, 0).attr.fg, SYN_IDENT)
    assert_equal(c.get(15, 0).attr.bg, EDITOR_BG)


def test_editor_refreshes_highlights_after_edits() raises:
    """Newly typed text gets re-tokenized: typing ``fn`` produces a keyword
    highlight that wasn't there a moment ago.

    Editor.handle_key now defers the actual tokenization to the
    render path's ``flush_highlights`` call (so the shared
    ``GrammarRegistry`` doesn't have to thread through every edit
    method); we drive that explicitly with a local registry to read
    ``ed.highlights`` synchronously.
    """
    var path = _temp_path(String("_hl.mojo"))
    assert_true(write_file(path, String("\n")))
    var ed = Editor.from_file(path)
    var registry = GrammarRegistry()
    var speller = Speller()
    ed.flush_highlights(registry, speller)
    assert_true(len(ed.highlights) == 0)
    _ = ed.handle_key(_key(UInt32(ord("f"))), _VIEW)
    _ = ed.handle_key(_key(UInt32(ord("n"))), _VIEW)
    ed.flush_highlights(registry, speller)
    var saw_fn_keyword = False
    for i in range(len(ed.highlights)):
        var h = ed.highlights[i]
        if h.row == 0 and h.col_start == 0 and h.col_end == 2 \
                and h.attr == highlight_keyword_attr():
            saw_fn_keyword = True
    assert_true(saw_fn_keyword)
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_paint_overlays_highlight_attr() raises:
    """The highlight attr lands on the right cells in the canvas after
    ``editor.paint``."""
    var path = _temp_path(String("_hlpaint.mojo"))
    assert_true(write_file(path, String("fn main():\n")))
    var ed = Editor.from_file(path)
    var registry = GrammarRegistry()
    var speller = Speller()
    ed.flush_highlights(registry, speller)
    var canvas = Canvas(40, 5)
    canvas.fill(Rect(0, 0, 40, 5), String(" "), default_attr())
    ed.paint(canvas, Rect(0, 0, 40, 5), False)
    # ``fn`` lives at columns 0–1 with the keyword attr.
    assert_true(canvas.get(0, 0).attr == highlight_keyword_attr())
    assert_true(canvas.get(1, 0).attr == highlight_keyword_attr())
    # The space and the ``main`` identifier aren't keywords.
    assert_false(canvas.get(2, 0).attr == highlight_keyword_attr())
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_paint_compresses_kwargs_off_caret_line() raises:
    """With ``compress_kwargs`` on, a ``foo(a=a, d=4)`` line that doesn't
    hold the caret renders ``foo(≡a, d=4)`` (label concealed, separator
    repainted as the distinct ``≡`` marker), while the identical line *under*
    the caret keeps its real text."""
    var path = _temp_path(String("_kwcompress.py"))
    assert_true(write_file(
        path, String("foo(a=a, d=4)\nfoo(a=a, d=4)\n"),
    ))
    var ed = Editor.from_file(path)
    ed.compress_kwargs = True
    var registry = GrammarRegistry()
    var speller = Speller()
    ed.flush_highlights(registry, speller)
    var canvas = Canvas(40, 5)
    canvas.fill(Rect(0, 0, 40, 5), String(" "), default_attr())
    # Caret stays at (0, 0) — row 0 is the active line.
    ed.paint(canvas, Rect(0, 0, 40, 5), True)
    # Row 0 (caret line) is expanded: real ``foo(a=a, ...``.
    assert_equal(canvas.get(4, 0).glyph, String("a"))
    assert_equal(canvas.get(5, 0).glyph, String("="))
    assert_equal(canvas.get(6, 0).glyph, String("a"))
    # Row 1 (no caret) is compressed: ``foo(≡a, ...`` — the label ``a`` is
    # gone, so the separator (repainted ``≡``) shifts left into its column.
    assert_equal(canvas.get(4, 1).glyph, String("≡"))
    assert_equal(canvas.get(5, 1).glyph, String("a"))
    assert_equal(canvas.get(6, 1).glyph, String(","))
    # And with the option off, row 1 renders its real text again.
    ed.compress_kwargs = False
    canvas.fill(Rect(0, 0, 40, 5), String(" "), default_attr())
    ed.paint(canvas, Rect(0, 0, 40, 5), True)
    assert_equal(canvas.get(4, 1).glyph, String("a"))
    assert_equal(canvas.get(5, 1).glyph, String("="))
    assert_equal(canvas.get(6, 1).glyph, String("a"))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_text_click_does_not_toggle_breakpoint() raises:
    # Click past the gutter — normal cursor placement, no toggle.
    var ed = Editor(String("alpha\nbeta\ngamma"))
    ed.line_numbers = True
    var ev = Event.mouse_event(
        Point(5, 1), MOUSE_BUTTON_LEFT,
        pressed=True, motion=False, mods=0,
    )
    _ = ed.handle_mouse(ev, Rect(0, 0, 40, 5))
    assert_false(Bool(ed.consume_breakpoint_toggle()))
    assert_equal(ed.selections[0].row, 1)


def test_save_as_dialog_seeds_from_existing_path() raises:
    """``open(start_path)`` splits the path: directory feeds the listing,
    basename pre-fills the filename input, focus starts on the input.
    Listing must be dirs-only (the user is picking a folder)."""
    var dlg = SaveAsDialog()
    # Use ``./hello.mojo`` so the listing draws from the repo root —
    # which actually has subdirectories — making the dirs-only filter
    # observable. (The ``examples/`` directory has no subdirs, so a
    # filter test rooted there would pass vacuously.)
    dlg.open(String("./hello.mojo"))
    assert_true(dlg.active)
    assert_equal(dlg.filename.text, String("hello.mojo"))
    assert_equal(dlg.browser.dir, String("."))
    # The repo root has plain files (CLAUDE.md, run.sh, pixi.toml, …).
    # If the filter were broken, the listing would include them; we
    # require every entry to be a directory.
    var saw_real_entry = False
    for i in range(len(dlg.browser.entries)):
        if dlg.browser.entries[i] == String(".."):
            continue
        saw_real_entry = True
        assert_true(dlg.browser.entry_is_dir[i])
    assert_true(saw_real_entry)


def test_save_as_dialog_typing_updates_filename() raises:
    var dlg = SaveAsDialog()
    dlg.open(String(""))
    assert_equal(dlg.filename.text, String(""))
    _ = dlg.handle_key(Event.key_event(UInt32(ord("a"))))
    _ = dlg.handle_key(Event.key_event(UInt32(ord("b"))))
    _ = dlg.handle_key(Event.key_event(UInt32(ord(".")), MOD_NONE))
    _ = dlg.handle_key(Event.key_event(UInt32(ord("t"))))
    _ = dlg.handle_key(Event.key_event(UInt32(ord("x"))))
    _ = dlg.handle_key(Event.key_event(UInt32(ord("t"))))
    assert_equal(dlg.filename.text, String("ab.txt"))
    # Backspace deletes from the input while focus stays there.
    _ = dlg.handle_key(Event.key_event(KEY_BACKSPACE))
    assert_equal(dlg.filename.text, String("ab.tx"))


def test_save_as_dialog_enter_submits_joined_path() raises:
    var dlg = SaveAsDialog()
    dlg.open(String("examples/hello.mojo"))
    _ = dlg.handle_key(Event.key_event(KEY_ENTER))
    assert_true(dlg.submitted)
    assert_equal(dlg.selected_path, String("examples/hello.mojo"))


def test_save_as_dialog_tab_focus_then_listing_navigation() raises:
    """Tab moves focus to the listing; Enter on the listing descends
    rather than submitting, since the user is still picking a folder."""
    var dlg = SaveAsDialog()
    dlg.open(String("examples/hello.mojo"))
    _ = dlg.handle_key(Event.key_event(KEY_TAB))
    # Up to ``..``, then Enter to ascend.
    _ = dlg.handle_key(Event.key_event(KEY_UP))
    assert_equal(dlg.browser.selected, 0)
    assert_equal(dlg.browser.entries[0], String(".."))
    _ = dlg.handle_key(Event.key_event(KEY_ENTER))
    assert_false(dlg.submitted)
    # Tab back, then Enter — should submit at the new (parent) directory.
    _ = dlg.handle_key(Event.key_event(KEY_TAB))
    _ = dlg.handle_key(Event.key_event(KEY_ENTER))
    assert_true(dlg.submitted)
    # ``..`` from "examples" lands on the project root; the path joins
    # the new dir with the unchanged filename.
    assert_true(dlg.selected_path.as_bytes()[len(dlg.selected_path.as_bytes()) - 1] != 0x2F)
    var n = len(dlg.selected_path.as_bytes())
    var b = dlg.selected_path.as_bytes()
    var hello = String("hello.mojo").as_bytes()
    var hn = len(hello)
    assert_true(n >= hn)
    for i in range(hn):
        assert_equal(Int(b[n - hn + i]), Int(hello[i]))


def test_save_as_dialog_empty_filename_blocks_submit() raises:
    var dlg = SaveAsDialog()
    dlg.open(String(""))
    _ = dlg.handle_key(Event.key_event(KEY_ENTER))
    assert_false(dlg.submitted)


def test_editor_sticky_col_down_through_short_line() raises:
    """Down-arrowing from a wide line through a short one and back to a wider
    one returns the cursor to the original column."""
    var ed = Editor(String("hello world\nab\nabcdefghij"))
    _ = ed.handle_key(_key(KEY_END), _VIEW)
    assert_equal(ed.selections[0].row, 0)
    assert_equal(ed.selections[0].col, 11)
    assert_equal(ed.selections[0].desired_col, 11)
    _ = ed.handle_key(_key(KEY_DOWN), _VIEW)
    # Line 1 ("ab") is 2 chars: cursor clamps but desired_col is preserved.
    assert_equal(ed.selections[0].row, 1)
    assert_equal(ed.selections[0].col, 2)
    assert_equal(ed.selections[0].desired_col, 11)
    _ = ed.handle_key(_key(KEY_DOWN), _VIEW)
    # Line 2 is 10 chars: cursor lands at min(11, 10) = 10. Desired untouched.
    assert_equal(ed.selections[0].row, 2)
    assert_equal(ed.selections[0].col, 10)
    assert_equal(ed.selections[0].desired_col, 11)


def test_editor_sticky_col_up_through_short_line() raises:
    var ed = Editor(String("hello world\nab\nabcdefghij"))
    _ = ed.handle_key(_key(KEY_DOWN), _VIEW)
    _ = ed.handle_key(_key(KEY_DOWN), _VIEW)
    _ = ed.handle_key(_key(KEY_END), _VIEW)
    assert_equal(ed.selections[0].row, 2)
    assert_equal(ed.selections[0].col, 10)
    assert_equal(ed.selections[0].desired_col, 10)
    _ = ed.handle_key(_key(KEY_UP), _VIEW)
    assert_equal(ed.selections[0].row, 1)
    assert_equal(ed.selections[0].col, 2)
    assert_equal(ed.selections[0].desired_col, 10)
    _ = ed.handle_key(_key(KEY_UP), _VIEW)
    assert_equal(ed.selections[0].row, 0)
    assert_equal(ed.selections[0].col, 10)
    assert_equal(ed.selections[0].desired_col, 10)


def test_editor_sticky_col_reset_by_left_arrow() raises:
    var ed = Editor(String("hello world\nab\nabcdefghij"))
    _ = ed.handle_key(_key(KEY_END), _VIEW)
    _ = ed.handle_key(_key(KEY_DOWN), _VIEW)
    assert_equal(ed.selections[0].desired_col, 11)
    _ = ed.handle_key(_key(KEY_LEFT), _VIEW)
    # Horizontal move resets the remembered column to wherever we end up.
    assert_equal(ed.selections[0].col, 1)
    assert_equal(ed.selections[0].desired_col, 1)
    _ = ed.handle_key(_key(KEY_DOWN), _VIEW)
    assert_equal(ed.selections[0].row, 2)
    assert_equal(ed.selections[0].col, 1)


def test_editor_sticky_col_reset_by_right_arrow() raises:
    var ed = Editor(String("hello world\nab\nabcdefghij"))
    _ = ed.handle_key(_key(KEY_END), _VIEW)
    _ = ed.handle_key(_key(KEY_DOWN), _VIEW)
    # cursor (1, 2), desired 11. Right at end of line moves to start of next.
    _ = ed.handle_key(_key(KEY_RIGHT), _VIEW)
    assert_equal(ed.selections[0].row, 2)
    assert_equal(ed.selections[0].col, 0)
    assert_equal(ed.selections[0].desired_col, 0)


def test_editor_sticky_col_reset_by_typing() raises:
    var ed = Editor(String("hello world\nab"))
    _ = ed.handle_key(_key(KEY_END), _VIEW)
    _ = ed.handle_key(_key(KEY_DOWN), _VIEW)
    assert_equal(ed.selections[0].desired_col, 11)
    _ = ed.handle_key(_key(UInt32(ord("X"))), _VIEW)
    assert_equal(ed.selections[0].col, 3)
    assert_equal(ed.selections[0].desired_col, 3)


def test_editor_sticky_col_reset_by_click() raises:
    var ed = Editor(String("hello world\nabcdefghij"))
    _ = ed.handle_key(_key(KEY_END), _VIEW)
    assert_equal(ed.selections[0].desired_col, 11)
    var view = Rect(0, 0, 40, 10)
    _ = ed.handle_mouse(
        Event.mouse_event(Point(3, 0), MOUSE_BUTTON_LEFT, True, False),
        view,
    )
    assert_equal(ed.selections[0].col, 3)
    assert_equal(ed.selections[0].desired_col, 3)


def test_editor_sticky_col_reset_by_home_end() raises:
    var ed = Editor(String("hello world\nab\nabcdefghij"))
    _ = ed.handle_key(_key(KEY_END), _VIEW)        # desired=11
    _ = ed.handle_key(_key(KEY_DOWN), _VIEW)       # row 1, col 2, desired 11
    _ = ed.handle_key(_key(KEY_HOME), _VIEW)
    assert_equal(ed.selections[0].col, 0)
    assert_equal(ed.selections[0].desired_col, 0)
    _ = ed.handle_key(_key(KEY_DOWN), _VIEW)
    assert_equal(ed.selections[0].row, 2)
    assert_equal(ed.selections[0].col, 0)


def test_editor_sticky_col_pageup_pagedown() raises:
    var ed = Editor(
        String("0123456789\n0123456789\nab\n0123456789\n0123456789\n0123456789")
    )
    _ = ed.handle_key(_key(KEY_END), _VIEW)
    assert_equal(ed.selections[0].col, 10)
    var small_view = Rect(0, 0, 80, 3)
    _ = ed.handle_key(_key(KEY_PAGEDOWN), small_view)
    # PageDown jumps view-height (3) rows; the destination line is 10 chars long.
    assert_equal(ed.selections[0].row, 3)
    assert_equal(ed.selections[0].col, 10)
    assert_equal(ed.selections[0].desired_col, 10)
    # Step back through the short line; sticky column survives.
    _ = ed.handle_key(_key(KEY_UP), small_view)
    assert_equal(ed.selections[0].row, 2)
    assert_equal(ed.selections[0].col, 2)
    assert_equal(ed.selections[0].desired_col, 10)
    _ = ed.handle_key(_key(KEY_PAGEUP), small_view)
    # PageUp from row 2 jumps to row 0 (clamped at 0).
    assert_equal(ed.selections[0].row, 0)
    assert_equal(ed.selections[0].col, 10)
    assert_equal(ed.selections[0].desired_col, 10)


def test_editor_sticky_col_shift_down_keeps_anchor() raises:
    """Shift+Down should extend selection and use the sticky column too."""
    var ed = Editor(String("hello world\nab\nabcdefghij"))
    _ = ed.handle_key(_key(KEY_END), _VIEW)
    _ = ed.handle_key(_key(KEY_DOWN, MOD_SHIFT), _VIEW)
    assert_true(ed.has_selection())
    assert_equal(ed.selections[0].row, 1)
    assert_equal(ed.selections[0].col, 2)
    assert_equal(ed.selections[0].anchor_row, 0)
    assert_equal(ed.selections[0].anchor_col, 11)
    assert_equal(ed.selections[0].desired_col, 11)
    _ = ed.handle_key(_key(KEY_DOWN, MOD_SHIFT), _VIEW)
    assert_equal(ed.selections[0].row, 2)
    assert_equal(ed.selections[0].col, 10)
    assert_equal(ed.selections[0].desired_col, 11)


def test_editor_left_right_steps_over_multibyte_codepoint() raises:
    """Arrow keys must move by whole UTF-8 codepoints — never park the
    cursor in the middle of a multi-byte sequence."""
    # "café" — bytes: c(0), a(1), f(2), é(3-4). 4 codepoints, 5 bytes.
    var ed = Editor(String("café"))
    _ = ed.handle_key(_key(KEY_RIGHT), _VIEW)
    _ = ed.handle_key(_key(KEY_RIGHT), _VIEW)
    _ = ed.handle_key(_key(KEY_RIGHT), _VIEW)
    assert_equal(ed.selections[0].col, 3)        # at start of é
    _ = ed.handle_key(_key(KEY_RIGHT), _VIEW)
    assert_equal(ed.selections[0].col, 5)        # past é, end of line (skipped 2 bytes)
    _ = ed.handle_key(_key(KEY_LEFT), _VIEW)
    assert_equal(ed.selections[0].col, 3)        # back over the whole codepoint
    _ = ed.handle_key(_key(KEY_LEFT), _VIEW)
    assert_equal(ed.selections[0].col, 2)        # ASCII step works as before


def test_editor_backspace_removes_whole_codepoint() raises:
    """Backspace at the end of a line containing é must remove all of é."""
    var ed = Editor(String("café"))
    _ = ed.handle_key(_key(KEY_END), _VIEW)
    assert_equal(ed.selections[0].col, 5)
    _ = ed.handle_key(_key(KEY_BACKSPACE), _VIEW)
    assert_equal(ed.buffer.line(0), String("caf"))
    assert_equal(ed.selections[0].col, 3)


def test_editor_delete_key_removes_whole_codepoint() raises:
    """Delete (forward) at the boundary before é must remove all of é and
    leave the buffer as valid UTF-8."""
    var ed = Editor(String("café"))
    _ = ed.handle_key(_key(KEY_RIGHT), _VIEW)
    _ = ed.handle_key(_key(KEY_RIGHT), _VIEW)
    _ = ed.handle_key(_key(KEY_RIGHT), _VIEW)
    assert_equal(ed.selections[0].col, 3)
    _ = ed.handle_key(_key(KEY_DELETE), _VIEW)
    assert_equal(ed.buffer.line(0), String("caf"))
    assert_equal(ed.selections[0].col, 3)


def test_editor_set_hover_result_displays_only_for_current_word() raises:
    """A late hover response that doesn't match the word the mouse is
    currently dwelling on is dropped: the popup must not pop up at the
    wrong place after the user has moved to a different identifier."""
    var ed = Editor(String("foo bar\n"))
    var view = Rect(0, 0, 40, 5)
    var hover = Event.mouse_event(
        Point(1, 0), MOUSE_BUTTON_NONE, True, True,
    )
    _ = ed.handle_mouse(hover, view)
    # Response matching the current candidate (word "foo" starts at 0)
    # is accepted.
    ed.set_hover_result(0, 0, String("int"))
    assert_equal(ed._hover_result_text, String("int"))
    # A response for a different position is silently dropped — would
    # otherwise float over the wrong identifier.
    ed.set_hover_result(0, 4, String("str"))
    assert_equal(ed._hover_result_text, String("int"))
    # Typing clears the popup so it doesn't float over fresh edits.
    var key = Event.key_event(KEY_RIGHT, MOD_NONE)
    _ = ed.handle_key(key, view)
    assert_equal(ed._hover_result_text, String(""))


def test_editor_set_completions_opens_popup() raises:
    """``set_completions`` flips the popup visible and parks items.
    An empty list closes (or stays closed) so a server response with
    zero matches doesn't paint an empty popup."""
    var ed = Editor(String("foo"))
    var items = List[CompletionItem]()
    items.append(CompletionItem(
        String("foo_bar"), String("foo_bar"), 6, String(""),
        String("foo_bar"), False, 0, 0, 0, 0,
        List[TextEditEntry](),
    ))
    items.append(CompletionItem(
        String("foo_baz"), String("foo_baz"), 6, String(""),
        String("foo_baz"), False, 0, 0, 0, 0,
        List[TextEditEntry](),
    ))
    ed.set_completions(items^, 0, 0)
    assert_true(ed.completion_popup_visible)
    assert_equal(len(ed.completion_items), 2)
    assert_equal(ed.completion_highlight, 0)
    ed.close_completion_popup()
    assert_false(ed.completion_popup_visible)
    # Empty list is treated as "close" — no stale state lingers.
    ed.set_completions(List[CompletionItem](), 0, 0)
    assert_false(ed.completion_popup_visible)


def test_editor_typing_word_char_stamps_autotrigger_request() raises:
    """Typing an identifier char (letter, digit, underscore) auto-stamps
    ``pending_completion_request`` so the desktop dispatches a fresh
    LSP query without the user having to press the completion key."""
    var ed = Editor(String(""))
    var ev = Event.key_event(UInt32(0x66))  # 'f'
    _ = ed.handle_key(ev, Rect(0, 0, 40, 5))
    var req = ed.consume_completion_request()
    assert_true(Bool(req))
    assert_equal(req.value().col, 1)
    # ``.`` is also a trigger so member-access pops up the popup.
    var ev2 = Event.key_event(UInt32(0x2E))  # '.'
    _ = ed.handle_key(ev2, Rect(0, 0, 40, 5))
    var req2 = ed.consume_completion_request()
    assert_true(Bool(req2))


def test_editor_typing_non_word_char_skips_autotrigger() raises:
    """Typing punctuation that doesn't extend an identifier (space,
    ``(``, ``=``, …) must NOT auto-stamp a completion request — that
    would fire LSP queries on every keystroke."""
    var ed = Editor(String(""))
    var ev = Event.key_event(UInt32(0x28))  # '('
    _ = ed.handle_key(ev, Rect(0, 0, 40, 5))
    var req = ed.consume_completion_request()
    assert_false(Bool(req))


def test_editor_typing_non_word_char_closes_visible_popup() raises:
    """A visible popup gets dismissed when the user types a char that
    doesn't extend the in-progress identifier (e.g. space)."""
    var ed = Editor(String(""))
    var items = List[CompletionItem]()
    items.append(CompletionItem(
        String("foo"), String("foo"), 6, String(""),
        String("foo"), False, 0, 0, 0, 0,
        List[TextEditEntry](),
    ))
    ed.set_completions(items^, 0, 0)
    assert_true(ed.completion_popup_visible)
    var ev = Event.key_event(UInt32(0x20))  # space
    _ = ed.handle_key(ev, Rect(0, 0, 40, 5))
    assert_false(ed.completion_popup_visible)


def test_editor_show_no_completion_message_opens_unselectable_popup() raises:
    """``show_no_completion_message`` opens a popup with a single
    non-acceptable ``<no completion found>`` entry. Arrow keys must
    not move the highlight and Enter must dismiss without inserting."""
    var ed = Editor(String("foo"))
    ed.move_to(0, 3, False)
    ed.show_no_completion_message(0, 0)
    assert_true(ed.completion_popup_visible)
    assert_true(ed.completion_is_message)
    assert_equal(len(ed.completion_items), 1)
    assert_equal(
        ed.completion_items[0].label, String("<no completion found>"),
    )
    # Arrow keys are no-ops on a message popup.
    ed._completion_step(1)
    assert_equal(ed.completion_highlight, 0)
    # Enter dismisses, does not insert anything.
    var ok = ed.accept_completion()
    assert_true(ok)
    assert_false(ed.completion_popup_visible)
    assert_false(ed.completion_is_message)
    assert_equal(ed.buffer.line(0), String("foo"))


def test_editor_set_diagnostics_builds_per_row_severity_index() raises:
    """``Editor.set_diagnostics`` populates ``diagnostic_lines`` so
    that each row carries the *winning* (lowest-numbered) severity.
    A row with both an error and a warning surfaces as Error; the
    minimap uses this index without re-walking the diagnostic list."""
    var ed = Editor(String("first\nsecond\nthird\nfourth"))
    var diags = List[Diagnostic]()
    diags.append(Diagnostic(
        0, 0, 0, 5, DIAG_SEVERITY_WARNING, String("warn"), String("test"),
    ))
    diags.append(Diagnostic(
        1, 0, 1, 6, DIAG_SEVERITY_ERROR, String("err"), String("test"),
    ))
    diags.append(Diagnostic(
        # Same row as the warning above — error must win.
        0, 1, 0, 4, DIAG_SEVERITY_ERROR, String("err2"), String("test"),
    ))
    diags.append(Diagnostic(
        2, 0, 2, 5, DIAG_SEVERITY_HINT, String("hint"), String("test"),
    ))
    # Row 3 has no diagnostic; must stay clean.
    ed.set_diagnostics(diags^)
    assert_equal(len(ed.diagnostic_lines), 4)
    assert_equal(ed.diagnostic_lines[0], DIAG_SEVERITY_ERROR)
    assert_equal(ed.diagnostic_lines[1], DIAG_SEVERITY_ERROR)
    assert_equal(ed.diagnostic_lines[2], DIAG_SEVERITY_HINT)
    assert_equal(ed.diagnostic_lines[3], 0)


def test_editor_minimap_kind_prioritizes_error_over_git_and_spell() raises:
    """An LSP error on a row outranks both an uncommitted-change marker
    and a spell flag on the same row — the user shouldn't have to scroll
    past whitespace edits to see real problems on the minimap."""
    var ed = Editor(String("alpha\nbeta\ngamma"))
    # Pretend git change + spell flag on row 0.
    var git = List[Int]()
    git.append(2)  # GIT_CHANGE_MODIFIED
    git.append(0)
    git.append(0)
    ed.git_change_lines = git^
    var spell = List[Bool]()
    spell.append(True)
    spell.append(False)
    spell.append(False)
    ed.spell_lines = spell^
    # Error on the same row.
    var diags = List[Diagnostic]()
    diags.append(Diagnostic(
        0, 0, 0, 3, DIAG_SEVERITY_ERROR, String("e"), String("test"),
    ))
    ed.set_diagnostics(diags^)
    # Error wins (kind=3) over git (1) and spell (2).
    var kind = ed._minimap_kind_in_slice(0, 1)
    assert_equal(kind, 3)
    # Also: an empty slice past the end returns 0 (clean).
    assert_equal(ed._minimap_kind_in_slice(2, 3), 0)


def test_editor_minimap_warning_outranks_git_change() raises:
    """Same priority test, one notch lower: warning beats git change."""
    var ed = Editor(String("a\nb"))
    var git = List[Int]()
    git.append(2)
    git.append(0)
    ed.git_change_lines = git^
    var diags = List[Diagnostic]()
    diags.append(Diagnostic(
        0, 0, 0, 1, DIAG_SEVERITY_WARNING, String("w"), String("t"),
    ))
    ed.set_diagnostics(diags^)
    assert_equal(ed._minimap_kind_in_slice(0, 1), 4)


def test_editor_minimap_hint_loses_to_spell() raises:
    """Hints sit at the bottom of the priority ladder so a 'consider
    renaming' message can't drown a real misspelling on the minimap."""
    var ed = Editor(String("a\nb"))
    var spell = List[Bool]()
    spell.append(True)
    spell.append(False)
    ed.spell_lines = spell^
    var diags = List[Diagnostic]()
    diags.append(Diagnostic(
        0, 0, 0, 1, DIAG_SEVERITY_HINT, String("h"), String("t"),
    ))
    ed.set_diagnostics(diags^)
    # Spell (kind=2) beats hint (kind=6).
    assert_equal(ed._minimap_kind_in_slice(0, 1), 2)


def test_editor_right_click_on_breakpoint_emits_menu_request() raises:
    """Right-click in the gutter over a row that has a breakpoint
    surfaces a ``BreakpointMenuRequest``. A right-click on a gutter
    row *without* a breakpoint is a no-op."""
    var ed = Editor(String("a\nb\nc\nd\n"))
    ed.gutter_width = 2
    var lines = List[Int]()
    lines.append(2)
    ed.breakpoint_lines = lines^
    var view = Rect(0, 0, 40, 6)
    var ev_hit = Event.mouse_event(
        Point(0, 2), MOUSE_BUTTON_RIGHT, True, False,
    )
    _ = ed.handle_mouse(ev_hit, view)
    var req = ed.consume_breakpoint_menu()
    assert_true(Bool(req))
    assert_equal(req.value().row, 2)
    var ev_miss = Event.mouse_event(
        Point(0, 1), MOUSE_BUTTON_RIGHT, True, False,
    )
    _ = ed.handle_mouse(ev_miss, view)
    assert_false(Bool(ed.consume_breakpoint_menu()))


def test_editor_right_gutter_paints_gray_square_for_changes() raises:
    """When the file fits in the view, the right-edge column maps 1:1
    onto buffer rows: a gray ``■`` lands on each row whose status is
    ADDED or MODIFIED, and rows with no change leave the column blank."""
    var ed = Editor(String("alpha\nbeta\ngamma\n"))
    ed.git_changes_visible = True
    var marks = List[Int]()
    marks.append(GIT_CHANGE_ADDED)
    marks.append(GIT_CHANGE_NONE)
    marks.append(GIT_CHANGE_MODIFIED)
    ed.set_git_changes(marks^)
    assert_equal(ed._right_gutter(), 1)
    var canvas = Canvas(40, 5)
    canvas.fill(Rect(0, 0, 40, 5), String(" "), default_attr())
    ed.paint(canvas, Rect(0, 0, 40, 5), False)
    # Column 39 is the right gutter. Row 0 (ADDED) and row 2 (MODIFIED)
    # should carry the square; row 1 (NONE) is blank.
    assert_equal(canvas.get(39, 0).glyph, String("■"))
    # EDITOR_FG: the classic light gray under the default theme, but a slot
    # that keeps contrast against the editor surface in light themes too.
    assert_equal(canvas.get(39, 0).attr.fg, EDITOR_FG)
    assert_equal(canvas.get(39, 1).glyph, String(" "))
    assert_equal(canvas.get(39, 2).glyph, String("■"))
    # When git-changes is off the right gutter is zero-width again.
    ed.invalidate_git_changes()
    assert_equal(ed._right_gutter(), 0)


def test_editor_paints_deletion_underscore_in_gutter() raises:
    """A pure-deletion marker paints a red ``_`` in the git-changes gutter
    column on the row above the removed run; rows with no deletion leave
    that column blank."""
    var ed = Editor(String("alpha\nbeta\ngamma\n"))
    ed.git_changes_visible = True
    var marks = List[Int]()
    marks.append(GIT_CHANGE_NONE)
    marks.append(GIT_CHANGE_NONE)
    marks.append(GIT_CHANGE_NONE)
    ed.set_git_changes(marks^)
    var deleted = List[Bool]()
    deleted.append(True)         # lines removed just below row 0
    deleted.append(False)
    deleted.append(False)
    ed.set_git_deletions(deleted^)
    var canvas = Canvas(40, 5)
    canvas.fill(Rect(0, 0, 40, 5), String(" "), default_attr())
    ed.paint(canvas, Rect(0, 0, 40, 5), False)
    # The git-changes column sits just after the line-number gutter (no
    # breakpoints → no dap column).
    var gx = ed._line_number_gutter()
    assert_equal(canvas.get(gx, 0).glyph, String("_"))
    assert_equal(canvas.get(gx, 0).attr.fg, LIGHT_RED)
    # Row 1 has no deletion below it — gutter column blank there.
    assert_equal(canvas.get(gx, 1).glyph, String(" "))


def test_editor_right_gutter_projects_full_file_when_scrolled() raises:
    """The right gutter is a minimap of the whole file, not of the
    visible region: scrolling past the changed line still paints the
    square at the projected screen row, computed off ``line_count`` and
    ``view.height()``. With 20 lines in a 5-row view, line 10 falls in
    the slice owned by screen row 2 — and that's where the square lands
    no matter where ``scroll_y`` sits."""
    var text = String("")
    for i in range(20):
        text = text + String("line") + String(i) + String("\n")
    var ed = Editor(text^)
    ed.git_changes_visible = True
    var marks = List[Int]()
    for i in range(20):
        marks.append(
            GIT_CHANGE_MODIFIED if i == 10 else GIT_CHANGE_NONE
        )
    ed.set_git_changes(marks^)
    var canvas = Canvas(40, 5)
    canvas.fill(Rect(0, 0, 40, 5), String(" "), default_attr())
    # Scroll deep into the file — the gutter must still anchor at the
    # whole-file projection, not at the visible window.
    ed.scroll_y = 15
    ed.paint(canvas, Rect(0, 0, 40, 5), False)
    # Slice owned by screen row 2 covers buffer rows [(2*20)/5 = 8,
    # (3*20)/5 = 12), which contains line 10.
    assert_equal(canvas.get(39, 2).glyph, String("■"))
    # Adjacent rows share no changed buffer line, so they stay blank.
    assert_equal(canvas.get(39, 1).glyph, String(" "))
    assert_equal(canvas.get(39, 3).glyph, String(" "))


def test_editor_invalidate_spell_drops_overlay_after_word_added() raises:
    """After ``Speller.add_user_word`` and ``Editor.invalidate_spell``,
    the next ``flush_highlights`` should clear the underline for the
    newly-accepted word — verifying the refresh hook actually loops
    back through ``_refresh_spell``."""
    var words = List[String]()
    words.append(String("hello"))
    var speller = _spell_with_dict(words)
    var path = _temp_path(String("_spell_invalidate.py"))
    assert_true(write_file(path, String("# helo\n")))
    var ed = Editor.from_file(path)
    var registry = GrammarRegistry()
    ed.flush_highlights(registry, speller)
    assert_equal(len(ed.spell_highlights), 1)
    # Teach the speller about "helo", then ask the editor to redo
    # the spell pass on the next flush.
    var udp = user_dict_path()
    _ = external_call["unlink", Int32]((udp + String("\0")).unsafe_ptr())
    _ = speller.add_user_word(String("helo"))
    ed.invalidate_spell()
    ed.flush_highlights(registry, speller)
    assert_equal(len(ed.spell_highlights), 0)
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())
    _ = external_call["unlink", Int32]((udp + String("\0")).unsafe_ptr())


def test_editor_spell_uses_curly_colored_underline_on_supported_terminal() raises:
    """When the host terminal advertises support (we spoof
    ``TERM_PROGRAM=iTerm.app``) the spell highlight keeps the comment
    cyan foreground and gets a separate curly red underline channel —
    the VS-Code-squiggle look."""
    # Force-detect support by setting iTerm2's env var.
    var c_name = String("TERM_PROGRAM\0")
    var c_value = String("iTerm.app\0")
    _ = external_call["setenv", Int32](
        c_name.unsafe_ptr(), c_value.unsafe_ptr(), Int32(1),
    )
    # Defensive: kitty / wezterm / WT vars can short-circuit before
    # TERM_PROGRAM is read; clear them so the iTerm.app spoof wins.
    _ = external_call["unsetenv", Int32](
        String("WT_SESSION\0").unsafe_ptr(),
    )
    _ = external_call["unsetenv", Int32](
        String("KITTY_WINDOW_ID\0").unsafe_ptr(),
    )
    _ = external_call["unsetenv", Int32](
        String("VTE_VERSION\0").unsafe_ptr(),
    )
    var words = List[String]()
    words.append(String("hello"))
    var speller = _spell_with_dict(words)
    var path = _temp_path(String("_spell_curly.py"))
    assert_true(write_file(path, String("# helo\n")))
    var ed = Editor.from_file(path)
    var registry = GrammarRegistry()
    ed.flush_highlights(registry, speller)
    assert_equal(len(ed.spell_highlights), 1)
    var sh = ed.spell_highlights[0]
    # Curly + underline bits set, separate red underline color, fg
    # stays the comment's cyan (i.e. *not* LIGHT_RED).
    assert_true((sh.attr.style & STYLE_UNDERLINE) != 0)
    assert_true((sh.attr.style & STYLE_UNDERLINE_CURLY) != 0)
    assert_equal(sh.attr.underline_color, Int16(LIGHT_RED))
    assert_false(sh.attr.fg == LIGHT_RED)
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_minimap_git_change_wins_over_spell_on_same_row() raises:
    """When a row has both an uncommitted change and a spelling issue,
    the right-side minimap projects the git change color (gray), not
    the spell color (yellow). Spell still paints inline as the
    underline; the gutter is reserved for the higher-priority signal."""
    var words = List[String]()
    words.append(String("hello"))
    var speller = _spell_with_dict(words)
    var path = _temp_path(String("_spell_pri.py"))
    assert_true(write_file(path, String("# helo\n")))
    var ed = Editor.from_file(path)
    var registry = GrammarRegistry()
    ed.flush_highlights(registry, speller)
    # Force both signals on row 0.
    ed.git_change_lines = List[Int]()
    ed.git_change_lines.append(GIT_CHANGE_MODIFIED)
    assert_true(ed.spell_lines[0])
    var canvas = Canvas(40, 5)
    canvas.fill(Rect(0, 0, 40, 5), String(" "), default_attr())
    ed.paint(canvas, Rect(0, 0, 40, 5), False)
    # The right-edge cell on row 0 paints in the git-change color
    # (EDITOR_FG — the classic light gray under the default theme), not
    # the spell color (YELLOW).
    var sq = canvas.get(39, 0)
    assert_equal(sq.glyph, String("■"))
    assert_equal(sq.attr.fg, EDITOR_FG)
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_minimap_click_scrolls_to_marked_line() raises:
    """Clicking on the right-edge minimap column should scroll the
    editor so the buffer row that owns the projected slice is visible
    (and place the cursor on it). With 20 lines in a 5-row view, the
    slice owned by screen row 2 covers buffer rows [8, 12); a left-
    click on column 39 / row 2 must golden-reveal buffer row 10 (the
    marked one) rather than fall through to the text-area handler."""
    var text = String("")
    for i in range(20):
        text = text + String("line") + String(i) + String("\n")
    var ed = Editor(text^)
    ed.git_changes_visible = True
    var marks = List[Int]()
    for i in range(20):
        marks.append(
            GIT_CHANGE_MODIFIED if i == 10 else GIT_CHANGE_NONE
        )
    ed.set_git_changes(marks^)
    ed.scroll_y = 0
    var view = Rect(0, 0, 40, 5)
    var click = Event.mouse_event(
        Point(39, 2), MOUSE_BUTTON_LEFT, True, False,
    )
    _ = ed.handle_mouse(click, view)
    # Cursor lands on the marked buffer row, scroll_y golden-reveals it.
    assert_equal(ed.selections[0].row, 10)
    assert_equal(ed.selections[0].col, 0)
    # 5-row view, golden line = int(5 * 0.38) = 1 → target = 10 - 1 = 9
    assert_equal(ed.scroll_y, 9)


def test_editor_minimap_hover_records_spell_word() raises:
    """A bare-hover event over a minimap row that carries a spelling
    issue should populate ``_minimap_hover_*`` with kind=2 and the
    offending word so the tooltip can render it. Clicking elsewhere
    afterwards must clear the hover state again."""
    var words = List[String]()
    words.append(String("hello"))
    words.append(String("world"))
    var speller = _spell_with_dict(words)
    var path = _temp_path(String("_spell_hover.py"))
    assert_true(write_file(path, String("# helo world\n")))
    var ed = Editor.from_file(path)
    var registry = GrammarRegistry()
    ed.flush_highlights(registry, speller)
    assert_true(ed.spell_lines[0])
    var view = Rect(0, 0, 40, 5)
    # Bare hover (button=NONE, motion=True) on the minimap column on
    # row 0 — there's only the spell mark, so kind=2 and word=helo.
    var hover = Event.mouse_event(
        Point(39, 0), MOUSE_BUTTON_NONE, True, True,
    )
    _ = ed.handle_mouse(hover, view)
    assert_equal(ed._minimap_hover_kind, 2)
    assert_equal(ed._minimap_hover_buf_row, 0)
    assert_equal(ed._minimap_hover_word, String("helo"))
    # Hover past end-of-line on a clean column — no spell underline
    # there and no minimap mark, so the state must clear. (A column
    # that falls *on* the spell word now keeps the tooltip alive
    # because in-text hover is wired up too — that's covered
    # separately by ``test_editor_text_hover_*``.)
    var hover_off = Event.mouse_event(
        Point(30, 0), MOUSE_BUTTON_NONE, True, True,
    )
    _ = ed.handle_mouse(hover_off, view)
    assert_equal(ed._minimap_hover_kind, 0)
    assert_equal(ed._minimap_hover_buf_row, -1)
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_minimap_hover_paints_tooltip() raises:
    """After a hover sets the spell-mark state, ``Editor.paint`` must
    overlay a tooltip box that includes the misspelled word so the user
    can read it."""
    var words = List[String]()
    words.append(String("hello"))
    words.append(String("world"))
    var speller = _spell_with_dict(words)
    var path = _temp_path(String("_spell_tip.py"))
    assert_true(write_file(path, String("# helo world\n")))
    var ed = Editor.from_file(path)
    var registry = GrammarRegistry()
    ed.flush_highlights(registry, speller)
    var view = Rect(0, 0, 40, 5)
    var hover = Event.mouse_event(
        Point(39, 0), MOUSE_BUTTON_NONE, True, True,
    )
    _ = ed.handle_mouse(hover, view)
    var canvas = Canvas(40, 5)
    canvas.fill(view, String(" "), default_attr())
    ed.paint(canvas, view, False)
    # Pull the row of cells where the tooltip's label sits and concat
    # the glyphs into a string so we can search for the word.
    var row_text = String("")
    for x in range(view.b.x):
        row_text = row_text + canvas.get(x, 1).glyph
    assert_true(_contains(row_text, String("helo")))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_text_hover_over_diagnostic_records_kind_and_message() raises:
    """Hovering over a cell covered by a diagnostic underline (in the
    editor surface itself, not the minimap) must populate the same
    hover state the minimap-mark hover does so the tooltip can render.
    A warning at columns [3, 7) on row 0 → cursor at (3, 0) is on it;
    expect kind=4 and the diagnostic's message in ``_minimap_hover_word``."""
    var ed = Editor(String("alpha beta gamma"))
    var diags = List[Diagnostic]()
    diags.append(Diagnostic(
        0, 3, 0, 7, DIAG_SEVERITY_WARNING,
        String("unused identifier"), String("pyright"),
    ))
    ed.set_diagnostics(diags^)
    var view = Rect(0, 0, 40, 5)
    var hover = Event.mouse_event(
        Point(3, 0), MOUSE_BUTTON_NONE, True, True,
    )
    _ = ed.handle_mouse(hover, view)
    assert_equal(ed._minimap_hover_kind, 4)
    assert_equal(ed._minimap_hover_buf_row, 0)
    assert_equal(
        ed._minimap_hover_word, String("[pyright] unused identifier"),
    )


def test_editor_text_hover_off_diagnostic_clears_state() raises:
    """A hover on a cell *outside* a diagnostic range (and not on a
    spell flag) clears the hover state — no stale tooltip lingers
    from a previous frame."""
    var ed = Editor(String("alpha beta gamma"))
    var diags = List[Diagnostic]()
    diags.append(Diagnostic(
        0, 3, 0, 7, DIAG_SEVERITY_ERROR, String("oops"), String("t"),
    ))
    ed.set_diagnostics(diags^)
    var view = Rect(0, 0, 40, 5)
    # First hover on the diagnostic so the state is non-empty.
    _ = ed.handle_mouse(
        Event.mouse_event(Point(3, 0), MOUSE_BUTTON_NONE, True, True),
        view,
    )
    assert_equal(ed._minimap_hover_kind, 3)
    # Now hover one cell past the diagnostic's end (col 7 is exclusive).
    _ = ed.handle_mouse(
        Event.mouse_event(Point(8, 0), MOUSE_BUTTON_NONE, True, True),
        view,
    )
    assert_equal(ed._minimap_hover_kind, 0)


def test_editor_text_hover_picks_most_severe_diagnostic_on_overlap() raises:
    """When multiple diagnostics overlap a cell, the most severe one
    wins (lowest numeric severity = highest priority — error beats
    warning beats info beats hint)."""
    var ed = Editor(String("alpha beta gamma"))
    var diags = List[Diagnostic]()
    # Hint covering cols [0, 12).
    diags.append(Diagnostic(
        0, 0, 0, 12, DIAG_SEVERITY_HINT, String("hint"), String("t"),
    ))
    # Warning covering cols [3, 7).
    diags.append(Diagnostic(
        0, 3, 0, 7, DIAG_SEVERITY_WARNING, String("warn"), String("t"),
    ))
    # Error at exactly col 5.
    diags.append(Diagnostic(
        0, 5, 0, 6, DIAG_SEVERITY_ERROR, String("err"), String("t"),
    ))
    ed.set_diagnostics(diags^)
    var view = Rect(0, 0, 40, 5)
    # Cell 5 has all three: error must win.
    _ = ed.handle_mouse(
        Event.mouse_event(Point(5, 0), MOUSE_BUTTON_NONE, True, True),
        view,
    )
    assert_equal(ed._minimap_hover_kind, 3)
    assert_equal(ed._minimap_hover_word, String("[t] err"))
    # Cell 4 has hint + warning but not error: warning wins.
    _ = ed.handle_mouse(
        Event.mouse_event(Point(4, 0), MOUSE_BUTTON_NONE, True, True),
        view,
    )
    assert_equal(ed._minimap_hover_kind, 4)
    # Cell 10 has only the hint.
    _ = ed.handle_mouse(
        Event.mouse_event(Point(10, 0), MOUSE_BUTTON_NONE, True, True),
        view,
    )
    assert_equal(ed._minimap_hover_kind, 6)


def test_editor_text_hover_over_spell_word_records_word() raises:
    """A hover over a misspelled word in the editor surface (not the
    minimap) must populate kind=2 and surface the offending word so
    the same tooltip the minimap uses can render. Confirms the
    text-area branch is wired for spell hits, not just diagnostics."""
    var words = List[String]()
    words.append(String("hello"))
    words.append(String("world"))
    var speller = _spell_with_dict(words)
    var path = _temp_path(String("_text_spell_hover.py"))
    assert_true(write_file(path, String("# helo world\n")))
    var ed = Editor.from_file(path)
    var registry = GrammarRegistry()
    ed.flush_highlights(registry, speller)
    assert_true(ed.spell_lines[0])
    var view = Rect(0, 0, 40, 5)
    # Cell 4 is inside "helo" (line is "# helo world" → bytes 2..6).
    _ = ed.handle_mouse(
        Event.mouse_event(Point(4, 0), MOUSE_BUTTON_NONE, True, True),
        view,
    )
    assert_equal(ed._minimap_hover_kind, 2)
    assert_equal(ed._minimap_hover_buf_row, 0)
    assert_equal(ed._minimap_hover_word, String("helo"))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_text_hover_past_eol_clears_state() raises:
    """Cells past the end of a buffer line don't carry a real cell
    (the row only has the visible glyphs); hover-tooltip should not
    fire there even when the row carries diagnostics earlier on."""
    var ed = Editor(String("ab"))
    var diags = List[Diagnostic]()
    diags.append(Diagnostic(
        0, 0, 0, 2, DIAG_SEVERITY_ERROR, String("e"), String("t"),
    ))
    ed.set_diagnostics(diags^)
    var view = Rect(0, 0, 40, 5)
    # Past EOL — no glyph to hover on.
    _ = ed.handle_mouse(
        Event.mouse_event(Point(20, 0), MOUSE_BUTTON_NONE, True, True),
        view,
    )
    assert_equal(ed._minimap_hover_kind, 0)


def test_editor_text_hover_diagnostic_renders_tooltip() raises:
    """End-to-end: an in-text hover over a diagnostic range produces a
    visible tooltip box on the next paint, with the message in it.
    Mirrors the existing minimap-tooltip render test but exercises the
    text-area hover path."""
    var ed = Editor(String("alpha beta gamma"))
    var diags = List[Diagnostic]()
    diags.append(Diagnostic(
        0, 6, 0, 10, DIAG_SEVERITY_ERROR,
        String("unknown name"), String("pyright"),
    ))
    ed.set_diagnostics(diags^)
    var view = Rect(0, 0, 60, 5)
    _ = ed.handle_mouse(
        Event.mouse_event(Point(7, 0), MOUSE_BUTTON_NONE, True, True),
        view,
    )
    assert_equal(ed._minimap_hover_kind, 3)
    var canvas = Canvas(60, 5)
    canvas.fill(view, String(" "), default_attr())
    ed.paint(canvas, view, False)
    # Sweep the canvas for the message — the tooltip's row anchor is
    # cursor.y - 1, with the label two cells in. Walking the whole grid
    # avoids guessing exactly which row the layout pinned it to.
    var found = False
    for y in range(view.b.y):
        var row_text = String("")
        for x in range(view.b.x):
            row_text = row_text + canvas.get(x, y).glyph
        if _contains(row_text, String("unknown name")):
            found = True
            break
    assert_true(found)


def test_editor_text_hover_anchor_aligns_with_underline_left() raises:
    """The tooltip must sit one row below the underlined span with its
    left edge aligned to the underline's leftmost cell — not anchored
    at the cursor like the minimap-mark hover. Buffer ``alpha beta
    gamma``, diagnostic on bytes [6, 10) which renders the underline at
    screen cells 6..10. Hovering anywhere in that span (we pick cell 8)
    should park the anchor at (x=6, y=1) — the cell directly under the
    'b' of 'beta'."""
    var ed = Editor(String("alpha beta gamma"))
    var diags = List[Diagnostic]()
    diags.append(Diagnostic(
        0, 6, 0, 10, DIAG_SEVERITY_ERROR,
        String("oops"), String("t"),
    ))
    ed.set_diagnostics(diags^)
    var view = Rect(0, 0, 60, 10)
    _ = ed.handle_mouse(
        Event.mouse_event(Point(8, 0), MOUSE_BUTTON_NONE, True, True),
        view,
    )
    assert_equal(ed._minimap_hover_kind, 3)
    assert_true(ed._minimap_hover_below)
    # Anchor x = leftmost cell of underline (6); y = row directly below
    # the underline (0 + 1 = 1).
    assert_equal(ed._minimap_hover_x, 6)
    assert_equal(ed._minimap_hover_y, 1)


def test_editor_minimap_hover_keeps_above_left_anchor() raises:
    """Minimap-source hovers must keep their original above-left
    anchoring — the new below-the-underline behavior is text-area-only.
    A hover on the right-edge minimap column should leave
    ``_minimap_hover_below`` at False so paint uses the legacy
    placement."""
    var words = List[String]()
    words.append(String("hello"))
    words.append(String("world"))
    var speller = _spell_with_dict(words)
    var path = _temp_path(String("_minimap_anchor.py"))
    assert_true(write_file(path, String("# helo world\n")))
    var ed = Editor.from_file(path)
    var registry = GrammarRegistry()
    ed.flush_highlights(registry, speller)
    var view = Rect(0, 0, 40, 5)
    _ = ed.handle_mouse(
        Event.mouse_event(Point(39, 0), MOUSE_BUTTON_NONE, True, True),
        view,
    )
    assert_equal(ed._minimap_hover_kind, 2)
    assert_false(ed._minimap_hover_below)
    # Minimap path stores cursor pos verbatim.
    assert_equal(ed._minimap_hover_x, 39)
    assert_equal(ed._minimap_hover_y, 0)
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_spell_noinspection_suppresses_next_line() raises:
    """A ``# noinspection SpellCheckingInspection`` comment must
    suppress spell underlines on the directive line itself (so the
    word ``noinspection`` doesn't get flagged) and on the following
    line (the IntelliJ "applies to next code element" semantic).
    Lines after the suppression window must still get flagged."""
    var words = List[String]()
    words.append(String("hello"))
    words.append(String("world"))
    var speller = _spell_with_dict(words)
    var path = _temp_path(String("_spell_noinspect.py"))
    # Row 0: the directive, contains ``noinspection`` (12 lowercase
    # letters, would normally be flagged).
    # Row 1: a comment with a misspelling ``helo`` — must NOT flag.
    # Row 2: another comment with ``helo`` — must flag (out of window).
    assert_true(write_file(path, String(
        "# noinspection SpellCheckingInspection\n"
        + "# helo world\n"
        + "# helo world\n"
    )))
    var ed = Editor.from_file(path)
    var registry = GrammarRegistry()
    ed.flush_highlights(registry, speller)
    # Exactly one underline highlight, on row 2.
    assert_equal(len(ed.spell_highlights), 1)
    var sh = ed.spell_highlights[0]
    assert_equal(sh.row, 2)
    # And spell_lines reflects that — only row 2 is marked.
    assert_false(ed.spell_lines[0])
    assert_false(ed.spell_lines[1])
    assert_true(ed.spell_lines[2])
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_spell_underlines_misspelled_word_in_comment() raises:
    """End-to-end: a misspelled word inside a ``#`` comment surfaces as
    a ``STYLE_UNDERLINE`` highlight at the right byte range, and the
    row gets marked in ``spell_lines`` so the minimap can project it."""
    # Dictionary is broad enough that only ``helo`` flags inside the
    # comment — ``hello`` and ``world`` are present.
    var words = List[String]()
    words.append(String("hello"))
    words.append(String("world"))
    var speller = _spell_with_dict(words)
    var path = _temp_path(String("_spell.py"))
    assert_true(write_file(path, String("# helo world hello\n")))
    var ed = Editor.from_file(path)
    var registry = GrammarRegistry()
    ed.flush_highlights(registry, speller)
    # Exactly one underline highlight: for ``helo`` at bytes 2..6.
    assert_equal(len(ed.spell_highlights), 1)
    var sh = ed.spell_highlights[0]
    assert_equal(sh.row, 0)
    assert_equal(sh.col_start, 2)
    assert_equal(sh.col_end, 6)
    assert_true((sh.attr.style & STYLE_UNDERLINE) != 0)
    # Row 0 is marked as having a spell issue; row 1 (the empty
    # trailing line) is not.
    assert_true(len(ed.spell_lines) >= 1)
    assert_true(ed.spell_lines[0])
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_bracket_match_finds_pair_under_cursor() raises:
    """Cursor sitting on an opener returns the matching closer; same
    for a cursor sitting on a closer (scans backward)."""
    var ed = Editor(String("foo(bar)"))
    ed.selections[0].row = 0
    ed.selections[0].col = 3  # on '('
    var m = ed._find_bracket_match_at_cursor()
    assert_true(m)
    var p = m.value()
    assert_equal(p[0], 0); assert_equal(p[1], 3)
    assert_equal(p[2], 0); assert_equal(p[3], 7)
    ed.selections[0].col = 7  # on ')'
    var m2 = ed._find_bracket_match_at_cursor()
    assert_true(m2)
    var p2 = m2.value()
    assert_equal(p2[0], 0); assert_equal(p2[1], 7)
    assert_equal(p2[2], 0); assert_equal(p2[3], 3)


def test_editor_bracket_match_uses_char_just_behind_cursor() raises:
    """Cursor sitting *after* a bracket (typical caret-between-glyphs
    position) still matches the bracket immediately to its left."""
    var ed = Editor(String("foo(bar)"))
    ed.selections[0].row = 0
    ed.selections[0].col = 8  # one past the ')'
    var m = ed._find_bracket_match_at_cursor()
    assert_true(m)
    var p = m.value()
    assert_equal(p[1], 7)  # source = ')'
    assert_equal(p[3], 3)  # match = '('


def test_editor_bracket_match_respects_nesting() raises:
    """Inner pairs don't fool the outer scan and vice versa."""
    var ed = Editor(String("a(b(c)d)e"))
    ed.selections[0].row = 0
    ed.selections[0].col = 1  # outer '('
    var m = ed._find_bracket_match_at_cursor()
    assert_true(m)
    var p = m.value()
    assert_equal(p[3], 7)  # outer ')'
    ed.selections[0].col = 3  # inner '('
    var m2 = ed._find_bracket_match_at_cursor()
    assert_true(m2)
    var p2 = m2.value()
    assert_equal(p2[3], 5)  # inner ')'


def test_editor_bracket_match_across_lines() raises:
    """Forward and backward scans cross row boundaries cleanly."""
    var ed = Editor(String("if (\n    foo,\n    bar,\n)"))
    ed.selections[0].row = 0
    ed.selections[0].col = 3  # '(' on row 0
    var m = ed._find_bracket_match_at_cursor()
    assert_true(m)
    var p = m.value()
    assert_equal(p[2], 3)  # ')' on row 3
    assert_equal(p[3], 0)


def test_editor_bracket_match_unbalanced_returns_none() raises:
    """Missing partner gives ``None`` — no false matches."""
    var ed = Editor(String("foo(bar"))
    ed.selections[0].row = 0
    ed.selections[0].col = 3  # unmatched '('
    var m = ed._find_bracket_match_at_cursor()
    assert_true(not m)


def test_editor_bracket_match_no_bracket_at_cursor() raises:
    """Cursor away from any bracket returns ``None``."""
    var ed = Editor(String("foo(bar)"))
    ed.selections[0].row = 0
    ed.selections[0].col = 1  # on 'o'
    var m = ed._find_bracket_match_at_cursor()
    assert_true(not m)


def test_editor_bracket_match_skips_brackets_in_strings() raises:
    """A ``(`` that lives inside a string highlight must be ignored
    by the matcher, so the outer ``(`` correctly pairs with the outer
    ``)``. We synthesize the string-scope highlights directly rather
    than running the tokenizer — keeps the test independent of which
    grammars are bundled."""
    # Source:    f("(", "z")
    # Cols:      0 1 2 3 4 5 6 7 8 9 10
    # The two '(' bytes inside the string literal at cols 3 sit
    # inside a string span; the outer '(' at col 1 must match ')' at
    # col 10, not the inner one.
    var ed = Editor(String("f(\"(\", \"z\")"))
    # Mark both string literals as string-attr highlights.
    ed.highlights.append(Highlight(0, 2, 5, highlight_string_attr()))
    ed.highlights.append(Highlight(0, 7, 10, highlight_string_attr()))
    ed.selections[0].row = 0
    ed.selections[0].col = 1  # outer '('
    var m = ed._find_bracket_match_at_cursor()
    assert_true(m)
    var p = m.value()
    assert_equal(p[1], 1)
    assert_equal(p[3], 10)


def test_editor_bracket_match_source_inside_string_returns_none() raises:
    """If the source bracket itself sits inside a string scope, the
    matcher returns nothing — we don't want to confuse the user by
    matching across a literal."""
    var ed = Editor(String("f(\"(\", \"z\")"))
    ed.highlights.append(Highlight(0, 2, 5, highlight_string_attr()))
    ed.highlights.append(Highlight(0, 7, 10, highlight_string_attr()))
    ed.selections[0].row = 0
    ed.selections[0].col = 3  # '(' inside the string literal
    var m = ed._find_bracket_match_at_cursor()
    assert_true(not m)


def test_editor_paint_collapsed_view_is_cheap() raises:
    """Maximizing the debug pane collapses the workspace to height 0,
    which gives editor windows a negative-height ``interior``. Without
    a guard, ``editor.paint`` would call ``wrap_lines`` with
    ``max_rows = view.height() = -2``; the negative value bypasses
    ``wrap_lines``'s ``max_rows >= 0`` gate and walks the entire
    buffer every frame — ~200 ms on a multi-thousand-line file,
    enough to peg the main loop at 100 % CPU.

    This regression test asserts the cheap path: a soft-wrap editor
    with a large buffer, painted into an empty view, must not produce
    any visual rows. (We can't time the call portably, but a buffer
    walk would produce many rows; the empty result is the proxy.)
    """
    var text = String("")
    for _ in range(2000):
        text = text + String(
            "the quick brown fox jumps over the lazy dog\n"
        )
    var ed = Editor(text^)
    # Negative height (b.y < a.y) is what window.interior() produces
    # when its outer rect collapses to height 0.
    var collapsed = Rect(1, 5, 50, 3)
    assert_true(collapsed.is_empty())
    var canvas = Canvas(80, 24)
    ed.paint(canvas, collapsed, False)


def test_editor_smooth_scroll_region_and_overdraw() raises:
    """Native smooth-scroll core helpers (the terminal frontend never calls
    these, so this is the only coverage). ``scroll_regions`` reports the
    focused editor's interior + (sub, frac); ``smooth_begin`` gives the
    current/max position as visual-row coordinates; ``smooth_set`` applies a
    visual-row coordinate, clamped, splitting it into (scroll_y, sub, frac);
    ``paint_editor_region`` renders the body at the current scroll_y."""
    var text = String("")
    for i in range(200):
        text = text + String("line ") + String(i) + String("\n")
    var d = Desktop()
    d.windows.add(
        Window.editor_window(String("buf"), Rect(2, 3, 60, 20), text^)
    )
    var idx = d.windows.focused
    d.windows.windows[idx].editor.wrap_mode = WRAP_NONE
    var screen = Rect(0, 0, 80, 40)

    var regions = d.scroll_regions(screen)
    assert_equal(len(regions), 1)
    assert_equal(regions[0].win_idx, idx)
    # The region rect is exactly the (post-fit) window interior.
    var interior = d.windows.windows[idx].interior()
    assert_equal(regions[0].interior.a.x, interior.a.x)
    assert_equal(regions[0].interior.b.y, interior.b.y)
    assert_equal(regions[0].sub, 0)
    assert_true(abs(regions[0].frac) < 0.001)

    # smooth_begin: at the top, current position is 0; max is positive.
    var m = d.smooth_begin(idx, screen)
    assert_true(abs(m[0]) < 0.001)
    assert_true(m[1] > 0.0)

    # smooth_set at visual row 10.4 -> scroll_y 10, sub 0 (no wrap), frac 0.4.
    d.smooth_set(idx, screen, 10.4)
    assert_equal(d.windows.windows[idx].editor.scroll_y, 10)
    assert_equal(d.windows.windows[idx].editor.scroll_sub, 0)
    assert_true(abs(d.windows.windows[idx].editor.scroll_frac - 0.4) < 0.001)
    # Out-of-range clamps to max; report it as (sub, frac).
    d.smooth_set(idx, screen, 1.0e9)
    assert_true(d.windows.windows[idx].editor.scroll_y > 100)

    # Overdraw render at the current scroll_y. With scroll_y back at 10,
    # region row 0 carries buffer line 10 ("line 10").
    d.smooth_set(idx, screen, 10.0)
    var rcols = interior.width()
    var rrows = interior.height() + 2
    var canvas = Canvas(rcols, rrows)
    canvas.clear(default_attr())
    d.paint_editor_region(idx, canvas, rcols, rrows, True)
    var row0 = String("")
    for x in range(rcols):
        row0 = row0 + canvas.get(x, 0).glyph
    assert_true(row0.find(String("line 10")) >= 0)


def test_editor_smooth_scroll_wrap_sub_row_anchor() raises:
    """Under soft wrap, the smooth-scroll anchor steps by *visual* rows, not
    buffer lines: a long line that wraps to several rows can be scrolled into
    partially (``scroll_sub`` > 0) instead of jumping a whole paragraph."""
    # First line wraps to many visual rows; the rest are short.
    var long = String("")
    for _ in range(60):
        long = long + String("wordy ")
    var text = long + String("\n")
    for i in range(50):
        text = text + String("short ") + String(i) + String("\n")
    var d = Desktop()
    d.windows.add(
        Window.editor_window(String("wrap"), Rect(2, 3, 40, 20), text^)
    )
    var idx = d.windows.focused
    d.windows.windows[idx].editor.wrap_mode = WRAP_SOFT
    var screen = Rect(0, 0, 60, 40)
    # Realize the layout (fit windows) so the interior width is set.
    _ = d.scroll_regions(screen)

    # The first buffer line occupies several visual rows at this width.
    var interior = d.windows.windows[idx].interior()
    var content_w = interior.width() \
        - d.windows.windows[idx].editor._total_gutter() \
        - d.windows.windows[idx].editor._right_gutter()
    var first_rows = d.windows.windows[idx].editor._line_visual_rows(
        0, content_w
    )
    assert_true(first_rows >= 3)

    # Scrolling to visual row 2 must land *inside* the first buffer line
    # (scroll_y still 0, sub == 2) — the per-visual-row anchoring that makes
    # wrapped smooth scroll possible.
    d.smooth_set(idx, screen, 2.0)
    assert_equal(d.windows.windows[idx].editor.scroll_y, 0)
    assert_equal(d.windows.windows[idx].editor.scroll_sub, 2)

    # Scrolling one visual row past the first line lands on buffer line 1,
    # sub 0.
    d.smooth_set(idx, screen, Float64(first_rows))
    assert_equal(d.windows.windows[idx].editor.scroll_y, 1)
    assert_equal(d.windows.windows[idx].editor.scroll_sub, 0)


def test_kwarg_conceal_basic_python() raises:
    # ``foo(a=a, b=b, d=4)`` hides exactly the two redundant labels (the
    # ``a`` before ``=a`` and the ``b`` before ``=b``); ``d=4`` is left
    # alone because the value isn't the label.
    # Separator selection by language: '=' for py/mojo, none for plain text.
    assert_equal(kwarg_separator_for_extension(String("py")), 0x3D)
    assert_equal(kwarg_separator_for_extension(String("mojo")), 0x3D)
    assert_equal(kwarg_separator_for_extension(String("txt")), -1)
    var line = String("foo(a=a, b=b, d=4)")
    var hide = kwarg_conceal_ranges(line, 0x3D, List[Tuple[Int, Int]]())
    assert_equal(len(hide), 2)
    # ``a`` is at byte 4..5 (just before the first '='), ``b`` at 9..10.
    assert_equal(hide[0][0], 4)
    assert_equal(hide[0][1], 5)
    assert_equal(hide[1][0], 9)
    assert_equal(hide[1][1], 10)


def test_kwarg_conceal_skips_statement_and_mismatch() raises:
    # Statement-level ``x = x`` is at paren depth 0 → never compressed.
    var stmt = kwarg_conceal_ranges(
        String("x = x"), 0x3D, List[Tuple[Int, Int]](),
    )
    assert_equal(len(stmt), 0)
    # Inside parens but the names differ → not compressed.
    var diff = kwarg_conceal_ranges(
        String("foo(a=b)"), 0x3D, List[Tuple[Int, Int]](),
    )
    assert_equal(len(diff), 0)


def test_kwarg_conceal_skips_strings_and_eq_eq() raises:
    # ``==`` comparison is not a keyword-arg separator.
    var cmp = kwarg_conceal_ranges(
        String("foo(a == a)"), 0x3D, List[Tuple[Int, Int]](),
    )
    assert_equal(len(cmp), 0)
    # A ``name=name`` that lives inside a string span is masked out.
    var line = String("foo('a=a')")
    var spans = List[Tuple[Int, Int]]()
    spans.append((4, 9))  # the quoted 'a=a'
    var hidden = kwarg_conceal_ranges(line, 0x3D, spans)
    assert_equal(len(hidden), 0)


def test_kwarg_conceal_skips_annotation_default() raises:
    # ``def f(request, name: str | None = None):`` must NOT conceal the
    # ``None`` before ``=``. That ``None`` is part of the type annotation
    # ``str | None`` — preceded by '|', not a keyword-argument boundary — so
    # comparing it against the default ``None`` is wrong.
    var line = String("def impersonate(request, name: str | None = None):")
    var hide = kwarg_conceal_ranges(line, 0x3D, List[Tuple[Int, Int]]())
    assert_equal(len(hide), 0)


def test_kwarg_conceal_swift_colon() raises:
    # Swift uses ':' — ``foo(a: a)`` hides the label ``a`` (byte 4..5),
    # leaving ``: a``.
    assert_equal(kwarg_separator_for_extension(String("swift")), 0x3A)
    var hide = kwarg_conceal_ranges(
        String("foo(a: a)"), 0x3A, List[Tuple[Int, Int]](),
    )
    assert_equal(len(hide), 1)
    assert_equal(hide[0][0], 4)
    assert_equal(hide[0][1], 5)


def test_kwarg_conceal_build_segment_collapses_and_shifts() raises:
    # Segment ``a=a`` with the leading ``a`` hidden renders ``≡a``: the
    # separator '=' is repainted as the distinct marker, byte 0 collapses to
    # cell 0 while bytes 1 (now '≡') and 2 ('a') shift left. The '≡' is 3
    # UTF-8 bytes but still one display cell, so the byte→cell map is
    # unchanged from the literal-'=' case.
    var seg = String("a=a")
    var hide = List[Tuple[Int, Int]]()
    hide.append((0, 1))
    var built = build_concealed_segment(seg, hide, String("≡"))
    assert_equal(built[0], String("≡a"))
    var cell_map = built[1].copy()
    assert_equal(len(cell_map), 3)  # one entry per raw byte
    assert_equal(cell_map[0], 0)    # hidden 'a' collapses to cell 0
    assert_equal(cell_map[1], 0)    # separator now at cell 0
    assert_equal(cell_map[2], 1)    # 'a' now at cell 1
    assert_equal(built[2], 2)       # two display cells
    # Empty sep_glyph keeps the literal separator byte (legacy behavior).
    var plain = build_concealed_segment(seg, hide, String(""))
    assert_equal(plain[0], String("=a"))


def test_undo_history_is_capped_by_bytes_not_just_entries() raises:
    """A big buffer's undo history is bounded in *bytes*, not entries.

    Every entry is a whole-buffer copy, so the 500-entry cap alone meant
    the cost of a full stack scaled with the file: 500 edits in a 1 MB
    file retained ~500 MB per editor, times every open window. Typing is
    all it took to get there.
    """
    # ~1 MB buffer: 1024 lines of 1 KB. Assigning ``buffer.lines``
    # directly keeps the fixture out of the O(n^2) string-concat that
    # building one 1 MB literal would cost.
    var chunk = String("")
    for _ in range(64):
        chunk = chunk + String("0123456789abcdef")
    var lines = List[String]()
    for _ in range(1024):
        lines.append(chunk)
    var ed = Editor(String(""))
    ed.buffer.lines = lines^
    var per_snapshot = 0
    for i in range(ed.buffer.line_count()):
        per_snapshot += len(ed.buffer.lines[i].as_bytes()) + 1
    assert_true(per_snapshot > 1000000)
    for _ in range(200):
        ed._push_undo()
    var total = 0
    for i in range(len(ed._undo_stack)):
        total += ed._undo_stack[i].byte_size
    # The byte budget is what bound this, not the entry count: 200 pushes
    # is well under the 500-entry cap, yet entries were dropped and the
    # retained bytes fit the budget (~210 MB unbounded, before the fix).
    assert_true(len(ed._undo_stack) < 200)
    assert_true(len(ed._undo_stack) < _UNDO_STACK_LIMIT)
    assert_true(total <= _UNDO_STACK_BYTE_BUDGET)
    # …and it still keeps a usable amount of history.
    assert_true(len(ed._undo_stack) >= _UNDO_STACK_MIN_ENTRIES)


def test_undo_history_still_honors_the_entry_cap() raises:
    """A small buffer never reaches the byte budget, so the entry cap is
    what stops the stack — the behaviour that was there before."""
    var ed = Editor(String("hello\nworld\n"))
    for _ in range(_UNDO_STACK_LIMIT + 100):
        ed._push_undo()
    assert_equal(len(ed._undo_stack), _UNDO_STACK_LIMIT)
    # Trimming drops the *oldest* entries, so undo still rewinds.
    assert_true(ed.undo())


def main() raises:
    setup_test_env()
    test_editor_fold_collapse()
    test_editor_sticky_rows()
    test_editor_sticky_rows_multiline()
    test_editor_sticky_scroll_paints_headers()
    test_editor_typing_and_arrows()
    test_editor_typing_non_ascii()
    test_editor_typing_replaces_selection()
    test_editor_backspace_deletes_selection()
    test_editor_diff_selection_copies_phantom_rows()
    test_editor_cut_whole_line_when_no_selection()
    test_editor_cut_whole_line_only_line()
    test_editor_smart_indent_mirrors_previous_line()
    test_editor_smart_indent_after_open_brace()
    test_editor_smart_indent_after_colon()
    test_editor_cut_selection()
    test_editor_paste_text_single_line()
    test_editor_paste_text_multiline()
    test_editor_paste_replaces_selection()
    test_editor_goto_line()
    test_editor_find_next()
    test_editor_find_next_case_insensitive()
    test_editor_find_next_whole_word()
    test_editor_find_next_regex()
    test_editor_replace_all_case_insensitive()
    test_editor_toggle_comment_single_line()
    test_editor_toggle_comment_selection()
    test_editor_toggle_comment_language_aware()
    test_editor_toggle_comment_indented()
    test_editor_toggle_comment_common_indent()
    test_editor_toggle_comment_skips_blank_lines()
    test_editor_toggle_case()
    test_editor_replace_all()
    test_editor_uses_editorconfig_indent()
    test_editor_tab_indents_selected_lines()
    test_editor_preserves_crlf_round_trip()
    test_editor_rejects_modified_letter_typing()
    test_editor_rename_multirow_refreshes_all_highlights()
    test_editor_default_text_is_light_green()
    test_editor_refreshes_highlights_after_edits()
    test_editor_paint_overlays_highlight_attr()
    test_editor_paint_compresses_kwargs_off_caret_line()
    test_editor_text_click_does_not_toggle_breakpoint()
    test_save_as_dialog_seeds_from_existing_path()
    test_save_as_dialog_typing_updates_filename()
    test_save_as_dialog_enter_submits_joined_path()
    test_save_as_dialog_tab_focus_then_listing_navigation()
    test_save_as_dialog_empty_filename_blocks_submit()
    test_editor_sticky_col_down_through_short_line()
    test_editor_sticky_col_up_through_short_line()
    test_editor_sticky_col_reset_by_left_arrow()
    test_editor_sticky_col_reset_by_right_arrow()
    test_editor_sticky_col_reset_by_typing()
    test_editor_sticky_col_reset_by_click()
    test_editor_sticky_col_reset_by_home_end()
    test_editor_sticky_col_pageup_pagedown()
    test_editor_sticky_col_shift_down_keeps_anchor()
    test_editor_left_right_steps_over_multibyte_codepoint()
    test_editor_backspace_removes_whole_codepoint()
    test_editor_delete_key_removes_whole_codepoint()
    test_editor_set_hover_result_displays_only_for_current_word()
    test_editor_set_completions_opens_popup()
    test_editor_typing_word_char_stamps_autotrigger_request()
    test_editor_typing_non_word_char_skips_autotrigger()
    test_editor_typing_non_word_char_closes_visible_popup()
    test_editor_show_no_completion_message_opens_unselectable_popup()
    test_editor_set_diagnostics_builds_per_row_severity_index()
    test_editor_minimap_kind_prioritizes_error_over_git_and_spell()
    test_editor_minimap_warning_outranks_git_change()
    test_editor_minimap_hint_loses_to_spell()
    test_editor_right_click_on_breakpoint_emits_menu_request()
    test_editor_right_gutter_paints_gray_square_for_changes()
    test_editor_paints_deletion_underscore_in_gutter()
    test_editor_right_gutter_projects_full_file_when_scrolled()
    test_editor_invalidate_spell_drops_overlay_after_word_added()
    test_editor_spell_uses_curly_colored_underline_on_supported_terminal()
    test_editor_minimap_git_change_wins_over_spell_on_same_row()
    test_editor_minimap_click_scrolls_to_marked_line()
    test_editor_minimap_hover_records_spell_word()
    test_editor_minimap_hover_paints_tooltip()
    test_editor_text_hover_over_diagnostic_records_kind_and_message()
    test_editor_text_hover_off_diagnostic_clears_state()
    test_editor_text_hover_picks_most_severe_diagnostic_on_overlap()
    test_editor_text_hover_over_spell_word_records_word()
    test_editor_text_hover_past_eol_clears_state()
    test_editor_text_hover_diagnostic_renders_tooltip()
    test_editor_text_hover_anchor_aligns_with_underline_left()
    test_editor_minimap_hover_keeps_above_left_anchor()
    test_editor_spell_noinspection_suppresses_next_line()
    test_editor_spell_underlines_misspelled_word_in_comment()
    test_editor_bracket_match_finds_pair_under_cursor()
    test_editor_bracket_match_uses_char_just_behind_cursor()
    test_editor_bracket_match_respects_nesting()
    test_editor_bracket_match_across_lines()
    test_editor_bracket_match_unbalanced_returns_none()
    test_editor_bracket_match_no_bracket_at_cursor()
    test_editor_bracket_match_skips_brackets_in_strings()
    test_editor_bracket_match_source_inside_string_returns_none()
    test_editor_paint_collapsed_view_is_cheap()
    test_editor_smooth_scroll_region_and_overdraw()
    test_editor_smooth_scroll_wrap_sub_row_anchor()
    test_kwarg_conceal_basic_python()
    test_kwarg_conceal_skips_statement_and_mismatch()
    test_kwarg_conceal_skips_strings_and_eq_eq()
    test_kwarg_conceal_skips_annotation_default()
    test_kwarg_conceal_swift_colon()
    test_kwarg_conceal_build_segment_collapses_and_shifts()
    test_undo_history_is_capped_by_bytes_not_just_entries()
    test_undo_history_still_honors_the_entry_cap()
    print("editor_edit: 108 tests passed")
