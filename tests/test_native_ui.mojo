"""The macOS-style UI (View ▸ macOS-style UI): the core keeps owning a dialog's
state and submit path, but hands its display to the host as a native sheet.
These pin the core half — what counts as native, that nothing in-grid can
answer a dialog the host is showing, and that a native answer runs the same
handler a click on the in-grid button would."""

from std.testing import TestSuite, assert_equal, assert_false, assert_true
from turbokod.canvas import Canvas
from turbokod.colors import default_attr
from turbokod.desktop import (
    Desktop, EDITOR_FIND, EDITOR_GOTO, EDITOR_REPLACE, VIEW_NATIVE_UI,
)
from turbokod.search_options import SearchOptions
from turbokod.color_picker import ColorPickerDialog, MODE_RGB
from turbokod.fill_dialog import FillDialog
from turbokod.events import Event, KEY_ENTER
from turbokod.geometry import Point, Rect
from turbokod.window import Window
from turbokod.file_io import write_file
from turbokod.posix import sleep_ms
from turbokod.string_utils import string_list
from support import _SCREEN, _git_capture, _run_git, _temp_path, setup_test_env


def _native_desktop(text: String) -> Desktop:
    var d = Desktop()
    d.host_owns_menu = True
    d.config.native_ui = True
    d.windows.add(Window.editor_window(
        String("buf"), Rect(0, 1, 60, 20), text,
    ))
    return d^


def _screen_has(mut d: Desktop, needle: String) raises -> Bool:
    """True when ``needle`` appears on some painted row."""
    var canvas = Canvas(_SCREEN.b.x, _SCREEN.b.y)
    canvas.clear(default_attr())
    d.paint(canvas, _SCREEN)
    for y in range(_SCREEN.b.y):
        var row = String("")
        for x in range(_SCREEN.b.x):
            row += canvas.get(x, y).glyph
        if needle in row:
            return True
    return False


def test_confirm_paints_in_grid_with_native_ui_off() raises:
    var d = _native_desktop(String("x\n"))
    d.config.native_ui = False
    d.confirm_dialog.open(String("Install rust LSP?"), String("Install"))
    assert_true(_screen_has(d, String("Install rust LSP?")))


def test_native_ui_needs_a_host_that_owns_the_menu() raises:
    var d = Desktop()
    d.config.native_ui = True
    assert_false(d.native_ui())   # terminal frontend: always in-grid
    d.host_owns_menu = True
    assert_true(d.native_ui())


def test_view_menu_toggles_native_ui() raises:
    var d = Desktop()
    d.host_owns_menu = True
    assert_false(d.config.native_ui)
    _ = d.dispatch_action(VIEW_NATIVE_UI, _SCREEN)
    assert_true(d.config.native_ui)
    _ = d.dispatch_action(VIEW_NATIVE_UI, _SCREEN)
    assert_false(d.config.native_ui)


def test_native_confirm_ignores_grid_keys_and_takes_the_host_answer() raises:
    var d = _native_desktop(String("x\n"))
    d._pending_action = String("lsp:install")
    d._pending_arg = String("rust")
    d.confirm_dialog.open(String("Install rust LSP?"), String("Install"))
    assert_true(d.native_dialog_active())
    assert_false(_screen_has(d, String("Install rust LSP?")))
    # "c" would press Cancel in-grid; behind a native sheet it does nothing.
    _ = d.handle_event(Event.key_event(UInt32(ord("c"))), _SCREEN)
    assert_true(d.confirm_dialog.active)
    _ = d.native_confirm_answer(-1)
    assert_false(d.confirm_dialog.active)
    assert_equal(d._pending_action, String(""))
    assert_false(d.install_runner.is_active())


def test_find_goes_to_the_bar_and_go_to_line_is_a_native_prompt() raises:
    var d = _native_desktop(String("a\nb\nc\nd\n"))
    _ = d.dispatch_action(EDITOR_FIND, _SCREEN)
    assert_false(d.prompt.active)
    assert_equal(d.native_find_request, String("find"))
    _ = d.dispatch_action(EDITOR_GOTO, _SCREEN)
    assert_true(d.native_dialog_active())
    assert_equal(d.native_prompt_action(), String("Go"))


def test_native_go_to_line_answer_runs_the_submit_path() raises:
    var d = _native_desktop(String("a\nb\nc\nd\n"))
    _ = d.dispatch_action(EDITOR_GOTO, _SCREEN)
    _ = d.native_prompt_answer(String("3"), True)
    assert_false(d.prompt.active)
    assert_equal(d.windows.windows[0].editor.primary_caret().row, 2)


