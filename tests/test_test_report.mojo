"""Live test reports: the ``TURBOKOD_TEST_REPORT`` protocol, its reader
(``TestReport``), the results view, and the test pane's plumbing of the
variable into the child.

Shared fixtures live in ``tests/support.mojo`` and
``scripts/run_tests.sh`` runs every suite.
"""

from std.collections.list import List
from std.testing import (
    TestSuite, assert_equal, assert_false, assert_true,
)

from turbokod.canvas import (
    Canvas, HOST_SPLIT, HOST_TEST_DETAIL, HOST_TEST_HEADER, HOST_TEST_LIST,
)
from turbokod.json import json_get_int, json_get_string
from turbokod.desktop import Desktop
from turbokod.colors import Attr, PANE_BG, WHITE
from turbokod.events import (
    Event, EVENT_MOUSE, KEY_DOWN, KEY_UP, MOD_NONE, MOUSE_BUTTON_LEFT,
    MOUSE_WHEEL_UP,
)
from turbokod.file_io import read_file, stat_file, write_file
from turbokod.geometry import Point, Rect
from turbokod.posix import sleep_ms
from turbokod.test_pane import TestPane
from turbokod.test_report import (
    OUTCOME_ERROR, OUTCOME_FAILED, OUTCOME_PASSED, OUTCOME_RUNNING,
    OUTCOME_SKIPPED, TEST_REPORT_ENV, reporting_env, TestReport,
)
from turbokod.test_results import (
    clean_output, is_landscape, TestResultsView, wrap_cells,
)

from support import _temp_path, setup_test_env


def _feed(mut r: TestReport, s: String):
    r.feed(s.as_bytes())


def _row(c: Canvas, y: Int) -> String:
    var out = String("")
    for x in range(c.width):
        var g = c.get(x, y).glyph
        out += g if len(g.as_bytes()) > 0 else String(" ")
    return out


def _sample_report() -> TestReport:
    var r = TestReport()
    _feed(r, String('{"event": "collected", "total": 4}\n'))
    _feed(r, String('{"event": "start", "id": "t.py::a"}\n'))
    _feed(r, String(
        '{"event": "result", "id": "t.py::a", "outcome": "passed"}\n'
    ))
    _feed(r, String(
        '{"event": "result", "id": "t.py::b", "outcome": "failed",'
        ' "file": "/p/t.py", "line": 7, "message": "assert 1 == 2",'
        ' "output": "  File \\"/p/t.py\\", line 9\\nE   boom\\n"}\n'
    ))
    return r^


# --- the reader -------------------------------------------------------------


def test_report_counts_outcomes_and_keeps_failures() raises:
    var r = _sample_report()
    assert_true(r.reporting())
    assert_equal(r.total, 4)
    assert_equal(r.done(), 2)
    assert_equal(r.count(OUTCOME_PASSED), 1)
    assert_equal(r.failed(), 1)
    # Every test, in the order it appeared.
    assert_equal(len(r.tests), 2)
    assert_equal(r.tests[0].id, String("t.py::a"))
    assert_equal(r.tests[0].outcome, OUTCOME_PASSED)
    ref b = r.tests[1]
    assert_equal(b.id, String("t.py::b"))
    assert_equal(b.outcome, OUTCOME_FAILED)
    assert_equal(b.line, 7)
    assert_equal(b.message, String("assert 1 == 2"))
    assert_true(b.output.startswith('  File "/p/t.py"'))
    # The started test finished, so nothing is in progress.
    assert_equal(r.current, String(""))
    assert_false(r.finished)
    _feed(r, String('{"event": "finish", "exit_code": 1}\n'))
    assert_true(r.finished)
    assert_equal(r.exit_code, 1)


def test_report_waits_for_the_rest_of_a_line() raises:
    """A runner's write can land in two reads; half a line isn't an event."""
    var r = TestReport()
    _feed(r, String('{"event": "start", "id": "t.py::sl'))
    assert_false(r.reporting())
    _feed(r, String('ow"}\n{"event": "res'))
    assert_equal(r.current, String("t.py::slow"))
    assert_equal(r.tests[0].outcome, OUTCOME_RUNNING)
    _feed(r, String('ult", "id": "t.py::slow", "outcome": "skipped"}\n'))
    assert_equal(r.count(OUTCOME_SKIPPED), 1)
    assert_equal(r.current, String(""))


def test_report_skips_lines_it_cannot_read() raises:
    """Garbage, non-objects and unknown events neither count nor wedge
    the reader."""
    var r = TestReport()
    _feed(r, String('not json\n[1, 2]\n{"event": "later-protocol"}\n'))
    assert_false(r.reporting())
    _feed(r, String(
        '{"event": "result", "id": "x", "outcome": "error", "extra": 1}\n'
    ))
    assert_equal(r.count(OUTCOME_ERROR), 1)
    assert_equal(r.failed(), 1)


