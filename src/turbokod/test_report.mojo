"""Live test reports: the protocol a test runner speaks to the test pane.

When the test pane runs a command it sets ``TURBOKOD_TEST_REPORT`` to a file
path. A runner that knows about TurboKod appends one JSON object per line to
that file as it goes; ``TestReport`` tails the file each tick and keeps the
running totals, the failures with their output, and the test in progress, for
the pane's results view and its title. A runner that doesn't report leaves the
file empty, and the pane shows its terminal output as before.

The events (every field but ``event`` optional; unknown events and fields are
ignored, so the protocol can grow):

* ``{"event": "collected", "total": 120}`` — how many tests the run will
  report, for the progress bar. May be sent again; the last one wins.
* ``{"event": "start", "id": "...", "file": "/abs/x.py", "line": 12}`` — a
  test began.
* ``{"event": "result", "id": "...", "outcome": "failed", "file": ...,
  "line": ..., "duration_ms": 3, "message": "one line", "output": "..."}`` —
  a test ended. ``outcome`` is ``passed`` / ``failed`` / ``error`` /
  ``skipped`` / ``xfailed`` / ``xpassed``; ``message`` is one line (the
  assertion, the skip reason) and ``output`` anything worth reading (the
  failure's traceback and captured output).
* ``{"event": "finish", "exit_code": 1}`` — the run is over.

``file`` is absolute (or relative to the run's directory) and ``line`` is
1-based, 0 for "no line". The bundled pytest plugin
(``data/pytest_plugin/turbokod_pytest.py``) speaks this; the full write-up
is ``docs/test-reporting.md``.
"""

from std.collections.dict import Dict
from std.collections.list import List
from std.ffi import external_call

from .file_io import (
    delete_path, make_parent_dirs, O_RDONLY, read_existing_file, read_file,
    stat_file, write_file,
)
from .json import json_get_int, json_get_string, parse_json
from .posix import alloc_zero_buffer, getenv_value, monotonic_ms, realpath


comptime TEST_REPORT_ENV = String("TURBOKOD_TEST_REPORT")
"""The variable that hands a runner the report file's path."""

comptime PYTEST_PLUGIN_DIR = String("src/turbokod/data/pytest_plugin")
"""The bundled pytest plugin's directory, relative to the resource root
(the repo in a dev run, ``Contents/Resources`` in the app)."""

comptime OUTCOME_PASSED  = UInt8(0)
comptime OUTCOME_FAILED  = UInt8(1)
comptime OUTCOME_ERROR   = UInt8(2)
comptime OUTCOME_SKIPPED = UInt8(3)
comptime OUTCOME_XFAILED = UInt8(4)
comptime OUTCOME_XPASSED = UInt8(5)
comptime _OUTCOME_COUNT = 6
comptime OUTCOME_RUNNING = UInt8(6)
"""Started and not finished: a test's state between ``start`` and
``result``. Not an outcome, so ``counts`` has no slot for it."""

comptime _MAX_POLL_BYTES = 1024 * 1024
"""How much of the report one tick reads, so a flood doesn't stall a frame;
the rest is read on the next one."""


def outcome_from_name(name: String) -> UInt8:
    if name == String("failed"):
        return OUTCOME_FAILED
    if name == String("error"):
        return OUTCOME_ERROR
    if name == String("skipped"):
        return OUTCOME_SKIPPED
    if name == String("xfailed"):
        return OUTCOME_XFAILED
    if name == String("xpassed"):
        return OUTCOME_XPASSED
    return OUTCOME_PASSED


@fieldwise_init
struct TestResult(Copyable, Movable):
    """One test of the run: running, or how it ended."""
    var id: String
    var outcome: UInt8
    var file: String
    var line: Int
    """1-based; 0 when the runner gave none."""
    var duration_ms: Int
    var message: String
    var output: String
    var stamp: Int
    """``TestReport.version`` of the event that last changed this test, so
    a host can fetch only what changed since the version it has."""


