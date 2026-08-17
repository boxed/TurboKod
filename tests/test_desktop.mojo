"""Desktop shell: windows, navigation, session, projects.

One of the per-topic suites split out of the former
``test_basic.mojo``; shared fixtures live in ``tests/support.mojo``
and ``scripts/run_tests.sh`` runs every suite.
"""

from std.ffi import external_call
from std.testing import assert_equal, assert_false, assert_true
from turbokod.canvas import Canvas
from turbokod.claude_detect import CLAUDE_WAITING, CLAUDE_WORKING
from turbokod.colors import default_attr
from turbokod.session_store import (
    Session, SessionWindow, _resolve_session_path, _session_path,
    encode_session, load_session, save_session
)
from turbokod.view_state_store import (
    StoredViewState, load_view_states, save_view_states
)
from turbokod.drafts_store import StoredDraft, save_drafts
from turbokod.desktop import (
    Desktop, PendingSaveAction,
    EDITOR_FIND, EDITOR_NAV_BACK, EDITOR_NAV_FORWARD, EDITOR_NEW,
    EDITOR_REPLACE, EDITOR_SAVE, EDITOR_SAVE_AS, PROJECT_CLOSE_ACTION,
    PROJECT_SETTINGS, PROJECT_FIND, PROJECT_OPEN_RECENT_PREFIX,
    PROJECT_REPLACE, WINDOW_CLOSE_ALL, WINDOW_FOCUS_PREFIX
)
from turbokod.file_io import (
    basename, delete_path, find_git_project, join_path, project_relative,
    read_file, stat_file, write_file
)
from turbokod.file_tree import FILE_TREE_WIDTH
from turbokod.onig import onig_global_init, onig_tracked_count
from turbokod.project_targets import (
    ProjectTargets, RunTarget, load_project_targets, resolved_cwd,
    resolved_program, save_project_targets
)
from turbokod.project_settings import ProjectSettings
from turbokod.project_on_save import (
    load_project_on_save, write_project_on_save
)
from turbokod.install_runner import InstallRunner
from turbokod.json import parse_json
from turbokod.lsp_dispatch import (
    CompletionItem, DefinitionResolved, TextEditEntry
)
from turbokod.lsp import LspProcess
from turbokod.posix import close_fd, kill_pid, which
from turbokod.project_grammars import GrammarOverride
from turbokod.config import (
    MAX_FONT_SIZE, MIN_FONT_SIZE, OnSaveAction, WRAP_SOFT
)
from turbokod.settings import Settings
from turbokod.window import WindowManager
from turbokod.events import (
    Event, EVENT_FOCUS_OUT, EVENT_RESIZE, KEY_END, KEY_ENTER, KEY_ESC,
    MOD_META, MOUSE_BUTTON_LEFT, MOUSE_BUTTON_NONE
)
from turbokod.geometry import Point, Rect
from turbokod.prompt import (
    SUBMIT_FIND_NEXT, SUBMIT_REPLACE, SUBMIT_REPLACE_ALL
)
from turbokod.terminal_pane import TerminalPane
from turbokod.view import Fill, Label, centered
from turbokod.window import Window

from support import (
    _SCREEN, _doc_paths, _docs_contains, _key, _ps_open, _starts_with,
    _temp_path, setup_test_env
)


def _title_row_text(c: Canvas, y: Int, x0: Int, x1: Int) -> String:
    """Concatenate the glyphs of canvas row ``y`` over ``[x0, x1)`` so a
    test can substring-match what's painted on a title bar."""
    var s = String("")
    for x in range(x0, x1):
        s += c.get(x, y).glyph
    return s


def _popup_items_one() -> List[CompletionItem]:
    var items = List[CompletionItem]()
    items.append(CompletionItem(
        String("foobar"), String("foobar"), 6, String(""), String("foobar"),
        False, 0, 0, 0, 0,
        List[TextEditEntry](),
    ))
    return items^


def test_desktop_take_attention_drains_panes_and_dap() raises:
    """``Desktop.take_attention_events`` sums + clears the Desktop
    counter (debugger stops) and every terminal pane's counter."""
    var d = Desktop()
    d.attention_events = 1                       # as bumped by dap_tick
    d.terminal_panes.append(TerminalPane())
    d.terminal_panes[0]._note_claude_state(CLAUDE_WORKING, 0)
    d.terminal_panes[0]._note_claude_state(CLAUDE_WAITING, 0)
    d.terminal_panes[0]._note_claude_state(CLAUDE_WAITING, 2000)
    assert_equal(d.take_attention_events(), 2)
    assert_equal(d.take_attention_events(), 0)   # drained


def test_open_file_at_golden_when_already_open() raises:
    """A deliberate open-at-line jump golden-centers the target whether
    the file is being opened fresh OR is already open in a window. Uses a
    temp file under /tmp (no project root) so ``paint``'s session-restore
    never fires and contaminates the window list."""
    var path = _temp_path(String("_golden.txt"))
    var content = String("L0")
    for i in range(1, 3000):
        content += "\n" + String("L") + String(i)
    assert_true(write_file(path, content))
    var d = Desktop()
    var screen = Rect(0, 0, 120, 50)
    # Fresh open at a deep line.
    d.open_file_at(path, 1500, 0, screen)
    var idx = len(d.windows.windows) - 1
    assert_true(d.windows.windows[idx].is_editor)
    var h = d.windows.windows[idx].interior().height()
    var above = ((h - 1) * 382) // 1000
    assert_equal(
        d.windows.windows[idx].editor.selections[0].row
            - d.windows.windows[idx].editor.scroll_y,
        above,
    )                                            # fresh = golden
    # Jump again to a different deep line — now ALREADY open (same path).
    d.open_file_at(path, 2500, 0, screen)
    assert_equal(len(d.windows.windows), idx + 1)   # no second window
    assert_equal(
        d.windows.windows[idx].editor.selections[0].row
            - d.windows.windows[idx].editor.scroll_y,
        above,
    )                                            # already-open = golden too
    # ``_jump_to`` (goto-definition / references / nav) defaults to golden
    # for an already-open file too — the regression the user hit.
    d._jump_to(DefinitionResolved(path, 1000, 0), screen)
    assert_equal(len(d.windows.windows), idx + 1)
    assert_equal(
        d.windows.windows[idx].editor.selections[0].row
            - d.windows.windows[idx].editor.scroll_y,
        above,
    )
    # …and the debugger opt-out (``golden=False``) does NOT golden-center:
    # a small step from the current line keeps minimal edge scroll.
    d._jump_to(DefinitionResolved(path, 1005, 0), screen, golden=False)
    assert_equal(
        d.windows.windows[idx].editor.selections[0].row
            - d.windows.windows[idx].editor.scroll_y,
        above + 5,                               # 5 rows below the golden row
    )
    # Regression: with soft/smart wrap ON (the myapp-project default), an
    # already-open jump still golden-centers rather than falling back to
    # minimal edge scroll. Short lines wrap to one visual row each, so the
    # buffer-row offset equals the visual-row offset = ``above``.
    d.windows.windows[idx].editor.wrap_mode = WRAP_SOFT
    d._jump_to(DefinitionResolved(path, 2000, 0), screen)
    assert_equal(
        d.windows.windows[idx].editor.selections[0].row
            - d.windows.windows[idx].editor.scroll_y,
        above,
    )


def test_desktop_project_lifecycle() raises:
    var d = Desktop()
    assert_false(d.project)
    # The Project menu is created at construction time and is always
    # labelled "Project" — both in the no-project state and once a
    # project is loaded. Right-aligned so it lives on the far right
    # of the menu bar. The empty default config has no recents to
    # show, so the initial item list is empty.
    var idx = d._project_menu_idx
    assert_true(idx >= 0)
    assert_true(d.menu_bar.menus[idx].visible)
    assert_true(d.menu_bar.menus[idx].right_aligned)
    assert_equal(d.menu_bar.menus[idx].label, String("Project"))
    assert_equal(len(d.menu_bar.menus[idx].items), 0)
    d.detect_project_from(String("examples/hello.mojo"))
    assert_true(d.project)
    assert_true(d.menu_bar.menus[idx].visible)
    # Label stays "Project" — the project name lives in the window
    # title bar, not the menu label.
    assert_equal(d.menu_bar.menus[idx].label, String("Project"))
    # Active-project items: Project Settings..., separator (no other
    # recents survive — ``_append_recent_project_items`` skips the active
    # one), close. (The file-tree cycle lives in the host's View menu, not
    # here.) ``_set_project`` drops the orphan separator only when the
    # recents block is entirely empty; with a single matching-active recent
    # we still see one separator (between the project actions and Close
    # project). Separators carry no action.
    assert_equal(
        d.menu_bar.menus[idx].items[0].action, PROJECT_SETTINGS,
    )
    var last = len(d.menu_bar.menus[idx].items) - 1
    assert_equal(
        d.menu_bar.menus[idx].items[last].action, PROJECT_CLOSE_ACTION,
    )
    assert_true(d.menu_bar.menus[idx].items[last - 1].is_separator)
    # Detection is sticky: a second call doesn't reset the project.
    var first = d.project.value()
    d.detect_project_from(String("src/turbokod/desktop.mojo"))
    assert_equal(d.project.value(), first)
    # close_project clears project state but keeps the menu visible.
    # The label stays "Project" and the dropdown is just the inline
    # recent-project list now. ``_set_project`` recorded the turbokod
    # root into ``config.recent_projects`` on the way in, so at least
    # one direct-pick entry exists here.
    d.close_project()
    assert_false(d.project)
    assert_true(d.menu_bar.menus[idx].visible)
    assert_equal(d.menu_bar.menus[idx].label, String("Project"))
    assert_true(len(d.menu_bar.menus[idx].items) >= 1)
    assert_true(_starts_with(
        d.menu_bar.menus[idx].items[0].action, PROJECT_OPEN_RECENT_PREFIX,
    ))
    # After closing, detection works again.
    d.detect_project_from(String("examples/hello.mojo"))
    assert_true(d.project)
    assert_true(d.menu_bar.menus[idx].visible)
    assert_equal(d.menu_bar.menus[idx].label, String("Project"))


def test_recent_project_pick_routes_to_new_window_when_host_owns_menu() raises:
    """When ``host_owns_menu`` is on (Swift frontend), picking a recent
    project from the Project menu must stash the path on the Desktop and
    return the ``app.new_window`` sentinel so the host spawns a window
    and reads the path back. With ``host_owns_menu`` off (terminal) the
    same action falls back to swap-in-place — verified by the absence
    of a pending path after dispatch."""
    var d = Desktop()
    # Prime recents by detecting and then closing the current project.
    d.detect_project_from(String("examples/hello.mojo"))
    var primed = d.project.value()
    d.close_project()
    # Find the recent-project action we just primed — its index in
    # ``config.recent_projects`` is the suffix of its menu action.
    var slot = -1
    for i in range(len(d.config.recent_projects)):
        if d.config.recent_projects[i] == primed:
            slot = i
            break
    assert_true(slot >= 0)
    var action = PROJECT_OPEN_RECENT_PREFIX + String(slot)
    # Host-owned: dispatch returns the host sentinel and stashes the path.
    d.host_owns_menu = True
    var screen = Rect(0, 0, 80, 24)
    var result = d.dispatch_action(action, screen)
    assert_true(result)
    assert_equal(result.value(), String("app.new_window"))
    assert_true(d._pending_new_window_project)
    assert_equal(d._pending_new_window_project.value(), primed)
    assert_false(d.project)   # didn't open here — host will spawn the window
    # Terminal path: same action swaps in place, no pending path.
    d._pending_new_window_project = Optional[String]()
    d.host_owns_menu = False
    var r2 = d.dispatch_action(action, screen)
    assert_false(r2)
    assert_false(d._pending_new_window_project)
    assert_true(d.project)
    assert_equal(d.project.value(), primed)


