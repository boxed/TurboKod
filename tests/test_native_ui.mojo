"""The macOS-style UI (View ▸ macOS-style UI): the core keeps owning a dialog's
state and submit path, but hands its display to the host as a native sheet.
These pin the core half — what counts as native, that nothing in-grid can
answer a dialog the host is showing, and that a native answer runs the same
handler a click on the in-grid button would."""

from std.testing import TestSuite, assert_equal, assert_false, assert_true
from turbokod.canvas import Canvas
from turbokod.colors import default_attr
from turbokod.desktop import (
    APP_SETTINGS, DOCK_DEBUG_PANE, Desktop, PROJECT_SETTINGS, EDITOR_FIND, EDITOR_GOTO,
    EDITOR_REPLACE, VIEW_NATIVE_UI, VIEW_PLATINUM_UI,
)
from turbokod.search_options import SearchOptions
from turbokod.color_picker import ColorPickerDialog, MODE_RGB
from turbokod.fill_dialog import FillDialog
from turbokod.project_settings import grammar_options
from turbokod.theme import theme_names
from turbokod.ui_grid import ui_act, ui_set
from turbokod.git_changes import LineHistoryEntry
from turbokod.diff import MergeRegion, REGION_CONFLICT, REGION_STABLE
from turbokod.merge_view import CHOICE_DISK
from turbokod.events import Event, KEY_ENTER
from turbokod.geometry import Point, Rect
from turbokod.window import Window
from turbokod.dap_dispatch import DapStackFrame, DapVariable
from turbokod.file_io import write_file
from turbokod.posix import sleep_ms
from turbokod.string_utils import string_list
from support import _SCREEN, _git_capture, _run_git, _temp_path, setup_test_env


def _native_desktop(text: String) -> Desktop:
    var d = Desktop()
    d.host_owns_menu = True
    d.config.native_ui = True
    d.set_settings_detached(True)   # as the macOS host does
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
    d.apply_welcome(True, False, String("Dracula"), d.font_label(), 13, False)
    assert_true(d.config.native_ui)
    assert_equal(d.config.theme, String("Dracula"))
    assert_equal(d.active_theme.name, String("Dracula"))
    assert_equal(d.config.font_size, 13)
    assert_false(d.config.welcome_done)   # still choosing
    d.apply_welcome(False, True, String("Turbo C++ 3.0"), d.font_label(), 0, True)
    assert_false(d.config.native_ui)
    assert_true(d.platinum_ui())
    assert_true(d.settings.platinum_ui)
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


def test_native_settings_edit_the_same_state_and_sync_into_config() raises:
    var d = _native_desktop(String("x\n"))
    _ = d.dispatch_action(APP_SETTINGS, _SCREEN)
    assert_true(d.settings.active)
    assert_true(d.settings_native)
    # Its own window, not a modal: the workspace stays usable.
    assert_equal(len(d.ui_surfaces()), 0)
    assert_false(d.native_ui_surface_active())
    assert_equal(len(d.settings_surfaces()), 1)
    var was = d.config.trim_trailing_whitespace
    var themes = theme_names()
    var dracula = 0
    for i in range(len(themes)):
        if themes[i] == String("Dracula"):
            dracula = i
    d.ui_apply(String("settings"), [
        ui_set(String("trim_trailing_whitespace"), String("0") if was else String("1")),
        ui_set(String("theme"), String(dracula)),
        ui_set(String("max_open_windows"), String("7")),
    ])
    assert_true(d.config.trim_trailing_whitespace != was)
    assert_equal(d.config.theme, String("Dracula"))
    assert_equal(d.config.max_open_windows, 7)


def test_a_look_changed_from_the_menu_survives_an_edit_in_settings() raises:
    # Settings has its own window, so the View menu stays usable while it's
    # open; its next edit wrote back the look it had when it opened
    var d = _native_desktop(String("x\n"))
    _ = d.dispatch_action(APP_SETTINGS, _SCREEN)
    var was = d.config.native_ui
    _ = d.dispatch_action(VIEW_NATIVE_UI, _SCREEN)
    assert_equal(d.config.native_ui, not was)
    d.ui_apply(String("settings"), [
        ui_set(String("cursor_blink"), String("0") if d.config.cursor_blink else String("1")),
    ])
    assert_equal(d.config.native_ui, not was)


