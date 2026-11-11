"""Live test reporting for TurboKod's test pane.

TurboKod loads this plugin (``PYTEST_ADDOPTS=-p turbokod_pytest``, with this
directory on ``PYTHONPATH``) when it runs pytest, and sets
``TURBOKOD_TEST_REPORT`` to a file. The plugin appends one JSON object per line
to that file as the run goes: the number of tests collected, each test as it
starts, each test's outcome (with its failure output), and the end of the run.
The protocol is runner-agnostic and documented in ``docs/test-reporting.md``.

Without ``TURBOKOD_TEST_REPORT`` the plugin does nothing. It removes the
variable from the environment once it has read it, so a pytest that a test
runs in a subprocess doesn't write into this run's report.

Under pytest-xdist only the controller reports: it sees every worker's results
through the usual hooks, and the workers never get the variable.
"""

import json
import os

import pytest

_ENV = "TURBOKOD_TEST_REPORT"


class _Reporter:
    def __init__(self, config, path):
        self.config = config
        self.root = str(config.rootpath)
        # Line-buffered append: TurboKod tails the file, and a reader that
        # sees half a line waits for the rest of it.
        self.out = open(path, "a", encoding="utf-8", errors="replace", buffering=1)
        self.collected_sent = False
        self.pending = {}

    def emit(self, **event):
        try:
            self.out.write(json.dumps(event, ensure_ascii=False) + "\n")
            self.out.flush()
        except (OSError, ValueError):
            pass

    def location(self, report):
        loc = getattr(report, "location", None)
        if not loc:
            return "", 0
        path, line, _ = loc
        if not os.path.isabs(path):
            path = os.path.join(self.root, path)
        return path, (line + 1) if line is not None else 0

    # --- collection -------------------------------------------------------

    def collected(self, total):
        self.collected_sent = True
        self.emit(event="collected", total=total)

    @pytest.hookimpl(trylast=True)
    def pytest_collection_finish(self, session):
        # The xdist controller collects nothing itself; its workers report.
        if self.config.pluginmanager.hasplugin("dsession"):
            return
        self.collected(len(session.items))

    @pytest.hookimpl(optionalhook=True)
    def pytest_xdist_node_collection_finished(self, node, ids):
        # Every worker collects the whole suite; the first one says how big
        # it is.
        if not self.collected_sent:
            self.collected(len(ids))

    def pytest_collectreport(self, report):
        if report.failed:
            path = str(getattr(report, "fspath", "") or "")
            if path and not os.path.isabs(path):
                path = os.path.join(self.root, path)
            self.emit(
                event="result", id=report.nodeid or path, outcome="error",
                file=path, line=0, duration_ms=0,
                message="collection failed", output=_longrepr(report),
            )

    # --- tests --------------------------------------------------------------

    def pytest_runtest_logstart(self, nodeid, location):
        path, line, _ = location
        if path and not os.path.isabs(path):
            path = os.path.join(self.root, path)
        self.emit(
            event="start", id=nodeid, file=path,
            line=(line + 1) if line is not None else 0,
        )

    def pytest_runtest_logreport(self, report):
        # One test makes three reports (setup, call, teardown); fold them
        # into one result, sent with the teardown, which always comes last.
        p = self.pending.setdefault(report.nodeid, {
            "outcome": "passed", "duration": 0.0, "message": "", "output": [],
        })
        p["duration"] += getattr(report, "duration", 0.0) or 0.0
        outcome = _outcome(report)
        if outcome is not None and _rank(outcome) > _rank(p["outcome"]):
            p["outcome"] = outcome
            p["message"] = _message(report, outcome)
        if report.failed:
            text = _longrepr(report)
            if text:
                p["output"].append(text)
            for name, content in getattr(report, "sections", []):
                if content.strip():
                    p["output"].append("----- " + name + " -----\n" + content)
        if report.when != "teardown":
            return
        del self.pending[report.nodeid]
        path, line = self.location(report)
        output = ""
        if p["outcome"] in ("failed", "error"):
            output = "\n".join(p["output"])
        self.emit(
            event="result", id=report.nodeid, outcome=p["outcome"],
            file=path, line=line, duration_ms=int(p["duration"] * 1000),
            message=p["message"], output=output,
        )

    def pytest_sessionfinish(self, session, exitstatus):
        self.emit(event="finish", exit_code=int(exitstatus))
        try:
            self.out.close()
        except OSError:
            pass


def _outcome(report):
    """This phase's contribution to the test's outcome, or None."""
    xfail = hasattr(report, "wasxfail")
    if report.when == "call":
        if xfail:
            return "xfailed" if report.skipped else "xpassed"
        if report.failed:
            return "failed"
        if report.skipped:
            return "skipped"
        return "passed"
    if report.failed:
        return "error"
    if report.skipped:
        return "xfailed" if xfail else "skipped"
    return None


_RANKS = {"passed": 0, "xpassed": 1, "skipped": 2, "xfailed": 3, "failed": 4, "error": 5}


def _rank(outcome):
    return _RANKS.get(outcome, 0)


def _message(report, outcome):
    if outcome in ("skipped", "xfailed") and isinstance(report.longrepr, tuple):
        # (path, line, "Skipped: reason")
        return str(report.longrepr[2])
    if outcome == "xfailed":
        return str(getattr(report, "wasxfail", ""))
    crash = getattr(report.longrepr, "reprcrash", None)
    if crash is not None:
        return str(crash.message).split("\n", 1)[0]
    if outcome == "error":
        return "error in " + report.when
    return ""


def _longrepr(report):
    try:
        text = report.longreprtext or ""
    except Exception:
        text = str(report.longrepr or "")
    # xdist heads a worker's traceback with "[gw0] darwin -- Python 3.12 ...".
    if text.startswith("[gw"):
        text = text.split("\n", 1)[1] if "\n" in text else ""
    return text.lstrip("\n")


def pytest_configure(config):
    if hasattr(config, "workerinput"):
        return  # an xdist worker: the controller reports
    path = os.environ.pop(_ENV, "")
    if not path:
        return
    config.pluginmanager.register(_Reporter(config, path), "turbokod-reporter")
