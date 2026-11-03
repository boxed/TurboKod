"""Timing harness for showing a repo's newest commit in the git view.

    ./run.sh bench/commit_show_bench.mojo <repo-root>
"""

from std.sys import argv

from turbokod.geometry import Rect
from turbokod.highlight import GrammarRegistry
from turbokod.local_changes import LocalChanges, _PANE_COMMITS
from turbokod.posix import monotonic_ms


def main():
    var args = argv()
    var root = String(args[1]) if len(args) > 1 else String(".")
    var registry = GrammarRegistry()
    var bounds = Rect(0, 0, 200, 50)
    var lc = LocalChanges()
    lc.open(root)
    lc.native_select(_PANE_COMMITS, 0, bounds)
    var t0 = monotonic_ms()
    lc.native_panels(registry, bounds)
    var t1 = monotonic_ms()
    print("show commit:", t1 - t0, "ms,", len(lc.info.lines), "rows,",
          len(lc._collapsed_rows), "diffs left out")
    if len(lc._collapsed_rows) == 0:
        return
    var row = lc._collapsed_rows[0]
    lc.info.scroll = row - 5
    lc.info.cursor = row
    lc.native_open(5, row)
    t0 = monotonic_ms()
    lc.native_panels(registry, bounds)
    t1 = monotonic_ms()
    print("expand", lc._expanded_paths[0], ":", t1 - t0, "ms,",
          len(lc.info.lines), "rows; scroll kept:", lc.info.scroll == row - 5)