def test_desktop_file_tree_cycle_shrinks_workspace() raises:
    """The View-menu file-tree item is a three-way cycle:
    hidden → docked right → docked left → hidden. The workspace gives
    up ``FILE_TREE_WIDTH`` columns on whichever side the tree occupies."""
    var d = Desktop()
    var screen = Rect(0, 0, 100, 30)
    var ws_no_tree = d.workspace_rect(screen)
    assert_equal(ws_no_tree.a.x, 0)
    assert_equal(ws_no_tree.b.x, 100)
    # Detect project, then cycle the tree on via the menu action handler.
    d.detect_project_from(String("examples/hello.mojo"))
    d._cycle_file_tree()
    assert_true(d.file_tree.visible)
    assert_false(d.file_tree.dock_left)
    var ws_right = d.workspace_rect(screen)
    assert_equal(ws_right.a.x, 0)
    assert_equal(ws_right.b.x, 100 - FILE_TREE_WIDTH)
    assert_equal(d.file_tree.rect(screen).a.x, 100 - FILE_TREE_WIDTH)
    # Second step: same tree, docked on the left edge instead.
    d._cycle_file_tree()
    assert_true(d.file_tree.visible)
    assert_true(d.file_tree.dock_left)
    var ws_left = d.workspace_rect(screen)
    assert_equal(ws_left.a.x, FILE_TREE_WIDTH)
    assert_equal(ws_left.b.x, 100)
    assert_equal(d.file_tree.rect(screen).a.x, 0)
    # Third step: hidden again, workspace back to full width.
    d._cycle_file_tree()
    assert_false(d.file_tree.visible)
    assert_equal(d.workspace_rect(screen).a.x, 0)
    assert_equal(d.workspace_rect(screen).b.x, 100)


def test_window_min_size_enforced_at_construction() raises:
    """Framework guarantees the rect is wide enough for close + maximize
    chrome and tall enough to hold both borders, even if the caller
    passed a smaller rect."""
    var w = Window(String("tiny"), Rect(0, 0, 3, 1), List[String]())
    assert_true(w.rect.width() >= 10)
    assert_true(w.rect.height() >= 2)
    var ed = Window.editor_window(String("e"), Rect(5, 5, 8, 6), String(""))
    assert_true(ed.rect.width() >= 10)
    assert_true(ed.rect.height() >= 2)


def test_window_min_size_survives_workspace_shrink() raises:
    """``fit_into`` must not produce a sub-minimum window when scaling
    into a workspace that's smaller than the caller's original."""
    var wm = WindowManager()
    wm.add(Window(String("A"), Rect(0, 0, 80, 24), List[String]()))
    wm.fit_into(Rect(0, 0, 80, 24))
    wm.fit_into(Rect(0, 0, 12, 4))
    assert_true(wm.windows[0].rect.width() >= 10)
    assert_true(wm.windows[0].rect.height() >= 2)


def test_window_manager_fit_into_moves_then_resizes() raises:
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


def test_desktop_dispatch_editor_save_passes_through_when_no_editor() raises:
    """Save with no editor focused should be a no-op intercepted by Desktop —
    the action does not bubble back to the caller."""
    var d = Desktop()
    var maybe = d.dispatch_action(EDITOR_SAVE, _SCREEN)
    assert_false(Bool(maybe))


def test_desktop_dispatch_passes_through_unknown_actions() raises:
    var d = Desktop()
    var maybe = d.dispatch_action(String("focus:About"), _SCREEN)
    assert_true(Bool(maybe))
    assert_equal(maybe.value(), String("focus:About"))


def test_desktop_dispatch_editor_save_writes_focused_editor() raises:
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


def test_window_focus_change_saves_prior_window() raises:
    """Switching focus from window A to window B saves A's dirty
    buffer — the per-window counterpart of ``EVENT_FOCUS_OUT``'s
    app-wide save. Exercises the default (``config.auto_save`` is
    ``True`` out of the box)."""
    var path_a = _temp_path(String("_wfc_a.txt"))
    var path_b = _temp_path(String("_wfc_b.txt"))
    assert_true(write_file(path_a, String("aaa\n")))
    assert_true(write_file(path_b, String("bbb\n")))
    var d = Desktop()
    var canvas = Canvas(_SCREEN.width(), _SCREEN.height())
    d.windows.add(Window.from_file(String("a"), Rect(0, 1, 40, 12), path_a))
    d.windows.add(Window.from_file(String("b"), Rect(40, 1, 80, 12), path_b))
    # Seed the focus tracker with the current focused editor.
    d.paint(canvas, _SCREEN)
    # Make A dirty.
    d.windows.focus_by_index(0)
    _ = d.windows.windows[0].editor.handle_key(
        Event.key_event(KEY_END), Rect(0, 1, 40, 12),
    )
    _ = d.windows.windows[0].editor.handle_key(
        Event.key_event(UInt32(ord("!"))), Rect(0, 1, 40, 12),
    )
    assert_true(d.windows.windows[0].editor.dirty)
    # Run a paint to update the tracker against A.
    d.paint(canvas, _SCREEN)
    # Switch focus to B — next paint should save A.
    d.windows.focus_by_index(1)
    d.paint(canvas, _SCREEN)
    assert_false(d.windows.windows[0].editor.dirty)
    assert_equal(read_file(path_a), String("aaa!\n"))
    _ = external_call["unlink", Int32]((path_a + String("\0")).unsafe_ptr())
    _ = external_call["unlink", Int32]((path_b + String("\0")).unsafe_ptr())


def test_window_focus_change_via_dispatch_action_saves() raises:
    """The tab bar click path lands at ``dispatch_action(WINDOW_FOCUS_PREFIX
    + idx)``. After the next paint that route must have saved the
    previously focused dirty editor — same as direct ``focus_by_index``."""
    var path_a = _temp_path(String("_wfc_disp_a.txt"))
    var path_b = _temp_path(String("_wfc_disp_b.txt"))
    assert_true(write_file(path_a, String("aaa\n")))
    assert_true(write_file(path_b, String("bbb\n")))
    var d = Desktop()
    var canvas = Canvas(_SCREEN.width(), _SCREEN.height())
    d.windows.add(Window.from_file(String("a"), Rect(0, 1, 40, 12), path_a))
    d.windows.add(Window.from_file(String("b"), Rect(40, 1, 80, 12), path_b))
    d.paint(canvas, _SCREEN)
    # Focus A and dirty it.
    _ = d.dispatch_action(WINDOW_FOCUS_PREFIX + String(0), _SCREEN)
    _ = d.windows.windows[0].editor.handle_key(
        Event.key_event(KEY_END), Rect(0, 1, 40, 12),
    )
    _ = d.windows.windows[0].editor.handle_key(
        Event.key_event(UInt32(ord("!"))), Rect(0, 1, 40, 12),
    )
    assert_true(d.windows.windows[0].editor.dirty)
    d.paint(canvas, _SCREEN)
    # Now dispatch the tab-bar route to focus B.
    _ = d.dispatch_action(WINDOW_FOCUS_PREFIX + String(1), _SCREEN)
    d.paint(canvas, _SCREEN)
    assert_false(d.windows.windows[0].editor.dirty)
    assert_equal(read_file(path_a), String("aaa!\n"))
    _ = external_call["unlink", Int32]((path_a + String("\0")).unsafe_ptr())
    _ = external_call["unlink", Int32]((path_b + String("\0")).unsafe_ptr())


def test_window_focus_change_skips_untitled_buffer() raises:
    """An untitled (no backing path) editor losing focus must not be
    saved — same skip rule as ``_autosave_all_dirty``."""
    var path_b = _temp_path(String("_wfc_unt_b.txt"))
    assert_true(write_file(path_b, String("bbb\n")))
    var d = Desktop()
    var canvas = Canvas(_SCREEN.width(), _SCREEN.height())
    # Window 0 is an untitled in-memory buffer (no file_path).
    d.windows.add(Window.editor_window(
        String("untitled"), Rect(0, 1, 40, 12), String("scratch\n"),
    ))
    d.windows.add(Window.from_file(String("b"), Rect(40, 1, 80, 12), path_b))
    d.paint(canvas, _SCREEN)
    d.windows.focus_by_index(0)
    _ = d.windows.windows[0].editor.handle_key(
        Event.key_event(KEY_END), Rect(0, 1, 40, 12),
    )
    _ = d.windows.windows[0].editor.handle_key(
        Event.key_event(UInt32(ord("!"))), Rect(0, 1, 40, 12),
    )
    assert_true(d.windows.windows[0].editor.dirty)
    d.paint(canvas, _SCREEN)
    d.windows.focus_by_index(1)
    # Should not raise (untitled has no path; tracker skips it).
    d.paint(canvas, _SCREEN)
    # Still dirty — untitled buffers are never auto-saved.
    assert_true(d.windows.windows[0].editor.dirty)
    _ = external_call["unlink", Int32]((path_b + String("\0")).unsafe_ptr())


def test_desktop_replace_all_button_runs_global_replace() raises:
    var d = Desktop()
    d.windows.add(Window.editor_window(
        String("buf"), Rect(0, 1, 40, 12), String("foo bar foo\n"),
    ))
    # Click "Replace..." — the prompt opens with two input strips.
    _ = d.dispatch_action(EDITOR_REPLACE, _SCREEN)
    assert_true(d.prompt.active)
    assert_true(d.prompt.has_second)
    # Fill both fields and fire the Replace All button. Replace All
    # closes the dialog after running.
    d.prompt.input.set_text(String("foo"))
    d.prompt.second_input.set_text(String("BAR"))
    d.prompt.submitted = True
    d.prompt.submit_kind = SUBMIT_REPLACE_ALL
    _ = d._on_prompt_submit()
    assert_false(d.prompt.active)
    assert_equal(d.windows.windows[0].editor.buffer.line(0), String("BAR bar BAR"))


def test_desktop_replace_button_replaces_current_match_then_advances() raises:
    var d = Desktop()
    d.windows.add(Window.editor_window(
        String("buf"), Rect(0, 1, 40, 12), String("foo bar foo\n"),
    ))
    # Select the first "foo" so it counts as the current match.
    d.windows.windows[0].editor.move_to(0, 0, False)
    d.windows.windows[0].editor.move_to(0, 3, True)
    _ = d.dispatch_action(EDITOR_REPLACE, _SCREEN)
    d.prompt.input.set_text(String("foo"))
    d.prompt.second_input.set_text(String("BAR"))
    d.prompt.submitted = True
    d.prompt.submit_kind = SUBMIT_REPLACE
    _ = d._on_prompt_submit()
    # First "foo" replaced; cursor advanced to the second "foo" (now
    # selected as the next match) and the dialog is still open so the
    # user can keep stepping.
    assert_true(d.prompt.active)
    assert_equal(d.windows.windows[0].editor.buffer.line(0), String("BAR bar foo"))
    assert_equal(d.windows.windows[0].editor.selection_text(), String("foo"))


def test_desktop_find_next_button_just_advances() raises:
    var d = Desktop()
    d.windows.add(Window.editor_window(
        String("buf"), Rect(0, 1, 40, 12), String("foo bar foo\n"),
    ))
    _ = d.dispatch_action(EDITOR_REPLACE, _SCREEN)
    d.prompt.input.set_text(String("foo"))
    d.prompt.second_input.set_text(String("BAR"))
    d.prompt.submitted = True
    d.prompt.submit_kind = SUBMIT_FIND_NEXT
    _ = d._on_prompt_submit()
    # Buffer untouched; cursor parked on the first "foo"; dialog open.
    assert_true(d.prompt.active)
    assert_equal(d.windows.windows[0].editor.buffer.line(0), String("foo bar foo"))
    assert_equal(d.windows.windows[0].editor.selection_text(), String("foo"))


def test_desktop_replace_seeds_find_from_selection() raises:
    var d = Desktop()
    d.windows.add(Window.editor_window(
        String("buf"), Rect(0, 1, 40, 12), String("foo bar baz\n"),
    ))
    # Select "bar" in the editor.
    d.windows.windows[0].editor.move_to(0, 4, False)
    d.windows.windows[0].editor.move_to(0, 7, True)
    _ = d.dispatch_action(EDITOR_REPLACE, _SCREEN)
    assert_true(d.prompt.active)
    assert_true(d.prompt.has_second)
    # Find prefilled with the selection, fully selected; cursor jumps
    # to the empty Replace field so the next keystroke types the
    # replacement rather than overwriting the seed.
    assert_equal(d.prompt.input.text, String("bar"))
    assert_true(d.prompt.input.has_selection())
    assert_equal(d.prompt.second_input.text, String(""))
    assert_true(d.prompt._focus.is_focused(1))