def test_a_lower_window_limit_closes_documents_when_settings_closes() raises:
    # Applied as typed, "12" over "20" was 1 first: every clean document
    # but one closed
    var d = Desktop()
    for name in ["_cap_a.txt", "_cap_b.txt", "_cap_c.txt"]:
        var path = _temp_path(String(name))
        _ = write_file(path, String("x\n"))
        d.open_file(path, _SCREEN)
    _ = d.dispatch_action(APP_SETTINGS, _SCREEN)
    d.ui_apply(String("settings"), [ui_set(String("max_open_windows"), String("1"))])
    d.ui_apply(String("settings"), [ui_set(String("max_open_windows"), String("12"))])
    assert_equal(len(d.windows.windows), 3)
    d.ui_apply(String("settings"), [ui_set(String("max_open_windows"), String("2"))])
    assert_equal(len(d.windows.windows), 3)
    d.ui_apply(String("settings"), [ui_act(String("close"))])
    assert_false(d.settings.active)
    assert_equal(len(d.windows.windows), 2)
    assert_equal(d.config.max_open_windows, 2)
    # the same through the window's own close button
    _ = d.dispatch_action(APP_SETTINGS, _SCREEN)
    d.ui_apply(String("settings"), [ui_set(String("max_open_windows"), String("1"))])
    assert_equal(len(d.windows.windows), 2)
    d.close_settings()
    assert_false(d.settings.active)
    assert_equal(len(d.windows.windows), 1)


def _platinum_desktop(text: String) -> Desktop:
    var d = _native_desktop(text)
    d.config.native_ui = False
    d.config.platinum_ui = True
    return d^


def test_platinum_ui_needs_a_host_and_yields_to_native_ui() raises:
    var d = Desktop()
    d.config.platinum_ui = True
    assert_false(d.platinum_ui())   # terminal frontend: always the grid
    d.host_owns_menu = True
    assert_true(d.platinum_ui())
    assert_false(d.native_ui())
    d.config.native_ui = True
    assert_false(d.platinum_ui())


def test_view_menu_looks_are_one_choice() raises:
    var d = Desktop()
    d.host_owns_menu = True
    _ = d.dispatch_action(VIEW_PLATINUM_UI, _SCREEN)
    assert_true(d.platinum_ui())
    _ = d.dispatch_action(VIEW_NATIVE_UI, _SCREEN)
    assert_true(d.native_ui())
    assert_false(d.config.platinum_ui)
    _ = d.dispatch_action(VIEW_PLATINUM_UI, _SCREEN)
    assert_true(d.platinum_ui())
    assert_false(d.config.native_ui)
    _ = d.dispatch_action(VIEW_PLATINUM_UI, _SCREEN)
    assert_false(d.platinum_ui())
    assert_false(d.native_ui())


def test_settings_look_choice_sets_the_look() raises:
    var d = _native_desktop(String("x\n"))
    _ = d.dispatch_action(APP_SETTINGS, _SCREEN)
    d.ui_apply(String("settings"), [ui_set(String("look"), String("2"))])
    assert_true(d.config.platinum_ui)
    assert_false(d.config.native_ui)
    assert_equal(d.settings._look_index(), 2)
    d.ui_apply(String("settings"), [ui_set(String("look"), String("1"))])
    assert_true(d.config.native_ui)
    assert_false(d.config.platinum_ui)
    d.ui_apply(String("settings"), [ui_set(String("look"), String("0"))])
    assert_false(d.config.native_ui)
    assert_false(d.config.platinum_ui)


def test_platinum_dialogs_go_to_the_host_and_ignore_grid_keys() raises:
    var d = _platinum_desktop(String("x\n"))
    d.fill_dialog.open(2)
    assert_true(d.native_ui_surface_active())
    assert_false(_screen_has(d, String("Fill 2 cursors")))
    _ = d.handle_event(Event.key_event(KEY_ENTER), _SCREEN)
    assert_true(d.fill_dialog.active)
    # Settings opens in the host's window, Platinum-drawn.
    _ = d.dispatch_action(APP_SETTINGS, _SCREEN)
    assert_true(d.settings_native)


def test_platinum_takes_the_confirm_but_leaves_prompts_in_the_grid() raises:
    var d = _platinum_desktop(String("a\nb\n"))
    d.confirm_dialog.open(String("Install rust LSP?"), String("Install"))
    assert_true(d.native_dialog_active())
    assert_false(_screen_has(d, String("Install rust LSP?")))
    _ = d.native_confirm_answer(-1)
    assert_false(d.confirm_dialog.active)
    _ = d.dispatch_action(EDITOR_GOTO, _SCREEN)
    assert_true(d.prompt.active)
    assert_false(d.native_dialog_active())


