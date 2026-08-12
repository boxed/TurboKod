"""Odds and ends that do not fit another suite.

One of the per-topic suites split out of the former
``test_basic.mojo``; shared fixtures live in ``tests/support.mojo``
and ``scripts/run_tests.sh`` runs every suite.
"""

from std.ffi import external_call
from std.testing import assert_equal, assert_false, assert_true
from turbokod.canvas import Canvas, utf8_byte_to_cell, utf8_codepoint_count
from turbokod.colors import Attr, BLACK, WHITE, default_attr
from turbokod.editor import Editor, TextBuffer
from turbokod.session_store import Session, SessionWindow, save_session
from turbokod.desktop import (
    Desktop, EDITOR_CUT, EDITOR_FIND, EDITOR_PASTE, HELP_HOTKEYS,
    PROJECT_CLOSE_ACTION, _expand_save_placeholders, _pyenv_pins_satisfied,
    _split_version_pins, ctrl_key, format_hotkey
)
from turbokod.file_io import (
    basename, delete_path, delete_tree, join_path, read_file, stat_file,
    write_file
)
from turbokod.git_changes import parse_unified_diff_files
from turbokod.local_changes import build_minimal_patch
from turbokod.menu import Menu, MenuBar, MenuItem
from turbokod.project import replace_in_project
from turbokod.text_select import PaneTextSelect
from turbokod.project_targets import resolve_python_interpreter
from turbokod.string_utils import (
    char_width, display_columns, escape_drop_paths, tail_to_columns
)
from turbokod.type_ahead import is_printable_ascii
from turbokod.lsp_dispatch import CompletionItem, TextEditEntry
from turbokod.git_changes import (
    apply_patch_to_worktree, compute_unstaged_diff, fetch_git_status
)
from turbokod.highlight import GrammarRegistry, extension_of
from turbokod.posix import which
from turbokod.spell import Speller
from turbokod.config import TurbokodConfig, load_config, save_config
from turbokod.settings import Settings
from turbokod.window import (
    TitleCommand, _fit_title_path, hit_title_command, paint_title_commands
)
from turbokod.events import (
    Event, EVENT_FOCUS_OUT, EVENT_KEY, EVENT_NONE, EVENT_QUIT, EVENT_RESIZE,
    KEY_END, KEY_ENTER, KEY_ESC, KEY_F5, KEY_UP, MOD_ALT, MOD_CTRL, MOD_META,
    MOD_NONE, MOD_SHIFT, MOUSE_BUTTON_LEFT
)
from turbokod.geometry import Point, Rect
from turbokod.terminal import parse_input
from turbokod.terminal_pane import TerminalPane
from turbokod.view import centered
from turbokod.window import Window

from support import (
    _SCREEN, _contains, _doc_paths, _docs_contains, _ensure_dir, _rm_rf,
    _run_git, _temp_path, setup_test_env
)


def test_help_hotkeys_opens_readonly_reference() raises:
    """Help ▸ Keyboard Shortcuts opens a single read-only window whose
    body documents the editor-level chords that have no menu item.
    Dispatching again refocuses rather than stacking duplicates."""
    var d = Desktop()
    var screen = Rect(0, 0, 120, 40)
    var before = len(d.windows.windows)
    _ = d.dispatch_action(HELP_HOTKEYS, screen)
    assert_equal(len(d.windows.windows), before + 1)
    var idx = len(d.windows.windows) - 1
    assert_equal(d.windows.windows[idx].title, String("Keyboard Shortcuts"))
    assert_true(d.windows.windows[idx].editor.read_only)
    assert_true(not d.windows.windows[idx].editor.line_numbers)
    # Body joins to one string; check both a registry-backed binding and
    # an editor-only chord that no menu surfaces.
    var body = String("")
    for r in range(d.windows.windows[idx].editor.buffer.line_count()):
        body = body + d.windows.windows[idx].editor.buffer.line(r) + String("\n")
    assert_true(_contains(body, String("Grow selection")))
    assert_true(_contains(body, String("Cmd+Up")))
    assert_true(_contains(body, String("Save")))
    # Aliases sharing one help string merge into a single row.
    assert_true(_contains(body, String("Ctrl+Space / Ctrl+J")))
    # F2 / Shift+F6 are aliases for LSP rename — also one merged row.
    assert_true(_contains(body, String("F2 / Shift+F6")))
    assert_true(_contains(body, String("Rename symbol")))
    # Second dispatch must not open a duplicate.
    _ = d.dispatch_action(HELP_HOTKEYS, screen)
    assert_equal(len(d.windows.windows), before + 1)


