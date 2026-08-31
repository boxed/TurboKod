"""What does a mouse-wheel notch in the git view's file list actually cost?

``bench/git_view_bench.mojo`` times ``LocalChanges`` on its own, which
answers "is the modal's own paint slow?" but not "is a wheel notch
slow?" — the modal is painted by ``Desktop.paint``, on top of a full
workspace repaint that happens whether or not anything under the modal
is visible. This harness drives the real thing: the same
``process_external_changes`` + ``Desktop.paint`` pair the Swift redraw
timer and ``tk_desktop_tick``/``tk_desktop_layout`` run, with the git
view up and wheel events going in at gesture rates.

    ./run.sh bench/git_frame_bench.mojo <repo-root-with-a-dirty-tree>

Borrows its frame-cost framing from ``tests/bench_draw.mojo``.
"""

from std.sys import argv

from turbokod.canvas import Canvas
from turbokod.colors import default_attr
from turbokod.desktop import Desktop
from turbokod.events import Event, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP
from turbokod.geometry import Point, Rect
from turbokod.window import Window
from turbokod.posix import monotonic_ms, sleep_ms


comptime _COLS = 200
comptime _ROWS = 50
comptime _SCREEN = Rect(0, 0, _COLS, _ROWS)


def _report(name: String, iters: Int, total_ms: Int):
    var us = (total_ms * 1000) // iters if iters > 0 else 0
    print(
        name, ": ", total_ms, " ms / ", iters, " = ", us // 1000, ".",
        (us // 100) % 10, " ms/frame", sep="",
    )


def _frame(mut d: Desktop, mut canvas: Canvas) raises:
    """Exactly what the host does per redraw: tick, then lay out."""
    d.process_external_changes(_SCREEN)
    d.lsp_tick(_SCREEN)
    d.dap_tick(_SCREEN)
    d.terminal_tick()
    d.save_actions_tick()
    canvas.clear(default_attr())
    d.paint(canvas, _SCREEN)


def main() raises:
    var args = argv()
    if len(args) < 2:
        print("usage: bench_git_frame <repo-root>")
        return
    var root = String(args[1])
    var d = Desktop()
    d.open_project(root)
    # A real editor window, like the app always has: the modal paints on
    # top of the workspace, so what's underneath is part of the frame
    # cost whether or not any of it is visible.
    d.windows.add(
        Window.from_file(
            String("desktop.mojo"),
            Rect(0, 1, _COLS, _ROWS - 1),
            String("src/turbokod/desktop.mojo"),
        )
    )
    var canvas = Canvas(_COLS, _ROWS)
    # Warm up: cold grammar compile + first-frame deferrals shouldn't
    # land in the steady-state numbers.
    for _ in range(5):
        _frame(d, canvas)

    var n0 = 40
    var w0 = monotonic_ms()
    for _ in range(n0):
        _frame(d, canvas)
    var w1 = monotonic_ms()
    _report(String("idle frame, no modal    "), n0, w1 - w0)

    d.local_changes.open(root)
    for _ in range(3):
        _frame(d, canvas)
    print("files in the list: ", len(d.local_changes.files), sep="")

    # ---- 1. a frame with nothing moving ------------------------------
    var n = 40
    var t0 = monotonic_ms()
    for _ in range(n):
        _frame(d, canvas)
    var t1 = monotonic_ms()
    _report(String("idle frame, git view up "), n, t1 - t0)

    # ---- 1b. what's left in the frame with the modal up --------------
    # The modal's own paint is ~0.03 ms (bench/git_view_bench.mojo), so
    # whatever remains is Desktop.paint's pre-paint housekeeping.
    var m = 200
    var h0 = monotonic_ms()
    for _ in range(m):
        d._apply_view_config()
    var h1 = monotonic_ms()
    _report(String("  _apply_view_config     "), m, h1 - h0)
    h0 = monotonic_ms()
    for _ in range(m):
        d._rebuild_window_menu()
    h1 = monotonic_ms()
    _report(String("  _rebuild_window_menu   "), m, h1 - h0)
    h0 = monotonic_ms()
    for _ in range(m):
        d._refresh_shortcuts()
    h1 = monotonic_ms()
    _report(String("  _refresh_shortcuts     "), m, h1 - h0)
    h0 = monotonic_ms()
    for _ in range(m):
        d._refresh_target_tabs()
    h1 = monotonic_ms()
    _report(String("  _refresh_target_tabs   "), m, h1 - h0)
    h0 = monotonic_ms()
    for _ in range(m):
        d.windows.fit_into(d.workspace_rect(_SCREEN))
    h1 = monotonic_ms()
    _report(String("  windows.fit_into       "), m, h1 - h0)
    h0 = monotonic_ms()
    for _ in range(m):
        d.local_changes.paint(canvas, _SCREEN, d.grammar_registry)
    h1 = monotonic_ms()
    _report(String("  local_changes.paint    "), m, h1 - h0)

    # ---- 2. how far one wheel notch travels --------------------------
    # The pointer has to sit over the files pane for the wheel to route
    # there; the pane starts a few rows down from the modal's top edge.
    var over_files = Point(6, 8)
    var before_sel = d.local_changes.sel_file
    var before_scroll = d.local_changes.scroll_files
    _ = d.local_changes.handle_mouse(
        Event.mouse_event(over_files, MOUSE_WHEEL_DOWN),
        _SCREEN, d.grammar_registry,
    )
    print(
        "one notch moves: sel ", before_sel, "->", d.local_changes.sel_file,
        "  scroll ", before_scroll, "->", d.local_changes.scroll_files,
        sep="",
    )

    # ---- 3. a wheel gesture at trackpad rates ------------------------
    # macOS delivers momentum events at the display rate; the host
    # integrates precise deltas into one notch per two cell-rows, so a
    # hard flick lands notches every ~16 ms for a second or more.
    for interval in [8, 16, 33]:
        var worst = 0
        var total = 0
        var reps = 30
        var start_scroll = d.local_changes.scroll_files
        for _ in range(reps):
            _ = d.local_changes.handle_mouse(
                Event.mouse_event(over_files, MOUSE_WHEEL_DOWN),
                _SCREEN, d.grammar_registry,
            )
            var f0 = monotonic_ms()
            _frame(d, canvas)
            var f1 = monotonic_ms()
            total += f1 - f0
            if f1 - f0 > worst: worst = f1 - f0
            var left = interval - (f1 - f0)
            if left > 0: sleep_ms(left)
        print(
            "notch every ", interval, " ms -> frame avg ", total // reps,
            " ms  worst ", worst, " ms  travelled ",
            d.local_changes.scroll_files - start_scroll, " rows in ", reps,
            " notches", sep="",
        )
        # Let it settle so the next run starts from a quiet state.
        sleep_ms(500)
        _frame(d, canvas)

    # Scroll back up so a re-run starts near the top.
    for _ in range(120):
        _ = d.local_changes.handle_mouse(
            Event.mouse_event(over_files, MOUSE_WHEEL_UP),
            _SCREEN, d.grammar_registry,
        )
    print("=== done ===")