def test_desktop_find_seeds_from_editor_selection() raises:
    var d = Desktop()
    d.windows.add(Window.editor_window(
        String("buf"), Rect(0, 1, 40, 12), String("foo bar baz\n"),
    ))
    # Select "bar" in the editor.
    d.windows.windows[0].editor.move_to(0, 4, False)
    d.windows.windows[0].editor.move_to(0, 7, True)
    assert_equal(d.windows.windows[0].editor.selection_text(), String("bar"))
    _ = d.dispatch_action(EDITOR_FIND, _SCREEN)
    assert_true(d.prompt.active)
    # Prefilled with the selection, fully selected so a typed key replaces it.
    assert_equal(d.prompt.input.text, String("bar"))
    assert_true(d.prompt.input.has_selection())
    assert_equal(d.prompt.input.selection_text(), String("bar"))


def test_desktop_find_skips_seed_for_multiline_selection() raises:
    # A find term must be single-line; a multi-line editor selection
    # is not a meaningful default for the prompt.
    var d = Desktop()
    d.windows.add(Window.editor_window(
        String("buf"), Rect(0, 1, 40, 12), String("foo\nbar\nbaz\n"),
    ))
    d.windows.windows[0].editor.move_to(0, 0, False)
    d.windows.windows[0].editor.move_to(1, 3, True)
    _ = d.dispatch_action(EDITOR_FIND, _SCREEN)
    assert_true(d.prompt.active)
    assert_equal(d.prompt.input.text, String(""))


def test_desktop_find_no_selection_no_prefill() raises:
    var d = Desktop()
    d.windows.add(Window.editor_window(
        String("buf"), Rect(0, 1, 40, 12), String("foo bar baz\n"),
    ))
    _ = d.dispatch_action(EDITOR_FIND, _SCREEN)
    assert_true(d.prompt.active)
    assert_equal(d.prompt.input.text, String(""))


def test_desktop_open_file_uses_80_percent_size() raises:
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


def test_desktop_open_file_cascades_by_one() raises:
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


def test_desktop_open_file_focuses_existing() raises:
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


def test_desktop_open_file_inherits_maximize_state() raises:
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


def test_desktop_new_file_creates_untitled_editor_window() raises:
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


def test_desktop_dispatch_editor_new_opens_window() raises:
    """The framework intercepts ``EDITOR_NEW`` so apps wired to the action
    don't need any extra handling for File → New."""
    var d = Desktop()
    var maybe = d.dispatch_action(EDITOR_NEW, _SCREEN)
    assert_false(Bool(maybe))                    # framework consumed the action
    assert_equal(len(d.windows.windows), 1)
    assert_true(d.windows.windows[0].is_editor)
    assert_equal(d.windows.windows[0].editor.file_path, String(""))


def test_desktop_save_as_updates_window_title() raises:
    """After Save As succeeds, the window's title bar reflects the
    just-chosen filename — both when an Untitled buffer is being given
    a name for the first time and when an existing file is saved under
    a new name. Without this the tab strip + title border keep showing
    the pre-save name even though ``editor.file_path`` is already the
    new path."""
    var path_a = _temp_path(String("_saveas_untitled.txt"))
    var path_b = _temp_path(String("_saveas_renamed.txt"))
    var d = Desktop()
    d.new_file(_SCREEN)
    assert_equal(d.windows.windows[0].title, String("Untitled"))
    # Untitled → first save under ``path_a``. Seed and submit the
    # dialog directly — same control flow ``EDITOR_SAVE_AS`` triggers.
    d.save_as_dialog.open(path_a)
    _ = d.handle_event(Event.key_event(KEY_ENTER), _SCREEN)
    assert_equal(d.windows.windows[0].editor.file_path, path_a)
    assert_equal(d.windows.windows[0].title, basename(path_a))
    # Already-named buffer → save under a different name.
    d.save_as_dialog.open(path_b)
    _ = d.handle_event(Event.key_event(KEY_ENTER), _SCREEN)
    assert_equal(d.windows.windows[0].editor.file_path, path_b)
    assert_equal(d.windows.windows[0].title, basename(path_b))
    _ = external_call["unlink", Int32]((path_a + String("\0")).unsafe_ptr())
    _ = external_call["unlink", Int32]((path_b + String("\0")).unsafe_ptr())


def test_desktop_window_menu_lists_open_windows() raises:
    var d = Desktop()
    d.windows.add(Window(String("alpha"), Rect(0, 1, 20, 5), List[String]()))
    d.windows.add(Window(String("beta"),  Rect(0, 1, 20, 5), List[String]()))
    d._rebuild_window_menu()
    var menu = d.menu_bar.menus[d._window_menu_idx].copy()
    # 2 window items + separator + Maximize all + Restore all = 5 items.
    assert_equal(len(menu.items), 5)
    assert_equal(menu.items[0].label, String("alpha"))
    assert_equal(menu.items[0].action, String("window:focus:0"))
    assert_equal(menu.items[1].label, String("beta"))
    assert_equal(menu.items[1].action, String("window:focus:1"))
    assert_true(menu.items[2].is_separator)
    assert_equal(menu.items[3].label, String("Maximize all"))
    assert_equal(menu.items[4].label, String("Restore all"))


def test_desktop_window_menu_when_empty() raises:
    var d = Desktop()
    d._rebuild_window_menu()
    var menu = d.menu_bar.menus[d._window_menu_idx].copy()
    # No windows: skip the separator, just show the bulk actions.
    assert_equal(len(menu.items), 2)
    assert_equal(menu.items[0].label, String("Maximize all"))
    assert_equal(menu.items[1].label, String("Restore all"))


def test_desktop_window_focus_action_focuses_window() raises:
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


def test_desktop_maximize_all_and_restore_all() raises:
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


def test_desktop_project_find_requires_active_project() raises:
    var d = Desktop()
    # No project: dispatch is a no-op (the modal stays closed).
    _ = d.dispatch_action(PROJECT_FIND, _SCREEN)
    assert_false(d.project_find.active)
    # With a project: the fullscreen find UI opens.
    d.detect_project_from(String("examples/hello.mojo"))
    _ = d.dispatch_action(PROJECT_FIND, _SCREEN)
    assert_true(d.project_find.active)


def test_desktop_project_replace_opens_find_in_replace_mode() raises:
    var d = Desktop()
    # No project: dispatch is a no-op (the modal stays closed).
    _ = d.dispatch_action(PROJECT_REPLACE, _SCREEN)
    assert_false(d.project_find.active)
    # With a project: Cmd+Shift+R opens the same find surface, in replace
    # mode (a Replace strip + the Replace All action).
    d.detect_project_from(String("examples/hello.mojo"))
    _ = d.dispatch_action(PROJECT_REPLACE, _SCREEN)
    assert_true(d.project_find.active)
    assert_true(d.project_find.replace_mode)
    # Tab cycles query(0) -> replace(3) -> scope(1) -> glob(2) -> query(0).
    assert_equal(d.project_find.focus, 0)
    d.project_find._cycle_focus(False)
    assert_equal(d.project_find.focus, 3)
    d.project_find._cycle_focus(False)
    assert_equal(d.project_find.focus, 1)
    d.project_find._cycle_focus(False)
    assert_equal(d.project_find.focus, 2)
    d.project_find._cycle_focus(False)
    assert_equal(d.project_find.focus, 0)
    # Plain Find (Cmd+Shift+F) reuses the struct but skips replace mode and
    # keeps the replace strip out of the Tab cycle (query -> scope -> glob).
    _ = d.dispatch_action(PROJECT_FIND, _SCREEN)
    assert_false(d.project_find.replace_mode)
    d.project_find._cycle_focus(False)
    assert_equal(d.project_find.focus, 1)
    d.project_find._cycle_focus(False)
    assert_equal(d.project_find.focus, 2)
    d.project_find._cycle_focus(False)
    assert_equal(d.project_find.focus, 0)


def test_nav_history_records_initial_open() raises:
    """Opening a file seeds the nav stack with the file's starting
    cursor position so the very first Cmd+[ has somewhere to go."""
    var path = _temp_path(String("_nav_init.txt"))
    assert_true(write_file(path, String("alpha\nbeta\ngamma\n")))
    var d = Desktop()
    d.open_file(path, _SCREEN)
    d._track_nav_position()
    assert_equal(len(d._nav_stack), 1)
    assert_equal(d._nav_pos, 0)
    assert_equal(d._nav_stack[0].file_path, path)
    assert_equal(d._nav_stack[0].row, 0)
    assert_equal(d._nav_stack[0].col, 0)
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_nav_history_ignores_small_drift() raises:
    """Movement under the row / col threshold inside the same file
    does not push a new entry — the stack only captures real jumps."""
    var path = _temp_path(String("_nav_drift.txt"))
    var lines = String("")
    for _ in range(50):
        lines = lines + String("x\n")
    assert_true(write_file(path, lines))
    var d = Desktop()
    d.open_file(path, _SCREEN)
    d._track_nav_position()
    assert_equal(len(d._nav_stack), 1)
    # Move 5 rows down — under the 10-row threshold; no new entry.
    d.windows.windows[0].editor.move_to(5, 0, False, True)
    d._track_nav_position()
    assert_equal(len(d._nav_stack), 1)
    # Move another 4 rows — total 9 from the recorded baseline; still no.
    d.windows.windows[0].editor.move_to(9, 0, False, True)
    d._track_nav_position()
    assert_equal(len(d._nav_stack), 1)
    # Cross the threshold — a new entry lands at the current position.
    d.windows.windows[0].editor.move_to(20, 0, False, True)
    d._track_nav_position()
    assert_equal(len(d._nav_stack), 2)
    assert_equal(d._nav_stack[1].row, 20)
    assert_equal(d._nav_pos, 1)
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_nav_history_records_file_change() raises:
    """A focus change to a different file always records, regardless of
    where the cursor lands — cross-file motion is what the back button
    is most useful for."""
    var path_a = _temp_path(String("_nav_fa.txt"))
    var path_b = _temp_path(String("_nav_fb.txt"))
    assert_true(write_file(path_a, String("a1\na2\na3\n")))
    assert_true(write_file(path_b, String("b1\nb2\nb3\n")))
    var d = Desktop()
    d.open_file(path_a, _SCREEN)
    d._track_nav_position()
    d.open_file(path_b, _SCREEN)
    d._track_nav_position()
    assert_equal(len(d._nav_stack), 2)
    assert_equal(d._nav_stack[0].file_path, path_a)
    assert_equal(d._nav_stack[1].file_path, path_b)
    assert_equal(d._nav_pos, 1)
    _ = external_call["unlink", Int32]((path_a + String("\0")).unsafe_ptr())
    _ = external_call["unlink", Int32]((path_b + String("\0")).unsafe_ptr())


def test_nav_history_back_and_forward() raises:
    """Cmd+[ steps back through stored entries; Cmd+] returns forward.
    Both bottom-out as no-ops at the ends of the stack."""
    var path_a = _temp_path(String("_nav_ba.txt"))
    var path_b = _temp_path(String("_nav_bb.txt"))
    assert_true(write_file(path_a, String("a1\na2\na3\n")))
    assert_true(write_file(path_b, String("b1\nb2\nb3\n")))
    var d = Desktop()
    d.open_file(path_a, _SCREEN)
    d._track_nav_position()
    d.open_file(path_b, _SCREEN)
    d._track_nav_position()
    # Three entries: A@0, B@0 — back lands on A.
    d.navigate_back(_SCREEN)
    assert_equal(d._nav_pos, 0)
    assert_equal(d.windows.windows[d.windows.focused].editor.file_path, path_a)
    # Hitting back again at the bottom is a no-op.
    d.navigate_back(_SCREEN)
    assert_equal(d._nav_pos, 0)
    # Forward returns to B.
    d.navigate_forward(_SCREEN)
    assert_equal(d._nav_pos, 1)
    assert_equal(d.windows.windows[d.windows.focused].editor.file_path, path_b)
    # Forward at the top is a no-op.
    d.navigate_forward(_SCREEN)
    assert_equal(d._nav_pos, 1)
    _ = external_call["unlink", Int32]((path_a + String("\0")).unsafe_ptr())
    _ = external_call["unlink", Int32]((path_b + String("\0")).unsafe_ptr())