def test_emoji_double_width() raises:
    """Emoji occupy two cells end-to-end: ``char_width`` reports 2,
    ``display_columns`` / ``utf8_byte_to_cell`` / ``utf8_codepoint_count``
    all count two, and ``put_text`` paints the glyph plus an empty
    width-0 continuation cell so following text stays aligned."""
    assert_equal(char_width(0x1F680), 2)  # 🚀
    assert_equal(char_width(0x2B50), 2)   # ⭐
    assert_equal(char_width(ord("A")), 1)
    # CJK is intentionally still narrow (East-Asian width not modeled).
    assert_equal(char_width(0x65E5), 1)   # 日

    assert_equal(display_columns(String("a🚀b")), 4)

    # put_text: 'a' at 0, emoji (width 2) at 1, continuation (width 0,
    # empty glyph) at 2, 'b' at 3 — advances by 4.
    var c = Canvas(20, 1)
    var n = c.put_text(Point(0, 0), String("a🚀b"), default_attr())
    assert_equal(n, 4)
    assert_equal(c.get(0, 0).glyph, String("a"))
    assert_equal(c.get(1, 0).width, 2)
    assert_equal(c.get(2, 0).width, 0)
    assert_equal(c.get(2, 0).glyph, String(""))
    assert_equal(c.get(3, 0).glyph, String("b"))

    # The byte→cell map and cell count agree with put_text: bytes are
    # a(1) + emoji(4) + b(1); 'b' lands at cell 3.
    var s = String("a🚀b")
    var cm = utf8_byte_to_cell(s)
    assert_equal(len(cm), 6)
    assert_equal(cm[0], 0)
    assert_equal(cm[1], 1)
    assert_equal(cm[5], 3)
    assert_equal(utf8_codepoint_count(s), 4)

    # A wide glyph that can't fit before ``max_x`` is dropped rather than
    # painting a half glyph past the limit.
    var c2 = Canvas(20, 1)
    var n2 = c2.put_text(Point(0, 0), String("🚀"), default_attr(), 1)
    assert_equal(n2, 0)
    assert_equal(c2.get(0, 0).glyph, String(" "))


def test_escape_drop_paths_joins_and_trails() raises:
    """``escape_drop_paths`` splits a newline-separated drop list, escapes each
    path, space-joins them, and appends a trailing space (terminal-emulator
    drop convention). Blank entries are skipped; all-blank yields empty."""
    assert_equal(escape_drop_paths(String("/a/b.txt")),
                 String("/a/b.txt "))
    assert_equal(escape_drop_paths(String("/a b.txt\n/c d.txt")),
                 String("/a\\ b.txt /c\\ d.txt "))
    # Empty / whitespace-only input contributes no token and no trailing space.
    assert_equal(escape_drop_paths(String("")), String(""))
    assert_equal(escape_drop_paths(String("\n")), String(""))


def test_pane_text_select_drag() raises:
    # PaneTextSelect drives the mouse-drag text selection shared by the
    # Find-in-Project context panel and the docked Find Results pane. Two
    # rows are stamped (byte==cell: byte b lands at text_x + (b - byte_start)).
    var sel = PaneTextSelect()
    sel.begin_frame()
    sel.add_row(0, String("hello world"), 5, 2, 0, 11, 40)
    sel.add_row(1, String("second line"), 6, 2, 0, 11, 40)

    # A bare press (no motion yet) is not a selection — the caller still
    # treats it as a click. Press at byte 0 of row 0 (x == text_x == 2).
    assert_true(
        not sel.handle_mouse(Event.mouse_event(
            Point(2, 5), MOUSE_BUTTON_LEFT, True, False, MOD_NONE, 1,
        ))
    )
    assert_true(not sel.has_selection())

    # Drag to byte 5 of the same row (x == 2 + 5). Motion returns True so the
    # caller suppresses its own click handling; the span is "hello".
    _ = sel.handle_mouse(Event.mouse_event(
        Point(7, 5), MOUSE_BUTTON_LEFT, True, True, MOD_NONE, 1,
    ))
    assert_true(sel.has_selection())
    assert_equal(sel.text(), String("hello"))

    # Extend across into row 1 byte 6 (x == 2 + 6) — multi-row spans join
    # rows with a newline and include the rest of the first line.
    _ = sel.handle_mouse(Event.mouse_event(
        Point(8, 6), MOUSE_BUTTON_LEFT, True, True, MOD_NONE, 1,
    ))
    assert_equal(sel.text(), String("hello world\nsecond"))

    # Release commits — the selection persists for a subsequent Cmd+C.
    _ = sel.handle_mouse(Event.mouse_event(
        Point(8, 6), MOUSE_BUTTON_LEFT, False, False, MOD_NONE, 1,
    ))
    assert_true(sel.has_selection())
    assert_equal(sel.text(), String("hello world\nsecond"))

    # A dragged-backwards selection normalizes to document order.
    sel.begin_frame()
    sel.add_row(0, String("alpha"), 5, 2, 0, 5, 40)
    _ = sel.handle_mouse(Event.mouse_event(
        Point(5, 5), MOUSE_BUTTON_LEFT, True, False, MOD_NONE, 1,   # byte 3
    ))
    _ = sel.handle_mouse(Event.mouse_event(
        Point(2, 5), MOUSE_BUTTON_LEFT, True, True, MOD_NONE, 1,    # byte 0
    ))
    assert_equal(sel.text(), String("alp"))

    # A fresh press clears the prior selection (until it moves again).
    _ = sel.handle_mouse(Event.mouse_event(
        Point(4, 5), MOUSE_BUTTON_LEFT, True, False, MOD_NONE, 1,
    ))
    assert_true(not sel.has_selection())