def test_native_prompt_cancel_closes_without_submitting() raises:
    var d = _native_desktop(String("a\nb\nc\nd\n"))
    _ = d.dispatch_action(EDITOR_GOTO, _SCREEN)
    _ = d.native_prompt_answer(String("3"), False)
    assert_false(d.prompt.active)
    assert_equal(d.windows.windows[0].editor.primary_caret().row, 0)
    # Enter now goes to the editor, not a lingering prompt.
    _ = d.handle_event(Event.key_event(KEY_ENTER), _SCREEN)
    assert_false(d.native_dialog_active())


def test_native_ui_tabs_fill_the_workspace_frameless() raises:
    var d = _native_desktop(String("a\nb\n"))
    var canvas = Canvas(_SCREEN.b.x, _SCREEN.b.y)
    canvas.clear(default_attr())
    d.config.native_ui = False
    d.paint(canvas, _SCREEN)
    var before = d.windows.windows[0].rect
    d.config.native_ui = True
    d.paint(canvas, _SCREEN)
    ref w = d.windows.windows[0]
    assert_true(w.frameless)
    assert_true(w.rect == d.workspace_rect(_SCREEN))
    assert_true(w.interior() == w.rect)
    # The border's hit zones are gone: the top row is editor text.
    assert_false(w.title_bar_hit(w.rect.a))
    assert_false(w.close_button_hit(w.rect.a))
    # The host's tab strip replaces the in-grid one.
    assert_true(d.tab_bar_rect(_SCREEN).is_empty())
    # Switching back restores the framed window where it was.
    d.config.native_ui = False
    d.paint(canvas, _SCREEN)
    assert_false(d.windows.windows[0].frameless)
    assert_true(d.windows.windows[0].rect == before)


def test_tabbed_session_saves_the_framed_layout() raises:
    var d = _native_desktop(String("a\n"))
    # Keep the workspace fixed across the switch (the in-grid tab bar's
    # row would otherwise rescale the layout proportionally).
    d.config.tab_bar = False
    var canvas = Canvas(_SCREEN.b.x, _SCREEN.b.y)
    canvas.clear(default_attr())
    d.config.native_ui = False
    d.paint(canvas, _SCREEN)
    var framed = d.windows.windows[0].rect
    d.config.native_ui = True
    d.paint(canvas, _SCREEN)
    d.project = Optional[String](String("/x"))
    d.windows.windows[0].editor.file_path = String("/x/a.txt")
    var snap = d._snapshot_session()
    assert_equal(len(snap.windows), 1)
    assert_false(snap.windows[0].is_maximized)
    assert_true(snap.windows[0].rect() == framed)


def test_close_tab_asks_before_dropping_unsaved_work() raises:
    var d = _native_desktop(String("a\n"))
    d.windows.windows[0].editor.dirty = True
    d.close_tab(0)
    assert_equal(len(d.windows.windows), 1)
    assert_true(d.native_dialog_active())
    var labels = d.confirm_dialog.labels.copy()
    assert_equal(labels[1], String("Delete"))


def _quick_open_with(mut d: Desktop, paths: List[String]):
    """Quick Open up with ``paths`` already indexed (no async indexer)."""
    d.quick_open.active = True
    for i in range(len(paths)):
        d.quick_open.entries.append(paths[i])
        d.quick_open.entries_abs.append(paths[i])
    d.quick_open.set_query(String("x"))
    d.quick_open.set_query(String(""))


def test_native_picker_is_reported_only_with_native_ui() raises:
    var d = Desktop()
    _quick_open_with(d, [String("/a/one.txt")])
    assert_equal(d.native_picker_kind(), String(""))
    d.host_owns_menu = True
    d.config.native_ui = True
    assert_equal(d.native_picker_kind(), String("quick_open"))
    d.native_picker_close()
    assert_false(d.quick_open.active)
    assert_equal(d.native_picker_kind(), String(""))


def test_native_quick_open_filters_and_opens_the_picked_row() raises:
    var a = _temp_path(String("_nqo_alpha.txt"))
    var b = _temp_path(String("_nqo_beta.txt"))
    _ = write_file(a, String("alpha\n"))
    _ = write_file(b, String("beta\n"))
    var d = _native_desktop(String("x\n"))
    _quick_open_with(d, [a, b])
    assert_equal(len(d.quick_open.matched), 2)
    d.native_picker_set(String("query"), String("beta"))
    assert_equal(len(d.quick_open.matched), 1)
    _ = d.native_picker_activate(0, 0, _SCREEN)
    assert_false(d.quick_open.active)
    var f = d.windows.focused
    assert_equal(d.windows.windows[f].editor.file_path, b)