def test_nav_history_branching_truncates_forward() raises:
    """After going back, a fresh navigation drops the forward portion
    of the stack — same model as edit-after-undo wiping redo."""
    var path = _temp_path(String("_nav_branch.txt"))
    var lines = String("")
    for _ in range(80):
        lines = lines + String("x\n")
    assert_true(write_file(path, lines))
    var d = Desktop()
    d.open_file(path, _SCREEN)
    d._track_nav_position()
    d.windows.windows[0].editor.move_to(30, 0, False, True)
    d._track_nav_position()
    d.windows.windows[0].editor.move_to(60, 0, False, True)
    d._track_nav_position()
    # Stack: 0, 30, 60 — go back to 30.
    assert_equal(len(d._nav_stack), 3)
    d.navigate_back(_SCREEN)
    assert_equal(d._nav_pos, 1)
    # New jump to 50: forward portion (entry at 60) gets dropped.
    d.windows.windows[0].editor.move_to(50, 0, False, True)
    d._track_nav_position()
    assert_equal(len(d._nav_stack), 3)
    assert_equal(d._nav_pos, 2)
    assert_equal(d._nav_stack[2].row, 50)
    # Forward is now a no-op since we're back at the top.
    d.navigate_forward(_SCREEN)
    assert_equal(d._nav_pos, 2)
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_nav_history_back_via_dispatch_action() raises:
    """The Cmd+[ binding routes through ``dispatch_action`` like any
    other framework action — the same call should drive the back step."""
    var path_a = _temp_path(String("_nav_da.txt"))
    var path_b = _temp_path(String("_nav_db.txt"))
    assert_true(write_file(path_a, String("a\n")))
    assert_true(write_file(path_b, String("b\n")))
    var d = Desktop()
    d.open_file(path_a, _SCREEN)
    d._track_nav_position()
    d.open_file(path_b, _SCREEN)
    d._track_nav_position()
    var maybe = d.dispatch_action(EDITOR_NAV_BACK, _SCREEN)
    assert_false(Bool(maybe))   # framework consumed the action
    assert_equal(d.windows.windows[d.windows.focused].editor.file_path, path_a)
    var maybe2 = d.dispatch_action(EDITOR_NAV_FORWARD, _SCREEN)
    assert_false(Bool(maybe2))
    assert_equal(d.windows.windows[d.windows.focused].editor.file_path, path_b)
    _ = external_call["unlink", Int32]((path_a + String("\0")).unsafe_ptr())
    _ = external_call["unlink", Int32]((path_b + String("\0")).unsafe_ptr())


def test_nav_history_cmd_bracket_keys_fire_dispatch() raises:
    """The Cmd+[ event arrives as ``(0x5B, MOD_META)`` — brackets aren't
    letters so the parser doesn't collapse them to ESC, and Cmd is kept
    distinct from Ctrl. The hotkey table must turn those into nav
    actions."""
    var path_a = _temp_path(String("_nav_ka.txt"))
    var path_b = _temp_path(String("_nav_kb.txt"))
    assert_true(write_file(path_a, String("a\n")))
    assert_true(write_file(path_b, String("b\n")))
    var d = Desktop()
    d.open_file(path_a, _SCREEN)
    # ``handle_event`` runs the per-frame nav tracking via ``paint``
    # in the real loop; in this test we drive the recording manually
    # so the stack reflects the explicit opens.
    d._track_nav_position()
    d.open_file(path_b, _SCREEN)
    d._track_nav_position()
    var back_ev = Event.key_event(UInt32(ord("[")), MOD_META)
    _ = d.handle_event(back_ev, _SCREEN)
    assert_equal(d.windows.windows[d.windows.focused].editor.file_path, path_a)
    var fwd_ev = Event.key_event(UInt32(ord("]")), MOD_META)
    _ = d.handle_event(fwd_ev, _SCREEN)
    assert_equal(d.windows.windows[d.windows.focused].editor.file_path, path_b)
    _ = external_call["unlink", Int32]((path_a + String("\0")).unsafe_ptr())
    _ = external_call["unlink", Int32]((path_b + String("\0")).unsafe_ptr())


def test_window_manager_close_focused() raises:
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


def test_window_manager_rotate_focus_cycles_in_stable_order() raises:
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


def test_window_manager_rotate_focus_noop_when_fewer_than_two_windows() raises:
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


def test_window_menu_items_show_ctrl_n_shortcut() raises:
    """The Window menu items (rebuilt every paint) carry the matching
    Ctrl+N shortcut for the first nine windows."""
    var d = Desktop()
    d.windows.add(Window(String("a"), Rect(0, 1, 20, 5), List[String]()))
    d.windows.add(Window(String("b"), Rect(0, 1, 20, 5), List[String]()))
    d._rebuild_window_menu()
    d._refresh_shortcuts()
    var menu = d.menu_bar.menus[d._window_menu_idx].copy()
    assert_equal(menu.items[0].label, String("a"))
    assert_equal(menu.items[0].shortcut, String("Ctrl+1"))
    assert_equal(menu.items[1].label, String("b"))
    assert_equal(menu.items[1].shortcut, String("Ctrl+2"))


def test_project_settings_on_save_seeds_state() raises:
    """Project Settings seeds the On-save section: the union(library,
    project_actions) display list parks selection on row 0, and an enabled
    project copy reads back as ticked."""
    var lib = List[OnSaveAction]()
    lib.append(OnSaveAction(
        String("python"), String("/usr/bin/black"),
        List[String](), String(""),
    ))
    var pa = List[OnSaveAction]()
    pa.append(OnSaveAction(
        String("python"), String("/usr/bin/black"),
        List[String](), String(""),
    ))
    var ps = _ps_open(lib^, pa^)
    assert_true(ps.active)
    assert_equal(ps.section, 0)
    assert_equal(len(ps._os_union()), 1)
    assert_equal(ps.selected_os, 0)
    assert_true(ps._os_is_enabled(ps._os_union()[0]))


def test_desktop_set_font_maps_default_label_to_empty() raises:
    """``set_font`` stores the built-in default as the empty string (the
    config file stays label-free) and bumps ``font_version`` on every
    change so the Swift host refetches."""
    var d = Desktop()
    assert_equal(d.font_label(), String("IBM VGA 8x16 (built-in)"))
    var v0 = d.font_version
    d.set_font(String("Menlo"))
    assert_equal(d.config.font, String("Menlo"))
    assert_equal(d.font_label(), String("Menlo"))
    assert_equal(d.font_version, v0 + 1)
    d.set_font(String("IBM VGA 8x16 (built-in)"))
    assert_equal(d.config.font, String(""))
    assert_equal(d.font_version, v0 + 2)


def test_desktop_set_font_size_clamps_and_bumps_version() raises:
    """``set_font_size`` clamps explicit sizes into the sane range, keeps
    0 as "the font's default", and bumps ``font_version`` only on real
    changes so the Swift host refetches exactly when needed."""
    var d = Desktop()
    assert_equal(d.config.font_size, 0)
    var v0 = d.font_version
    d.set_font_size(20)
    assert_equal(d.config.font_size, 20)
    assert_equal(d.font_version, v0 + 1)
    # No-op on the same value.
    d.set_font_size(20)
    assert_equal(d.font_version, v0 + 1)
    # Clamped at both ends.
    d.set_font_size(1)
    assert_equal(d.config.font_size, MIN_FONT_SIZE)
    d.set_font_size(1000)
    assert_equal(d.config.font_size, MAX_FONT_SIZE)
    # 0 restores "default" untouched by the clamp.
    d.set_font_size(0)
    assert_equal(d.config.font_size, 0)


def test_desktop_routes_alt_tap_to_focused_editor() raises:
    # The native frontend reports bare Alt transitions through
    # tk_desktop_mod_key → Desktop.handle_event(EVENT_MOD_KEY) → the
    # focused editor's handle_mod_key. This guards that routing so the
    # native plumbing can't silently stop reaching the editor.
    from turbokod.events import MOD_KEY_ALT
    var path = _temp_path(String("_dalttap.txt"))
    assert_true(write_file(path, String("alpha\nbeta\ngamma\n")))
    var d = Desktop()
    d.windows.add(Window.from_file(String("dalttap.txt"), Rect(0, 1, 40, 12), path))
    # Multi-line selection in the focused editor.
    d.windows.windows[0].editor.move_to(0, 1, False)
    d.windows.windows[0].editor.move_to(2, 1, True)
    assert_true(d.windows.windows[0].editor.has_selection())
    # Alt-tap (press + release) routed through the Desktop event entry.
    _ = d.handle_event(Event.mod_key_event(MOD_KEY_ALT, True), _SCREEN)
    _ = d.handle_event(Event.mod_key_event(MOD_KEY_ALT, False), _SCREEN)
    assert_equal(d.windows.windows[0].editor.caret_count(), 3)
    assert_false(d.windows.windows[0].editor.has_selection())
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_window_manager_fit_into_keeps_maximized_pinned() raises:
    var wm = WindowManager()
    var w = Window(String("M"), Rect(0, 1, 100, 25), List[String]())
    w.is_maximized = True
    wm.add(w^)
    var smaller = Rect(0, 1, 60, 20)
    wm.fit_into(smaller)
    assert_true(wm.windows[0].rect == smaller)


def test_window_manager_fit_into_scales_side_by_side_on_grow() raises:
    """Two windows tiled side by side covering the workspace must still
    cover it after the terminal grows, with their shared edge staying
    seamless and the width ratio between them preserved."""
    var wm = WindowManager()
    # Workspace is 100x24 (y in [1, 25)); two windows split it 40/60.
    wm.add(Window(String("L"), Rect(0, 1, 40, 25), List[String]()))
    wm.add(Window(String("R"), Rect(40, 1, 100, 25), List[String]()))
    # First call baselines at the original workspace without scaling.
    wm.fit_into(Rect(0, 1, 100, 25))
    # Grow the terminal: width 100 → 200, height stays at 24.
    wm.fit_into(Rect(0, 1, 200, 25))
    # Left edge of L pinned to workspace left edge.
    assert_equal(wm.windows[0].rect.a.x, 0)
    # Right edge of R pinned to workspace right edge — full coverage.
    assert_equal(wm.windows[1].rect.b.x, 200)
    # The seam is seamless: L.b.x == R.a.x.
    assert_equal(wm.windows[0].rect.b.x, wm.windows[1].rect.a.x)
    # Width ratio preserved at 40:60 → 80:120 in a 200-wide workspace.
    assert_equal(wm.windows[0].rect.width(), 80)
    assert_equal(wm.windows[1].rect.width(), 120)
    # y-axis untouched because workspace height didn't change.
    assert_equal(wm.windows[0].rect.a.y, 1)
    assert_equal(wm.windows[0].rect.b.y, 25)


def test_window_manager_fit_into_scales_side_by_side_on_shrink() raises:
    """Same as the grow test, but the terminal shrinks. The shared seam
    and the full-coverage invariant must still hold."""
    var wm = WindowManager()
    wm.add(Window(String("L"), Rect(0, 1, 40, 25), List[String]()))
    wm.add(Window(String("R"), Rect(40, 1, 100, 25), List[String]()))
    wm.fit_into(Rect(0, 1, 100, 25))
    # Shrink: width 100 → 50.
    wm.fit_into(Rect(0, 1, 50, 25))
    assert_equal(wm.windows[0].rect.a.x, 0)
    assert_equal(wm.windows[1].rect.b.x, 50)
    assert_equal(wm.windows[0].rect.b.x, wm.windows[1].rect.a.x)
    # 40:60 of 50 → 20:30.
    assert_equal(wm.windows[0].rect.width(), 20)
    assert_equal(wm.windows[1].rect.width(), 30)