def test_report_polls_what_the_file_gains() raises:
    var path = _temp_path(String("report.jsonl"))
    _ = write_file(path, String("stale\n"))
    var r = TestReport()
    r.reset(path)
    # A fresh run starts from a clean file.
    assert_false(stat_file(path).ok)
    assert_false(r.poll())
    _ = write_file(path, String('{"event": "collected", "total": 3}\n{"ev'))
    assert_true(r.poll())
    assert_equal(r.total, 3)
    _ = write_file(
        path,
        String(
            '{"event": "collected", "total": 3}\n'
            '{"event": "start", "id": "q"}\n'
        ),
    )
    assert_true(r.poll())
    assert_equal(r.current, String("q"))
    assert_false(r.poll())
    # Re-attaching reads the file again from its start, and keeps it.
    var again = TestReport()
    again.reset(path, fresh=False)
    assert_true(again.poll())
    assert_equal(again.total, 3)
    assert_equal(again.current, String("q"))
    again.discard()
    assert_false(stat_file(path).ok)


def test_reporting_env_loads_the_pytest_plugin() raises:
    var env = reporting_env(String("/r.jsonl"), String("/plugin"))
    assert_equal(len(env), 3)
    assert_equal(env[0], TEST_REPORT_ENV + String("=/r.jsonl"))
    assert_true(env[1].startswith("PYTHONPATH=/plugin"))
    assert_true(env[2].startswith("PYTEST_ADDOPTS="))
    assert_true(env[2].endswith("-p turbokod_pytest"))
    # Without the plugin, a runner still gets the file.
    assert_equal(len(reporting_env(String("/r.jsonl"), String(""))), 1)
    assert_equal(len(reporting_env(String(""), String("/plugin"))), 0)


# --- the view ---------------------------------------------------------------


def test_clean_output_strips_escapes_and_wrap_keeps_codepoints() raises:
    assert_equal(
        clean_output(String("\x1b[31mred\x1b[0m\r\n\tx")),
        String("red\n    x"),
    )
    var pieces = wrap_cells(String("abcdéfg"), 3)
    assert_equal(len(pieces), 3)
    assert_equal(pieces[0], String("abc"))
    assert_equal(pieces[1], String("déf"))
    assert_equal(pieces[2], String("g"))
    assert_equal(len(wrap_cells(String(""), 5)), 1)


def test_report_a_second_result_replaces_the_first() raises:
    """A rerun plugin reports a flaky test twice: it's one test, counted
    once, with the last outcome."""
    var r = TestReport()
    _feed(r, String('{"event": "result", "id": "f", "outcome": "failed"}\n'))
    _feed(r, String('{"event": "result", "id": "f", "outcome": "passed"}\n'))
    assert_equal(len(r.tests), 1)
    assert_equal(r.done(), 1)
    assert_equal(r.failed(), 0)
    assert_equal(r.tests[0].outcome, OUTCOME_PASSED)


def _painted_view(w: Int, h: Int) raises -> Tuple[TestResultsView, Canvas]:
    var v = TestResultsView()
    v.report = _sample_report()
    var grid = Canvas(w, h)
    grid.clear(Attr(WHITE, PANE_BG))
    v.paint(grid, Point(0, 0), True, True, False, 0)
    return (v^, grid^)


def test_results_view_splits_side_by_side_when_landscape() raises:
    assert_true(is_landscape(80, 12))
    var vg = _painted_view(80, 12)
    ref grid = vg[1]
    var top = _row(grid, 0)
    assert_true(top.startswith(" 2/4 "))
    assert_true("█" in top)
    assert_true("✓ 1" in top)
    assert_true("✗ 1" in top)
    # The list on the left, the first failure picked, its detail right.
    var r2 = _row(grid, 2)
    assert_true(r2.startswith(" ✓ t.py::a"))
    assert_true("│ ✗ t.py::b" in r2)
    assert_true(_row(grid, 3).startswith(" ✗ t.py::b"))
    assert_true("failed in 0 ms" in _row(grid, 3))
    assert_true("assert 1 == 2" in _row(grid, 5))
    assert_equal(vg[0].selected, 1)
    assert_equal(vg[0].title_suffix(), String(" · 2/4 · 1 failed"))


def test_results_view_stacks_when_portrait() raises:
    assert_false(is_landscape(40, 30))
    var vg = _painted_view(40, 30)
    ref grid = vg[1]
    assert_true(_row(grid, 2).startswith(" ✓ t.py::a"))
    assert_true(_row(grid, 3).startswith(" ✗ t.py::b"))
    # The list takes 2/5 of the 28 rows below the header, then a rule.
    assert_true(_row(grid, 13).startswith("────"))
    assert_true(_row(grid, 14).startswith(" ✗ t.py::b"))