def test_platinum_tabs_keep_a_gutter_for_the_scroll_bar() raises:
    var d = _platinum_desktop(String("a\nb\n"))
    var canvas = Canvas(_SCREEN.b.x, _SCREEN.b.y)
    canvas.clear(default_attr())
    d.paint(canvas, _SCREEN)
    ref w = d.windows.windows[0]
    assert_true(w.frameless)
    assert_true(w.rect == d.workspace_rect(_SCREEN))
    # Two columns at the right are the host's 16-point scroll bar's.
    assert_equal(w.interior().b.x, w.rect.b.x - 2)
    assert_true(d.tab_bar_rect(_SCREEN).is_empty())
    # The macOS-style UI's overlay scroller needs no gutter.
    d.config.platinum_ui = False
    d.config.native_ui = True
    d.paint(canvas, _SCREEN)
    assert_true(d.windows.windows[0].interior() == d.windows.windows[0].rect)


def test_settings_stay_in_grid_without_native_ui() raises:
    var d = Desktop()
    _ = d.dispatch_action(APP_SETTINGS, _SCREEN)
    assert_true(d.settings.active)
    assert_false(d.settings_native)


def test_native_spelling_sheet_takes_over_the_grid_dialog() raises:
    var d = _native_desktop(String("x\n"))
    d.spelling_dialog.open(List[String](), False)
    assert_true(d.native_spelling_active())
    # Grid input can't reach it behind the sheet.
    _ = d.handle_event(Event.key_event(KEY_ENTER), _SCREEN)
    assert_true(d.spelling_dialog.active)
    d.native_spelling_add(2, List[Int]())   # nothing selected: no-op
    assert_true(d.spelling_dialog.active)
    d.spelling_dialog.close()
    assert_false(d.native_spelling_active())


def test_native_history_selects_and_hides_the_tree_overlay() raises:
    var d = _native_desktop(String("x\n"))
    d.file_tree.visible = True
    assert_true(d.native_tree_shown())
    var es = List[LineHistoryEntry]()
    es.append(LineHistoryEntry(
        String("aaa1111"), String("Ann"), String("2026-10-01"),
        String("first"), String("+a\n"), True,
    ))
    es.append(LineHistoryEntry(
        String("bbb2222"), String("Bo"), String("2026-10-02"),
        String("second"), String("+b\n"), False,
    ))
    d.history.open(String("a.txt"), es^)
    assert_true(d.native_history_active())
    # The source list must not float over the full-screen history.
    assert_false(d.native_tree_shown())
    d.native_history_select(1)
    assert_equal(d.history.list.selected, 1)
    d.history.close()
    assert_true(d.native_tree_shown())


def test_native_merge_applies_only_once_every_change_has_a_choice() raises:
    # Staged the way conflict detection leaves it: the buffer holds local
    # edits, the disk holds the other change, and the editor remembers
    # that disk text as the merge's other side.
    var path = _temp_path(String("_native_merge.txt"))
    _ = write_file(path, String("top\ndisk\n"))
    var d = _native_desktop(String("top\nmine\n"))
    d.windows.windows[0].editor.file_path = path
    d.windows.windows[0].editor._conflict_disk_text = String("top\ndisk\n")
    var regions = List[MergeRegion]()
    regions.append(MergeRegion(
        REGION_STABLE, [String("top")], List[String](), List[String](),
        List[String](),
    ))
    regions.append(MergeRegion(
        REGION_CONFLICT, List[String](), [String("mine")], [String("disk")],
        [String("base")],
    ))
    d.merge_view.open(regions^, 0, path)
    assert_true(d.native_merge_active())
    assert_false(d.native_merge_finish(True, _SCREEN))   # nothing chosen yet
    assert_true(d.merge_view.active)
    d.merge_view.native_choose(0, CHOICE_DISK, List[String]())
    assert_true(d.native_merge_finish(True, _SCREEN))
    assert_false(d.merge_view.active)
    assert_true(String("disk") in d.windows.windows[0].editor.text_snapshot())