def test_hit_title_command_returns_id_under_cursor() raises:
    var c = Canvas(40, 1)
    var commands = List[TitleCommand]()
    commands.append(TitleCommand(String("[X]"), String("first")))
    commands.append(TitleCommand(String("[Y]"), String("second")))
    var attr = Attr(WHITE, BLACK)
    var hits = paint_title_commands(
        c, Point(0, 0), commands, attr, attr, attr, 40,
    )
    # Inside the first command's rect.
    assert_equal(hit_title_command(hits, Point(3, 0)), String("first"))
    # On the gap between commands — no hit.
    assert_equal(hit_title_command(hits, Point(5, 0)), String(""))
    # Inside the second command's rect.
    assert_equal(hit_title_command(hits, Point(7, 0)), String("second"))
    # Different row — no hit.
    assert_equal(hit_title_command(hits, Point(3, 1)), String(""))


def test_event_factories() raises:
    var k = Event.key_event(KEY_ENTER)
    assert_true(k.kind == EVENT_KEY)
    assert_true(k.is_key(KEY_ENTER))

    var q = Event.quit_event()
    assert_true(q.kind == EVENT_QUIT)

    var r = Event.resize_event(80, 24)
    assert_true(r.kind == EVENT_RESIZE)
    assert_true(r.pos == Point(80, 24))


def test_centered() raises:
    var outer = Rect(0, 0, 80, 24)
    var inner = centered(outer, 20, 6)
    assert_true(inner == Rect(30, 9, 50, 15))


# ----- Scrollbar primitive tests --------------------------------------------


def test_text_buffer_split_and_join() raises:
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


def test_basename() raises:
    assert_equal(basename(String("/foo/bar")), String("bar"))
    assert_equal(basename(String("/foo/bar/")), String("bar"))
    assert_equal(basename(String("foo")), String("foo"))
    assert_equal(basename(String("/")), String("/"))


def test_right_aligned_menu_layout() raises:
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


def test_delete_tree_file_and_recursive_dir() raises:
    # Plain file: delete_tree with is_dir=False unlinks it.
    var f = _temp_path(String("_del_file.txt"))
    assert_true(write_file(f, String("x")))
    assert_true(stat_file(f).ok)
    assert_true(delete_tree(f, False))
    assert_false(stat_file(f).ok)
    # Directory with nested contents: recursive delete removes everything.
    var root = _temp_path(String("_del_dir"))
    # Best-effort clean of a stale tree from a prior run.
    _ = delete_tree(root, True)
    assert_equal(
        external_call["mkdir", Int32](
            (root + String("\0")).unsafe_ptr(), Int32(0o755),
        ),
        Int32(0),
    )
    var sub = join_path(root, String("sub"))
    assert_equal(
        external_call["mkdir", Int32](
            (sub + String("\0")).unsafe_ptr(), Int32(0o755),
        ),
        Int32(0),
    )
    assert_true(write_file(join_path(root, String("a.txt")), String("a")))
    assert_true(write_file(join_path(sub, String("b.txt")), String("b")))
    assert_true(delete_tree(root, True))
    assert_false(stat_file(root).ok)


def test_text_buffer_strips_crlf_on_split() raises:
    """A CRLF-encoded payload must split into clean lines — leaving the
    ``\\r`` byte attached to each line would later corrupt the terminal
    paint (stray ``\\r`` resets the cursor to column 0 mid-row) and
    confuse cursor / selection math.
    """
    var b = TextBuffer(String("ab\r\ncd\r\n"))
    assert_equal(b.line_count(), 3)
    assert_equal(b.line(0), String("ab"))
    assert_equal(b.line(1), String("cd"))
    assert_equal(b.line(2), String(""))
    # A trailing CR with no following LF also gets stripped.
    var b2 = TextBuffer(String("only\r"))
    assert_equal(b2.line_count(), 1)
    assert_equal(b2.line(0), String("only"))