def test_results_view_click_and_keys_pick_a_test() raises:
    var vg = _painted_view(80, 12)
    var v = vg[0].copy()
    var grid = vg[1].copy()
    # Grid at (5, 20): click the first list row.
    var e = Event.mouse_event(Point(8, 22), MOUSE_BUTTON_LEFT, True, False)
    assert_true(v.handle_mouse(e, Point(5, 20), True))
    assert_equal(v.selected, 0)
    v.paint(grid, Point(5, 20), False, True, True, 1)
    assert_true("✓ t.py::a" in _row(grid, 2))
    assert_true(v.handle_key(Event.key_event(KEY_DOWN)))
    assert_equal(v.selected, 1)
    assert_true(v.handle_key(Event.key_event(KEY_DOWN)))
    assert_equal(v.selected, 1)
    _ = v.handle_key(Event.key_event(KEY_UP))
    assert_equal(v.selected, 0)


def test_results_view_detail_links_open_the_test() raises:
    var vg = _painted_view(80, 12)
    var v = vg[0].copy()
    var grid = vg[1].copy()
    v.paint(grid, Point(5, 20), False, True, True, 1)
    # The detail's header (x 33 = list 32 + rule) opens the test.
    var e = Event.mouse_event(Point(5 + 35, 22), MOUSE_BUTTON_LEFT, True, False)
    _ = v.handle_mouse(e, Point(5, 20), True)
    var link = v.take_link()
    assert_true(Bool(link))
    assert_equal(link.value().path, String("/p/t.py"))
    assert_equal(link.value().line, 7)
    assert_false(Bool(v.take_link()))
    # The traceback's ``File "...", line N`` is a link too (row 7).
    var e2 = Event.mouse_event(Point(5 + 40, 27), MOUSE_BUTTON_LEFT, True, False)
    _ = v.handle_mouse(e2, Point(5, 20), True)
    var link2 = v.take_link()
    assert_true(Bool(link2))
    assert_equal(link2.value().line, 9)


def test_results_view_list_follows_the_run_until_scrolled() raises:
    """With nothing failed (so nothing selected) the list shows the newest
    tests; scrolling it by hand stops that."""
    var v = TestResultsView()
    for i in range(20):
        _feed(v.report, String('{"event": "result", "id": "t') + String(i)
            + String('", "outcome": "passed"}\n'))
    var grid = Canvas(80, 8)
    v.paint(grid, Point(0, 0), True, True, False, 0)
    assert_true(_row(grid, 7).startswith(" ✓ t19"))
    var wheel = Event.mouse_event(Point(3, 4), MOUSE_WHEEL_UP, True, False)
    _ = v.handle_mouse(wheel, Point(0, 0), True)
    _feed(v.report, String('{"event": "start", "id": "t20"}\n'))
    v.paint(grid, Point(0, 0), True, True, False, 0)
    assert_true(_row(grid, 7).startswith(" ✓ t16"))


def test_results_split_drags_through_the_desktop() raises:
    """The results view's divider, driven the way the app drives it: the
    cursor flips over it, a drag through ``Desktop.handle_event`` moves
    it, and the new position lands in the config every pane follows."""
    var d = Desktop()
    d.config.test_results_view = True
    d.test_pane.results.report = _sample_report()
    d.test_pane.started = True
    d.test_pane.exited = True
    d._test_output_held = True
    var screen = Rect(0, 0, 120, 40)
    d.dap_tick(screen)
    var canvas = Canvas(120, 40)
    canvas.clear(Attr(WHITE, PANE_BG))
    d.paint(canvas, screen)
    var origin = d.test_pane.sel._last_body.a
    var div = d.test_pane.results.split_wide.divider_rect()
    assert_false(div.is_empty())
    var x = origin.x + div.a.x
    var y = origin.y + div.a.y + 1
    assert_equal(d.pointer_shape_at(Point(x, y), screen), String("ew-resize"))
    assert_equal(
        d.pointer_shape_at(Point(x - 3, y), screen) == String("ew-resize"),
        False,
    )
    var before = d.config.test_split_wide
    _ = d.handle_event(
        Event.mouse_event(Point(x, y), MOUSE_BUTTON_LEFT, True, False), screen,
    )
    _ = d.handle_event(
        Event.mouse_event(Point(x + 20, y), MOUSE_BUTTON_LEFT, True, True),
        screen,
    )
    _ = d.handle_event(
        Event.mouse_event(Point(x + 20, y), MOUSE_BUTTON_LEFT, False, False),
        screen,
    )
    d.dap_tick(screen)
    assert_true(d.config.test_split_wide > before)
    d.paint(canvas, screen)
    assert_equal(d.test_pane.results.split_wide.divider_rect().a.x, div.a.x + 20)


