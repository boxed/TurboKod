"""Pure-data tests: geometry, colors, canvas, event factories.

These tests don't touch the terminal so they can run in CI without a TTY.
Run with::

    mojo run -I src tests/test_basic.mojo
"""

from std.ffi import external_call
from std.testing import assert_equal, assert_false, assert_true

from turbokod.canvas import Canvas, wrap_to_width
from turbokod.dir_browser import DirBrowser
from turbokod.painter import Painter
from turbokod.cell import Cell, blank_cell
from turbokod.colors import (
    Attr, BLACK, BLUE, DARK_GRAY, GREEN, LIGHT_BLUE, LIGHT_GRAY, LIGHT_GREEN,
    STYLE_UNDERLINE, WHITE, YELLOW, default_attr,
)
from turbokod.diff import MergeResult, diff3_merge, diff_lines, unified_diff
from turbokod.editor import (
    EXT_CHANGE_CONFLICT, EXT_CHANGE_MERGED, EXT_CHANGE_NONE,
    EXT_CHANGE_RELOADED, Editor, TextBuffer,
)
from turbokod.editorconfig import (
    EditorConfig, load_editorconfig_for_path, match_section, parse_editorconfig,
)
from turbokod.file_dialog import FileDialog
from turbokod.save_as_dialog import SaveAsDialog
from turbokod.session_store import (
    Session, SessionWindow, _resolve_session_path, _session_relative,
    encode_session, load_session, save_session,
)
from turbokod.desktop import (
    APP_QUIT_ACTION,
    Desktop,
    EDITOR_FIND, EDITOR_GOTO, EDITOR_NEW, EDITOR_QUICK_OPEN, EDITOR_REPLACE,
    EDITOR_SAVE, EDITOR_SAVE_AS, EDITOR_TOGGLE_CASE, EDITOR_TOGGLE_COMMENT,
    Hotkey,
    PROJECT_CLOSE_ACTION, PROJECT_CONFIG_TARGETS, PROJECT_FIND, PROJECT_REPLACE,
    PROJECT_TREE_ACTION,
    WINDOW_CLOSE,
    _find_doc_entry_for_word,
    ctrl_key, format_hotkey,
)
from turbokod.file_io import (
    basename, find_git_project, join_path, list_directory, parent_path,
    read_file, stat_file, write_file,
)
from turbokod.git_blame import BlameLine, parse_blame_porcelain
from turbokod.git_changes import (
    ChangedFile, GIT_CHANGE_ADDED, GIT_CHANGE_MODIFIED, GIT_CHANGE_NONE,
    diff_buffer_against_head, parse_unified_diff_files,
)
from turbokod.local_changes import LocalChanges, build_minimal_patch
from turbokod.file_tree import FILE_TREE_WIDTH, FileTree
from turbokod.menu import Menu, MenuBar, MenuItem
from turbokod.project import (
    GitignoreMatcher, find_in_project, replace_in_project, walk_project_files,
)
from turbokod.project_targets import (
    ProjectTargets, RunTarget,
    detect_project_language,
    load_project_targets, resolve_python_interpreter, resolved_cwd,
    resolved_program, save_project_targets,
)
from turbokod.buttons import (
    ShadowButton, paint_shadow_button, shadow_button_hit,
)
from turbokod.debug_pane import (
    DebugPane, PANE_MODE_DEBUG, PANE_MODE_RUN,
)
from turbokod.run_manager import RunSession, drain_run_output, poll_run_exit
from turbokod.status import StatusBar, StatusTab
from turbokod.targets_dialog import TargetsDialog
from turbokod.quick_open import QuickOpen, quick_open_match
from turbokod.install_runner import InstallResult, InstallRunner, _last_lines
from turbokod.doc_config import (
    DocSpec, built_in_docsets, docs_install_command,
    find_docset_by_language, find_docset_for_extension,
)
from turbokod.doc_store import DocEntry, DocStore, html_to_text
from turbokod.doc_pick import DocPick
from turbokod.json import (
    JsonValue, encode_json, json_array, json_bool, json_int, json_null,
    json_object, json_str, parse_json,
)
from turbokod.language_config import (
    built_in_servers, find_language_by_id, find_language_for_extension,
)
from turbokod.lsp import (
    LSP_NOTIFICATION, LSP_RESPONSE, LspClient, LspIncoming, LspProcess,
    _drop_prefix, _find_double_crlf, _parse_content_length, capture_command,
    classify_message,
)
from turbokod.git_changes import (
    apply_patch_to_index, compute_staged_diff, compute_unstaged_diff,
    fetch_git_status, stage_file, unstage_file,
)
from turbokod.dap import (
    DAP_EVENT, DAP_REQUEST, DAP_RESPONSE,
    DapClient, DapIncoming, classify_dap_message, dap_initialize_arguments,
)
from turbokod.dap_dispatch import (
    DapManager, DapStackFrame, DapScope, DapVariable, DapThread,
    _parse_scopes, _parse_stack_trace, _parse_threads, _parse_variables,
)
from turbokod.debugger_config import (
    DAP_REQUEST_LAUNCH, DebuggerSpec,
    built_in_debuggers, find_debugger_for_language, launch_arguments_for,
)
from turbokod.highlight import (
    DefinitionRequest, GrammarRegistry, Highlight, HighlightCache,
    extension_of, highlight_for_extension, highlight_incremental,
    highlight_comment_attr, highlight_decorator_attr, highlight_ident_attr,
    highlight_keyword_attr,
    highlight_number_attr, highlight_operator_attr, highlight_string_attr,
    word_at,
)
from turbokod.grammar_install import (
    built_in_downloadable_grammars,
    find_downloadable_grammar_by_language,
    find_downloadable_grammar_for_extension,
    grammar_install_command, user_grammar_path, user_grammar_path_for_ext,
)
from turbokod.onig import OnigRegex, onig_global_init
from turbokod.tm_grammar import load_grammar_from_string
from turbokod.tm_tokenizer import tokenize_with_grammar
from turbokod.window import WindowManager, paint_drop_shadow
from turbokod.events import (
    Event, EVENT_KEY, EVENT_MOUSE, EVENT_NONE, EVENT_OPEN_PATH,
    EVENT_QUIT, EVENT_RESIZE,
    KEY_BACKSPACE, KEY_DELETE, KEY_DOWN, KEY_END, KEY_ENTER, KEY_ESC,
    KEY_F5, KEY_HOME,
    KEY_LEFT, KEY_PAGEDOWN, KEY_PAGEUP, KEY_RIGHT, KEY_TAB, KEY_UP,
    MOD_ALT, MOD_CTRL, MOD_META, MOD_NONE, MOD_SHIFT,
    MOUSE_BUTTON_LEFT, MOUSE_BUTTON_NONE, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from turbokod.geometry import Point, Rect
from turbokod.confirm_dialog import ConfirmDialog
from turbokod.prompt import Prompt
from turbokod.terminal import parse_input
from turbokod.text_field import text_field_clipboard_key
from turbokod.view import Fill, Frame, Label, centered
from turbokod.window import Window


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


fn test_parse_window_size_report() raises:
    # ``CSI 8 ; rows ; cols t`` — xterm window-size report. The native
    # wrapper pushes this on every resize so turbokod sees the new
    # dimensions immediately; we should turn it into an EVENT_RESIZE
    # carrying ``(cols, rows)`` in ``pos``.
    var ev = parse_input(String("\x1b[8;25;80t"))
    assert_equal(ev[1], 10)  # consumed all 10 bytes of the sequence
    assert_true(ev[0].kind == EVENT_RESIZE)
    assert_equal(ev[0].pos.x, 80)  # cols = width
    assert_equal(ev[0].pos.y, 25)  # rows = height

    # Larger size, just to make sure we're not constant-folding.
    var ev2 = parse_input(String("\x1b[8;50;200t"))
    assert_true(ev2[0].kind == EVENT_RESIZE)
    assert_equal(ev2[0].pos.x, 200)
    assert_equal(ev2[0].pos.y, 50)


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


fn test_editor_double_click_selects_word() raises:
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


fn test_editor_double_click_drag_extends_by_word_forward() raises:
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


fn test_editor_double_click_drag_extends_by_word_backward() raises:
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


fn test_editor_triple_click_selects_line() raises:
    var ed = Editor(String("first line\nsecond line\nthird line"))
    # Three quick presses on row 1, col 4.
    for _ in range(3):
        _ = ed.handle_mouse(
            Event.mouse_event(Point(4, 1), MOUSE_BUTTON_LEFT, True, False),
            _VIEW,
        )
    # Whole line + trailing newline (since this isn't the last line).
    assert_equal(ed.selection_text(), String("second line\n"))


fn test_editor_triple_click_last_line_no_newline() raises:
    var ed = Editor(String("first\nlast"))
    for _ in range(3):
        _ = ed.handle_mouse(
            Event.mouse_event(Point(2, 1), MOUSE_BUTTON_LEFT, True, False),
            _VIEW,
        )
    # Last line: no trailing newline available.
    assert_equal(ed.selection_text(), String("last"))


fn test_editor_triple_click_drag_extends_by_line_forward() raises:
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


fn test_editor_triple_click_drag_extends_by_line_backward() raises:
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


fn test_editor_cut_whole_line_when_no_selection() raises:
    var ed = Editor(String("first\nsecond\nthird"))
    ed.move_to(1, 3, False)
    ed.cut_to_clipboard()
    assert_equal(ed.buffer.line_count(), 2)
    assert_equal(ed.buffer.line(0), String("first"))
    assert_equal(ed.buffer.line(1), String("third"))
    assert_equal(ed.cursor_row, 1); assert_equal(ed.cursor_col, 0)


fn test_editor_cut_whole_line_only_line() raises:
    var ed = Editor(String("only line"))
    ed.move_to(0, 4, False)
    ed.cut_to_clipboard()
    assert_equal(ed.buffer.line_count(), 1)
    assert_equal(ed.buffer.line(0), String(""))
    assert_equal(ed.cursor_row, 0); assert_equal(ed.cursor_col, 0)


fn test_editor_smart_indent_mirrors_previous_line() raises:
    var ed = Editor(String("    hello"))
    ed.move_to(0, 9, False)
    _ = ed.handle_key(_key(KEY_ENTER), _VIEW)
    assert_equal(ed.buffer.line_count(), 2)
    assert_equal(ed.buffer.line(1), String("    "))
    assert_equal(ed.cursor_row, 1); assert_equal(ed.cursor_col, 4)


fn test_editor_smart_indent_after_open_brace() raises:
    var ed = Editor(String("if (x) {"))
    ed.move_to(0, 8, False)
    _ = ed.handle_key(_key(KEY_ENTER), _VIEW)
    assert_equal(ed.buffer.line(1), String("    "))
    assert_equal(ed.cursor_col, 4)


fn test_editor_smart_indent_after_colon() raises:
    var ed = Editor(String("    def foo():"))
    ed.move_to(0, 14, False)
    _ = ed.handle_key(_key(KEY_ENTER), _VIEW)
    assert_equal(ed.buffer.line(1), String("        "))
    assert_equal(ed.cursor_col, 8)


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


fn test_terminal_parses_shift_tab() raises:
    """Backtab (CSI Z) and the modifier-reporting form (CSI 1;2 Z) both
    arrive as KEY_TAB with MOD_SHIFT so the editor can treat Shift+Tab
    as the inverse of Tab."""
    var bare = parse_input(String("\x1b[Z"))
    assert_true(bare[0].kind == EVENT_KEY)
    assert_true(bare[0].key == KEY_TAB)
    assert_true((bare[0].mods & MOD_SHIFT) != 0)
    assert_equal(bare[1], 3)

    var modreport = parse_input(String("\x1b[1;2Z"))
    assert_true(modreport[0].key == KEY_TAB)
    assert_true((modreport[0].mods & MOD_SHIFT) != 0)


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
    # Initial check: nothing changed since open, so the status code is
    # EXT_CHANGE_NONE.
    assert_equal(ed.check_for_external_change(), EXT_CHANGE_NONE)


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


fn test_system_menu_pins_to_left_edge() raises:
    """The hamburger (``is_system``) menu always occupies cells 0..3, the
    same slot the static glyph used to live in, regardless of insertion
    order or what other left-aligned menus are present."""
    var bar = MenuBar()
    var file_items = List[MenuItem]()
    file_items.append(MenuItem(String("New"), String("noop")))
    bar.add(Menu(String("File"), file_items^))
    var sys_items = List[MenuItem]()
    sys_items.append(MenuItem(String("Quit"), String("quit")))
    bar.add(Menu(String("≡"), sys_items^, is_system=True))
    var rects = bar._layout(80)
    # System menu pinned to cells 0..3 (insertion order index 1).
    assert_equal(rects[1].a.x, 0)
    assert_equal(rects[1].b.x, 3)
    # File still starts at x=3 — the system slot doesn't shift packing.
    assert_equal(rects[0].a.x, 3)
    assert_equal(rects[0].b.x, 3 + len(String("File").as_bytes()) + 2)


fn test_right_aligned_menu_layout() raises:
    """A right-aligned menu sits flush with the screen's right edge, with
    its hit-test rect ending at exactly screen_width."""
    var bar = MenuBar()
    var left_items = List[MenuItem]()
    left_items.append(MenuItem(String("New"), String("noop")))
    bar.add(Menu(String("File"), left_items^))
    var right_items = List[MenuItem]()
    right_items.append(MenuItem(String("Close project"), PROJECT_CLOSE_ACTION))
    bar.add(Menu(String("turbokod"), right_items^, right_aligned=True))
    var rects = bar._layout(80)
    # Left menu starts at x=3 and gets " File "  (label + 2 padding).
    assert_equal(rects[0].a.x, 3)
    assert_equal(rects[0].b.x, 3 + len(String("File").as_bytes()) + 2)
    # Right-aligned menu's right edge is the screen width; width = label+2.
    assert_equal(rects[1].b.x, 80)
    var right_w = len(String("turbokod").as_bytes()) + 2
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
    # Label is the project root's basename — for this repo, "turbokod".
    assert_equal(d.menu_bar.menus[idx].label, String("turbokod"))
    # The project menu has: tree-toggle, configure-targets, separator,
    # close. The separator counts as an item but carries no action.
    assert_equal(len(d.menu_bar.menus[idx].items), 4)
    assert_equal(d.menu_bar.menus[idx].items[0].action, PROJECT_TREE_ACTION)
    assert_equal(
        d.menu_bar.menus[idx].items[1].action, PROJECT_CONFIG_TARGETS,
    )
    assert_true(d.menu_bar.menus[idx].items[2].is_separator)
    assert_equal(d.menu_bar.menus[idx].items[3].action, PROJECT_CLOSE_ACTION)
    # Detection is sticky: a second call doesn't reset the project.
    var first = d.project.value()
    d.detect_project_from(String("src/turbokod/desktop.mojo"))
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
    return String("/tmp/turbokod_test_") + String(Int(pid)) + suffix


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


fn _lines_from(text: String) -> List[String]:
    """Mirror ``TextBuffer.__init__`` for tests that need a plain
    ``List[String]`` line view of a string (used by ``diff3_merge``
    cases below)."""
    var out = List[String]()
    var b = text.as_bytes()
    var start = 0
    var i = 0
    while i < len(b):
        if b[i] == 0x0A:
            out.append(String(StringSlice(unsafe_from_utf8=b[start:i])))
            start = i + 1
        i += 1
    out.append(String(StringSlice(unsafe_from_utf8=b[start:len(b)])))
    return out^


fn test_diff3_merge_clean_when_only_ours_changed() raises:
    """If theirs equals base, the merge takes ours unmodified."""
    var base = _lines_from(String("a\nb\nc\n"))
    var ours = _lines_from(String("a\nB\nc\n"))
    var theirs = _lines_from(String("a\nb\nc\n"))
    var m = diff3_merge(base, ours, theirs)
    assert_equal(m.conflicts, 0)
    assert_equal(m.first_conflict_row, -1)
    assert_equal(len(m.lines), len(ours))
    for i in range(len(ours)):
        assert_equal(m.lines[i], ours[i])


fn test_diff3_merge_clean_when_only_theirs_changed() raises:
    """Symmetric: if ours equals base, the merge takes theirs."""
    var base = _lines_from(String("a\nb\nc\n"))
    var ours = _lines_from(String("a\nb\nc\n"))
    var theirs = _lines_from(String("a\nB\nc\n"))
    var m = diff3_merge(base, ours, theirs)
    assert_equal(m.conflicts, 0)
    for i in range(len(theirs)):
        assert_equal(m.lines[i], theirs[i])


fn test_diff3_merge_clean_when_changes_disjoint() raises:
    """Both sides changed, but in different regions — auto-merges."""
    var base = _lines_from(String("a\nb\nc\nd\ne\n"))
    var ours = _lines_from(String("A\nb\nc\nd\ne\n"))
    var theirs = _lines_from(String("a\nb\nc\nd\nE\n"))
    var m = diff3_merge(base, ours, theirs)
    assert_equal(m.conflicts, 0)
    var want = _lines_from(String("A\nb\nc\nd\nE\n"))
    assert_equal(len(m.lines), len(want))
    for i in range(len(want)):
        assert_equal(m.lines[i], want[i])


fn test_diff3_merge_identical_changes_dont_conflict() raises:
    """When both sides edit the same region to the same result, take it."""
    var base = _lines_from(String("a\nb\nc\n"))
    var ours = _lines_from(String("a\nB\nc\n"))
    var theirs = _lines_from(String("a\nB\nc\n"))
    var m = diff3_merge(base, ours, theirs)
    assert_equal(m.conflicts, 0)
    var want = _lines_from(String("a\nB\nc\n"))
    for i in range(len(want)):
        assert_equal(m.lines[i], want[i])


fn test_diff3_merge_conflict_when_both_edit_same_line() raises:
    """Same base line, two different changes → conflict markers."""
    var base = _lines_from(String("a\nb\nc\n"))
    var ours = _lines_from(String("a\nOURS\nc\n"))
    var theirs = _lines_from(String("a\nTHEIRS\nc\n"))
    var m = diff3_merge(base, ours, theirs,
        String("local"), String("disk"))
    assert_equal(m.conflicts, 1)
    assert_true(m.first_conflict_row >= 0)
    # The marker block must be present in order.
    var saw_open = False
    var saw_eq = False
    var saw_close = False
    var open_idx = -1
    var eq_idx = -1
    var close_idx = -1
    for i in range(len(m.lines)):
        if m.lines[i] == String("<<<<<<< local"):
            saw_open = True
            open_idx = i
        elif m.lines[i] == String("======="):
            saw_eq = True
            eq_idx = i
        elif m.lines[i] == String(">>>>>>> disk"):
            saw_close = True
            close_idx = i
    assert_true(saw_open)
    assert_true(saw_eq)
    assert_true(saw_close)
    assert_true(open_idx < eq_idx)
    assert_true(eq_idx < close_idx)
    assert_equal(m.first_conflict_row, open_idx)


fn test_editor_external_change_clean_reload_when_buffer_clean() raises:
    """Buffer is clean: an external write triggers a verbatim reload."""
    var path = _temp_path(String("_ext_clean.txt"))
    assert_true(write_file(path, String("alpha\nbeta\n")))
    var ed = Editor.from_file(path)
    assert_false(ed.dirty)
    # Rewrite with different size so the stat-compare detects it even
    # within the same wall-clock second.
    assert_true(write_file(path, String("alpha\nbeta\nGAMMA\n")))
    var status = ed.check_for_external_change()
    assert_equal(status, EXT_CHANGE_RELOADED)
    assert_false(ed.dirty)
    assert_equal(ed.buffer.line_count(), 4)
    assert_equal(ed.buffer.line(2), String("GAMMA"))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


fn test_editor_external_change_refreshes_highlights() raises:
    """Reload from disk must produce highlights matching the new
    content — not stale entries pointing into the previous buffer.
    Exercises a scope-changing case (block comment over multiple
    lines, then erased) so the cache's per-line post-stack actually
    matters.
    """
    var path = _temp_path(String("_ext_hl.rs"))
    assert_true(write_file(
        path,
        String("/* block start\nstill in block\nstill in block 2\n*/ end\n"),
    ))
    var ed = Editor.from_file(path)
    var registry = GrammarRegistry()
    ed.flush_highlights(registry)
    assert_true(len(ed.highlights) > 0)
    # Same path, but the block comment is gone — the new buffer's
    # post-stacks differ from the cached ones at every row.
    assert_true(write_file(
        path,
        String("fn two() {}\nfn three() {}\n"),
    ))
    var status = ed.check_for_external_change()
    assert_equal(status, EXT_CHANGE_RELOADED)
    ed.flush_highlights(registry)
    var post = ed.highlights.copy()
    var expected = highlight_for_extension(String("rs"), ed.buffer.lines)
    # Same shape as a full retokenize against the new buffer.
    assert_equal(len(post), len(expected))
    for i in range(len(post)):
        assert_equal(post[i].row, expected[i].row)
        assert_equal(post[i].col_start, expected[i].col_start)
        assert_equal(post[i].col_end, expected[i].col_end)
    # No highlight may point at a row past the new buffer's end.
    var max_row = ed.buffer.line_count() - 1
    for i in range(len(post)):
        assert_true(post[i].row <= max_row)
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


fn test_editor_external_change_auto_merges_disjoint_edits() raises:
    """Buffer edits and disk edits in different regions → silent merge."""
    var path = _temp_path(String("_ext_merge.txt"))
    assert_true(write_file(path, String("a\nb\nc\nd\ne\n")))
    var ed = Editor.from_file(path)
    # Local edit on the first line: type before the 'a'.
    _ = ed.handle_key(Event.key_event(UInt32(ord("X"))), _VIEW)
    assert_true(ed.dirty)
    assert_equal(ed.buffer.line(0), String("Xa"))
    # External edit on the last non-empty line.
    assert_true(write_file(path, String("a\nb\nc\nd\nEEE\n")))
    var status = ed.check_for_external_change()
    assert_equal(status, EXT_CHANGE_MERGED)
    # Both edits present, no conflict markers.
    assert_equal(ed.buffer.line(0), String("Xa"))
    assert_equal(ed.buffer.line(4), String("EEE"))
    # Buffer differs from disk now (disk lacks our 'X'), so still dirty.
    assert_true(ed.dirty)
    # No conflict diff queued.
    assert_false(ed.consume_conflict_diff())
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


fn test_editor_external_change_clears_dirty_when_disk_already_has_our_edits() raises:
    """If disk happens to already match our buffer (someone applied
    the same edit externally), the merge resolves to clean and the
    buffer goes back to non-dirty."""
    var path = _temp_path(String("_ext_match.txt"))
    assert_true(write_file(path, String("alpha\n")))
    var ed = Editor.from_file(path)
    _ = ed.handle_key(Event.key_event(KEY_END), _VIEW)
    _ = ed.handle_key(Event.key_event(UInt32(ord("!"))), _VIEW)
    assert_true(ed.dirty)
    assert_equal(ed.buffer.line(0), String("alpha!"))
    # External writer produced the exact same content (different size
    # from baseline so stat fires).
    assert_true(write_file(path, String("alpha!\n")))
    var status = ed.check_for_external_change()
    assert_equal(status, EXT_CHANGE_MERGED)
    assert_false(ed.dirty)
    assert_equal(ed.buffer.line(0), String("alpha!"))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


fn test_editor_external_change_conflict_inserts_markers() raises:
    """Both buffer and disk modified the same line → conflict markers
    are embedded, cursor jumps to the first marker, and a pre-rendered
    diff is queued for the host to display."""
    var path = _temp_path(String("_ext_conflict.txt"))
    assert_true(write_file(path, String("a\nb\nc\n")))
    var ed = Editor.from_file(path)
    # Local: cursor at start of "b", select line, replace with "OURS".
    ed.move_to(1, 0, False)
    ed.move_to(1, 1, True)
    _ = ed.handle_key(Event.key_event(UInt32(ord("O"))), _VIEW)
    _ = ed.handle_key(Event.key_event(UInt32(ord("U"))), _VIEW)
    _ = ed.handle_key(Event.key_event(UInt32(ord("R"))), _VIEW)
    _ = ed.handle_key(Event.key_event(UInt32(ord("S"))), _VIEW)
    assert_equal(ed.buffer.line(1), String("OURS"))
    assert_true(ed.dirty)
    # External: same line replaced with different content; size differs
    # so stat-compare fires.
    assert_true(write_file(path, String("a\nTHEIRS\nc\n")))
    var status = ed.check_for_external_change()
    assert_equal(status, EXT_CHANGE_CONFLICT)
    assert_true(ed.dirty)
    # First conflict marker present and the cursor sits on it.
    var found_open = False
    for i in range(ed.buffer.line_count()):
        if ed.buffer.line(i).find(String("<<<<<<<")) >= 0:
            found_open = True
            assert_equal(ed.cursor_row, i)
            break
    assert_true(found_open)
    # Both versions appear in the buffer.
    var saw_ours = False
    var saw_theirs = False
    for i in range(ed.buffer.line_count()):
        if ed.buffer.line(i) == String("OURS"):
            saw_ours = True
        elif ed.buffer.line(i) == String("THEIRS"):
            saw_theirs = True
    assert_true(saw_ours)
    assert_true(saw_theirs)
    # The host-facing diff is queued (consumed on first read).
    var diff = ed.consume_conflict_diff()
    assert_true(diff)
    var diff_text = diff.value()
    # Must contain both old- and new-disk markers from unified_diff.
    assert_true(diff_text.find(String("@@")) >= 0)
    # consume_conflict_diff is one-shot.
    assert_false(ed.consume_conflict_diff())
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


fn test_editorconfig_parse_basic() raises:
    """Parser walks an INI-ish blob into sections + global ``root`` flag."""
    var text = String(
        "# leading comment\n"
        + "root = true\n"
        + "\n"
        + "[*]\n"
        + "indent_style = space\n"
        + "indent_size = 4\n"
        + "\n"
        + "[*.{c,h}]\n"
        + "indent_style = tab\n"
    )
    var f = parse_editorconfig(String("/tmp/x"), text)
    assert_true(f.is_root)
    assert_equal(len(f.sections), 2)
    assert_equal(f.sections[0].pattern, String("*"))
    assert_equal(len(f.sections[0].keys), 2)
    assert_equal(f.sections[1].pattern, String("*.{c,h}"))


fn test_editorconfig_match_section() raises:
    # No-slash patterns match basenames at any depth.
    assert_true(match_section(String("*.py"), String("foo.py")))
    assert_true(match_section(String("*.py"), String("a/b/foo.py")))
    assert_false(match_section(String("*.py"), String("foo.pyc")))
    # Anchored (slashed) patterns match relative path from the start.
    assert_true(match_section(String("src/*.c"), String("src/main.c")))
    assert_false(match_section(String("src/*.c"), String("a/src/main.c")))
    # ``**`` crosses directory boundaries.
    assert_true(match_section(String("**/foo"), String("foo")))
    assert_true(match_section(String("**/foo"), String("a/b/foo")))
    # Alternation.
    assert_true(match_section(String("*.{c,h}"), String("main.c")))
    assert_true(match_section(String("*.{c,h}"), String("main.h")))
    assert_false(match_section(String("*.{c,h}"), String("main.cpp")))
    # Character class.
    assert_true(match_section(String("[ab].txt"), String("a.txt")))
    assert_true(match_section(String("[ab].txt"), String("b.txt")))
    assert_false(match_section(String("[ab].txt"), String("c.txt")))
    # Negated character class.
    assert_true(match_section(String("[!a].txt"), String("b.txt")))
    assert_false(match_section(String("[!a].txt"), String("a.txt")))
    # Range.
    assert_true(match_section(String("[a-z].txt"), String("k.txt")))
    assert_false(match_section(String("[a-z].txt"), String("K.txt")))


fn test_editorconfig_load_from_fixture() raises:
    """The fixture: top-level config sets 4-space LF + trim + final-NL,
    overrides ``*.{c,h}`` to tab/2 and ``Makefile`` to tab. The ``sub/``
    dir's file overrides ``*.py`` to indent_size=2 — and inherits the
    rest from the parent because that file lacks ``root = true``."""
    var fix = String("tests/fixtures/editorconfig/")
    var c = load_editorconfig_for_path(fix + String("foo.txt"))
    assert_equal(c.indent_style, String("space"))
    assert_equal(c.indent_size, 4)
    assert_equal(c.end_of_line, String("lf"))
    assert_equal(c.trim_trailing_whitespace, 1)
    assert_equal(c.insert_final_newline, 1)
    var c2 = load_editorconfig_for_path(fix + String("main.c"))
    assert_equal(c2.indent_style, String("tab"))
    assert_equal(c2.tab_width, 2)
    # ``end_of_line`` was set on ``[*]`` and inherits.
    assert_equal(c2.end_of_line, String("lf"))
    # Closer file wins per-property: sub/ overrides *.py size to 2,
    # but inherits other settings from the parent's ``[*]``.
    var c3 = load_editorconfig_for_path(fix + String("sub/foo.py"))
    assert_equal(c3.indent_style, String("space"))
    assert_equal(c3.indent_size, 2)
    assert_equal(c3.end_of_line, String("lf"))


fn test_editor_uses_editorconfig_indent() raises:
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


fn test_editor_tab_indents_selected_lines() raises:
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


fn test_editor_shift_tab_dedents_selected_lines() raises:
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
    # Cursor was at col 4 on row 0; 4 spaces removed → col 0.
    assert_equal(ed.cursor_row, 0)
    assert_equal(ed.cursor_col, 0)


fn test_editor_shift_tab_dedents_cursor_line_without_selection() raises:
    """Shift+Tab with no selection dedents only the cursor's line."""
    var ed = Editor(String("    alpha\n    beta"))
    ed.move_to(1, 6, False)         # row 1, somewhere inside "beta"
    _ = ed.handle_key(_key(KEY_TAB, MOD_SHIFT), _VIEW)
    assert_equal(ed.buffer.line(0), String("    alpha"))
    assert_equal(ed.buffer.line(1), String("beta"))
    assert_equal(ed.cursor_col, 2)


fn test_editor_shift_tab_no_indent_is_noop() raises:
    """Shift+Tab on lines with no leading whitespace must not push an
    undo entry — otherwise undo would step through dead-no-op states."""
    var ed = Editor(String("alpha\nbeta"))
    ed.move_to(0, 0, False)
    ed.move_to(1, 4, True)
    var before = ed.buffer.line(0) + String("|") + ed.buffer.line(1)
    _ = ed.handle_key(_key(KEY_TAB, MOD_SHIFT), _VIEW)
    var after = ed.buffer.line(0) + String("|") + ed.buffer.line(1)
    assert_equal(before, after)


fn test_editor_save_applies_editorconfig_transforms() raises:
    """``save`` should trim trailing whitespace and ensure a final newline
    when the editorconfig says to. The fixture's top-level ``[*]`` sets
    both, so saving a .txt file inside the fixture tree exercises both."""
    var path = String("tests/fixtures/editorconfig/test_save.txt")
    # Bootstrap with a payload that ``trim`` + ``final newline`` will rewrite.
    assert_true(write_file(path, String("alpha   \nbeta")))
    var ed = Editor.from_file(path)
    assert_equal(ed.editorconfig.trim_trailing_whitespace, 1)
    assert_equal(ed.editorconfig.insert_final_newline, 1)
    assert_true(ed.save())
    var got = read_file(path)
    # ``alpha   `` → ``alpha`` (trailing spaces trimmed) and a final ``\n``
    # is appended even though the original file lacked one.
    assert_equal(got, String("alpha\nbeta\n"))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


fn test_editor_save_uses_editorconfig_line_endings() raises:
    """When ``end_of_line`` is ``crlf``, ``save`` should join lines with
    ``\\r\\n`` even though the buffer uses ``\\n`` internally."""
    var dir = String("/tmp/turbokod_ec_eol_") + String(
        Int(external_call["getpid", Int32]())
    )
    _ = external_call["mkdir", Int32](
        (dir + String("\0")).unsafe_ptr(), UInt32(0o755),
    )
    var ec_path = dir + String("/.editorconfig")
    assert_true(write_file(ec_path, String(
        "root = true\n[*]\nend_of_line = crlf\n"
    )))
    var f_path = dir + String("/x.txt")
    assert_true(write_file(f_path, String("a\nb")))
    var ed = Editor.from_file(f_path)
    assert_equal(ed.editorconfig.end_of_line, String("crlf"))
    assert_true(ed.save())
    var got = read_file(f_path)
    assert_equal(got, String("a\r\nb"))
    _ = external_call["unlink", Int32]((f_path + String("\0")).unsafe_ptr())
    _ = external_call["unlink", Int32]((ec_path + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((dir + String("\0")).unsafe_ptr())


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
    var matches = find_in_project(root.value(), String("Turbokod: a Mojo-idiomatic port"))
    assert_true(len(matches) >= 1)
    var found_in_init = False
    for i in range(len(matches)):
        if matches[i].rel == String("src/turbokod/__init__.mojo"):
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
    var path_a = _temp_path(String("_cascade_a.txt"))
    var path_b = _temp_path(String("_cascade_b.txt"))
    var path_c = _temp_path(String("_cascade_c.txt"))
    assert_true(write_file(path_a, String("a\n")))
    assert_true(write_file(path_b, String("b\n")))
    assert_true(write_file(path_c, String("c\n")))
    var d = Desktop()
    d.open_file(path_a, _SCREEN)
    d.open_file(path_b, _SCREEN)
    d.open_file(path_c, _SCREEN)
    var ws = d.workspace_rect(_SCREEN)
    assert_equal(d.windows.windows[0].rect.a.x, ws.a.x + 0)
    assert_equal(d.windows.windows[0].rect.a.y, ws.a.y + 0)
    assert_equal(d.windows.windows[1].rect.a.x, ws.a.x + 1)
    assert_equal(d.windows.windows[1].rect.a.y, ws.a.y + 1)
    assert_equal(d.windows.windows[2].rect.a.x, ws.a.x + 2)
    assert_equal(d.windows.windows[2].rect.a.y, ws.a.y + 2)
    _ = external_call["unlink", Int32]((path_a + String("\0")).unsafe_ptr())
    _ = external_call["unlink", Int32]((path_b + String("\0")).unsafe_ptr())
    _ = external_call["unlink", Int32]((path_c + String("\0")).unsafe_ptr())


fn test_desktop_open_file_focuses_existing() raises:
    """Re-opening an already-open path focuses that window instead of
    creating a duplicate."""
    var path_a = _temp_path(String("_dedup_a.txt"))
    var path_b = _temp_path(String("_dedup_b.txt"))
    assert_true(write_file(path_a, String("a\n")))
    assert_true(write_file(path_b, String("b\n")))
    var d = Desktop()
    d.open_file(path_a, _SCREEN)
    d.open_file(path_b, _SCREEN)
    assert_equal(len(d.windows.windows), 2)
    assert_equal(d.windows.focused, 1)
    # Re-opening A should focus the existing window, not add a third.
    d.open_file(path_a, _SCREEN)
    assert_equal(len(d.windows.windows), 2)
    assert_equal(d.windows.focused, 0)
    _ = external_call["unlink", Int32]((path_a + String("\0")).unsafe_ptr())
    _ = external_call["unlink", Int32]((path_b + String("\0")).unsafe_ptr())


fn test_desktop_open_file_inherits_maximize_state() raises:
    var path_a = _temp_path(String("_maxinh_a.txt"))
    var path_b = _temp_path(String("_maxinh_b.txt"))
    assert_true(write_file(path_a, String("m\n")))
    assert_true(write_file(path_b, String("n\n")))
    var d = Desktop()
    d.open_file(path_a, _SCREEN)
    # Maximize the first window, then open a second (different) file.
    d.windows.windows[0].toggle_maximize(d.workspace_rect(_SCREEN))
    assert_true(d.windows.windows[0].is_maximized)
    d.open_file(path_b, _SCREEN)
    # The new window inherits maximized mode but its restore rect is the
    # 80% cascade slot (so toggling brings it back to the right size).
    assert_true(d.windows.windows[1].is_maximized)
    var ws = d.workspace_rect(_SCREEN)
    assert_true(d.windows.windows[1].rect == ws)
    assert_equal(
        d.windows.windows[1]._restore_rect.width(), (ws.width() * 80) // 100,
    )
    assert_equal(d.windows.windows[1]._restore_rect.a.x, ws.a.x + 1)
    _ = external_call["unlink", Int32]((path_a + String("\0")).unsafe_ptr())
    _ = external_call["unlink", Int32]((path_b + String("\0")).unsafe_ptr())


fn test_desktop_new_file_creates_untitled_editor_window() raises:
    """``new_file`` opens an empty editor with no backing path so Save
    falls through to Save As, and successive calls get unique titles."""
    var d = Desktop()
    d.new_file(_SCREEN)
    assert_equal(len(d.windows.windows), 1)
    assert_true(d.windows.windows[0].is_editor)
    assert_equal(d.windows.windows[0].title, String("Untitled"))
    assert_equal(d.windows.windows[0].editor.file_path, String(""))
    assert_equal(d.windows.windows[0].editor.buffer.line_count(), 1)
    assert_equal(d.windows.windows[0].editor.buffer.line(0), String(""))
    d.new_file(_SCREEN)
    assert_equal(len(d.windows.windows), 2)
    assert_equal(d.windows.windows[1].title, String("Untitled 2"))


fn test_desktop_dispatch_editor_new_opens_window() raises:
    """The framework intercepts ``EDITOR_NEW`` so apps wired to the action
    don't need any extra handling for File → New."""
    var d = Desktop()
    var maybe = d.dispatch_action(EDITOR_NEW, _SCREEN)
    assert_false(Bool(maybe))                    # framework consumed the action
    assert_equal(len(d.windows.windows), 1)
    assert_true(d.windows.windows[0].is_editor)
    assert_equal(d.windows.windows[0].editor.file_path, String(""))


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
    # No project: dispatch is a no-op (the modal stays closed).
    _ = d.dispatch_action(PROJECT_FIND, _SCREEN)
    assert_false(d.project_find.active)
    # With a project: the fullscreen find UI opens.
    d.detect_project_from(String("examples/hello.mojo"))
    _ = d.dispatch_action(PROJECT_FIND, _SCREEN)
    assert_true(d.project_find.active)


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


fn test_window_manager_rotate_focus_cycles_in_stable_order() raises:
    """Cmd+` rotation walks the windows in insertion order and wraps
    past the end. Reverse rotation walks the same sequence backwards."""
    var wm = WindowManager()
    wm.add(Window(String("a"), Rect(0, 1, 20, 5), List[String]()))
    wm.add(Window(String("b"), Rect(0, 1, 20, 5), List[String]()))
    wm.add(Window(String("c"), Rect(0, 1, 20, 5), List[String]()))
    wm.focus_by_index(0)
    wm.rotate_focus(True)
    assert_equal(wm.focused, 1)
    wm.rotate_focus(True)
    assert_equal(wm.focused, 2)
    # Wrap past the end.
    wm.rotate_focus(True)
    assert_equal(wm.focused, 0)
    # Reverse rotation wraps before the start.
    wm.rotate_focus(False)
    assert_equal(wm.focused, 2)
    wm.rotate_focus(False)
    assert_equal(wm.focused, 1)
    # Rotation also raises the new window to the top of z-order so a
    # subsequent click-through sees the same window the user is editing.
    assert_equal(wm.z_order[len(wm.z_order) - 1], 1)


fn test_window_manager_rotate_focus_noop_when_fewer_than_two_windows() raises:
    """Rotation must do nothing when there's nothing to rotate to —
    no crash, no spurious focus change."""
    var wm0 = WindowManager()
    wm0.rotate_focus(True)  # zero windows: just don't crash
    assert_equal(wm0.focused, -1)
    var wm1 = WindowManager()
    wm1.add(Window(String("only"), Rect(0, 1, 20, 5), List[String]()))
    wm1.rotate_focus(True)
    assert_equal(wm1.focused, 0)
    wm1.rotate_focus(False)
    assert_equal(wm1.focused, 0)


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


fn test_dropdown_reserves_indent_for_checkable_items() raises:
    """A dropdown that contains any checkable item must reserve a 2-cell
    label-indent so the ``✓`` glyph slot is consistent across rows.
    ``set_item_checked`` flips state by action without disturbing the
    rest of the menu."""
    var bar = MenuBar()
    var items = List[MenuItem]()
    items.append(MenuItem(
        String("Line Numbers"), String("view:ln"), checkable=True,
    ))
    items.append(MenuItem(
        String("Soft Wrap"), String("view:sw"), checkable=True,
    ))
    bar.add(Menu(String("View"), items^))
    bar.open_idx = 0
    assert_true(bar._menu_has_checkable(0))
    var dr = bar._dropdown_rect(80)
    var widest_label = len(String("Line Numbers").as_bytes())
    # 2 (left pad) + 2 (checkbox slot) + label + 2 (right pad)
    var expected_min_w = widest_label + 6
    assert_true(dr.b.x - dr.a.x >= expected_min_w)
    bar.set_item_checked(String("view:ln"), True)
    assert_true(bar.menus[0].items[0].checked)
    assert_false(bar.menus[0].items[1].checked)
    bar.set_item_checked(String("view:ln"), False)
    assert_false(bar.menus[0].items[0].checked)


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


fn test_parse_csi_modify_other_keys_cmd_shift_f_folds_onto_ctrl_shift_f() raises:
    """``ESC[27;10;102~`` is the meta-bit form (mod = 1 + 1 + 8) of
    Cmd+Shift+F. The framework treats Cmd as Ctrl across the board, so
    this collapses to ``(ord('f'), MOD_CTRL|MOD_SHIFT)`` — the exact
    event Ctrl+Shift+F produces, so a single hotkey registration covers
    both modifier flavors. Without this fold the keystroke fell through
    to the focused editor and got typed as 'f'."""
    var ev = parse_input(String("\x1b[27;10;102~"))
    assert_true(ev[0].kind == EVENT_KEY)
    assert_equal(Int(ev[0].key), Int(ord("f")))
    assert_true((ev[0].mods & MOD_CTRL) != 0)
    assert_true((ev[0].mods & MOD_SHIFT) != 0)
    assert_true((ev[0].mods & MOD_META) == 0)


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


fn test_parse_osc_open_path_emits_event_open_path() raises:
    """The native wrapper forwards a second-instance argv as ``OSC 2;
    __mvc_open:<path> BEL``. The terminal parser must recognise it, emit
    EVENT_OPEN_PATH carrying the path, and consume the entire sequence.
    """
    var s = String("\x1b]2;__mvc_open:/Users/me/foo.txt\x07")
    var ev = parse_input(s)
    assert_true(ev[0].kind == EVENT_OPEN_PATH)
    assert_equal(ev[0].text, String("/Users/me/foo.txt"))
    assert_equal(ev[1], len(s.as_bytes()))


fn test_parse_osc_open_path_with_line_suffix() raises:
    """The wrapper appends ``\\x1f<line>`` to the path when translating
    a ``turbokod://open?...&line=N`` URL. Path comes through clean and
    ``ev.pos.y`` carries the 1-based line number; without the suffix
    ``ev.pos.y`` defaults to 0 (the base case)."""
    var s = String("\x1b]2;__mvc_open:/Users/me/foo.py\x1f277\x07")
    var ev = parse_input(s)
    assert_true(ev[0].kind == EVENT_OPEN_PATH)
    assert_equal(ev[0].text, String("/Users/me/foo.py"))
    assert_equal(ev[0].pos.y, 277)
    assert_equal(ev[1], len(s.as_bytes()))


fn test_parse_osc_open_path_st_terminator() raises:
    """OSC's other valid terminator is ``ESC \\``. We must accept both;
    xterm style guides recommend it for any payload that might contain a
    BEL byte (paths can't, but the parser shouldn't care about that)."""
    var s = String("\x1b]2;__mvc_open:/tmp/x\x1b\\")
    var ev = parse_input(s)
    assert_true(ev[0].kind == EVENT_OPEN_PATH)
    assert_equal(ev[0].text, String("/tmp/x"))
    assert_equal(ev[1], len(s.as_bytes()))


fn test_parse_osc_unknown_is_consumed_silently() raises:
    """Unrecognised OSC (window-title sets, palette queries, etc.) must
    be swallowed — leaking the trailing bytes through the generic ESC
    handler would emit an ``Alt+]`` keypress and corrupt the editor."""
    var s = String("\x1b]0;some title\x07")
    var ev = parse_input(s)
    assert_true(ev[0].kind == EVENT_NONE)
    assert_equal(ev[1], len(s.as_bytes()))


fn test_parse_osc_partial_defers() raises:
    """Without a terminator yet, parse_input should signal "not enough
    data" via (EVENT_NONE, 0) so Terminal.poll_event saves the bytes for
    the next read instead of misinterpreting them."""
    var s = String("\x1b]2;__mvc_open:/half-")
    var ev = parse_input(s)
    assert_true(ev[0].kind == EVENT_NONE)
    assert_equal(ev[1], 0)


fn test_parse_csi_modify_other_keys_cmd_letter_folds_onto_ctrl_form() raises:
    """``ESC[27;9;115~`` is the meta-bit form (mod = 1 + 8) of Cmd+S that
    the native Rust host emits for ``super_key()``. The framework folds
    it onto the same ``(0x13, MOD_NONE)`` event that Ctrl+S produces, so
    a single hotkey registration covers both modifiers."""
    var ev = parse_input(String("\x1b[27;9;115~"))
    assert_true(ev[0].kind == EVENT_KEY)
    assert_equal(Int(ev[0].key), 0x13)
    assert_equal(Int(ev[0].mods), Int(MOD_NONE))


fn test_parse_csi_modify_other_keys_cmd_backtick_keeps_key_intact() raises:
    """Cmd+\\` arrives as ``ESC[27;9;96~`` (mod=9 → meta-only, cp=0x60).
    Backtick is *not* a letter, so the Ctrl+letter→control-byte fold
    must skip it — otherwise it would collapse to ``(0, MOD_NONE)``,
    indistinguishable from KEY_NONE. The event must keep its 0x60 key
    code with the META→CTRL fold preserved on ``mods`` so hotkey
    tables can bind to ``(ord('\\`'), MOD_CTRL)``."""
    var ev = parse_input(String("\x1b[27;9;96~"))
    assert_true(ev[0].kind == EVENT_KEY)
    assert_equal(Int(ev[0].key), 0x60)
    assert_equal(Int(ev[0].mods), Int(MOD_CTRL))


fn test_cmd_s_via_modify_other_keys_triggers_save_hotkey() raises:
    """End-to-end: a Cmd+S event delivered as ``CSI 27;9;115~`` is folded
    by the terminal parser onto Ctrl+S and triggers ``EDITOR_SAVE`` —
    same dispatch as if the user had pressed Ctrl+S."""
    var d = Desktop()
    var parsed = parse_input(String("\x1b[27;9;115~"))
    assert_true(parsed[0].kind == EVENT_KEY)
    assert_equal(Int(parsed[0].key), 0x13)
    var maybe = d.handle_event(parsed[0], _SCREEN)
    # No editor focused → save is a no-op intercepted by Desktop. The
    # important assertion is that the action *was* recognized: nothing
    # bubbles back to the caller.
    assert_false(Bool(maybe))


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


fn test_downloadable_grammar_registry_has_elm() raises:
    """The seed entry — opening a ``.elm`` file is what triggers the
    download prompt in ``Desktop._maybe_prompt_grammar_install``."""
    var specs = built_in_downloadable_grammars()
    var idx = find_downloadable_grammar_for_extension(specs, String("elm"))
    assert_true(idx >= 0)
    assert_equal(specs[idx].language_id, String("elm"))
    assert_equal(specs[idx].display, String("Elm"))
    var by_lang = find_downloadable_grammar_by_language(specs, String("elm"))
    assert_equal(by_lang, idx)


fn test_downloadable_grammar_registry_misses_unknown() raises:
    """``txt`` shouldn't trigger a grammar prompt — keeps the prompt
    machinery from firing on every file the user opens."""
    var specs = built_in_downloadable_grammars()
    var idx = find_downloadable_grammar_for_extension(specs, String("txt"))
    assert_equal(idx, -1)


fn test_grammar_install_command_targets_user_config() raises:
    """The shell command must mkdir the per-language dir and curl the
    grammar JSON to the path the highlighter probes
    (``user_grammar_path_for_ext``). Verified by string-match because
    the runner is a shell pipeline; the alternative is end-to-end with
    a fake server, which adds infrastructure with no payoff."""
    var specs = built_in_downloadable_grammars()
    var idx = find_downloadable_grammar_by_language(specs, String("elm"))
    assert_true(idx >= 0)
    var cmd = grammar_install_command(String("elm"), specs[idx].url)
    var dest = user_grammar_path(String("elm"))
    # If $HOME is set the destination path will be embedded; if not,
    # the helper produces an empty path and we just check ``mkdir -p``
    # still appears (the runner would fail in that case, which is the
    # correct end state for a sandboxed process with no $HOME).
    assert_true(_contains(cmd, String("mkdir -p")))
    assert_true(_contains(cmd, String("curl ")))
    if len(dest.as_bytes()) > 0:
        assert_true(_contains(cmd, dest))


fn test_user_grammar_path_for_ext_misses_when_not_installed() raises:
    """When no user grammar is on disk, the helper returns empty so
    ``_grammar_path_for_ext`` falls through to the generic per-language
    fallback rather than handing the loader a non-existent path."""
    # Elm has a registry entry, but unless the test environment
    # happens to have ~/.config/turbokod/languages/elm/elm.tmLanguage.json
    # already (vanishingly unlikely on CI), the helper must report it
    # as not installed.
    var path = user_grammar_path(String("elm"))
    if len(path.as_bytes()) > 0 and stat_file(path).ok:
        # Test environment already has Elm installed — the helper must
        # at least return a non-empty path.
        assert_true(len(user_grammar_path_for_ext(String("elm")).as_bytes()) > 0)
    else:
        assert_equal(user_grammar_path_for_ext(String("elm")), String(""))
    # Unknown extensions always return empty regardless of disk state.
    assert_equal(user_grammar_path_for_ext(String("zzz")), String(""))


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
    """Multi-line triple-quoted strings keep highlight state across rows.
    A docstring (triple-quoted string at statement position) is painted
    with the comment attr; an inline triple-quoted string keeps the
    string attr."""
    var lines = _hl_lines(
        String("\"\"\"docstring start"),
        String("middle line"),
        String("end of docstring\"\"\""),
        String("def f(): pass"),
    )
    var hls = highlight_for_extension(String("py"), lines)
    var have_row_0 = False
    var have_row_1 = False
    var have_row_2 = False
    for i in range(len(hls)):
        if hls[i].attr == highlight_comment_attr():
            if hls[i].row == 0: have_row_0 = True
            if hls[i].row == 1: have_row_1 = True
            if hls[i].row == 2: have_row_2 = True
    assert_true(have_row_0)
    assert_true(have_row_1)
    assert_true(have_row_2)
    # Row 3 (``def f(): pass``) must come back to plain code: ``def`` is
    # a keyword. The previous version of this test used ``var x = 1``,
    # left over from when Python and Mojo shared a bespoke tokenizer
    # that recognized both keyword sets — Python's grammar (rightly)
    # has no notion of ``var``, so that line produced no keyword
    # highlights and silently broke the docstring-close check.
    var saw_kw = False
    for i in range(len(hls)):
        if hls[i].row == 3 and hls[i].attr == highlight_keyword_attr():
            saw_kw = True
    assert_true(saw_kw)

    # Inline triple-quoted string: not at statement position, stays a string.
    var inline = _hl_lines(String("s = \"\"\"hi\"\"\""))
    var ihls = highlight_for_extension(String("py"), inline)
    var saw_inline_string = False
    for i in range(len(ihls)):
        if ihls[i].attr == highlight_string_attr():
            saw_inline_string = True
    assert_true(saw_inline_string)


fn test_highlight_unknown_extension_returns_empty() raises:
    var lines = _hl_lines(String("fn main():"), String("  pass"))
    var hls = highlight_for_extension(String("txt"), lines)
    assert_equal(len(hls), 0)


fn test_highlight_rust_keywords_strings_comments() raises:
    """The generic registry-driven tokenizer paints C-family files with
    the same attr palette as the Mojo/Python path: a ``var`` keyword,
    ``"hi"`` string, ``// note`` line comment, ``42`` number. Routed
    through ``.zig`` (Zig is still on the generic path — no bundled
    TextMate grammar) so this test stays focused on the generic
    tokenizer, not the TextMate runtime."""
    var lines = _hl_lines(
        String("fn main() {"),
        String("    var s = \"hi\"  // note"),
        String("    var n = 42"),
        String("}"),
    )
    var hls = highlight_for_extension(String("zig"), lines)
    var saw_var_kw = False
    var saw_string = False
    var saw_comment = False
    var saw_number = False
    for i in range(len(hls)):
        var h = hls[i]
        if h.row == 1 and h.col_start == 4 and h.col_end == 7 \
                and h.attr == highlight_keyword_attr():
            saw_var_kw = True
        if h.row == 1 and h.attr == highlight_string_attr():
            saw_string = True
        if h.row == 1 and h.attr == highlight_comment_attr():
            saw_comment = True
        if h.row == 2 and h.attr == highlight_number_attr():
            saw_number = True
    assert_true(saw_var_kw)
    assert_true(saw_string)
    assert_true(saw_comment)
    assert_true(saw_number)


fn test_highlight_rust_block_comment_spans_lines() raises:
    """A ``/* ... */`` block comment that opens on one row and closes on
    a later row keeps every row in between painted as comment. State is
    threaded through ``_highlight_generic`` the same way triple-quoted
    strings are threaded through the Mojo/Python tokenizer. Targets
    a generic-path extension to keep this test off the TextMate route.

    Zig doesn't actually have ``/* ... */`` block comments, but the
    spec's ``block_open``/``block_close`` are empty for Zig. Use the
    ``.cpp``... wait, ``.cpp`` now goes through TextMate too. Use
    ``.kt`` (Kotlin) — generic-path C-family with ``/*..*/``."""
    var lines = _hl_lines(
        String("/* opening line"),
        String("middle line"),
        String("end */ var x = 1"),
    )
    var hls = highlight_for_extension(String("kt"), lines)
    var have_0 = False
    var have_1 = False
    var have_2 = False
    for i in range(len(hls)):
        if hls[i].attr == highlight_comment_attr():
            if hls[i].row == 0: have_0 = True
            if hls[i].row == 1: have_1 = True
            if hls[i].row == 2: have_2 = True
    assert_true(have_0)
    assert_true(have_1)
    assert_true(have_2)
    # Past the closing ``*/`` the tokenizer must be back to normal: ``let``
    # comes back as a keyword and ``1`` as a number.
    var saw_let = False
    var saw_number = False
    for i in range(len(hls)):
        if hls[i].row == 2 and hls[i].attr == highlight_keyword_attr():
            saw_let = True
        if hls[i].row == 2 and hls[i].attr == highlight_number_attr():
            saw_number = True
    assert_true(saw_let)
    assert_true(saw_number)


fn test_onig_basic_search() raises:
    """Sanity-check the libonig FFI: compile a regex and find a match.
    This is the foundation the TextMate-grammar highlighter will sit
    on top of — if it breaks we want a clear test failure, not a
    cryptic crash inside the grammar runtime."""
    onig_global_init()
    var rx = OnigRegex(String("hel+o"))
    var m = rx.search(String("say hellllo world"))
    var got = False
    if m:
        got = True
        assert_equal(m.value().start, 4)
        assert_equal(m.value().end, 11)
    assert_true(got)


fn test_onig_no_match_returns_none() raises:
    """The Optional API surfaces no-match as ``None`` (not as a
    sentinel match with ``start < 0``), matching the rest of the
    codebase's error idioms."""
    onig_global_init()
    var rx = OnigRegex(String("xyz+"))
    var m = rx.search(String("abc def"))
    var got = False
    if m:
        got = True
    assert_true(not got)


fn test_onig_search_at_offset() raises:
    """``search_at(start)`` skips the first match if it falls before
    ``start`` — this is what the grammar runtime needs for ``\\G``
    continuation in ``begin``/``while`` rules."""
    onig_global_init()
    var rx = OnigRegex(String("ab"))
    var hay = String("abXYZab")
    var first = rx.search(hay)
    var first_ok = False
    if first:
        first_ok = True
        assert_equal(first.value().start, 0)
    assert_true(first_ok)
    var second = rx.search_at(hay, 1)
    var second_ok = False
    if second:
        second_ok = True
        assert_equal(second.value().start, 5)
    assert_true(second_ok)


fn test_textmate_rust_grammar_paints_keywords_and_strings() raises:
    """Loading the bundled Rust TextMate grammar and tokenizing a
    small snippet produces keyword / string / comment / number
    highlights at the expected scopes. This is the integration test
    that proves the JSON loader, the regex FFI, the tokenizer, and
    the scope→Attr mapping all line up.

    We assert presence (at least one of each kind) rather than exact
    span offsets — those will shift as the bundled grammar grows.
    """
    var lines = _hl_lines(
        String("fn main() {"),
        String("    let s = \"hi\";  // note"),
        String("    let n = 42;"),
        String("}"),
    )
    var hls = highlight_for_extension(String("rs"), lines)
    var saw_keyword = False
    var saw_string = False
    var saw_comment = False
    var saw_number = False
    for i in range(len(hls)):
        var a = hls[i].attr
        if a == highlight_keyword_attr():
            saw_keyword = True
        if a == highlight_string_attr():
            saw_string = True
        if a == highlight_comment_attr():
            saw_comment = True
        if a == highlight_number_attr():
            saw_number = True
    assert_true(saw_keyword)
    assert_true(saw_string)
    assert_true(saw_comment)
    assert_true(saw_number)


fn test_textmate_brackets_paint_as_operators() raises:
    """``()`` / ``[]`` / ``{}`` must be painted with the operator attr
    in TextMate-tokenized files. The vendored Python grammar doesn't
    tag brackets at all, so without the post-pass they fall through
    uncolored — the bug this test guards against.

    We assert positively (each bracket has an operator highlight) and
    negatively (a bracket inside a string keeps the string color, not
    the operator color)."""
    var lines = _hl_lines(
        String("def f(a, b): return a + [1, 2, 3][0]"),
        String("s = \"(not an operator)\""),
    )
    var hls = highlight_for_extension(String("py"), lines)
    var op_attr = highlight_operator_attr()
    var str_attr = highlight_string_attr()
    var line0 = lines[0]
    var b0 = line0.as_bytes()
    # Every bracket on row 0 outside any string scope: ``(``, ``)``,
    # ``[`` (after ``+``), ``]``, ``[`` (the index), ``]`` (the index).
    # Last-writer wins (mirrors how the editor paints overlapping
    # highlights) so we walk all matches and keep the latest.
    for i in range(len(b0)):
        var c = Int(b0[i])
        if c != 0x28 and c != 0x29 and c != 0x5B and c != 0x5D \
                and c != 0x7B and c != 0x7D:
            continue
        var got = Attr(0, 0)
        var found = False
        for hi in range(len(hls)):
            var h = hls[hi]
            if h.row == 0 and h.col_start <= i and i < h.col_end:
                got = h.attr
                found = True
        assert_true(found)
        assert_true(got == op_attr)

    # Row 1 has ``"(not an operator)"`` — the parens are inside the
    # string scope and should keep the string color (we don't
    # overpaint inside strings).
    var line1 = lines[1]
    var b1 = line1.as_bytes()
    for i in range(len(b1)):
        var c = Int(b1[i])
        if c != 0x28 and c != 0x29:
            continue
        var got = Attr(0, 0)
        var found = False
        for hi in range(len(hls)):
            var h = hls[hi]
            if h.row == 1 and h.col_start <= i and i < h.col_end:
                got = h.attr
                found = True
        assert_true(found)
        assert_true(got == str_attr)


fn _hl_set(hls: List[Highlight]) -> List[Highlight]:
    """Sort-of-canonicalize a Highlight list: sort by (row, col_start,
    col_end). Two passes that agree should produce equal lists post-sort
    even if they emit highlights in slightly different orders."""
    var sorted = List[Highlight]()
    for i in range(len(hls)):
        sorted.append(hls[i])
    # Insertion sort — lists are small (a few thousand entries) and we
    # don't want to pull in a generic sort dependency.
    for i in range(1, len(sorted)):
        var j = i
        while j > 0:
            var a = sorted[j - 1]
            var b = sorted[j]
            var swap = False
            if a.row > b.row:
                swap = True
            elif a.row == b.row:
                if a.col_start > b.col_start:
                    swap = True
                elif a.col_start == b.col_start and a.col_end > b.col_end:
                    swap = True
            if not swap:
                break
            sorted[j - 1] = b
            sorted[j] = a
            j -= 1
    return sorted^


fn test_textmate_incremental_matches_full_retokenize() raises:
    """The incremental tokenizer must produce the same highlights as a
    full re-run when given the same buffer + a dirty-row hint. We
    exercise both shapes of edit:

    * a token-level change (adding a comment to one line) — tokenizer
      state at end of the line is unchanged, early-exit fires
      immediately.
    * a scope-changing change (opening a block comment that doesn't
      close on the same line) — tokenizer state changes, and the
      incremental path keeps re-tokenizing until either the state
      rejoins the cached trajectory or the buffer ends.

    In both cases the resulting Highlight list should be byte-for-byte
    identical to a full retokenize of the same buffer.
    """
    var lines = List[String]()
    lines.append(String("fn main() {"))
    lines.append(String("    let s = \"hello\";"))
    lines.append(String("    let n = 42;"))
    lines.append(String("    return;"))
    lines.append(String("}"))
    lines.append(String(""))
    lines.append(String("fn other() { 1 }"))

    # Warm the registry + per-Editor state with a full pass.
    var registry = GrammarRegistry()
    var cache = HighlightCache()
    var _ = highlight_incremental(
        String("rs"), lines, 0, registry, cache,
    )

    # Token-level edit on row 1: append a line comment.
    lines[1] = lines[1] + String(" // note")
    var incr_a = highlight_incremental(
        String("rs"), lines, 1, registry, cache,
    )
    var full_a = highlight_for_extension(String("rs"), lines)
    var s_incr_a = _hl_set(incr_a)
    var s_full_a = _hl_set(full_a)
    assert_equal(len(s_incr_a), len(s_full_a))
    for i in range(len(s_incr_a)):
        assert_equal(s_incr_a[i].row, s_full_a[i].row)
        assert_equal(s_incr_a[i].col_start, s_full_a[i].col_start)
        assert_equal(s_incr_a[i].col_end, s_full_a[i].col_end)

    # Scope-changing edit on row 2: open a block comment that the
    # rest of the buffer is now inside.
    lines[2] = String("    /* let n = 42;")
    var incr_b = highlight_incremental(
        String("rs"), lines, 2, registry, cache,
    )
    var full_b = highlight_for_extension(String("rs"), lines)
    var s_incr_b = _hl_set(incr_b)
    var s_full_b = _hl_set(full_b)
    assert_equal(len(s_incr_b), len(s_full_b))
    for i in range(len(s_incr_b)):
        assert_equal(s_incr_b[i].row, s_full_b[i].row)
        assert_equal(s_incr_b[i].col_start, s_full_b[i].col_start)
        assert_equal(s_incr_b[i].col_end, s_full_b[i].col_end)


fn test_textmate_html_embeds_css_inside_style_block() raises:
    """The HTML grammar's ``<style>`` block embeds CSS via
    ``include: "source.css"`` inside a ``(?!\\G)``-gated begin/end.
    Our loader follows the include into the bundled CSS grammar
    (``_path_for_scope`` mapping); our tokenizer's ``\\G``-anchor
    handling makes the ``(?!\\G)`` fire on a fresh line so the CSS
    body actually gets tokenized.

    Verifies end-to-end: a CSS-body line inside ``<style>`` should
    produce more highlights than the surrounding ``<style>`` /
    ``</style>`` tag-only rows, indicating CSS grammar patterns
    fired against the body.
    """
    # Standalone CSS sanity check.
    var css_lines = List[String]()
    css_lines.append(String(".cls { color: red; }"))
    var css_hls = highlight_for_extension(String("css"), css_lines)
    assert_true(len(css_hls) > 0)

    # HTML with an embedded CSS body. The body row should pick up
    # CSS-grammar highlights via the embed.
    var html_lines = List[String]()
    html_lines.append(String("<style>"))
    html_lines.append(String("  .cls { color: red; }"))
    html_lines.append(String("</style>"))
    var html_hls = highlight_for_extension(String("html"), html_lines)
    var row1_count = 0
    for i in range(len(html_hls)):
        if html_hls[i].row == 1:
            row1_count += 1
    # The body line gets multiple highlights from the CSS grammar
    # (selector, property, value, punctuation, etc.). A handful is
    # plenty to prove the embed fires; lots more is expected. We
    # don't pin to a specific count because the bundled grammar's
    # exact tokenization can shift across grammar updates.
    assert_true(row1_count >= 4)


fn test_textmate_capture_patterns_run_inside_group() raises:
    """A ``captures`` entry that carries its own ``patterns`` array
    re-tokenizes the captured byte range. We exercise this with a
    string literal grammar that captures the body of a quoted
    string and runs an escape-sequence pattern over it."""
    var grammar_json = String(
        "{\"scopeName\": \"source.test\", \"patterns\": ["
        "{\"match\": \"\\\"([^\\\"]*)\\\"\", "
        "\"name\": \"string.quoted.test\", "
        "\"captures\": {"
        "\"1\": {"
        "\"name\": \"string.body.test\", "
        "\"patterns\": ["
        "{\"match\": \"\\\\\\\\.\", \"name\": \"constant.character.escape.test\"}"
        "]"
        "}"
        "}}], \"repository\": {}}"
    )
    var g = load_grammar_from_string(grammar_json)
    var lines = List[String]()
    lines.append(String("\"a\\nb\""))
    var hls = tokenize_with_grammar(g, lines)
    # Expect: outer string scope spans the whole match (col 0..6),
    # plus an escape-character highlight at col 2..4 for the ``\n``.
    var saw_outer_string = False
    var saw_escape = False
    for i in range(len(hls)):
        var h = hls[i]
        if h.col_start == 0 and h.col_end == 6 \
                and h.attr == highlight_string_attr():
            saw_outer_string = True
        # ``constant.character.*`` maps to string_attr in our scope
        # mapping. The escape's col range (col 2..4 = ``\n``) lies
        # *inside* the outer string's range; the test only cares
        # that the escape's specific Highlight got emitted.
        if h.col_start == 2 and h.col_end == 4 \
                and h.attr == highlight_string_attr():
            saw_escape = True
    assert_true(saw_outer_string)
    assert_true(saw_escape)


fn test_textmate_while_rule_keeps_scope_open_per_line() raises:
    """``while``-rules: a ``begin`` opens a scope that stays open for
    every subsequent line whose start matches the ``while`` regex.
    Markdown blockquotes use this — every line beginning with ``>``
    is part of the quote, the first line that doesn't ends it.

    Hand-rolled grammar so we don't depend on an external grammar's
    quirks."""
    var grammar_json = String(
        "{\"scopeName\": \"source.test\", \"patterns\": ["
        "{\"begin\": \"^>\", \"while\": \"^>\", "
        "\"name\": \"markup.quote.test\", "
        "\"patterns\": ["
        "{\"match\": \"\\\\w+\", \"name\": \"keyword.control.test\"}"
        "]}], \"repository\": {}}"
    )
    var g = load_grammar_from_string(grammar_json)
    var lines = List[String]()
    lines.append(String("> first quoted line"))
    lines.append(String("> second quoted line"))
    lines.append(String("not in quote"))
    var hls = tokenize_with_grammar(g, lines)
    # Every quoted line should have the ``markup.quote`` scope painted
    # somewhere in its range. We map ``markup.*`` to the ident attr in
    # the bundled scope mapping (no specific markup mapping yet), but
    # the keyword patterns inside the quote should still highlight.
    var saw_kw_in_quote_0 = False
    var saw_kw_in_quote_1 = False
    var saw_kw_outside = False
    for i in range(len(hls)):
        var h = hls[i]
        if h.attr == highlight_keyword_attr():
            if h.row == 0:
                saw_kw_in_quote_0 = True
            elif h.row == 1:
                saw_kw_in_quote_1 = True
            elif h.row == 2:
                saw_kw_outside = True
    assert_true(saw_kw_in_quote_0)
    assert_true(saw_kw_in_quote_1)
    # Row 2 is outside the quote; the ``keyword`` pattern is nested
    # inside the begin/while scope, so it should *not* have fired
    # there.
    assert_true(not saw_kw_outside)


fn test_textmate_captures_overlay_on_match() raises:
    """A pattern with ``captures`` should emit the outer match scope
    plus a refined per-capture scope inside it. We exercise this
    against a hand-rolled grammar so the assertion is independent
    of whatever the bundled vscode rust grammar happens to do.

    The grammar matches ``fn <name>`` with the ``fn`` keyword as
    capture 1 (``keyword.control``) and the function name as
    capture 2 (``entity.name.function``). Both should produce
    distinct highlights at distinct byte ranges."""
    var grammar_json = String(
        "{\"scopeName\": \"source.test\", \"patterns\": ["
        "{\"match\": \"(fn)\\\\s+(\\\\w+)\", "
        "\"name\": \"meta.function.test\", "
        "\"captures\": {"
        "\"1\": {\"name\": \"keyword.control.test\"}, "
        "\"2\": {\"name\": \"entity.name.function.test\"}"
        "}}], \"repository\": {}}"
    )
    var g = load_grammar_from_string(grammar_json)
    var lines = List[String]()
    lines.append(String("fn hello"))
    var hls = tokenize_with_grammar(g, lines)
    var keyword_at_0_2 = False
    var ident_at_3_8 = False
    for i in range(len(hls)):
        var h = hls[i]
        if h.row == 0 and h.col_start == 0 and h.col_end == 2 \
                and h.attr == highlight_keyword_attr():
            keyword_at_0_2 = True
        # ``entity.name.function`` maps to ident_attr in our scope
        # mapping; the function-name span is bytes 3..8.
        if h.row == 0 and h.col_start == 3 and h.col_end == 8 \
                and h.attr == highlight_ident_attr():
            ident_at_3_8 = True
    assert_true(keyword_at_0_2)
    assert_true(ident_at_3_8)


fn test_editor_default_text_is_light_green() raises:
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
    # ``focused=False`` so the cursor inversion (BLUE on YELLOW at
    # the cursor position) doesn't fight the default-attr probe.
    ed.paint(c, Rect(0, 0, 20, 3), False)
    # Column 0 of an unhighlighted, plain-text buffer must carry
    # the new default.
    assert_equal(c.get(0, 0).attr.fg, LIGHT_GREEN)
    assert_equal(c.get(0, 0).attr.bg, BLUE)
    # Past EOL the trailing fill cells must also be the new default.
    assert_equal(c.get(15, 0).attr.fg, LIGHT_GREEN)
    assert_equal(c.get(15, 0).attr.bg, BLUE)


fn test_textmate_all_bundled_grammars_load() raises:
    """Every grammar bundled under ``src/turbokod/grammars/`` should
    parse, compile its regexes through libonig, and produce *some*
    highlights for a tiny representative snippet. This catches
    breakages from grammar updates that introduce regex syntax
    libonig rejects, or pattern shapes our runtime doesn't handle.

    The assertion is intentionally loose — we just want non-empty
    output, not specific scopes — so adding a new grammar doesn't
    require a hand-tuned test alongside it."""
    # extension, sample-line that should produce at least one highlight.
    var probes = List[Tuple[String, String]]()
    probes.append((String("rs"),   String("fn main() {}")))
    probes.append((String("go"),   String("package main")))
    probes.append((String("ts"),   String("const x: number = 1;")))
    probes.append((String("js"),   String("const x = 1;")))
    probes.append((String("cpp"),  String("int main() { return 0; }")))
    probes.append((String("sh"),   String("if [ -f x ]; then echo y; fi")))
    probes.append((String("html"), String("<html><body>hi</body></html>")))
    probes.append((String("css"),  String(".cls { color: red; }")))
    probes.append((String("json"), String("{\"a\": 1}")))
    probes.append((String("diff"), String("-removed line")))
    # ``while``-rule grammars: now wired through our runtime once
    # ``PATTERN_BEGIN_WHILE`` was added. Light smoke probes — the
    # while-rule semantics get a dedicated test below.
    probes.append((String("rb"),   String("def hi; \"hi\"; end")))
    probes.append((String("yaml"), String("key: value")))
    for i in range(len(probes)):
        var ext = probes[i][0]
        var sample = probes[i][1]
        var lines = List[String]()
        lines.append(sample)
        var hls = highlight_for_extension(ext, lines)
        # ``len(hls) > 0`` is the loose contract: each grammar's
        # snippet was hand-picked to contain at least one obviously
        # colorable token (keyword, string, comment, etc.).
        if len(hls) == 0:
            print("no highlights produced for extension: " + ext)
        assert_true(len(hls) > 0)


fn test_textmate_json_grammar_paints_strings_and_numbers() raises:
    """Adding a new language is just a grammar JSON drop-in plus an
    entry in ``_grammar_path_for_ext``. Verify the JSON grammar
    kicks in for ``.json`` files: keys + values render as strings,
    numeric literals as numbers, ``true`` / ``false`` as keywords."""
    var lines = _hl_lines(
        String("{"),
        String("  \"name\": \"value\","),
        String("  \"count\": 42,"),
        String("  \"flag\": true"),
        String("}"),
    )
    var hls = highlight_for_extension(String("json"), lines)
    var saw_string = False
    var saw_number = False
    var saw_keyword = False
    for i in range(len(hls)):
        var a = hls[i].attr
        if a == highlight_string_attr():
            saw_string = True
        if a == highlight_number_attr():
            saw_number = True
        if a == highlight_keyword_attr():
            saw_keyword = True
    assert_true(saw_string)
    assert_true(saw_number)
    assert_true(saw_keyword)


fn test_textmate_rust_block_comment_spans_lines() raises:
    """The TextMate runtime threads its scope stack across lines, so
    a ``/* ... */`` that opens on one line and closes on a later one
    paints every row in between as comment. This is the same
    behavior as the generic tokenizer's ``_HL_IN_BLOCK_COMMENT``
    state, but driven by the grammar's begin/end pattern."""
    var lines = _hl_lines(
        String("/* outer"),
        String("middle"),
        String("end */ let x = 1;"),
    )
    var hls = highlight_for_extension(String("rs"), lines)
    var have_0 = False
    var have_1 = False
    var have_2_comment = False
    var have_2_keyword = False
    for i in range(len(hls)):
        if hls[i].attr == highlight_comment_attr():
            if hls[i].row == 0: have_0 = True
            if hls[i].row == 1: have_1 = True
            if hls[i].row == 2: have_2_comment = True
        if hls[i].row == 2 and hls[i].attr == highlight_keyword_attr():
            have_2_keyword = True
    assert_true(have_0)
    assert_true(have_1)
    assert_true(have_2_comment)
    assert_true(have_2_keyword)


fn test_onig_invalid_pattern_raises() raises:
    """A malformed pattern surfaces as a ``raise`` from the
    constructor, with libonig's nonzero rc embedded in the message —
    enough to grep the source."""
    onig_global_init()
    var raised = False
    try:
        var _rx = OnigRegex(String("(unclosed"))
    except:
        raised = True
    assert_true(raised)


fn test_editor_refreshes_highlights_after_edits() raises:
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
    ed.flush_highlights(registry)
    assert_true(len(ed.highlights) == 0)
    _ = ed.handle_key(_key(UInt32(ord("f"))), _VIEW)
    _ = ed.handle_key(_key(UInt32(ord("n"))), _VIEW)
    ed.flush_highlights(registry)
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
    var registry = GrammarRegistry()
    ed.flush_highlights(registry)
    var canvas = Canvas(40, 5)
    canvas.fill(Rect(0, 0, 40, 5), String(" "), default_attr())
    ed.paint(canvas, Rect(0, 0, 40, 5), False)
    # ``fn`` lives at columns 0–1 with the keyword attr.
    assert_true(canvas.get(0, 0).attr == highlight_keyword_attr())
    assert_true(canvas.get(1, 0).attr == highlight_keyword_attr())
    # The space and the ``main`` identifier aren't keywords.
    assert_false(canvas.get(2, 0).attr == highlight_keyword_attr())
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


fn test_editor_alt_click_emits_definition_request() raises:
    # Cmd+click in iTerm2 is delivered to the app as Left+Alt — the editor
    # treats Alt+left-click as the goto-definition trigger.
    var ed = Editor(String("foo bar baz"))
    var ev = Event.mouse_event(
        Point(4, 0), MOUSE_BUTTON_LEFT,
        pressed=True, motion=False, mods=MOD_ALT,
    )
    _ = ed.handle_mouse(ev, Rect(0, 0, 40, 5))
    var req = ed.consume_definition_request()
    assert_true(Bool(req))
    var dr = req.value()
    assert_equal(dr.row, 0)
    assert_equal(dr.col, 4)
    assert_equal(dr.word, String("bar"))
    # The cursor must NOT have moved (Alt+click is non-mutating).
    assert_equal(ed.cursor_col, 0)
    # And the slot is consumed: a second poll returns empty.
    var req2 = ed.consume_definition_request()
    assert_false(Bool(req2))


fn test_editor_alt_click_outside_identifier_is_silent() raises:
    var ed = Editor(String("foo  bar"))
    # Click on the space between words.
    var ev = Event.mouse_event(
        Point(3, 0), MOUSE_BUTTON_LEFT,
        pressed=True, motion=False, mods=MOD_ALT,
    )
    _ = ed.handle_mouse(ev, Rect(0, 0, 40, 5))
    var req = ed.consume_definition_request()
    assert_false(Bool(req))


fn test_editor_gutter_click_emits_breakpoint_toggle() raises:
    # Line-number gutter on → 2 cells of gutter at the left edge. A
    # left-click there must surface as a pending breakpoint toggle for
    # the corresponding buffer row, without moving the cursor.
    var ed = Editor(String("alpha\nbeta\ngamma"))
    ed.line_numbers = True
    var ev = Event.mouse_event(
        Point(0, 1), MOUSE_BUTTON_LEFT,
        pressed=True, motion=False, mods=0,
    )
    _ = ed.handle_mouse(ev, Rect(0, 0, 40, 5))
    var req = ed.consume_breakpoint_toggle()
    assert_true(Bool(req))
    assert_equal(req.value(), 1)
    assert_equal(ed.cursor_row, 0)
    assert_equal(ed.cursor_col, 0)
    # Slot is one-shot.
    assert_false(Bool(ed.consume_breakpoint_toggle()))


fn test_editor_text_click_does_not_toggle_breakpoint() raises:
    # Click past the gutter — normal cursor placement, no toggle.
    var ed = Editor(String("alpha\nbeta\ngamma"))
    ed.line_numbers = True
    var ev = Event.mouse_event(
        Point(5, 1), MOUSE_BUTTON_LEFT,
        pressed=True, motion=False, mods=0,
    )
    _ = ed.handle_mouse(ev, Rect(0, 0, 40, 5))
    assert_false(Bool(ed.consume_breakpoint_toggle()))
    assert_equal(ed.cursor_row, 1)


fn test_editor_gutter_click_below_eof_is_ignored() raises:
    # Click in the gutter on a screen row past the last buffer line —
    # no breakpoint should be toggled (matches "click on empty space"
    # being a no-op for cursor placement, just without the cursor side
    # effect).
    var ed = Editor(String("alpha\nbeta"))
    ed.line_numbers = True
    var ev = Event.mouse_event(
        Point(0, 4), MOUSE_BUTTON_LEFT,
        pressed=True, motion=False, mods=0,
    )
    _ = ed.handle_mouse(ev, Rect(0, 0, 40, 6))
    assert_false(Bool(ed.consume_breakpoint_toggle()))


fn test_editor_gutter_drag_motion_does_not_toggle() raises:
    # Drag motion through the gutter must not flood pending toggles.
    var ed = Editor(String("alpha\nbeta\ngamma"))
    ed.line_numbers = True
    var ev = Event.mouse_event(
        Point(0, 1), MOUSE_BUTTON_LEFT,
        pressed=True, motion=True, mods=0,
    )
    _ = ed.handle_mouse(ev, Rect(0, 0, 40, 5))
    assert_false(Bool(ed.consume_breakpoint_toggle()))


fn test_quick_open_match_rules() raises:
    """Locked-in spec: the query is split on spaces into tokens, and each
    token is then split around every ``/`` (with ``/`` kept as its own
    one-byte part). Each part must appear as a case-insensitive substring
    of the path, in order."""
    var path = String("src/turbokod/cell.mojo")
    # `k/c` → parts ["k", "/", "c"] all present as substrings in order.
    assert_true(quick_open_match(path, String("k/c")))
    # Space-separated tokens — both substrings, in order.
    assert_true(quick_open_match(path, String("k c")))
    # `k/m` → "k" (in turbokod), "/" (after turbokod), "m" (in .mojo).
    assert_true(quick_open_match(path, String("k/m")))
    # `km/` → "km" then "/". "km" is not a substring of the path.
    assert_false(quick_open_match(path, String("km/")))

    # Multi-token across other shapes:
    assert_true(quick_open_match(String("job_call"),  String("j c")))
    assert_true(quick_open_match(String("jobCall"),   String("j c")))
    # Plain substring matching — `j` then `c` are both in "jack", in order.
    assert_true(quick_open_match(String("jack"),      String("j c")))

    # Empty query matches everything; tokens must keep their order.
    assert_true(quick_open_match(path, String("")))
    assert_false(quick_open_match(String("cell mojo"), String("mojo cell")))


fn test_quick_open_match_case_and_separator_shapes() raises:
    # Case-insensitive substring matching across mixed case.
    assert_true(quick_open_match(String("HelloWorld"), String("h w")))
    assert_true(quick_open_match(String("Helloworld"), String("h")))
    # Substrings can sit on either side of any separator byte.
    assert_true(quick_open_match(String("foo-bar.baz"), String("f b b")))
    # Path-segment boundaries via slashes — each token a substring in order.
    assert_true(quick_open_match(String("a/b/c"), String("a b c")))


fn test_quick_open_slash_in_query_requires_directory_separator() raises:
    """A space-separated query like ``foo bar`` matches when both ``foo``
    and ``bar`` appear as substrings of the path, in that order. A slash
    in the query — ``foo/bar`` — works the same way, except the slash
    itself is also a required substring between the two parts: it is
    equivalent to the three-part query ``foo`` / ``/`` / ``bar``, all
    matched as substrings in order. So ``foo/bar`` demands that ``foo``
    and ``bar`` straddle a real directory separator in the path.

    Worked example with ``pro/views``:

    * ``dryft/prospects/views.py`` — ``pro`` is in ``prospects``, then a
      ``/``, then ``views`` is in ``views.py``. Match.
    * ``dryft/homepage/cms/migrations/0003_snippet_preview_values.py`` —
      no segment contains ``pro`` (``preview_values`` has ``p``, ``r``,
      ``v``, ``i``, ``e``, ``w``, ``s`` only as a *subsequence*, not a
      contiguous substring; the literal text ``pro`` is absent), so the
      first part already fails. No match.
    """
    assert_true(quick_open_match(
        String("dryft/prospects/views.py"), String("pro/views"),
    ))
    assert_false(quick_open_match(
        String("dryft/homepage/cms/migrations/0003_snippet_preview_values.py"),
        String("pro/views"),
    ))


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
        if qo.entries[qo.matched[i]] == String("src/turbokod/editor.mojo"):
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


fn test_painter_clips_text_at_right_edge() raises:
    """Long text passed to ``Painter.put_text`` must not bleed past the
    clip's right edge — every cell beyond ``clip.b.x`` stays untouched."""
    var canvas = Canvas(20, 3)
    canvas.fill(Rect(0, 0, 20, 3), String("·"), Attr(BLACK, BLUE))
    var painter = Painter(Rect(2, 1, 8, 2))   # 6-cell wide clip
    _ = painter.put_text(
        canvas, Point(2, 1),
        String("ABCDEFGHIJKLMNOP"), Attr(BLACK, BLUE),
    )
    # Cells inside the clip get the letters; cells just outside on the
    # right keep their sentinel.
    assert_equal(canvas.get(2, 1).glyph, String("A"))
    assert_equal(canvas.get(7, 1).glyph, String("F"))
    assert_equal(canvas.get(8, 1).glyph, String("·"))   # right neighbour intact
    assert_equal(canvas.get(1, 1).glyph, String("·"))   # left neighbour intact
    # Drawing on a row outside the clip is a no-op.
    _ = painter.put_text(
        canvas, Point(2, 0),
        String("OUTSIDE"), Attr(BLACK, BLUE),
    )
    assert_equal(canvas.get(2, 0).glyph, String("·"))


fn test_painter_skips_codepoints_left_of_clip() raises:
    """When the start point is left of the clip, leading codepoints
    must be skipped one cell at a time (codepoint-aware) so the
    remaining glyphs land at the right visual columns. ``café WORLD``
    occupies cells 0..9; with the clip starting at cell 5, only
    ``WORLD`` should appear, at its expected columns."""
    var canvas = Canvas(20, 1)
    canvas.fill(Rect(0, 0, 20, 1), String("·"), Attr(BLACK, BLUE))
    var painter = Painter(Rect(5, 0, 15, 1))
    _ = painter.put_text(
        canvas, Point(0, 0),
        String("café WORLD"),
        Attr(BLACK, BLUE),
    )
    # Cells 0..4 left of clip stay sentinel.
    for x in range(5):
        assert_equal(canvas.get(x, 0).glyph, String("·"))
    # ``W``..``D`` land at cells 5..9 — same columns they would in an
    # unclipped paint, which is the whole point of codepoint-aware
    # skipping (a byte-stride skip would drop one extra cell from the
    # 2-byte ``é`` and shift everything left).
    assert_equal(canvas.get(5, 0).glyph, String("W"))
    assert_equal(canvas.get(6, 0).glyph, String("O"))
    assert_equal(canvas.get(9, 0).glyph, String("D"))
    # Cells 10..14 (still inside the clip) and 15+ (right of clip)
    # never got a glyph.
    assert_equal(canvas.get(10, 0).glyph, String("·"))
    assert_equal(canvas.get(15, 0).glyph, String("·"))


fn test_painter_fill_intersects_with_clip() raises:
    var canvas = Canvas(10, 5)
    canvas.fill(Rect(0, 0, 10, 5), String("·"), Attr(BLACK, BLUE))
    var painter = Painter(Rect(2, 1, 7, 4))
    # Caller-rect overhangs the clip; the fill is automatically trimmed.
    painter.fill(canvas, Rect(0, 0, 100, 100), String("#"), Attr(BLACK, BLUE))
    assert_equal(canvas.get(0, 0).glyph, String("·"))
    assert_equal(canvas.get(2, 1).glyph, String("#"))
    assert_equal(canvas.get(6, 3).glyph, String("#"))
    assert_equal(canvas.get(7, 3).glyph, String("·"))   # one past clip
    assert_equal(canvas.get(2, 4).glyph, String("·"))   # one below clip


fn test_dir_browser_long_name_does_not_overflow_listing() raises:
    """Regression: a directory entry far longer than the listing rect
    must not overwrite cells outside the rect, on any side. Drives the
    overflow with a 200-char synthetic entry — anything longer than
    the rect width would have leaked under the pre-Painter code only
    when callers forgot ``max_x``."""
    var canvas = Canvas(40, 5)
    var sentinel = Attr(BLACK, BLUE)
    canvas.fill(Rect(0, 0, 40, 5), String("·"), sentinel)
    var br = DirBrowser(False)
    br.entries = List[String]()
    br.entry_is_dir = List[Bool]()
    var huge = String("")
    for _ in range(200):
        huge = huge + String("X")
    br.entries.append(huge^)
    br.entry_is_dir.append(False)
    br.selected = 0
    var clip = Rect(5, 1, 15, 4)
    br.paint(canvas, clip, True)
    # Every cell outside the clip must still be the sentinel.
    for y in range(5):
        for x in range(40):
            var inside = (
                clip.a.x <= x and x < clip.b.x
                and clip.a.y <= y and y < clip.b.y
            )
            if not inside:
                assert_equal(canvas.get(x, y).glyph, String("·"))


fn test_file_dialog_lists_and_navigates() raises:
    var dlg = FileDialog()
    dlg.open(String("examples"))
    assert_true(dlg.active)
    # Should have at least ".." and a few example files.
    assert_true(len(dlg.browser.entries) >= 2)
    assert_equal(dlg.browser.entries[0], String(".."))
    # Navigate to second entry; arrow event-driven.
    _ = dlg.handle_key(Event.key_event(KEY_DOWN))
    assert_equal(dlg.browser.selected, 1)
    _ = dlg.handle_key(Event.key_event(KEY_UP))
    assert_equal(dlg.browser.selected, 0)


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


fn test_sgr_mouse_motion_no_button() raises:
    """Mouse-mode 1003 reports motion with no button held as raw button-bits
    ``3 | 32`` (35). The parser must surface that as MOUSE_BUTTON_NONE +
    motion=True; mapping it to RIGHT (the legacy bug) made every hover look
    like a phantom right-click."""
    var ev = parse_input(String("\x1b[<35;10;1M"))
    assert_true(ev[0].kind == EVENT_MOUSE)
    assert_true(ev[0].button == MOUSE_BUTTON_NONE)
    assert_true(ev[0].motion)
    assert_equal(ev[0].pos.x, 9)
    assert_equal(ev[0].pos.y, 0)


fn test_menu_hover_switches_open_menu() raises:
    """While a menu is open, hovering (button=NONE, motion=True) over a
    different menu in the bar switches the open menu to it. This is the
    macOS-style sticky behavior the user gets after a click-then-move."""
    var bar = MenuBar()
    var file_items = List[MenuItem]()
    file_items.append(MenuItem(String("Save"), EDITOR_SAVE))
    bar.add(Menu(String("File"), file_items^))
    var edit_items = List[MenuItem]()
    edit_items.append(MenuItem(String("Find"), EDITOR_FIND))
    bar.add(Menu(String("Edit"), edit_items^))
    bar.open_menu(0)
    var rects = bar._layout(80)
    var edit_x = (rects[1].a.x + rects[1].b.x) // 2
    var hover = Event.mouse_event(
        Point(edit_x, 0), MOUSE_BUTTON_NONE, True, True,
    )
    var r = bar.handle_event(hover, 80)
    assert_true(r.consumed)
    assert_equal(bar.open_idx, 1)


fn test_menu_drag_release_on_item_triggers() raises:
    """Click-and-hold on File, drag down into the dropdown, release on the
    Save row → the release fires EDITOR_SAVE without an extra click."""
    var bar = MenuBar()
    var items = List[MenuItem]()
    items.append(MenuItem(String("Save"), EDITOR_SAVE))
    items.append(MenuItem(String("Quit"), APP_QUIT_ACTION))
    bar.add(Menu(String("File"), items^))
    var rects = bar._layout(80)
    var fx = (rects[0].a.x + rects[0].b.x) // 2
    # Press on File — opens the menu, starts tracking.
    var press = Event.mouse_event(Point(fx, 0), MOUSE_BUTTON_LEFT, True, False)
    _ = bar.handle_event(press, 80)
    assert_equal(bar.open_idx, 0)
    assert_true(bar.tracking)
    # Drag onto the second item in the dropdown.
    var dr = bar._dropdown_rect(80)
    var item_y = dr.a.y + 1 + 1   # row 1 inside the dropdown = "Quit"
    var drag = Event.mouse_event(
        Point(dr.a.x + 2, item_y), MOUSE_BUTTON_LEFT, True, True,
    )
    _ = bar.handle_event(drag, 80)
    assert_equal(bar.selected_item, 1)
    # Release on the dragged-onto item triggers it.
    var release = Event.mouse_event(
        Point(dr.a.x + 2, item_y), MOUSE_BUTTON_LEFT, False, False,
    )
    var r = bar.handle_event(release, 80)
    assert_true(r.action)
    assert_equal(r.action.value(), APP_QUIT_ACTION)
    assert_false(bar.is_open())
    assert_false(bar.tracking)


fn test_menu_drag_release_outside_closes() raises:
    """Click-and-hold on File, drag off the bar and dropdown, release in
    empty space → the menu closes (drag-select cancellation)."""
    var bar = MenuBar()
    var items = List[MenuItem]()
    items.append(MenuItem(String("Save"), EDITOR_SAVE))
    bar.add(Menu(String("File"), items^))
    var rects = bar._layout(80)
    var fx = (rects[0].a.x + rects[0].b.x) // 2
    _ = bar.handle_event(
        Event.mouse_event(Point(fx, 0), MOUSE_BUTTON_LEFT, True, False), 80,
    )
    assert_true(bar.is_open())
    assert_true(bar.tracking)
    # Drag well below the dropdown, then release there.
    var dr = bar._dropdown_rect(80)
    var off = Point(dr.b.x + 5, dr.b.y + 5)
    _ = bar.handle_event(
        Event.mouse_event(off, MOUSE_BUTTON_LEFT, True, True), 80,
    )
    var r = bar.handle_event(
        Event.mouse_event(off, MOUSE_BUTTON_LEFT, False, False), 80,
    )
    assert_false(r.action)
    assert_false(bar.is_open())
    assert_false(bar.tracking)


fn test_menu_click_then_click_flow() raises:
    """Sticky/Mac-style flow: a click that lands on File and releases there
    leaves the menu open in non-tracking mode; a separate later click on a
    dropdown item then triggers it."""
    var bar = MenuBar()
    var items = List[MenuItem]()
    items.append(MenuItem(String("Save"), EDITOR_SAVE))
    bar.add(Menu(String("File"), items^))
    var rects = bar._layout(80)
    var fx = (rects[0].a.x + rects[0].b.x) // 2
    # First click: press + release on File. Menu opens, tracking clears on
    # release.
    _ = bar.handle_event(
        Event.mouse_event(Point(fx, 0), MOUSE_BUTTON_LEFT, True, False), 80,
    )
    assert_true(bar.tracking)
    _ = bar.handle_event(
        Event.mouse_event(Point(fx, 0), MOUSE_BUTTON_LEFT, False, False), 80,
    )
    assert_equal(bar.open_idx, 0)
    assert_false(bar.tracking)
    # Second click: press on dropdown item triggers it (no drag needed).
    var dr = bar._dropdown_rect(80)
    var item_y = dr.a.y + 1
    var r = bar.handle_event(
        Event.mouse_event(Point(dr.a.x + 2, item_y), MOUSE_BUTTON_LEFT, True, False),
        80,
    )
    assert_true(r.action)
    assert_equal(r.action.value(), EDITOR_SAVE)
    assert_false(bar.is_open())


fn test_file_dialog_selects_a_file() raises:
    var dlg = FileDialog()
    dlg.open(String("examples"))
    # Find hello.mojo in the listing and step to it.
    var target = -1
    for i in range(len(dlg.browser.entries)):
        if dlg.browser.entries[i] == String("hello.mojo"):
            target = i
            break
    assert_true(target > 0)
    while dlg.browser.selected < target:
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
    assert_equal(dlg.browser.selected, 1)
    assert_false(dlg.submitted)


fn test_file_dialog_double_click_opens() raises:
    var dlg = FileDialog()
    dlg.open(String("examples"))
    # Find hello.mojo, then click it twice.
    var target = -1
    for i in range(len(dlg.browser.entries)):
        if dlg.browser.entries[i] == String("hello.mojo"):
            target = i
            break
    assert_true(target > 0)
    var screen = Rect(0, 0, 80, 24)
    var list_top = 6
    var visible_y = list_top + (target - dlg.browser.scroll)
    _ = dlg.handle_mouse(
        Event.mouse_event(Point(20, visible_y), MOUSE_BUTTON_LEFT, True, False),
        screen,
    )
    assert_equal(dlg.browser.selected, target)
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
    var initial = dlg.browser.scroll
    # Wheel down a few times.
    _ = dlg.handle_mouse(
        Event.mouse_event(Point(20, 10), MOUSE_WHEEL_DOWN, True, False),
        screen,
    )
    # If there are more entries than the visible window, scroll moves; else stays.
    if len(dlg.browser.entries) > 13:
        assert_true(dlg.browser.scroll > initial)
    # Wheel up resets toward 0.
    _ = dlg.handle_mouse(
        Event.mouse_event(Point(20, 10), MOUSE_WHEEL_UP, True, False),
        screen,
    )
    assert_true(dlg.browser.scroll <= initial + 3)


fn test_save_as_dialog_seeds_from_existing_path() raises:
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
    assert_equal(dlg.filename, String("hello.mojo"))
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


fn test_save_as_dialog_typing_updates_filename() raises:
    var dlg = SaveAsDialog()
    dlg.open(String(""))
    assert_equal(dlg.filename, String(""))
    _ = dlg.handle_key(Event.key_event(UInt32(ord("a"))))
    _ = dlg.handle_key(Event.key_event(UInt32(ord("b"))))
    _ = dlg.handle_key(Event.key_event(UInt32(ord(".")), MOD_NONE))
    _ = dlg.handle_key(Event.key_event(UInt32(ord("t"))))
    _ = dlg.handle_key(Event.key_event(UInt32(ord("x"))))
    _ = dlg.handle_key(Event.key_event(UInt32(ord("t"))))
    assert_equal(dlg.filename, String("ab.txt"))
    # Backspace deletes from the input while focus stays there.
    _ = dlg.handle_key(Event.key_event(KEY_BACKSPACE))
    assert_equal(dlg.filename, String("ab.tx"))


fn test_save_as_dialog_enter_submits_joined_path() raises:
    var dlg = SaveAsDialog()
    dlg.open(String("examples/hello.mojo"))
    _ = dlg.handle_key(Event.key_event(KEY_ENTER))
    assert_true(dlg.submitted)
    assert_equal(dlg.selected_path, String("examples/hello.mojo"))


fn test_save_as_dialog_tab_focus_then_listing_navigation() raises:
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


fn test_save_as_dialog_empty_filename_blocks_submit() raises:
    var dlg = SaveAsDialog()
    dlg.open(String(""))
    _ = dlg.handle_key(Event.key_event(KEY_ENTER))
    assert_false(dlg.submitted)


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


fn test_editor_left_right_steps_over_multibyte_codepoint() raises:
    """Arrow keys must move by whole UTF-8 codepoints — never park the
    cursor in the middle of a multi-byte sequence."""
    # "café" — bytes: c(0), a(1), f(2), é(3-4). 4 codepoints, 5 bytes.
    var ed = Editor(String("café"))
    _ = ed.handle_key(_key(KEY_RIGHT), _VIEW)
    _ = ed.handle_key(_key(KEY_RIGHT), _VIEW)
    _ = ed.handle_key(_key(KEY_RIGHT), _VIEW)
    assert_equal(ed.cursor_col, 3)        # at start of é
    _ = ed.handle_key(_key(KEY_RIGHT), _VIEW)
    assert_equal(ed.cursor_col, 5)        # past é, end of line (skipped 2 bytes)
    _ = ed.handle_key(_key(KEY_LEFT), _VIEW)
    assert_equal(ed.cursor_col, 3)        # back over the whole codepoint
    _ = ed.handle_key(_key(KEY_LEFT), _VIEW)
    assert_equal(ed.cursor_col, 2)        # ASCII step works as before


fn test_editor_backspace_removes_whole_codepoint() raises:
    """Backspace at the end of a line containing é must remove all of é."""
    var ed = Editor(String("café"))
    _ = ed.handle_key(_key(KEY_END), _VIEW)
    assert_equal(ed.cursor_col, 5)
    _ = ed.handle_key(_key(KEY_BACKSPACE), _VIEW)
    assert_equal(ed.buffer.line(0), String("caf"))
    assert_equal(ed.cursor_col, 3)


fn test_editor_delete_key_removes_whole_codepoint() raises:
    """Delete (forward) at the boundary before é must remove all of é and
    leave the buffer as valid UTF-8."""
    var ed = Editor(String("café"))
    _ = ed.handle_key(_key(KEY_RIGHT), _VIEW)
    _ = ed.handle_key(_key(KEY_RIGHT), _VIEW)
    _ = ed.handle_key(_key(KEY_RIGHT), _VIEW)
    assert_equal(ed.cursor_col, 3)
    _ = ed.handle_key(_key(KEY_DELETE), _VIEW)
    assert_equal(ed.buffer.line(0), String("caf"))
    assert_equal(ed.cursor_col, 3)


fn test_editor_vertical_movement_uses_cell_column() raises:
    """Down through a row of multi-byte characters preserves the visual
    column, not the byte offset. ``ééé`` is 6 bytes / 3 cells; landing
    column 2 (cells) on it must be byte 4, not byte 2 (mid-codepoint)."""
    # Line 0: "abcdef" (6 ASCII), line 1: "ééé" (3 codepoints, 6 bytes).
    var ed = Editor(String("abcdef\néééxyz"))
    _ = ed.handle_key(_key(KEY_RIGHT), _VIEW)
    _ = ed.handle_key(_key(KEY_RIGHT), _VIEW)        # cursor on 'c'
    assert_equal(ed.cursor_col, 2)
    assert_equal(ed.desired_col, 2)
    _ = ed.handle_key(_key(KEY_DOWN), _VIEW)
    # Cell 2 on "éééxyz" is the third é → byte 4, a codepoint boundary.
    assert_equal(ed.cursor_row, 1)
    assert_equal(ed.cursor_col, 4)
    assert_equal(ed.desired_col, 2)
    _ = ed.handle_key(_key(KEY_UP), _VIEW)
    assert_equal(ed.cursor_row, 0)
    assert_equal(ed.cursor_col, 2)


fn test_editor_mouse_click_lands_on_codepoint_boundary() raises:
    """A click at cell column N inside a multi-byte run must drop the cursor
    at the *codepoint* at column N, never mid-sequence."""
    var ed = Editor(String("ééé"))
    var view = Rect(0, 0, 40, 10)
    # Cell column 2 → third é → byte offset 4.
    _ = ed.handle_mouse(
        Event.mouse_event(Point(2, 0), MOUSE_BUTTON_LEFT, True, False),
        view,
    )
    assert_equal(ed.cursor_row, 0)
    assert_equal(ed.cursor_col, 4)
    # Far past EOL clamps to line end (a boundary).
    _ = ed.handle_mouse(
        Event.mouse_event(Point(20, 0), MOUSE_BUTTON_LEFT, True, False),
        view,
    )
    assert_equal(ed.cursor_col, 6)


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


fn test_language_registry_loads_from_bundled_json() raises:
    """The catalog imported from Helix's languages.toml should load cleanly
    and contain at least the long-tail languages we now expect."""
    var specs = built_in_servers()
    # Catalog isn't tiny — sanity-check the lower bound rather than a
    # specific count so refreshes don't break this test.
    assert_true(len(specs) > 50)

    # Elm regression: pre-import the registry didn't contain Elm at all.
    var elm_idx = find_language_by_id(specs, String("elm"))
    assert_true(elm_idx >= 0)
    assert_true(len(specs[elm_idx].candidates) > 0)
    assert_equal(
        specs[elm_idx].candidates[0].argv[0],
        String("elm-language-server"),
    )

    # Extension routing for one of the curated entries with an install hint.
    var py_idx = find_language_for_extension(specs, String("py"))
    assert_true(py_idx >= 0)
    assert_equal(specs[py_idx].language_id, String("python"))
    assert_true(len(specs[py_idx].install_hint.as_bytes()) > 0)


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


fn test_install_runner_last_lines_picks_tail_skipping_blanks() raises:
    """``_last_lines`` is the helper the install popup uses to render the
    rolling 5-line tail. Trailing blanks should be dropped (so the popup
    doesn't fill its window with empty rows when the installer ends with
    a newline) and trailing CR/whitespace per line stripped."""
    # Fewer lines than asked-for: returns them all, oldest first.
    var two = _last_lines(String("alpha\nbeta\n"), 5)
    assert_equal(len(two), 2)
    assert_equal(two[0], String("alpha"))
    assert_equal(two[1], String("beta"))
    # More lines than asked-for: returns the last N.
    var input = String("a\nb\nc\nd\ne\nf\ng\n")
    var tail = _last_lines(input, 3)
    assert_equal(len(tail), 3)
    assert_equal(tail[0], String("e"))
    assert_equal(tail[1], String("f"))
    assert_equal(tail[2], String("g"))
    # CRLF / trailing space are stripped per line.
    var crlf = _last_lines(String("hello\r\nworld  \n"), 5)
    assert_equal(len(crlf), 2)
    assert_equal(crlf[0], String("hello"))
    assert_equal(crlf[1], String("world"))
    # Empty / whitespace-only lines collapse out (so a trailing blank
    # after the final progress line doesn't push real output off-screen).
    var blanks = _last_lines(String("first\n\n\nsecond\n   \n"), 5)
    assert_equal(len(blanks), 2)
    assert_equal(blanks[0], String("first"))
    assert_equal(blanks[1], String("second"))


fn test_install_runner_runs_sh_command_to_completion() raises:
    """End-to-end: spawn ``sh -c "echo hello"`` via the runner and tick
    until the child reaps. The returned ``InstallResult`` should carry
    exit 0, the captured ``hello`` output, and the original label /
    command we started with."""
    var r = InstallRunner()
    assert_false(r.is_active())
    r.start(String("smoke"), String("echo hello"))
    assert_true(r.is_active())
    var result_opt: Optional[InstallResult] = Optional[InstallResult]()
    # ``echo`` takes microseconds; the loop ceiling exists only to bound
    # the test if something goes wrong in the spawn / reap path.
    for _ in range(2000):
        result_opt = r.tick()
        if result_opt:
            break
    assert_true(Bool(result_opt))
    var result = result_opt.value()
    assert_true(result.ok())
    assert_equal(result.label, String("smoke"))
    assert_equal(result.command, String("echo hello"))
    # ``echo hello`` writes ``hello\n`` to stdout — the trailing newline
    # is preserved in ``output`` (we only strip per-line in the popup).
    var ob = result.output.as_bytes()
    assert_true(len(ob) >= 5)
    var first5 = String(StringSlice(unsafe_from_utf8=ob[:5]))
    assert_equal(first5, String("hello"))
    # Runner is back to idle, ready to accept a new install.
    assert_false(r.is_active())


fn test_install_runner_failure_carries_nonzero_exit() raises:
    """A non-zero exit must be visible to the host so it knows to open
    the failure-output editor window. ``sh -c 'exit 7'`` is the minimal
    deterministic failure."""
    var r = InstallRunner()
    r.start(String("fail-smoke"), String("exit 7"))
    var result_opt: Optional[InstallResult] = Optional[InstallResult]()
    for _ in range(200):
        result_opt = r.tick()
        if result_opt:
            break
    assert_true(Bool(result_opt))
    var result = result_opt.value()
    assert_false(result.ok())
    assert_equal(result.exit_code(), 7)


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


fn test_dap_classify_response() raises:
    var resp = parse_json(String(
        "{\"seq\":3,\"type\":\"response\",\"request_seq\":1,"
        + "\"success\":true,\"command\":\"initialize\","
        + "\"body\":{\"supportsConfigurationDoneRequest\":true}}"
    ))
    var c = classify_dap_message(resp)
    assert_equal(Int(c.kind), Int(DAP_RESPONSE))
    assert_equal(c.seq, 3)
    assert_true(Bool(c.request_seq))
    assert_equal(c.request_seq.value(), 1)
    assert_true(Bool(c.success))
    assert_true(c.success.value())
    assert_equal(c.command.value(), String("initialize"))
    assert_true(Bool(c.body))


fn test_dap_classify_event() raises:
    var ev = parse_json(String(
        "{\"seq\":4,\"type\":\"event\",\"event\":\"stopped\","
        + "\"body\":{\"reason\":\"breakpoint\",\"threadId\":1,"
        + "\"allThreadsStopped\":true}}"
    ))
    var c = classify_dap_message(ev)
    assert_equal(Int(c.kind), Int(DAP_EVENT))
    assert_equal(c.seq, 4)
    assert_equal(c.event.value(), String("stopped"))
    assert_true(Bool(c.body))


fn test_dap_classify_reverse_request() raises:
    var rq = parse_json(String(
        "{\"seq\":5,\"type\":\"request\",\"command\":\"runInTerminal\","
        + "\"arguments\":{\"args\":[\"/usr/bin/echo\"]}}"
    ))
    var c = classify_dap_message(rq)
    assert_equal(Int(c.kind), Int(DAP_REQUEST))
    assert_equal(c.command.value(), String("runInTerminal"))
    assert_true(Bool(c.arguments))


fn test_dap_classify_response_with_failure() raises:
    var resp = parse_json(String(
        "{\"seq\":7,\"type\":\"response\",\"request_seq\":2,"
        + "\"success\":false,\"command\":\"launch\","
        + "\"message\":\"file not found\"}"
    ))
    var c = classify_dap_message(resp)
    assert_equal(Int(c.kind), Int(DAP_RESPONSE))
    assert_true(Bool(c.success))
    assert_false(c.success.value())
    assert_true(Bool(c.message))
    assert_equal(c.message.value(), String("file not found"))


fn test_dap_initialize_arguments_shape() raises:
    var args = dap_initialize_arguments(
        String("turbokod"), String("debugpy"),
    )
    assert_true(args.is_object())
    assert_true(args.object_has(String("clientID")))
    assert_true(args.object_has(String("adapterID")))
    var aid = args.object_get(String("adapterID"))
    assert_equal(aid.value().as_str(), String("debugpy"))
    var lstart = args.object_get(String("linesStartAt1"))
    assert_true(lstart.value().is_bool())
    assert_false(lstart.value().as_bool())


fn test_dap_seq_autoincrement_via_cat() raises:
    """End-to-end: sequence numbers increment monotonically across
    requests. ``/bin/cat`` is the cheapest pipe-back fixture available."""
    var cat_info = stat_file(String("/bin/cat"))
    if not cat_info.ok:
        assert_true(True)
        return
    var argv = List[String]()
    argv.append(String("/bin/cat"))
    var client = DapClient.spawn(argv)
    var seq1 = client.send_request(String("initialize"), json_object())
    var seq2 = client.send_request(String("threads"), json_object())
    assert_equal(seq1, 1)
    assert_equal(seq2, 2)
    client.terminate()


fn test_dap_parse_threads() raises:
    var body = parse_json(String(
        "{\"threads\":[{\"id\":1,\"name\":\"main\"},"
        + "{\"id\":2,\"name\":\"worker\"}]}"
    ))
    var threads = _parse_threads(Optional[JsonValue](body))
    assert_equal(len(threads), 2)
    assert_equal(threads[0].id, 1)
    assert_equal(threads[0].name, String("main"))
    assert_equal(threads[1].id, 2)
    assert_equal(threads[1].name, String("worker"))


fn test_dap_parse_stack_trace_zero_based() raises:
    """Adapters return 1-based lines (debugpy + delve always; lldb-dap
    honors our linesStartAt1=false flag). The parser normalizes to
    0-based to match Editor's row index."""
    var body = parse_json(String(
        "{\"stackFrames\":[{\"id\":42,\"name\":\"main\","
        + "\"line\":10,\"column\":1,"
        + "\"source\":{\"path\":\"/tmp/foo.py\"}}]}"
    ))
    var frames = _parse_stack_trace(Optional[JsonValue](body))
    assert_equal(len(frames), 1)
    assert_equal(frames[0].id, 42)
    assert_equal(frames[0].name, String("main"))
    assert_equal(frames[0].path, String("/tmp/foo.py"))
    assert_equal(frames[0].line, 9)
    assert_equal(frames[0].column, 0)


fn test_dap_parse_scopes_and_variables() raises:
    var scopes_body = parse_json(String(
        "{\"scopes\":[{\"name\":\"Locals\",\"variablesReference\":7,"
        + "\"expensive\":false}]}"
    ))
    var scopes = _parse_scopes(Optional[JsonValue](scopes_body))
    assert_equal(len(scopes), 1)
    assert_equal(scopes[0].name, String("Locals"))
    assert_equal(scopes[0].variables_reference, 7)
    assert_false(scopes[0].expensive)
    var vars_body = parse_json(String(
        "{\"variables\":[{\"name\":\"x\",\"value\":\"42\","
        + "\"type\":\"int\",\"variablesReference\":0},"
        + "{\"name\":\"obj\",\"value\":\"<Foo>\",\"type\":\"Foo\","
        + "\"variablesReference\":11}]}"
    ))
    var variables = _parse_variables(Optional[JsonValue](vars_body))
    assert_equal(len(variables), 2)
    assert_equal(variables[0].name, String("x"))
    assert_equal(variables[0].value, String("42"))
    assert_equal(variables[0].type_name, String("int"))
    assert_equal(variables[0].variables_reference, 0)
    assert_equal(variables[1].variables_reference, 11)


fn test_dap_registry_lookup() raises:
    var debs = built_in_debuggers()
    assert_true(len(debs) >= 3)
    var py = find_debugger_for_language(debs, String("python"))
    assert_true(py >= 0)
    assert_equal(debs[py].name, String("debugpy"))
    var unknown = find_debugger_for_language(debs, String("ada"))
    assert_equal(unknown, -1)


fn test_dap_launch_arguments_for_debugpy() raises:
    var debs = built_in_debuggers()
    var idx = find_debugger_for_language(debs, String("python"))
    assert_true(idx >= 0)
    var args = List[String]()
    args.append(String("--verbose"))
    var body = launch_arguments_for(
        debs[idx], String("/tmp/main.py"), String("/tmp"), args^, False,
    )
    assert_true(body.is_object())
    assert_equal(
        body.object_get(String("program")).value().as_str(),
        String("/tmp/main.py"),
    )
    assert_equal(
        body.object_get(String("console")).value().as_str(),
        String("internalConsole"),
    )
    var arr = body.object_get(String("args"))
    assert_true(arr.value().is_array())
    assert_equal(arr.value().array_len(), 1)
    assert_equal(arr.value().array_at(0).as_str(), String("--verbose"))


fn test_dap_launch_arguments_for_delve() raises:
    var debs = built_in_debuggers()
    var idx = find_debugger_for_language(debs, String("go"))
    assert_true(idx >= 0)
    var body = launch_arguments_for(
        debs[idx], String("/tmp/cmd"), String("/tmp"), List[String](), False,
    )
    assert_equal(
        body.object_get(String("mode")).value().as_str(),
        String("debug"),
    )


fn test_dap_manager_breakpoint_toggle() raises:
    """Local breakpoint state mutates correctly even with no adapter
    spawned. Toggle semantics: add → remove → add."""
    var mgr = DapManager()
    assert_false(mgr.has_breakpoint(String("/tmp/x.py"), 5))
    mgr.toggle_breakpoint(String("/tmp/x.py"), 5)
    assert_true(mgr.has_breakpoint(String("/tmp/x.py"), 5))
    mgr.toggle_breakpoint(String("/tmp/x.py"), 12)
    assert_true(mgr.has_breakpoint(String("/tmp/x.py"), 12))
    var lines = mgr.breakpoints_for(String("/tmp/x.py"))
    assert_equal(len(lines), 2)
    mgr.toggle_breakpoint(String("/tmp/x.py"), 5)
    assert_false(mgr.has_breakpoint(String("/tmp/x.py"), 5))
    assert_true(mgr.has_breakpoint(String("/tmp/x.py"), 12))


fn test_project_targets_load_parses_fields() raises:
    """A minimal config with one run-only and one run+debug target
    must round-trip through the loader with all fields populated."""
    var root = _temp_path(String("_targets"))
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var dir = join_path(root, String(".turbokod"))
    _ = external_call["mkdir", Int32](
        (dir + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var path = join_path(dir, String("targets.json"))
    var body = String(
        "{\n"
        + "  \"active\": \"main\",\n"
        + "  \"targets\": [\n"
        + "    {\"name\": \"tests\","
        + " \"program\": \"pixi\", \"args\": [\"run\", \"test\"]},\n"
        + "    {\"name\": \"main\","
        + " \"program\": \"app.py\", \"args\": [\"--verbose\"],"
        + " \"cwd\": \"sub\", \"language\": \"python\"}\n"
        + "  ]\n"
        + "}\n"
    )
    assert_true(write_file(path, body))
    var loaded = load_project_targets(root)
    assert_equal(len(loaded.targets), 2)
    # ``active`` resolved by name to index 1, not the file's order.
    assert_equal(loaded.active, 1)
    assert_equal(loaded.targets[0].name, String("tests"))
    assert_equal(loaded.targets[0].program, String("pixi"))
    assert_equal(len(loaded.targets[0].args), 2)
    assert_equal(loaded.targets[0].args[0], String("run"))
    assert_equal(loaded.targets[0].args[1], String("test"))
    assert_equal(loaded.targets[0].debug_language, String(""))
    assert_equal(loaded.targets[1].name, String("main"))
    assert_equal(loaded.targets[1].program, String("app.py"))
    assert_equal(loaded.targets[1].cwd, String("sub"))
    assert_equal(loaded.targets[1].debug_language, String("python"))
    assert_equal(len(loaded.targets[1].args), 1)
    assert_equal(loaded.targets[1].args[0], String("--verbose"))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((dir + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((root + String("\0")).unsafe_ptr())


fn test_project_targets_save_roundtrips_active() raises:
    """``save_project_targets`` must rewrite the ``active`` pointer
    so the next ``load_project_targets`` returns the new selection."""
    var root = _temp_path(String("_targets_save"))
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var dir = join_path(root, String(".turbokod"))
    _ = external_call["mkdir", Int32](
        (dir + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var path = join_path(dir, String("targets.json"))
    var body = String(
        "{\n"
        + "  \"active\": \"a\",\n"
        + "  \"targets\": [\n"
        + "    {\"name\": \"a\", \"run\": \"echo a\"},\n"
        + "    {\"name\": \"b\", \"run\": \"echo b\"}\n"
        + "  ]\n"
        + "}\n"
    )
    assert_true(write_file(path, body))
    var t = load_project_targets(root)
    assert_equal(t.active, 0)
    assert_true(t.set_active_by_name(String("b")))
    assert_true(save_project_targets(root, t))
    var t2 = load_project_targets(root)
    assert_equal(t2.active, 1)
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((dir + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((root + String("\0")).unsafe_ptr())


fn test_project_targets_resolve_paths() raises:
    """``resolved_cwd`` anchors relative cwds on the project root.
    ``resolved_program`` mirrors shell semantics: a bare name (no
    slash) is left alone for ``$PATH`` resolution, anything with a
    slash is anchored on the resolved cwd, and absolute paths pass
    through unchanged."""
    var root = String("/proj")
    assert_equal(resolved_cwd(root, String("")), root)
    assert_equal(resolved_cwd(root, String("sub/dir")), String("/proj/sub/dir"))
    assert_equal(resolved_cwd(root, String("/abs")), String("/abs"))
    # Bare name → PATH lookup, untouched.
    assert_equal(
        resolved_program(root, String(""), String("python")),
        String("python"),
    )
    assert_equal(
        resolved_program(root, String("build"), String("make")),
        String("make"),
    )
    # Slash in name → anchored on resolved cwd.
    assert_equal(
        resolved_program(root, String(""), String("bin/app")),
        String("/proj/bin/app"),
    )
    assert_equal(
        resolved_program(root, String("build"), String("./app")),
        String("/proj/build/./app"),
    )
    # Absolute program ignores cwd entirely.
    assert_equal(
        resolved_program(root, String("build"), String("/usr/bin/x")),
        String("/usr/bin/x"),
    )


fn test_resolve_python_interpreter() raises:
    """Bare ``python`` swaps to ``<project>/.venv/bin/python`` when one
    exists; otherwise it's returned unchanged for ``$PATH`` lookup.
    Anything that isn't ``python`` / ``python3`` is also pass-through
    so non-Python targets aren't accidentally rewritten."""
    var root = _temp_path(String("_pyresolve"))
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    # No venv yet — bare ``python`` falls through. (We can't assert
    # equality with literal "python" because an ambient ``VIRTUAL_ENV``
    # in the test runner's env would make ``resolve_python_interpreter``
    # pick that instead; just check it doesn't bogusly point into the
    # bare project root.)
    var no_venv = resolve_python_interpreter(root, String("python"))
    assert_true(no_venv != join_path(root, String(".venv/bin/python")))
    assert_true(no_venv != join_path(root, String("venv/bin/python")))
    # Non-Python program is always pass-through, regardless of env.
    assert_equal(
        resolve_python_interpreter(root, String("ruby")),
        String("ruby"),
    )
    assert_equal(
        resolve_python_interpreter(root, String("/usr/bin/python")),
        String("/usr/bin/python"),
    )
    # Drop a ``.venv/bin/python`` shim and confirm the lookup finds it.
    # ``.venv`` lives next to the source root so we exercise the
    # project-local detection branch (not the env-var fallback).
    var venv_dir = join_path(root, String(".venv"))
    _ = external_call["mkdir", Int32](
        (venv_dir + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var venv_bin = join_path(venv_dir, String("bin"))
    _ = external_call["mkdir", Int32](
        (venv_bin + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var venv_python = join_path(venv_bin, String("python"))
    assert_true(write_file(venv_python, String("#!/bin/sh\nexec /usr/bin/false\n")))
    assert_equal(
        resolve_python_interpreter(root, String("python")),
        venv_python,
    )
    assert_equal(
        resolve_python_interpreter(root, String("python3")),
        venv_python,
    )
    # Cleanup. Tear down deepest-first; ``.venv/bin/python`` is the
    # only file we created.
    _ = external_call["unlink", Int32]((venv_python + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((venv_bin + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((venv_dir + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((root + String("\0")).unsafe_ptr())


fn test_detect_project_language_python_markers() raises:
    """``detect_project_language`` flags any project root that
    contains a known Python marker file (``pyproject.toml`` /
    ``setup.py`` / ``setup.cfg``) as ``python``. A bare ``*.py``
    at the root is enough on its own."""
    var root = _temp_path(String("_pylang"))
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    # Empty project: no markers, no guess.
    assert_equal(detect_project_language(root), String(""))
    # Drop pyproject.toml — ``python`` wins immediately.
    var pyproj = join_path(root, String("pyproject.toml"))
    assert_true(write_file(pyproj, String("[project]\nname=\"x\"\n")))
    assert_equal(detect_project_language(root), String("python"))
    _ = external_call["unlink", Int32]((pyproj + String("\0")).unsafe_ptr())
    # setup.py also flips the result.
    var setup = join_path(root, String("setup.py"))
    assert_true(write_file(setup, String("from setuptools import setup\n")))
    assert_equal(detect_project_language(root), String("python"))
    _ = external_call["unlink", Int32]((setup + String("\0")).unsafe_ptr())
    # ``setup.cfg`` — same thing.
    var setup_cfg = join_path(root, String("setup.cfg"))
    assert_true(write_file(setup_cfg, String("[metadata]\nname = x\n")))
    assert_equal(detect_project_language(root), String("python"))
    _ = external_call["unlink", Int32]((setup_cfg + String("\0")).unsafe_ptr())
    # Bare *.py at the root is the last-resort signal.
    var py_file = join_path(root, String("main.py"))
    assert_true(write_file(py_file, String("print('hi')\n")))
    assert_equal(detect_project_language(root), String("python"))
    _ = external_call["unlink", Int32]((py_file + String("\0")).unsafe_ptr())
    # No markers left → no guess.
    assert_equal(detect_project_language(root), String(""))
    _ = external_call["rmdir", Int32]((root + String("\0")).unsafe_ptr())


fn test_detect_project_language_no_match() raises:
    """A project root with no known markers returns the empty string,
    which the caller surfaces as a "couldn't detect" status hint
    rather than picking the wrong runner."""
    var root = _temp_path(String("_unknown"))
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var rb = join_path(root, String("hello.rb"))
    assert_true(write_file(rb, String("puts 'hi'\n")))
    assert_equal(detect_project_language(root), String(""))
    _ = external_call["unlink", Int32]((rb + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((root + String("\0")).unsafe_ptr())


fn test_status_bar_tab_hit_test() raises:
    """Painting the bar captures per-tab rects; ``hit_test_tab`` then
    routes a click on each tab to its index, and a click outside
    the strip to -1."""
    var sb = StatusBar()
    var tabs = List[StatusTab]()
    tabs.append(StatusTab(String("tests"), False, False))
    tabs.append(StatusTab(String("main"), False, False))
    sb.set_tabs(tabs^, 0)
    var canvas = Canvas(80, 10)
    sb.paint(canvas, Rect(0, 0, 80, 10))
    var y = 9   # screen.b.y - 1
    var first = sb.hit_test_tab(Point(2, y), Rect(0, 0, 80, 10))
    var second = sb.hit_test_tab(Point(15, y), Rect(0, 0, 80, 10))
    # First tab starts at column 2 (1 padding + 1 separator); the
    # second tab is several columns over. Either way both >= 0.
    assert_true(first >= 0)
    assert_true(second >= 0)
    # Clicks on a different row never hit a tab.
    assert_equal(sb.hit_test_tab(Point(2, 0), Rect(0, 0, 80, 10)), -1)


fn test_shadow_button_paints_face_and_shadow() raises:
    """The shared button widget must paint the label on a green
    face and drop a half-block shadow on the right column + the
    row below — same idiom the dir_browser jump strip uses."""
    var canvas = Canvas(20, 4)
    canvas.fill(Rect(0, 0, 20, 4), String(" "), Attr(BLACK, LIGHT_GRAY))
    var btn = ShadowButton(String(" OK "), 2, 1)
    paint_shadow_button(canvas, btn, Attr(BLACK, GREEN), LIGHT_GRAY)
    # Face row carries the label on green.
    assert_equal(canvas.get(2, 1).glyph, String(" "))
    assert_equal(canvas.get(3, 1).glyph, String("O"))
    assert_equal(canvas.get(4, 1).glyph, String("K"))
    assert_equal(canvas.get(3, 1).attr.bg, GREEN)
    # Right-edge shadow column at face_width + x.
    assert_equal(canvas.get(2 + 4, 1).glyph, String("▄"))
    assert_equal(canvas.get(2 + 4, 1).attr.bg, LIGHT_GRAY)
    # Bottom shadow row, shifted right by 1.
    assert_equal(canvas.get(3, 2).glyph, String("▀"))
    assert_equal(canvas.get(2 + 4, 2).glyph, String("▀"))
    # Cell to the left of the button stays untouched.
    assert_equal(canvas.get(1, 1).glyph, String(" "))
    assert_equal(canvas.get(1, 1).attr.bg, LIGHT_GRAY)


fn test_shadow_button_hit_includes_shadow_rows() raises:
    """A click on the bottom-shadow row should still register —
    users miss-click downward routinely. Clicks outside the hit
    rect (or on motion / non-press events) must be rejected."""
    var btn = ShadowButton(String(" OK "), 2, 1)
    # Press inside the face.
    var press_face = Event.mouse_event(Point(3, 1), MOUSE_BUTTON_LEFT)
    assert_true(shadow_button_hit(btn, press_face))
    # Press on the right-shadow column.
    var press_shadow_r = Event.mouse_event(Point(6, 1), MOUSE_BUTTON_LEFT)
    assert_true(shadow_button_hit(btn, press_shadow_r))
    # Press on the bottom-shadow row.
    var press_shadow_b = Event.mouse_event(Point(4, 2), MOUSE_BUTTON_LEFT)
    assert_true(shadow_button_hit(btn, press_shadow_b))
    # Press just below the shadow row — outside.
    var miss = Event.mouse_event(Point(4, 3), MOUSE_BUTTON_LEFT)
    assert_false(shadow_button_hit(btn, miss))
    # Release events don't activate.
    var release = Event.mouse_event(
        Point(3, 1), MOUSE_BUTTON_LEFT, pressed=False,
    )
    assert_false(shadow_button_hit(btn, release))


fn test_canvas_darken_rect_preserves_glyph() raises:
    """``darken_rect`` is the compositor primitive for drop shadows:
    it changes a cell's attr to dim-on-black but must leave the
    glyph (and width) alone, so whatever the caller painted there
    earlier still reads through the shadow."""
    var c = Canvas(10, 5)
    # Stamp some content that the shadow will overlay.
    _ = c.put_text(Point(0, 0), String("hello"), Attr(WHITE, BLUE))
    _ = c.put_text(Point(0, 1), String("world"), Attr(YELLOW, BLUE))
    c.darken_rect(Rect(2, 0, 4, 2))
    # Glyphs survive.
    assert_equal(c.get(2, 0).glyph, String("l"))
    assert_equal(c.get(3, 0).glyph, String("l"))
    assert_equal(c.get(2, 1).glyph, String("r"))
    assert_equal(c.get(3, 1).glyph, String("l"))
    # Attr is the shadow attr — DARK_GRAY on BLACK.
    assert_equal(c.get(2, 0).attr.fg, DARK_GRAY)
    assert_equal(c.get(2, 0).attr.bg, BLACK)
    assert_equal(c.get(3, 1).attr.fg, DARK_GRAY)
    assert_equal(c.get(3, 1).attr.bg, BLACK)
    # Cells outside the rect are untouched.
    assert_equal(c.get(0, 0).attr.fg, WHITE)
    assert_equal(c.get(0, 0).attr.bg, BLUE)
    assert_equal(c.get(4, 0).attr.fg, WHITE)


fn test_paint_drop_shadow_targets_right_and_bottom() raises:
    """``paint_drop_shadow`` darkens the 2-cell right strip (offset
    one row down from the top edge) and the 1-row bottom strip
    (offset 2 cells right of the left edge), matching the diagonal
    "lifted" effect of the per-button shadows."""
    var c = Canvas(20, 8)
    # Background that the shadow needs to dim.
    c.fill(Rect(0, 0, 20, 8), String("·"), Attr(WHITE, BLUE))
    var dialog = Rect(3, 2, 13, 6)   # 10×4 dialog
    paint_drop_shadow(c, dialog)
    # Right strip: x in {13, 14}, y in [3, 6).
    assert_equal(c.get(13, 3).attr.bg, BLACK)
    assert_equal(c.get(14, 3).attr.bg, BLACK)
    assert_equal(c.get(13, 5).attr.bg, BLACK)
    assert_equal(c.get(14, 5).attr.bg, BLACK)
    # Glyph underneath the shadow survives.
    assert_equal(c.get(13, 3).glyph, String("·"))
    # Top-right corner of the dialog is *not* shadowed (shadow starts
    # one row down so the top edge looks "lit").
    assert_equal(c.get(13, 2).attr.bg, BLUE)
    # Bottom strip: x in [5, 15), y == 6.
    assert_equal(c.get(5, 6).attr.bg, BLACK)
    assert_equal(c.get(14, 6).attr.bg, BLACK)
    # The two cells immediately under the dialog's left edge are
    # *not* shadowed (offset 2) — keeps the bottom-left corner lit.
    assert_equal(c.get(3, 6).attr.bg, BLUE)
    assert_equal(c.get(4, 6).attr.bg, BLUE)
    # Cells inside the dialog rect are untouched by the shadow.
    assert_equal(c.get(5, 3).attr.bg, BLUE)


fn test_debug_pane_default_title_is_debug() raises:
    """``DebugPane`` defaults to DEBUG mode — the pane's top border
    paints ``Debug`` so existing callers see no behavioural change."""
    var pane = DebugPane()
    pane.visible = True
    var c = Canvas(40, 10)
    pane.paint(c, Rect(0, 0, 40, 10))
    assert_equal(c.get(2, 0).glyph, String(" "))
    assert_equal(c.get(3, 0).glyph, String("D"))
    assert_equal(c.get(4, 0).glyph, String("e"))
    assert_equal(c.get(5, 0).glyph, String("b"))


fn test_debug_pane_run_mode_swaps_title() raises:
    """RUN mode flips the title to ``Run`` — the pane's the same
    code path, just a different label."""
    var pane = DebugPane()
    pane.visible = True
    pane.set_mode(PANE_MODE_RUN)
    var c = Canvas(40, 10)
    pane.paint(c, Rect(0, 0, 40, 10))
    assert_equal(c.get(3, 0).glyph, String("R"))
    assert_equal(c.get(4, 0).glyph, String("u"))
    assert_equal(c.get(5, 0).glyph, String("n"))


fn test_debug_pane_run_mode_hides_inspect_divider() raises:
    """RUN mode collapses Stack/Locals (always empty there) so Output
    fills the pane. The ``─ Output ─`` divider row that DEBUG paints
    between the two sections must NOT be drawn — a row of ``─``
    glyphs in the inspect area would confirm the pre-fix behaviour."""
    var pane = DebugPane()
    pane.visible = True
    pane.set_mode(PANE_MODE_RUN)
    pane.append_output(String("hello"))
    var c = Canvas(40, 10)
    c.fill(Rect(0, 0, 40, 10), String("·"), Attr(BLACK, LIGHT_GRAY))
    pane.paint(c, Rect(0, 0, 40, 10))
    # Scan rows 2..9 (below the title and status row): no row should
    # be a continuous ``─`` strip carrying an ``Output`` label.
    for y in range(2, 10):
        if c.get(3, y).glyph == String("O") \
                and c.get(4, y).glyph == String("u") \
                and c.get(5, y).glyph == String("t"):
            assert_true(False)


fn test_debug_pane_run_mode_uses_full_height_for_output() raises:
    """The most recent output line must reach the bottom row of the
    panel — RUN mode saves the divider row that DEBUG mode would have
    painted, and that row goes to Output instead."""
    var pane = DebugPane()
    pane.visible = True
    pane.set_mode(PANE_MODE_RUN)
    for i in range(20):
        pane.append_output(String("line ") + String(i))
    var c = Canvas(40, 10)
    pane.paint(c, Rect(0, 0, 40, 10))
    # Bottom panel row is y=9. Autoscroll keeps the latest line
    # ("line 19") pinned there.
    assert_equal(c.get(2, 9).glyph, String("l"))
    assert_equal(c.get(3, 9).glyph, String("i"))
    assert_equal(c.get(4, 9).glyph, String("n"))


fn test_debug_pane_debug_mode_keeps_output_divider() raises:
    """DEBUG mode still paints the ``─ Output ─`` divider so the
    inspect column reads as a separate section above the log."""
    var pane = DebugPane()
    pane.visible = True
    pane.append_output(String("debug output"))
    var c = Canvas(40, 12)
    pane.paint(c, Rect(0, 0, 40, 12))
    var found = False
    for y in range(2, 11):
        if c.get(3, y).glyph == String("O") \
                and c.get(4, y).glyph == String("u") \
                and c.get(5, y).glyph == String("t"):
            found = True
    assert_true(found)


fn _find_glyph_x(c: Canvas, y: Int, glyph: String) -> Int:
    """Locate the first column at row ``y`` whose glyph matches
    ``glyph``. Returns -1 when not found."""
    for x in range(c.width):
        if c.get(x, y).glyph == glyph:
            return x
    return -1


fn test_debug_pane_traceback_link_underlines_span() raises:
    """A Python-style ``File "<path>", line N`` entry in the output log
    must paint with an underline + LIGHT_BLUE foreground over the whole
    ``File "..." , line N`` span so users see it as a clickable link."""
    var pane = DebugPane()
    pane.visible = True
    pane.set_mode(PANE_MODE_RUN)
    pane.append_output(String('  File "/tmp/foo.py", line 42, in main'))
    var c = Canvas(60, 8)
    pane.paint(c, Rect(0, 0, 60, 8))
    # Find ``F`` of ``File`` on whichever row Output painted to.
    var link_y = -1
    var link_x = -1
    for y in range(2, 8):
        var x = _find_glyph_x(c, y, String("F"))
        if x >= 0 and c.get(x + 1, y).glyph == String("i"):
            link_y = y
            link_x = x
            break
    assert_true(link_y >= 0)
    # The first cell of ``File`` must carry the link styling.
    var head = c.get(link_x, link_y)
    assert_equal(head.attr.fg, LIGHT_BLUE)
    assert_true((head.attr.style & STYLE_UNDERLINE) != 0)
    # The closing digit ``2`` of ``42`` is the last cell of the span;
    # no need to recompute the offset, just walk forward until we find
    # ``2`` followed by ``,``.
    var two_x = -1
    for x in range(link_x, c.width - 1):
        if c.get(x, link_y).glyph == String("2") \
                and c.get(x + 1, link_y).glyph == String(","):
            two_x = x
            break
    assert_true(two_x >= 0)
    var tail = c.get(two_x, link_y)
    assert_equal(tail.attr.fg, LIGHT_BLUE)
    assert_true((tail.attr.style & STYLE_UNDERLINE) != 0)
    # The trailing comma after the digits is *not* part of the link.
    var after = c.get(two_x + 1, link_y)
    assert_equal(after.attr.fg, WHITE)
    assert_true((after.attr.style & STYLE_UNDERLINE) == 0)


fn test_debug_pane_plain_output_has_no_link_styling() raises:
    """A line that doesn't match the traceback pattern is painted with
    the normal output attribute — no underline, default foreground."""
    var pane = DebugPane()
    pane.visible = True
    pane.set_mode(PANE_MODE_RUN)
    pane.append_output(String("just some output"))
    var c = Canvas(40, 8)
    pane.paint(c, Rect(0, 0, 40, 8))
    # Walk every cell that ended up with ``j`` of ``just`` and verify
    # neither styling artifact is present.
    for y in range(2, 8):
        var x = _find_glyph_x(c, y, String("j"))
        if x < 0:
            continue
        var cell = c.get(x, y)
        assert_equal(cell.attr.fg, WHITE)
        assert_true((cell.attr.style & STYLE_UNDERLINE) == 0)


fn test_debug_pane_click_on_traceback_link_sets_pending_open() raises:
    """Clicking inside the link span stores ``(path, line)`` for the
    host to consume. The trailing ``in main`` text is *not* part of the
    span, so a click on ``in`` falls through to the autoscroll-toggle
    path and leaves no pending request."""
    var pane = DebugPane()
    pane.visible = True
    pane.set_mode(PANE_MODE_RUN)
    pane.append_output(String('  File "/tmp/foo.py", line 42, in main'))
    var panel = Rect(0, 0, 60, 8)
    var c = Canvas(60, 8)
    pane.paint(c, panel)
    # Find ``F`` so we click on a known cell inside the link.
    var link_y = -1
    var link_x = -1
    for y in range(2, 8):
        var x = _find_glyph_x(c, y, String("F"))
        if x >= 0 and c.get(x + 1, y).glyph == String("i"):
            link_y = y
            link_x = x
            break
    assert_true(link_y >= 0)
    var hit = pane.handle_mouse(
        Event.mouse_event(
            Point(link_x + 2, link_y), MOUSE_BUTTON_LEFT, True, False,
        ),
        panel,
    )
    assert_true(hit)
    var req = pane.consume_open_request()
    assert_equal(req[0], String("/tmp/foo.py"))
    assert_equal(req[1], 42)
    # Second consume returns the cleared sentinel.
    var req2 = pane.consume_open_request()
    assert_equal(req2[0], String(""))
    assert_equal(req2[1], 0)
    # A click outside the link span (well past the digits) must NOT
    # set a pending open request — that path's reserved for the
    # autoscroll-toggle behaviour.
    _ = pane.handle_mouse(
        Event.mouse_event(
            Point(50, link_y), MOUSE_BUTTON_LEFT, True, False,
        ),
        panel,
    )
    var req3 = pane.consume_open_request()
    assert_equal(req3[0], String(""))


fn test_targets_dialog_edit_and_submit() raises:
    """A dialog round-trip: open with two existing targets, type a
    new name into the focused input, then add a third target — the
    final ``into_targets`` must reflect both edits and place the
    active marker on the original active row."""
    var src = ProjectTargets()
    var t1 = RunTarget()
    t1.name = String("alpha")
    t1.program = String("echo")
    t1.args.append(String("a"))
    src.targets.append(t1^)
    var t2 = RunTarget()
    t2.name = String("beta")
    t2.program = String("echo")
    t2.args.append(String("b"))
    src.targets.append(t2^)
    src.active = 1
    var dlg = TargetsDialog()
    dlg.open(src^)
    assert_true(dlg.active)
    assert_equal(len(dlg.entries), 2)
    # ``selected`` honors ``active`` — index 1 (beta).
    assert_equal(dlg.selected, 1)
    # Tab from list focus to the Name input, then append "X".
    _ = dlg.handle_key(Event.key_event(KEY_TAB))
    _ = dlg.handle_key(Event.key_event(UInt32(ord("X"))))
    var rebuilt = dlg.into_targets()
    assert_equal(rebuilt.targets[1].name, String("betaX"))
    # Active marker still points at the renamed row (we tracked it
    # by ``active_name`` set at open).
    assert_equal(rebuilt.targets[rebuilt.active].name, String("betaX"))


fn test_targets_dialog_add_and_remove() raises:
    """Adding then removing yields the original list (modulo empty
    ``run`` field on the new entry, which is fine for this test —
    we never persist it)."""
    var src = ProjectTargets()
    var t1 = RunTarget()
    t1.name = String("only")
    t1.program = String("echo")
    src.targets.append(t1^)
    src.active = 0
    var dlg = TargetsDialog()
    dlg.open(src^)
    # _activate_focus on Add — focus is on the list initially, walk
    # there via mouse-style direct manipulation.
    dlg.focus = 6   # _FOCUS_ADD
    _ = dlg.handle_key(Event.key_event(KEY_ENTER))
    assert_equal(len(dlg.entries), 2)
    assert_equal(dlg.selected, 1)
    # Selected is now the new "new" target. Switch focus to Remove
    # and activate.
    dlg.focus = 7   # _FOCUS_REMOVE
    _ = dlg.handle_key(Event.key_event(KEY_ENTER))
    assert_equal(len(dlg.entries), 1)
    assert_equal(dlg.entries[0].name, String("only"))


fn test_targets_dialog_save_button_submits() raises:
    var src = ProjectTargets()
    var t1 = RunTarget()
    t1.name = String("only")
    src.targets.append(t1^)
    src.active = 0
    var dlg = TargetsDialog()
    dlg.open(src^)
    dlg.focus = 8   # _FOCUS_SAVE
    _ = dlg.handle_key(Event.key_event(KEY_ENTER))
    assert_true(dlg.submitted)


fn test_targets_dialog_esc_discards_edits() raises:
    var src = ProjectTargets()
    var t1 = RunTarget()
    t1.name = String("a")
    src.targets.append(t1^)
    src.active = 0
    var dlg = TargetsDialog()
    dlg.open(src^)
    # Move to name input, type something, then ESC. Dialog should
    # close *and* not be submitted.
    _ = dlg.handle_key(Event.key_event(KEY_TAB))
    _ = dlg.handle_key(Event.key_event(UInt32(ord("Z"))))
    _ = dlg.handle_key(Event.key_event(KEY_ESC))
    assert_false(dlg.active)
    assert_false(dlg.submitted)


fn test_run_session_lifecycle() raises:
    """``RunSession.start`` spawns ``program`` + ``args``;
    ``poll_run_exit`` reaps the child and exposes its exit code."""
    var s = RunSession()
    var args = List[String]()
    args.append(String("-c"))
    args.append(String("printf 'hi\\n'; exit 7"))
    s.start(
        String("echo-test"), String("sh"), args^, String(""),
    )
    assert_true(s.is_active())
    assert_true(s.matches(String("echo-test")))
    # Drain output until the child exits. Bound the loop so a stuck
    # test fails rather than hangs the whole suite.
    var captured = String("")
    var ticks = 0
    # Each tick polls stdout (non-blocking) and waitpid_nohang. The
    # spawn pipeline goes through two ``sh`` instances now (outer
    # shell ``exec``-ing the inner ``sh -c …``), so leave plenty of
    # iterations — the child still wins the race almost always, but
    # CI under load occasionally needs a few hundred polls.
    while ticks < 2000:
        var out = drain_run_output(s)
        captured = captured + out.stdout
        if poll_run_exit(s):
            break
        ticks += 1
    assert_true(s.exited)
    assert_equal(s.exit_code, 7)
    s.terminate()
    assert_false(s.is_active())
    # Captured output had the printf payload — covers the drain path
    # at least once (the kernel may deliver before or after exit).
    var cb = captured.as_bytes()
    var has_hi = False
    for i in range(len(cb)):
        if i + 1 < len(cb) and cb[i] == 0x68 and cb[i + 1] == 0x69:
            has_hi = True
            break
    assert_true(has_hi)


fn test_doc_registry_lookup() raises:
    """Built-in docsets should resolve every language id we ship with
    a server in the LSP catalog (so the user can hit Ctrl+K on the
    same files Cmd+click works on), and every spec's language_id must
    round-trip through both lookup helpers."""
    var specs = built_in_docsets()
    assert_true(len(specs) > 0)
    # Spot-check the python entry: extension routing + language lookup
    # both find it, and the slug is the pinned form (not bare "python").
    var py_idx = find_docset_for_extension(specs, String("py"))
    assert_true(py_idx >= 0)
    assert_equal(specs[py_idx].language_id, String("python"))
    var by_lang = find_docset_by_language(specs, String("python"))
    assert_equal(by_lang, py_idx)
    var pb = specs[py_idx].slug.as_bytes()
    var has_tilde = False
    for i in range(len(pb)):
        if pb[i] == 0x7E:    # '~'
            has_tilde = True
            break
    assert_true(has_tilde)
    # Unknown extension hits the not-found path.
    assert_equal(find_docset_for_extension(specs, String("xyz")), -1)


fn test_doc_install_command_shape() raises:
    """The install command must:
    * mkdir the destination dir,
    * curl both index.json and db.json,
    * use ``-f`` so an HTTP 4xx writes nothing rather than saving an
      error page as the docset (and keeps the install runner's
      "non-zero exit on failure" contract intact)."""
    var cmd = docs_install_command(
        String("python~3.12"),
        String("/tmp/.turbokod/docs/python~3.12"),
    )
    var b = cmd.as_bytes()
    # ``index.json`` and ``db.json`` both referenced.
    var idx_marker = String("index.json")
    var db_marker  = String("db.json")
    var ib = idx_marker.as_bytes()
    var dbb = db_marker.as_bytes()
    var found_idx = False
    var found_db = False
    for i in range(len(b)):
        if i + len(ib) <= len(b):
            var matches = True
            for k in range(len(ib)):
                if b[i + k] != ib[k]:
                    matches = False
                    break
            if matches:
                found_idx = True
        if i + len(dbb) <= len(b):
            var matches2 = True
            for k in range(len(dbb)):
                if b[i + k] != dbb[k]:
                    matches2 = False
                    break
            if matches2:
                found_db = True
    assert_true(found_idx)
    assert_true(found_db)
    # ``-f`` flag (curl's "fail silently on HTTP error") is in both
    # invocations — the input-flag character ``f`` should appear at
    # least twice. Coarse but enough to detect a regression that
    # silently drops the flag.
    var f_count = 0
    for i in range(len(b)):
        if i + 1 < len(b) and b[i] == 0x2D and b[i + 1] == 0x66:    # '-f'
            f_count += 1
    assert_true(f_count >= 2)
    # mkdir -p so a missing parent doesn't bork the run.
    var mkdir_marker = String("mkdir -p")
    var mb = mkdir_marker.as_bytes()
    var has_mkdir = False
    for i in range(len(b) - len(mb) + 1):
        var matches = True
        for k in range(len(mb)):
            if b[i + k] != mb[k]:
                matches = False
                break
        if matches:
            has_mkdir = True
            break
    assert_true(has_mkdir)


fn test_html_to_text_basics() raises:
    """Tags strip cleanly, entities decode, ``<b>`` becomes ``**``, and
    paragraphs are separated by a blank line."""
    var rendered = html_to_text(String(
        "<p>Hello, <b>world</b>!</p>"
        + String("<p>Second &amp; line.</p>"),
    ))
    # ``<b>`` rendered as markdown bold around its content.
    var b = rendered.as_bytes()
    var marker = String("Hello, **world**!")
    var mb = marker.as_bytes()
    var found = False
    for i in range(len(b) - len(mb) + 1):
        var ok = True
        for k in range(len(mb)):
            if b[i + k] != mb[k]:
                ok = False
                break
        if ok:
            found = True
            break
    assert_true(found)
    # Entity decoded.
    var amp_marker = String("Second & line.")
    var ab = amp_marker.as_bytes()
    var amp_found = False
    for i in range(len(b) - len(ab) + 1):
        var ok = True
        for k in range(len(ab)):
            if b[i + k] != ab[k]:
                ok = False
                break
        if ok:
            amp_found = True
            break
    assert_true(amp_found)
    # Paragraphs separated by a blank line (``\n\n``) — that's the bit
    # the old non-markdown renderer was missing.
    var blank_marker = String("**!\n\nSecond")
    var blb = blank_marker.as_bytes()
    var blank_found = False
    for i in range(len(b) - len(blb) + 1):
        var ok = True
        for k in range(len(blb)):
            if b[i + k] != blb[k]:
                ok = False
                break
        if ok:
            blank_found = True
            break
    assert_true(blank_found)
    # No leftover '<' or '>' from tags.
    for i in range(len(b)):
        assert_true(b[i] != 0x3C and b[i] != 0x3E)


fn test_html_to_text_headings_become_hashes() raises:
    """``<h1>`` -> ``#``, ``<h2>`` -> ``##``, … with a blank line below."""
    var rendered = html_to_text(String(
        "<h1>Title</h1><h2>Sub</h2><p>Body.</p>"
    ))
    var b = rendered.as_bytes()
    var want = String("# Title\n\n## Sub\n\nBody.")
    var wb = want.as_bytes()
    var found = False
    for i in range(len(b) - len(wb) + 1):
        var ok = True
        for k in range(len(wb)):
            if b[i + k] != wb[k]:
                ok = False
                break
        if ok:
            found = True
            break
    assert_true(found)


fn test_html_to_text_lists_and_inline() raises:
    """``<ul>`` items get ``- ``, ``<ol>`` items get ``1. ``,
    ``<code>`` becomes backticks, ``<a href>`` becomes
    ``[text](href)``."""
    var rendered = html_to_text(String(
        "<p>Try <a href=\"x.html\">this</a> or <code>foo</code>.</p>"
        + String("<ul><li>one</li><li>two</li></ul>")
        + String("<ol><li>first</li><li>second</li></ol>"),
    ))
    var b = rendered.as_bytes()
    # Inline link.
    var link_m = String("[this](x.html)")
    var lmb = link_m.as_bytes()
    var link_found = False
    for i in range(len(b) - len(lmb) + 1):
        var ok = True
        for k in range(len(lmb)):
            if b[i + k] != lmb[k]:
                ok = False
                break
        if ok:
            link_found = True
            break
    assert_true(link_found)
    # Inline code.
    var code_m = String("`foo`")
    var cmb = code_m.as_bytes()
    var code_found = False
    for i in range(len(b) - len(cmb) + 1):
        var ok = True
        for k in range(len(cmb)):
            if b[i + k] != cmb[k]:
                ok = False
                break
        if ok:
            code_found = True
            break
    assert_true(code_found)
    # ``<ul>`` items.
    var ul_m = String("- one\n- two")
    var umb = ul_m.as_bytes()
    var ul_found = False
    for i in range(len(b) - len(umb) + 1):
        var ok = True
        for k in range(len(umb)):
            if b[i + k] != umb[k]:
                ok = False
                break
        if ok:
            ul_found = True
            break
    assert_true(ul_found)
    # ``<ol>`` items numbered.
    var ol_m = String("1. first\n2. second")
    var omb = ol_m.as_bytes()
    var ol_found = False
    for i in range(len(b) - len(omb) + 1):
        var ok = True
        for k in range(len(omb)):
            if b[i + k] != omb[k]:
                ok = False
                break
        if ok:
            ol_found = True
            break
    assert_true(ol_found)


fn test_html_to_text_pre_uses_fence() raises:
    """``<pre>`` blocks are wrapped in ```` ``` ```` fences while
    keeping their internal whitespace verbatim."""
    var rendered = html_to_text(String(
        "<p>before</p><pre>fn foo():\n    return 42</pre><p>after</p>"
    ))
    var b = rendered.as_bytes()
    var want = String("```\nfn foo():\n    return 42\n```")
    var wb = want.as_bytes()
    var found = False
    for i in range(len(b) - len(wb) + 1):
        var ok = True
        for k in range(len(wb)):
            if b[i + k] != wb[k]:
                ok = False
                break
        if ok:
            found = True
            break
    assert_true(found)


fn test_html_to_text_preserves_pre() raises:
    """``<pre>`` blocks must keep their internal whitespace verbatim —
    that's the whole point of code samples in the docs.

    We use a deliberately weird indent that a generic whitespace-collapse
    pass would mangle (two leading spaces, internal tab) so a regression
    that breaks the ``pre_depth`` branch shows up as a failed match.
    """
    var html = String(
        "<p>before</p><pre>  fn foo():\n\treturn 42</pre><p>after</p>"
    )
    var rendered = html_to_text(html)
    # The tab and leading two spaces survived.
    var marker = String("  fn foo():\n\treturn 42")
    var b = rendered.as_bytes()
    var mb = marker.as_bytes()
    var found = False
    for i in range(len(b) - len(mb) + 1):
        var ok = True
        for k in range(len(mb)):
            if b[i + k] != mb[k]:
                ok = False
                break
        if ok:
            found = True
            break
    assert_true(found)


fn test_find_doc_entry_exact_match_wins() raises:
    """Exact name match beats both case-insensitive and suffix matches.

    Without this priority a click on ``find`` (which has a top-level
    DevDocs entry in some languages) would land on a method like
    ``str.find`` instead of the canonical entry, even though both are
    plausible — the LSP couldn't resolve, so we don't know which one
    the user meant. Exact equality is the least surprising default.
    """
    var entries = List[DocEntry]()
    entries.append(DocEntry(
        String("str.find"), String("library/str"),
        String("find"), String("Methods"),
    ))
    entries.append(DocEntry(
        String("find"), String("library/find"),
        String(""), String("Built-in Functions"),
    ))
    var idx = _find_doc_entry_for_word(entries, String("find"))
    # Exact "find" should win over the suffix match on "str.find".
    assert_equal(idx, 1)


fn test_find_doc_entry_falls_back_to_suffix_match() raises:
    """When no entry matches the bare word, ``foo`` should still resolve
    to ``Type.foo`` so a Cmd+click on ``s.find()`` opens ``str.find``."""
    var entries = List[DocEntry]()
    entries.append(DocEntry(
        String("dict.get"), String("library/stdtypes"),
        String("dict.get"), String("Methods"),
    ))
    entries.append(DocEntry(
        String("str.find"), String("library/stdtypes"),
        String("str.find"), String("Methods"),
    ))
    var idx = _find_doc_entry_for_word(entries, String("find"))
    assert_equal(idx, 1)


fn test_find_doc_entry_returns_minus_one_when_no_match() raises:
    var entries = List[DocEntry]()
    entries.append(DocEntry(
        String("abs"), String("library/functions"),
        String("abs"), String("Built-in Functions"),
    ))
    assert_equal(
        _find_doc_entry_for_word(entries, String("nonexistent")),
        -1,
    )
    # Empty word never matches anything.
    assert_equal(_find_doc_entry_for_word(entries, String("")), -1)


fn test_find_doc_entry_case_insensitive_when_no_exact() raises:
    """CSS / HTML docs spell some entries lowercase even if the source
    site uses TitleCase; a Cmd+click that comes back empty from the
    LSP should still find the entry. Exact match would have already
    been preferred (this case has none), so case-folded match is the
    next best signal."""
    var entries = List[DocEntry]()
    entries.append(DocEntry(
        String("Display"), String("css/display"),
        String(""), String("Properties"),
    ))
    var idx = _find_doc_entry_for_word(entries, String("display"))
    assert_equal(idx, 0)


fn test_html_to_text_strips_script_and_style() raises:
    """``<script>`` / ``<style>`` content must not leak into the
    rendered text. DevDocs HTML doesn't ship script tags, but vendored
    HTML from arbitrary doc sources sometimes does, and surfacing
    JavaScript verbatim in a doc viewer is jarring."""
    var rendered = html_to_text(String(
        "<p>Hi</p><script>alert('boom');</script><p>bye</p>",
    ))
    var b = rendered.as_bytes()
    var bad = String("alert")
    var bb = bad.as_bytes()
    var leaked = False
    for i in range(len(b) - len(bb) + 1):
        var ok = True
        for k in range(len(bb)):
            if b[i + k] != bb[k]:
                ok = False
                break
        if ok:
            leaked = True
            break
    assert_false(leaked)


fn test_html_to_text_table_renders_as_gfm_table() raises:
    """``<table>`` becomes a GFM table: pipe-bordered rows, a separator
    after the first row, columns padded to the widest cell, and inline
    markup inside cells survives the recursive cell render. The earlier
    renderer just emitted tab-separated cells, which collapsed to a
    single illegible line in the doc pane.
    """
    # Inline markup, header row, multiple body rows, ragged cell widths.
    var rendered = html_to_text(String(
        "<p>Before.</p>"
        + String("<table>")
        + String("<tr><th>Function</th><th>Description</th></tr>")
        + String("<tr><td><code>abs(x)</code></td>")
        + String("<td>The <em>absolute</em> value of <strong>x</strong>.</td></tr>")
        + String("<tr><td><code>min(a)</code></td><td>min docs.</td></tr>")
        + String("</table>")
        + String("<p>After.</p>"),
    ))
    var want = String(
        "Before.\n\n"
        + String("| Function | Description                    |\n")
        + String("| -------- | ------------------------------ |\n")
        + String("| `abs(x)` | The *absolute* value of **x**. |\n")
        + String("| `min(a)` | min docs.                      |\n")
        + String("\nAfter."),
    )
    var b = rendered.as_bytes()
    var wb = want.as_bytes()
    var found = False
    for i in range(len(b) - len(wb) + 1):
        var ok = True
        for k in range(len(wb)):
            if b[i + k] != wb[k]:
                ok = False
                break
        if ok:
            found = True
            break
    assert_true(found)


fn test_html_to_text_table_escapes_pipes_in_cells() raises:
    """A literal ``|`` inside a cell would otherwise terminate the cell
    early and shift every column to its right; we escape as ``\\|``."""
    var rendered = html_to_text(String(
        "<table><tr><th>Op</th></tr><tr><td>a|b</td></tr></table>",
    ))
    var b = rendered.as_bytes()
    var want = String("| a\\|b |")
    var wb = want.as_bytes()
    var found = False
    for i in range(len(b) - len(wb) + 1):
        var ok = True
        for k in range(len(wb)):
            if b[i + k] != wb[k]:
                ok = False
                break
        if ok:
            found = True
            break
    assert_true(found)


fn test_text_field_clipboard_key_ignores_non_key_event() raises:
    var text = String("hello")
    var ev = Event.mouse_event(Point(0, 0), MOUSE_BUTTON_LEFT)
    var r = text_field_clipboard_key(ev, text)
    assert_false(r.consumed)
    assert_false(r.changed)
    assert_equal(text, String("hello"))


fn test_text_field_clipboard_key_ignores_printable() raises:
    var text = String("abc")
    var r = text_field_clipboard_key(Event.key_event(UInt32(ord("d"))), text)
    assert_false(r.consumed)
    assert_false(r.changed)
    assert_equal(text, String("abc"))


fn test_text_field_clipboard_key_ctrl_x_clears_text() raises:
    var text = String("delete me")
    var r = text_field_clipboard_key(Event.key_event(UInt32(0x18)), text)
    assert_true(r.consumed)
    assert_true(r.changed)
    assert_equal(text, String(""))
    # A second Ctrl+X on the now-empty field still consumes the keystroke
    # but reports nothing changed (no spurious refilters / dirty marks).
    var r2 = text_field_clipboard_key(Event.key_event(UInt32(0x18)), text)
    assert_true(r2.consumed)
    assert_false(r2.changed)


fn test_text_field_clipboard_key_round_trips_through_clipboard() raises:
    """Ctrl+X copies to the system clipboard; a subsequent Ctrl+V on a
    fresh field should restore the same payload. Validates the
    end-to-end framework path; relies on the platform's clipboard
    helper (pbcopy/pbpaste on macOS) being available."""
    var src = String("payload-from-ctrl-x")
    _ = text_field_clipboard_key(Event.key_event(UInt32(0x18)), src)
    var dst = String("")
    var r = text_field_clipboard_key(Event.key_event(UInt32(0x16)), dst)
    assert_true(r.consumed)
    assert_true(r.changed)
    assert_equal(dst, String("payload-from-ctrl-x"))


fn test_session_round_trip() raises:
    """A persisted session should decode to the same fields it was
    encoded from. Covers the full ``encode_session`` → ``parse_json``
    → ``load_session`` path against a temp project root so the test
    doesn't touch the repo's own ``.turbokod/session.json``."""
    var root = String("/tmp/turbokod_session_test_round_trip")
    # Clean up any prior run so a stale ``.turbokod/`` doesn't shadow
    # the empty-state assertion below.
    _ = external_call["system", Int32](
        (String("rm -rf '") + root + String("'\0")).unsafe_ptr(),
    )
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var s = Session()
    var w0 = SessionWindow()
    w0.path = String("src/turbokod/desktop.mojo")
    w0.rect_a_x = 5
    w0.rect_a_y = 3
    w0.rect_b_x = 75
    w0.rect_b_y = 28
    w0.is_maximized = False
    w0.restore_a_x = 5
    w0.restore_a_y = 3
    w0.restore_b_x = 75
    w0.restore_b_y = 28
    w0.cursor_row = 42
    w0.cursor_col = 7
    w0.scroll_x = 0
    w0.scroll_y = 30
    s.windows.append(w0^)
    var w1 = SessionWindow()
    w1.path = String("/abs/somewhere/else.txt")
    w1.rect_a_x = 0
    w1.rect_a_y = 0
    w1.rect_b_x = 40
    w1.rect_b_y = 20
    w1.is_maximized = True
    w1.restore_a_x = 10
    w1.restore_a_y = 4
    w1.restore_b_x = 60
    w1.restore_b_y = 22
    w1.cursor_row = 0
    w1.cursor_col = 12
    w1.scroll_x = 5
    w1.scroll_y = 0
    s.windows.append(w1^)
    s.z_order.append(1)
    s.z_order.append(0)
    s.focused = 0
    assert_true(save_session(root, s))
    var loaded = load_session(root)
    assert_equal(len(loaded.windows), 2)
    assert_equal(loaded.windows[0].path, String("src/turbokod/desktop.mojo"))
    assert_equal(loaded.windows[0].rect_a_x, 5)
    assert_equal(loaded.windows[0].rect_b_y, 28)
    assert_equal(loaded.windows[0].cursor_row, 42)
    assert_equal(loaded.windows[0].scroll_y, 30)
    assert_false(loaded.windows[0].is_maximized)
    assert_true(loaded.windows[1].is_maximized)
    assert_equal(loaded.windows[1].restore_a_x, 10)
    assert_equal(loaded.windows[1].path, String("/abs/somewhere/else.txt"))
    assert_equal(len(loaded.z_order), 2)
    assert_equal(loaded.z_order[0], 1)
    assert_equal(loaded.z_order[1], 0)
    assert_equal(loaded.focused, 0)
    # Cleanup so re-running the test starts from a clean state.
    _ = external_call["system", Int32](
        (String("rm -rf '") + root + String("'\0")).unsafe_ptr(),
    )


fn test_session_load_missing_returns_empty() raises:
    """A project root with no ``.turbokod/session.json`` should yield
    an empty session — that's the signal ``_restore_session`` uses to
    skip the restore path entirely."""
    var s = load_session(String("/tmp/turbokod_session_does_not_exist_abcxyz"))
    assert_equal(len(s.windows), 0)
    assert_equal(len(s.z_order), 0)
    assert_equal(s.focused, -1)


fn test_session_relative_path_round_trip() raises:
    """``_session_relative`` strips the project prefix; the inverse
    re-anchors. Files outside the project keep their absolute form
    on the way out and pass through on the way back in."""
    var root = String("/Users/foo/proj")
    var inside = String("/Users/foo/proj/src/main.mojo")
    var outside = String("/etc/hosts")
    var rel_in = _session_relative(root, inside)
    assert_equal(rel_in, String("src/main.mojo"))
    var rel_out = _session_relative(root, outside)
    assert_equal(rel_out, outside)
    var resolved_in = _resolve_session_path(root, rel_in)
    assert_equal(resolved_in, inside)
    var resolved_out = _resolve_session_path(root, rel_out)
    assert_equal(resolved_out, outside)


fn test_desktop_restores_session_from_disk() raises:
    """Open a project that already has a ``.turbokod/session.json`` and
    confirm the desktop replays it: a window for the saved file shows
    up, the rect / cursor / scroll are reapplied, and the focused
    index points at the saved entry."""
    var root = String("/tmp/turbokod_session_restore_test")
    var cleanup = String("rm -rf '") + root + String("'\0")
    _ = external_call["system", Int32](cleanup.unsafe_ptr())
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var file_path = root + String("/foo.txt")
    assert_true(write_file(file_path, String("alpha\nbeta\ngamma\ndelta\n")))
    # Author a session that places the file at a non-default rect with
    # cursor on row 2 col 3.
    var s = Session()
    var sw = SessionWindow()
    sw.path = String("foo.txt")
    sw.rect_a_x = 4
    sw.rect_a_y = 2
    sw.rect_b_x = 50
    sw.rect_b_y = 18
    sw.is_maximized = False
    sw.restore_a_x = 4
    sw.restore_a_y = 2
    sw.restore_b_x = 50
    sw.restore_b_y = 18
    sw.cursor_row = 2
    sw.cursor_col = 3
    sw.scroll_x = 0
    sw.scroll_y = 0
    s.windows.append(sw^)
    s.z_order.append(0)
    s.focused = 0
    assert_true(save_session(root, s))
    var d = Desktop()
    d.open_project(root)
    assert_true(d.project)
    assert_true(d._pending_restore)
    var screen = Rect(0, 0, 80, 30)
    d._pending_restore = False
    d._restore_session(screen)
    assert_equal(len(d.windows.windows), 1)
    var w0 = d.windows.windows[0]
    assert_true(w0.is_editor)
    assert_equal(w0.rect.a.x, 4)
    assert_equal(w0.rect.a.y, 2)
    assert_equal(w0.rect.b.x, 50)
    assert_equal(w0.rect.b.y, 18)
    assert_equal(w0.editor.cursor_row, 2)
    assert_equal(w0.editor.cursor_col, 3)
    assert_equal(d.windows.focused, 0)
    _ = external_call["system", Int32](cleanup.unsafe_ptr())


fn test_desktop_resize_reapplies_clipped_session_rect() raises:
    """When the first restore lands on a smaller-than-saved workspace
    (the host pushes its real dimensions a few ms after startup), the
    saved rects get clipped down. A subsequent resize event must re-
    apply the originally-saved rects against the now-correct
    workspace, instead of leaving windows stuck at their initial
    clip values forever."""
    var root = String("/tmp/turbokod_resize_reapply_test")
    var cleanup = String("rm -rf '") + root + String("'\0")
    _ = external_call["system", Int32](cleanup.unsafe_ptr())
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var file_path = root + String("/foo.txt")
    assert_true(write_file(file_path, String("a\nb\nc\n")))
    var s = Session()
    var sw = SessionWindow()
    sw.path = String("foo.txt")
    # Saved rect (20, 8, 75, 24) — fits a 100x30 screen, NOT a 80x24 one.
    sw.rect_a_x = 20
    sw.rect_a_y = 8
    sw.rect_b_x = 75
    sw.rect_b_y = 24
    sw.is_maximized = False
    sw.restore_a_x = 20
    sw.restore_a_y = 8
    sw.restore_b_x = 75
    sw.restore_b_y = 24
    s.windows.append(sw^)
    s.z_order.append(0)
    s.focused = 0
    assert_true(save_session(root, s))
    var d = Desktop()
    d.open_project(root)
    d._pending_restore = False
    # First restore at the cramped 80x24 workspace clips ay from 8 to 7.
    d._restore_session(Rect(0, 0, 80, 24))
    assert_equal(len(d.windows.windows), 1)
    var initial = d.windows.windows[0].rect
    assert_equal(initial.a.y, 7)
    assert_equal(initial.b.y, 23)
    # The host now pushes the real dimensions — feed an EVENT_RESIZE
    # to the desktop and confirm the saved rect is re-applied at the
    # larger workspace.
    var resize_ev = Event.resize_event(100, 30)
    _ = d.handle_event(resize_ev, Rect(0, 0, 100, 30))
    var refit = d.windows.windows[0].rect
    assert_equal(refit.a.x, 20)
    assert_equal(refit.a.y, 8)
    assert_equal(refit.b.x, 75)
    assert_equal(refit.b.y, 24)
    _ = external_call["system", Int32](cleanup.unsafe_ptr())


fn test_desktop_arms_session_restore_when_non_editor_windows_present() raises:
    """``_set_project`` must arm the session restore even when host-added
    placeholder windows are already present. Regression for: a host that
    adds non-file-backed demo windows before opening a file blocked the
    restore path entirely, and the subsequent save then overwrote the
    on-disk session with the cascade-default rect."""
    var root = String("/tmp/turbokod_set_project_arms_restore_test")
    var cleanup = String("rm -rf '") + root + String("'\0")
    _ = external_call["system", Int32](cleanup.unsafe_ptr())
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var d = Desktop()
    # Host adds a non-editor placeholder window (mimicking demo content)
    # before any project is set.
    var placeholder_lines = List[String]()
    placeholder_lines.append(String("placeholder"))
    d.windows.add(Window(
        String("Demo"), Rect(4, 3, 50, 16), placeholder_lines^,
    ))
    assert_equal(len(d.windows.windows), 1)
    d.open_project(root)
    assert_true(d._pending_restore)
    _ = external_call["system", Int32](cleanup.unsafe_ptr())


fn test_desktop_restores_non_maximized_rect_not_restore_rect() raises:
    """When a saved window's ``rect`` differs from its ``restore_rect``
    (e.g. user dragged a non-maximized window after creation, so the
    constructor-stamped ``_restore_rect`` is now stale), restoring it
    must place the window at ``rect`` — the user's last-known position
    — not at ``restore_rect``. Regression for: new windows pulled in
    from session were being constructed with ``restore``, so a moved
    non-maximized window came back at its original cascade slot."""
    var root = String("/tmp/turbokod_restore_rect_vs_rect_test")
    var cleanup = String("rm -rf '") + root + String("'\0")
    _ = external_call["system", Int32](cleanup.unsafe_ptr())
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var file_path = root + String("/moved.txt")
    assert_true(write_file(file_path, String("one\ntwo\n")))
    var s = Session()
    var sw = SessionWindow()
    sw.path = String("moved.txt")
    # User dragged the window to (20, 8, 80, 28); the stale
    # ``_restore_rect`` is the original cascade slot at (5, 2, 60, 20).
    sw.rect_a_x = 20
    sw.rect_a_y = 8
    sw.rect_b_x = 80
    sw.rect_b_y = 28
    sw.is_maximized = False
    sw.restore_a_x = 5
    sw.restore_a_y = 2
    sw.restore_b_x = 60
    sw.restore_b_y = 20
    sw.cursor_row = 0
    sw.cursor_col = 0
    sw.scroll_x = 0
    sw.scroll_y = 0
    s.windows.append(sw^)
    s.z_order.append(0)
    s.focused = 0
    assert_true(save_session(root, s))
    var d = Desktop()
    d.open_project(root)
    d._pending_restore = False
    d._restore_session(Rect(0, 0, 100, 30))
    assert_equal(len(d.windows.windows), 1)
    var w0 = d.windows.windows[0]
    assert_equal(w0.rect.a.x, 20)
    assert_equal(w0.rect.a.y, 8)
    assert_equal(w0.rect.b.x, 80)
    assert_equal(w0.rect.b.y, 28)
    # ``_restore_rect`` should preserve the saved un-maximized rect so
    # a later un-maximize lands the window where the user last left it
    # *before* maximizing — even though we never maximized in this run.
    assert_equal(w0._restore_rect.a.x, 5)
    assert_equal(w0._restore_rect.b.x, 60)
    _ = external_call["system", Int32](cleanup.unsafe_ptr())


fn test_desktop_snapshot_captures_per_window_rects() raises:
    """Each open file-backed window must show up in the snapshot with
    its own rect. Regression guard: a copy bug or wrong loop variable
    would yield identical rects across the session entries."""
    var root = String("/tmp/turbokod_snapshot_rects_test")
    var cleanup = String("rm -rf '") + root + String("'\0")
    _ = external_call["system", Int32](cleanup.unsafe_ptr())
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    assert_true(write_file(root + String("/a.txt"), String("aaa\n")))
    assert_true(write_file(root + String("/b.txt"), String("bbb\n")))
    var d = Desktop()
    d.open_project(root)
    d._pending_restore = False     # skip any auto-restore in this test
    var screen = Rect(0, 0, 80, 30)
    d.open_file(root + String("/a.txt"), screen)
    d.open_file(root + String("/b.txt"), screen)
    assert_equal(len(d.windows.windows), 2)
    # Force the two windows to distinct rects via direct mutation —
    # avoids depending on the cascade default sliding them apart by
    # exactly some specific amount.
    d.windows.windows[0].rect = Rect(2, 1, 30, 12)
    d.windows.windows[0]._restore_rect = Rect(2, 1, 30, 12)
    d.windows.windows[0].is_maximized = False
    d.windows.windows[1].rect = Rect(40, 5, 75, 25)
    d.windows.windows[1]._restore_rect = Rect(40, 5, 75, 25)
    d.windows.windows[1].is_maximized = False
    var session = d._snapshot_session()
    assert_equal(len(session.windows), 2)
    # The snapshot should map each window through to its own rect, not
    # a shared one. We don't depend on order — find by path suffix
    # (the snapshot may emit relative or absolute paths depending on
    # whether ``editor.file_path`` is canonical-equal to the
    # project root).
    var idx_a = -1
    var idx_b = -1
    for i in range(len(session.windows)):
        var p = session.windows[i].path
        var pb = p.as_bytes()
        var alen = len(String("a.txt").as_bytes())
        var blen = len(String("b.txt").as_bytes())
        if len(pb) >= alen \
                and String(StringSlice(unsafe_from_utf8=pb[len(pb) - alen:])) \
                == String("a.txt"):
            idx_a = i
        if len(pb) >= blen \
                and String(StringSlice(unsafe_from_utf8=pb[len(pb) - blen:])) \
                == String("b.txt"):
            idx_b = i
    assert_true(idx_a >= 0)
    assert_true(idx_b >= 0)
    assert_equal(session.windows[idx_a].rect_a_x, 2)
    assert_equal(session.windows[idx_a].rect_b_x, 30)
    assert_equal(session.windows[idx_b].rect_a_x, 40)
    assert_equal(session.windows[idx_b].rect_b_x, 75)
    _ = external_call["system", Int32](cleanup.unsafe_ptr())


fn test_desktop_restores_multiple_windows_at_distinct_positions() raises:
    """Two saved windows must come back at the *two* rects on disk —
    not both at the same position. Regression guard against snapshot
    or restore code accidentally copying one window's rect into the
    others (e.g. a closure-capture or single-Rect-buffer bug)."""
    var root = String("/tmp/turbokod_session_multi_test")
    var cleanup = String("rm -rf '") + root + String("'\0")
    _ = external_call["system", Int32](cleanup.unsafe_ptr())
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    assert_true(write_file(root + String("/foo.txt"), String("a\nb\nc\n")))
    assert_true(write_file(root + String("/bar.txt"), String("x\ny\nz\nw\n")))
    var s = Session()
    var w0 = SessionWindow()
    w0.path = String("foo.txt")
    w0.rect_a_x = 2
    w0.rect_a_y = 1
    w0.rect_b_x = 30
    w0.rect_b_y = 12
    w0.restore_a_x = 2
    w0.restore_a_y = 1
    w0.restore_b_x = 30
    w0.restore_b_y = 12
    s.windows.append(w0^)
    var w1 = SessionWindow()
    w1.path = String("bar.txt")
    w1.rect_a_x = 40
    w1.rect_a_y = 5
    w1.rect_b_x = 75
    w1.rect_b_y = 25
    w1.restore_a_x = 40
    w1.restore_a_y = 5
    w1.restore_b_x = 75
    w1.restore_b_y = 25
    w1.cursor_row = 1
    w1.cursor_col = 2
    s.windows.append(w1^)
    s.z_order.append(0)
    s.z_order.append(1)
    s.focused = 1
    assert_true(save_session(root, s))
    var d = Desktop()
    d.open_project(root)
    var screen = Rect(0, 0, 80, 30)
    d._pending_restore = False
    d._restore_session(screen)
    assert_equal(len(d.windows.windows), 2)
    # ``open_project`` canonicalizes via ``realpath``, so on macOS the
    # stored project root is ``/private/tmp/...``, not ``/tmp/...``.
    # Compare against the canonical project root rather than the
    # original test path.
    var canonical = d.project.value()
    var foo_idx = -1
    var bar_idx = -1
    for i in range(len(d.windows.windows)):
        var fp = d.windows.windows[i].editor.file_path
        if fp == canonical + String("/foo.txt"):
            foo_idx = i
        if fp == canonical + String("/bar.txt"):
            bar_idx = i
    assert_true(foo_idx >= 0)
    assert_true(bar_idx >= 0)
    assert_equal(d.windows.windows[foo_idx].rect.a.x, 2)
    assert_equal(d.windows.windows[foo_idx].rect.a.y, 1)
    assert_equal(d.windows.windows[foo_idx].rect.b.x, 30)
    assert_equal(d.windows.windows[foo_idx].rect.b.y, 12)
    assert_equal(d.windows.windows[bar_idx].rect.a.x, 40)
    assert_equal(d.windows.windows[bar_idx].rect.a.y, 5)
    assert_equal(d.windows.windows[bar_idx].rect.b.x, 75)
    assert_equal(d.windows.windows[bar_idx].rect.b.y, 25)
    assert_equal(d.windows.windows[bar_idx].editor.cursor_row, 1)
    assert_equal(d.windows.windows[bar_idx].editor.cursor_col, 2)
    assert_equal(d.windows.focused, bar_idx)
    _ = external_call["system", Int32](cleanup.unsafe_ptr())


fn test_desktop_restores_maximized_window_keeps_per_window_restore_rect() raises:
    """A saved maximized window must come back maximized AND keep its
    own ``_restore_rect`` so un-maximizing returns to the user's
    pre-max layout — not to the shared workspace rect. Regression for
    the bug where ``toggle_maximize`` clobbered the just-loaded
    ``_restore_rect``."""
    var root = String("/tmp/turbokod_session_max_test")
    var cleanup = String("rm -rf '") + root + String("'\0")
    _ = external_call["system", Int32](cleanup.unsafe_ptr())
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    assert_true(write_file(root + String("/m.txt"), String("m\n")))
    var s = Session()
    var sw = SessionWindow()
    sw.path = String("m.txt")
    # Saved state: window is maximized to a 100×30 workspace, but the
    # underlying un-maximized rect is small (8, 4)→(40, 18).
    sw.rect_a_x = 0
    sw.rect_a_y = 1
    sw.rect_b_x = 100
    sw.rect_b_y = 28
    sw.is_maximized = True
    sw.restore_a_x = 8
    sw.restore_a_y = 4
    sw.restore_b_x = 40
    sw.restore_b_y = 18
    s.windows.append(sw^)
    s.focused = 0
    assert_true(save_session(root, s))
    var d = Desktop()
    d.open_project(root)
    var screen = Rect(0, 0, 100, 30)
    d._pending_restore = False
    d._restore_session(screen)
    assert_equal(len(d.windows.windows), 1)
    var w = d.windows.windows[0]
    assert_true(w.is_maximized)
    # _restore_rect must reflect the saved un-maximized layout.
    assert_equal(w._restore_rect.a.x, 8)
    assert_equal(w._restore_rect.a.y, 4)
    assert_equal(w._restore_rect.b.x, 40)
    assert_equal(w._restore_rect.b.y, 18)
    _ = external_call["system", Int32](cleanup.unsafe_ptr())


fn test_desktop_save_then_restore_round_trip_through_paint() raises:
    """End-to-end: open two files in a project at distinct rects via
    ``paint`` (which writes the session), then construct a fresh
    ``Desktop`` against the same project and confirm the saved layout
    is restored. Covers the full ``_save_session_if_changed`` →
    ``load_session`` → ``_restore_session`` loop."""
    var root = String("/tmp/turbokod_session_e2e_test")
    var cleanup = String("rm -rf '") + root + String("'\0")
    _ = external_call["system", Int32](cleanup.unsafe_ptr())
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    assert_true(write_file(root + String("/p.txt"), String("p\n")))
    assert_true(write_file(root + String("/q.txt"), String("q\n")))
    var screen = Rect(0, 0, 80, 30)
    var canvas = Canvas(80, 30)

    # --- session 1: open two files, position them, paint to save ---------
    var d1 = Desktop()
    d1.open_project(root)
    d1.open_file(root + String("/p.txt"), screen)
    d1.open_file(root + String("/q.txt"), screen)
    assert_equal(len(d1.windows.windows), 2)
    d1.windows.windows[0].rect = Rect(2, 1, 30, 12)
    d1.windows.windows[0]._restore_rect = Rect(2, 1, 30, 12)
    d1.windows.windows[0].is_maximized = False
    d1.windows.windows[1].rect = Rect(40, 5, 75, 25)
    d1.windows.windows[1]._restore_rect = Rect(40, 5, 75, 25)
    d1.windows.windows[1].is_maximized = False
    d1.windows.focused = 1
    d1.paint(canvas, screen)
    var session_path = root + String("/.turbokod/session.json")
    assert_true(stat_file(session_path).ok)

    # --- session 2: fresh Desktop, restore via paint ---------------------
    var d2 = Desktop()
    d2.open_project(root)
    assert_true(d2._pending_restore)
    d2.paint(canvas, screen)
    assert_equal(len(d2.windows.windows), 2)
    var p_idx = -1
    var q_idx = -1
    for i in range(len(d2.windows.windows)):
        var fp = d2.windows.windows[i].editor.file_path
        var fpb = fp.as_bytes()
        var slen = len(String("/p.txt").as_bytes())
        if len(fpb) >= slen \
                and String(StringSlice(unsafe_from_utf8=fpb[len(fpb) - slen:])) \
                == String("/p.txt"):
            p_idx = i
        if len(fpb) >= slen \
                and String(StringSlice(unsafe_from_utf8=fpb[len(fpb) - slen:])) \
                == String("/q.txt"):
            q_idx = i
    assert_true(p_idx >= 0)
    assert_true(q_idx >= 0)
    # Each restored window must keep its own saved rect — not collapse
    # to a shared default.
    assert_true(d2.windows.windows[p_idx].rect.a.x \
                != d2.windows.windows[q_idx].rect.a.x)
    assert_equal(d2.windows.windows[p_idx].rect.a.x, 2)
    assert_equal(d2.windows.windows[p_idx].rect.b.x, 30)
    assert_equal(d2.windows.windows[q_idx].rect.a.x, 40)
    assert_equal(d2.windows.windows[q_idx].rect.b.x, 75)
    _ = external_call["system", Int32](cleanup.unsafe_ptr())


fn test_desktop_snapshot_skips_untitled_windows() raises:
    """``_snapshot_session`` filters out non-editor windows and
    file-less editors (Untitled buffers). Only file-backed editors
    show up in the saved session."""
    var d = Desktop()
    d.detect_project_from(String("examples/hello.mojo"))
    assert_true(d.project)
    var screen = Rect(0, 0, 80, 30)
    d.new_file(screen)                          # file-less Untitled
    try:
        d.open_file(String("examples/hello.mojo"), screen)
    except:
        pass
    var session = d._snapshot_session()
    # Only the file-backed window should be in the snapshot.
    assert_equal(len(session.windows), 1)
    var path = session.windows[0].path
    # Stored relative to the project root resolved by
    # ``find_git_project`` — for this checkout that's the repo root,
    # so the path becomes ``examples/hello.mojo``.
    assert_equal(path, String("examples/hello.mojo"))


fn test_diff_grammar_paints_inserted_deleted_and_hunk_header() raises:
    """The bundled diff TextMate grammar maps ``-`` lines to the string
    color (red), ``+`` lines to the ident color (green), and the
    ``@@`` hunk header to the decorator color (cyan)."""
    var lines = _hl_lines(
        String("--- a/file.txt"),
        String("+++ b/file.txt"),
        String("@@ -1,3 +1,3 @@"),
        String(" context"),
        String("-removed"),
        String("+added"),
    )
    var hls = highlight_for_extension(String("diff"), lines)
    var saw_deleted = False
    var saw_inserted = False
    var saw_range = False
    for i in range(len(hls)):
        var a = hls[i].attr
        if hls[i].row == 4 and a == highlight_string_attr():
            saw_deleted = True
        if hls[i].row == 5 and a == highlight_ident_attr():
            saw_inserted = True
        if hls[i].row == 2 and a == highlight_decorator_attr():
            saw_range = True
    assert_true(saw_deleted)
    assert_true(saw_inserted)
    assert_true(saw_range)


fn test_diff_identical_inputs_have_no_hunks() raises:
    """Two identical inputs produce only the file headers — no ``@@``."""
    var same = String("alpha\nbeta\ngamma\n")
    var out = unified_diff(same, same, String("a"), String("b"))
    var idx = out.find(String("@@"))
    assert_equal(idx, -1)


fn test_diff_lines_pure_insert() raises:
    """Inserting one line in the middle: one delete-free, one insert op."""
    var a = List[String]()
    a.append(String("one"))
    a.append(String("three"))
    var b = List[String]()
    b.append(String("one"))
    b.append(String("two"))
    b.append(String("three"))
    var ops = diff_lines(a, b)
    var equals = 0
    var inserts = 0
    var deletes = 0
    for i in range(len(ops)):
        if ops[i].kind == 0:
            equals += 1
        elif ops[i].kind == 1:
            deletes += 1
        else:
            inserts += 1
    assert_equal(equals, 2)
    assert_equal(inserts, 1)
    assert_equal(deletes, 0)


fn test_diff_lines_pure_delete() raises:
    """Removing one line: one delete op, no inserts."""
    var a = List[String]()
    a.append(String("one"))
    a.append(String("two"))
    a.append(String("three"))
    var b = List[String]()
    b.append(String("one"))
    b.append(String("three"))
    var ops = diff_lines(a, b)
    var equals = 0
    var inserts = 0
    var deletes = 0
    for i in range(len(ops)):
        if ops[i].kind == 0:
            equals += 1
        elif ops[i].kind == 1:
            deletes += 1
        else:
            inserts += 1
    assert_equal(equals, 2)
    assert_equal(inserts, 0)
    assert_equal(deletes, 1)


fn test_diff_lines_replace_round_trips() raises:
    """Applying the edit script must turn ``a`` into ``b`` exactly."""
    var a = List[String]()
    a.append(String("the quick brown fox"))
    a.append(String("jumps over"))
    a.append(String("the lazy dog"))
    var b = List[String]()
    b.append(String("the quick red fox"))
    b.append(String("hops over"))
    b.append(String("the lazy dog"))
    b.append(String("end"))
    var ops = diff_lines(a, b)
    # Replay: equal/delete consume from a, insert produces from b. The
    # produced sequence (equal lines from a, plus inserts from b in order)
    # should match b exactly when the script is applied.
    var produced = List[String]()
    for i in range(len(ops)):
        if ops[i].kind == 0:
            produced.append(a[ops[i].a_index])
        elif ops[i].kind == 2:
            produced.append(b[ops[i].b_index])
    assert_equal(len(produced), len(b))
    for i in range(len(b)):
        assert_equal(produced[i], b[i])


fn test_unified_diff_renders_hunk_header_and_marks() raises:
    """A simple replace: hunk header present, ``-old`` and ``+new`` lines
    emitted, surrounding equals appear with a leading space."""
    var a = String("alpha\nbeta\ngamma\n")
    var b = String("alpha\nBETA\ngamma\n")
    var out = unified_diff(a, b, String("old"), String("new"))
    assert_true(out.find(String("--- old")) >= 0)
    assert_true(out.find(String("+++ new")) >= 0)
    assert_true(out.find(String("@@")) >= 0)
    assert_true(out.find(String("-beta")) >= 0)
    assert_true(out.find(String("+BETA")) >= 0)
    assert_true(out.find(String(" alpha")) >= 0)
    assert_true(out.find(String(" gamma")) >= 0)


fn test_git_blame_parses_two_line_porcelain() raises:
    """Two source lines, two distinct commits — parser must emit one
    ``BlameLine`` per line with the right short-SHA + author. Each
    record's first occurrence carries metadata; that author should
    propagate to ``BlameLine.author`` for that record.
    """
    var text = (
        String("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 1 1 1\n")
        + String("author Alice\n")
        + String("author-mail <alice@example.com>\n")
        + String("summary first line\n")
        + String("\thello\n")
        + String("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 2 2 1\n")
        + String("author Bob\n")
        + String("author-mail <bob@example.com>\n")
        + String("summary second line\n")
        + String("\tworld\n")
    )
    var lines = parse_blame_porcelain(text)
    assert_equal(len(lines), 2)
    assert_equal(lines[0].commit, String("aaaaaaaa"))
    assert_equal(lines[0].author, String("Alice"))
    assert_equal(lines[1].commit, String("bbbbbbbb"))
    assert_equal(lines[1].author, String("Bob"))


fn test_git_blame_propagates_cached_author_for_repeated_sha() raises:
    """Lines 2..N of a same-commit group only carry ``<sha> <orig> <final>``
    + ``\\t<content>`` — no metadata. The parser must remember the
    author from the first occurrence so the repeated lines still get
    a real name (not "Not Committed Yet")."""
    var sha = String("cccccccccccccccccccccccccccccccccccccccc")
    var input = (
        sha + String(" 1 1 2\n")
        + String("author Carol\n")
        + String("summary same commit, two lines\n")
        + String("\tline one\n")
        + sha + String(" 2 2\n")
        + String("\tline two\n")
    )
    var lines = parse_blame_porcelain(input)
    assert_equal(len(lines), 2)
    assert_equal(lines[0].commit, String("cccccccc"))
    assert_equal(lines[0].author, String("Carol"))
    assert_equal(lines[1].commit, String("cccccccc"))
    assert_equal(lines[1].author, String("Carol"))


fn test_git_blame_marks_uncommitted_with_zero_sha_and_placeholder() raises:
    """Git emits a 40-char zero SHA and ``Not Committed Yet`` author
    for lines that exist only in the worktree. The parser preserves
    that — tests downstream rendering doesn't crash on the all-zero
    short SHA."""
    var text = (
        String("0000000000000000000000000000000000000000 1 1 1\n")
        + String("author Not Committed Yet\n")
        + String("summary Version of foo from foo.txt\n")
        + String("\tfresh line\n")
    )
    var lines = parse_blame_porcelain(text)
    assert_equal(len(lines), 1)
    assert_equal(lines[0].commit, String("00000000"))
    assert_equal(lines[0].author, String("Not Committed Yet"))


fn test_editor_blame_gutter_widens_total_gutter() raises:
    """``set_blame`` enables the gutter; the editor's overall left
    margin grows to make room for ``<sha> <author>`` (8+1+14+1 = 24
    cells). Toggling off shrinks the margin back."""
    var ed = Editor(String("alpha\nbeta\n"))
    var bl = List[BlameLine]()
    bl.append(BlameLine(String("12345678"), String("Anders")))
    bl.append(BlameLine(String("12345678"), String("Anders")))
    ed.set_blame(bl^)
    assert_true(ed.blame_visible)
    assert_equal(ed._blame_gutter(), 24)
    ed.toggle_blame()
    assert_false(ed.blame_visible)
    assert_equal(ed._blame_gutter(), 0)


fn test_parse_unified_diff_splits_two_files() raises:
    """Two files in one diff stream — the parser must split on the
    ``diff --git`` boundary and pull each path from the ``+++ b/...``
    header. The first file's chunk gets ``+++ b/foo.txt`` so its path
    is ``foo.txt``; the second has ``+++ b/dir/bar.mojo``."""
    var text = (
        String("diff --git a/foo.txt b/foo.txt\n")
        + String("index abcdef..123456 100644\n")
        + String("--- a/foo.txt\n")
        + String("+++ b/foo.txt\n")
        + String("@@ -1,2 +1,2 @@\n")
        + String("-old\n")
        + String("+new\n")
        + String(" unchanged\n")
        + String("diff --git a/dir/bar.mojo b/dir/bar.mojo\n")
        + String("index 999..888 100644\n")
        + String("--- a/dir/bar.mojo\n")
        + String("+++ b/dir/bar.mojo\n")
        + String("@@ -10 +10 @@\n")
        + String("-fn old(): pass\n")
        + String("+fn new(): pass\n")
    )
    var files = parse_unified_diff_files(text)
    assert_equal(len(files), 2)
    assert_equal(files[0].path, String("foo.txt"))
    assert_equal(files[1].path, String("dir/bar.mojo"))


fn test_parse_unified_diff_handles_pure_delete() raises:
    """A pure file delete shows ``+++ /dev/null``; the parser must
    fall back to ``--- a/<path>`` so the sidebar still has a real
    name to show."""
    var text = (
        String("diff --git a/gone.txt b/gone.txt\n")
        + String("deleted file mode 100644\n")
        + String("index abc..0000000\n")
        + String("--- a/gone.txt\n")
        + String("+++ /dev/null\n")
        + String("@@ -1 +0,0 @@\n")
        + String("-bye\n")
    )
    var files = parse_unified_diff_files(text)
    assert_equal(len(files), 1)
    assert_equal(files[0].path, String("gone.txt"))


fn test_diff_buffer_against_head_marks_added_and_modified() raises:
    """Diffing the editor's in-memory line list against the HEAD blob
    marks pure inserts as ADDED and inserts paired with deletes as
    MODIFIED. Lines untouched on either side land as NONE."""
    var head = (
        String("alpha\n")
        + String("beta\n")
        + String("gamma\n")
        + String("delta\n")
    )
    var buffer = List[String]()
    buffer.append(String("alpha"))
    buffer.append(String("BETA"))           # modified (replaces "beta")
    buffer.append(String("gamma"))
    buffer.append(String("inserted"))       # pure add
    buffer.append(String("delta"))
    buffer.append(String(""))               # trailing empty (was newline at EOF)
    var marks = diff_buffer_against_head(head, buffer)
    assert_equal(len(marks), len(buffer))
    assert_equal(marks[0], GIT_CHANGE_NONE)
    assert_equal(marks[1], GIT_CHANGE_MODIFIED)
    assert_equal(marks[2], GIT_CHANGE_NONE)
    assert_equal(marks[3], GIT_CHANGE_ADDED)
    assert_equal(marks[4], GIT_CHANGE_NONE)


fn test_editor_git_changes_gutter_widens_total_gutter() raises:
    """``set_git_changes`` flips the column on; the editor's overall
    left margin grows by exactly one cell. ``invalidate_git_changes``
    drops the cache so the gutter goes away again."""
    var ed = Editor(String("alpha\nbeta\ngamma\n"))
    ed.git_changes_visible = True
    var marks = List[Int]()
    marks.append(GIT_CHANGE_ADDED)
    marks.append(GIT_CHANGE_MODIFIED)
    marks.append(GIT_CHANGE_NONE)
    ed.set_git_changes(marks^)
    assert_equal(ed._git_changes_gutter(), 1)
    ed.invalidate_git_changes()
    # Visible flag still on, but no data → no column.
    assert_equal(ed._git_changes_gutter(), 0)


fn test_local_changes_open_records_status_when_clean() raises:
    """Pointing the widget at ``/tmp`` (not a git repo) makes
    ``compute_local_changes`` return empty; ``open`` should record a
    user-readable status string and end up with no files."""
    var lc = LocalChanges()
    lc.open(String("/tmp"))
    assert_true(lc.active)
    assert_equal(len(lc.files), 0)
    assert_true(len(lc.status_message.as_bytes()) > 0)
    lc.close()
    assert_false(lc.active)


fn test_build_minimal_patch_keeps_only_target_plus_line() raises:
    """A pure-add hunk with two ``+`` lines: targeting one of them
    must produce a patch with just that one as ``+`` and the other
    dropped, leaving context lines intact. ``--recount`` will fix the
    @@ counts so we don't assert on those."""
    var diff = String(
        "diff --git a/x b/x\n"
        + "--- a/x\n"
        + "+++ b/x\n"
        + "@@ -1,2 +1,4 @@\n"
        + " ctx_before\n"
        + "+added_one\n"
        + "+added_two\n"
        + " ctx_after\n"
    )
    # Lines (0-indexed after _split_lines):
    # 0: diff --git a/x b/x
    # 1: --- a/x
    # 2: +++ b/x
    # 3: @@ -1,2 +1,4 @@
    # 4:  ctx_before
    # 5: +added_one
    # 6: +added_two
    # 7:  ctx_after
    var patch = build_minimal_patch(diff, 6, False)
    # Must contain the target +added_two but NOT +added_one.
    assert_true(String("+added_two") in patch)
    assert_false(String("+added_one") in patch)
    # Context preserved.
    assert_true(String(" ctx_before") in patch)
    assert_true(String(" ctx_after") in patch)
    # File header preserved.
    assert_true(String("--- a/x") in patch)
    assert_true(String("+++ b/x") in patch)


fn test_build_minimal_patch_demotes_paired_minus_to_context() raises:
    """A replacement hunk (``-`` paired with ``+``): targeting the
    ``+`` line forward (staging) must convert the ``-`` line into
    context so the LEFT side still matches the index. Otherwise the
    patch would refuse to apply because the context wouldn't line up."""
    var diff = String(
        "diff --git a/x b/x\n"
        + "--- a/x\n"
        + "+++ b/x\n"
        + "@@ -1,3 +1,3 @@\n"
        + " ctx\n"
        + "-old_line\n"
        + "+new_line\n"
        + " more_ctx\n"
    )
    # Line indices: 4= ctx, 5=-old_line, 6=+new_line, 7= more_ctx.
    var patch = build_minimal_patch(diff, 6, False)
    # The +new_line stays; -old_line becomes context (gets a leading space).
    assert_true(String("+new_line") in patch)
    assert_false(String("-old_line") in patch)
    assert_true(String(" old_line") in patch)


fn test_build_minimal_patch_reverse_drops_paired_minus() raises:
    """In the staged section we use --reverse. Targeting a ``+`` line
    must convert other ``+`` lines to context (so the RIGHT side still
    matches the index) and drop other ``-`` lines (their would-be
    presence in the LEFT side has nothing to do with the index that
    we're patching)."""
    var diff = String(
        "diff --git a/x b/x\n"
        + "--- a/x\n"
        + "+++ b/x\n"
        + "@@ -1,3 +1,3 @@\n"
        + " ctx\n"
        + "-old_line\n"
        + "+new_line\n"
        + " more_ctx\n"
    )
    var patch = build_minimal_patch(diff, 6, True)
    assert_true(String("+new_line") in patch)
    # Reverse: the unselected ``-`` is dropped entirely (not converted).
    assert_false(String("-old_line") in patch)
    assert_false(String(" old_line") in patch)


fn test_build_minimal_patch_returns_empty_for_non_pm_lines() raises:
    """Cursor on a context / header line: nothing to stage, return
    empty so the caller can no-op cleanly."""
    var diff = String(
        "diff --git a/x b/x\n"
        + "--- a/x\n"
        + "+++ b/x\n"
        + "@@ -1,2 +1,3 @@\n"
        + " ctx\n"
        + "+added\n"
        + " more\n"
    )
    # Index 4 is " ctx" (context line) — not toggleable.
    assert_equal(len(build_minimal_patch(diff, 4, False).as_bytes()), 0)
    # Index 3 is the @@ header.
    assert_equal(len(build_minimal_patch(diff, 3, False).as_bytes()), 0)
    # Index 0 is the file header.
    assert_equal(len(build_minimal_patch(diff, 0, False).as_bytes()), 0)


fn _run_git(root: String, var args: List[String]) raises -> Int:
    """Wrapper around ``capture_command`` for the staging integration
    test below. Returns the exit status. We rebuild the argv with
    ``git -C <root>`` in front so the test doesn't have to repeat it."""
    var argv = List[String]()
    argv.append(String("git"))
    argv.append(String("-C"))
    argv.append(root)
    for i in range(len(args)):
        argv.append(args[i])
    var r = capture_command(argv)
    return Int(r.status)


fn _ensure_dir(path: String) raises:
    var argv = List[String]()
    argv.append(String("mkdir"))
    argv.append(String("-p"))
    argv.append(path)
    _ = capture_command(argv)


fn _rm_rf(path: String) raises:
    var argv = List[String]()
    argv.append(String("rm"))
    argv.append(String("-rf"))
    argv.append(path)
    _ = capture_command(argv)


fn test_stage_unstage_round_trip_against_real_git() raises:
    """End-to-end: spin up a throwaway git repo, modify a file, walk it
    through stage_file → fetch_git_status → unstage_file. Asserts the
    porcelain X/Y columns flip the way we expect, which is the contract
    the LocalChanges UI is built on. Skipped silently when ``git`` is
    missing or ``git init`` fails (e.g., a build environment without
    git on PATH)."""
    var dir = _temp_path(String("_stage_int"))
    _rm_rf(dir)
    _ensure_dir(dir)
    # ``git init -q`` so we don't pollute test output. Pass ``-b main``
    # to avoid the default-branch warning that newer git emits — we
    # don't care which branch, just that the call succeeds.
    var init_args = List[String]()
    init_args.append(String("init"))
    init_args.append(String("-q"))
    init_args.append(String("-b"))
    init_args.append(String("main"))
    var rc = _run_git(dir, init_args^)
    if rc != 0:
        # No git available — skip silently.
        _rm_rf(dir)
        return
    # Configure user so commit doesn't fail; ``-c`` per-invocation would
    # be cleaner but we'd have to plumb it through every helper call.
    var cfg1 = List[String]()
    cfg1.append(String("config"))
    cfg1.append(String("user.email"))
    cfg1.append(String("test@example.com"))
    _ = _run_git(dir, cfg1^)
    var cfg2 = List[String]()
    cfg2.append(String("config"))
    cfg2.append(String("user.name"))
    cfg2.append(String("Test"))
    _ = _run_git(dir, cfg2^)
    # Initial commit of a known-content file.
    var f = join_path(dir, String("a.txt"))
    assert_true(write_file(f, String("alpha\nbeta\ngamma\n")))
    var add_initial = List[String]()
    add_initial.append(String("add"))
    add_initial.append(String("a.txt"))
    _ = _run_git(dir, add_initial^)
    var commit_args = List[String]()
    commit_args.append(String("commit"))
    commit_args.append(String("-q"))
    commit_args.append(String("-m"))
    commit_args.append(String("init"))
    _ = _run_git(dir, commit_args^)
    # Modify the file.
    assert_true(write_file(f, String("alpha\nbeta-modified\ngamma\n")))
    # Status should show ' M a.txt'.
    var statuses = fetch_git_status(dir)
    assert_equal(len(statuses), 1)
    assert_equal(Int(statuses[0].staged), 0x20)
    assert_equal(Int(statuses[0].worktree), 0x4D)    # 'M'
    assert_equal(statuses[0].path, String("a.txt"))
    # Stage the whole file.
    assert_true(stage_file(dir, String("a.txt")))
    statuses = fetch_git_status(dir)
    assert_equal(len(statuses), 1)
    assert_equal(Int(statuses[0].staged), 0x4D)      # 'M'
    assert_equal(Int(statuses[0].worktree), 0x20)
    # Unstage and verify it bounces back.
    assert_true(unstage_file(dir, String("a.txt")))
    statuses = fetch_git_status(dir)
    assert_equal(len(statuses), 1)
    assert_equal(Int(statuses[0].staged), 0x20)
    assert_equal(Int(statuses[0].worktree), 0x4D)
    # Build a minimal patch from the unstaged diff and apply it: that
    # exercises the line-staging path end-to-end. The hunk has one ``-``
    # / one ``+`` pair, so targeting the ``+`` line stages the change
    # while demoting the ``-`` to context (algorithm tested above).
    var unstaged = compute_unstaged_diff(dir)
    assert_true(len(unstaged.as_bytes()) > 0)
    var per_file = parse_unified_diff_files(unstaged)
    assert_equal(len(per_file), 1)
    var lines = List[String]()
    var b = per_file[0].diff.as_bytes()
    var s = 0
    for i in range(len(b)):
        if b[i] == 0x0A:
            lines.append(String(StringSlice(unsafe_from_utf8=b[s:i])))
            s = i + 1
    if s < len(b):
        lines.append(String(StringSlice(unsafe_from_utf8=b[s:len(b)])))
    # Find the ``+beta-modified`` line index.
    var plus_idx = -1
    for i in range(len(lines)):
        var lb = lines[i].as_bytes()
        if len(lb) > 0 and Int(lb[0]) == 0x2B \
                and lines[i] != String("+++ b/a.txt"):
            plus_idx = i
            break
    assert_true(plus_idx > 0)
    var patch = build_minimal_patch(per_file[0].diff, plus_idx, False)
    assert_true(len(patch.as_bytes()) > 0)
    assert_true(apply_patch_to_index(dir, patch, False))
    # After applying: the staged side should now have a modification.
    # Worktree column stays modified because we only staged the ``+`` half
    # of the replacement (``-beta`` was demoted to context, so removing
    # ``beta`` is still pending) — that's the correct line-staging
    # semantics, just an awkward end-state. The point of the assertion
    # is that staging didn't no-op.
    var staged_after = compute_staged_diff(dir)
    assert_true(len(staged_after.as_bytes()) > 0)
    statuses = fetch_git_status(dir)
    assert_equal(len(statuses), 1)
    assert_equal(Int(statuses[0].staged), 0x4D)
    assert_equal(Int(statuses[0].worktree), 0x4D)
    _rm_rf(dir)


fn test_build_minimal_patch_drops_other_hunks() raises:
    """A diff with two hunks: targeting a line in the first must produce
    output containing only that hunk; the second hunk's lines must not
    appear at all (otherwise we'd accidentally stage other changes)."""
    var diff = String(
        "diff --git a/x b/x\n"
        + "--- a/x\n"
        + "+++ b/x\n"
        + "@@ -1,2 +1,3 @@\n"
        + " a\n"
        + "+added_in_hunk1\n"
        + " b\n"
        + "@@ -10,1 +11,2 @@\n"
        + " c\n"
        + "+added_in_hunk2\n"
    )
    var patch = build_minimal_patch(diff, 5, False)
    assert_true(String("+added_in_hunk1") in patch)
    assert_false(String("+added_in_hunk2") in patch)
    # Second hunk header dropped too.
    assert_false(String("@@ -10,1") in patch)


fn test_canvas_put_wrapped_text_paints_inside_rect_only() raises:
    """Framework primitive: long text rendered through
    ``put_wrapped_text`` must wrap inside the rect and never colour a
    cell outside it. The Prompt overflow fix relies on this contract,
    and any future popup with variable text content should too."""
    var canvas = Canvas(40, 10)
    canvas.clear(Attr(BLACK, BLUE))
    var rect = Rect(5, 2, 25, 6)   # 20 cells wide, 4 rows tall
    var text = String(
        "Install rust LSP? 'rustup component add rust-analyzer' (y/N)"
    )
    var rows = canvas.put_wrapped_text(rect, text, Attr(WHITE, BLACK))
    assert_true(rows >= 1)
    assert_true(rows <= 4)
    # No cell outside ``rect`` should have its background flipped from
    # the workspace fill — that's exactly the property dialogs need.
    for y in range(10):
        for x in range(40):
            var inside = (x >= 5 and x < 25 and y >= 2 and y < 6)
            if inside:
                continue
            assert_equal(canvas.get(x, y).attr.bg, BLUE)


fn test_canvas_put_wrapped_text_returns_zero_for_empty_rect() raises:
    var canvas = Canvas(20, 5)
    canvas.clear(Attr(BLACK, BLUE))
    var rows = canvas.put_wrapped_text(
        Rect(0, 0, 0, 0), String("hello"), Attr(WHITE, BLACK),
    )
    assert_equal(rows, 0)


fn test_prompt_wrap_short_text_stays_on_one_line() raises:
    var lines = wrap_to_width(String("Find: "), 56)
    assert_equal(len(lines), 1)
    assert_equal(lines[0], String("Find: "))


fn test_prompt_wrap_breaks_at_last_space_within_budget() raises:
    var lines = wrap_to_width(
        String("Install rust LSP? 'rustup component add rust-analyzer' (y/N): "),
        20,
    )
    # Every line must fit the 20-cell budget; rejoining yields a string
    # that — modulo the soft-break spaces — recovers the original tokens.
    for i in range(len(lines)):
        assert_true(len(lines[i].as_bytes()) <= 20)
    var joined = String("")
    for i in range(len(lines)):
        if i > 0: joined = joined + String(" ")
        joined = joined + lines[i]
    # Trailing space on the original is preserved on the final line —
    # the prompt renders the input strip after that space, so leaving
    # it in the wrap output keeps inline and wrapped layouts visually
    # consistent around the input.
    assert_equal(
        joined,
        String("Install rust LSP? 'rustup component add rust-analyzer' (y/N): "),
    )


fn test_prompt_wrap_hard_breaks_an_unbreakable_word() raises:
    # No spaces — the wrapper must still chop the input into width-sized
    # chunks rather than emit one giant overflowing line.
    var lines = wrap_to_width(String("aaaaaaaaaaaaaaaaaaaa"), 6)
    assert_equal(len(lines), 4)
    assert_equal(lines[0], String("aaaaaa"))
    assert_equal(lines[1], String("aaaaaa"))
    assert_equal(lines[2], String("aaaaaa"))
    assert_equal(lines[3], String("aa"))


fn test_prompt_wrap_empty_returns_empty_list() raises:
    var lines = wrap_to_width(String(""), 60)
    assert_equal(len(lines), 0)


fn test_prompt_paint_clamps_long_label_inside_dialog() raises:
    """The painted cells of a long-label prompt must all live inside
    the prompt's dialog rect — nothing leaks into the surrounding
    workspace cells the way the un-clamped ``put_text`` used to."""
    var screen = Rect(0, 0, 80, 24)
    var canvas = Canvas(80, 24)
    canvas.clear(Attr(BLACK, BLUE))
    var prompt = Prompt()
    prompt.open(
        String("Install rust LSP? 'rustup component add rust-analyzer' (y/N): "),
    )
    prompt.paint(canvas, screen)
    # The dialog centers itself; the only cells whose attr changed
    # from the (BLACK, BLUE) workspace fill are inside the dialog rect
    # *or* inside the drop-shadow strip directly to its right and
    # below. Anything else is a paint leak.
    var dialog_w = 60
    var dx = (80 - dialog_w) // 2
    # Walk a generous outer band around the dialog and shadow and
    # confirm the workspace fill is intact: cells outside the dialog
    # rect (and outside the 2-cell right shadow / 1-row bottom shadow)
    # must still carry the original blue background.
    for y in range(24):
        for x in range(80):
            var inside_dialog = (
                x >= dx and x < dx + dialog_w and y >= 8 and y < 16
            )
            var in_right_shadow = (
                x >= dx + dialog_w and x < dx + dialog_w + 2
                and y >= 9 and y < 16
            )
            var in_bottom_shadow = (
                x >= dx + 2 and x < dx + dialog_w + 2 and y == 16
            )
            if inside_dialog or in_right_shadow or in_bottom_shadow:
                continue
            var c = canvas.get(x, y)
            assert_equal(c.attr.bg, BLUE)


fn test_confirm_dialog_y_key_resolves_yes() raises:
    var d = ConfirmDialog()
    d.open(String("Install rust LSP?"))
    assert_true(d.active)
    assert_false(d.submitted)
    _ = d.handle_key(Event.key_event(UInt32(ord("y"))))
    assert_true(d.submitted)
    assert_true(d.confirmed)


fn test_confirm_dialog_n_key_resolves_no() raises:
    var d = ConfirmDialog()
    d.open(String("Install rust LSP?"))
    _ = d.handle_key(Event.key_event(UInt32(ord("n"))))
    assert_true(d.submitted)
    assert_false(d.confirmed)


fn test_confirm_dialog_esc_cancels() raises:
    var d = ConfirmDialog()
    d.open(String("Install rust LSP?"))
    _ = d.handle_key(Event.key_event(KEY_ESC))
    assert_true(d.submitted)
    assert_false(d.confirmed)


fn test_confirm_dialog_enter_uses_focused_button() raises:
    """Default focus is No (safer for installs); Tab toggles to Yes;
    Enter resolves whichever side is focused."""
    var d = ConfirmDialog()
    d.open(String("Download docs?"))
    _ = d.handle_key(Event.key_event(KEY_ENTER))
    assert_true(d.submitted)
    assert_false(d.confirmed)   # default focus is No
    var d2 = ConfirmDialog()
    d2.open(String("Download docs?"))
    _ = d2.handle_key(Event.key_event(KEY_TAB))
    _ = d2.handle_key(Event.key_event(KEY_ENTER))
    assert_true(d2.submitted)
    assert_true(d2.confirmed)


fn test_confirm_dialog_default_yes_focuses_yes() raises:
    """Callers that want Enter to mean Yes pass ``default_yes=True``."""
    var d = ConfirmDialog()
    d.open(String("Save changes?"), default_yes=True)
    _ = d.handle_key(Event.key_event(KEY_ENTER))
    assert_true(d.submitted)
    assert_true(d.confirmed)


fn test_confirm_dialog_paints_inside_dialog_rect() raises:
    """Same overflow guarantee as the Prompt: a long install hint
    must stay inside the centered dialog rect (plus the drop shadow)."""
    var screen = Rect(0, 0, 80, 24)
    var canvas = Canvas(80, 24)
    canvas.clear(Attr(BLACK, BLUE))
    var dialog = ConfirmDialog()
    dialog.open(
        String("Install rust LSP? 'rustup component add rust-analyzer'"),
    )
    dialog.paint(canvas, screen)
    var dialog_w = 60
    var dx = (80 - dialog_w) // 2
    # The painted area covers the dialog rect itself plus the right-edge
    # shadow column (dx + dialog_w) and the bottom-shadow row. Cells
    # outside that band must still carry the workspace fill.
    for y in range(24):
        for x in range(80):
            var c = canvas.get(x, y)
            if c.attr.bg == BLUE:
                continue
            assert_true(x >= dx and x < dx + dialog_w + 2)


fn test_desktop_confirm_dialog_yes_starts_grammar_install() raises:
    """Smoke-test the wiring: typing a confirm dialog into the
    grammar-install pending action and pressing 'y' must clear the
    dialog and leave a grammar-install language recorded on the
    desktop. Doesn't actually run curl — the desktop's
    ``_start_grammar_install`` records ``_grammar_install_lang`` only
    after a successful ``InstallRunner.start``, which would normally
    require a sub-process; checking that the pending state was
    cleared is enough to verify the dispatch path."""
    var d = Desktop()
    d._pending_action = String("grammar:install")
    d._pending_arg = String("elm")
    d.confirm_dialog.open(String("Download Elm syntax grammar?"))
    assert_true(d.confirm_dialog.active)
    _ = d.handle_event(
        Event.key_event(UInt32(ord("y"))), Rect(0, 0, 80, 24),
    )
    # Dialog closed and pending action cleared regardless of whether
    # the install spawn succeeded in this test environment.
    assert_false(d.confirm_dialog.active)
    assert_equal(d._pending_action, String(""))
    assert_equal(d._pending_arg, String(""))


fn test_desktop_confirm_dialog_no_clears_pending_action() raises:
    var d = Desktop()
    d._pending_action = String("lsp:install")
    d._pending_arg = String("rust")
    d.confirm_dialog.open(String("Install rust LSP?"))
    _ = d.handle_event(
        Event.key_event(UInt32(ord("n"))), Rect(0, 0, 80, 24),
    )
    assert_false(d.confirm_dialog.active)
    assert_equal(d._pending_action, String(""))
    assert_equal(d._pending_arg, String(""))
    # Install runner stays idle — user said no.
    assert_false(d.install_runner.is_active())


fn main() raises:
    test_confirm_dialog_y_key_resolves_yes()
    test_confirm_dialog_n_key_resolves_no()
    test_confirm_dialog_esc_cancels()
    test_confirm_dialog_enter_uses_focused_button()
    test_confirm_dialog_default_yes_focuses_yes()
    test_confirm_dialog_paints_inside_dialog_rect()
    test_desktop_confirm_dialog_yes_starts_grammar_install()
    test_desktop_confirm_dialog_no_clears_pending_action()
    test_canvas_put_wrapped_text_paints_inside_rect_only()
    test_canvas_put_wrapped_text_returns_zero_for_empty_rect()
    test_prompt_wrap_short_text_stays_on_one_line()
    test_prompt_wrap_breaks_at_last_space_within_budget()
    test_prompt_wrap_hard_breaks_an_unbreakable_word()
    test_prompt_wrap_empty_returns_empty_list()
    test_prompt_paint_clamps_long_label_inside_dialog()
    test_diff_grammar_paints_inserted_deleted_and_hunk_header()
    test_diff_identical_inputs_have_no_hunks()
    test_diff_lines_pure_insert()
    test_diff_lines_pure_delete()
    test_diff_lines_replace_round_trips()
    test_unified_diff_renders_hunk_header_and_marks()
    test_git_blame_parses_two_line_porcelain()
    test_git_blame_propagates_cached_author_for_repeated_sha()
    test_git_blame_marks_uncommitted_with_zero_sha_and_placeholder()
    test_editor_blame_gutter_widens_total_gutter()
    test_parse_unified_diff_splits_two_files()
    test_parse_unified_diff_handles_pure_delete()
    test_diff_buffer_against_head_marks_added_and_modified()
    test_editor_git_changes_gutter_widens_total_gutter()
    test_local_changes_open_records_status_when_clean()
    test_build_minimal_patch_keeps_only_target_plus_line()
    test_build_minimal_patch_demotes_paired_minus_to_context()
    test_build_minimal_patch_reverse_drops_paired_minus()
    test_build_minimal_patch_returns_empty_for_non_pm_lines()
    test_build_minimal_patch_drops_other_hunks()
    test_stage_unstage_round_trip_against_real_git()
    test_point_arithmetic()
    test_rect_basics()
    test_rect_helpers()
    test_attr()
    test_canvas_put_text()
    test_canvas_box()
    test_canvas_fill()
    test_event_factories()
    test_parse_input_keys()
    test_parse_window_size_report()
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
    test_editor_double_click_selects_word()
    test_editor_double_click_drag_extends_by_word_forward()
    test_editor_double_click_drag_extends_by_word_backward()
    test_editor_triple_click_selects_line()
    test_editor_triple_click_last_line_no_newline()
    test_editor_triple_click_drag_extends_by_line_forward()
    test_editor_triple_click_drag_extends_by_line_backward()
    test_editor_cut_whole_line_when_no_selection()
    test_editor_cut_whole_line_only_line()
    test_editor_smart_indent_mirrors_previous_line()
    test_editor_smart_indent_after_open_brace()
    test_editor_smart_indent_after_colon()
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
    test_system_menu_pins_to_left_edge()
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
    test_diff3_merge_clean_when_only_ours_changed()
    test_diff3_merge_clean_when_only_theirs_changed()
    test_diff3_merge_clean_when_changes_disjoint()
    test_diff3_merge_identical_changes_dont_conflict()
    test_diff3_merge_conflict_when_both_edit_same_line()
    test_editor_external_change_clean_reload_when_buffer_clean()
    test_editor_external_change_refreshes_highlights()
    test_editor_external_change_auto_merges_disjoint_edits()
    test_editor_external_change_clears_dirty_when_disk_already_has_our_edits()
    test_editor_external_change_conflict_inserts_markers()
    test_editor_replace_all()
    test_editorconfig_parse_basic()
    test_editorconfig_match_section()
    test_editorconfig_load_from_fixture()
    test_editor_uses_editorconfig_indent()
    test_editor_save_applies_editorconfig_transforms()
    test_editor_save_uses_editorconfig_line_endings()
    test_walk_project_files_finds_known_files()
    test_find_in_project_locates_string()
    test_gitignore_matches_directory_pattern()
    test_gitignore_matches_glob_and_negate()
    test_walk_project_files_respects_gitignore()
    test_downloadable_grammar_registry_has_elm()
    test_downloadable_grammar_registry_misses_unknown()
    test_grammar_install_command_targets_user_config()
    test_user_grammar_path_for_ext_misses_when_not_installed()
    test_extension_of_helper()
    test_word_at_helper()
    test_highlight_for_extension_recognizes_mojo()
    test_highlight_triple_quoted_string_spans_lines()
    test_highlight_unknown_extension_returns_empty()
    test_highlight_rust_keywords_strings_comments()
    test_highlight_rust_block_comment_spans_lines()
    test_onig_basic_search()
    test_onig_no_match_returns_none()
    test_onig_search_at_offset()
    test_onig_invalid_pattern_raises()
    test_textmate_rust_grammar_paints_keywords_and_strings()
    test_textmate_brackets_paint_as_operators()
    test_textmate_html_embeds_css_inside_style_block()
    test_textmate_capture_patterns_run_inside_group()
    test_textmate_while_rule_keeps_scope_open_per_line()
    test_textmate_captures_overlay_on_match()
    test_textmate_incremental_matches_full_retokenize()
    test_editor_default_text_is_light_green()
    test_textmate_all_bundled_grammars_load()
    test_textmate_json_grammar_paints_strings_and_numbers()
    test_textmate_rust_block_comment_spans_lines()
    test_editor_refreshes_highlights_after_edits()
    test_editor_paint_overlays_highlight_attr()
    test_editor_alt_click_emits_definition_request()
    test_editor_alt_click_outside_identifier_is_silent()
    test_editor_gutter_click_emits_breakpoint_toggle()
    test_editor_text_click_does_not_toggle_breakpoint()
    test_editor_gutter_click_below_eof_is_ignored()
    test_editor_gutter_drag_motion_does_not_toggle()
    test_install_runner_last_lines_picks_tail_skipping_blanks()
    test_install_runner_runs_sh_command_to_completion()
    test_install_runner_failure_carries_nonzero_exit()
    test_doc_registry_lookup()
    test_doc_install_command_shape()
    test_html_to_text_basics()
    test_html_to_text_headings_become_hashes()
    test_html_to_text_lists_and_inline()
    test_html_to_text_pre_uses_fence()
    test_html_to_text_preserves_pre()
    test_html_to_text_strips_script_and_style()
    test_html_to_text_table_renders_as_gfm_table()
    test_html_to_text_table_escapes_pipes_in_cells()
    test_find_doc_entry_exact_match_wins()
    test_find_doc_entry_falls_back_to_suffix_match()
    test_find_doc_entry_returns_minus_one_when_no_match()
    test_find_doc_entry_case_insensitive_when_no_exact()
    test_quick_open_match_rules()
    test_quick_open_match_case_and_separator_shapes()
    test_quick_open_slash_in_query_requires_directory_separator()
    test_quick_open_filters_as_you_type()
    test_ctrl_o_opens_quick_open_when_project_active()
    test_ctrl_o_bubbles_when_no_project()
    test_desktop_dispatch_editor_save_passes_through_when_no_editor()
    test_desktop_dispatch_passes_through_unknown_actions()
    test_desktop_dispatch_editor_save_writes_focused_editor()
    test_desktop_replace_chains_two_prompts()
    test_desktop_open_file_uses_80_percent_size()
    test_desktop_open_file_cascades_by_one()
    test_desktop_open_file_focuses_existing()
    test_desktop_open_file_inherits_maximize_state()
    test_desktop_new_file_creates_untitled_editor_window()
    test_desktop_dispatch_editor_new_opens_window()
    test_desktop_window_menu_lists_open_windows()
    test_desktop_window_menu_when_empty()
    test_desktop_window_focus_action_focuses_window()
    test_desktop_maximize_all_and_restore_all()
    test_window_manager_close_focused()
    test_ctrl_n_focuses_window_by_number()
    test_focus_changes_keep_window_list_order_stable()
    test_window_manager_rotate_focus_cycles_in_stable_order()
    test_window_manager_rotate_focus_noop_when_fewer_than_two_windows()
    test_window_menu_items_show_ctrl_n_shortcut()
    test_ctrl_w_closes_focused_window()
    test_format_hotkey_renders_combinations()
    test_menu_items_get_shortcut_text_after_refresh()
    test_dropdown_widens_to_fit_shortcut()
    test_dropdown_reserves_indent_for_checkable_items()
    test_parse_csi_modify_other_keys_normalizes_ctrl_q()
    test_parse_csi_modify_other_keys_cmd_letter_folds_onto_ctrl_form()
    test_parse_csi_modify_other_keys_cmd_backtick_keeps_key_intact()
    test_cmd_s_via_modify_other_keys_triggers_save_hotkey()
    test_parse_csi_modify_other_keys_ctrl_shift_f()
    test_parse_csi_modify_other_keys_cmd_shift_f_folds_onto_ctrl_shift_f()
    test_parse_csi_unknown_sequence_is_consumed_whole()
    test_parse_osc_open_path_emits_event_open_path()
    test_parse_osc_open_path_with_line_suffix()
    test_parse_osc_open_path_st_terminator()
    test_parse_osc_unknown_is_consumed_silently()
    test_parse_osc_partial_defers()
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
    test_painter_clips_text_at_right_edge()
    test_painter_skips_codepoints_left_of_clip()
    test_painter_fill_intersects_with_clip()
    test_dir_browser_long_name_does_not_overflow_listing()
    test_file_dialog_lists_and_navigates()
    test_partial_sgr_mouse_does_not_emit_esc()
    test_sgr_mouse_wheel_up()
    test_sgr_mouse_motion_no_button()
    test_menu_hover_switches_open_menu()
    test_menu_drag_release_on_item_triggers()
    test_menu_drag_release_outside_closes()
    test_menu_click_then_click_flow()
    test_file_dialog_selects_a_file()
    test_file_dialog_mouse_click_selects()
    test_file_dialog_double_click_opens()
    test_file_dialog_wheel_scrolls()
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
    test_editor_vertical_movement_uses_cell_column()
    test_editor_mouse_click_lands_on_codepoint_boundary()
    test_window_v_scrollbar_hit_arrows_and_thumb()
    test_window_v_scroll_by_clamps()
    test_window_v_scroll_drag_to_end()
    test_json_round_trip_lsp_envelope()
    test_json_string_escapes()
    test_json_parse_errors_raise()
    test_json_floats_round_trip_as_text()
    test_language_registry_loads_from_bundled_json()
    test_lsp_framer_finds_double_crlf()
    test_lsp_framer_parses_content_length()
    test_lsp_framer_extract_one_message()
    test_lsp_drop_prefix_helper()
    test_lsp_classify_message()
    test_lsp_subprocess_round_trip_via_cat()
    test_lsp_initialize_against_mojo_lsp_server()
    test_dap_classify_response()
    test_dap_classify_event()
    test_dap_classify_reverse_request()
    test_dap_classify_response_with_failure()
    test_dap_initialize_arguments_shape()
    test_dap_seq_autoincrement_via_cat()
    test_dap_parse_threads()
    test_dap_parse_stack_trace_zero_based()
    test_dap_parse_scopes_and_variables()
    test_dap_registry_lookup()
    test_dap_launch_arguments_for_debugpy()
    test_dap_launch_arguments_for_delve()
    test_dap_manager_breakpoint_toggle()
    test_project_targets_load_parses_fields()
    test_project_targets_save_roundtrips_active()
    test_project_targets_resolve_paths()
    test_resolve_python_interpreter()
    test_detect_project_language_python_markers()
    test_detect_project_language_no_match()
    test_status_bar_tab_hit_test()
    test_shadow_button_paints_face_and_shadow()
    test_shadow_button_hit_includes_shadow_rows()
    test_canvas_darken_rect_preserves_glyph()
    test_paint_drop_shadow_targets_right_and_bottom()
    test_debug_pane_default_title_is_debug()
    test_debug_pane_run_mode_swaps_title()
    test_debug_pane_run_mode_hides_inspect_divider()
    test_debug_pane_run_mode_uses_full_height_for_output()
    test_debug_pane_debug_mode_keeps_output_divider()
    test_debug_pane_traceback_link_underlines_span()
    test_debug_pane_plain_output_has_no_link_styling()
    test_debug_pane_click_on_traceback_link_sets_pending_open()
    test_targets_dialog_edit_and_submit()
    test_targets_dialog_add_and_remove()
    test_targets_dialog_save_button_submits()
    test_targets_dialog_esc_discards_edits()
    test_run_session_lifecycle()
    test_text_field_clipboard_key_ignores_non_key_event()
    test_text_field_clipboard_key_ignores_printable()
    test_text_field_clipboard_key_ctrl_x_clears_text()
    test_text_field_clipboard_key_round_trips_through_clipboard()
    test_session_round_trip()
    test_session_load_missing_returns_empty()
    test_session_relative_path_round_trip()
    test_desktop_snapshot_skips_untitled_windows()
    test_desktop_restores_session_from_disk()
    test_desktop_arms_session_restore_when_non_editor_windows_present()
    test_desktop_resize_reapplies_clipped_session_rect()
    test_desktop_restores_non_maximized_rect_not_restore_rect()
    test_desktop_restores_multiple_windows_at_distinct_positions()
    test_desktop_snapshot_captures_per_window_rects()
    test_desktop_save_then_restore_round_trip_through_paint()
    test_desktop_restores_maximized_window_keeps_per_window_restore_rect()
    print("all tests passed")