def test_dispatch_paste_targets_focused_terminal_pane() raises:
    """⌘V on the native frontend arrives as ``dispatch_action(
    EDITOR_PASTE)`` via the Edit menu's key-equivalent. When a terminal
    pane owns keyboard focus the paste belongs to the pane — exactly
    like typing — and must not fall through to the editor window
    behind it. Regression: the old path called the focused editor's
    ``paste_from_clipboard`` unconditionally, which clobbered the
    editor's selection (with the test-suite fake clipboard the paste
    text is empty, so the selection is simply deleted)."""
    var path = _temp_path(String("_dpaste.txt"))
    assert_true(write_file(path, String("hello\n")))
    var d = Desktop()
    d.windows.add(Window.from_file(String("dpaste.txt"), Rect(0, 1, 40, 12), path))
    # Select "hello" so a stray editor paste would visibly mutate the buffer.
    d.windows.windows[0].editor.move_to(0, 0, False)
    d.windows.windows[0].editor.move_to(0, 5, True)
    assert_true(d.windows.windows[0].editor.has_selection())
    # A focused terminal pane (no pty child needed — routing is what's
    # under test; the pty write is a no-op when the child isn't alive).
    var pane = TerminalPane()
    pane.focused = True
    d.terminal_panes.append(pane^)
    var maybe = d.dispatch_action(EDITOR_PASTE, _SCREEN)
    assert_false(Bool(maybe))
    assert_equal(d.windows.windows[0].editor.buffer.line(0), String("hello"))
    assert_true(d.windows.windows[0].editor.has_selection())
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_app_focus_out_saves_all_dirty_windows_by_default() raises:
    """``EVENT_FOCUS_OUT`` from the host terminal flushes every dirty
    editor when ``config.auto_save`` is on — and that's the default,
    so a fresh ``Desktop()`` saves on wrapper-window focus loss
    without the user opting in."""
    var path_a = _temp_path(String("_app_fo_a.txt"))
    var path_b = _temp_path(String("_app_fo_b.txt"))
    assert_true(write_file(path_a, String("aaa\n")))
    assert_true(write_file(path_b, String("bbb\n")))
    var d = Desktop()
    # Sanity-check the default is on.
    assert_true(d.config.auto_save)
    d.windows.add(Window.from_file(String("a"), Rect(0, 1, 40, 12), path_a))
    d.windows.add(Window.from_file(String("b"), Rect(40, 1, 80, 12), path_b))
    # Make both dirty.
    for i in range(2):
        _ = d.windows.windows[i].editor.handle_key(
            Event.key_event(KEY_END), Rect(0, 1, 40, 12),
        )
        _ = d.windows.windows[i].editor.handle_key(
            Event.key_event(UInt32(ord("!"))), Rect(0, 1, 40, 12),
        )
        assert_true(d.windows.windows[i].editor.dirty)
    _ = d.handle_event(Event.focus_event(False), _SCREEN)
    assert_false(d.windows.windows[0].editor.dirty)
    assert_false(d.windows.windows[1].editor.dirty)
    assert_equal(read_file(path_a), String("aaa!\n"))
    assert_equal(read_file(path_b), String("bbb!\n"))
    _ = external_call["unlink", Int32]((path_a + String("\0")).unsafe_ptr())
    _ = external_call["unlink", Int32]((path_b + String("\0")).unsafe_ptr())


def test_normalize_ctrl_letter_preserves_cmd_bracket() raises:
    """Sanity-check: the terminal parser must NOT collapse Cmd+[
    down to ESC, AND must keep Cmd+ distinct from Ctrl+ on non-letter
    keys — otherwise we couldn't bind Cmd+2 (step over) separately
    from Ctrl+2 (focus window 2)."""
    # CSI 27 ; 9 ; 91 ~  — modifyOtherKeys=2 form for Cmd+[. Lands
    # as (0x5B, MOD_META): Cmd preserved, and not collapsed to ESC.
    var seq = String("\x1b[27;9;91~")
    var ev_consumed = parse_input(seq)
    assert_equal(ev_consumed[0].kind, EVENT_KEY)
    assert_equal(ev_consumed[0].key, UInt32(ord("[")))
    assert_equal(ev_consumed[0].mods, MOD_META)
    # Cmd+2 stays MOD_META.
    var seq_two = String("\x1b[27;9;50~")
    var ev_two = parse_input(seq_two)
    assert_equal(ev_two[0].key, UInt32(ord("2")))
    assert_equal(ev_two[0].mods, MOD_META)
    # Ctrl+2 (mod = 1 + 4 = 5) lands separately as MOD_CTRL.
    var seq_ctrl_two = String("\x1b[27;5;50~")
    var ev_ctrl_two = parse_input(seq_ctrl_two)
    assert_equal(ev_ctrl_two[0].key, UInt32(ord("2")))
    assert_equal(ev_ctrl_two[0].mods, MOD_CTRL)
    # Cmd+S surfaces as (ord('s'), MOD_META) so Cmd and Ctrl bindings
    # stay separate. Ctrl+S (the bare control byte, see test below) is
    # intentionally not bound by default.
    var seq_s = String("\x1b[27;9;115~")
    var ev_s = parse_input(seq_s)
    assert_equal(ev_s[0].key, UInt32(ord("s")))
    assert_equal(ev_s[0].mods, MOD_META)
    # Ctrl+S delivered as the modifyOtherKeys form lands canonical:
    # (ord('s'), MOD_CTRL). Same shape as Cmd+S above but with CTRL
    # instead of META so the two are addressable separately.
    var seq_ctrl_s = String("\x1b[27;5;115~")
    var ev_ctrl_s = parse_input(seq_ctrl_s)
    assert_equal(ev_ctrl_s[0].key, UInt32(ord("s")))
    assert_equal(ev_ctrl_s[0].mods, MOD_CTRL)