def test_native_review_picks_navigates_and_ends() raises:
    var root = _repo_with_a_change()
    var d = _native_desktop(String("x\n"))
    d.project = Optional[String](root)
    d.review.open(root)
    assert_true(d.native_review_picker())
    # The picker is a modal sheet: grid input can't pick behind it.
    _ = d.handle_event(Event.key_event(KEY_ENTER), _SCREEN)
    assert_true(d.native_review_picker())
    d.native_review_pick(0)          # "Unstaged changes"
    assert_true(d.native_review_reviewing())
    assert_equal(d.review.file_count(), 1)
    var p = d.native_review_progress()
    assert_true(p[0] <= p[1])
    d.native_review_close()
    assert_false(d.review.active)


def test_native_settings_language_editor_stacks_on_the_settings_window() raises:
    """Settings ▸ Languages ▸ Add opens the language editor over the
    Settings window (its window stack), and its Save lands an override."""
    var d = _native_desktop(String("x\n"))
    _ = d.dispatch_action(APP_SETTINGS, _SCREEN)
    d.ui_apply(String("settings"), [ui_act(String("lang_add"))])
    assert_equal(len(d.settings_surfaces()), 2)
    assert_false(d.native_ui_surface_active())
    d.ui_apply(String("language_editor"), [
        ui_set(String("language_id"), String("zzlang")),
        ui_set(String("file_types"), String("zz zzz")),
        ui_set(String("command"), String("zz-ls --stdio")),
        ui_act(String("add")),
        ui_act(String("save")),
    ])
    assert_equal(len(d.settings_surfaces()), 1)
    var found = False
    for i in range(len(d.config.language_servers)):
        if d.config.language_servers[i].language_id == String("zzlang"):
            found = True
            assert_equal(len(d.config.language_servers[i].file_types), 2)
    assert_true(found)
    d.ui_apply(String("settings"), [ui_act(String("close"))])
    assert_false(d.settings.active)


def test_native_pane_headers_take_over_the_header_row() raises:
    var d = _native_desktop(String("x\n"))
    var canvas = Canvas(_SCREEN.b.x, _SCREEN.b.y)
    canvas.clear(default_attr())
    d.paint(canvas, _SCREEN)
    assert_true(d.debug_pane.dock.host_chrome)
    d.native_pane_act(DOCK_DEBUG_PANE, 0, 2, String(""))
    assert_true(d.debug_pane.dock.is_minimized())
    d.native_pane_act(DOCK_DEBUG_PANE, 0, 2, String(""))
    assert_false(d.debug_pane.dock.is_minimized())
    d.native_pane_act(DOCK_DEBUG_PANE, 0, 4, String("debug:stop"))
    assert_equal(d.debug_pane.dock.consume_command_id(), String("debug:stop"))
    d.config.native_ui = False
    d.paint(canvas, _SCREEN)
    assert_false(d.debug_pane.dock.host_chrome)


def _row_text(c: Canvas, y: Int) -> String:
    var s = String("")
    for x in range(c.width):
        s += c.get(x, y).glyph
    return s^