def test_window_manager_fit_into_scales_stacked_on_resize() raises:
    """Same proportional behavior on the y-axis: two windows stacked
    vertically and covering the workspace stay covering it."""
    var wm = WindowManager()
    # Workspace 80x20 (y in [1, 21)); split top 8 rows, bottom 12 rows.
    wm.add(Window(String("T"), Rect(0, 1, 80, 9), List[String]()))
    wm.add(Window(String("B"), Rect(0, 9, 80, 21), List[String]()))
    wm.fit_into(Rect(0, 1, 80, 21))
    # Grow height: 20 → 40 rows (y in [1, 41)).
    wm.fit_into(Rect(0, 1, 80, 41))
    assert_equal(wm.windows[0].rect.a.y, 1)
    assert_equal(wm.windows[1].rect.b.y, 41)
    assert_equal(wm.windows[0].rect.b.y, wm.windows[1].rect.a.y)
    # 8:12 of 40 → 16:24.
    assert_equal(wm.windows[0].rect.height(), 16)
    assert_equal(wm.windows[1].rect.height(), 24)


def test_window_manager_fit_into_proportional_2x2_grid() raises:
    """A 2x2 tile fully covering the workspace stays fully covering it
    after a resize; all four interior seams stay aligned."""
    var wm = WindowManager()
    # Workspace 100x20 (y in [1, 21)); split 50/50 horizontally and
    # 8/12 vertically.
    wm.add(Window(String("TL"), Rect(0, 1, 50, 9), List[String]()))
    wm.add(Window(String("TR"), Rect(50, 1, 100, 9), List[String]()))
    wm.add(Window(String("BL"), Rect(0, 9, 50, 21), List[String]()))
    wm.add(Window(String("BR"), Rect(50, 9, 100, 21), List[String]()))
    wm.fit_into(Rect(0, 1, 100, 21))
    # Grow both axes: 100x20 → 200x40 (y in [1, 41)).
    wm.fit_into(Rect(0, 1, 200, 41))
    # Outer edges cover the new workspace exactly.
    assert_equal(wm.windows[0].rect.a.x, 0)
    assert_equal(wm.windows[0].rect.a.y, 1)
    assert_equal(wm.windows[3].rect.b.x, 200)
    assert_equal(wm.windows[3].rect.b.y, 41)
    # Horizontal seam: TL.b.x == TR.a.x == BL.b.x == BR.a.x.
    assert_equal(wm.windows[0].rect.b.x, wm.windows[1].rect.a.x)
    assert_equal(wm.windows[2].rect.b.x, wm.windows[3].rect.a.x)
    assert_equal(wm.windows[0].rect.b.x, wm.windows[2].rect.b.x)
    # Vertical seam: TL.b.y == BL.a.y == TR.b.y == BR.a.y.
    assert_equal(wm.windows[0].rect.b.y, wm.windows[2].rect.a.y)
    assert_equal(wm.windows[1].rect.b.y, wm.windows[3].rect.a.y)
    assert_equal(wm.windows[0].rect.b.y, wm.windows[1].rect.b.y)


def test_window_manager_fit_into_baseline_no_scale_on_first_call() raises:
    """The first ``fit_into`` after construction has no baseline to scale
    against, so it falls back to clip-and-move — preserves the move-only
    behavior the existing test suite (and session restore startup) rely
    on."""
    var wm = WindowManager()
    # Window past the new right edge — should slide left, not scale.
    wm.add(Window(String("A"), Rect(70, 5, 90, 15), List[String]()))
    wm.fit_into(Rect(0, 1, 80, 25))
    assert_equal(wm.windows[0].rect.width(), 20)   # width preserved
    assert_equal(wm.windows[0].rect.b.x, 80)       # slid against right edge


def test_window_manager_note_workspace_suppresses_next_scale() raises:
    """``note_workspace`` rebases the snapshot without touching rects,
    so a workspace change reported via ``note_workspace`` followed by a
    matching ``fit_into`` doesn't trigger proportional scaling — this is
    what session restore relies on after manually assigning rects."""
    var wm = WindowManager()
    wm.add(Window(String("A"), Rect(10, 5, 30, 15), List[String]()))
    # First fit baselines at workspace 80x24.
    wm.fit_into(Rect(0, 1, 80, 25))
    var before = wm.windows[0].rect
    # Restore handler "reapplied" rects to fit a larger workspace, then
    # told the manager about the new workspace.
    wm.note_workspace(Rect(0, 1, 160, 50))
    # Next paint sees the same workspace as the baseline → no scaling.
    wm.fit_into(Rect(0, 1, 160, 50))
    assert_true(wm.windows[0].rect == before)


def test_window_manager_fit_into_round_trip_is_lossless() raises:
    """Two windows split 50/50 covering the workspace must come back to
    exactly 50/50 after a shrink-then-grow round trip. The naive
    "scale the current rect every time" approach accumulates integer
    rounding error and ends up with asymmetric widths; this test pins
    the per-window-baseline path that avoids that drift."""
    var wm = WindowManager()
    # Workspace 101 wide so the half-point doesn't divide evenly —
    # rounding-error accumulation is most visible at odd widths.
    wm.add(Window(String("L"), Rect(0, 1, 50, 25), List[String]()))
    wm.add(Window(String("R"), Rect(50, 1, 101, 25), List[String]()))
    wm.fit_into(Rect(0, 1, 101, 25))
    # Shrink to about half the width.
    wm.fit_into(Rect(0, 1, 50, 25))
    # Grow back to the original.
    wm.fit_into(Rect(0, 1, 101, 25))
    assert_equal(wm.windows[0].rect.a.x, 0)
    assert_equal(wm.windows[0].rect.b.x, 50)
    assert_equal(wm.windows[1].rect.a.x, 50)
    assert_equal(wm.windows[1].rect.b.x, 101)


def test_window_manager_fit_into_user_drag_rebases_baseline() raises:
    """A user edge-drag captured between paints must rebase the
    baseline. Without that, resizing the terminal after the drag would
    scale from the stale pre-drag baseline, undoing the drag."""
    var wm = WindowManager()
    wm.add(Window(String("L"), Rect(0, 1, 50, 25), List[String]()))
    wm.add(Window(String("R"), Rect(50, 1, 100, 25), List[String]()))
    wm.fit_into(Rect(0, 1, 100, 25))
    # Simulate a user drag of L's right edge: rect mutates between
    # paints with the workspace unchanged.
    wm.windows[0].rect = Rect(0, 1, 60, 25)
    # Next paint with the same workspace — manager observes the user
    # change and rebases the baseline.
    wm.fit_into(Rect(0, 1, 100, 25))
    # Now resize the terminal: scaling must come from the rebased
    # baseline (60 wide of 100) not from the original (50 wide of 100).
    wm.fit_into(Rect(0, 1, 200, 25))
    # 60 of 100 → 120 of 200 for the left edge of R / right edge of L.
    assert_equal(wm.windows[0].rect.b.x, 120)


def test_window_manager_fit_into_scales_restore_rect_for_maximized() raises:
    """A maximized window's ``_restore_rect`` is scaled along with the
    workspace so un-maximizing after a terminal resize lands at the
    proportionally-correct place rather than reverting to the
    pre-resize coordinates."""
    var wm = WindowManager()
    var w = Window(String("M"), Rect(0, 1, 100, 25), List[String]())
    w._restore_rect = Rect(10, 5, 50, 15)
    w.is_maximized = True
    wm.add(w^)
    wm.fit_into(Rect(0, 1, 100, 25))
    # Double both axes: width 100→200, height 24→48.
    wm.fit_into(Rect(0, 1, 200, 49))
    # Rect pinned to the new workspace.
    assert_true(wm.windows[0].rect == Rect(0, 1, 200, 49))
    # _restore_rect scaled proportionally: x doubled, y doubled (from
    # the y origin at 1): a.y = 1 + (5-1)*48/24 = 1 + 8 = 9; b.y = 1 +
    # (15-1)*48/24 = 1 + 28 = 29.
    assert_equal(wm.windows[0]._restore_rect.a.x, 20)
    assert_equal(wm.windows[0]._restore_rect.b.x, 100)
    assert_equal(wm.windows[0]._restore_rect.a.y, 9)
    assert_equal(wm.windows[0]._restore_rect.b.y, 29)


def test_window_manager_title_hover_arms_for_editor_with_path() raises:
    """Bare hover over the title bar of a file-backed editor window
    arms the full-path reveal; hovering elsewhere clears it. A
    left-click anywhere also drops the tracker so the title reverts
    to its short name."""
    var wm = WindowManager()
    var w = Window.editor_window(
        String("hello.mojo"), Rect(2, 2, 30, 12), String("body"),
    )
    w.editor.file_path = String("/tmp/proj/hello.mojo")
    wm.add(w^)
    # Hover on the title row (y == rect.a.y == 2), at a column that
    # isn't the close button or the maximize/number indicator.
    var hover = Event.mouse_event(
        Point(15, 2), MOUSE_BUTTON_NONE, pressed=True, motion=True,
    )
    _ = wm.handle_mouse(hover, Rect(0, 1, 80, 25))
    assert_equal(wm._title_hover_idx, 0)
    # Hover off the title row — body cell at y=5 — clears it.
    var off = Event.mouse_event(
        Point(15, 5), MOUSE_BUTTON_NONE, pressed=True, motion=True,
    )
    _ = wm.handle_mouse(off, Rect(0, 1, 80, 25))
    assert_equal(wm._title_hover_idx, -1)
    # Re-arm, then a left-click clears it.
    _ = wm.handle_mouse(hover, Rect(0, 1, 80, 25))
    assert_equal(wm._title_hover_idx, 0)
    var click = Event.mouse_event(
        Point(15, 2), MOUSE_BUTTON_LEFT, pressed=True, motion=False,
    )
    _ = wm.handle_mouse(click, Rect(0, 1, 80, 25))
    assert_equal(wm._title_hover_idx, -1)


def test_window_manager_title_hover_skips_unbacked_buffers() raises:
    """Untitled / file-less editor windows must not arm the reveal —
    a centered ``Untitled`` title with no path has nothing useful to
    show."""
    var wm = WindowManager()
    var w = Window.editor_window(
        String("Untitled"), Rect(2, 2, 30, 12), String(""),
    )
    # editor.file_path is empty by default for editor_window().
    wm.add(w^)
    var hover = Event.mouse_event(
        Point(15, 2), MOUSE_BUTTON_NONE, pressed=True, motion=True,
    )
    _ = wm.handle_mouse(hover, Rect(0, 1, 80, 25))
    assert_equal(wm._title_hover_idx, -1)


def test_window_manager_title_hover_reveals_full_path_in_titlebar() raises:
    """While the title label is hovered, ``paint`` swaps the short
    filename for the editor's full path; un-hovered it shows the short
    name only."""
    var wm = WindowManager()
    # Wide enough that the full path fits between the close button and
    # the right-corner indicator once centered.
    var w = Window.editor_window(
        String("hello.mojo"), Rect(2, 2, 52, 12), String("body"),
    )
    w.editor.file_path = String("/tmp/proj/hello.mojo")
    wm.add(w^)
    # No hover: short name on the title row, full path absent.
    var c = Canvas(60, 14)
    wm.paint(c)
    var row = _title_row_text(c, 2, 2, 52)
    assert_true(row.find(String("hello.mojo")) != -1)
    assert_true(row.find(String("/tmp/proj/hello.mojo")) == -1)
    # Hover the title label, repaint: the full path is now revealed.
    var hover = Event.mouse_event(
        Point(25, 2), MOUSE_BUTTON_NONE, pressed=True, motion=True,
    )
    _ = wm.handle_mouse(hover, Rect(0, 1, 80, 25))
    assert_equal(wm._title_hover_idx, 0)
    var c2 = Canvas(60, 14)
    wm.paint(c2)
    var row2 = _title_row_text(c2, 2, 2, 52)
    assert_true(row2.find(String("/tmp/proj/hello.mojo")) != -1)


def test_window_v_scrollbar_hit_arrows_and_thumb() raises:
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


def test_window_v_scroll_by_clamps() raises:
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