struct TestReport(Copyable, Movable):
    """The state of one run's report, fed from its file by ``poll``."""
    var path: String
    """The report file; empty while no run reports."""
    var _offset: Int
    var _partial: List[UInt8]
    """The bytes of a line whose newline hasn't been written yet."""

    var total: Int
    """Tests the run said it would report; -1 until it says."""
    var counts: List[Int]
    """Finished tests per ``OUTCOME_*``."""
    var tests: List[TestResult]
    """Every test the run reported, in the order each first appeared
    (started, or finished without a start — a collection error)."""
    var _index: Dict[String, Int]
    """``tests`` position by id."""
    var current: String
    """The test that most recently started and hasn't finished; empty
    otherwise."""
    var finished: Bool
    var exit_code: Int
    var events: Int
    """Events read so far: zero means the runner hasn't reported (yet)."""
    var version: Int
    """Bumped on every change, so a view can cache what it built from it."""
    var generation: Int
    """Bumped by every ``reset``: a new run, whose tests start over."""

    def __init__(out self):
        self.path = String("")
        self._offset = 0
        self._partial = List[UInt8]()
        self.total = -1
        self.counts = List[Int]()
        for _ in range(_OUTCOME_COUNT):
            self.counts.append(0)
        self.tests = List[TestResult]()
        self._index = Dict[String, Int]()
        self.current = String("")
        self.finished = False
        self.exit_code = 0
        self.events = 0
        self.version = 0
        self.generation = 0

    def reset(mut self, path: String, fresh: Bool = True):
        """Start over for a run that reports into ``path`` (empty: one
        that doesn't). With ``fresh`` the previous run's file is deleted,
        and so is any leftover at ``path``, so the run starts from a clean
        file; without, ``path`` is read again from its start."""
        if fresh:
            self.discard()
        var v = self.version
        var g = self.generation
        self = TestReport()
        self.version = v + 1
        self.generation = g + 1
        self.path = path
        if len(path.as_bytes()) > 0:
            make_parent_dirs(path)
            if fresh:
                _ = delete_path(path)

    def discard(mut self):
        """Delete the report file (the run is over and its pane is going)."""
        if len(self.path.as_bytes()) > 0:
            _ = delete_path(self.path)

    # --- queries ------------------------------------------------------

    def reporting(self) -> Bool:
        return self.events > 0

    def done(self) -> Int:
        var n = 0
        for i in range(len(self.counts)):
            n += self.counts[i]
        return n

    def count(self, outcome: UInt8) -> Int:
        return self.counts[Int(outcome)]

    def failed(self) -> Int:
        return self.count(OUTCOME_FAILED) + self.count(OUTCOME_ERROR)

    def find(self, id: String) -> Int:
        """``tests`` position of ``id``, or -1."""
        var at = self._index.get(id)
        if at:
            return at.value()
        return -1

    def _entry(mut self, id: String) -> Int:
        """``tests`` position of ``id``, appending a running entry for a
        test not seen yet."""
        var at = self.find(id)
        if at >= 0:
            return at
        self.tests.append(TestResult(
            id, OUTCOME_RUNNING, String(""), 0, 0, String(""), String(""),
            self.version + 1,
        ))
        self._index[id] = len(self.tests) - 1
        return len(self.tests) - 1

    # --- input --------------------------------------------------------

    def poll(mut self) -> Bool:
        """Read whatever the runner appended since the last poll. True
        when something changed."""
        if len(self.path.as_bytes()) == 0:
            return False
        var info = stat_file(self.path)
        if not info.ok or Int(info.size) <= self._offset:
            return False
        var c_path = self.path + String("\0")
        var fd = external_call["open", Int32](c_path.unsafe_ptr(), O_RDONLY)
        if fd < 0:
            return False
        var before = self.version
        var buf = alloc_zero_buffer(65536)
        var budget = _MAX_POLL_BYTES
        while budget > 0:
            var n = external_call["pread", Int](
                fd, buf.unsafe_ptr(), 65536, self._offset,
            )
            if n <= 0:
                break
            self._offset += n
            budget -= n
            self.feed(Span[UInt8, origin_of(buf)](
                unsafe_ptr=buf.unsafe_ptr(), length=n,
            ))
        _ = external_call["close", Int32](fd)
        return self.version != before

    def feed(mut self, bytes: Span[UInt8, _]):
        """Take the next bytes of the report: every complete line is an
        event, and an incomplete last one waits for the rest."""
        for i in range(len(bytes)):
            var b = bytes[i]
            if b != 0x0A:
                self._partial.append(b)
                continue
            if len(self._partial) > 0:
                var line = String(StringSpan(
                    unsafe_from_utf8=Span(self._partial)
                ))
                self._partial = List[UInt8]()
                self.feed_line(line)

    def feed_line(mut self, line: String):
        """Apply one event. A line that isn't a JSON object is skipped, so
        a runner's stray write can't wedge the report."""
        try:
            var ev = parse_json(line)
            if not ev.is_object():
                return
            var kind = json_get_string(ev, String("event"))
            if kind == String("collected"):
                self.total = json_get_int(ev, String("total"), self.total)
            elif kind == String("start"):
                var id = json_get_string(ev, String("id"))
                var at = self._entry(id)
                if len(self.tests[at].file.as_bytes()) == 0:
                    self.tests[at].file = json_get_string(ev, String("file"))
                    self.tests[at].line = json_get_int(ev, String("line"), 0)
                    self.tests[at].stamp = self.version + 1
                self.current = id
            elif kind == String("result"):
                var id = json_get_string(ev, String("id"))
                var outcome = outcome_from_name(
                    json_get_string(ev, String("outcome"))
                )
                var at = self._entry(id)
                # A second result for the same id (a rerun plugin) replaces
                # the first, in the counts too.
                var prev = self.tests[at].outcome
                if prev != OUTCOME_RUNNING:
                    self.counts[Int(prev)] -= 1
                self.counts[Int(outcome)] += 1
                if id == self.current:
                    self.current = String("")
                ref t = self.tests[at]
                t.outcome = outcome
                var file = json_get_string(ev, String("file"))
                if len(file.as_bytes()) > 0:
                    t.file = file
                    t.line = json_get_int(ev, String("line"), 0)
                t.duration_ms = json_get_int(ev, String("duration_ms"), 0)
                t.message = json_get_string(ev, String("message"))
                t.output = json_get_string(ev, String("output"))
                t.stamp = self.version + 1
            elif kind == String("finish"):
                self.finished = True
                self.current = String("")
                self.exit_code = json_get_int(
                    ev, String("exit_code"), self.exit_code,
                )
            else:
                return
            self.events += 1
            self.version += 1
        except:
            return