def test_format_hotkey_renders_combinations() raises:
    # Plain Ctrl+letter — canonical form is (lowercase letter, MOD_CTRL).
    assert_equal(format_hotkey(ctrl_key(String("q")), MOD_CTRL), String("Ctrl+Q"))
    assert_equal(format_hotkey(ctrl_key(String("s")), MOD_CTRL), String("Ctrl+S"))
    # Ctrl+Shift combos — same shape, with SHIFT in the mod set.
    assert_equal(
        format_hotkey(UInt32(ord("f")), MOD_CTRL | MOD_SHIFT),
        String("Ctrl+Shift+F"),
    )
    # Special keys.
    assert_equal(format_hotkey(KEY_F5, MOD_NONE), String("F5"))
    assert_equal(format_hotkey(KEY_UP, MOD_SHIFT), String("Shift+Up"))


def test_alt_letter_opens_menu_by_mnemonic() raises:
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


def test_detached_settings_clipboard_chord_does_not_recurse() raises:
    """Regression: a clipboard menu chord (⌘V / ⌘X / …) fired while the
    *detached* native Settings window is open must not recurse forever.

    On macOS the Edit menu's ⌘-key-equivalents land in
    ``dispatch_action`` directly. ``_modal_owns_input`` is true (Settings
    is open), so the action re-injects the chord — but the detached
    Settings block in ``handle_event`` is gated ``not settings_detached``
    and skips it, so the re-injected chord used to fall through to the
    hotkey table, re-match ⌘V → EDITOR_PASTE → ``dispatch_action`` again,
    and recurse until the stack overflowed (the app vanished with no
    crash report). The chord must instead reach the Settings surface — so
    a ⌘X with a selection in the language editor's argv strip cuts it.
    """
    var d = Desktop()
    d.set_settings_detached(True)
    d.settings.open(False)
    assert_true(d.settings.active)
    # Open the language editor and focus its argv strip with a selection.
    d.settings.language_editor.open(
        String("lang"), List[String](), List[String](), False,
    )
    d.settings.language_editor._add_candidate()
    d.settings.language_editor.argv_tf.set_text(String("pylsp --stdio"))
    d.settings.language_editor.argv_tf.select_all()
    assert_true(d.settings.language_editor.argv_tf.has_selection())
    # Pre-fix this recursed to a stack overflow; post-fix it returns and
    # the chord reaches the argv field (cut deletes the selection).
    var maybe = d.dispatch_action(EDITOR_CUT, _SCREEN)
    assert_false(Bool(maybe))
    assert_equal(
        len(d.settings.language_editor.argv_tf.text.as_bytes()), 0,
    )
    # A paste chord likewise returns rather than recursing.
    var maybe2 = d.dispatch_action(EDITOR_PASTE, _SCREEN)
    assert_false(Bool(maybe2))


def test_is_printable_ascii_gates_search_keys() raises:
    """The framework predicate that decides "is this a search
    keystroke or a control key" — must include letters / digits /
    punctuation and exclude DEL, NUL, arrow-key codes, etc."""
    assert_true(is_printable_ascii(UInt32(ord("a"))))
    assert_true(is_printable_ascii(UInt32(ord("Z"))))
    assert_true(is_printable_ascii(UInt32(ord("0"))))
    assert_true(is_printable_ascii(UInt32(0x20)))   # space
    assert_false(is_printable_ascii(UInt32(0x1F)))  # below printable
    assert_false(is_printable_ascii(UInt32(0x7F)))  # DEL


def test_expand_save_placeholders_substitutes_filepath() raises:
    """``$FilePath$`` in an arg is replaced by the saved file path at
    spawn time. This is the only placeholder we recognise today."""
    var got = _expand_save_placeholders(
        String("$FilePath$"), String("/work/main.py"),
    )
    assert_equal(got, String("/work/main.py"))
    var inline = _expand_save_placeholders(
        String("--target=$FilePath$"), String("/work/main.py"),
    )
    assert_equal(inline, String("--target=/work/main.py"))
    var multi = _expand_save_placeholders(
        String("$FilePath$:$FilePath$"), String("/x"),
    )
    assert_equal(multi, String("/x:/x"))
    # No placeholder = pass-through.
    var passthrough = _expand_save_placeholders(
        String("--quiet"), String("/work/main.py"),
    )
    assert_equal(passthrough, String("--quiet"))
    # The token is case-sensitive — ``$filepath$`` is left alone so a
    # user who genuinely wants that literal string can have it.
    var case_sensitive = _expand_save_placeholders(
        String("$filepath$"), String("/work/main.py"),
    )
    assert_equal(case_sensitive, String("$filepath$"))