def test_window_v_scrollbar_track_click_centers_target() raises:
    """A click in the page area of the v-scrollbar jumps to the
    proportional buffer row and centers it in the view, instead of
    scrolling by one page. With 51 buffer rows in an 8-row view and a
    6-cell track, a click at track row 3 corresponds to row 25 in the
    file; centering puts ``scroll_y`` at ``25 - 8/2 = 21``."""
    var lines = String("")
    for i in range(50):
        lines = lines + String("L") + String(i) + String("\n")
    var w = Window.editor_window(String("ed"), Rect(0, 0, 30, 10), lines)
    # Click below the thumb (part 4): track row 3 of 6.
    var hit = w.v_scrollbar_hit(Point(29, 5))
    assert_equal(hit[0], 4)
    assert_equal(hit[1], 3)
    w.v_scroll_to_track_pos(hit[1])
    assert_equal(w.editor.scroll_y, 21)
    # Click at the very top of the track jumps to row 0 — already at the
    # file's start, so centering can't go negative; ``scroll_y`` clamps
    # to 0.
    w.editor.scroll_y = 30
    w.v_scroll_to_track_pos(0)
    assert_equal(w.editor.scroll_y, 0)
    # Click at the bottom of the track centers a row near the end of the
    # file. Track row 5 of 6 maps to row ``5*51/6 = 42``; centered that
    # leaves ``scroll_y = 42 - 4 = 38``, which is below ``max_scroll``
    # (43) — so the user lands with line 42 in the middle of the view
    # rather than glued to the bottom of the file.
    w.v_scroll_to_track_pos(5)
    assert_equal(w.editor.scroll_y, 38)


def test_window_v_scroll_drag_to_end() raises:
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


def test_desktop_esc_dismisses_completion_popup() raises:
    """ESC routed through the Desktop must close the focused editor's
    completion popup before any other ESC-bound action (menu close /
    multi-caret clear / esc-prefix arm). Without this the popup would
    persist until the user typed past the anchor."""
    var d = Desktop()
    d.windows.add(Window.editor_window(
        String("buf"), Rect(0, 1, 40, 12), String("foo bar\n"),
    ))
    d.windows.windows[0].editor.move_to(0, 3, False)
    d.windows.windows[0].editor.set_completions(
        _popup_items_one(), 0, 0,
    )
    assert_true(d.windows.windows[0].editor.completion_popup_visible)
    _ = d.handle_event(Event.key_event(KEY_ESC), _SCREEN)
    assert_false(d.windows.windows[0].editor.completion_popup_visible)
    # ESC must not have also armed the menu-mnemonic prefix when it was
    # consumed by the popup-close path.
    assert_false(d._esc_armed)


def test_desktop_left_click_outside_popup_dismisses_it() raises:
    """A left-click anywhere outside the popup's screen rect dismisses
    it. The click still proceeds to its normal target — the popup is
    just a transient overlay."""
    var d = Desktop()
    d.windows.add(Window.editor_window(
        String("buf"), Rect(0, 1, 40, 12), String("foo bar\n"),
    ))
    d.windows.windows[0].editor.move_to(0, 3, False)
    d.windows.windows[0].editor.set_completions(
        _popup_items_one(), 0, 0,
    )
    assert_true(d.windows.windows[0].editor.completion_popup_visible)
    # Click somewhere clearly outside the popup (far-right column of
    # the editor's text area; popup is anchored at column 0).
    _ = d.handle_event(
        Event.mouse_event(
            Point(35, 10), MOUSE_BUTTON_LEFT, True, False,
        ),
        _SCREEN,
    )
    assert_false(d.windows.windows[0].editor.completion_popup_visible)


def test_desktop_left_click_inside_popup_keeps_it_open() raises:
    """A left-click that lands *inside* the popup rect must not dismiss
    it — that lane is reserved for future item-click acceptance."""
    var d = Desktop()
    d.windows.add(Window.editor_window(
        String("buf"), Rect(0, 1, 40, 12), String("foo bar\n"),
    ))
    d.windows.windows[0].editor.move_to(0, 3, False)
    d.windows.windows[0].editor.set_completions(
        _popup_items_one(), 0, 0,
    )
    var interior = d.windows.windows[0].interior()
    var maybe_rect = d.windows.windows[0] \
        .editor.completion_popup_screen_rect(interior)
    assert_true(Bool(maybe_rect))
    var pr = maybe_rect.value()
    # Click the popup's top-left interior cell.
    _ = d.handle_event(
        Event.mouse_event(
            Point(pr.a.x, pr.a.y), MOUSE_BUTTON_LEFT, True, False,
        ),
        _SCREEN,
    )
    assert_true(d.windows.windows[0].editor.completion_popup_visible)


def test_project_targets_load_parses_fields() raises:
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


def test_project_targets_save_roundtrips_active() raises:
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


def test_project_targets_resolve_paths() raises:
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


def test_project_on_save_round_trip() raises:
    """``write_project_on_save`` then ``load_project_on_save`` round-trips
    the enabled set through ``<project>/.turbokod/on_save.json``."""
    var root = _temp_path(String("_psroot"))
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var args = List[String]()
    args.append(String("--quiet"))
    var actions = List[OnSaveAction]()
    actions.append(OnSaveAction(
        String("python"), String("/usr/bin/black"), args^, String(""),
    ))
    assert_true(write_project_on_save(root, actions))
    var loaded = load_project_on_save(root)
    assert_equal(len(loaded), 1)
    assert_equal(loaded[0].language_id, String("python"))
    assert_equal(loaded[0].program, String("/usr/bin/black"))
    assert_equal(len(loaded[0].args), 1)
    assert_equal(loaded[0].args[0], String("--quiet"))


def test_project_settings_on_save_enable_disable() raises:
    """Ticking a library row copies it into ``project_actions`` (enable);
    unticking removes the matching copy (disable). Both raise dirty."""
    var lib = List[OnSaveAction]()
    lib.append(OnSaveAction(
        String("python"), String("/usr/bin/black"),
        List[String](), String(""),
    ))
    var ps = _ps_open(lib^, List[OnSaveAction]())
    assert_equal(len(ps.project_actions), 0)
    ps._os_toggle(0)
    assert_equal(len(ps.project_actions), 1)
    assert_true(ps._os_is_enabled(ps._os_union()[0]))
    assert_true(ps.on_save_dirty)
    ps._os_toggle(0)
    assert_equal(len(ps.project_actions), 0)


def test_project_settings_grammars_add_remove() raises:
    """Project Settings Grammars section: add a mapping, type an extension,
    then remove it — each step raises ``grammars_dirty``."""
    var ps = ProjectSettings()
    ps.open(
        String("/tmp/turbokod_ps_unit"), ProjectTargets(),
        List[GrammarOverride](), List[OnSaveAction](), List[OnSaveAction](),
    )
    ps.section = 2  # Grammars
    ps.focus = UInt8(17)  # _FOCUS_GR_ADD
    _ = ps.handle_key(_key(KEY_ENTER))
    assert_equal(len(ps.grammars), 1)
    assert_true(ps.grammars_dirty)
    ps.focus = UInt8(15)  # _FOCUS_GR_EXT
    _ = ps.handle_key(_key(UInt32(ord("h"))))
    _ = ps.handle_key(_key(UInt32(ord("t"))))
    _ = ps.handle_key(_key(UInt32(ord("m"))))
    _ = ps.handle_key(_key(UInt32(ord("l"))))
    assert_equal(ps.grammars[0].ext, String("html"))
    ps.focus = UInt8(18)  # _FOCUS_GR_REMOVE
    _ = ps.handle_key(_key(KEY_ENTER))
    assert_equal(len(ps.grammars), 0)


def test_project_settings_paint_smoke() raises:
    """Paint each Project Settings section (in-grid + detached) onto a
    canvas — exercises the layout / sub-painter math that the logic-only
    tests skip. A crash or out-of-bounds write fails the test."""
    var lib = List[OnSaveAction]()
    lib.append(OnSaveAction(
        String("python"), String("/usr/bin/black"),
        List[String](), String(""),
    ))
    var src = ProjectTargets()
    var t1 = RunTarget()
    t1.name = String("tests")
    t1.program = String("pytest")
    src.targets.append(t1^)
    src.active = 0
    var grammars = List[GrammarOverride]()
    grammars.append(GrammarOverride(String("html"), String("django-html")))
    var ps = ProjectSettings()
    ps.open(
        String("/tmp/turbokod_ps_unit"), src^, grammars^, lib^,
        List[OnSaveAction](),
    )
    var screen = Rect(0, 0, 100, 40)
    for sec in range(3):
        ps.section = sec
        var c = Canvas(100, 40)
        c.clear(default_attr())
        ps.paint(c, screen)
    # Detached fills the whole surface (native window path).
    ps.detached = True
    for sec in range(3):
        ps.section = sec
        var c2 = Canvas(100, 40)
        c2.clear(default_attr())
        ps.paint(c2, screen)


def test_session_round_trip() raises:
    """A persisted session should decode to the same fields it was
    encoded from. Covers the full ``encode_session`` → ``parse_json``
    → ``load_session`` path against a temp project root so the test
    doesn't touch the repo's own per-user session file."""
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
    w0.last_focus_ms = 1_700_000_000_123
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
    assert_equal(loaded.windows[0].last_focus_ms, 1_700_000_000_123)
    # A window that never carried a timestamp loads as 0 (epoch).
    assert_equal(loaded.windows[1].last_focus_ms, 0)
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


def test_session_per_user_path() raises:
    """The on-disk session file lives under ``per_user/<USER>/`` next
    to breakpoints.json / view_states.json — keeps each developer's
    open-window set separate, so an accidental ``git add .turbokod``
    doesn't restore a teammate's layout on this checkout."""
    var root = String("/tmp/turbokod_session_per_user_test")
    _ = external_call["system", Int32](
        (String("rm -rf '") + root + String("'\0")).unsafe_ptr(),
    )
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var user_env = String("USER=carol_test\0")
    _ = external_call["putenv", Int32](user_env.unsafe_ptr())
    var s = Session()
    var w = SessionWindow()
    w.path = String("main.py")
    w.rect_a_x = 0
    w.rect_a_y = 1
    w.rect_b_x = 40
    w.rect_b_y = 20
    w.restore_a_x = 0
    w.restore_a_y = 1
    w.restore_b_x = 40
    w.restore_b_y = 20
    s.windows.append(w^)
    s.focused = 0
    assert_true(save_session(root, s))
    var expected = root + String(
        "/.turbokod/per_user/carol_test/session.json"
    )
    assert_true(stat_file(expected).ok)
    _ = external_call["system", Int32](
        (String("rm -rf '") + root + String("'\0")).unsafe_ptr(),
    )


def test_session_load_missing_returns_empty() raises:
    """A project root with no persisted session file should yield an
    empty session — that's the signal ``_restore_session`` uses to
    skip the restore path entirely."""
    var s = load_session(String("/tmp/turbokod_session_does_not_exist_abcxyz"))
    assert_equal(len(s.windows), 0)
    assert_equal(len(s.z_order), 0)
    assert_equal(s.focused, -1)


def test_view_state_store_round_trip() raises:
    """Persisted per-file view states decode back to the same fields.
    Inside-project paths are stored project-relative so the file
    survives moving the project; absolute paths pass through. The
    store keys by absolute path and load reattaches the project root
    to project-relative entries on the way back."""
    var root = String("/tmp/turbokod_vs_test_round_trip")
    _ = external_call["system", Int32](
        (String("rm -rf '") + root + String("'\0")).unsafe_ptr(),
    )
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var views = List[StoredViewState]()
    views.append(StoredViewState(
        root + String("/src/foo.mojo"), 42, 4, 0, 30,
    ))
    views.append(StoredViewState(
        String("/etc/hosts"), 0, 0, 0, 0,
    ))
    assert_true(save_view_states(root, views))
    var loaded = load_view_states(root)
    assert_equal(len(loaded), 2)
    assert_equal(loaded[0].path, root + String("/src/foo.mojo"))
    assert_equal(loaded[0].cursor_row, 42)
    assert_equal(loaded[0].cursor_col, 4)
    assert_equal(loaded[0].scroll_x, 0)
    assert_equal(loaded[0].scroll_y, 30)
    assert_equal(loaded[1].path, String("/etc/hosts"))
    assert_equal(loaded[1].cursor_row, 0)
    assert_equal(loaded[1].scroll_y, 0)
    _ = external_call["system", Int32](
        (String("rm -rf '") + root + String("'\0")).unsafe_ptr(),
    )


def test_view_state_store_load_missing_returns_empty() raises:
    """No file → empty list. Same contract as the sibling stores so
    the Desktop can blindly load on every project open."""
    var vs = load_view_states(
        String("/tmp/turbokod_vs_does_not_exist_xyz"),
    )
    assert_equal(len(vs), 0)


