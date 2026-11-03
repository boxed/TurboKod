"""Terminal and run panes on tmux (``tmux_session.mojo``): readable
session names, re-attaching a project's panes after a close/reopen, and
run panes that report their exit. The live tests need tmux and skip
without it; ``setup_test_env`` points ``TMUX_TMPDIR`` at the scratch
``$HOME``, so they run a server of their own, never the user's."""

from std.collections.list import List
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from turbokod.canvas import Canvas
from turbokod.desktop import Desktop
from turbokod.events import (
    Event, MOUSE_BUTTON_LEFT, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from turbokod.geometry import Point, Rect
from turbokod.lsp import capture_command
from turbokod.posix import getenv_value, setenv_value, sleep_ms
from turbokod.project_targets import RunTarget
from turbokod.tmux_session import (
    new_tmux_session_name, prepare_tmux_socket_dir, tmux_pane_state, tmux_available,
    tmux_binary, tmux_history, tmux_kill_session, tmux_kind, tmux_project_sessions,
    tmux_respawn, tmux_session_names, tmux_socket_path, tmux_stop,
)

from support import _ensure_dir, _rm_rf, _temp_path, _test_home, setup_test_env


def _tmux_sessions_settle(mut d: Desktop, root: String, want: Int) -> Int:
    """Tick ``d``'s panes until ``root`` has ``want`` tmux sessions (the
    client creates its session asynchronously), up to ~5 s."""
    var n = len(tmux_project_sessions(root))
    var waited = 0
    while n != want and waited < 5000:
        d.terminal_tick()
        sleep_ms(20)
        waited += 20
        n = len(tmux_project_sessions(root))
    return n

def _pane_shows(mut d: Desktop, needle: String) -> Bool:
    """Tick until terminal pane 0's grid contains ``needle``, up to ~5 s."""
    var waited = 0
    while waited < 5000:
        d.terminal_tick()
        var rows = d.terminal_panes[0].vt.tail_rows(24)
        for i in range(len(rows)):
            if needle in rows[i]:
                return True
        sleep_ms(20)
        waited += 20
    return False

def test_tmux_names() raises:
    assert_equal(tmux_kind(String("claude"), String("")), String("claude"))
    assert_equal(tmux_kind(String("npm run dev"), String("")), String("npm"))
    assert_equal(tmux_kind(String(""), String("")), String("shell"))
    assert_equal(tmux_kind(String("x"), String("server")), String("run-server"))
    var none = List[String]()
    assert_equal(
        new_tmux_session_name(String("/p/turbokod"), String("claude"), none),
        String("turbokod-claude"),
    )
    assert_equal(
        new_tmux_session_name(String("/p/turbokod/"), String("shell"), none),
        String("turbokod-shell"),
    )
    # tmux forbids ``.`` and ``:``; spaces would need quoting.
    assert_equal(
        new_tmux_session_name(String("/p/my app.v2"), String("run-dev server"), none),
        String("my-app-v2-run-dev-server"),
    )
    var taken = List[String]()
    taken.append(String("turbokod-claude"))
    taken.append(String("turbokod-claude-2"))
    assert_equal(
        new_tmux_session_name(String("/p/turbokod"), String("claude"), taken),
        String("turbokod-claude-3"),
    )

def test_tmux_panes_reattach() raises:
    """A terminal pane runs in a tmux session filed under its project:
    closing the project (as quitting the app does) only detaches, opening
    it again re-attaches the same session with its startup command, and
    closing the pane ends the session. Skipped without tmux; the server is
    the scratch $HOME's own (``setup_test_env`` sets ``TMUX_TMPDIR``)."""
    if not tmux_available():
        return
    # Never the user's server: ``setup_test_env`` moved TMUX_TMPDIR.
    assert_true(tmux_socket_path().startswith(_test_home()))
    var root = _temp_path(String("_tmux_panes"))
    _rm_rf(root)
    _ensure_dir(root)
    var d = Desktop()
    d.config.terminal_tmux = True
    d.open_project(root)
    var canonical = d.project.value()
    assert_equal(len(d.terminal_panes), 0)
    d._open_terminal_pane(String("echo tk-marker"))
    assert_equal(len(d.terminal_panes), 1)
    assert_true(d.terminal_panes[0].is_tmux())
    var name = d.terminal_panes[0].tmux_session
    # Readable: the project dir plus the command's first word.
    assert_true(name.endswith("_tmux_panes-echo"))
    assert_equal(_tmux_sessions_settle(d, canonical, 1), 1)
    # The client stays attached and draws the session: the typed startup
    # command's output reaches the pane's grid.
    assert_true(_pane_shows(d, String("tk-marker")))
    assert_true(d.terminal_panes[0].pty.alive)

    d.close_project()
    assert_equal(len(d.terminal_panes), 0)
    var still = tmux_project_sessions(canonical)
    assert_equal(len(still), 1)
    assert_equal(still[0].name, name)
    assert_equal(still[0].startup_command, String("echo tk-marker"))
    # Found without a locale too, as in an app launched from the Dock: tmux
    # then prints the listing's tab separators as ``_`` unless told ``-u``.
    var saved = List[String]()
    for v in [String("LC_ALL"), String("LC_CTYPE"), String("LANG")]:
        saved.append(getenv_value(v))
        _ = setenv_value(v, String(""))
    var bare = tmux_project_sessions(canonical)
    var k = 0
    for v in [String("LC_ALL"), String("LC_CTYPE"), String("LANG")]:
        _ = setenv_value(v, saved[k])
        k += 1
    assert_equal(len(bare), 1)
    assert_equal(bare[0].name, name)

    d.open_project(root)
    assert_equal(len(d.terminal_panes), 1)
    assert_equal(d.terminal_panes[0].tmux_session, name)
    assert_equal(d.terminal_panes[0].startup_command, String("echo tk-marker"))
    assert_false(d.terminal_panes[0].focused)
    # Re-attached, the session's screen comes back.
    assert_true(_pane_shows(d, String("tk-marker")))

    d.terminal_panes[0].dock.request_close()
    d.terminal_tick()
    assert_equal(len(d.terminal_panes), 0)
    assert_equal(len(tmux_project_sessions(canonical)), 0)

    var kill = List[String]()
    kill.append(tmux_binary())
    kill.append(String("-S"))
    kill.append(tmux_socket_path())
    kill.append(String("kill-server"))
    _ = capture_command(kill)
    d.shutdown()
    _rm_rf(root)

def test_tmux_keeps_a_trailing_semicolon() raises:
    # tmux took a ";" ending an argument as the end of the command: a
    # startup command "echo x;" was kept, and typed, as "echo x"
    if not tmux_available():
        return
    assert_true(tmux_socket_path().startswith(_test_home()))
    var root = _temp_path(String("_tmux_semi"))
    _rm_rf(root)
    _ensure_dir(root)
    var d = Desktop()
    d.config.terminal_tmux = True
    d.open_project(root)
    var canonical = d.project.value()
    d._open_terminal_pane(String("echo tk-semi;"))
    assert_equal(_tmux_sessions_settle(d, canonical, 1), 1)
    assert_true(_pane_shows(d, String("tk-semi")))
    var sessions = tmux_project_sessions(canonical)
    assert_equal(sessions[0].startup_command, String("echo tk-semi;"))
    d.close_project()
    var kill = List[String]()
    kill.append(tmux_binary())
    kill.append(String("-S"))
    kill.append(tmux_socket_path())
    kill.append(String("kill-server"))
    _ = capture_command(kill)
    d.shutdown()
    _rm_rf(root)


def _tmux(var words: List[String]) raises -> String:
    var argv = List[String]()
    argv.append(tmux_binary())
    argv.append(String("-S"))
    argv.append(tmux_socket_path())
    for i in range(len(words)):
        argv.append(words[i])
    return capture_command(argv).stdout


def test_tmux_commands_reach_only_their_own_session() raises:
    # a bare -t name falls back to the first session it starts: with
    # tk-gone gone, closing its pane killed tk-gone-2
    if not tmux_available():
        return
    assert_true(tmux_socket_path().startswith(_test_home()))
    prepare_tmux_socket_dir(tmux_socket_path())
    _ = _tmux([String("-f"), String("/dev/null"), String("new-session"), String("-d"), String("-s"), String("tk-gone-2")])
    tmux_kill_session(String("tk-gone"))
    tmux_stop(String("tk-gone"))
    tmux_respawn(String("tk-gone"))
    assert_equal(tmux_history(String("tk-gone"), 10), String("\x1b[0m"))
    assert_equal(tmux_session_names(), [String("tk-gone-2")])
    tmux_kill_session(String("tk-gone-2"))
    assert_equal(len(tmux_session_names()), 0)
    _ = _tmux([String("kill-server")])


def _run_pane_settles(mut d: Desktop, idx: Int) -> Bool:
    """Tick until run pane ``idx`` has seen its process exit, up to ~5 s."""
    var waited = 0
    while waited < 5000:
        d.terminal_tick()
        if d.terminal_panes[idx].run_exited:
            return True
        sleep_ms(20)
        waited += 20
    return False

def test_tmux_run_pane() raises:
    """Cmd+R with tmux runs the target as its session's process: the env
    and args arrive, the exit status is read off tmux's exit line, the
    dead pane stays (with its output) across a project close/reopen, and
    Restart runs it again in the same session."""
    if not tmux_available():
        return
    assert_true(tmux_socket_path().startswith(_test_home()))
    var root = _temp_path(String("_tmux_run"))
    _rm_rf(root)
    _ensure_dir(root)
    var d = Desktop()
    d.config.terminal_tmux = True
    d.open_project(root)
    var canonical = d.project.value()
    var t = RunTarget()
    t.name = String("job")
    t.program = String("/bin/sh")
    t.args.append(String("-c"))
    t.args.append(String("echo got-$TK_X-$0; exit 3"))
    t.args.append(String("it's"))
    t.env.append(String("TK_X=yes"))
    d._target_run_in_tmux(t)
    assert_equal(len(d.terminal_panes), 1)
    assert_true(d.terminal_panes[0].is_run())
    assert_false(d.terminal_panes[0].focused)
    assert_true(d.terminal_panes[0].tmux_session.endswith("_tmux_run-run-job"))
    assert_true(_run_pane_settles(d, 0))
    assert_equal(d.terminal_panes[0].run_exit_status, String("3"))
    assert_true(_pane_shows(d, String("got-yes-it's")))

    d.close_project()
    assert_equal(len(d.terminal_panes), 0)
    d.open_project(root)
    assert_equal(len(d.terminal_panes), 1)
    assert_equal(d.terminal_panes[0].run_target, String("job"))
    # Re-attached to the dead pane: its exit line is read back.
    assert_true(_run_pane_settles(d, 0))
    assert_equal(d.terminal_panes[0].run_exit_status, String("3"))

    d.terminal_panes[0].respawn()
    assert_false(d.terminal_panes[0].run_exited)
    assert_true(_run_pane_settles(d, 0))
    assert_equal(d.terminal_panes[0].run_exit_status, String("3"))

    d.terminal_panes[0].dock.request_close()
    d.terminal_tick()
    assert_equal(len(d.terminal_panes), 0)
    assert_equal(len(tmux_project_sessions(canonical)), 0)
    var kill = List[String]()
    kill.append(tmux_binary())
    kill.append(String("-S"))
    kill.append(tmux_socket_path())
    kill.append(String("kill-server"))
    _ = capture_command(kill)
    d.shutdown()
    _rm_rf(root)


def test_tmux_run_stop_and_restart() raises:
    """Stop is a Ctrl-C: the target dies, the pane stays and reports it.
    Restart runs it again, and the previous run's exit line on screen isn't
    taken for this run's."""
    if not tmux_available():
        return
    var root = _temp_path(String("_tmux_stop"))
    _rm_rf(root)
    _ensure_dir(root)
    var d = Desktop()
    d.config.terminal_tmux = True
    d.open_project(root)
    var t = RunTarget()
    t.name = String("server")
    t.program = String("/bin/sleep")
    t.args.append(String("30"))
    d._target_run_in_tmux(t)
    # Running, and still running a moment later.
    for _ in range(25):
        d.terminal_tick()
        sleep_ms(20)
    assert_true(d.terminal_panes[0].is_running())
    d._stop_debug_and_run()
    assert_true(_run_pane_settles(d, 0))
    assert_equal(d.terminal_panes[0].run_exit_status, String("130"))
    assert_equal(len(d.terminal_panes), 1)

    d.terminal_panes[0].respawn()
    for _ in range(50):
        d.terminal_tick()
        sleep_ms(20)
    assert_true(d.terminal_panes[0].is_running())

    d.terminal_panes[0].dock.request_close()
    d.terminal_tick()
    var kill = List[String]()
    kill.append(tmux_binary())
    kill.append(String("-S"))
    kill.append(tmux_socket_path())
    kill.append(String("kill-server"))
    _ = capture_command(kill)
    d.shutdown()
    _rm_rf(root)


def test_tmux_test_run() raises:
    """Cmd+T with tmux runs the tests as their own session's process: a
    restart of the app (a project close/reopen) re-attaches the pane as a
    test run, and a target's run and Stop leave the tests alone."""
    if not tmux_available():
        return
    var root = _temp_path(String("_tmux_tests"))
    _rm_rf(root)
    _ensure_dir(root)
    var d = Desktop()
    d.config.terminal_tmux = True
    d.open_project(root)
    var canonical = d.project.value()
    var args = List[String]()
    args.append(String("-c"))
    args.append(String("sleep 1; echo 'File \"x.py\", line 3'; exit 1"))
    d._target_test_in_tmux(String("/bin/sh"), args, canonical)
    assert_equal(len(d.terminal_panes), 1)
    assert_true(d.terminal_panes[0].tests)
    assert_false(d.terminal_panes[0].focused)
    assert_true(d.terminal_panes[0].tmux_session.endswith("_tmux_tests-tests"))
    assert_equal(d.terminal_panes[0].header_title(), String("Tests — running"))
    # A target's run, and Stop, are the target's business.
    var t = RunTarget()
    t.name = String("tests")
    t.program = String("/bin/sleep")
    t.args.append(String("30"))
    d._target_run_in_tmux(t)
    assert_equal(len(d.terminal_panes), 2)
    assert_false(d.terminal_panes[1].tests)
    d._stop_debug_and_run()
    assert_true(_run_pane_settles(d, 0))
    assert_equal(d.terminal_panes[0].run_exit_status, String("1"))
    assert_equal(d.terminal_panes[0].header_title(), String("Tests — failed (1)"))

    d.close_project()
    assert_equal(len(d.terminal_panes), 0)
    d.open_project(root)
    assert_equal(len(d.terminal_panes), 2)
    var ti = 0 if d.terminal_panes[0].tests else 1
    assert_true(d.terminal_panes[ti].tests)
    assert_false(d.terminal_panes[1 - ti].tests)
    assert_true(_run_pane_settles(d, ti))
    assert_equal(d.terminal_panes[ti].header_title(), String("Tests — failed (1)"))

    var kill = List[String]()
    kill.append(tmux_binary())
    kill.append(String("-S"))
    kill.append(tmux_socket_path())
    kill.append(String("kill-server"))
    _ = capture_command(kill)
    d.shutdown()
    _rm_rf(root)


def test_tmux_pane_scrolls_and_selects_itself() raises:
    """Wheel and drag in a tmux pane stay turbokod's: scrolling shows a
    capture of tmux's history with the pane's own scroll bar, and a drag
    selects without copying — tmux's copy mode (selection that copies on
    release, a ``[0/123]`` indicator) never starts. The bar shows at the
    bottom too, in a column of its own."""
    if not tmux_available():
        return
    var root = _temp_path(String("_tmux_scroll"))
    _rm_rf(root)
    _ensure_dir(root)
    var d = Desktop()
    d.config.terminal_tmux = True
    d.open_project(root)
    d._open_terminal_pane(String("seq 1 200"))
    var panel = Rect(0, 0, 60, 16)
    var canvas = Canvas(60, 16)
    d.terminal_panes[0].paint(canvas, panel)
    assert_true(_pane_shows(d, String("200")))
    var name = d.terminal_panes[0].tmux_session
    # The shell has no mouse mode on; tmux itself tracks the mouse.
    var state = tmux_pane_state(name)
    assert_false(state.wants_mouse)
    assert_true(state.history_rows > 100)
    assert_true(d.terminal_panes[0].vt.tracks_mouse())

    # At the bottom the bar is already there, sized by tmux's history.
    for _ in range(60):
        d.terminal_tick()
        sleep_ms(20)
    d.terminal_panes[0].paint(canvas, panel)
    assert_true(d.terminal_panes[0].scroll_bar.bar.metrics().present)
    # It takes the right column; the grid is one narrower.
    assert_equal(d.terminal_panes[0].vt.cols(), 59)

    var up = Event.mouse_event(Point(5, 8), MOUSE_WHEEL_UP, True, False)
    _ = d.terminal_panes[0].handle_mouse(up, panel)
    assert_true(d.terminal_panes[0]._history_on)
    assert_equal(d.terminal_panes[0].history.view_offset(), 3)
    assert_true(d.terminal_panes[0].history.scrollback_rows() > 100)
    d.terminal_panes[0].paint(canvas, panel)
    assert_true(d.terminal_panes[0].scroll_bar.bar.metrics().present)

    _ = d.terminal_panes[0].handle_mouse(
        Event.mouse_event(Point(0, 4), MOUSE_BUTTON_LEFT, True, False), panel,
    )
    _ = d.terminal_panes[0].handle_mouse(
        Event.mouse_event(Point(2, 5), MOUSE_BUTTON_LEFT, True, True), panel,
    )
    _ = d.terminal_panes[0].handle_mouse(
        Event.mouse_event(Point(2, 5), MOUSE_BUTTON_LEFT, False, False), panel,
    )
    assert_true(d.terminal_panes[0].has_selection())
    assert_true(len(d.terminal_panes[0].selected_text().as_bytes()) > 0)

    var down = Event.mouse_event(Point(5, 8), MOUSE_WHEEL_DOWN, True, False)
    _ = d.terminal_panes[0].handle_mouse(down, panel)
    assert_false(d.terminal_panes[0]._history_on)
    d.terminal_panes[0].paint(canvas, panel)
    assert_true(d.terminal_panes[0].scroll_bar.bar.metrics().present)

    # A drag on the live screen selects in the pane, too.
    _ = d.terminal_panes[0].handle_mouse(
        Event.mouse_event(Point(0, 4), MOUSE_BUTTON_LEFT, True, False), panel,
    )
    _ = d.terminal_panes[0].handle_mouse(
        Event.mouse_event(Point(2, 5), MOUSE_BUTTON_LEFT, True, True), panel,
    )
    _ = d.terminal_panes[0].handle_mouse(
        Event.mouse_event(Point(2, 5), MOUSE_BUTTON_LEFT, False, False), panel,
    )
    assert_true(d.terminal_panes[0].has_selection())
    var mode = List[String]()
    mode.append(tmux_binary())
    mode.append(String("-S"))
    mode.append(tmux_socket_path())
    mode.append(String("display-message"))
    mode.append(String("-p"))
    mode.append(String("-t"))
    mode.append(name)
    mode.append(String("#{pane_in_mode}"))
    assert_equal(capture_command(mode).stdout, String("0\n"))

    d.terminal_panes[0].dock.request_close()
    d.terminal_tick()
    var kill = List[String]()
    kill.append(tmux_binary())
    kill.append(String("-S"))
    kill.append(tmux_socket_path())
    kill.append(String("kill-server"))
    _ = capture_command(kill)
    d.shutdown()
    _rm_rf(root)


def main() raises:
    setup_test_env()
    TestSuite.discover_tests[__functions_in_module()]().run()