def test_pyenv_pin_satisfaction() raises:
    """The broken-pyenv-shim detector: a ``.python-version`` pin only
    counts as satisfied when it names ``system`` or an exactly-matching
    installed version directory. The uv-managed case — pin ``3.14``,
    pyenv has only ``3.12.6`` — must read as broken even though uv
    itself would resolve it fine."""
    var installed = List[String]()
    installed.append(String("3.12.6"))
    # uv-style pin that pyenv can't satisfy.
    var uv_pin = _split_version_pins(String("3.14\n"))
    assert_equal(len(uv_pin), 1)
    assert_equal(uv_pin[0], String("3.14"))
    assert_false(_pyenv_pins_satisfied(uv_pin, installed))
    # Exact match works; no prefix resolution in either direction.
    assert_true(_pyenv_pins_satisfied(
        _split_version_pins(String("3.12.6")), installed,
    ))
    assert_false(_pyenv_pins_satisfied(
        _split_version_pins(String("3.12")), installed,
    ))
    # ``system`` is always available.
    assert_true(_pyenv_pins_satisfied(
        _split_version_pins(String("system")), installed,
    ))
    # Multi-version file: every line must be installed.
    assert_false(_pyenv_pins_satisfied(
        _split_version_pins(String("3.12.6\n3.14\n")), installed,
    ))
    # CRLF + surrounding whitespace are stripped by the splitter.
    var crlf = _split_version_pins(String("  3.12.6\r\n"))
    assert_equal(len(crlf), 1)
    assert_equal(crlf[0], String("3.12.6"))
    # Empty file → no pins → caller treats as "global applies".
    assert_equal(len(_split_version_pins(String("\n"))), 0)


def test_extension_of_helper() raises:
    assert_equal(extension_of(String("foo.mojo")), String("mojo"))
    assert_equal(extension_of(String("a/b/foo.MOJO")), String("mojo"))
    assert_equal(extension_of(String("Makefile")), String(""))
    assert_equal(extension_of(String("a.b/c")), String(""))   # dot before /
    assert_equal(extension_of(String("")), String(""))


def test_document_link_over_template_tag_is_dropped() raises:
    """An HTML language server that doesn't parse Django emits a naive
    documentLink over the whole ``href="{% static '…' %}"`` value — which
    underlines the entire tag and hijacks Cmd+click away from the
    project-aware template resolution. ``set_document_links`` must drop any
    link whose span covers a ``{% %}`` / ``{{ }}`` tag, while keeping real
    links untouched."""
    var line = String(
        '<link href="{% static ' + "'offer_extra.css'"
        + ' %}" rel="stylesheet">'
    )
    var ed = Editor(line)
    var links = List[TextEditEntry]()
    # href value spans bytes 12..42 (covers the template tag) → dropped.
    links.append(TextEditEntry(0, 12, 0, 42, String("file:///bogus")))
    # A plain link with no template tag → kept.
    links.append(TextEditEntry(0, 0, 0, 5, String("https://example.com")))
    ed.set_document_links(links^)
    assert_equal(len(ed.document_links), 1)
    assert_equal(ed.document_link_at(0, 27), String(""))          # tag: gone
    assert_equal(ed.document_link_at(0, 2), String("https://example.com"))


def test_big_buffer_disables_wrap_and_highlight() raises:
    """Wrap reflows and syntax tokenizing both scan every line, so a huge
    buffer must bail out of both. A single very long line (minified JS/CSS)
    trips ``_big_buffer``; ordinary content does not. When set,
    ``flush_highlights`` must produce no highlights (skip the slow
    TextMate/onig pass) instead of hanging."""
    var long_line = String("")
    for _ in range(6000):                       # > _BIG_BUFFER_LINE_BYTES
        long_line += "x"
    var big = Editor(long_line + String(".js"))
    big.file_path = String("min.js")
    assert_true(big._big_buffer)
    var registry = GrammarRegistry()
    var speller = Speller()
    big.flush_highlights(registry, speller)     # must be instant, not ~28 s
    assert_equal(len(big.highlights), 0)
    var small = Editor(String("def f():\n    return 1\n"))
    assert_true(not small._big_buffer)
    # Many short lines, well under the total cap → still wrappable.
    var many = String("")
    for _ in range(500):
        many += "a short line of code\n"
    var med = Editor(many^)
    assert_true(not med._big_buffer)


def test_replace_in_project_round_trip() raises:
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


def test_fit_title_path_keeps_tail_with_ellipsis() raises:
    """``_fit_title_path`` returns the whole path when it fits and a
    leading-ellipsis tail (filename end preserved) when it doesn't."""
    var p = String("/tmp/proj/hello.mojo")  # 20 columns
    # Fits exactly.
    assert_equal(_fit_title_path(p, 20), p)
    assert_equal(_fit_title_path(p, 99), p)
    # Too narrow: leading "…" + tail, total within max_cols, tail kept.
    var t = _fit_title_path(p, 10)
    assert_equal(display_columns(t), 10)
    assert_equal(t, String("…") + tail_to_columns(p, 9))
    assert_true(t.find(String(".mojo")) != -1)  # filename tail kept
    # Degenerate width.
    assert_equal(_fit_title_path(p, 0), String("…"))


def test_partial_sgr_mouse_does_not_emit_esc() raises:
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


