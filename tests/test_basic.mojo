"""Pure-data tests: geometry, colors, canvas, event factories.

These tests don't touch the terminal so they can run in CI without a TTY.
Run with::

    mojo run -I src tests/test_basic.mojo
"""

from std.ffi import external_call
from std.testing import assert_equal, assert_false, assert_true

from mojovision.canvas import Canvas
from mojovision.cell import Cell, blank_cell
from mojovision.colors import Attr, BLACK, BLUE, WHITE, YELLOW, default_attr
from mojovision.editor import Editor, TextBuffer
from mojovision.file_dialog import FileDialog
from mojovision.desktop import (
    APP_QUIT_ACTION,
    Desktop,
    EDITOR_FIND, EDITOR_GOTO, EDITOR_QUICK_OPEN, EDITOR_REPLACE, EDITOR_SAVE,
    EDITOR_SAVE_AS, EDITOR_TOGGLE_CASE, EDITOR_TOGGLE_COMMENT,
    Hotkey,
    PROJECT_CLOSE_ACTION, PROJECT_FIND, PROJECT_REPLACE, PROJECT_TREE_ACTION,
    WINDOW_CLOSE,
    ctrl_key, format_hotkey,
)
from mojovision.file_io import (
    basename, find_git_project, join_path, list_directory, parent_path,
    read_file, stat_file, write_file,
)
from mojovision.file_tree import FILE_TREE_WIDTH, FileTree
from mojovision.menu import Menu, MenuBar, MenuItem
from mojovision.project import (
    GitignoreMatcher, find_in_project, replace_in_project, walk_project_files,
)
from mojovision.quick_open import QuickOpen, quick_open_match
from mojovision.json import (
    JsonValue, encode_json, json_array, json_bool, json_int, json_null,
    json_object, json_str, parse_json,
)
from mojovision.lsp import (
    LSP_NOTIFICATION, LSP_RESPONSE, LspClient, LspIncoming, LspProcess,
    _drop_prefix, _find_double_crlf, _parse_content_length, classify_message,
)
from mojovision.highlight import (
    DefinitionRequest, Highlight, extension_of, highlight_for_extension,
    highlight_comment_attr, highlight_keyword_attr, highlight_number_attr,
    highlight_string_attr, word_at,
)
from mojovision.window import WindowManager
from mojovision.events import (
    Event, EVENT_KEY, EVENT_MOUSE, EVENT_NONE, EVENT_QUIT, EVENT_RESIZE,
    KEY_BACKSPACE, KEY_DELETE, KEY_DOWN, KEY_END, KEY_ENTER, KEY_ESC,
    KEY_F5, KEY_HOME,
    KEY_LEFT, KEY_PAGEDOWN, KEY_PAGEUP, KEY_RIGHT, KEY_UP,
    MOD_ALT, MOD_CTRL, MOD_NONE, MOD_SHIFT,
    MOUSE_BUTTON_LEFT, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from mojovision.geometry import Point, Rect
from mojovision.terminal import parse_input
from mojovision.view import Fill, Frame, Label, centered
from mojovision.window import Window


fn test_point_arithmetic() raises:
    var p = Point(2, 3)
    var q = Point(5, 7)
    assert_true((p + q) == Point(7, 10))
    assert_true((q - p) == Point(3, 4))
    assert_true(p == Point(2, 3))
    assert_false(p == q)


fn test_rect_basics() raises:
    var r = Rect(0, 0, 10, 5)
    assert_equal(r.width(), 10)
    assert_equal(r.height(), 5)
    assert_false(r.is_empty())
    assert_true(r.contains(Point(5, 2)))
    assert_false(r.contains(Point(10, 2)))  # exclusive
    assert_false(r.contains(Point(5, 5)))   # exclusive

    var s = Rect(5, 2, 12, 6)
    var inter = r.intersect(s)
    assert_true(inter == Rect(5, 2, 10, 5))

    var u = r.union(s)
    assert_true(u == Rect(0, 0, 12, 6))

    assert_true(Rect(0, 0, 0, 0).is_empty())


fn test_rect_helpers() raises:
    var r = Rect.sized(Point(3, 4), 7, 2)
    assert_true(r == Rect(3, 4, 10, 6))
    assert_true(r.translated(Point(1, 1)) == Rect(4, 5, 11, 7))
    assert_true(r.inset(1, 0) == Rect(4, 4, 9, 6))


fn test_attr() raises:
    var a = Attr(WHITE, BLUE)
    var b = a.with_fg(YELLOW)
    assert_true(a.fg == WHITE)
    assert_true(b.fg == YELLOW)
    assert_true(b.bg == BLUE)
    assert_false(a == b)


fn test_canvas_put_text() raises:
    var c = Canvas(20, 5)
    var n = c.put_text(Point(2, 1), String("hello"), default_attr())
    assert_equal(n, 5)
    assert_equal(c.get(2, 1).glyph, String("h"))
    assert_equal(c.get(6, 1).glyph, String("o"))
    assert_equal(c.get(7, 1).glyph, String(" "))  # untouched


fn test_canvas_box() raises:
    var c = Canvas(10, 5)
    c.draw_box(Rect(0, 0, 10, 5), default_attr(), False)
    assert_equal(c.get(0, 0).glyph, String("┌"))
    assert_equal(c.get(9, 0).glyph, String("┐"))
    assert_equal(c.get(0, 4).glyph, String("└"))
    assert_equal(c.get(9, 4).glyph, String("┘"))
    assert_equal(c.get(5, 0).glyph, String("─"))


fn test_canvas_fill() raises:
    var c = Canvas(5, 3)
    c.fill(Rect(1, 1, 4, 2), String("X"), default_attr())
    assert_equal(c.get(0, 0).glyph, String(" "))
    assert_equal(c.get(1, 1).glyph, String("X"))
    assert_equal(c.get(3, 1).glyph, String("X"))
    assert_equal(c.get(4, 1).glyph, String(" "))


fn test_event_factories() raises:
    var k = Event.key_event(KEY_ENTER)
    assert_true(k.kind == EVENT_KEY)
    assert_true(k.is_key(KEY_ENTER))

    var q = Event.quit_event()
    assert_true(q.kind == EVENT_QUIT)

    var r = Event.resize_event(80, 24)
    assert_true(r.kind == EVENT_RESIZE)
    assert_true(r.pos == Point(80, 24))


fn test_parse_input_keys() raises:
    # Lone ESC could be a real keypress or the start of a partial sequence
    # whose tail hasn't arrived yet — the parser defers the decision via
    # (EVENT_NONE, 0). Terminal.poll_event disambiguates with a timeout.
    var esc = parse_input(String("\x1b"))
    assert_true(esc[0].kind == EVENT_NONE)
    assert_equal(esc[1], 0)

    var arrow_up = parse_input(String("\x1b[A"))
    assert_true(arrow_up[0].kind == EVENT_KEY)
    assert_equal(arrow_up[1], 3)

    var enter = parse_input(String("\r"))
    assert_true(enter[0].is_key(KEY_ENTER))

    var letter = parse_input(String("a"))
    assert_true(letter[0].kind == EVENT_KEY)
    assert_true(letter[0].key == UInt32(ord("a")))


fn test_parse_input_sgr_mouse() raises:
    # Left-button press at (10, 5). Terminal reports 1-based; we expose 0-based.
    var press = parse_input(String("\x1b[<0;11;6M"))
    assert_true(press[0].kind == 2)  # EVENT_MOUSE
    assert_true(press[0].pos == Point(10, 5))
    assert_true(press[0].pressed)
    assert_false(press[0].motion)

    # Drag-motion of left button (motion bit 32 set) at (12, 7).
    var drag = parse_input(String("\x1b[<32;13;8M"))
    assert_true(drag[0].kind == 2)
    assert_true(drag[0].pos == Point(12, 7))
    assert_true(drag[0].pressed)
    assert_true(drag[0].motion)

    # Release: terminator 'm'.
    var release = parse_input(String("\x1b[<0;15;9m"))
    assert_true(release[0].kind == 2)
    assert_false(release[0].pressed)

    # Two events back-to-back: parser must consume only the first.
    var two = parse_input(String("\x1b[<0;1;1M\x1b[<0;2;2m"))
    assert_equal(two[1], 9)  # first sequence is 9 bytes


fn test_centered() raises:
    var outer = Rect(0, 0, 80, 24)
    var inner = centered(outer, 20, 6)
    assert_true(inner == Rect(30, 9, 50, 15))


# ----- Editor tests ---------------------------------------------------------


comptime _VIEW = Rect(0, 0, 80, 24)
comptime _SCREEN = Rect(0, 0, 100, 30)


fn _key(k: UInt32, mods: UInt8 = MOD_NONE) -> Event:
    return Event.key_event(k, mods)


fn test_text_buffer_split_and_join() raises:
    var b = TextBuffer(String("ab\ncd"))
    assert_equal(b.line_count(), 2)
    assert_equal(b.line(0), String("ab"))
    assert_equal(b.line(1), String("cd"))
    var p = b.split(0, 1)                 # "ab" → "a" / "b"
    assert_equal(p[0], 1); assert_equal(p[1], 0)
    assert_equal(b.line_count(), 3)
    assert_equal(b.line(0), String("a"))
    assert_equal(b.line(1), String("b"))
    assert_equal(b.line(2), String("cd"))
    # Backspace at start of line 1 joins it onto line 0.
    var q = b.delete_before(1, 0)
    assert_equal(q[0], 0); assert_equal(q[1], 1)
    assert_equal(b.line_count(), 2)
    assert_equal(b.line(0), String("ab"))


fn test_editor_typing_and_arrows() raises:
    var ed = Editor(String("hello"))
    assert_equal(ed.cursor_col, 0)
    _ = ed.handle_key(_key(KEY_END), _VIEW)
    assert_equal(ed.cursor_col, 5)
    _ = ed.handle_key(_key(UInt32(ord("!"))), _VIEW)
    assert_equal(ed.buffer.line(0), String("hello!"))
    assert_equal(ed.cursor_col, 6)
    _ = ed.handle_key(_key(KEY_LEFT), _VIEW)
    assert_equal(ed.cursor_col, 5)
    _ = ed.handle_key(_key(KEY_HOME), _VIEW)
    assert_equal(ed.cursor_col, 0)


fn test_editor_word_movement() raises:
    var ed = Editor(String("hello world foo"))
    # Ctrl+Right from start: lands at start of "world" (col 6).
    _ = ed.handle_key(_key(KEY_RIGHT, MOD_CTRL), _VIEW)
    assert_equal(ed.cursor_col, 6)
    # Again: start of "foo" (col 12).
    _ = ed.handle_key(_key(KEY_RIGHT, MOD_CTRL), _VIEW)
    assert_equal(ed.cursor_col, 12)
    # Again: end of buffer (col 15) — no further word.
    _ = ed.handle_key(_key(KEY_RIGHT, MOD_CTRL), _VIEW)
    assert_equal(ed.cursor_col, 15)
    # Ctrl+Left walks back to start of each word.
    _ = ed.handle_key(_key(KEY_LEFT, MOD_CTRL), _VIEW)
    assert_equal(ed.cursor_col, 12)
    _ = ed.handle_key(_key(KEY_LEFT, MOD_CTRL), _VIEW)
    assert_equal(ed.cursor_col, 6)
    _ = ed.handle_key(_key(KEY_LEFT, MOD_CTRL), _VIEW)
    assert_equal(ed.cursor_col, 0)


fn test_editor_word_movement_across_lines() raises:
    var ed = Editor(String("abc\ndef"))
    # Ctrl+Right from start: end of "abc" on line 0.
    _ = ed.handle_key(_key(KEY_RIGHT, MOD_CTRL), _VIEW)
    assert_equal(ed.cursor_row, 0); assert_equal(ed.cursor_col, 3)
    # Again: jumps to start of next line.
    _ = ed.handle_key(_key(KEY_RIGHT, MOD_CTRL), _VIEW)
    assert_equal(ed.cursor_row, 1); assert_equal(ed.cursor_col, 0)
    # Ctrl+Left from (1,0): end of previous line.
    _ = ed.handle_key(_key(KEY_LEFT, MOD_CTRL), _VIEW)
    assert_equal(ed.cursor_row, 0); assert_equal(ed.cursor_col, 3)


fn test_editor_shift_arrow_extends_selection() raises:
    var ed = Editor(String("hello"))
    assert_false(ed.has_selection())
    _ = ed.handle_key(_key(KEY_RIGHT, MOD_SHIFT), _VIEW)
    assert_true(ed.has_selection())
    assert_equal(ed.anchor_col, 0); assert_equal(ed.cursor_col, 1)
    _ = ed.handle_key(_key(KEY_RIGHT, MOD_SHIFT), _VIEW)
    assert_equal(ed.anchor_col, 0); assert_equal(ed.cursor_col, 2)
    # Plain arrow collapses selection.
    _ = ed.handle_key(_key(KEY_RIGHT), _VIEW)
    assert_false(ed.has_selection())
    assert_equal(ed.cursor_col, 3); assert_equal(ed.anchor_col, 3)


fn test_editor_shift_ctrl_arrow_composes() raises:
    """Selection and word movement compose: Shift+Ctrl+Right keeps the anchor
    while jumping by a whole word."""
    var ed = Editor(String("hello world foo"))
    var both: UInt8 = MOD_SHIFT | MOD_CTRL
    _ = ed.handle_key(_key(KEY_RIGHT, both), _VIEW)
    assert_true(ed.has_selection())
    assert_equal(ed.anchor_col, 0); assert_equal(ed.cursor_col, 6)
    _ = ed.handle_key(_key(KEY_RIGHT, both), _VIEW)
    assert_equal(ed.anchor_col, 0); assert_equal(ed.cursor_col, 12)
    # Now Shift+Ctrl+Left walks the cursor back through words; anchor stays.
    _ = ed.handle_key(_key(KEY_LEFT, both), _VIEW)
    assert_equal(ed.anchor_col, 0); assert_equal(ed.cursor_col, 6)


fn test_editor_typing_replaces_selection() raises:
    var ed = Editor(String("hello"))
    # Select first 4 chars
    for _ in range(4):
        _ = ed.handle_key(_key(KEY_RIGHT, MOD_SHIFT), _VIEW)
    assert_equal(ed.cursor_col, 4)
    _ = ed.handle_key(_key(UInt32(ord("X"))), _VIEW)
    assert_equal(ed.buffer.line(0), String("Xo"))
    assert_false(ed.has_selection())
    assert_equal(ed.cursor_col, 1)


fn test_editor_backspace_deletes_selection() raises:
    var ed = Editor(String("hello"))
    _ = ed.handle_key(_key(KEY_RIGHT), _VIEW)         # cursor at 1
    for _ in range(3):
        _ = ed.handle_key(_key(KEY_RIGHT, MOD_SHIFT), _VIEW)
    # selection covers "ell"
    _ = ed.handle_key(_key(KEY_BACKSPACE), _VIEW)
    assert_equal(ed.buffer.line(0), String("ho"))
    assert_false(ed.has_selection())


fn test_editor_mouse_click_sets_cursor() raises:
    var ed = Editor(String("hello"))
    _ = ed.handle_mouse(
        Event.mouse_event(Point(3, 0), MOUSE_BUTTON_LEFT, True, False),
        _VIEW,
    )
    assert_equal(ed.cursor_col, 3)
    assert_false(ed.has_selection())


fn test_editor_mouse_drag_extends_selection() raises:
    var ed = Editor(String("hello world"))
    _ = ed.handle_mouse(
        Event.mouse_event(Point(1, 0), MOUSE_BUTTON_LEFT, True, False),
        _VIEW,
    )
    assert_equal(ed.cursor_col, 1)
    _ = ed.handle_mouse(
        Event.mouse_event(Point(7, 0), MOUSE_BUTTON_LEFT, True, True),
        _VIEW,
    )
    assert_true(ed.has_selection())
    assert_equal(ed.anchor_col, 1); assert_equal(ed.cursor_col, 7)


fn test_editor_mouse_click_clamps_to_line() raises:
    var ed = Editor(String("hi"))
    _ = ed.handle_mouse(
        Event.mouse_event(Point(50, 0), MOUSE_BUTTON_LEFT, True, False),
        _VIEW,
    )
    # Past EOL → clamped to line length.
    assert_equal(ed.cursor_col, 2)


fn test_terminal_parses_modified_arrows() raises:
    """The CSI ``ESC[1;<mod><letter>`` form gives us shift/ctrl on arrows."""
    var shift_right = parse_input(String("\x1b[1;2C"))
    assert_true(shift_right[0].kind == EVENT_KEY)
    assert_true(shift_right[0].key == KEY_RIGHT)
    assert_true((shift_right[0].mods & MOD_SHIFT) != 0)
    assert_equal(shift_right[1], 6)

    var ctrl_left = parse_input(String("\x1b[1;5D"))
    assert_true(ctrl_left[0].key == KEY_LEFT)
    assert_true((ctrl_left[0].mods & MOD_CTRL) != 0)

    var shift_up = parse_input(String("\x1b[1;2A"))
    assert_true(shift_up[0].key == KEY_UP)
    assert_true((shift_up[0].mods & MOD_SHIFT) != 0)

    var shift_down = parse_input(String("\x1b[1;2B"))
    assert_true(shift_down[0].key == KEY_DOWN)
    assert_true((shift_down[0].mods & MOD_SHIFT) != 0)

    var both_up = parse_input(String("\x1b[1;6A"))
    assert_true(both_up[0].key == KEY_UP)
    assert_true((both_up[0].mods & MOD_SHIFT) != 0)
    assert_true((both_up[0].mods & MOD_CTRL) != 0)

    var both_right = parse_input(String("\x1b[1;6C"))
    assert_true(both_right[0].key == KEY_RIGHT)
    assert_true((both_right[0].mods & MOD_SHIFT) != 0)
    assert_true((both_right[0].mods & MOD_CTRL) != 0)


fn test_editor_selection_text() raises:
    var ed = Editor(String("hello world"))
    # Select "hello "
    for _ in range(6):
        _ = ed.handle_key(_key(KEY_RIGHT, MOD_SHIFT), _VIEW)
    assert_equal(ed.selection_text(), String("hello "))


fn test_editor_cut_selection() raises:
    var ed = Editor(String("hello world"))
    for _ in range(5):
        _ = ed.handle_key(_key(KEY_RIGHT, MOD_SHIFT), _VIEW)
    var cut = ed.cut_selection()
    assert_equal(cut, String("hello"))
    assert_equal(ed.buffer.line(0), String(" world"))
    assert_false(ed.has_selection())


fn test_editor_paste_text_single_line() raises:
    var ed = Editor(String("hello"))
    ed.move_to(0, 5, False)
    ed.paste_text(String(" world"))
    assert_equal(ed.buffer.line(0), String("hello world"))
    assert_equal(ed.cursor_col, 11)


fn test_editor_paste_text_multiline() raises:
    var ed = Editor(String("hello"))
    ed.move_to(0, 5, False)
    ed.paste_text(String("\nworld\nfoo"))
    assert_equal(ed.buffer.line_count(), 3)
    assert_equal(ed.buffer.line(0), String("hello"))
    assert_equal(ed.buffer.line(1), String("world"))
    assert_equal(ed.buffer.line(2), String("foo"))
    assert_equal(ed.cursor_row, 2)
    assert_equal(ed.cursor_col, 3)


fn test_editor_paste_replaces_selection() raises:
    var ed = Editor(String("hello world"))
    for _ in range(5):
        _ = ed.handle_key(_key(KEY_RIGHT, MOD_SHIFT), _VIEW)
    ed.paste_text(String("HEY"))
    assert_equal(ed.buffer.line(0), String("HEY world"))
    assert_false(ed.has_selection())


fn test_editor_selection_text_multiline() raises:
    var ed = Editor(String("ab\ncd\nef"))
    # Select from (0,1) to (2,1) — i.e., "b\ncd\ne"
    ed.move_to(0, 1, False)
    ed.move_to(2, 1, True)
    assert_equal(ed.selection_text(), String("b\ncd\ne"))


fn test_editor_goto_line() raises:
    var ed = Editor(String("a\nb\nc\nd\ne"))
    ed.goto_line(3)
    assert_equal(ed.cursor_row, 2)
    assert_equal(ed.cursor_col, 0)
    # Out-of-range clamps.
    ed.goto_line(99)
    assert_equal(ed.cursor_row, 4)
    ed.goto_line(0)
    assert_equal(ed.cursor_row, 0)


fn test_editor_find_next() raises:
    var ed = Editor(String("foo bar foo baz"))
    var hit1 = ed.find_next(String("foo"))
    assert_true(hit1)
    # First hit at col 0 — but find_next searches *after* the cursor; with
    # cursor initially at (0,0) the implementation skips one column. So the
    # first hit is at col 8 ("foo baz").
    assert_equal(ed.cursor_row, 0); assert_equal(ed.cursor_col, 11)
    assert_true(ed.has_selection())
    assert_equal(ed.selection_text(), String("foo"))
    # Wrap to the earlier match.
    var hit2 = ed.find_next(String("foo"))
    assert_true(hit2)
    assert_equal(ed.cursor_col, 3)


fn test_editor_toggle_comment_single_line() raises:
    var ed = Editor(String("hello"))
    ed.toggle_comment()
    assert_equal(ed.buffer.line(0), String("// hello"))
    ed.toggle_comment()
    assert_equal(ed.buffer.line(0), String("hello"))


fn test_editor_toggle_comment_selection() raises:
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


fn test_editor_toggle_case() raises:
    var ed = Editor(String("Hello World"))
    ed.move_to(0, 0, False)
    ed.move_to(0, 5, True)         # select "Hello"
    ed.toggle_case()
    assert_equal(ed.buffer.line(0), String("hELLO World"))


fn test_editor_dirty_flag() raises:
    var ed = Editor(String("hello"))
    assert_false(ed.dirty)
    _ = ed.handle_key(_key(KEY_RIGHT), _VIEW)        # navigation, not dirty
    assert_false(ed.dirty)
    _ = ed.handle_key(_key(UInt32(ord("X"))), _VIEW)  # insert, dirty
    assert_true(ed.dirty)


fn test_file_io_read_and_stat() raises:
    """Check we can read & stat a file we know exists in the repo."""
    var path = String("examples/hello.mojo")
    var info = stat_file(path)
    assert_true(info.ok)
    assert_true(Int(info.size) > 0)
    var text = read_file(path)
    assert_equal(Int(info.size), len(text.as_bytes()))


fn test_editor_from_file() raises:
    var ed = Editor.from_file(String("examples/hello.mojo"))
    assert_true(ed.buffer.line_count() > 5)
    assert_false(ed.dirty)
    assert_true(Int(ed.file_size) > 0)
    # Initial check: nothing changed since open, so reload returns False.
    assert_false(ed.check_for_external_change())


fn test_terminal_parses_alt_letter_as_letter() raises:
    """``ESC <letter>`` parses as the letter with MOD_ALT — including 'f'
    and 'b'. The framework now uses these for menu mnemonics
    (Alt+F → File menu); word-jump still works via Ctrl+arrow and via
    Alt+arrow on terminals that report modifiers for arrows."""
    var alt_f = parse_input(String("\x1bf"))
    assert_true(alt_f[0].kind == EVENT_KEY)
    assert_equal(Int(alt_f[0].key), Int(ord("f")))
    assert_true((alt_f[0].mods & MOD_ALT) != 0)
    assert_equal(alt_f[1], 2)

    var alt_b = parse_input(String("\x1bb"))
    assert_equal(Int(alt_b[0].key), Int(ord("b")))
    assert_true((alt_b[0].mods & MOD_ALT) != 0)


fn test_editor_alt_arrow_word_jump() raises:
    """MOD_ALT triggers word movement (macOS convention)."""
    var ed = Editor(String("hello world foo"))
    _ = ed.handle_key(_key(KEY_RIGHT, MOD_ALT), _VIEW)
    assert_equal(ed.cursor_col, 6)
    _ = ed.handle_key(_key(KEY_RIGHT, MOD_ALT), _VIEW)
    assert_equal(ed.cursor_col, 12)
    _ = ed.handle_key(_key(KEY_LEFT, MOD_ALT), _VIEW)
    assert_equal(ed.cursor_col, 6)


fn test_path_helpers() raises:
    assert_equal(join_path(String("a"), String("b")), String("a/b"))
    assert_equal(join_path(String("a/"), String("b")), String("a/b"))
    assert_equal(join_path(String(""), String("b")), String("b"))
    assert_equal(parent_path(String("/foo/bar")), String("/foo"))
    assert_equal(parent_path(String("/")), String("/"))
    assert_equal(parent_path(String("foo")), String("."))


fn test_basename() raises:
    assert_equal(basename(String("/foo/bar")), String("bar"))
    assert_equal(basename(String("/foo/bar/")), String("bar"))
    assert_equal(basename(String("foo")), String("foo"))
    assert_equal(basename(String("/")), String("/"))


fn test_find_git_project() raises:
    """Tests run from the repo root, which has a .git folder, so opening
    a file inside the repo should locate the project root."""
    var root = find_git_project(String("examples/hello.mojo"))
    assert_true(root)
    # The project root contains examples/, src/, and .git.
    var info = stat_file(join_path(root.value(), String(".git")))
    assert_true(info.ok)
    var examples = stat_file(join_path(root.value(), String("examples")))
    assert_true(examples.ok)


fn _empty_menu(label: String) -> Menu:
    return Menu(label, List[MenuItem]())


fn test_menu_layout_pins_file_edit_window_help() raises:
    """Display order must always be File, Edit, [middle], Window, Help —
    regardless of insertion order. ``self.menus`` retains insertion order
    (so cached indices stay valid); only the layout rects reorder."""
    var bar = MenuBar()
    # Insert in deliberately scrambled order.
    bar.add(_empty_menu(String("Help")))
    bar.add(_empty_menu(String("Window")))
    bar.add(_empty_menu(String("Tools")))
    bar.add(_empty_menu(String("File")))
    bar.add(_empty_menu(String("Build")))
    bar.add(_empty_menu(String("Edit")))
    var rects = bar._layout(80)
    # Walk rects by display x; collect labels in order.
    var n = len(bar.menus)
    var sorted_labels = List[String]()
    var used = List[Bool]()
    for _ in range(n):
        used.append(False)
    for _ in range(n):
        var best = -1
        var best_x = 1_000_000
        for i in range(n):
            if used[i]: continue
            if rects[i].a.x < best_x and rects[i].b.x > rects[i].a.x:
                best_x = rects[i].a.x
                best = i
        if best < 0: break
        used[best] = True
        sorted_labels.append(bar.menus[best].label)
    assert_equal(len(sorted_labels), 6)
    assert_equal(sorted_labels[0], String("File"))
    assert_equal(sorted_labels[1], String("Edit"))
    # Middle two are Tools and Build in insertion order.
    assert_equal(sorted_labels[2], String("Tools"))
    assert_equal(sorted_labels[3], String("Build"))
    assert_equal(sorted_labels[4], String("Window"))
    assert_equal(sorted_labels[5], String("Help"))
    # The menus list itself must NOT be reordered (cached indices rely on it).
    assert_equal(bar.menus[0].label, String("Help"))
    assert_equal(bar.menus[5].label, String("Edit"))


fn test_right_aligned_menu_layout() raises:
    """A right-aligned menu sits flush with the screen's right edge, with
    its hit-test rect ending at exactly screen_width."""
    var bar = MenuBar()
    var left_items = List[MenuItem]()
    left_items.append(MenuItem(String("New"), String("noop")))
    bar.add(Menu(String("File"), left_items^))
    var right_items = List[MenuItem]()
    right_items.append(MenuItem(String("Close project"), PROJECT_CLOSE_ACTION))
    bar.add(Menu(String("mojovision"), right_items^, right_aligned=True))
    var rects = bar._layout(80)
    # Left menu starts at x=3 and gets " File "  (label + 2 padding).
    assert_equal(rects[0].a.x, 3)
    assert_equal(rects[0].b.x, 3 + len(String("File").as_bytes()) + 2)
    # Right-aligned menu's right edge is the screen width; width = label+2.
    assert_equal(rects[1].b.x, 80)
    var right_w = len(String("mojovision").as_bytes()) + 2
    assert_equal(rects[1].a.x, 80 - right_w)


fn test_desktop_project_lifecycle() raises:
    var d = Desktop()
    assert_false(d.project)
    d.detect_project_from(String("examples/hello.mojo"))
    assert_true(d.project)
    # Project menu is now in menu_bar.menus, right-aligned and visible.
    var idx = d._project_menu_idx
    assert_true(idx >= 0)
    assert_true(d.menu_bar.menus[idx].visible)
    assert_true(d.menu_bar.menus[idx].right_aligned)
    # Label is the project root's basename — for this repo, "mojovision".
    assert_equal(d.menu_bar.menus[idx].label, String("mojovision"))
    # The project menu starts with two items: tree-toggle and close.
    assert_equal(len(d.menu_bar.menus[idx].items), 2)
    assert_equal(d.menu_bar.menus[idx].items[0].action, PROJECT_TREE_ACTION)
    assert_equal(d.menu_bar.menus[idx].items[1].action, PROJECT_CLOSE_ACTION)
    # Detection is sticky: a second call doesn't reset the project.
    var first = d.project.value()
    d.detect_project_from(String("src/mojovision/desktop.mojo"))
    assert_equal(d.project.value(), first)
    # close_project clears state and hides the menu.
    d.close_project()
    assert_false(d.project)
    assert_false(d.menu_bar.menus[idx].visible)
    # After closing, detection works again.
    d.detect_project_from(String("examples/hello.mojo"))
    assert_true(d.project)
    assert_true(d.menu_bar.menus[idx].visible)


fn test_file_tree_expand_collapse() raises:
    var t = FileTree()
    t.open(String("."))   # repo root, contains examples/, src/, tests/, ...
    var initial_count = len(t.entries)
    assert_true(initial_count > 0)
    # Find a known directory ("examples") and expand it.
    var examples_idx = -1
    for i in range(len(t.entries)):
        if t.entries[i].name == String("examples") and t.entries[i].is_dir:
            examples_idx = i
            break
    assert_true(examples_idx >= 0)
    assert_false(t.entries[examples_idx].is_expanded)
    t._toggle_expand(examples_idx)
    assert_true(t.entries[examples_idx].is_expanded)
    assert_true(len(t.entries) > initial_count)
    # Children of examples/ have depth=1 and live right after the entry.
    assert_equal(t.entries[examples_idx + 1].depth, 1)
    # Collapse: list shrinks back to the initial count.
    t._toggle_expand(examples_idx)
    assert_false(t.entries[examples_idx].is_expanded)
    assert_equal(len(t.entries), initial_count)


fn test_file_tree_filters_dotfiles() raises:
    var t = FileTree()
    t.open(String("."))
    # Repo root contains a .git directory; it must not appear in entries.
    for i in range(len(t.entries)):
        var nbytes = t.entries[i].name.as_bytes()
        if len(nbytes) > 0:
            assert_true(Int(nbytes[0]) != 0x2E)


fn test_desktop_workspace_shrinks_with_file_tree() raises:
    var d = Desktop()
    var screen = Rect(0, 0, 100, 30)
    var ws_no_tree = d.workspace_rect(screen)
    assert_equal(ws_no_tree.b.x, 100)
    # Detect project, then toggle the tree on via the menu action handler.
    d.detect_project_from(String("examples/hello.mojo"))
    d._toggle_file_tree()
    assert_true(d.file_tree.visible)
    var ws_tree = d.workspace_rect(screen)
    assert_equal(ws_tree.b.x, 100 - FILE_TREE_WIDTH)
    # Tree-toggle item label should now read "Hide file tree".
    assert_equal(
        d.menu_bar.menus[d._project_menu_idx].items[0].label,
        String("Hide file tree"),
    )
    # Toggling again hides the tree and restores workspace + label.
    d._toggle_file_tree()
    assert_false(d.file_tree.visible)
    assert_equal(d.workspace_rect(screen).b.x, 100)
    assert_equal(
        d.menu_bar.menus[d._project_menu_idx].items[0].label,
        String("Show file tree"),
    )


fn test_window_manager_fit_into_moves_then_resizes() raises:
    """``fit_into`` prefers moving over resizing; resizes only when the window
    is wider/taller than the new workspace."""
    var wm = WindowManager()
    # Window that fits but is past the new right edge — should move left.
    wm.add(Window(String("A"), Rect(70, 5, 90, 15), List[String]()))
    # Window that's wider than the new workspace — should be resized.
    wm.add(Window(String("B"), Rect(5, 5, 95, 15), List[String]()))
    var smaller = Rect(0, 1, 80, 25)
    wm.fit_into(smaller)
    # A: 20 wide, fits in 80; expected to be slid left to (60, 80).
    assert_equal(wm.windows[0].rect.b.x, 80)
    assert_equal(wm.windows[0].rect.width(), 20)
    # B: was 90 wide; gets clipped to workspace width 80.
    assert_equal(wm.windows[1].rect.a.x, 0)
    assert_equal(wm.windows[1].rect.b.x, 80)
    assert_equal(wm.windows[1].rect.width(), 80)


fn _temp_path(suffix: String) -> String:
    """Cheap unique path under /tmp; pid+suffix is enough for our serial test
    suite (no parallelism)."""
    var pid = external_call["getpid", Int32]()
    return String("/tmp/mojovision_test_") + String(Int(pid)) + suffix


fn test_write_file_round_trip() raises:
    var path = _temp_path(String("_rt.txt"))
    var payload = String("line one\nline two\nno-trailing-newline")
    assert_true(write_file(path, payload))
    var got = read_file(path)
    assert_equal(got, payload)
    # Write a different payload — confirm it replaces, not appends.
    var smaller = String("x")
    assert_true(write_file(path, smaller))
    assert_equal(read_file(path), smaller)
    # Empty payload writes a zero-byte file.
    assert_true(write_file(path, String("")))
    assert_equal(read_file(path), String(""))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


fn test_editor_save_clears_dirty() raises:
    var path = _temp_path(String("_save.txt"))
    assert_true(write_file(path, String("hello\nworld\n")))
    var ed = Editor.from_file(path)
    assert_false(ed.dirty)
    _ = ed.handle_key(Event.key_event(KEY_END), _VIEW)
    _ = ed.handle_key(Event.key_event(UInt32(ord("!"))), _VIEW)
    assert_true(ed.dirty)
    assert_true(ed.save())
    assert_false(ed.dirty)
    var contents = read_file(path)
    # First line was "hello"; cursor moved to its end before typing '!'.
    var first_line = String(StringSlice(
        unsafe_from_utf8=contents.as_bytes()[:6],
    ))
    assert_equal(first_line, String("hello!"))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


fn test_editor_save_as_adopts_path() raises:
    var path = _temp_path(String("_saveas.txt"))
    var ed = Editor(String("alpha\nbeta\n"))
    assert_equal(ed.file_path, String(""))
    assert_true(ed.save_as(path))
    assert_equal(ed.file_path, path)
    assert_false(ed.dirty)
    assert_equal(read_file(path), String("alpha\nbeta\n"))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


fn test_editor_replace_all() raises:
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


fn test_walk_project_files_finds_known_files() raises:
    """The repo root has examples/, src/, tests/ — all should be reachable."""
    var root = find_git_project(String("examples/hello.mojo"))
    assert_true(root)
    var paths = walk_project_files(root.value())
    assert_true(len(paths) > 5)
    var saw_hello = False
    var saw_test = False
    var saw_dotfile = False
    for i in range(len(paths)):
        if _ends_with(paths[i], String("examples/hello.mojo")):
            saw_hello = True
        if _ends_with(paths[i], String("tests/test_basic.mojo")):
            saw_test = True
        # Anything under ``.git`` or ``.pixi`` would be a leak.
        if _contains(paths[i], String("/.git/")) \
                or _contains(paths[i], String("/.pixi/")):
            saw_dotfile = True
    assert_true(saw_hello)
    assert_true(saw_test)
    assert_false(saw_dotfile)


fn _ends_with(s: String, suffix: String) -> Bool:
    var sb = s.as_bytes()
    var fb = suffix.as_bytes()
    if len(fb) > len(sb):
        return False
    for i in range(len(fb)):
        if sb[len(sb) - len(fb) + i] != fb[i]:
            return False
    return True


fn _contains(s: String, sub: String) -> Bool:
    var sb = s.as_bytes()
    var nb = sub.as_bytes()
    var n = len(nb)
    var h = len(sb)
    if n == 0:
        return True
    if n > h:
        return False
    for i in range(h - n + 1):
        var hit = True
        for k in range(n):
            if sb[i + k] != nb[k]:
                hit = False
                break
        if hit:
            return True
    return False


fn test_find_in_project_locates_string() raises:
    """Search the repo for a string that's known to live in exactly one place."""
    var root = find_git_project(String("examples/hello.mojo"))
    assert_true(root)
    var matches = find_in_project(root.value(), String("Mojovision: a Mojo-idiomatic port"))
    assert_true(len(matches) >= 1)
    var found_in_init = False
    for i in range(len(matches)):
        if matches[i].rel == String("src/mojovision/__init__.mojo"):
            found_in_init = True
            assert_true(matches[i].line_no >= 1)
    assert_true(found_in_init)


fn test_desktop_dispatch_editor_save_passes_through_when_no_editor() raises:
    """Save with no editor focused should be a no-op intercepted by Desktop —
    the action does not bubble back to the caller."""
    var d = Desktop()
    var maybe = d.dispatch_action(EDITOR_SAVE, _SCREEN)
    assert_false(Bool(maybe))


fn test_desktop_dispatch_passes_through_unknown_actions() raises:
    var d = Desktop()
    var maybe = d.dispatch_action(String("focus:About"), _SCREEN)
    assert_true(Bool(maybe))
    assert_equal(maybe.value(), String("focus:About"))


fn test_desktop_dispatch_editor_save_writes_focused_editor() raises:
    var path = _temp_path(String("_dsave.txt"))
    assert_true(write_file(path, String("hello\n")))
    var d = Desktop()
    d.windows.add(Window.from_file(String("dsave.txt"), Rect(0, 1, 40, 12), path))
    # Mark dirty by appending a char.
    _ = d.windows.windows[0].editor.handle_key(
        Event.key_event(KEY_END), Rect(0, 1, 40, 12),
    )
    _ = d.windows.windows[0].editor.handle_key(
        Event.key_event(UInt32(ord("!"))), Rect(0, 1, 40, 12),
    )
    assert_true(d.windows.windows[0].editor.dirty)
    var maybe = d.dispatch_action(EDITOR_SAVE, _SCREEN)
    assert_false(Bool(maybe))
    assert_false(d.windows.windows[0].editor.dirty)
    assert_equal(read_file(path), String("hello!\n"))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


fn test_desktop_replace_chains_two_prompts() raises:
    var d = Desktop()
    d.windows.add(Window.editor_window(
        String("buf"), Rect(0, 1, 40, 12), String("foo bar foo\n"),
    ))
    # Click "Replace..." → first prompt opens for "find".
    _ = d.dispatch_action(EDITOR_REPLACE, _SCREEN)
    assert_true(d.prompt.active)
    # Submit "foo" — Desktop should immediately re-open the prompt for "replace".
    d.prompt.input = String("foo")
    d.prompt.submitted = True
    _ = d._on_prompt_submit()
    assert_true(d.prompt.active)   # second prompt is open
    # Submit "BAR" — the replacement actually happens now.
    d.prompt.input = String("BAR")
    d.prompt.submitted = True
    _ = d._on_prompt_submit()
    assert_false(d.prompt.active)
    assert_equal(d.windows.windows[0].editor.buffer.line(0), String("BAR bar BAR"))


fn test_desktop_open_file_uses_80_percent_size() raises:
    var path = _temp_path(String("_open80.txt"))
    assert_true(write_file(path, String("hello\n")))
    var d = Desktop()
    d.open_file(path, _SCREEN)
    var ws = d.workspace_rect(_SCREEN)
    assert_equal(d.windows.windows[0].rect.width(), (ws.width() * 80) // 100)
    assert_equal(d.windows.windows[0].rect.height(), (ws.height() * 80) // 100)
    # First open lands at the workspace origin (no cascade yet).
    assert_equal(d.windows.windows[0].rect.a.x, ws.a.x)
    assert_equal(d.windows.windows[0].rect.a.y, ws.a.y)
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


fn test_desktop_open_file_cascades_by_one() raises:
    var path = _temp_path(String("_cascade.txt"))
    assert_true(write_file(path, String("c\n")))
    var d = Desktop()
    d.open_file(path, _SCREEN)
    d.open_file(path, _SCREEN)
    d.open_file(path, _SCREEN)
    var ws = d.workspace_rect(_SCREEN)
    assert_equal(d.windows.windows[0].rect.a.x, ws.a.x + 0)
    assert_equal(d.windows.windows[0].rect.a.y, ws.a.y + 0)
    assert_equal(d.windows.windows[1].rect.a.x, ws.a.x + 1)
    assert_equal(d.windows.windows[1].rect.a.y, ws.a.y + 1)
    assert_equal(d.windows.windows[2].rect.a.x, ws.a.x + 2)
    assert_equal(d.windows.windows[2].rect.a.y, ws.a.y + 2)
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


fn test_desktop_open_file_inherits_maximize_state() raises:
    var path = _temp_path(String("_maxinh.txt"))
    assert_true(write_file(path, String("m\n")))
    var d = Desktop()
    d.open_file(path, _SCREEN)
    # Maximize the first window, then open a second.
    d.windows.windows[0].toggle_maximize(d.workspace_rect(_SCREEN))
    assert_true(d.windows.windows[0].is_maximized)
    d.open_file(path, _SCREEN)
    # The new window inherits maximized mode but its restore rect is the
    # 80% cascade slot (so toggling brings it back to the right size).
    assert_true(d.windows.windows[1].is_maximized)
    var ws = d.workspace_rect(_SCREEN)
    assert_true(d.windows.windows[1].rect == ws)
    assert_equal(
        d.windows.windows[1]._restore_rect.width(), (ws.width() * 80) // 100,
    )
    assert_equal(d.windows.windows[1]._restore_rect.a.x, ws.a.x + 1)
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


fn test_desktop_window_menu_lists_open_windows() raises:
    var d = Desktop()
    d.windows.add(Window(String("alpha"), Rect(0, 1, 20, 5), List[String]()))
    d.windows.add(Window(String("beta"),  Rect(0, 1, 20, 5), List[String]()))
    d._rebuild_window_menu()
    var menu = d.menu_bar.menus[d._window_menu_idx]
    # 2 window items + separator + Maximize all + Restore all = 5 items.
    assert_equal(len(menu.items), 5)
    assert_equal(menu.items[0].label, String("alpha"))
    assert_equal(menu.items[0].action, String("window:focus:0"))
    assert_equal(menu.items[1].label, String("beta"))
    assert_equal(menu.items[1].action, String("window:focus:1"))
    assert_true(menu.items[2].is_separator)
    assert_equal(menu.items[3].label, String("Maximize all"))
    assert_equal(menu.items[4].label, String("Restore all"))


fn test_desktop_window_menu_when_empty() raises:
    var d = Desktop()
    d._rebuild_window_menu()
    var menu = d.menu_bar.menus[d._window_menu_idx]
    # No windows: skip the separator, just show the bulk actions.
    assert_equal(len(menu.items), 2)
    assert_equal(menu.items[0].label, String("Maximize all"))
    assert_equal(menu.items[1].label, String("Restore all"))


fn test_desktop_window_focus_action_focuses_window() raises:
    var d = Desktop()
    d.windows.add(Window(String("a"), Rect(0, 1, 20, 5), List[String]()))
    d.windows.add(Window(String("b"), Rect(0, 1, 20, 5), List[String]()))
    d.windows.add(Window(String("c"), Rect(0, 1, 20, 5), List[String]()))
    # Focus the first window via the dynamic action string. The windows list
    # itself stays in insertion order (so menu bindings remain stable); only
    # ``focused`` and the z-order change.
    _ = d.dispatch_action(String("window:focus:0"), _SCREEN)
    assert_equal(d.windows.focused, 0)
    assert_equal(d.windows.windows[0].title, String("a"))
    assert_equal(d.windows.windows[1].title, String("b"))
    assert_equal(d.windows.windows[2].title, String("c"))
    # Focused window is at the top of z-order.
    assert_equal(d.windows.z_order[len(d.windows.z_order) - 1], 0)


fn test_desktop_maximize_all_and_restore_all() raises:
    var d = Desktop()
    d.windows.add(Window(String("a"), Rect(0, 1, 20, 5), List[String]()))
    d.windows.add(Window(String("b"), Rect(5, 6, 30, 12), List[String]()))
    var ws = d.workspace_rect(_SCREEN)
    _ = d.dispatch_action(String("window:maximize_all"), _SCREEN)
    for i in range(len(d.windows.windows)):
        assert_true(d.windows.windows[i].is_maximized)
        assert_true(d.windows.windows[i].rect == ws)
    _ = d.dispatch_action(String("window:restore_all"), _SCREEN)
    assert_false(d.windows.windows[0].is_maximized)
    assert_false(d.windows.windows[1].is_maximized)
    assert_true(d.windows.windows[0].rect == Rect(0, 1, 20, 5))
    assert_true(d.windows.windows[1].rect == Rect(5, 6, 30, 12))


fn test_desktop_project_find_requires_active_project() raises:
    var d = Desktop()
    # No project: dispatch is a no-op (prompt never opens).
    _ = d.dispatch_action(PROJECT_FIND, _SCREEN)
    assert_false(d.prompt.active)
    # With a project: prompt opens.
    d.detect_project_from(String("examples/hello.mojo"))
    _ = d.dispatch_action(PROJECT_FIND, _SCREEN)
    assert_true(d.prompt.active)


fn test_window_manager_close_focused() raises:
    var wm = WindowManager()
    wm.add(Window(String("a"), Rect(0, 1, 20, 5), List[String]()))
    wm.add(Window(String("b"), Rect(0, 1, 20, 5), List[String]()))
    wm.add(Window(String("c"), Rect(0, 1, 20, 5), List[String]()))
    assert_equal(wm.focused, 2)
    assert_true(wm.close_focused())
    assert_equal(len(wm.windows), 2)
    assert_equal(wm.focused, 1)
    # Close the remaining two; once empty, focused becomes -1 and the call
    # is a no-op on subsequent invocations.
    assert_true(wm.close_focused())
    assert_true(wm.close_focused())
    assert_false(wm.close_focused())
    assert_equal(wm.focused, -1)


fn test_ctrl_n_focuses_window_by_number() raises:
    """Ctrl+1..Ctrl+9 focus the corresponding window. The event has to
    arrive in the modifyOtherKeys form (mods=MOD_CTRL on a digit) since
    bare Ctrl+digit isn't representable as a control byte — but the
    parser already produces this form, and the hotkey table maps it to
    ``window:focus:N``. Crucially, ``windows`` itself stays in insertion
    order across focus changes so the bindings remain stable."""
    var d = Desktop()
    d.windows.add(Window(String("a"), Rect(0, 1, 20, 5), List[String]()))
    d.windows.add(Window(String("b"), Rect(0, 1, 20, 5), List[String]()))
    d.windows.add(Window(String("c"), Rect(0, 1, 20, 5), List[String]()))
    assert_equal(d.windows.windows[d.windows.focused].title, String("c"))
    _ = d.handle_event(Event.key_event(UInt32(ord("1")), MOD_CTRL), _SCREEN)
    assert_equal(d.windows.focused, 0)
    assert_equal(d.windows.windows[0].title, String("a"))
    # The list order MUST NOT change just because focus changed.
    assert_equal(d.windows.windows[1].title, String("b"))
    assert_equal(d.windows.windows[2].title, String("c"))
    # Ctrl+2 focuses index 1 (still "b" thanks to stable list order).
    _ = d.handle_event(Event.key_event(UInt32(ord("2")), MOD_CTRL), _SCREEN)
    assert_equal(d.windows.focused, 1)
    assert_equal(d.windows.windows[d.windows.focused].title, String("b"))


fn test_focus_changes_keep_window_list_order_stable() raises:
    """Repeated focus changes must not reshuffle ``windows``; only ``z_order``
    moves. This is what keeps Ctrl+N bindings (and the Window menu items)
    pointing at the same windows across rapid focus changes."""
    var wm = WindowManager()
    wm.add(Window(String("a"), Rect(0, 1, 20, 5), List[String]()))
    wm.add(Window(String("b"), Rect(0, 1, 20, 5), List[String]()))
    wm.add(Window(String("c"), Rect(0, 1, 20, 5), List[String]()))
    wm.focus_by_index(0)
    wm.focus_by_index(2)
    wm.focus_by_index(1)
    wm.focus_by_index(0)
    assert_equal(wm.windows[0].title, String("a"))
    assert_equal(wm.windows[1].title, String("b"))
    assert_equal(wm.windows[2].title, String("c"))
    # z-order tail is the most recently focused window.
    assert_equal(wm.z_order[len(wm.z_order) - 1], 0)


fn test_window_menu_items_show_ctrl_n_shortcut() raises:
    """The Window menu items (rebuilt every paint) carry the matching
    Ctrl+N shortcut for the first nine windows."""
    var d = Desktop()
    d.windows.add(Window(String("a"), Rect(0, 1, 20, 5), List[String]()))
    d.windows.add(Window(String("b"), Rect(0, 1, 20, 5), List[String]()))
    d._rebuild_window_menu()
    d._refresh_shortcuts()
    var menu = d.menu_bar.menus[d._window_menu_idx]
    assert_equal(menu.items[0].label, String("a"))
    assert_equal(menu.items[0].shortcut, String("Ctrl+1"))
    assert_equal(menu.items[1].label, String("b"))
    assert_equal(menu.items[1].shortcut, String("Ctrl+2"))


fn test_ctrl_w_closes_focused_window() raises:
    var d = Desktop()
    d.windows.add(Window.editor_window(
        String("first"), Rect(0, 1, 40, 12), String("hello\n"),
    ))
    d.windows.add(Window.editor_window(
        String("second"), Rect(0, 1, 40, 12), String("world\n"),
    ))
    assert_equal(len(d.windows.windows), 2)
    var ev = Event.key_event(ctrl_key(String("w")))
    var maybe = d.handle_event(ev, _SCREEN)
    assert_false(Bool(maybe))
    assert_equal(len(d.windows.windows), 1)
    assert_equal(d.windows.windows[0].title, String("first"))


fn test_format_hotkey_renders_combinations() raises:
    # Control-character form for plain Ctrl+letter.
    assert_equal(format_hotkey(ctrl_key(String("q")), MOD_NONE), String("Ctrl+Q"))
    assert_equal(format_hotkey(ctrl_key(String("s")), MOD_NONE), String("Ctrl+S"))
    # Modified-letter form for Ctrl+Shift combos.
    assert_equal(
        format_hotkey(UInt32(ord("f")), MOD_CTRL | MOD_SHIFT),
        String("Ctrl+Shift+F"),
    )
    # Special keys.
    assert_equal(format_hotkey(KEY_F5, MOD_NONE), String("F5"))
    assert_equal(format_hotkey(KEY_UP, MOD_SHIFT), String("Shift+Up"))


fn test_menu_items_get_shortcut_text_after_refresh() raises:
    """Once Desktop's _refresh_shortcuts runs, every menu item that maps to
    a registered hotkey has the matching shortcut string stamped onto it."""
    var d = Desktop()
    var items = List[MenuItem]()
    items.append(MenuItem(String("Save"),  EDITOR_SAVE))
    items.append(MenuItem(String("Quit"),  APP_QUIT_ACTION))
    items.append(MenuItem(String("Close"), WINDOW_CLOSE))
    items.append(MenuItem(String("New"),   String("noop")))
    d.menu_bar.add(Menu(String("File"), items^))
    d._refresh_shortcuts()
    var file_idx = -1
    for i in range(len(d.menu_bar.menus)):
        if d.menu_bar.menus[i].label == String("File"):
            file_idx = i
            break
    assert_true(file_idx >= 0)
    var fm = d.menu_bar.menus[file_idx]
    assert_equal(fm.items[0].shortcut, String("Ctrl+S"))
    assert_equal(fm.items[1].shortcut, String("Ctrl+Q"))
    assert_equal(fm.items[2].shortcut, String("Ctrl+W"))
    # Item with no registered hotkey: empty.
    assert_equal(fm.items[3].shortcut, String(""))


fn test_dropdown_widens_to_fit_shortcut() raises:
    """The dropdown rect must accommodate label + gap + shortcut; without
    the widening, ``Ctrl+Shift+F`` would overlap the menu item label."""
    var bar = MenuBar()
    var items = List[MenuItem]()
    var save = MenuItem(String("Save"), EDITOR_SAVE)
    save.shortcut = String("Ctrl+S")
    items.append(save)
    var pf = MenuItem(String("Find in project..."), PROJECT_FIND)
    pf.shortcut = String("Ctrl+Shift+F")
    items.append(pf)
    bar.add(Menu(String("Edit"), items^))
    bar.open_idx = 0
    var dr = bar._dropdown_rect(80)
    var widest_label = len(String("Find in project...").as_bytes())
    var widest_sc = len(String("Ctrl+Shift+F").as_bytes())
    # 2 (left pad) + label + 2 (gap) + shortcut + 2 (right pad)
    var expected_min_w = widest_label + widest_sc + 6
    assert_true(dr.b.x - dr.a.x >= expected_min_w)


fn test_parse_csi_modify_other_keys_normalizes_ctrl_q() raises:
    """``ESC[27;5;113~`` (xterm modifyOtherKeys=2 form for Ctrl+Q) parses
    to ``(0x11, MOD_NONE)`` — the same form we get on terminals that send
    Ctrl+Q as a bare control byte. Without this fix the parser dropped
    only ``ESC[27;5;`` and the trailing ``113~`` leaked into the editor."""
    var ev = parse_input(String("\x1b[27;5;113~"))
    assert_true(ev[0].kind == EVENT_KEY)
    assert_equal(Int(ev[0].key), 0x11)
    assert_equal(Int(ev[0].mods), Int(MOD_NONE))
    assert_equal(ev[1], len(String("\x1b[27;5;113~").as_bytes()))


fn test_parse_csi_modify_other_keys_ctrl_shift_f() raises:
    """``ESC[27;6;102~`` is Ctrl+Shift+F. Shift is preserved (so the
    project-find hotkey can match it); only plain Ctrl+letter is normalized."""
    var ev = parse_input(String("\x1b[27;6;102~"))
    assert_true(ev[0].kind == EVENT_KEY)
    assert_equal(Int(ev[0].key), Int(ord("f")))
    assert_true((ev[0].mods & MOD_CTRL) != 0)
    assert_true((ev[0].mods & MOD_SHIFT) != 0)


fn test_parse_csi_unknown_sequence_is_consumed_whole() raises:
    """Any unrecognized CSI sequence must be eaten in one bite — without
    that, trailing bytes (digits, ``~``) get re-parsed as printable keys
    and end up in the focused editor."""
    # Made-up sequence the parser doesn't recognize. ``end + 1`` must be
    # consumed regardless.
    var s = String("\x1b[99;42q")
    var ev = parse_input(s)
    assert_true(ev[0].kind == EVENT_NONE)
    assert_equal(ev[1], len(s.as_bytes()))


fn test_parse_csi_kitty_u_ctrl_letter() raises:
    """Kitty kbd protocol: ``CSI <cp> ; <mod> u``. ``ESC[113;5u`` (Ctrl+Q)
    parses with the same control-char normalization."""
    var ev = parse_input(String("\x1b[113;5u"))
    assert_true(ev[0].kind == EVENT_KEY)
    assert_equal(Int(ev[0].key), 0x11)
    assert_equal(Int(ev[0].mods), Int(MOD_NONE))


fn test_editor_rejects_modified_letter_typing() raises:
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


fn test_ctrl_q_modifyOtherKeys_triggers_quit_action() raises:
    """End-to-end: a Ctrl+Q event delivered as the modifyOtherKeys form
    is normalized by the parser and matched by the default Ctrl+Q hotkey.
    The Desktop returns APP_QUIT_ACTION; nothing is inserted into the
    focused editor."""
    var d = Desktop()
    d.windows.add(Window.editor_window(
        String("buf"), Rect(0, 1, 40, 12), String("hello\n"),
    ))
    # Synthesize what parse_input would produce for ESC[27;5;113~.
    var parsed = parse_input(String("\x1b[27;5;113~"))
    assert_true(parsed[0].kind == EVENT_KEY)
    var maybe = d.handle_event(parsed[0], _SCREEN)
    assert_true(Bool(maybe))
    assert_equal(maybe.value(), APP_QUIT_ACTION)
    # And the buffer is untouched — none of the trailing bytes leaked.
    assert_equal(d.windows.windows[0].editor.buffer.line(0), String("hello"))


fn test_ctrl_key_helper() raises:
    """``Ctrl+letter`` arrives as a control character on most terminals;
    ``ctrl_key`` produces the matching codepoint."""
    assert_equal(Int(ctrl_key(String("q"))), 0x11)
    assert_equal(Int(ctrl_key(String("Q"))), 0x11)
    assert_equal(Int(ctrl_key(String("a"))), 0x01)
    assert_equal(Int(ctrl_key(String("z"))), 0x1A)
    assert_equal(Int(ctrl_key(String("f"))), 0x06)


fn test_menu_keyboard_nav_arrows_and_enter() raises:
    """Up/Down step the dropdown selection (skipping separators), Left/Right
    rotate to the next visible menu, Enter triggers the selected item's
    action."""
    var d = Desktop()
    var file_items = List[MenuItem]()
    file_items.append(MenuItem(String("New"),  String("noop")))
    file_items.append(MenuItem.separator())
    file_items.append(MenuItem(String("Quit"), APP_QUIT_ACTION))
    d.menu_bar.add(Menu(String("File"), file_items^))
    var edit_items = List[MenuItem]()
    edit_items.append(MenuItem(String("Find..."), EDITOR_FIND))
    d.menu_bar.add(Menu(String("Edit"), edit_items^))
    # Open File via mnemonic; selection lands on the first non-separator.
    _ = d.handle_event(Event.key_event(UInt32(ord("f")), MOD_ALT), _SCREEN)
    var file_idx = -1
    var edit_idx = -1
    for i in range(len(d.menu_bar.menus)):
        if d.menu_bar.menus[i].label == String("File"):
            file_idx = i
        elif d.menu_bar.menus[i].label == String("Edit"):
            edit_idx = i
    assert_equal(d.menu_bar.open_idx, file_idx)
    assert_equal(d.menu_bar.selected_item, 0)   # New
    # Down skips the separator at index 1 → lands on Quit (index 2).
    _ = d.handle_event(Event.key_event(KEY_DOWN), _SCREEN)
    assert_equal(d.menu_bar.selected_item, 2)
    # Down wraps back to New (skipping the separator the long way).
    _ = d.handle_event(Event.key_event(KEY_DOWN), _SCREEN)
    assert_equal(d.menu_bar.selected_item, 0)
    # Right rotates to the Edit menu; selection resets.
    _ = d.handle_event(Event.key_event(KEY_RIGHT), _SCREEN)
    assert_equal(d.menu_bar.open_idx, edit_idx)
    assert_equal(d.menu_bar.selected_item, 0)
    # Left rotates back.
    _ = d.handle_event(Event.key_event(KEY_LEFT), _SCREEN)
    assert_equal(d.menu_bar.open_idx, file_idx)
    # Down to Quit, then Enter — the framework dispatches APP_QUIT_ACTION
    # back to the caller.
    _ = d.handle_event(Event.key_event(KEY_DOWN), _SCREEN)
    var maybe = d.handle_event(Event.key_event(KEY_ENTER), _SCREEN)
    assert_true(Bool(maybe))
    assert_equal(maybe.value(), APP_QUIT_ACTION)
    # Activating an item closes the menu.
    assert_false(d.menu_bar.is_open())


fn test_alt_letter_opens_menu_by_mnemonic() raises:
    """Alt+<letter> opens the first visible menu whose label starts with
    that letter (case-insensitive). The leading letter is what the menu
    bar paints in red as the mnemonic hint."""
    var d = Desktop()
    var file_items = List[MenuItem]()
    file_items.append(MenuItem(String("New"), String("noop")))
    d.menu_bar.add(Menu(String("File"), file_items^))
    var edit_items = List[MenuItem]()
    edit_items.append(MenuItem(String("Find..."), EDITOR_FIND))
    d.menu_bar.add(Menu(String("Edit"), edit_items^))
    # Alt+F opens File.
    _ = d.handle_event(Event.key_event(UInt32(ord("f")), MOD_ALT), _SCREEN)
    var file_idx = -1
    var edit_idx = -1
    for i in range(len(d.menu_bar.menus)):
        if d.menu_bar.menus[i].label == String("File"):
            file_idx = i
        elif d.menu_bar.menus[i].label == String("Edit"):
            edit_idx = i
    assert_equal(d.menu_bar.open_idx, file_idx)
    # Alt+E switches to Edit.
    _ = d.handle_event(Event.key_event(UInt32(ord("e")), MOD_ALT), _SCREEN)
    assert_equal(d.menu_bar.open_idx, edit_idx)
    # Uppercase works too.
    d.menu_bar.close()
    _ = d.handle_event(Event.key_event(UInt32(ord("F")), MOD_ALT), _SCREEN)
    assert_equal(d.menu_bar.open_idx, file_idx)
    # No matching letter → no-op (menu stays closed).
    d.menu_bar.close()
    _ = d.handle_event(Event.key_event(UInt32(ord("z")), MOD_ALT), _SCREEN)
    assert_false(d.menu_bar.is_open())


fn test_esc_prefix_opens_menu_by_mnemonic() raises:
    """Classic TV / DOS-style two-key sequence: ESC, then a letter, opens
    the matching menu. Lets users on macOS terminals (where Option+F is
    intercepted by the OS) still reach the mnemonic without reconfiguring
    their terminal."""
    var d = Desktop()
    var file_items = List[MenuItem]()
    file_items.append(MenuItem(String("New"), String("noop")))
    d.menu_bar.add(Menu(String("File"), file_items^))
    # First press: ESC alone. No menu opens; no action bubbles up.
    var maybe1 = d.handle_event(Event.key_event(KEY_ESC), _SCREEN)
    assert_false(Bool(maybe1))
    assert_false(d.menu_bar.is_open())
    # Second press: F. The framework picks it up as a mnemonic.
    var maybe2 = d.handle_event(
        Event.key_event(UInt32(ord("f"))), _SCREEN,
    )
    assert_false(Bool(maybe2))
    assert_true(d.menu_bar.is_open())
    var file_idx = -1
    for i in range(len(d.menu_bar.menus)):
        if d.menu_bar.menus[i].label == String("File"):
            file_idx = i
    assert_equal(d.menu_bar.open_idx, file_idx)


fn test_esc_prefix_disarms_after_one_keystroke() raises:
    """A non-letter (or unmatched letter) following ESC must disarm the
    prefix; the third keystroke is plain again."""
    var d = Desktop()
    var file_items = List[MenuItem]()
    file_items.append(MenuItem(String("New"), String("noop")))
    d.menu_bar.add(Menu(String("File"), file_items^))
    d.windows.add(Window.editor_window(
        String("buf"), Rect(0, 1, 40, 12), String(""),
    ))
    _ = d.handle_event(Event.key_event(KEY_ESC), _SCREEN)
    # No menu starts with 'z' — the keystroke disarms but doesn't open.
    _ = d.handle_event(Event.key_event(UInt32(ord("z"))), _SCREEN)
    assert_false(d.menu_bar.is_open())
    # Now type 'f' — it should reach the editor as plain typing, not the
    # mnemonic, because the previous keystroke disarmed the prefix.
    _ = d.handle_event(Event.key_event(UInt32(ord("f"))), _SCREEN)
    assert_false(d.menu_bar.is_open())
    assert_equal(d.windows.windows[0].editor.buffer.line(0), String("zf"))


fn test_top_level_esc_does_not_quit() raises:
    """Top-level ESC must not bubble up an action — quit is reserved for
    explicit bindings (Ctrl+Q etc.). It still closes a modal layer when
    one is open."""
    var d = Desktop()
    var maybe = d.handle_event(Event.key_event(KEY_ESC), _SCREEN)
    assert_false(Bool(maybe))
    # ESC closes an open menu but still doesn't bubble.
    d.menu_bar.add(Menu(String("File"), List[MenuItem]()))
    d.menu_bar.open_idx = 0
    assert_true(d.menu_bar.is_open())
    var maybe2 = d.handle_event(Event.key_event(KEY_ESC), _SCREEN)
    assert_false(Bool(maybe2))
    assert_false(d.menu_bar.is_open())


fn test_default_hotkey_ctrl_q_returns_quit() raises:
    var d = Desktop()
    var ev = Event.key_event(ctrl_key(String("q")))
    var maybe = d.handle_event(ev, _SCREEN)
    assert_true(Bool(maybe))
    assert_equal(maybe.value(), APP_QUIT_ACTION)


fn test_default_hotkey_ctrl_f_opens_find_prompt() raises:
    var d = Desktop()
    d.windows.add(Window.editor_window(
        String("buf"), Rect(0, 1, 40, 12), String("hello\n"),
    ))
    assert_false(d.prompt.active)
    var ev = Event.key_event(ctrl_key(String("f")))
    var maybe = d.handle_event(ev, _SCREEN)
    # Framework intercepted the hotkey; nothing for the caller to dispatch.
    assert_false(Bool(maybe))
    assert_true(d.prompt.active)


fn test_default_hotkey_ctrl_s_saves_focused_editor() raises:
    var path = _temp_path(String("_hkeys.txt"))
    assert_true(write_file(path, String("hello\n")))
    var d = Desktop()
    d.windows.add(Window.from_file(String("hk"), Rect(0, 1, 40, 12), path))
    _ = d.windows.windows[0].editor.handle_key(
        Event.key_event(KEY_END), Rect(0, 1, 40, 12),
    )
    _ = d.windows.windows[0].editor.handle_key(
        Event.key_event(UInt32(ord("!"))), Rect(0, 1, 40, 12),
    )
    assert_true(d.windows.windows[0].editor.dirty)
    var ev = Event.key_event(ctrl_key(String("s")))
    _ = d.handle_event(ev, _SCREEN)
    assert_false(d.windows.windows[0].editor.dirty)
    assert_equal(read_file(path), String("hello!\n"))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


fn test_hotkey_overrides_default_when_registered_later() raises:
    """Registrations are scanned newest-first, so a later-registered binding
    for the same key/mods pair wins."""
    var d = Desktop()
    # Bind Ctrl+Q to a custom app action; the default (APP_QUIT_ACTION)
    # should no longer fire.
    d.register_hotkey(ctrl_key(String("q")), MOD_NONE, String("custom:thing"))
    var ev = Event.key_event(ctrl_key(String("q")))
    var maybe = d.handle_event(ev, _SCREEN)
    assert_true(Bool(maybe))
    assert_equal(maybe.value(), String("custom:thing"))


fn test_hotkey_does_not_fire_while_prompt_active() raises:
    """Prompt modal keys must reach the prompt, not the hotkey table."""
    var d = Desktop()
    d.prompt.open(String("Find: "))
    # Without the modal-prompt guard, Ctrl+Q here would return APP_QUIT.
    var ev = Event.key_event(ctrl_key(String("q")))
    var maybe = d.handle_event(ev, _SCREEN)
    assert_false(Bool(maybe))
    assert_true(d.prompt.active)


fn test_gitignore_matches_directory_pattern() raises:
    var m = GitignoreMatcher.from_text(String("tvision/\n"))
    assert_true(m.ignored(String("tvision"), True))
    assert_false(m.ignored(String("tvision"), False))   # dir-only pattern
    assert_true(m.ignored(String("nested/tvision"), True))
    assert_false(m.ignored(String("examples"), True))


fn test_gitignore_matches_glob_and_negate() raises:
    var m = GitignoreMatcher.from_text(
        String("# build artefacts\n*.o\n!keep.o\nbuild/\n")
    )
    assert_true(m.ignored(String("foo.o"), False))
    assert_true(m.ignored(String("a/b/c.o"), False))
    # The negation must override the earlier pattern.
    assert_false(m.ignored(String("keep.o"), False))
    assert_true(m.ignored(String("build"), True))
    assert_false(m.ignored(String("hello.mojo"), False))


fn test_walk_project_files_respects_gitignore() raises:
    """The repo's .gitignore lists ``tvision/`` — that subtree must be
    excluded from the default walk, but visible when explicitly opted out."""
    var root = find_git_project(String("examples/hello.mojo"))
    assert_true(root)
    var paths = walk_project_files(root.value())
    var saw_tvision = False
    for i in range(len(paths)):
        if _contains(paths[i], String("/tvision/")):
            saw_tvision = True
            break
    assert_false(saw_tvision)
    # Without gitignore respect, the walk reaches into tvision/.
    var all_paths = walk_project_files(root.value(), respect_gitignore=False)
    var any_tvision = False
    for i in range(len(all_paths)):
        if _contains(all_paths[i], String("/tvision/")):
            any_tvision = True
            break
    assert_true(any_tvision)


fn _hl_lines(*texts: String) -> List[String]:
    var out = List[String]()
    for t in texts:
        out.append(String(t))
    return out^


fn test_extension_of_helper() raises:
    assert_equal(extension_of(String("foo.mojo")), String("mojo"))
    assert_equal(extension_of(String("a/b/foo.MOJO")), String("mojo"))
    assert_equal(extension_of(String("Makefile")), String(""))
    assert_equal(extension_of(String("a.b/c")), String(""))   # dot before /
    assert_equal(extension_of(String("")), String(""))


fn test_word_at_helper() raises:
    assert_equal(word_at(String("foo bar"), 0), String("foo"))
    assert_equal(word_at(String("foo bar"), 2), String("foo"))
    assert_equal(word_at(String("foo bar"), 4), String("bar"))
    assert_equal(word_at(String("foo bar"), 3), String(""))   # space, not ident
    assert_equal(word_at(String("snake_case"), 5), String("snake_case"))


fn test_highlight_for_extension_recognizes_mojo() raises:
    """``fn``/``var`` are keywords, ``"hello"`` is a string, ``# note`` is a
    comment, ``42`` is a number — each gets its own attr."""
    var lines = _hl_lines(
        String("fn main() raises:"),
        String("    var s = \"hello\"  # note"),
        String("    var n = 42"),
    )
    var hls = highlight_for_extension(String("mojo"), lines)
    var saw_keyword_fn = False
    var saw_keyword_var = False
    var saw_keyword_raises = False
    var saw_string = False
    var saw_comment = False
    var saw_number = False
    for i in range(len(hls)):
        var h = hls[i]
        var kind_attr = h.attr
        if h.row == 0 and h.col_start == 0 and h.col_end == 2 \
                and kind_attr == highlight_keyword_attr():
            saw_keyword_fn = True
        if h.row == 0 and kind_attr == highlight_keyword_attr() \
                and h.col_start == 10 and h.col_end == 16:
            saw_keyword_raises = True
        if h.row == 1 and h.col_start == 4 and h.col_end == 7 \
                and kind_attr == highlight_keyword_attr():
            saw_keyword_var = True
        if h.row == 1 and kind_attr == highlight_string_attr():
            saw_string = True
        if h.row == 1 and kind_attr == highlight_comment_attr():
            saw_comment = True
        if h.row == 2 and kind_attr == highlight_number_attr():
            saw_number = True
    assert_true(saw_keyword_fn)
    assert_true(saw_keyword_var)
    assert_true(saw_keyword_raises)
    assert_true(saw_string)
    assert_true(saw_comment)
    assert_true(saw_number)


fn test_highlight_triple_quoted_string_spans_lines() raises:
    """Multi-line triple-quoted strings keep highlight state across rows."""
    var lines = _hl_lines(
        String("\"\"\"docstring start"),
        String("middle line"),
        String("end of docstring\"\"\""),
        String("var x = 1"),
    )
    var hls = highlight_for_extension(String("py"), lines)
    var have_row_0 = False
    var have_row_1 = False
    var have_row_2 = False
    for i in range(len(hls)):
        if hls[i].attr == highlight_string_attr():
            if hls[i].row == 0: have_row_0 = True
            if hls[i].row == 1: have_row_1 = True
            if hls[i].row == 2: have_row_2 = True
    assert_true(have_row_0)
    assert_true(have_row_1)
    assert_true(have_row_2)
    # Row 3 (``var x = 1``) must come back to plain code: ``var`` keyword,
    # ``1`` number — not all-string.
    var saw_kw = False
    for i in range(len(hls)):
        if hls[i].row == 3 and hls[i].attr == highlight_keyword_attr():
            saw_kw = True
    assert_true(saw_kw)


fn test_highlight_unknown_extension_returns_empty() raises:
    var lines = _hl_lines(String("fn main():"), String("  pass"))
    var hls = highlight_for_extension(String("txt"), lines)
    assert_equal(len(hls), 0)


fn test_editor_refreshes_highlights_after_edits() raises:
    """Newly typed text gets re-tokenized: typing ``fn`` produces a keyword
    highlight that wasn't there a moment ago."""
    var path = _temp_path(String("_hl.mojo"))
    assert_true(write_file(path, String("\n")))
    var ed = Editor.from_file(path)
    assert_true(len(ed.highlights) == 0)
    _ = ed.handle_key(_key(UInt32(ord("f"))), _VIEW)
    _ = ed.handle_key(_key(UInt32(ord("n"))), _VIEW)
    var saw_fn_keyword = False
    for i in range(len(ed.highlights)):
        var h = ed.highlights[i]
        if h.row == 0 and h.col_start == 0 and h.col_end == 2 \
                and h.attr == highlight_keyword_attr():
            saw_fn_keyword = True
    assert_true(saw_fn_keyword)
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


fn test_editor_paint_overlays_highlight_attr() raises:
    """The highlight attr lands on the right cells in the canvas after
    ``editor.paint``."""
    var path = _temp_path(String("_hlpaint.mojo"))
    assert_true(write_file(path, String("fn main():\n")))
    var ed = Editor.from_file(path)
    var canvas = Canvas(40, 5)
    canvas.fill(Rect(0, 0, 40, 5), String(" "), default_attr())
    ed.paint(canvas, Rect(0, 0, 40, 5), False)
    # ``fn`` lives at columns 0–1 with the keyword attr.
    assert_true(canvas.get(0, 0).attr == highlight_keyword_attr())
    assert_true(canvas.get(1, 0).attr == highlight_keyword_attr())
    # The space and the ``main`` identifier aren't keywords.
    assert_false(canvas.get(2, 0).attr == highlight_keyword_attr())
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


fn test_editor_ctrl_click_emits_definition_request() raises:
    var ed = Editor(String("foo bar baz"))
    var ev = Event.mouse_event(
        Point(4, 0), MOUSE_BUTTON_LEFT,
        pressed=True, motion=False, mods=MOD_CTRL,
    )
    _ = ed.handle_mouse(ev, Rect(0, 0, 40, 5))
    var req = ed.consume_definition_request()
    assert_true(Bool(req))
    var dr = req.value()
    assert_equal(dr.row, 0)
    assert_equal(dr.col, 4)
    assert_equal(dr.word, String("bar"))
    # The cursor must NOT have moved (Ctrl+click is non-mutating).
    assert_equal(ed.cursor_col, 0)
    # And the slot is consumed: a second poll returns empty.
    var req2 = ed.consume_definition_request()
    assert_false(Bool(req2))


fn test_editor_ctrl_click_outside_identifier_is_silent() raises:
    var ed = Editor(String("foo  bar"))
    # Click on the space between words.
    var ev = Event.mouse_event(
        Point(3, 0), MOUSE_BUTTON_LEFT,
        pressed=True, motion=False, mods=MOD_CTRL,
    )
    _ = ed.handle_mouse(ev, Rect(0, 0, 40, 5))
    var req = ed.consume_definition_request()
    assert_false(Bool(req))


fn test_quick_open_match_rules() raises:
    """Locked-in spec: each token is a case-insensitive subsequence;
    first token matches anywhere, later tokens require a word boundary.
    Word boundaries: start, after non-alnum, lowercase→uppercase split."""
    var path = String("src/mojovision/cell.mojo")
    # Single token with a literal slash — subsequence match.
    assert_true(quick_open_match(path, String("j/c")))
    # Two tokens — j anywhere, c at a word boundary.
    assert_true(quick_open_match(path, String("j c")))
    # Subsequence within a token: j (in mojovision) → / → m (in .mojo).
    assert_true(quick_open_match(path, String("j/m")))
    # No / after the m in .mojo, so this can't match.
    assert_false(quick_open_match(path, String("jm/")))

    # Multi-token across other shapes:
    assert_true(quick_open_match(String("job_call"),  String("j c")))
    assert_true(quick_open_match(String("jobCall"),   String("j c")))
    # The c in "jack" isn't preceded by a word boundary.
    assert_false(quick_open_match(String("jack"),     String("j c")))

    # Empty query matches everything; tokens must keep their order.
    assert_true(quick_open_match(path, String("")))
    assert_false(quick_open_match(String("cell mojo"), String("mojo cell")))


fn test_quick_open_match_word_boundary_kinds() raises:
    # camelCase split — uppercase after lowercase counts as a boundary.
    assert_true(quick_open_match(String("HelloWorld"), String("h w")))
    # Leading uppercase counts as start-of-string boundary.
    assert_true(quick_open_match(String("Helloworld"), String("h")))
    # Embedded non-alnum — boundary right after.
    assert_true(quick_open_match(String("foo-bar.baz"), String("f b b")))
    # Path-segment boundaries via slashes.
    assert_true(quick_open_match(String("a/b/c"), String("a b c")))


fn test_quick_open_filters_as_you_type() raises:
    var root = find_git_project(String("examples/hello.mojo"))
    assert_true(root)
    var qo = QuickOpen()
    qo.open(root.value())
    assert_true(qo.active)
    var initial_count = len(qo.matched)
    assert_true(initial_count > 5)
    # Typing narrows the match list.
    qo.query = String("editor")
    qo._refilter()
    assert_true(len(qo.matched) > 0)
    assert_true(len(qo.matched) < initial_count)
    var found_editor_module = False
    for i in range(len(qo.matched)):
        if qo.entries[qo.matched[i]] == String("src/mojovision/editor.mojo"):
            found_editor_module = True
            break
    assert_true(found_editor_module)
    # Submission produces an absolute path joined with root.
    qo.selected_path = join_path(qo.root, qo.entries[qo.matched[0]])
    qo.submitted = True
    assert_true(_starts_with(qo.selected_path, root.value()))


fn _starts_with(s: String, prefix: String) -> Bool:
    var sb = s.as_bytes()
    var pb = prefix.as_bytes()
    if len(pb) > len(sb):
        return False
    for i in range(len(pb)):
        if sb[i] != pb[i]:
            return False
    return True


fn test_ctrl_o_opens_quick_open_when_project_active() raises:
    var d = Desktop()
    d.detect_project_from(String("examples/hello.mojo"))
    var ev = Event.key_event(ctrl_key(String("o")))
    var maybe = d.handle_event(ev, _SCREEN)
    assert_false(Bool(maybe))
    assert_true(d.quick_open.active)


fn test_ctrl_o_bubbles_when_no_project() raises:
    var d = Desktop()
    var ev = Event.key_event(ctrl_key(String("o")))
    var maybe = d.handle_event(ev, _SCREEN)
    assert_true(Bool(maybe))
    assert_equal(maybe.value(), EDITOR_QUICK_OPEN)
    assert_false(d.quick_open.active)


fn test_replace_in_project_round_trip() raises:
    """Set up a tiny scratch tree, replace across it, verify writes."""
    var root = _temp_path(String("_proj"))
    _ = external_call["mkdir", Int32]((root + String("\0")).unsafe_ptr(), Int32(0o755))
    var a = join_path(root, String("a.txt"))
    var b = join_path(root, String("b.txt"))
    assert_true(write_file(a, String("alpha foo gamma\n")))
    assert_true(write_file(b, String("foo foo\nno match\n")))
    var summary = replace_in_project(root, String("foo"), String("BAR"))
    assert_equal(summary[0], 2)   # both files changed
    assert_equal(summary[1], 3)   # 1 + 2 replacements
    assert_equal(read_file(a), String("alpha BAR gamma\n"))
    assert_equal(read_file(b), String("BAR BAR\nno match\n"))
    _ = external_call["unlink", Int32]((a + String("\0")).unsafe_ptr())
    _ = external_call["unlink", Int32]((b + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((root + String("\0")).unsafe_ptr())


fn test_window_manager_fit_into_keeps_maximized_pinned() raises:
    var wm = WindowManager()
    var w = Window(String("M"), Rect(0, 1, 100, 25), List[String]())
    w.is_maximized = True
    wm.add(w^)
    var smaller = Rect(0, 1, 60, 20)
    wm.fit_into(smaller)
    assert_true(wm.windows[0].rect == smaller)


fn test_file_dialog_lists_and_navigates() raises:
    var dlg = FileDialog()
    dlg.open(String("examples"))
    assert_true(dlg.active)
    # Should have at least ".." and a few example files.
    assert_true(len(dlg.entries) >= 2)
    assert_equal(dlg.entries[0], String(".."))
    # Navigate to second entry; arrow event-driven.
    _ = dlg.handle_key(Event.key_event(KEY_DOWN))
    assert_equal(dlg.selected, 1)
    _ = dlg.handle_key(Event.key_event(KEY_UP))
    assert_equal(dlg.selected, 0)


fn test_partial_sgr_mouse_does_not_emit_esc() raises:
    """A scroll-wheel event split across two reads must NOT emit KEY_ESC —
    that would make every quit-on-Esc app exit at random when scrolling.

    Partial sequences return ``(EVENT_NONE, 0)`` so Terminal.poll_event saves
    the tail as pending bytes and prepends them to the next read.
    """
    var partial = parse_input(String("\x1b[<64;15;5"))   # missing terminator
    assert_true(partial[0].kind == EVENT_NONE)
    assert_equal(partial[1], 0)

    # Partial CSI prefix — same convention.
    var just_csi = parse_input(String("\x1b["))
    assert_true(just_csi[0].kind == EVENT_NONE)
    assert_equal(just_csi[1], 0)

    # Partial SS3 prefix (some terminals emit ESC O <P|Q|R|S> for F1..F4).
    var just_ss3 = parse_input(String("\x1bO"))
    assert_true(just_ss3[0].kind == EVENT_NONE)
    assert_equal(just_ss3[1], 0)

    # Partial CSI mid digit-run (ESC[5 with no terminator yet).
    var partial_tilde = parse_input(String("\x1b[5"))
    assert_true(partial_tilde[0].kind == EVENT_NONE)
    assert_equal(partial_tilde[1], 0)

    # Partial CSI mid modified-key sequence.
    var partial_mod = parse_input(String("\x1b[1;5"))
    assert_true(partial_mod[0].kind == EVENT_NONE)
    assert_equal(partial_mod[1], 0)


fn test_sgr_mouse_wheel_up() raises:
    var ev = parse_input(String("\x1b[<64;15;5M"))
    assert_true(ev[0].kind == EVENT_MOUSE)
    assert_true(ev[0].button == MOUSE_WHEEL_UP)


fn test_file_dialog_selects_a_file() raises:
    var dlg = FileDialog()
    dlg.open(String("examples"))
    # Find hello.mojo in the listing and step to it.
    var target = -1
    for i in range(len(dlg.entries)):
        if dlg.entries[i] == String("hello.mojo"):
            target = i
            break
    assert_true(target > 0)
    while dlg.selected < target:
        _ = dlg.handle_key(Event.key_event(KEY_DOWN))
    _ = dlg.handle_key(Event.key_event(KEY_ENTER))
    assert_true(dlg.submitted)
    assert_equal(dlg.selected_path, String("examples/hello.mojo"))


fn test_file_dialog_mouse_click_selects() raises:
    var dlg = FileDialog()
    dlg.open(String("examples"))
    var screen = Rect(0, 0, 80, 24)
    # Geometry: width=60, height=18, x=10, y=3 → list_top=6.
    # Clicking row 7 (in-screen) maps to entry index = 0 + (7 - 6) = 1.
    _ = dlg.handle_mouse(
        Event.mouse_event(Point(20, 7), MOUSE_BUTTON_LEFT, True, False),
        screen,
    )
    assert_equal(dlg.selected, 1)
    assert_false(dlg.submitted)


fn test_file_dialog_double_click_opens() raises:
    var dlg = FileDialog()
    dlg.open(String("examples"))
    # Find hello.mojo, then click it twice.
    var target = -1
    for i in range(len(dlg.entries)):
        if dlg.entries[i] == String("hello.mojo"):
            target = i
            break
    assert_true(target > 0)
    var screen = Rect(0, 0, 80, 24)
    var list_top = 6
    var visible_y = list_top + (target - dlg.scroll)
    _ = dlg.handle_mouse(
        Event.mouse_event(Point(20, visible_y), MOUSE_BUTTON_LEFT, True, False),
        screen,
    )
    assert_equal(dlg.selected, target)
    assert_false(dlg.submitted)
    _ = dlg.handle_mouse(
        Event.mouse_event(Point(20, visible_y), MOUSE_BUTTON_LEFT, True, False),
        screen,
    )
    assert_true(dlg.submitted)
    assert_equal(dlg.selected_path, String("examples/hello.mojo"))


fn test_file_dialog_wheel_scrolls() raises:
    var dlg = FileDialog()
    dlg.open(String("examples"))
    var screen = Rect(0, 0, 80, 24)
    var initial = dlg.scroll
    # Wheel down a few times.
    _ = dlg.handle_mouse(
        Event.mouse_event(Point(20, 10), MOUSE_WHEEL_DOWN, True, False),
        screen,
    )
    # If there are more entries than the visible window, scroll moves; else stays.
    if len(dlg.entries) > 13:
        assert_true(dlg.scroll > initial)
    # Wheel up resets toward 0.
    _ = dlg.handle_mouse(
        Event.mouse_event(Point(20, 10), MOUSE_WHEEL_UP, True, False),
        screen,
    )
    assert_true(dlg.scroll <= initial + 3)


fn test_editor_sticky_col_down_through_short_line() raises:
    """Down-arrowing from a wide line through a short one and back to a wider
    one returns the cursor to the original column."""
    var ed = Editor(String("hello world\nab\nabcdefghij"))
    _ = ed.handle_key(_key(KEY_END), _VIEW)
    assert_equal(ed.cursor_row, 0)
    assert_equal(ed.cursor_col, 11)
    assert_equal(ed.desired_col, 11)
    _ = ed.handle_key(_key(KEY_DOWN), _VIEW)
    # Line 1 ("ab") is 2 chars: cursor clamps but desired_col is preserved.
    assert_equal(ed.cursor_row, 1)
    assert_equal(ed.cursor_col, 2)
    assert_equal(ed.desired_col, 11)
    _ = ed.handle_key(_key(KEY_DOWN), _VIEW)
    # Line 2 is 10 chars: cursor lands at min(11, 10) = 10. Desired untouched.
    assert_equal(ed.cursor_row, 2)
    assert_equal(ed.cursor_col, 10)
    assert_equal(ed.desired_col, 11)


fn test_editor_sticky_col_up_through_short_line() raises:
    var ed = Editor(String("hello world\nab\nabcdefghij"))
    _ = ed.handle_key(_key(KEY_DOWN), _VIEW)
    _ = ed.handle_key(_key(KEY_DOWN), _VIEW)
    _ = ed.handle_key(_key(KEY_END), _VIEW)
    assert_equal(ed.cursor_row, 2)
    assert_equal(ed.cursor_col, 10)
    assert_equal(ed.desired_col, 10)
    _ = ed.handle_key(_key(KEY_UP), _VIEW)
    assert_equal(ed.cursor_row, 1)
    assert_equal(ed.cursor_col, 2)
    assert_equal(ed.desired_col, 10)
    _ = ed.handle_key(_key(KEY_UP), _VIEW)
    assert_equal(ed.cursor_row, 0)
    assert_equal(ed.cursor_col, 10)
    assert_equal(ed.desired_col, 10)


fn test_editor_sticky_col_reset_by_left_arrow() raises:
    var ed = Editor(String("hello world\nab\nabcdefghij"))
    _ = ed.handle_key(_key(KEY_END), _VIEW)
    _ = ed.handle_key(_key(KEY_DOWN), _VIEW)
    assert_equal(ed.desired_col, 11)
    _ = ed.handle_key(_key(KEY_LEFT), _VIEW)
    # Horizontal move resets the remembered column to wherever we end up.
    assert_equal(ed.cursor_col, 1)
    assert_equal(ed.desired_col, 1)
    _ = ed.handle_key(_key(KEY_DOWN), _VIEW)
    assert_equal(ed.cursor_row, 2)
    assert_equal(ed.cursor_col, 1)


fn test_editor_sticky_col_reset_by_right_arrow() raises:
    var ed = Editor(String("hello world\nab\nabcdefghij"))
    _ = ed.handle_key(_key(KEY_END), _VIEW)
    _ = ed.handle_key(_key(KEY_DOWN), _VIEW)
    # cursor (1, 2), desired 11. Right at end of line moves to start of next.
    _ = ed.handle_key(_key(KEY_RIGHT), _VIEW)
    assert_equal(ed.cursor_row, 2)
    assert_equal(ed.cursor_col, 0)
    assert_equal(ed.desired_col, 0)


fn test_editor_sticky_col_reset_by_typing() raises:
    var ed = Editor(String("hello world\nab"))
    _ = ed.handle_key(_key(KEY_END), _VIEW)
    _ = ed.handle_key(_key(KEY_DOWN), _VIEW)
    assert_equal(ed.desired_col, 11)
    _ = ed.handle_key(_key(UInt32(ord("X"))), _VIEW)
    assert_equal(ed.cursor_col, 3)
    assert_equal(ed.desired_col, 3)


fn test_editor_sticky_col_reset_by_click() raises:
    var ed = Editor(String("hello world\nabcdefghij"))
    _ = ed.handle_key(_key(KEY_END), _VIEW)
    assert_equal(ed.desired_col, 11)
    var view = Rect(0, 0, 40, 10)
    _ = ed.handle_mouse(
        Event.mouse_event(Point(3, 0), MOUSE_BUTTON_LEFT, True, False),
        view,
    )
    assert_equal(ed.cursor_col, 3)
    assert_equal(ed.desired_col, 3)


fn test_editor_sticky_col_reset_by_home_end() raises:
    var ed = Editor(String("hello world\nab\nabcdefghij"))
    _ = ed.handle_key(_key(KEY_END), _VIEW)        # desired=11
    _ = ed.handle_key(_key(KEY_DOWN), _VIEW)       # row 1, col 2, desired 11
    _ = ed.handle_key(_key(KEY_HOME), _VIEW)
    assert_equal(ed.cursor_col, 0)
    assert_equal(ed.desired_col, 0)
    _ = ed.handle_key(_key(KEY_DOWN), _VIEW)
    assert_equal(ed.cursor_row, 2)
    assert_equal(ed.cursor_col, 0)


fn test_editor_sticky_col_pageup_pagedown() raises:
    var ed = Editor(
        String("0123456789\n0123456789\nab\n0123456789\n0123456789\n0123456789")
    )
    _ = ed.handle_key(_key(KEY_END), _VIEW)
    assert_equal(ed.cursor_col, 10)
    var small_view = Rect(0, 0, 80, 3)
    _ = ed.handle_key(_key(KEY_PAGEDOWN), small_view)
    # PageDown jumps view-height (3) rows; the destination line is 10 chars long.
    assert_equal(ed.cursor_row, 3)
    assert_equal(ed.cursor_col, 10)
    assert_equal(ed.desired_col, 10)
    # Step back through the short line; sticky column survives.
    _ = ed.handle_key(_key(KEY_UP), small_view)
    assert_equal(ed.cursor_row, 2)
    assert_equal(ed.cursor_col, 2)
    assert_equal(ed.desired_col, 10)
    _ = ed.handle_key(_key(KEY_PAGEUP), small_view)
    # PageUp from row 2 jumps to row 0 (clamped at 0).
    assert_equal(ed.cursor_row, 0)
    assert_equal(ed.cursor_col, 10)
    assert_equal(ed.desired_col, 10)


fn test_editor_sticky_col_shift_down_keeps_anchor() raises:
    """Shift+Down should extend selection and use the sticky column too."""
    var ed = Editor(String("hello world\nab\nabcdefghij"))
    _ = ed.handle_key(_key(KEY_END), _VIEW)
    _ = ed.handle_key(_key(KEY_DOWN, MOD_SHIFT), _VIEW)
    assert_true(ed.has_selection())
    assert_equal(ed.cursor_row, 1)
    assert_equal(ed.cursor_col, 2)
    assert_equal(ed.anchor_row, 0)
    assert_equal(ed.anchor_col, 11)
    assert_equal(ed.desired_col, 11)
    _ = ed.handle_key(_key(KEY_DOWN, MOD_SHIFT), _VIEW)
    assert_equal(ed.cursor_row, 2)
    assert_equal(ed.cursor_col, 10)
    assert_equal(ed.desired_col, 11)


fn test_window_v_scrollbar_hit_arrows_and_thumb() raises:
    var lines = String("")
    for i in range(50):
        lines = lines + String("line ") + String(i) + String("\n")
    var w = Window.editor_window(String("ed"), Rect(0, 0, 30, 10), lines)
    # Geometry: width 30, height 10. Scroll bar is at x = 29.
    # Up arrow at y=1 (border row a.y is 0, so a.y+1=1).
    var hit_up = w.v_scrollbar_hit(Point(29, 1))
    assert_equal(hit_up[0], 1)
    var hit_down = w.v_scrollbar_hit(Point(29, 8))
    assert_equal(hit_down[0], 5)
    # Scroll to the top — thumb sits at the top of the track.
    w.editor.scroll_y = 0
    var hit_thumb_top = w.v_scrollbar_hit(Point(29, 2))
    assert_equal(hit_thumb_top[0], 3)
    # Anything off the v-scrollbar column returns 0.
    var miss = w.v_scrollbar_hit(Point(15, 4))
    assert_equal(miss[0], 0)


fn test_window_v_scroll_by_clamps() raises:
    var lines = String("")
    for i in range(50):
        lines = lines + String("L") + String(i) + String("\n")
    var w = Window.editor_window(String("ed"), Rect(0, 0, 30, 10), lines)
    w.editor.scroll_y = 5
    w.v_scroll_by(-1)
    assert_equal(w.editor.scroll_y, 4)
    w.v_scroll_by(100)
    # Buffer = 50 lines + trailing empty = 51; view height = 8; max = 43.
    var view_h = 10 - 2
    var max_y = w.editor.buffer.line_count() - view_h
    assert_equal(w.editor.scroll_y, max_y)
    w.v_scroll_by(-1000)
    assert_equal(w.editor.scroll_y, 0)


fn test_window_v_scroll_drag_to_end() raises:
    var lines = String("")
    for i in range(50):
        lines = lines + String("L") + String(i) + String("\n")
    var w = Window.editor_window(String("ed"), Rect(0, 0, 30, 10), lines)
    # Drag the thumb to the very bottom of the track.
    w.v_drag_thumb_to(8, 0)
    var view_h = 10 - 2
    var max_y = w.editor.buffer.line_count() - view_h
    assert_equal(w.editor.scroll_y, max_y)
    # Drag to the top.
    w.v_drag_thumb_to(2, 0)
    assert_equal(w.editor.scroll_y, 0)


# --- Phase-2 LSP plumbing tests --------------------------------------------


fn _bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


fn test_json_round_trip_lsp_envelope() raises:
    """A representative JSON-RPC request envelope round-trips."""
    var params = json_object()
    params.put(String("processId"), json_int(0))
    params.put(String("rootUri"), json_null())
    params.put(String("capabilities"), json_object())
    var req = json_object()
    req.put(String("jsonrpc"), json_str(String("2.0")))
    req.put(String("id"), json_int(1))
    req.put(String("method"), json_str(String("initialize")))
    req.put(String("params"), params^)
    var encoded = encode_json(req)
    assert_equal(
        encoded,
        String("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\","
              + "\"params\":{\"processId\":0,\"rootUri\":null,"
              + "\"capabilities\":{}}}"),
    )
    var reparsed = parse_json(encoded)
    assert_true(reparsed.is_object())
    assert_equal(reparsed.object_get(String("id")).value().as_int(), 1)
    var p = reparsed.object_get(String("params")).value()
    assert_true(p.object_get(String("rootUri")).value().is_null())
    assert_true(p.object_get(String("capabilities")).value().is_object())


fn test_json_string_escapes() raises:
    # Includes a literal 0x01 byte to exercise the \uXXXX path.
    var raw = String("a\"b\\c\nd\te") + chr(1) + String("f")
    var enc = encode_json(json_str(raw))
    assert_equal(enc, String("\"a\\\"b\\\\c\\nd\\te\\u0001f\""))
    var dec = parse_json(enc)
    assert_true(dec.is_string())
    assert_equal(dec.as_str(), raw)


fn test_json_parse_errors_raise() raises:
    var ok = True
    try:
        _ = parse_json(String("{"))
        ok = False
    except:
        pass
    assert_true(ok)
    try:
        _ = parse_json(String("{\"a\":1"))
        ok = False
    except:
        pass
    assert_true(ok)
    try:
        _ = parse_json(String("\"unterminated"))
        ok = False
    except:
        pass
    assert_true(ok)


fn test_json_floats_round_trip_as_text() raises:
    var v = parse_json(String("3.14"))
    assert_true(v.is_float())
    assert_equal(encode_json(v), String("3.14"))


fn test_lsp_framer_finds_double_crlf() raises:
    var buf = _bytes_of(String("Content-Length: 5\r\n\r\nhello"))
    var idx = _find_double_crlf(buf)
    assert_equal(idx, 17)
    var none_buf = _bytes_of(String("no header here"))
    assert_equal(_find_double_crlf(none_buf), -1)


fn test_lsp_framer_parses_content_length() raises:
    var buf = _bytes_of(String("Content-Length: 42\r\n\r\n"))
    var hdr_end = _find_double_crlf(buf)
    assert_equal(_parse_content_length(buf, hdr_end), 42)
    var buf2 = _bytes_of(String("content-length: 7\r\n\r\n"))
    assert_equal(_parse_content_length(buf2, _find_double_crlf(buf2)), 7)
    var buf3 = _bytes_of(String(
        "Content-Type: application/vscode-jsonrpc; charset=utf-8\r\n"
        + "Content-Length: 11\r\n\r\n"
    ))
    assert_equal(_parse_content_length(buf3, _find_double_crlf(buf3)), 11)


fn test_lsp_framer_extract_one_message() raises:
    var p = LspProcess()
    var hello = String("Content-Length: 5\r\n\r\nhello")
    var hb = hello.as_bytes()
    for i in range(len(hb)):
        p._read_buffer.append(hb[i])
    var got1 = p._extract_one_message()
    assert_true(Bool(got1))
    assert_equal(got1.value(), String("hello"))
    assert_equal(len(p._read_buffer), 0)
    var two = String("Content-Length: 3\r\n\r\nfooContent-Length: 3\r\n\r\nbar")
    var tb = two.as_bytes()
    for i in range(len(tb)):
        p._read_buffer.append(tb[i])
    var first = p._extract_one_message()
    assert_true(Bool(first))
    assert_equal(first.value(), String("foo"))
    var second = p._extract_one_message()
    assert_true(Bool(second))
    assert_equal(second.value(), String("bar"))
    assert_equal(len(p._read_buffer), 0)
    var part = String("Content-Length: 4\r\n\r\nab")
    var pb = part.as_bytes()
    for i in range(len(pb)):
        p._read_buffer.append(pb[i])
    var none1 = p._extract_one_message()
    assert_false(Bool(none1))
    p._read_buffer.append(0x63)
    p._read_buffer.append(0x64)
    var done = p._extract_one_message()
    assert_true(Bool(done))
    assert_equal(done.value(), String("abcd"))


fn test_lsp_drop_prefix_helper() raises:
    var b = _bytes_of(String("hello world"))
    var rest = _drop_prefix(b^, 6)
    assert_equal(len(rest), 5)
    var s = String(StringSlice(ptr=rest.unsafe_ptr(), length=len(rest)))
    assert_equal(s, String("world"))


fn test_lsp_classify_message() raises:
    var resp = parse_json(String(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"ok\":true}}"
    ))
    var c = classify_message(resp)
    assert_equal(Int(c.kind), Int(LSP_RESPONSE))
    assert_true(Bool(c.id))
    assert_equal(c.id.value(), 7)
    assert_true(Bool(c.result))
    var note = parse_json(String(
        "{\"jsonrpc\":\"2.0\",\"method\":\"window/logMessage\","
        + "\"params\":{\"type\":3,\"message\":\"hi\"}}"
    ))
    var cn = classify_message(note)
    assert_equal(Int(cn.kind), Int(LSP_NOTIFICATION))
    assert_equal(cn.method.value(), String("window/logMessage"))


fn test_lsp_subprocess_round_trip_via_cat() raises:
    """End-to-end pipe + framer test using ``/bin/cat``."""
    var cat_info = stat_file(String("/bin/cat"))
    if not cat_info.ok:
        assert_true(True)
        return
    var argv = List[String]()
    argv.append(String("/bin/cat"))
    var p = LspProcess.spawn(argv)
    p.write_message(String("ping"))
    p.write_message(String("pong"))
    var got1: Optional[String] = Optional[String]()
    for _ in range(200):
        var maybe = p.poll_message(Int32(50))
        if maybe:
            got1 = maybe
            break
    assert_true(Bool(got1))
    assert_equal(got1.value(), String("ping"))
    var got2: Optional[String] = Optional[String]()
    for _ in range(200):
        var maybe = p.poll_message(Int32(50))
        if maybe:
            got2 = maybe
            break
    assert_true(Bool(got2))
    assert_equal(got2.value(), String("pong"))
    p.terminate()


fn test_lsp_initialize_against_mojo_lsp_server() raises:
    """Spawn ``mojo-lsp-server`` and round-trip an ``initialize`` request.
    Skipped silently if the binary isn't installed."""
    var server = String(".pixi/envs/default/bin/mojo-lsp-server")
    var info = stat_file(server)
    if not info.ok:
        assert_true(True)
        return
    var argv = List[String]()
    argv.append(server)
    var client = LspClient.spawn(argv)
    var params = json_object()
    params.put(String("processId"), json_int(0))
    params.put(String("rootUri"), json_null())
    params.put(String("capabilities"), json_object())
    var req_id = client.send_request(String("initialize"), params^)
    var got: Optional[LspIncoming] = Optional[LspIncoming]()
    for _ in range(100):
        var maybe = client.poll(Int32(50))
        if maybe:
            got = maybe
            break
    if not got:
        var err = client.process.drain_stderr()
        client.terminate()
        raise Error(String("no LSP response; stderr=") + err)
    var msg = got.value()
    assert_equal(Int(msg.kind), Int(LSP_RESPONSE))
    assert_equal(msg.id.value(), req_id)
    assert_true(Bool(msg.result))
    assert_true(msg.result.value().is_object())
    assert_true(msg.result.value().object_has(String("capabilities")))
    client.send_notification(String("initialized"), json_object())
    var shutdown_id = client.send_request(String("shutdown"), json_null())
    for _ in range(100):
        var maybe2 = client.poll(Int32(50))
        if maybe2 and Bool(maybe2.value().id) \
                and maybe2.value().id.value() == shutdown_id:
            break
    client.send_notification(String("exit"), json_null())
    var exited = False
    for _ in range(20):
        if client.process.try_reap():
            exited = True
            break
    if not exited:
        client.terminate()


fn main() raises:
    test_point_arithmetic()
    test_rect_basics()
    test_rect_helpers()
    test_attr()
    test_canvas_put_text()
    test_canvas_box()
    test_canvas_fill()
    test_event_factories()
    test_parse_input_keys()
    test_parse_input_sgr_mouse()
    test_centered()
    test_text_buffer_split_and_join()
    test_editor_typing_and_arrows()
    test_editor_word_movement()
    test_editor_word_movement_across_lines()
    test_editor_shift_arrow_extends_selection()
    test_editor_shift_ctrl_arrow_composes()
    test_editor_typing_replaces_selection()
    test_editor_backspace_deletes_selection()
    test_editor_mouse_click_sets_cursor()
    test_editor_mouse_drag_extends_selection()
    test_editor_mouse_click_clamps_to_line()
    test_terminal_parses_modified_arrows()
    test_editor_selection_text()
    test_editor_cut_selection()
    test_editor_paste_text_single_line()
    test_editor_paste_text_multiline()
    test_editor_paste_replaces_selection()
    test_editor_selection_text_multiline()
    test_editor_goto_line()
    test_editor_find_next()
    test_editor_toggle_comment_single_line()
    test_editor_toggle_comment_selection()
    test_editor_toggle_case()
    test_editor_dirty_flag()
    test_file_io_read_and_stat()
    test_editor_from_file()
    test_terminal_parses_alt_letter_as_letter()
    test_editor_alt_arrow_word_jump()
    test_path_helpers()
    test_basename()
    test_find_git_project()
    test_menu_layout_pins_file_edit_window_help()
    test_right_aligned_menu_layout()
    test_desktop_project_lifecycle()
    test_file_tree_expand_collapse()
    test_file_tree_filters_dotfiles()
    test_desktop_workspace_shrinks_with_file_tree()
    test_window_manager_fit_into_moves_then_resizes()
    test_window_manager_fit_into_keeps_maximized_pinned()
    test_write_file_round_trip()
    test_editor_save_clears_dirty()
    test_editor_save_as_adopts_path()
    test_editor_replace_all()
    test_walk_project_files_finds_known_files()
    test_find_in_project_locates_string()
    test_gitignore_matches_directory_pattern()
    test_gitignore_matches_glob_and_negate()
    test_walk_project_files_respects_gitignore()
    test_extension_of_helper()
    test_word_at_helper()
    test_highlight_for_extension_recognizes_mojo()
    test_highlight_triple_quoted_string_spans_lines()
    test_highlight_unknown_extension_returns_empty()
    test_editor_refreshes_highlights_after_edits()
    test_editor_paint_overlays_highlight_attr()
    test_editor_ctrl_click_emits_definition_request()
    test_editor_ctrl_click_outside_identifier_is_silent()
    test_quick_open_match_rules()
    test_quick_open_match_word_boundary_kinds()
    test_quick_open_filters_as_you_type()
    test_ctrl_o_opens_quick_open_when_project_active()
    test_ctrl_o_bubbles_when_no_project()
    test_desktop_dispatch_editor_save_passes_through_when_no_editor()
    test_desktop_dispatch_passes_through_unknown_actions()
    test_desktop_dispatch_editor_save_writes_focused_editor()
    test_desktop_replace_chains_two_prompts()
    test_desktop_open_file_uses_80_percent_size()
    test_desktop_open_file_cascades_by_one()
    test_desktop_open_file_inherits_maximize_state()
    test_desktop_window_menu_lists_open_windows()
    test_desktop_window_menu_when_empty()
    test_desktop_window_focus_action_focuses_window()
    test_desktop_maximize_all_and_restore_all()
    test_window_manager_close_focused()
    test_ctrl_n_focuses_window_by_number()
    test_focus_changes_keep_window_list_order_stable()
    test_window_menu_items_show_ctrl_n_shortcut()
    test_ctrl_w_closes_focused_window()
    test_format_hotkey_renders_combinations()
    test_menu_items_get_shortcut_text_after_refresh()
    test_dropdown_widens_to_fit_shortcut()
    test_parse_csi_modify_other_keys_normalizes_ctrl_q()
    test_parse_csi_modify_other_keys_ctrl_shift_f()
    test_parse_csi_unknown_sequence_is_consumed_whole()
    test_parse_csi_kitty_u_ctrl_letter()
    test_editor_rejects_modified_letter_typing()
    test_ctrl_q_modifyOtherKeys_triggers_quit_action()
    test_ctrl_key_helper()
    test_menu_keyboard_nav_arrows_and_enter()
    test_alt_letter_opens_menu_by_mnemonic()
    test_esc_prefix_opens_menu_by_mnemonic()
    test_esc_prefix_disarms_after_one_keystroke()
    test_top_level_esc_does_not_quit()
    test_default_hotkey_ctrl_q_returns_quit()
    test_default_hotkey_ctrl_f_opens_find_prompt()
    test_default_hotkey_ctrl_s_saves_focused_editor()
    test_hotkey_overrides_default_when_registered_later()
    test_hotkey_does_not_fire_while_prompt_active()
    test_desktop_project_find_requires_active_project()
    test_replace_in_project_round_trip()
    test_file_dialog_lists_and_navigates()
    test_partial_sgr_mouse_does_not_emit_esc()
    test_sgr_mouse_wheel_up()
    test_file_dialog_selects_a_file()
    test_file_dialog_mouse_click_selects()
    test_file_dialog_double_click_opens()
    test_file_dialog_wheel_scrolls()
    test_editor_sticky_col_down_through_short_line()
    test_editor_sticky_col_up_through_short_line()
    test_editor_sticky_col_reset_by_left_arrow()
    test_editor_sticky_col_reset_by_right_arrow()
    test_editor_sticky_col_reset_by_typing()
    test_editor_sticky_col_reset_by_click()
    test_editor_sticky_col_reset_by_home_end()
    test_editor_sticky_col_pageup_pagedown()
    test_editor_sticky_col_shift_down_keeps_anchor()
    test_window_v_scrollbar_hit_arrows_and_thumb()
    test_window_v_scroll_by_clamps()
    test_window_v_scroll_drag_to_end()
    test_json_round_trip_lsp_envelope()
    test_json_string_escapes()
    test_json_parse_errors_raise()
    test_json_floats_round_trip_as_text()
    test_lsp_framer_finds_double_crlf()
    test_lsp_framer_parses_content_length()
    test_lsp_framer_extract_one_message()
    test_lsp_drop_prefix_helper()
    test_lsp_classify_message()
    test_lsp_subprocess_round_trip_via_cat()
    test_lsp_initialize_against_mojo_lsp_server()
    print("all tests passed")