def test_view_state_store_per_user_path() raises:
    """The on-disk file lives under ``per_user/<USER>/`` next to
    breakpoints.json — keeps each developer's scroll positions
    separate, so an accidental ``git add .turbokod`` doesn't replace
    a teammate's set."""
    var root = String("/tmp/turbokod_vs_per_user_test")
    _ = external_call["system", Int32](
        (String("rm -rf '") + root + String("'\0")).unsafe_ptr(),
    )
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var user_env = String("USER=bob_test\0")
    _ = external_call["putenv", Int32](user_env.unsafe_ptr())
    var views = List[StoredViewState]()
    views.append(StoredViewState(
        root + String("/main.py"), 12, 0, 0, 5,
    ))
    assert_true(save_view_states(root, views))
    var expected = root + String(
        "/.turbokod/per_user/bob_test/view_states.json"
    )
    assert_true(stat_file(expected).ok)
    _ = external_call["system", Int32](
        (String("rm -rf '") + root + String("'\0")).unsafe_ptr(),
    )


def test_session_relative_path_round_trip() raises:
    """``project_relative`` strips the project prefix; the inverse
    re-anchors. Files outside the project keep their absolute form
    on the way out and pass through on the way back in."""
    var root = String("/Users/foo/proj")
    var inside = String("/Users/foo/proj/src/main.mojo")
    var outside = String("/etc/hosts")
    var rel_in = project_relative(root, inside)
    assert_equal(rel_in, String("src/main.mojo"))
    var rel_out = project_relative(root, outside)
    assert_equal(rel_out, outside)
    var resolved_in = _resolve_session_path(root, rel_in)
    assert_equal(resolved_in, inside)
    var resolved_out = _resolve_session_path(root, rel_out)
    assert_equal(resolved_out, outside)


def test_desktop_restores_session_from_disk() raises:
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
    var w0 = d.windows.windows[0].copy()
    assert_true(w0.is_editor)
    assert_equal(w0.rect.a.x, 4)
    assert_equal(w0.rect.a.y, 2)
    assert_equal(w0.rect.b.x, 50)
    assert_equal(w0.rect.b.y, 18)
    assert_equal(w0.editor.selections[0].row, 2)
    assert_equal(w0.editor.selections[0].col, 3)
    assert_equal(d.windows.focused, 0)
    _ = external_call["system", Int32](cleanup.unsafe_ptr())


def test_desktop_restores_drafts_from_disk() raises:
    """Open a project with a saved ``drafts.json`` and confirm the
    desktop reopens the untitled buffer: a titled "Untitled" editor
    window shows up with the saved content, the cursor is reapplied, and
    crucially the buffer reports itself as *dirty* (unsaved) even though
    the bytes came off disk — the draft file is an autosave shadow, not
    a real save."""
    var root = String("/tmp/turbokod_drafts_restore_test")
    var cleanup = String("rm -rf '") + root + String("'\0")
    _ = external_call["system", Int32](cleanup.unsafe_ptr())
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var drafts = List[StoredDraft]()
    var d0 = StoredDraft()
    d0.seq = 2
    d0.content = String("draft line one\ndraft line two")
    d0.rect_a_x = 4
    d0.rect_a_y = 2
    d0.rect_b_x = 50
    d0.rect_b_y = 18
    d0.restore_a_x = 4
    d0.restore_a_y = 2
    d0.restore_b_x = 50
    d0.restore_b_y = 18
    d0.cursor_row = 1
    d0.cursor_col = 5
    drafts.append(d0^)
    assert_true(save_drafts(root, drafts))
    var d = Desktop()
    d.open_project(root)
    assert_true(d.project)
    var screen = Rect(0, 0, 80, 30)
    d._pending_restore = False
    d._restore_drafts(screen)
    assert_equal(len(d.windows.windows), 1)
    var w0 = d.windows.windows[0].copy()
    assert_true(w0.is_editor)
    assert_equal(w0.title, String("Untitled 2"))
    assert_equal(len(w0.editor.file_path.as_bytes()), 0)
    assert_true(w0.editor.dirty)
    assert_equal(w0.editor.buffer.line(0), String("draft line one"))
    assert_equal(w0.editor.buffer.line(1), String("draft line two"))
    assert_equal(w0.editor.selections[0].row, 1)
    assert_equal(w0.editor.selections[0].col, 5)
    # The lone restored draft takes focus (a file-less project would
    # otherwise land on a -1 focus).
    assert_equal(d.windows.focused, 0)
    # A subsequent new_file must not collide with the restored seq.
    assert_true(d._untitled_count >= 2)
    _ = external_call["system", Int32](cleanup.unsafe_ptr())


def test_desktop_resize_reapplies_clipped_session_rect() raises:
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


def test_desktop_arms_session_restore_when_non_editor_windows_present() raises:
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


def test_desktop_restores_non_maximized_rect_not_restore_rect() raises:
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
    var w0 = d.windows.windows[0].copy()
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


def test_desktop_snapshot_captures_per_window_rects() raises:
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
                and String(StringSpan(unsafe_from_utf8=pb[len(pb) - alen:])) \
                == String("a.txt"):
            idx_a = i
        if len(pb) >= blen \
                and String(StringSpan(unsafe_from_utf8=pb[len(pb) - blen:])) \
                == String("b.txt"):
            idx_b = i
    assert_true(idx_a >= 0)
    assert_true(idx_b >= 0)
    assert_equal(session.windows[idx_a].rect_a_x, 2)
    assert_equal(session.windows[idx_a].rect_b_x, 30)
    assert_equal(session.windows[idx_b].rect_a_x, 40)
    assert_equal(session.windows[idx_b].rect_b_x, 75)
    _ = external_call["system", Int32](cleanup.unsafe_ptr())


def test_desktop_restores_multiple_windows_at_distinct_positions() raises:
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
    assert_equal(d.windows.windows[bar_idx].editor.selections[0].row, 1)
    assert_equal(d.windows.windows[bar_idx].editor.selections[0].col, 2)
    assert_equal(d.windows.focused, bar_idx)
    _ = external_call["system", Int32](cleanup.unsafe_ptr())


def test_desktop_restores_maximized_window_keeps_per_window_restore_rect() raises:
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
    var w = d.windows.windows[0].copy()
    assert_true(w.is_maximized)
    # _restore_rect must reflect the saved un-maximized layout.
    assert_equal(w._restore_rect.a.x, 8)
    assert_equal(w._restore_rect.a.y, 4)
    assert_equal(w._restore_rect.b.x, 40)
    assert_equal(w._restore_rect.b.y, 18)
    _ = external_call["system", Int32](cleanup.unsafe_ptr())


def test_desktop_save_then_restore_round_trip_through_paint() raises:
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
    var session_path = _session_path(root)
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
                and String(StringSpan(unsafe_from_utf8=fpb[len(fpb) - slen:])) \
                == String("/p.txt"):
            p_idx = i
        if len(fpb) >= slen \
                and String(StringSpan(unsafe_from_utf8=fpb[len(fpb) - slen:])) \
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


def test_window_cap_evicts_least_recently_used() raises:
    """With ``max_open_windows`` set, opening a document past the cap
    closes the least-recently-focused *clean* document — never the
    focused one, and never one with unsaved changes."""
    var root = String("/tmp/turbokod_window_cap_test")
    var cleanup = String("rm -rf '") + root + String("'\0")
    _ = external_call["system", Int32](cleanup.unsafe_ptr())
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    assert_true(write_file(root + String("/a.txt"), String("a\n")))
    assert_true(write_file(root + String("/b.txt"), String("b\n")))
    assert_true(write_file(root + String("/c.txt"), String("c\n")))
    assert_true(write_file(root + String("/d.txt"), String("d\n")))
    var screen = Rect(0, 0, 80, 30)
    var d = Desktop()
    d.open_project(root)
    d.config.max_open_windows = 2

    d.open_file(root + String("/a.txt"), screen)
    d.open_file(root + String("/b.txt"), screen)
    assert_equal(len(_doc_paths(d)), 2)
    # Force a deterministic recency order: a older than b.
    d.windows.windows[0]._last_focus_ms = 1000
    d.windows.windows[1]._last_focus_ms = 2000

    # Opening c is the 3rd doc → evict the least-recently-used clean doc (a).
    d.open_file(root + String("/c.txt"), screen)
    assert_equal(len(_doc_paths(d)), 2)
    assert_false(_docs_contains(d, String("a.txt")))
    assert_true(_docs_contains(d, String("b.txt")))
    assert_true(_docs_contains(d, String("c.txt")))

    # Now mark b (the LRU) dirty and open d. b is protected, so the next
    # least-recently-used *clean* doc (c) is evicted instead.
    for i in range(len(d.windows.windows)):
        if basename(d.windows.windows[i].editor.file_path) == String("b.txt"):
            d.windows.windows[i]._last_focus_ms = 1000
            d.windows.windows[i].editor.dirty = True
        elif basename(d.windows.windows[i].editor.file_path) == String("c.txt"):
            d.windows.windows[i]._last_focus_ms = 1500
    d.open_file(root + String("/d.txt"), screen)
    assert_equal(len(_doc_paths(d)), 2)
    assert_true(_docs_contains(d, String("b.txt")))   # dirty → kept
    assert_false(_docs_contains(d, String("c.txt")))  # clean LRU → evicted
    assert_true(_docs_contains(d, String("d.txt")))
    _ = external_call["system", Int32](cleanup.unsafe_ptr())


def test_window_cap_disabled_when_zero() raises:
    """``max_open_windows == 0`` means no limit — opening many documents
    never evicts."""
    var root = String("/tmp/turbokod_window_cap_off_test")
    var cleanup = String("rm -rf '") + root + String("'\0")
    _ = external_call["system", Int32](cleanup.unsafe_ptr())
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    assert_true(write_file(root + String("/a.txt"), String("a\n")))
    assert_true(write_file(root + String("/b.txt"), String("b\n")))
    assert_true(write_file(root + String("/c.txt"), String("c\n")))
    var screen = Rect(0, 0, 80, 30)
    var d = Desktop()
    d.open_project(root)
    d.config.max_open_windows = 0
    d.open_file(root + String("/a.txt"), screen)
    d.open_file(root + String("/b.txt"), screen)
    d.open_file(root + String("/c.txt"), screen)
    assert_equal(len(_doc_paths(d)), 3)
    _ = external_call["system", Int32](cleanup.unsafe_ptr())


def test_desktop_snapshot_skips_untitled_windows() raises:
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


def test_desktop_confirm_dialog_yes_starts_grammar_install() raises:
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


def test_desktop_shutdown_releases_its_libonig_handles() raises:
    """``Desktop.shutdown`` is what ``tk_desktop_free`` calls when a
    window closes, and it has to give back everything Mojo's destructor
    can't reach.

    The native app deliberately outlives its windows, so before this
    existed a closed window left its language servers, debug adapter and
    pty shells *running* with their pipes held, plus every compiled
    grammar, git-output matcher and Find regex it had accumulated —
    until the user quit the app entirely.

    Child processes aren't spawned in this test (no servers to talk to),
    so what's asserted is the handle side: painting a buffer compiles a
    grammar, running a Find compiles a searcher, and shutdown must
    return the count to where it started. It must also be safe to call
    twice — the host's teardown ordering makes that reachable.
    """
    onig_global_init()
    # A temp file outside any project root, so ``paint``'s session-restore
    # can't contaminate the window list (same reasoning as the golden-line
    # tests above).
    var path = _temp_path(String("_leak_probe.ts"))
    assert_true(write_file(path, String(
        "interface Foo { bar: string }\nconst x: Foo = { bar: 'hi' };\n",
    )))
    var live = onig_tracked_count()
    var d = Desktop()
    var screen = Rect(0, 0, 100, 40)
    d.open_file(path, screen)
    var canvas = Canvas(100, 40)
    d.paint(canvas, screen)
    var idx = len(d.windows.windows) - 1
    # A Find compiles a regex that lives on the Editor, not the registry —
    # invisible to the grammar release, so it needs its own teardown.
    _ = d.windows.windows[idx].editor.find_next(String("Foo"))
    assert_true(onig_tracked_count() > live)
    d.shutdown()
    assert_equal(onig_tracked_count(), live)
    # Idempotent — the host's teardown ordering makes a second call
    # reachable.
    d.shutdown()
    assert_equal(onig_tracked_count(), live)
    _ = delete_path(path)