def test_accept_completion_multibyte_prefix_deletes_codepoints() raises:
    """The replace span arrives as byte offsets but is deleted one
    *codepoint* at a time; iterating a byte count over-deletes a
    multibyte prefix and eats preceding characters. Replacing the
    2-byte ``ä`` in ``xyzä`` must leave ``xyz`` intact (not chew into
    ``z``)."""
    var ed = Editor(String("xyzä"))
    ed.move_to(0, 5, False)   # cursor at end (byte 5, past the 2-byte ä)
    var items = List[CompletionItem]()
    items.append(CompletionItem(
        String("Ä"), String("Ä"), 1, String(""), String("Ä"),
        True, 0, 3, 0, 5,        # has_range: replace bytes [3,5) == "ä"
        List[TextEditEntry](),
    ))
    ed.set_completions(items^, 0, 3)
    assert_true(ed.accept_completion())
    assert_equal(ed.buffer.line(0), String("xyzÄ"))


def test_resolve_python_interpreter() raises:
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


def test_restore_caps_to_most_recently_focused() raises:
    """Session restore honors ``max_open_windows``: it reopens only the
    most-recently-focused ``cap`` documents (always including the
    focused one), so a launch with a huge saved session doesn't pay to
    reconstruct every window on the first frame."""
    var root = String("/tmp/turbokod_restore_cap_test")
    var cleanup = String("rm -rf '") + root + String("'\0")
    _ = external_call["system", Int32](cleanup.unsafe_ptr())
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    assert_true(write_file(root + String("/a.txt"), String("a\n")))
    assert_true(write_file(root + String("/b.txt"), String("b\n")))
    assert_true(write_file(root + String("/c.txt"), String("c\n")))
    # Hand-author a session with three windows of distinct recency.
    # ``a`` is the focused (least-recent) one — it must survive the cap;
    # ``b`` is most-recent; ``c`` is in between and gets dropped at cap=2.
    var s = Session()
    var wa = SessionWindow()
    wa.path = String("a.txt")
    wa.rect_a_x = 2; wa.rect_a_y = 1; wa.rect_b_x = 30; wa.rect_b_y = 12
    wa.restore_a_x = 2; wa.restore_a_y = 1
    wa.restore_b_x = 30; wa.restore_b_y = 12
    wa.last_focus_ms = 100
    s.windows.append(wa^)
    var wb = SessionWindow()
    wb.path = String("b.txt")
    wb.rect_a_x = 32; wb.rect_a_y = 1; wb.rect_b_x = 60; wb.rect_b_y = 12
    wb.restore_a_x = 32; wb.restore_a_y = 1
    wb.restore_b_x = 60; wb.restore_b_y = 12
    wb.last_focus_ms = 300
    s.windows.append(wb^)
    var wc = SessionWindow()
    wc.path = String("c.txt")
    wc.rect_a_x = 2; wc.rect_a_y = 14; wc.rect_b_x = 30; wc.rect_b_y = 25
    wc.restore_a_x = 2; wc.restore_a_y = 14
    wc.restore_b_x = 30; wc.restore_b_y = 25
    wc.last_focus_ms = 200
    s.windows.append(wc^)
    s.z_order.append(0); s.z_order.append(2); s.z_order.append(1)
    s.focused = 0
    assert_true(save_session(root, s))

    var screen = Rect(0, 0, 80, 30)
    var canvas = Canvas(80, 30)
    var d = Desktop()
    d.open_project(root)
    d.config.max_open_windows = 2
    assert_true(d._pending_restore)
    d.paint(canvas, screen)
    # Only two documents reopened: focused ``a`` (always kept) and the
    # most-recently-focused ``b``; ``c`` is dropped.
    assert_equal(len(_doc_paths(d)), 2)
    assert_true(_docs_contains(d, String("a.txt")))
    assert_true(_docs_contains(d, String("b.txt")))
    assert_false(_docs_contains(d, String("c.txt")))
    _ = external_call["system", Int32](cleanup.unsafe_ptr())


def test_discard_line_round_trip_against_real_git() raises:
    """End-to-end for line-level discard (the ``d`` key in the Unstaged
    panel): spin up a throwaway repo, add two new lines to a committed
    file, then reverse-apply the minimal patch for ONE of them to the
    working tree. The targeted line must vanish from the file while the
    other added line stays — the discard is surgical, not whole-file.
    Skipped silently when ``git`` is missing or ``git init`` fails."""
    var dir = _temp_path(String("_discard_int"))
    _rm_rf(dir)
    _ensure_dir(dir)
    var init_args = List[String]()
    init_args.append(String("init"))
    init_args.append(String("-q"))
    init_args.append(String("-b"))
    init_args.append(String("main"))
    var rc = _run_git(dir, init_args^)
    if rc != 0:
        _rm_rf(dir)
        return
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
    # Two independent additions: NEW1 after beta, NEW2 after gamma.
    assert_true(write_file(f, String("alpha\nbeta\nNEW1\ngamma\nNEW2\n")))
    var unstaged = compute_unstaged_diff(dir)
    assert_true(len(unstaged.as_bytes()) > 0)
    var per_file = parse_unified_diff_files(unstaged)
    assert_equal(len(per_file), 1)
    # Find the ``+NEW2`` line index in the per-file diff.
    var lines = List[String]()
    var b = per_file[0].diff.as_bytes()
    var s = 0
    for i in range(len(b)):
        if b[i] == 0x0A:
            lines.append(String(StringSpan(unsafe_from_utf8=b[s:i])))
            s = i + 1
    if s < len(b):
        lines.append(String(StringSpan(unsafe_from_utf8=b[s:len(b)])))
    var target_idx = -1
    for i in range(len(lines)):
        if lines[i] == String("+NEW2"):
            target_idx = i
            break
    assert_true(target_idx > 0)
    # reverse=True builds a patch whose post-image matches the worktree
    # (other ``+`` demoted to context); reverse-applying it to the
    # working tree drops only ``NEW2``.
    var patch = build_minimal_patch(per_file[0].diff, target_idx, True)
    assert_true(len(patch.as_bytes()) > 0)
    assert_true(String("+NEW2") in patch)
    assert_true(apply_patch_to_worktree(dir, patch, True))
    # NEW2 gone, NEW1 kept, original content intact.
    assert_equal(read_file(f), String("alpha\nbeta\nNEW1\ngamma\n"))
    # The index was untouched (we patched the worktree, not --cached), so
    # the file is still tracked-modified, not staged.
    var statuses = fetch_git_status(dir)
    assert_equal(len(statuses), 1)
    assert_equal(Int(statuses[0].staged), 0x20)
    assert_equal(Int(statuses[0].worktree), 0x4D)    # 'M'
    _rm_rf(dir)