def test_native_project_find_fields_and_toggles_rerun_the_search() raises:
    var d = _native_desktop(String("x\n"))
    d.project_find.open(String("/nonexistent-root"))
    assert_equal(d.native_picker_kind(), String("project_find"))
    d.native_picker_set(String("query"), String("needle"))
    assert_equal(d.project_find.query.text, String("needle"))
    assert_true(d.project_find.searching())   # debounce pending
    d.native_picker_set(String("replace"), String("pin"))
    assert_equal(d.project_find.replace.text, String("pin"))
    var was_on = d.project_find.toggle_regex.on
    d.native_picker_option(String("regex"), not was_on)
    assert_true(d.project_find.toggle_regex.on != was_on)
    d.native_picker_option(String("regex"), was_on)   # leave it as found
    # Buttons need results to act on.
    d.native_picker_action(String("send_to_panel"), _SCREEN)
    assert_true(d.project_find.active)
    d.native_picker_close()
    assert_false(d.project_find.active)


def test_welcome_choices_apply_live_and_finish_once() raises:
    var d = Desktop()
    d.host_owns_menu = True
    assert_false(d.config.welcome_done)
    d.apply_welcome(True, String("Dracula"), d.font_label(), 13, False)
    assert_true(d.config.native_ui)
    assert_equal(d.config.theme, String("Dracula"))
    assert_equal(d.active_theme.name, String("Dracula"))
    assert_equal(d.config.font_size, 13)
    assert_false(d.config.welcome_done)   # still choosing
    d.apply_welcome(False, String("Turbo C++ 3.0"), d.font_label(), 0, True)
    assert_false(d.config.native_ui)
    assert_true(d.config.welcome_done)


def test_native_popup_lists_rows_and_dismisses_through_its_handler() raises:
    var d = _native_desktop(String("x\n"))
    d.spell_menu.open(String("wrod"), Point(4, 6), False)
    assert_equal(d.native_popup_kind(), String("spell"))
    var items = d.native_popup_items()
    assert_equal(len(items), 2)
    assert_true(items[0].enabled)
    assert_false(items[1].enabled)   # no project: project dictionary greyed
    var at = d.native_popup_anchor()
    assert_equal(at.x, 4)
    assert_equal(at.y, 6)
    # Grid input can't answer it behind the NSMenu's back.
    _ = d.handle_event(Event.key_event(KEY_ENTER), _SCREEN)
    assert_true(d.spell_menu.active)
    _ = d.native_popup_choose(0)
    assert_false(d.spell_menu.active)
    assert_equal(d.native_popup_kind(), String(""))


def _repo_with_a_change() raises -> String:
    """A repo with one committed file, modified in the worktree."""
    var root = _temp_path(String("_native_git"))
    _ = _run_git(String("/"), string_list(String("init"), String("-q"), root))
    # The test $HOME has no git identity; the view's own commit needs one.
    _ = _run_git(root, string_list(String("config"), String("user.email"), String("t@t")))
    _ = _run_git(root, string_list(String("config"), String("user.name"), String("t")))
    _ = write_file(root + String("/a.txt"), String("one\n"))
    _ = _run_git(root, string_list(String("add"), String("a.txt")))
    _ = _run_git(root, string_list(String("commit"), String("-qm"), String("first")))
    _ = write_file(root + String("/a.txt"), String("one\ntwo\n"))
    return root^


def _wait_git(mut d: Desktop):
    for _ in range(500):
        d.local_changes.tick()
        if not d.local_changes.native_busy():
            return
        sleep_ms(10)


def test_native_git_stages_and_commits_through_the_views_own_paths() raises:
    var root = _repo_with_a_change()
    var d = _native_desktop(String("x\n"))
    d.local_changes.open(root)
    assert_true(d.native_git_active())
    assert_equal(len(d.local_changes.files), 1)
    d.native_git_select(0, 0, _SCREEN)
    assert_true(d.local_changes.native_shows_file())
    d.native_git_key(0, UInt32(0x20), UInt8(0), _SCREEN)   # Space: stage
    assert_equal(Int(d.local_changes.files[0].staged), Int(ord("M")))
    d.native_git_commit(String("second"))
    _wait_git(d)
    var log = _git_capture(root, string_list(
        String("log"), String("--format=%s"),
    ))
    assert_true(String("second") in log)
    assert_true(d.native_git_close())
    assert_false(d.native_git_active())