def new_test_report_path() -> String:
    """A fresh report file for one run, under
    ``~/.cache/turbokod/test-reports`` (empty without ``$HOME``)."""
    var home = getenv_value(String("HOME"))
    if len(home.as_bytes()) == 0:
        return String("")
    var pid = Int(external_call["getpid", Int32]())
    return home + String("/.cache/turbokod/test-reports/") + String(pid) \
        + String("-") + String(monotonic_ms()) + String(".jsonl")


def session_test_report_path(session: String) -> String:
    """The report file of the tmux session ``session``'s test runs: named
    after the session, so a pane re-attached after a restart finds it."""
    var home = getenv_value(String("HOME"))
    if len(home.as_bytes()) == 0 or len(session.as_bytes()) == 0:
        return String("")
    return home + String("/.cache/turbokod/test-reports/tmux-") + session \
        + String(".jsonl")


def pytest_plugin_dir() -> String:
    """Directory holding the pytest plugin, for ``PYTHONPATH``: a copy of
    the bundled one under ``~/.cache/turbokod/pytest_plugin``, so Python
    writes its ``__pycache__`` there rather than into the (signed) app
    bundle. Empty when the bundled plugin isn't there (a frontend running
    away from its resources) or the copy can't be made."""
    var src = realpath(PYTEST_PLUGIN_DIR + String("/turbokod_pytest.py"))
    if len(src.as_bytes()) == 0:
        return String("")
    var home = getenv_value(String("HOME"))
    if len(home.as_bytes()) == 0:
        return String("")
    var dir = home + String("/.cache/turbokod/pytest_plugin")
    var dst = dir + String("/turbokod_pytest.py")
    try:
        var text = read_existing_file(src)
        if read_file(dst) != text:
            make_parent_dirs(dst)
            if not write_file(dst, text):
                return String("")
    except:
        return String("")
    return dir


def reporting_env(report_path: String, pytest_plugin: String) -> List[String]:
    """``NAME=value`` assignments that make a run report into
    ``report_path``: the path itself, and, when ``pytest_plugin`` is a
    directory, what loads the bundled plugin into a pytest (on
    ``PYTHONPATH``, and ``-p`` in ``PYTEST_ADDOPTS``), each added to the
    value this process has."""
    var out = List[String]()
    if len(report_path.as_bytes()) == 0:
        return out^
    out.append(TEST_REPORT_ENV + String("=") + report_path)
    if len(pytest_plugin.as_bytes()) > 0:
        var pp = getenv_value(String("PYTHONPATH"))
        var path = pytest_plugin
        if len(pp.as_bytes()) > 0:
            path = path + String(":") + pp
        out.append(String("PYTHONPATH=") + path)
        var opts = getenv_value(String("PYTEST_ADDOPTS"))
        var p = String("-p turbokod_pytest")
        if len(opts.as_bytes()) > 0:
            p = opts + String(" ") + p
        out.append(String("PYTEST_ADDOPTS=") + p)
    return out^