def test_native_debug_inspect_hands_the_columns_to_the_host() raises:
    """Under the macOS-style UI the Stack / Locals / Watches cells are
    left blank for the host's tables (``native_rect``), the output log
    starts under them, and a table action stages what a grid click does."""
    var d = _native_desktop(String("x\n"))
    d.debug_pane.visible = True
    d.debug_pane.set_status(String("DAP[x]: stopped"))
    var frames = List[DapStackFrame]()
    frames.append(DapStackFrame(
        7, String("a_rather_long_function_name"), String("/p/a.py"), 3, 0, False,
    ))
    frames.append(DapStackFrame(8, String("main"), String("/p/a.py"), 9, 0, True))
    var locals = List[DapVariable]()
    locals.append(DapVariable(String("obj"), String("<Obj>"), String("Obj"), 42))
    d.debug_pane.rebuild_inspect(
        frames^, String("Locals"), locals^, String("Watches"),
        [String("len(x) = 3")], 0,
    )
    d.debug_pane.append_output(String("hello from the log"))
    var canvas = Canvas(_SCREEN.b.x, _SCREEN.b.y)
    canvas.clear(default_attr())
    d.paint(canvas, _SCREEN)
    assert_true(d.debug_pane.host_inspect)
    var r = d.debug_pane.native_rect
    assert_false(r.is_empty())
    # Nothing of the columns or the status is painted under the host's view.
    for y in range(r.a.y, r.b.y):
        var row = _row_text(canvas, y)
        assert_equal(row.find(String("main")), -1)
        assert_equal(row.find(String("obj")), -1)
        assert_equal(row.find(String("stopped")), -1)
    # The log follows right under it.
    assert_true(_row_text(canvas, r.b.y).find(String("hello from the log")) >= 0)
    # Frames keep their whole name for the native table.
    assert_equal(d.debug_pane.rows[1].type_name, String("a_rather_long_function_name"))
    # Select the second frame, expand obj, remove the watch, add one.
    d.native_debug_act(0, 2, String(""))
    assert_equal(d.debug_pane.pending_frame_id, 8)
    assert_true(d.debug_pane.focused)
    var obj_row = -1
    var watch_row = -1
    for i in range(len(d.debug_pane.rows)):
        if d.debug_pane.rows[i].text.startswith(String("obj")):
            obj_row = i
        if d.debug_pane.rows[i].text.startswith(String("len(x)")):
            watch_row = i
    d.native_debug_act(0, obj_row, String(""))     # op 0 only selects frames
    assert_equal(d.debug_pane.pending_expand_ref, -1)
    d.native_debug_act(1, obj_row, String(""))
    assert_equal(d.debug_pane.pending_expand_ref, 42)
    d.native_debug_act(2, watch_row, String(""))
    assert_equal(d.debug_pane.pending_remove_watch, 0)
    d.native_debug_act(3, -1, String("y + 1"))
    assert_equal(d._dap_watch_exprs[len(d._dap_watch_exprs) - 1], String("y + 1"))
    # Floating panels: the panel window's paint hands them over too.
    d.panels_detached = True
    canvas.clear(default_attr())
    d.paint_panels(canvas, _SCREEN)
    assert_true(d.debug_pane.dock.host_chrome)
    assert_true(d.debug_pane.host_inspect)
    assert_false(d.debug_pane.native_rect.is_empty())
    d.panels_detached = False
    # Retro: the grid paints the columns again.
    d.config.native_ui = False
    canvas.clear(default_attr())
    d.paint(canvas, _SCREEN)
    assert_true(d.debug_pane.native_rect.is_empty())
    var seen = False
    for y in range(canvas.height):
        if _row_text(canvas, y).find(String("y + 1 =")) >= 0:
            seen = True
    assert_true(seen)


def test_native_project_settings_edit_through_the_sections_and_sync() raises:
    var root = _repo_with_a_change()
    var d = _native_desktop(String("x\n"))
    d.open_project(root)
    _ = d.dispatch_action(PROJECT_SETTINGS, _SCREEN)
    assert_true(d.project_settings.active)
    assert_true(d.native_ui_surface_active())
    assert_equal(d.ui_surface(), String("project_settings"))
    var name = String("project_settings")
    d.ui_apply(name, [ui_act(String("tg_add"))])
    d.ui_apply(name, [
        ui_set(String("tg_name"), String("app")),
        ui_set(String("tg_program"), String("python3")),
        ui_set(String("tg_args"), String("main.py --fast")),
        ui_set(String("tg_env"), String("A=1")),
    ])
    d.ui_apply(name, [ui_act(String("gr_add")), ui_set(String("gr_ext"), String("tmpl"))])
    var opts = grammar_options()
    var html = 0
    for k in range(len(opts)):
        if opts[k] == String("html"):
            html = k
    d.ui_apply(name, [ui_set(String("gr_lang"), String(html))])
    # Add opens the action editor on top; its Save lands in the library.
    d.ui_apply(name, [ui_act(String("os_add"))])
    assert_equal(len(d.ui_surfaces()), 2)
    assert_equal(d.ui_surface(), String("action_editor"))
    d.ui_apply(String("action_editor"), [
        ui_set(String("program"), String("/bin/echo")),
        ui_set(String("args"), String("hi")),
        ui_act(String("save")),
    ])
    assert_equal(d.ui_surface(), String("project_settings"))
    d.ui_apply(name, [ui_act(String("close"))])   # syncs, then closes
    assert_false(d.project_settings.active)
    var found = False
    for k in range(len(d.targets.targets)):
        if d.targets.targets[k].name == String("app"):
            found = True
            assert_equal(len(d.targets.targets[k].args), 2)
    assert_true(found)
    var mapped = False
    for k in range(len(d.grammar_registry.overrides)):
        if d.grammar_registry.overrides[k].ext == String("tmpl"):
            mapped = True
    assert_true(mapped)
    assert_true(len(d.project_on_save) >= 1)


def main() raises:
    setup_test_env()
    TestSuite.discover_tests[__functions_in_module()]().run()
