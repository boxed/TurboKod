"""Timing harness for the Local-changes (git view) file list.

Answers one question: what does moving the selection one row cost when
the repo has many changed files? Point it at a repo with a dirty tree:

    ./run.sh bench/git_view_bench.mojo <repo-root>
"""

from std.sys import argv

from turbokod.canvas import Canvas
from turbokod.events import Event, KEY_DOWN
from turbokod.geometry import Rect
from turbokod.highlight import GrammarRegistry
from turbokod.file_io import join_path, read_file
from turbokod.git_changes import fetch_blob_text, fetch_git_status, git_state_mtimes
from turbokod.highlight import (
    HighlightCache, extension_of, highlight_for_extension_cached,
)
from turbokod.local_changes import LocalChanges
from turbokod.posix import monotonic_ms, sleep_ms
from turbokod.string_utils import split_lines_no_trailing


def main():
    var args = argv()
    var root = String(args[1]) if len(args) > 1 else String(".")
    var screen = Rect(0, 0, 200, 50)
    var registry = GrammarRegistry()

    var t0 = monotonic_ms()
    var lc = LocalChanges()
    lc.open(root)
    var t1 = monotonic_ms()
    print("open():                  ", t1 - t0, "ms")
    print("files:                   ", len(lc.files))

    var canvas = Canvas(200, 50)
    t0 = monotonic_ms()
    lc.paint(canvas, screen, registry)
    t1 = monotonic_ms()
    print("first paint:             ", t1 - t0, "ms")

    # Steady-state repaint with the selection unchanged: this is what a
    # frame costs when nothing moved.
    var n = 60
    t0 = monotonic_ms()
    for _ in range(n):
        lc.paint(canvas, screen, registry)
    t1 = monotonic_ms()
    print("repaint, no move:        ", (t1 - t0), "ms /", n, "frames")

    # One row down + repaint, repeated: the arrow-key hold.
    var moves = 40
    t0 = monotonic_ms()
    for _ in range(moves):
        _ = lc.handle_key(Event.key_event(KEY_DOWN), screen, registry)
        lc.paint(canvas, screen, registry)
    t1 = monotonic_ms()
    print("move+paint:              ", (t1 - t0), "ms /", moves, "moves =",
          (t1 - t0) // moves, "ms per move")
    # Realistic key-repeat: macOS default repeat interval is ~90 ms,
    # which is LONGER than the paint path's settle debounce, so every
    # repeat pays a full right-panel rebuild. Measure the frame that
    # follows each settled move.
    for interval in [30, 60, 90, 120, 400]:
        var worst = 0
        var total = 0
        var reps = 12
        for _ in range(reps):
            _ = lc.handle_key(Event.key_event(KEY_DOWN), screen, registry)
            sleep_ms(interval)
            var s0 = monotonic_ms()
            lc.paint(canvas, screen, registry)
            var s1 = monotonic_ms()
            total += s1 - s0
            if s1 - s0 > worst: worst = s1 - s0
        # Release the key: the very next settled frame must fill the
        # panels in, or the debounce is swallowing the build entirely.
        sleep_ms(500)
        var r0 = monotonic_ms()
        lc.paint(canvas, screen, registry)
        var r1 = monotonic_ms()
        print("repeat every", interval, "ms -> paint avg",
              total // reps, "ms  worst", worst,
              "ms | settled frame", r1 - r0, "ms, unstaged rows",
              len(lc.unstaged.lines))

    # The 1 Hz external-change poll: a synchronous ``git status`` spawn
    # on the UI thread.
    t0 = monotonic_ms()
    for _ in range(5):
        var st = fetch_git_status(root)
        _ = len(st)
        var ms = git_state_mtimes(root)
        _ = ms
    t1 = monotonic_ms()
    print("poll (status+mtimes):    ", (t1 - t0) // 5, "ms each")

    var paths = List[String]()
    for i in range(len(lc.files)):
        paths.append(lc.files[i].path)
    lc.release()
    registry.release()
    breakdown(root, paths)


def breakdown(root: String, files: List[String]):
    """Split the per-move cost into its two halves: the ``git show``
    spawns that fetch each side's full text, and the full-file
    tokenize that colors the diff body."""
    var registry = GrammarRegistry()
    var t_blob = 0
    var t_read = 0
    var t_hl = 0
    var bytes_hl = 0
    for i in range(len(files)):
        var p = files[i]
        var t0 = monotonic_ms()
        var after = fetch_blob_text(root, String(""), p)
        var head = fetch_blob_text(root, String("HEAD"), p)
        var t1 = monotonic_ms()
        t_blob += t1 - t0
        t0 = monotonic_ms()
        var work: String
        try:
            work = read_file(join_path(root, p))
        except:
            work = String("")
        t1 = monotonic_ms()
        t_read += t1 - t0
        # Tokenize both sides, exactly as the panel builder does.
        t0 = monotonic_ms()
        for side in [work, after, head]:
            if len(side.as_bytes()) == 0 or len(side.as_bytes()) > 64 * 1024:
                continue
            var lines = split_lines_no_trailing(side)
            var cache = HighlightCache()
            _ = highlight_for_extension_cached(
                extension_of(p), lines, registry, cache,
            )
            bytes_hl += len(side.as_bytes())
        t1 = monotonic_ms()
        t_hl += t1 - t0
    print("--- per-file breakdown over", len(files), "files")
    print("  git show x2:           ", t_blob, "ms")
    print("  read worktree file:    ", t_read, "ms")
    print("  tokenize 3 sides:      ", t_hl, "ms  (", bytes_hl // 1024, "KiB )")
    registry.release()