def test_closing_a_window_releases_its_find_regex() raises:
    """A window closed mid-session hands its Find regex back.

    ``Desktop.shutdown`` walks the windows that are still *open*, so it
    can't reach the searcher of one already popped off the list — the
    release has to happen on the close path itself (``Window.release``).
    Before it did, every window close stranded ~1 KB of libonig for the
    life of the process, and ``_enforce_window_cap``'s LRU eviction made
    that automatic rather than user-driven.

    Both close paths are covered: ``close_focused`` is Window ▸ Close /
    the ``[■]`` button, ``close_by_index`` is what eviction and the
    delete-file sweep use.
    """
    onig_global_init()
    var a = _temp_path(String("_close_leak_a.ts"))
    var b = _temp_path(String("_close_leak_b.ts"))
    assert_true(write_file(a, String("interface Foo { bar: string }\n")))
    assert_true(write_file(b, String("interface Foo { baz: string }\n")))
    var live = onig_tracked_count()
    var d = Desktop()
    var screen = Rect(0, 0, 100, 40)
    d.open_file(a, screen)
    var idx_a = len(d.windows.windows) - 1
    d.open_file(b, screen)
    var idx_b = len(d.windows.windows) - 1
    # A Find compiles a regex that lives on the Editor, not on the
    # grammar registry — the default search options are case-*insensitive*,
    # which is precisely the configuration that needs libonig.
    _ = d.windows.windows[idx_a].editor.find_next(String("Foo"))
    _ = d.windows.windows[idx_b].editor.find_next(String("Foo"))
    assert_true(onig_tracked_count() > live)
    assert_true(d.windows.close_by_index(idx_a))
    assert_true(d.windows.close_focused())
    # Every window that compiled a regex is gone, so the count is already
    # back at the baseline — shutdown has nothing left to reach.
    assert_equal(onig_tracked_count(), live)
    d.shutdown()
    assert_equal(onig_tracked_count(), live)
    _ = delete_path(a)
    _ = delete_path(b)


def test_close_all_editor_windows_releases_their_find_regexes() raises:
    """Closing *every* editor at once releases their Find regexes too.

    ``_close_all_editor_windows`` is a third window-removal path
    alongside ``close_focused`` / ``close_by_index``: it rebuilds the
    window list by assignment rather than popping, so it used to drop
    each editor without the ``Window.release`` the other two do. Both of
    its callers are routine — Window ▸ Close All, and ``close_project``,
    which every project *switch* goes through — and because the windows
    are gone afterwards, no later ``shutdown`` can reach the stranded
    handles: one regex per editor that ran a Find, leaked permanently
    per project switch.
    """
    onig_global_init()
    var a = _temp_path(String("_close_all_leak_a.ts"))
    var b = _temp_path(String("_close_all_leak_b.ts"))
    assert_true(write_file(a, String("interface Foo { bar: string }\n")))
    assert_true(write_file(b, String("interface Foo { baz: string }\n")))
    var live = onig_tracked_count()
    var d = Desktop()
    var screen = Rect(0, 0, 100, 40)
    d.open_file(a, screen)
    d.open_file(b, screen)
    var found = 0
    for i in range(len(d.windows.windows)):
        if d.windows.windows[i].is_editor:
            _ = d.windows.windows[i].editor.find_next(String("Foo"))
            found += 1
    assert_equal(found, 2)
    assert_true(onig_tracked_count() >= live + 2)
    _ = d.dispatch_action(WINDOW_CLOSE_ALL, screen)
    # The editors are gone, so their searchers must be too — this is the
    # last moment anything could reach them.
    assert_equal(onig_tracked_count(), live)
    d.shutdown()
    assert_equal(onig_tracked_count(), live)
    _ = delete_path(a)
    _ = delete_path(b)


def test_shutdown_reaps_an_in_flight_on_save_child() raises:
    """``shutdown`` has to reap the on-save children too.

    They're the only children cleaned *purely* by a per-frame tick
    (``save_actions_tick``), and a closed window gets no further ticks —
    so before this the child kept running, its two pipe descriptors
    stayed open for the life of the app, and it sat unreaped in our
    process table. Auto-save on focus loss is what spawns them, which is
    exactly the moment a window is closing.

    Asserted through the pid rather than the fds: ``kill(pid, 0)``
    succeeds on a zombie, so its *failure* is what proves the reap
    happened rather than just a SIGTERM.
    """
    var sh_info = stat_file(String("/bin/sh"))
    if not sh_info.ok:
        assert_true(True)
        return
    var d = Desktop()
    var argv = List[String]()
    argv.append(String("/bin/sh"))
    argv.append(String("-c"))
    argv.append(String("sleep 30"))
    var proc = LspProcess.spawn(argv)
    if proc.stdin_fd >= 0:
        _ = close_fd(proc.stdin_fd)
    d.pending_save_actions.append(
        PendingSaveAction(
            proc.pid, proc.stdout_fd, proc.stderr_fd,
            String("sleep"), String(""),
        )
    )
    # Still alive going in, so the assertions below can't pass by accident.
    assert_equal(Int(kill_pid(proc.pid, Int32(0))), 0)
    d.shutdown()
    assert_equal(len(d.pending_save_actions), 0)
    assert_true(Int(kill_pid(proc.pid, Int32(0))) != 0)
    # Both pipe ends are ours and were closed — a second close is EBADF.
    assert_true(Int(close_fd(proc.stdout_fd)) != 0)
    assert_true(Int(close_fd(proc.stderr_fd)) != 0)


def test_shutdown_stops_the_search_subprocesses() raises:
    """Find in Project / Find Symbol each stream an ``rg`` child; a
    window closed mid-search used to leave it running with our three
    descriptors held, since ``shutdown`` never cancelled either runner.
    """
    if len(which(String("rg")).as_bytes()) == 0:
        assert_true(True)
        return
    var d = Desktop()
    var root = String("/Users")
    assert_true(d.find_symbol.runner.start(String("interface"), root))
    assert_true(d.find_symbol.runner.active)
    var sym_pid = d.find_symbol.runner.proc.pid
    d.shutdown()
    assert_false(d.find_symbol.runner.active)
    assert_true(Int(kill_pid(sym_pid, Int32(0))) != 0)


def test_desktop_confirm_dialog_no_clears_pending_action() raises:
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


def main() raises:
    setup_test_env()
    test_desktop_take_attention_drains_panes_and_dap()
    test_open_file_at_golden_when_already_open()
    test_desktop_project_lifecycle()
    test_recent_project_pick_routes_to_new_window_when_host_owns_menu()
    test_desktop_file_tree_cycle_shrinks_workspace()
    test_window_min_size_enforced_at_construction()
    test_window_min_size_survives_workspace_shrink()
    test_window_manager_fit_into_moves_then_resizes()
    test_desktop_dispatch_editor_save_passes_through_when_no_editor()
    test_desktop_dispatch_passes_through_unknown_actions()
    test_desktop_dispatch_editor_save_writes_focused_editor()
    test_window_focus_change_saves_prior_window()
    test_window_focus_change_via_dispatch_action_saves()
    test_window_focus_change_skips_untitled_buffer()
    test_desktop_replace_all_button_runs_global_replace()
    test_desktop_replace_button_replaces_current_match_then_advances()
    test_desktop_find_next_button_just_advances()
    test_desktop_replace_seeds_find_from_selection()
    test_desktop_find_seeds_from_editor_selection()
    test_desktop_find_skips_seed_for_multiline_selection()
    test_desktop_find_no_selection_no_prefill()
    test_desktop_open_file_uses_80_percent_size()
    test_desktop_open_file_cascades_by_one()
    test_desktop_open_file_focuses_existing()
    test_desktop_open_file_inherits_maximize_state()
    test_desktop_new_file_creates_untitled_editor_window()
    test_desktop_dispatch_editor_new_opens_window()
    test_desktop_save_as_updates_window_title()
    test_desktop_window_menu_lists_open_windows()
    test_desktop_window_menu_when_empty()
    test_desktop_window_focus_action_focuses_window()
    test_desktop_maximize_all_and_restore_all()
    test_desktop_project_find_requires_active_project()
    test_desktop_project_replace_opens_find_in_replace_mode()
    test_nav_history_records_initial_open()
    test_nav_history_ignores_small_drift()
    test_nav_history_records_file_change()
    test_nav_history_back_and_forward()
    test_nav_history_branching_truncates_forward()
    test_nav_history_back_via_dispatch_action()
    test_nav_history_cmd_bracket_keys_fire_dispatch()
    test_window_manager_close_focused()
    test_window_manager_rotate_focus_cycles_in_stable_order()
    test_window_manager_rotate_focus_noop_when_fewer_than_two_windows()
    test_window_menu_items_show_ctrl_n_shortcut()
    test_project_settings_on_save_seeds_state()
    test_desktop_set_font_maps_default_label_to_empty()
    test_desktop_set_font_size_clamps_and_bumps_version()
    test_desktop_routes_alt_tap_to_focused_editor()
    test_window_manager_fit_into_keeps_maximized_pinned()
    test_window_manager_fit_into_scales_side_by_side_on_grow()
    test_window_manager_fit_into_scales_side_by_side_on_shrink()
    test_window_manager_fit_into_scales_stacked_on_resize()
    test_window_manager_fit_into_proportional_2x2_grid()
    test_window_manager_fit_into_baseline_no_scale_on_first_call()
    test_window_manager_note_workspace_suppresses_next_scale()
    test_window_manager_fit_into_round_trip_is_lossless()
    test_window_manager_fit_into_user_drag_rebases_baseline()
    test_window_manager_fit_into_scales_restore_rect_for_maximized()
    test_window_manager_title_hover_arms_for_editor_with_path()
    test_window_manager_title_hover_skips_unbacked_buffers()
    test_window_manager_title_hover_reveals_full_path_in_titlebar()
    test_window_v_scrollbar_hit_arrows_and_thumb()
    test_window_v_scroll_by_clamps()
    test_window_v_scrollbar_track_click_centers_target()
    test_window_v_scroll_drag_to_end()
    test_desktop_esc_dismisses_completion_popup()
    test_desktop_left_click_outside_popup_dismisses_it()
    test_desktop_left_click_inside_popup_keeps_it_open()
    test_project_targets_load_parses_fields()
    test_project_targets_save_roundtrips_active()
    test_project_targets_resolve_paths()
    test_project_on_save_round_trip()
    test_project_settings_on_save_enable_disable()
    test_project_settings_grammars_add_remove()
    test_project_settings_paint_smoke()
    test_session_round_trip()
    test_session_per_user_path()
    test_session_load_missing_returns_empty()
    test_view_state_store_round_trip()
    test_view_state_store_load_missing_returns_empty()
    test_view_state_store_per_user_path()
    test_session_relative_path_round_trip()
    test_desktop_restores_session_from_disk()
    test_desktop_restores_drafts_from_disk()
    test_desktop_resize_reapplies_clipped_session_rect()
    test_desktop_arms_session_restore_when_non_editor_windows_present()
    test_desktop_restores_non_maximized_rect_not_restore_rect()
    test_desktop_snapshot_captures_per_window_rects()
    test_desktop_restores_multiple_windows_at_distinct_positions()
    test_desktop_restores_maximized_window_keeps_per_window_restore_rect()
    test_desktop_save_then_restore_round_trip_through_paint()
    test_window_cap_evicts_least_recently_used()
    test_window_cap_disabled_when_zero()
    test_desktop_snapshot_skips_untitled_windows()
    test_desktop_confirm_dialog_yes_starts_grammar_install()
    test_desktop_confirm_dialog_no_clears_pending_action()
    test_desktop_shutdown_releases_its_libonig_handles()
    test_closing_a_window_releases_its_find_regex()
    test_close_all_editor_windows_releases_their_find_regexes()
    test_shutdown_reaps_an_in_flight_on_save_child()
    test_shutdown_stops_the_search_subprocesses()
    print("desktop: 101 tests passed")