def test_results_view_leaves_its_regions_to_a_host_that_draws() raises:
    """In the native looks the view paints blank cells and says where its
    header, list and detail are (tagged with its pane), the divider being
    the split's own item."""
    var v = TestResultsView()
    v.report = _sample_report()
    v.host_tag = 3
    var grid = Canvas(80, 12)
    grid.host_widgets = True
    v.paint(grid, Point(0, 0), False, True, True, 1)
    var kinds = List[Int]()
    for i in range(len(grid.host_items)):
        kinds.append(Int(grid.host_items[i].kind))
        if grid.host_items[i].kind != HOST_SPLIT:
            assert_equal(grid.host_items[i].tag, 3)
    assert_true(Int(HOST_TEST_HEADER) in kinds)
    assert_true(Int(HOST_TEST_LIST) in kinds)
    assert_true(Int(HOST_TEST_DETAIL) in kinds)
    assert_true(Int(HOST_SPLIT) in kinds)
    assert_false("t.py::b" in _row(grid, 2))
    assert_false("█" in _row(grid, 0))


def test_native_state_sends_only_what_changed() raises:
    var v = TestResultsView()
    v.report = _sample_report()
    var first = v.native_state(-1, -1)
    var gen = json_get_int(first, String("generation"), -9)
    var ver = json_get_int(first, String("version"), -9)
    assert_equal(json_get_int(first, String("count"), 0), 2)
    assert_equal(first.object_get(String("rows")).value().array_len(), 2)
    # Nothing new: no rows.
    var same = v.native_state(gen, ver)
    assert_equal(same.object_get(String("rows")).value().array_len(), 0)
    _feed(v.report, String('{"event": "start", "id": "t.py::c"}\n'))
    var next = v.native_state(gen, ver)
    var rows = next.object_get(String("rows")).value().copy()
    assert_equal(rows.array_len(), 1)
    assert_equal(rows.array_at(0).array_at(0).as_int(), 2)
    assert_equal(rows.array_at(0).array_at(1).as_int(), Int(OUTCOME_RUNNING))
    # A new run: everything again.
    v.start(String(""))
    _feed(v.report, String('{"event": "start", "id": "x"}\n'))
    var fresh = v.native_state(gen, json_get_int(next, String("version"), 0))
    assert_equal(fresh.object_get(String("rows")).value().array_len(), 1)


def test_native_detail_carries_text_and_links() raises:
    var v = TestResultsView()
    v.report = _sample_report()
    v.select(1)
    var d = v.native_detail()
    assert_equal(json_get_string(d, String("id")), String("t.py::b"))
    var text = json_get_string(d, String("text"))
    assert_true(text.startswith("assert 1 == 2\n\n"))
    var links = d.object_get(String("links")).value().copy()
    assert_equal(links.array_len(), 1)
    ref l = links.array_at(0)
    assert_equal(l.array_at(0).as_int(), 2)
    assert_equal(l.array_at(3).as_str(), String("/p/t.py"))
    assert_equal(l.array_at(4).as_int(), 9)
    # Opening it, and the test, from the host.
    v.native_act(2, 9, String("/p/t.py"))
    assert_equal(v.take_link().value().line, 9)
    v.native_act(1, 1, String(""))
    assert_equal(v.take_link().value().line, 7)
    v.native_act(0, 0, String(""))
    assert_equal(v.selected, 0)


# --- the pane ---------------------------------------------------------------


def test_test_pane_hands_the_child_the_report_file() raises:
    """Any runner can report: the child gets ``TURBOKOD_TEST_REPORT`` and
    what it appends there shows up in the pane's report."""
    var pane = TestPane()
    var args = List[String]()
    args.append(String("-c"))
    args.append(String(
        "printf '%s\\n' '{\"event\": \"collected\", \"total\": 1}'"
        " '{\"event\": \"result\", \"id\": \"only\", \"outcome\": \"failed\","
        " \"output\": \"why\"}' >> \"$TURBOKOD_TEST_REPORT\""
    ))
    var path = _temp_path(String("pane-report.jsonl"))
    pane.run(String("/bin/sh"), args, String("/"), report_path=path)
    var waited = 0
    while pane.running() and waited < 5000:
        pane.tick()
        sleep_ms(10)
        waited += 10
    assert_false(pane.running())
    assert_equal(pane.results.report.total, 1)
    assert_equal(pane.results.report.failed(), 1)
    assert_equal(pane.results.report.tests[0].output, String("why"))
    assert_true(pane.header_title().endswith(" · 1/1 · 1 failed"))
    pane.close()
    pane.release()
    assert_false(stat_file(path).ok)


def main() raises:
    setup_test_env()
    TestSuite.discover_tests[__functions_in_module()]().run()
