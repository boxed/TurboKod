"""The macOS-style UI (View ▸ macOS-style UI): the core keeps owning a dialog's
state and submit path, but hands its display to the host as a native sheet.
These pin the core half — what counts as native, that nothing in-grid can
answer a dialog the host is showing, and that a native answer runs the same
handler a click on the in-grid button would."""

from std.testing import TestSuite, assert_equal, assert_false, assert_true
from turbokod.canvas import Canvas
from turbokod.colors import default_attr
from turbokod.desktop import (
    Desktop, EDITOR_FIND, EDITOR_GOTO, VIEW_NATIVE_UI,
)
from turbokod.events import Event, KEY_ENTER
from turbokod.geometry import Rect
from turbokod.window import Window
from support import _SCREEN, setup_test_env


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
    assert_false(d.native_dialogs())   # terminal frontend: always in-grid
    d.host_owns_menu = True
    assert_true(d.native_dialogs())


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


def test_find_stays_in_grid_but_go_to_line_is_native() raises:
    var d = _native_desktop(String("a\nb\nc\nd\n"))
    _ = d.dispatch_action(EDITOR_FIND, _SCREEN)
    assert_true(d.prompt.active)
    assert_false(d.native_dialog_active())
    d.prompt.close()
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


def main() raises:
    setup_test_env()
    TestSuite.discover_tests[__functions_in_module()]().run()