def test_native_git_overlay_cancel_and_status_dismiss() raises:
    var root = _repo_with_a_change()
    var d = _native_desktop(String("x\n"))
    d.local_changes.open(root)
    d.native_git_select(0, 0, _SCREEN)
    # Nothing staged: committing reports instead of opening the prompt.
    d.native_git_commit(String("nope"))
    assert_equal(d.local_changes.native_overlay_kind(), String("status"))
    d.native_git_answer(String("ok"), String(""))
    assert_equal(d.local_changes.native_overlay_kind(), String(""))
    # ``d`` on a file asks first; Cancel leaves the change alone.
    d.native_git_key(0, UInt32(ord("d")), UInt8(0), _SCREEN)
    assert_equal(d.local_changes.native_overlay_kind(), String("revert"))
    d.native_git_answer(String("cancel"), String(""))
    assert_equal(d.local_changes.native_overlay_kind(), String(""))
    assert_equal(len(d.local_changes.files), 1)
    d.local_changes.release()


def test_native_find_asks_for_the_bar_instead_of_the_prompt() raises:
    var d = _native_desktop(String("foo\nbar\nfoo\n"))
    _ = d.dispatch_action(EDITOR_REPLACE, _SCREEN)
    assert_false(d.prompt.active)
    assert_equal(d.native_find_request, String("replace"))


def test_native_find_bar_steps_replaces_and_remembers_the_needle() raises:
    var d = _native_desktop(String("foo\nbar\nfoo\n"))
    var opts = SearchOptions()
    d.native_find(String("next"), String("foo"), String(""), opts)
    assert_equal(d._last_search, String("foo"))   # F3 repeats it
    var first = d.windows.windows[0].editor.primary_caret().row
    d.native_find(String("next"), String("foo"), String(""), opts)
    assert_true(d.windows.windows[0].editor.primary_caret().row != first)
    d.native_find(String("replace_all"), String("foo"), String("baz"), opts)
    var text = d.windows.windows[0].editor.text_snapshot()
    assert_false(String("foo") in text)
    assert_true(String("baz") in text)


def test_native_color_pick_is_written_in_the_chosen_notation() raises:
    var cp = ColorPickerDialog()
    cp.open(UInt32(0xFF0000))
    assert_equal(cp.current_rgb_packed(), 0xFF0000)
    cp.native_apply(0x00FF00, MODE_RGB)
    assert_true(cp.accepted)
    assert_true(cp.submitted)
    assert_true(String("rgb") in cp.result_text)
    assert_true(String("255") in cp.result_text)


def test_native_tree_rows_open_toggle_and_arm_the_menu() raises:
    var root = _temp_path(String("_native_tree"))
    _ = _run_git(String("/"), string_list(String("init"), String("-q"), root))
    _ = write_file(root + String("/b.txt"), String("b\n"))
    _ = _run_git(String("/"), string_list(String("-C"), root, String("status")))
    var d = _native_desktop(String("x\n"))
    d.file_tree.open(root)
    d.file_tree.visible = True
    assert_true(d.native_tree_shown())
    var r = d.file_tree.content_rect(_SCREEN)
    assert_true(r.width() == d.file_tree.width - 1)   # separator stays core's
    var idx = -1
    for i in range(len(d.file_tree.entries)):
        if d.file_tree.entries[i].name == String("b.txt"):
            idx = i
    assert_true(idx >= 0)
    d.file_tree.native_open(idx)
    var opened = d.file_tree.consume_open()
    assert_true(Bool(opened))
    assert_true(opened.value().endswith(String("/b.txt")))
    d.native_tree_menu(idx, Point(2, 3))
    assert_equal(d.native_popup_kind(), String("tab_context"))


def test_native_fill_answer_generates_like_the_grid_dialog() raises:
    var f = FillDialog()
    f.open(3)
    f.native_answer(True, 1, String(""), String("5"), String("2"), False, 0)
    assert_true(f.submitted)
    assert_true(f.confirmed())
    var out = f.generate(3)
    assert_equal(out[0], String("5"))
    assert_equal(out[2], String("9"))


def test_native_fill_answer_with_a_bad_number_stays_open() raises:
    var f = FillDialog()
    f.open(2)
    f.native_answer(True, 1, String(""), String("x"), String("1"), False, 0)
    assert_false(f.submitted)   # the sheet comes back for a fix


def main() raises:
    setup_test_env()
    TestSuite.discover_tests[__functions_in_module()]().run()
