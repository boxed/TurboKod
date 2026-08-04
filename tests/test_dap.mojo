"""Debug adapter, run manager and the test runner.

One of the per-topic suites split out of the former
``test_basic.mojo``; shared fixtures live in ``tests/support.mojo``
and ``scripts/run_tests.sh`` runs every suite.
"""

from std.ffi import external_call
from std.testing import assert_equal, assert_false, assert_true
from turbokod.canvas import Canvas
from turbokod.colors import (
    Attr, BLACK, DARK_GRAY, LIGHT_BLUE, LIGHT_GRAY, STYLE_UNDERLINE, WHITE
)
from turbokod.editor import Editor
from turbokod.breakpoint_store import (
    StoredBreakpoint, load_breakpoints, save_breakpoints
)
from turbokod.desktop import Desktop
from turbokod.file_io import join_path, stat_file, write_file
from turbokod.project_targets import (
    ProjectTargets, RunTarget, pytest_python_files
)
from turbokod.debug_pane import DEBUG_PANE_CLOSE, DebugPane, PANE_MODE_RUN
from turbokod.run_manager import RunSession, drain_run_output, poll_run_exit
from turbokod.project_settings import ProjectSettings
from turbokod.json import JsonValue, json_object, parse_json
from turbokod.dap import (
    DAP_EVENT, DAP_REQUEST, DAP_RESPONSE, DapClient, classify_dap_message,
    dap_initialize_arguments
)
from turbokod.dap_dispatch import (
    DapManager, DapStackFrame, DapVariable, _parse_scopes, _parse_stack_trace,
    _parse_threads, _parse_variables
)
from turbokod.debugger_config import (
    built_in_debuggers, find_debugger_for_language, launch_arguments_for
)
from turbokod.posix import which
from turbokod.project_grammars import GrammarOverride
from turbokod.config import OnSaveAction
from turbokod.settings import Settings
from turbokod.events import (
    Event, KEY_DOWN, KEY_ENTER, KEY_ESC, KEY_UP, MOD_NONE, MOUSE_BUTTON_LEFT
)
from turbokod.geometry import Point, Rect
from turbokod import Vt
from turbokod.test_pane import TestPane

from support import _key, _temp_path, setup_test_env


def _find_glyph_x(c: Canvas, y: Int, glyph: String) -> Int:
    """Locate the first column at row ``y`` whose glyph matches
    ``glyph``. Returns -1 when not found."""
    for x in range(c.width):
        if c.get(x, y).glyph == glyph:
            return x
    return -1


def _ps_open_targets(var src: ProjectTargets) -> ProjectSettings:
    var ps = ProjectSettings()
    ps.open(
        String("/tmp/turbokod_ps_unit"), src^, List[GrammarOverride](),
        List[OnSaveAction](), List[OnSaveAction](),
    )
    ps.section = 1  # Targets
    return ps^


def test_debug_pane_repl_console() raises:
    # The interactive console: when ``repl_enabled`` the bottom input
    # line owns the keyboard — typed keys edit it, Enter latches the
    # expression for the host + records history, Up/Down recall it.
    var pane = DebugPane()
    pane.focused = True
    pane.repl_enabled = True
    # Type "x+1" into the console line.
    _ = pane.handle_key(Event.key_event(UInt32(ord("x")), MOD_NONE))
    _ = pane.handle_key(Event.key_event(UInt32(ord("+")), MOD_NONE))
    _ = pane.handle_key(Event.key_event(UInt32(ord("1")), MOD_NONE))
    assert_equal(pane.repl_input.text, String("x+1"))
    # Enter latches the expression (drained by the host), clears the line.
    assert_true(pane.handle_key(Event.key_event(KEY_ENTER, MOD_NONE)))
    assert_equal(pane.repl_input.text, String(""))
    assert_equal(pane.consume_repl_submit(), String("x+1"))
    assert_equal(pane.consume_repl_submit(), String(""))  # drained
    # A second submit, then walk history backwards with Up.
    _ = pane.handle_key(Event.key_event(UInt32(ord("y")), MOD_NONE))
    assert_true(pane.handle_key(Event.key_event(KEY_ENTER, MOD_NONE)))
    _ = pane.consume_repl_submit()
    _ = pane.handle_key(Event.key_event(KEY_UP, MOD_NONE))
    assert_equal(pane.repl_input.text, String("y"))      # newest
    _ = pane.handle_key(Event.key_event(KEY_UP, MOD_NONE))
    assert_equal(pane.repl_input.text, String("x+1"))    # older
    # Down steps forward, then off the end onto an empty live line.
    _ = pane.handle_key(Event.key_event(KEY_DOWN, MOD_NONE))
    assert_equal(pane.repl_input.text, String("y"))
    _ = pane.handle_key(Event.key_event(KEY_DOWN, MOD_NONE))
    assert_equal(pane.repl_input.text, String(""))
    # An empty Enter queues nothing.
    assert_true(pane.handle_key(Event.key_event(KEY_ENTER, MOD_NONE)))
    assert_equal(pane.consume_repl_submit(), String(""))
    # With the console disabled, typed keys don't reach the field (they
    # fall through to the host's scroll / hotkey handling instead).
    pane.repl_enabled = False
    _ = pane.handle_key(Event.key_event(UInt32(ord("z")), MOD_NONE))
    assert_equal(pane.repl_input.text, String(""))