def test_corrupt_config_is_not_clobbered_with_defaults() raises:
    """A config file that exists but won't parse must NOT be silently
    replaced by defaults that then get saved back — that's how a transient
    read glitch turns into permanent total settings loss. The loader moves
    the unreadable file aside (preserving it) and reports persistability so
    the caller knows the defaults are safe to write only because the
    original is out of the way.
    """
    var home = String("/tmp/turbokod_test_home")
    var dir = home + String("/.config/turbokod")
    var path = dir + String("/config.json")
    var corrupt_glob = path + String(".corrupt")

    # Clean any leftovers from a prior run so the aside-move lands on the
    # canonical ``.corrupt`` name (not ``.corrupt.1``).
    _ = delete_path(path)
    _ = delete_path(corrupt_glob)

    # 1. A clean save round-trips and is persistable.
    var cfg = TurbokodConfig()
    cfg.theme = String("MyCustomTheme")
    cfg.font_size = 19
    assert_true(save_config(cfg))
    var loaded = load_config()
    assert_true(loaded.persistable)
    assert_equal(loaded.config.theme, String("MyCustomTheme"))
    assert_equal(loaded.config.font_size, 19)

    # 2. Corrupt the file in place (simulating a torn/garbage config).
    assert_true(write_file(path, String("{ this is not valid json ]}")))

    # 3. Load now returns defaults — but the original was moved aside, not
    #    destroyed, and the result is persistable (safe to overwrite the
    #    now-absent canonical path).
    var recovered = load_config()
    assert_equal(recovered.config.theme, String("Turbo C++ 3.0"))
    assert_true(recovered.persistable)
    # The unreadable bytes are preserved under ``.corrupt`` for recovery...
    var aside = stat_file(corrupt_glob)
    assert_true(aside.ok)
    assert_equal(
        read_file(corrupt_glob), String("{ this is not valid json ]}"),
    )
    # ...and the canonical path no longer holds the garbage.
    assert_false(stat_file(path).ok)

    _ = delete_path(corrupt_glob)


def main() raises:
    setup_test_env()
    test_help_hotkeys_opens_readonly_reference()
    test_emoji_double_width()
    test_escape_drop_paths_joins_and_trails()
    test_pane_text_select_drag()
    test_hit_title_command_returns_id_under_cursor()
    test_event_factories()
    test_centered()
    test_text_buffer_split_and_join()
    test_basename()
    test_right_aligned_menu_layout()
    test_delete_tree_file_and_recursive_dir()
    test_text_buffer_strips_crlf_on_split()
    test_dispatch_paste_targets_focused_terminal_pane()
    test_app_focus_out_saves_all_dirty_windows_by_default()
    test_normalize_ctrl_letter_preserves_cmd_bracket()
    test_format_hotkey_renders_combinations()
    test_alt_letter_opens_menu_by_mnemonic()
    test_detached_settings_clipboard_chord_does_not_recurse()
    test_is_printable_ascii_gates_search_keys()
    test_expand_save_placeholders_substitutes_filepath()
    test_pyenv_pin_satisfaction()
    test_extension_of_helper()
    test_document_link_over_template_tag_is_dropped()
    test_big_buffer_disables_wrap_and_highlight()
    test_replace_in_project_round_trip()
    test_fit_title_path_keeps_tail_with_ellipsis()
    test_partial_sgr_mouse_does_not_emit_esc()
    test_accept_completion_multibyte_prefix_deletes_codepoints()
    test_resolve_python_interpreter()
    test_restore_caps_to_most_recently_focused()
    test_discard_line_round_trip_against_real_git()
    test_corrupt_config_is_not_clobbered_with_defaults()
    print("misc: 32 tests passed")