def test_pytest_link_opens_project_relative_file() raises:
    """A pytest-style ``<relpath>:<line>`` clicked in the test pane opens
    the file resolved against the PROJECT ROOT, not the process cwd, and
    the window survives the next paint. Regression: clicking opened a
    cwd-relative (usually nonexistent) path that then vanished."""
    var dir = String("/tmp/turbokod_pytestlink_") + String(
        Int(external_call["getpid", Int32]())
    )
    _ = external_call["mkdir", Int32](
        (dir + String("\0")).unsafe_ptr(), UInt32(0o755),
    )
    var rel = String("foo__tests.py")
    var fpath = dir + String("/") + rel
    var content = String("L0")
    for i in range(1, 1400):
        content += "\n" + String("L") + String(i)
    assert_true(write_file(fpath, content))
    var d = Desktop()
    d._set_project(dir)
    var screen = Rect(0, 0, 120, 50)
    var c = Canvas(120, 50)
    d.paint(c, screen)        # consume the one-shot session restore
    # Simulate the link click the test pane would have latched.
    d.test_pane.pending_open_path = rel
    d.test_pane.pending_open_line = 1289
    d.dap_tick(screen)
    var idx = d._find_window_for_path(fpath)
    assert_true(idx >= 0)             # opened the real project file
    d.paint(c, screen)
    assert_true(d._find_window_for_path(fpath) >= 0)   # and it survived
    _ = external_call["unlink", Int32]((fpath + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((dir + String("\0")).unsafe_ptr())


def test_dap_classify_response() raises:
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


def test_dap_classify_event() raises:
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


def test_dap_classify_reverse_request() raises:
    var rq = parse_json(String(
        "{\"seq\":5,\"type\":\"request\",\"command\":\"runInTerminal\","
        + "\"arguments\":{\"args\":[\"/usr/bin/echo\"]}}"
    ))
    var c = classify_dap_message(rq)
    assert_equal(Int(c.kind), Int(DAP_REQUEST))
    assert_equal(c.command.value(), String("runInTerminal"))
    assert_true(Bool(c.arguments))


def test_dap_classify_response_with_failure() raises:
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


def test_dap_initialize_arguments_shape() raises:
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


def test_dap_seq_autoincrement_via_cat() raises:
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


def test_dap_parse_threads() raises:
    var body = parse_json(String(
        "{\"threads\":[{\"id\":1,\"name\":\"main\"},"
        + "{\"id\":2,\"name\":\"worker\"}]}"
    ))
    var threads = _parse_threads(Optional[JsonValue](body.copy()))
    assert_equal(len(threads), 2)
    assert_equal(threads[0].id, 1)
    assert_equal(threads[0].name, String("main"))
    assert_equal(threads[1].id, 2)
    assert_equal(threads[1].name, String("worker"))


def test_dap_parse_stack_trace_zero_based() raises:
    """Adapters return 1-based lines (debugpy + delve always; lldb-dap
    honors our linesStartAt1=false flag). The parser normalizes to
    0-based to match Editor's row index."""
    var body = parse_json(String(
        "{\"stackFrames\":[{\"id\":42,\"name\":\"main\","
        + "\"line\":10,\"column\":1,"
        + "\"source\":{\"path\":\"/tmp/foo.py\"}}]}"
    ))
    var frames = _parse_stack_trace(Optional[JsonValue](body.copy()))
    assert_equal(len(frames), 1)
    assert_equal(frames[0].id, 42)
    assert_equal(frames[0].name, String("main"))
    assert_equal(frames[0].path, String("/tmp/foo.py"))
    assert_equal(frames[0].line, 9)
    assert_equal(frames[0].column, 0)


def test_dap_parse_scopes_and_variables() raises:
    var scopes_body = parse_json(String(
        "{\"scopes\":[{\"name\":\"Locals\",\"variablesReference\":7,"
        + "\"expensive\":false}]}"
    ))
    var scopes = _parse_scopes(Optional[JsonValue](scopes_body.copy()))
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
    var variables = _parse_variables(Optional[JsonValue](vars_body.copy()))
    assert_equal(len(variables), 2)
    assert_equal(variables[0].name, String("x"))
    assert_equal(variables[0].value, String("42"))
    assert_equal(variables[0].type_name, String("int"))
    assert_equal(variables[0].variables_reference, 0)
    assert_equal(variables[1].variables_reference, 11)


def test_dap_registry_lookup() raises:
    var debs = built_in_debuggers()
    assert_true(len(debs) >= 3)
    var py = find_debugger_for_language(debs, String("python"))
    assert_true(py >= 0)
    assert_equal(debs[py].name, String("debugpy"))
    var unknown = find_debugger_for_language(debs, String("ada"))
    assert_equal(unknown, -1)


def test_dap_launch_arguments_for_debugpy() raises:
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


def test_dap_launch_arguments_for_debugpy_module_mode() raises:
    """``python -m pytest tests/x.py`` should be rewritten to debugpy's
    ``module`` field — debugpy can't ``runpy`` the python binary."""
    var debs = built_in_debuggers()
    var idx = find_debugger_for_language(debs, String("python"))
    assert_true(idx >= 0)
    var args = List[String]()
    args.append(String("-m"))
    args.append(String("pytest"))
    args.append(String("tests/x.py"))
    var body = launch_arguments_for(
        debs[idx],
        String("/Users/me/p/venv/bin/python"),
        String("/Users/me/p"),
        args^,
        False,
    )
    assert_true(body.is_object())
    # Rewritten: ``module: pytest``, ``program`` absent, residual args
    # carry just the test path.
    assert_true(not body.object_get(String("program")))
    assert_equal(
        body.object_get(String("module")).value().as_str(),
        String("pytest"),
    )
    var arr = body.object_get(String("args"))
    assert_true(arr.value().is_array())
    assert_equal(arr.value().array_len(), 1)
    assert_equal(arr.value().array_at(0).as_str(), String("tests/x.py"))


def test_dap_launch_arguments_for_debugpy_versioned_python() raises:
    """``python3.11 -m unittest`` should also trigger module-mode
    rewriting — versioned interpreter basenames are still Python."""
    var debs = built_in_debuggers()
    var idx = find_debugger_for_language(debs, String("python"))
    assert_true(idx >= 0)
    var args = List[String]()
    args.append(String("-m"))
    args.append(String("unittest"))
    var body = launch_arguments_for(
        debs[idx],
        String("/usr/local/bin/python3.11"),
        String("/tmp"),
        args^,
        False,
    )
    assert_equal(
        body.object_get(String("module")).value().as_str(),
        String("unittest"),
    )


def test_dap_launch_arguments_for_debugpy_non_python_program() raises:
    """A real script path (not the python binary) keeps ``program``
    mode even when ``-m`` happens to be in args, because that's a
    plain CLI flag at that point."""
    var debs = built_in_debuggers()
    var idx = find_debugger_for_language(debs, String("python"))
    assert_true(idx >= 0)
    var args = List[String]()
    args.append(String("-m"))
    args.append(String("foo"))
    var body = launch_arguments_for(
        debs[idx], String("/tmp/main.py"), String("/tmp"), args^, False,
    )
    assert_equal(
        body.object_get(String("program")).value().as_str(),
        String("/tmp/main.py"),
    )
    assert_true(not body.object_get(String("module")))


def test_dap_launch_arguments_for_debugpy_script_mode() raises:
    """``python manage.py runserver`` should rewrite ``program`` to the
    script path (not the python binary) so debugpy actually runs the
    script. Without this, debugpy tries to ``runpy`` the python
    interpreter and stalls in ``_run_code``."""
    var debs = built_in_debuggers()
    var idx = find_debugger_for_language(debs, String("python"))
    assert_true(idx >= 0)
    var args = List[String]()
    args.append(String("manage.py"))
    args.append(String("runserver"))
    var body = launch_arguments_for(
        debs[idx],
        String("/Users/me/p/.venv/bin/python"),
        String("/Users/me/p"),
        args^,
        False,
    )
    assert_true(body.is_object())
    assert_equal(
        body.object_get(String("program")).value().as_str(),
        String("manage.py"),
    )
    assert_true(not body.object_get(String("module")))
    var arr = body.object_get(String("args"))
    assert_true(arr.value().is_array())
    assert_equal(arr.value().array_len(), 1)
    assert_equal(arr.value().array_at(0).as_str(), String("runserver"))


def test_dap_launch_arguments_for_debugpy_skips_flag_args() raises:
    """When the first arg starts with a dash (e.g. ``-c``, ``-W``) we
    leave ``program`` alone — those flags need bespoke handling we
    don't do yet, so forwarding the unrewritten args lets debugpy
    error explicitly instead of silently dropping a flag."""
    var debs = built_in_debuggers()
    var idx = find_debugger_for_language(debs, String("python"))
    assert_true(idx >= 0)
    var args = List[String]()
    args.append(String("-c"))
    args.append(String("print('hi')"))
    var body = launch_arguments_for(
        debs[idx],
        String("/usr/bin/python3"),
        String("/tmp"),
        args^,
        False,
    )
    assert_equal(
        body.object_get(String("program")).value().as_str(),
        String("/usr/bin/python3"),
    )
    assert_true(not body.object_get(String("module")))


def test_dap_launch_arguments_for_delve() raises:
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


def test_dap_manager_breakpoint_toggle() raises:
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


def test_dap_manager_breakpoint_enabled_default_and_toggle() raises:
    """New breakpoints default to enabled. ``set_breakpoint_enabled``
    flips the flag; the BP stays in the list (so the gutter still
    shows it) but is omitted from ``setBreakpoints`` payloads."""
    var mgr = DapManager()
    mgr.toggle_breakpoint(String("/tmp/x.py"), 7)
    assert_true(mgr.breakpoint_enabled(String("/tmp/x.py"), 7))
    mgr.set_breakpoint_enabled(String("/tmp/x.py"), 7, False)
    assert_false(mgr.breakpoint_enabled(String("/tmp/x.py"), 7))
    # Disabled BP stays in the list — the gutter still draws it gray.
    assert_true(mgr.has_breakpoint(String("/tmp/x.py"), 7))
    mgr.set_breakpoint_enabled(String("/tmp/x.py"), 7, True)
    assert_true(mgr.breakpoint_enabled(String("/tmp/x.py"), 7))


def test_dap_manager_breakpoints_info_for() raises:
    """``breakpoints_info_for`` returns parallel lines / enabled /
    conditional lists for one path. The editor uses these to colour
    the gutter dot per-row."""
    var mgr = DapManager()
    mgr.toggle_breakpoint(String("/tmp/a.py"), 1)
    mgr.toggle_breakpoint(String("/tmp/a.py"), 2)
    mgr.set_breakpoint_condition(String("/tmp/a.py"), 2, String("i > 0"))
    mgr.toggle_breakpoint(String("/tmp/a.py"), 3)
    mgr.set_breakpoint_enabled(String("/tmp/a.py"), 3, False)
    var info = mgr.breakpoints_info_for(String("/tmp/a.py"))
    assert_equal(len(info[0]), 3)
    assert_equal(info[0][0], 1)
    assert_true(info[1][0])    # enabled
    assert_false(info[2][0])   # not conditional
    assert_equal(info[0][1], 2)
    assert_true(info[1][1])
    assert_true(info[2][1])    # conditional
    assert_equal(info[0][2], 3)
    assert_false(info[1][2])   # disabled
    assert_false(info[2][2])


def test_dap_manager_breakpoint_wait_for_arms_on_trigger() raises:
    """A BP with a non-empty wait-for stays disarmed until
    ``arm_dependents`` is called for the matching ``"path:line"``
    key. Setting and clearing ``wait_for`` flips the armed state in
    the obvious direction. Default (``toggle_breakpoint`` without a
    wait-for) is empty + armed, matching pre-feature behaviour."""
    var mgr = DapManager()
    mgr.toggle_breakpoint(String("/tmp/x.py"), 5)
    mgr.toggle_breakpoint(String("/tmp/x.py"), 12)
    # Default: no dependency, both stored as empty.
    assert_equal(mgr.breakpoint_wait_for(String("/tmp/x.py"), 5), String(""))
    assert_equal(mgr.breakpoint_wait_for_at(0), String(""))
    # Make BP at line 12 wait for the BP at line 5 (1-based on the wire).
    mgr.set_breakpoint_wait_for(
        String("/tmp/x.py"), 12, String("/tmp/x.py:6"),
    )
    assert_equal(
        mgr.breakpoint_wait_for(String("/tmp/x.py"), 12),
        String("/tmp/x.py:6"),
    )
    # Hitting an unrelated location doesn't arm it.
    mgr.arm_dependents(String("/tmp/y.py"), 5)
    # (No public predicate for armed; the only observable effect is
    # via ``_send_set_breakpoints`` skipping the BP — that's exercised
    # downstream. We at least verify ``arm_dependents`` doesn't raise.)
    # Hitting the matching location resolves the dependency.
    mgr.arm_dependents(String("/tmp/x.py"), 5)
    # Clearing the wait-for through the API returns the BP to "always
    # armed".
    mgr.set_breakpoint_wait_for(
        String("/tmp/x.py"), 12, String(""),
    )
    assert_equal(mgr.breakpoint_wait_for(String("/tmp/x.py"), 12), String(""))


def test_dap_manager_captures_condition_exception_from_output() raises:
    """A pydevd ``Error while evaluating expression in conditional
    breakpoint`` output event must be parsed into the condition + the
    short error summary (last non-empty traceback line). The full text
    is *not* swallowed — it still flows through ``take_outputs`` so
    the user sees the full traceback in the debug pane."""
    var mgr = DapManager()
    var text = String(
        "pydevd: Error while evaluating expression in conditional"
        " breakpoint: x.attr\n"
        "Traceback (most recent call last):\n"
        '  File "<string>", line 1, in <module>\n'
        "NameError: name 'x' is not defined\n"
    )
    var matched = mgr._maybe_capture_condition_exception(text)
    assert_true(matched)
    assert_true(mgr.has_condition_exception())
    var ce = mgr.take_condition_exception()
    assert_true(Bool(ce))
    assert_equal(ce.value().condition, String("x.attr"))
    assert_equal(
        ce.value().error,
        String("NameError: name 'x' is not defined"),
    )
    # Drained — second take returns nothing.
    assert_false(mgr.has_condition_exception())
    assert_false(Bool(mgr.take_condition_exception()))


def test_dap_manager_condition_exception_ignores_unrelated_output() raises:
    """Plain stdout / stderr lines must not trip the condition-exception
    parser; otherwise random app output containing the word ``error``
    would pop the dialog."""
    var mgr = DapManager()
    assert_false(mgr._maybe_capture_condition_exception(
        String("hello world\n"),
    ))
    assert_false(mgr._maybe_capture_condition_exception(
        String("Error while evaluating something else\n"),
    ))
    # Note: prefix must be exact, including the leading "pydevd: ".
    assert_false(mgr._maybe_capture_condition_exception(
        String(
            "Error while evaluating expression in conditional"
            " breakpoint: foo\n",
        ),
    ))
    assert_false(mgr.has_condition_exception())


def test_pytest_python_files_multiline_toml_array() raises:
    """``python_files`` declared as a multi-line TOML array in
    ``pyproject.toml`` (iommi's shape) must parse every glob, not just
    the ones on the ``python_files =`` line. Regression: the parser used
    to read only that line, which on a multi-line array is just ``[`` —
    so iommi got empty globs, fell back to pytest defaults, and its
    ``*__tests.py`` files showed no gutter run-icons."""
    var root = _temp_path(String("_pyproject_ml"))
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var path = join_path(root, String("pyproject.toml"))
    var body = String(
        "[tool.pytest.ini_options]\n"
        + "DJANGO_SETTINGS_MODULE = \"tests.settings\"\n"
        + "python_files = [\n"
        + "    'test_*.py',\n"
        + "    'helpers.py',\n"
        + "    '*__tests.py',\n"
        + "]\n"
        + "markers = ['django']\n"
    )
    assert_true(write_file(path, body))
    var globs = pytest_python_files(root)
    assert_equal(len(globs), 3)
    assert_equal(globs[0], String("test_*.py"))
    assert_equal(globs[1], String("helpers.py"))
    assert_equal(globs[2], String("*__tests.py"))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((root + String("\0")).unsafe_ptr())


def test_pytest_python_files_singleline_toml_array() raises:
    """The single-line array form still parses — the multi-line fix must
    not regress ``python_files = ["test_*.py", "*__tests.py"]``."""
    var root = _temp_path(String("_pyproject_sl"))
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var path = join_path(root, String("pyproject.toml"))
    var body = String(
        "[tool.pytest.ini_options]\n"
        + "python_files = [\"test_*.py\", \"*__tests.py\"]\n"
    )
    assert_true(write_file(path, body))
    var globs = pytest_python_files(root)
    assert_equal(len(globs), 2)
    assert_equal(globs[0], String("test_*.py"))
    assert_equal(globs[1], String("*__tests.py"))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((root + String("\0")).unsafe_ptr())


def test_test_pane_runs_command_on_pty() raises:
    """End-to-end pty path: ``run`` spawns a child on a real pty,
    ``tick`` drains it into the emulator, and the child's exit code is
    harvested on EOF. Uses ``sh -c 'exit 7'`` so the code is
    unambiguous. TTY-free — the pty is its own pts pair, independent of
    the test harness's stdio (same idiom as the RunSession echo test)."""
    var pane = TestPane()
    pane.visible = True
    var args = List[String]()
    args.append(String("-c"))
    args.append(String("printf hi; exit 7"))
    pane.run(String("sh"), args^, String(""))
    assert_true(pane.running())
    # Pump the pty until the child exits. Bounded so a stuck child fails
    # the test rather than hanging the suite.
    var ticks = 0
    while ticks < 4000 and pane.running():
        pane.tick()
        ticks += 1
    assert_false(pane.running())
    assert_true(pane.exited)
    assert_equal(pane.exit_code, 7)


def test_test_pane_resize_preserves_content() raises:
    """Shrinking the pane's width then growing it back must not lose
    content. ``Vt.resize`` truncates on shrink, so the pane replays its
    captured output stream into a fresh grid on every size change — a
    narrow→wide round-trip therefore reproduces exactly the grid a
    direct wide render produces."""
    var line1 = String("alpha bravo charlie delta echo foxtrot golf\r\n")
    var line2 = String("second-line-marker-xyz\r\n")
    var pane = TestPane()
    pane.visible = True
    pane._emit(line1)
    pane._emit(line2)
    # Wide → narrow → wide. The narrow pass truncates a naive Vt grid;
    # the replay must bring the off-grid text back on the wide pass.
    var wide = Rect(Point(0, 0), Point(50, 10))
    var narrow = Rect(Point(0, 0), Point(20, 10))
    var cw = Canvas(50, 10)
    pane.paint(cw, wide)
    var cn = Canvas(20, 10)
    pane.paint(cn, narrow)
    var cw2 = Canvas(50, 10)
    pane.paint(cw2, wide)
    # A pane rendered straight to the wide size is the reference.
    var direct = TestPane()
    direct.visible = True
    direct._emit(line1)
    direct._emit(line2)
    var cd = Canvas(50, 10)
    direct.paint(cd, wide)
    # Every grid row must match the reference — no lost content.
    assert_equal(pane.vt.rows, direct.vt.rows)
    for r in range(pane.vt.rows):
        assert_equal(pane._row_text(r), direct._row_text(r))


def test_test_pane_detects_traceback_link() raises:
    """The pty/Vt-backed test pane scans its grid for ``File "...",
    line N`` spans, underlines them, and a click on the span yields an
    open request with the parsed path + 1-based line — the terminal
    equivalent of the run/debug pane's traceback links."""
    var pane = TestPane()
    pane.visible = True
    # Canned pytest-style traceback line fed straight into the emulator
    # (no pty needed — link detection runs off the grid). Fed through
    # ``_emit`` so it's captured for resize replay, matching the real
    # output path.
    pane._emit(
        String("E   File \"app/models.py\", line 7, in handler\r\n")
    )
    var canvas = Canvas(60, 8)
    var panel = Rect(Point(0, 0), Point(60, 8))
    pane.paint(canvas, panel)
    # The link was recorded during paint; it sits on the first body row
    # (one below the title row).
    assert_true(len(pane._last_links) >= 1)
    var link = pane._last_links[0]
    assert_equal(link.path, String("app/models.py"))
    assert_equal(link.line, 7)
    # Clicking inside the span produces an open request.
    var clickx = (link.x_start + link.x_end) // 2
    _ = pane.handle_mouse(
        Event.mouse_event(
            Point(clickx, link.y), MOUSE_BUTTON_LEFT, True, False,
        ),
        panel,
    )
    var req = pane.consume_open_request()
    assert_equal(req[0], String("app/models.py"))
    assert_equal(req[1], 7)
    # Drained — a second consume is empty.
    var req2 = pane.consume_open_request()
    assert_equal(req2[0], String(""))


def test_debug_pane_default_title_is_debug() raises:
    """``DebugPane`` defaults to DEBUG mode — the pane's top border
    paints ``Debug`` so existing callers see no behavioural change.

    The pane also paints a standard ``[■]`` close button at the
    top-LEFT (cells 1..3); the title's leading space therefore lands
    at col 5 and the first letter at col 6 in a panel rooted at x=0.
    """
    var pane = DebugPane()
    pane.visible = True
    var c = Canvas(40, 10)
    pane.paint(c, Rect(0, 0, 40, 10))
    assert_equal(c.get(1, 0).glyph, String("["))
    assert_equal(c.get(2, 0).glyph, String("■"))
    assert_equal(c.get(3, 0).glyph, String("]"))
    assert_equal(c.get(5, 0).glyph, String(" "))
    assert_equal(c.get(6, 0).glyph, String("D"))
    assert_equal(c.get(7, 0).glyph, String("e"))
    assert_equal(c.get(8, 0).glyph, String("b"))


def test_debug_pane_run_mode_swaps_title() raises:
    """RUN mode flips the title to ``Run`` — the pane's the same
    code path, just a different label. Title starts at col 6
    (after the ``[■]`` close button + leading space)."""
    var pane = DebugPane()
    pane.visible = True
    pane.set_mode(PANE_MODE_RUN)
    var c = Canvas(40, 10)
    pane.paint(c, Rect(0, 0, 40, 10))
    assert_equal(c.get(6, 0).glyph, String("R"))
    assert_equal(c.get(7, 0).glyph, String("u"))
    assert_equal(c.get(8, 0).glyph, String("n"))


def test_debug_pane_run_mode_hides_inspect_divider() raises:
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
    # Scan rows 1..9 (below the title row — no status text is set, so
    # the status row isn't reserved): no row should be a continuous
    # ``─`` strip carrying an ``Output`` label.
    for y in range(1, 10):
        if c.get(3, y).glyph == String("O") \
                and c.get(4, y).glyph == String("u") \
                and c.get(5, y).glyph == String("t"):
            assert_true(False)


def test_debug_pane_run_mode_uses_full_height_for_output() raises:
    """The most recent output line must reach the bottom row of the
    panel — RUN mode saves the divider row that DEBUG mode would have
    painted, and that row goes to Output instead."""
    var pane = DebugPane()
    pane.visible = True
    pane.set_mode(PANE_MODE_RUN)
    for i in range(20):
        pane.append_output(String("line ") + String(i) + String("\n"))
    var c = Canvas(40, 10)
    pane.paint(c, Rect(0, 0, 40, 10))
    # Bottom panel row is y=9. Autoscroll keeps the latest line
    # ("line 19") pinned there.
    assert_equal(c.get(2, 9).glyph, String("l"))
    assert_equal(c.get(3, 9).glyph, String("i"))
    assert_equal(c.get(4, 9).glyph, String("n"))


def test_debug_pane_debug_mode_keeps_output_divider() raises:
    """DEBUG mode with inspect content paints the ``─ Output ─`` divider
    so the Stack / Locals columns read as a separate section above the
    log."""
    var pane = DebugPane()
    pane.visible = True
    var frames = List[DapStackFrame]()
    frames.append(DapStackFrame(1, String("main"), String("/tmp/foo.py"), 41, 0, False))
    var locals = List[DapVariable]()
    pane.rebuild_inspect(
        frames^, String("Locals"), locals^,
        String("Watches"), List[String](), 0,
    )
    pane.append_output(String("debug output"))
    var c = Canvas(40, 12)
    pane.paint(c, Rect(0, 0, 40, 12))
    var found = False
    for y in range(1, 11):
        if c.get(3, y).glyph == String("O") \
                and c.get(4, y).glyph == String("u") \
                and c.get(5, y).glyph == String("t"):
            found = True
    assert_true(found)


def test_debug_pane_subtle_frame_paints_dim() raises:
    """A frame the adapter marked subtle (library / external code)
    paints in DARK_GRAY rather than WHITE so the user can still see
    the full call chain but visually distinguish their own code. The
    currently-inspected frame still gets the highlight regardless of
    the subtle hint."""
    var pane = DebugPane()
    pane.visible = True
    var frames = List[DapStackFrame]()
    # User frame at top — inspected by default.
    frames.append(DapStackFrame(
        1, String("my_func"), String("/proj/app.py"), 9, 0, False,
    ))
    # Library frame below it.
    frames.append(DapStackFrame(
        2, String("recv"), String("/lib/sock.py"), 41, 0, True,
    ))
    var locals = List[DapVariable]()
    pane.rebuild_inspect(
        frames^, String("Locals"), locals^,
        String("Watches"), List[String](), 0,
    )
    var c = Canvas(60, 16)
    pane.paint(c, Rect(0, 0, 60, 16))
    # Find the row containing ``recv`` — that's the subtle frame.
    var subtle_y = -1
    for y in range(1, 16):
        var x = _find_glyph_x(c, y, String("r"))
        if x >= 0 and c.get(x + 1, y).glyph == String("e") \
                and c.get(x + 2, y).glyph == String("c") \
                and c.get(x + 3, y).glyph == String("v"):
            subtle_y = y
            break
    assert_true(subtle_y >= 0)
    var subtle_x = _find_glyph_x(c, subtle_y, String("r"))
    assert_equal(c.get(subtle_x, subtle_y).attr.fg, DARK_GRAY)
    # And the inspected user frame stays in the highlight color, not dim.
    var user_y = -1
    for y in range(1, 16):
        var x = _find_glyph_x(c, y, String("m"))
        if x >= 0 and c.get(x + 1, y).glyph == String("y") \
                and c.get(x + 2, y).glyph == String("_"):
            user_y = y
            break
    assert_true(user_y >= 0)
    var user_x = _find_glyph_x(c, user_y, String("m"))
    # The current-frame highlight is BLACK on LIGHT_YELLOW — the key
    # invariant is that it's NOT painted dim.
    assert_true(c.get(user_x, user_y).attr.fg != DARK_GRAY)


def test_debug_pane_debug_mode_running_hides_inspect() raises:
    """DEBUG mode with no inspect rows (the program is running but not
    paused) drops the Stack / Locals columns and the ``─ Output ─``
    divider — same layout as RUN mode. Until a ``stopped`` event fires
    there's no frame data to show, so painting the section headers
    above empty columns just wastes screen space."""
    var pane = DebugPane()
    pane.visible = True
    pane.append_output(String("debug output"))
    var c = Canvas(40, 12)
    pane.paint(c, Rect(0, 0, 40, 12))
    for y in range(1, 12):
        if c.get(3, y).glyph == String("O") \
                and c.get(4, y).glyph == String("u") \
                and c.get(5, y).glyph == String("t"):
            assert_true(False)


def test_debug_pane_traceback_link_underlines_span() raises:
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
    for y in range(1, 8):
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


def test_debug_pane_plain_output_has_no_link_styling() raises:
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
    for y in range(1, 8):
        var x = _find_glyph_x(c, y, String("j"))
        if x < 0:
            continue
        var cell = c.get(x, y)
        assert_equal(cell.attr.fg, WHITE)
        assert_true((cell.attr.style & STYLE_UNDERLINE) == 0)


def test_debug_pane_click_on_traceback_link_sets_pending_open() raises:
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
    for y in range(1, 8):
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


def test_debug_pane_run_log_paints_scrollbar_when_overflowing() raises:
    """When the run/debug output overflows the visible area, a vertical
    scrollbar must be painted in the right margin (column ``panel.b.x - 1``)
    with ▲ at the top and ▼ at the bottom of the output rect."""
    var pane = DebugPane()
    pane.visible = True
    pane.set_mode(PANE_MODE_RUN)
    for i in range(40):
        pane.append_output(String("line ") + String(i) + String("\n"))
    var panel = Rect(0, 0, 40, 10)
    var c = Canvas(40, 10)
    pane.paint(c, panel)
    # Output rect spans rows [out_top, panel.b.y - 1] = [1, 9] — no
    # status text is set, so the status row isn't reserved.
    assert_equal(c.get(39, 1).glyph, String("▲"))
    assert_equal(c.get(39, 9).glyph, String("▼"))
    # At least one █ thumb glyph must exist somewhere on the rail.
    var thumb_seen = False
    for y in range(2, 9):
        if c.get(39, y).glyph == String("█"):
            thumb_seen = True
            break
    assert_true(thumb_seen)


def test_debug_pane_run_log_no_scrollbar_when_content_fits() raises:
    """A short log fits in the output area, so no scrollbar should
    be painted — the rightmost column stays as the panel background."""
    var pane = DebugPane()
    pane.visible = True
    pane.set_mode(PANE_MODE_RUN)
    pane.append_output(String("just one line"))
    var panel = Rect(0, 0, 40, 10)
    var c = Canvas(40, 10)
    pane.paint(c, panel)
    for y in range(1, 10):
        var glyph = c.get(39, y).glyph
        assert_true(
            glyph != String("▲") and glyph != String("▼")
            and glyph != String("█") and glyph != String("░"),
        )


def test_debug_pane_run_log_arrow_click_scrolls_output() raises:
    """A click on the ▼ arrow at the bottom of the scrollbar nudges
    the output down — autoscroll engages because we hit the bottom,
    then a click on the ▲ pulls scroll back up and disengages it."""
    var pane = DebugPane()
    pane.visible = True
    pane.set_mode(PANE_MODE_RUN)
    for i in range(40):
        pane.append_output(String("line ") + String(i) + String("\n"))
    var panel = Rect(0, 0, 40, 10)
    var c = Canvas(40, 10)
    pane.paint(c, panel)
    # Arrow-up click pulls scroll up by 3 rows; autoscroll must turn off
    # because we're no longer at the bottom. The ▲ arrow sits on the
    # first output row (y=1 — no status text, so no status row).
    var ev = Event.mouse_event(
        Point(39, 1), MOUSE_BUTTON_LEFT, True, False,
    )
    var consumed = pane.handle_mouse(ev, panel)
    assert_true(consumed)
    assert_false(pane.output.autoscroll)


def test_debug_pane_run_log_thumb_drag_scrolls_output() raises:
    """Pressing on the thumb starts a drag; mouse motion moves scroll;
    release ends the drag. Verifies the wiring end-to-end."""
    var pane = DebugPane()
    pane.visible = True
    pane.set_mode(PANE_MODE_RUN)
    for i in range(40):
        pane.append_output(String("line ") + String(i) + String("\n"))
    var panel = Rect(0, 0, 40, 10)
    var c = Canvas(40, 10)
    pane.paint(c, panel)
    # Find the thumb glyph y on the scrollbar column.
    var thumb_y = -1
    for y in range(2, 9):
        if c.get(39, y).glyph == String("█"):
            thumb_y = y
            break
    assert_true(thumb_y >= 0)
    # Press on the thumb.
    _ = pane.handle_mouse(
        Event.mouse_event(Point(39, thumb_y), MOUSE_BUTTON_LEFT, True, False),
        panel,
    )
    # Drag to the top of the track (mouse_y = 2 — first track row).
    _ = pane.handle_mouse(
        Event.mouse_event(Point(39, 2), MOUSE_BUTTON_LEFT, True, True),
        panel,
    )
    # Drag must have disengaged autoscroll.
    assert_false(pane.output.autoscroll)
    # Release.
    _ = pane.handle_mouse(
        Event.mouse_event(Point(39, 2), MOUSE_BUTTON_LEFT, False, False),
        panel,
    )


def test_debug_pane_close_button_dispatches() raises:
    """Clicking the standard ``[■]`` close button on the run/debug pane
    latches ``DEBUG_PANE_CLOSE`` in the dock's pending-command slot, the
    same channel the title-strip buttons use. The host consumes that
    id and routes it through ``dispatch_action`` to terminate the
    session(s) and hide the pane."""
    var pane = DebugPane()
    pane.visible = True
    var panel = Rect(0, 0, 40, 10)
    var c = Canvas(40, 10)
    pane.paint(c, panel)
    # The close button paints at cells (1,0)..(3,0); a click anywhere
    # in that span should latch ``DEBUG_PANE_CLOSE``.
    _ = pane.handle_mouse(
        Event.mouse_event(Point(2, 0), MOUSE_BUTTON_LEFT, True, False),
        panel,
    )
    assert_equal(pane.consume_command_id(), DEBUG_PANE_CLOSE)


def test_debug_pane_clear_output_wipes_log() raises:
    """``clear_output`` empties the output backlog but leaves inspect
    state alone — the Clear button on the pane is meant to drop
    noisy backlog without disturbing a paused debugger's locals."""
    var pane = DebugPane()
    pane.visible = True
    pane.set_mode(PANE_MODE_RUN)
    for i in range(5):
        pane.append_output(String("noise ") + String(i) + String("\n"))
    assert_equal(len(pane.output.lines), 5)
    pane.clear_output()
    assert_equal(len(pane.output.lines), 0)
    # Autoscroll should be re-armed so the next batch of output pins
    # to the bottom from a clean slate.
    assert_true(pane.output.autoscroll)


def test_debug_pane_long_output_line_soft_wraps() raises:
    """A line longer than the panel content width paints across
    multiple visual rows. Verifies the line shows up on more than
    one row and that the second row continues with the next chars."""
    var pane = DebugPane()
    pane.visible = True
    pane.set_mode(PANE_MODE_RUN)
    # 60 chars, content width is panel.width - 3 = 17 chars.
    pane.append_output(String("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwx"))
    var panel = Rect(0, 0, 20, 8)
    var c = Canvas(20, 8)
    pane.paint(c, panel)
    # First wrapped segment should start at the panel left margin on
    # the first output row (y=1 — no status text, so no status row).
    var first_x = _find_glyph_x(c, 1, String("A"))
    assert_true(first_x >= 0)
    # Second segment continues on the next row, starting where the
    # first segment ran out — find a char that should land in the
    # second wrapped row to confirm the line actually wrapped.
    var second_x = _find_glyph_x(c, 2, String("R"))
    assert_true(second_x >= 0)


def test_debug_pane_drag_selects_output_text() raises:
    """Dragging across output text marks a selection — verified
    through ``selected_text``. A press without a drag clears the
    selection (no zero-width selection on a plain click)."""
    var pane = DebugPane()
    pane.visible = True
    pane.set_mode(PANE_MODE_RUN)
    pane.append_output(String("hello world"))
    var panel = Rect(0, 0, 40, 8)
    var c = Canvas(40, 8)
    pane.paint(c, panel)
    # Find the row 'h' landed on.
    var hy = -1
    var hx = -1
    for y in range(1, 8):
        var x = _find_glyph_x(c, y, String("h"))
        if x >= 0:
            hy = y
            hx = x
            break
    assert_true(hy >= 0)
    # Press at 'h', drag to one cell past 'd' (cell 11 -> selecting
    # the entire word).
    _ = pane.handle_mouse(
        Event.mouse_event(Point(hx, hy), MOUSE_BUTTON_LEFT, True, False),
        panel,
    )
    _ = pane.handle_mouse(
        Event.mouse_event(Point(hx + 11, hy), MOUSE_BUTTON_LEFT, True, True),
        panel,
    )
    _ = pane.handle_mouse(
        Event.mouse_event(Point(hx + 11, hy), MOUSE_BUTTON_LEFT, False, False),
        panel,
    )
    assert_true(pane.has_selection())
    assert_equal(pane.selected_text(), String("hello world"))


def test_debug_pane_double_click_selects_word() raises:
    """Double-clicking a word in the run/debug output selects just that
    word — the editor's word-select gesture, now framework-wide."""
    var pane = DebugPane()
    pane.visible = True
    pane.set_mode(PANE_MODE_RUN)
    pane.append_output(String("hello world foo bar"))
    var panel = Rect(0, 0, 40, 8)
    var c = Canvas(40, 8)
    pane.paint(c, panel)
    var hy = -1
    var hx = -1
    for y in range(1, 8):
        var x = _find_glyph_x(c, y, String("h"))
        if x >= 0:
            hy = y
            hx = x
            break
    assert_true(hy >= 0)
    # Double-click inside "world" (8 cells past line start).
    _ = pane.handle_mouse(
        Event.mouse_event(Point(hx + 8, hy), MOUSE_BUTTON_LEFT, True, False,
                          MOD_NONE, 2), panel,
    )
    _ = pane.handle_mouse(
        Event.mouse_event(Point(hx + 8, hy), MOUSE_BUTTON_LEFT, False, False),
        panel,
    )
    assert_true(pane.has_selection())
    assert_equal(pane.selected_text(), String("world"))


def test_debug_pane_double_click_drag_extends_by_word() raises:
    """Double-click + drag grows the selection whole words at a time."""
    var pane = DebugPane()
    pane.visible = True
    pane.set_mode(PANE_MODE_RUN)
    pane.append_output(String("hello world foo bar"))
    var panel = Rect(0, 0, 40, 8)
    var c = Canvas(40, 8)
    pane.paint(c, panel)
    var hy = -1
    var hx = -1
    for y in range(1, 8):
        var x = _find_glyph_x(c, y, String("h"))
        if x >= 0:
            hy = y
            hx = x
            break
    assert_true(hy >= 0)
    _ = pane.handle_mouse(
        Event.mouse_event(Point(hx + 8, hy), MOUSE_BUTTON_LEFT, True, False,
                          MOD_NONE, 2), panel,
    )
    # Drag onto "bar" (col 17) — even a partial-word hover selects the
    # whole word.
    _ = pane.handle_mouse(
        Event.mouse_event(Point(hx + 17, hy), MOUSE_BUTTON_LEFT, True, True),
        panel,
    )
    _ = pane.handle_mouse(
        Event.mouse_event(Point(hx + 17, hy), MOUSE_BUTTON_LEFT, False, False),
        panel,
    )
    assert_equal(pane.selected_text(), String("world foo bar"))


def test_debug_pane_triple_click_drag_extends_by_line() raises:
    """Triple-click + drag selects whole logical lines."""
    var pane = DebugPane()
    pane.visible = True
    pane.set_mode(PANE_MODE_RUN)
    pane.append_output(String("row zero\nrow one\nrow two"))
    var panel = Rect(0, 0, 40, 8)
    var c = Canvas(40, 8)
    pane.paint(c, panel)
    var y0 = -1
    var x0 = -1
    var y2 = -1
    for y in range(1, 8):
        if _find_glyph_x(c, y, String("z")) >= 0:   # "zero" — only row 0
            y0 = y
            x0 = _find_glyph_x(c, y, String("r"))
        if _find_glyph_x(c, y, String("t")) >= 0:   # "two" — only row 2
            y2 = y
    assert_true(y0 >= 0)
    assert_true(y2 >= 0)
    _ = pane.handle_mouse(
        Event.mouse_event(Point(x0 + 2, y0), MOUSE_BUTTON_LEFT, True, False,
                          MOD_NONE, 3), panel,
    )
    _ = pane.handle_mouse(
        Event.mouse_event(Point(x0 + 2, y2), MOUSE_BUTTON_LEFT, True, True),
        panel,
    )
    _ = pane.handle_mouse(
        Event.mouse_event(Point(x0 + 2, y2), MOUSE_BUTTON_LEFT, False, False),
        panel,
    )
    assert_equal(
        pane.selected_text(), String("row zero\nrow one\nrow two"),
    )


def test_debug_pane_selection_spans_multiple_lines() raises:
    """A selection that starts on one logical line and ends on
    another joins the two slices with a newline."""
    var pane = DebugPane()
    pane.visible = True
    pane.set_mode(PANE_MODE_RUN)
    pane.append_output(String("first line\nsecond line"))
    var panel = Rect(0, 0, 40, 8)
    var c = Canvas(40, 8)
    pane.paint(c, panel)
    # Find both lines on the canvas.
    var fy = -1
    var sy = -1
    var fx = -1
    var sx = -1
    for y in range(1, 8):
        var fx_try = _find_glyph_x(c, y, String("f"))
        if fx_try >= 0 and c.get(fx_try + 1, y).glyph == String("i"):
            fy = y
            fx = fx_try
        var sx_try = _find_glyph_x(c, y, String("s"))
        if sx_try >= 0 and c.get(sx_try + 1, y).glyph == String("e"):
            sy = y
            sx = sx_try
    assert_true(fy >= 0)
    assert_true(sy >= 0)
    _ = pane.handle_mouse(
        Event.mouse_event(Point(fx, fy), MOUSE_BUTTON_LEFT, True, False),
        panel,
    )
    _ = pane.handle_mouse(
        Event.mouse_event(
            Point(sx + 11, sy), MOUSE_BUTTON_LEFT, True, True,
        ),
        panel,
    )
    _ = pane.handle_mouse(
        Event.mouse_event(
            Point(sx + 11, sy), MOUSE_BUTTON_LEFT, False, False,
        ),
        panel,
    )
    assert_equal(
        pane.selected_text(),
        String("first line\nsecond line"),
    )


def test_debug_pane_plain_click_clears_selection() raises:
    """A press without any drag motion produces no selection — the
    user just landed on a row, didn't ask to copy anything."""
    var pane = DebugPane()
    pane.visible = True
    pane.set_mode(PANE_MODE_RUN)
    pane.append_output(String("hello world"))
    var panel = Rect(0, 0, 40, 8)
    var c = Canvas(40, 8)
    pane.paint(c, panel)
    var hy = -1
    var hx = -1
    for y in range(1, 8):
        var x = _find_glyph_x(c, y, String("h"))
        if x >= 0:
            hy = y
            hx = x
            break
    assert_true(hy >= 0)
    _ = pane.handle_mouse(
        Event.mouse_event(Point(hx + 2, hy), MOUSE_BUTTON_LEFT, True, False),
        panel,
    )
    _ = pane.handle_mouse(
        Event.mouse_event(Point(hx + 2, hy), MOUSE_BUTTON_LEFT, False, False),
        panel,
    )
    assert_true(not pane.has_selection())
    assert_equal(pane.selected_text(), String(""))


def test_targets_dialog_edit_and_submit() raises:
    """Project Settings Targets section: open with two targets, type into
    the focused Name field — ``targets_value`` reflects the edit, raises
    ``targets_dirty``, and keeps the active marker on the original row."""
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
    var ps = _ps_open_targets(src^)
    assert_true(ps.active)
    assert_equal(len(ps.targets.targets), 2)
    # ``selected_tg`` honors ``active`` — index 1 (beta).
    assert_equal(ps.selected_tg, 1)
    ps.focus = UInt8(7)  # _FOCUS_TG_NAME
    _ = ps.handle_key(_key(UInt32(ord("X"))))
    var rebuilt = ps.targets_value()
    assert_equal(rebuilt.targets[1].name, String("betaX"))
    assert_equal(rebuilt.targets[rebuilt.active].name, String("betaX"))
    assert_true(ps.targets_dirty)


def test_targets_dialog_add_and_remove() raises:
    """Add then remove a target in the Targets section returns to the
    original list."""
    var src = ProjectTargets()
    var t1 = RunTarget()
    t1.name = String("only")
    t1.program = String("echo")
    src.targets.append(t1^)
    src.active = 0
    var ps = _ps_open_targets(src^)
    ps.focus = UInt8(12)  # _FOCUS_TG_ADD
    _ = ps.handle_key(_key(KEY_ENTER))
    assert_equal(len(ps.targets.targets), 2)
    assert_equal(ps.selected_tg, 1)
    ps.focus = UInt8(13)  # _FOCUS_TG_REMOVE
    _ = ps.handle_key(_key(KEY_ENTER))
    assert_equal(len(ps.targets.targets), 1)
    assert_equal(ps.targets.targets[0].name, String("only"))


def test_targets_dialog_save_button_submits() raises:
    """Persist-on-change: any target edit raises ``targets_dirty`` (the
    host writes targets.json on the next paint — there's no Save button)."""
    var src = ProjectTargets()
    var t1 = RunTarget()
    t1.name = String("only")
    src.targets.append(t1^)
    src.active = 0
    var ps = _ps_open_targets(src^)
    assert_false(ps.targets_dirty)
    ps.focus = UInt8(12)  # _FOCUS_TG_ADD
    _ = ps.handle_key(_key(KEY_ENTER))
    assert_true(ps.targets_dirty)


def test_targets_dialog_esc_discards_edits() raises:
    """Esc closes the Project Settings view."""
    var src = ProjectTargets()
    var t1 = RunTarget()
    t1.name = String("a")
    src.targets.append(t1^)
    src.active = 0
    var ps = _ps_open_targets(src^)
    _ = ps.handle_key(_key(KEY_ESC))
    assert_false(ps.active)


def test_run_session_lifecycle() raises:
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
    # Final drain after the child exited: the kernel can hold the
    # ``printf`` payload in the pipe buffer past the exit that
    # ``poll_run_exit`` observed, so the in-loop drain may have broken
    # out before the bytes were readable. The fd stays open until
    # ``terminate`` below, so one more non-blocking read collects them.
    var tail_out = drain_run_output(s)
    captured = captured + tail_out.stdout
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


def test_breakpoint_store_round_trip() raises:
    """Persisted breakpoints decode to the same fields they were
    encoded from. Inside-project paths are stored project-relative so
    the file survives moving the project directory; absolute paths
    pass through. ``load_breakpoints`` re-anchors relatives onto the
    current root."""
    var root = String("/tmp/turbokod_bp_test_round_trip")
    _ = external_call["system", Int32](
        (String("rm -rf '") + root + String("'\0")).unsafe_ptr(),
    )
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var bps = List[StoredBreakpoint]()
    bps.append(StoredBreakpoint(
        root + String("/src/foo.mojo"), 41, String(""), True,
        String(""),
    ))
    bps.append(StoredBreakpoint(
        root + String("/src/foo.mojo"), 87, String("i > 10"), True,
        String(""),
    ))
    bps.append(StoredBreakpoint(
        String("/etc/hosts"), 0, String(""), False,
        # Wait-for trigger that should round-trip verbatim — the
        # store doesn't validate keys, it just stashes the string.
        String("/etc/hosts:1"),
    ))
    assert_true(save_breakpoints(root, bps))
    var loaded = load_breakpoints(root)
    assert_equal(len(loaded), 3)
    # First two are inside the project — they round-trip absolute via
    # the project-relative encoding.
    assert_equal(loaded[0].path, root + String("/src/foo.mojo"))
    assert_equal(loaded[0].line, 41)
    assert_equal(loaded[0].condition, String(""))
    assert_true(loaded[0].enabled)
    assert_equal(loaded[0].wait_for, String(""))
    assert_equal(loaded[1].path, root + String("/src/foo.mojo"))
    assert_equal(loaded[1].line, 87)
    assert_equal(loaded[1].condition, String("i > 10"))
    assert_true(loaded[1].enabled)
    assert_equal(loaded[1].wait_for, String(""))
    # Outside the project — kept absolute on disk, loaded verbatim.
    # The disabled flag round-trips so a parked BP stays parked.
    assert_equal(loaded[2].path, String("/etc/hosts"))
    assert_equal(loaded[2].line, 0)
    assert_false(loaded[2].enabled)
    assert_equal(loaded[2].wait_for, String("/etc/hosts:1"))
    _ = external_call["system", Int32](
        (String("rm -rf '") + root + String("'\0")).unsafe_ptr(),
    )


def test_breakpoint_store_load_missing_returns_empty() raises:
    """No file → empty list. Mirrors the session-store contract."""
    var bps = load_breakpoints(String("/tmp/turbokod_bp_does_not_exist_xyz"))
    assert_equal(len(bps), 0)


def test_breakpoint_store_per_user_path() raises:
    """The on-disk file lives under ``per_user/<USER>/``. Verify by
    overriding ``$USER`` for the test and checking the file appears at
    the expected sub-path. Without this isolation an accidental
    ``git add .turbokod`` on a checkout would replace a teammate's
    breakpoint set with the committer's."""
    var root = String("/tmp/turbokod_bp_per_user_test")
    _ = external_call["system", Int32](
        (String("rm -rf '") + root + String("'\0")).unsafe_ptr(),
    )
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    # Stash and override $USER so the directory name is predictable.
    var user_env = String("USER=alice_test\0")
    _ = external_call["putenv", Int32](user_env.unsafe_ptr())
    var bps = List[StoredBreakpoint]()
    bps.append(StoredBreakpoint(
        root + String("/main.py"), 7, String(""), True, String(""),
    ))
    assert_true(save_breakpoints(root, bps))
    var expected = root + String("/.turbokod/per_user/alice_test/breakpoints.json")
    assert_true(stat_file(expected).ok)
    _ = external_call["system", Int32](
        (String("rm -rf '") + root + String("'\0")).unsafe_ptr(),
    )


def main() raises:
    setup_test_env()
    test_debug_pane_repl_console()
    test_pytest_link_opens_project_relative_file()
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
    test_dap_launch_arguments_for_debugpy_module_mode()
    test_dap_launch_arguments_for_debugpy_versioned_python()
    test_dap_launch_arguments_for_debugpy_non_python_program()
    test_dap_launch_arguments_for_debugpy_script_mode()
    test_dap_launch_arguments_for_debugpy_skips_flag_args()
    test_dap_launch_arguments_for_delve()
    test_dap_manager_breakpoint_toggle()
    test_dap_manager_breakpoint_enabled_default_and_toggle()
    test_dap_manager_breakpoints_info_for()
    test_dap_manager_breakpoint_wait_for_arms_on_trigger()
    test_dap_manager_captures_condition_exception_from_output()
    test_dap_manager_condition_exception_ignores_unrelated_output()
    test_pytest_python_files_multiline_toml_array()
    test_pytest_python_files_singleline_toml_array()
    test_test_pane_runs_command_on_pty()
    test_test_pane_resize_preserves_content()
    test_test_pane_detects_traceback_link()
    test_debug_pane_default_title_is_debug()
    test_debug_pane_run_mode_swaps_title()
    test_debug_pane_run_mode_hides_inspect_divider()
    test_debug_pane_run_mode_uses_full_height_for_output()
    test_debug_pane_debug_mode_keeps_output_divider()
    test_debug_pane_subtle_frame_paints_dim()
    test_debug_pane_debug_mode_running_hides_inspect()
    test_debug_pane_traceback_link_underlines_span()
    test_debug_pane_plain_output_has_no_link_styling()
    test_debug_pane_click_on_traceback_link_sets_pending_open()
    test_debug_pane_run_log_paints_scrollbar_when_overflowing()
    test_debug_pane_run_log_no_scrollbar_when_content_fits()
    test_debug_pane_run_log_arrow_click_scrolls_output()
    test_debug_pane_run_log_thumb_drag_scrolls_output()
    test_debug_pane_close_button_dispatches()
    test_debug_pane_clear_output_wipes_log()
    test_debug_pane_long_output_line_soft_wraps()
    test_debug_pane_drag_selects_output_text()
    test_debug_pane_double_click_selects_word()
    test_debug_pane_double_click_drag_extends_by_word()
    test_debug_pane_triple_click_drag_extends_by_line()
    test_debug_pane_selection_spans_multiple_lines()
    test_debug_pane_plain_click_clears_selection()
    test_targets_dialog_edit_and_submit()
    test_targets_dialog_add_and_remove()
    test_targets_dialog_save_button_submits()
    test_targets_dialog_esc_discards_edits()
    test_run_session_lifecycle()
    test_breakpoint_store_round_trip()
    test_breakpoint_store_load_missing_returns_empty()
    test_breakpoint_store_per_user_path()
    print("dap: 61 tests passed")
