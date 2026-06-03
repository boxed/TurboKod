"""Headless micro-profiler for the per-frame drawing path.

Replicates exactly what the Swift redraw timer drives every frame —
``tk_desktop_tick`` (housekeeping) followed by ``tk_desktop_layout``
(fresh Canvas + ``Desktop.paint`` + cell-pack) — but with no GUI, so it
runs anywhere and gives deterministic per-phase timings instead of
guesswork. Build/run with ``./run.sh tests/bench_draw.mojo``.

Each phase is timed over many iterations and reported as microseconds
per frame; multiply by the frame rate (20 Hz active, 4 Hz idle) to get
the steady CPU cost of that phase.
"""

from std.ffi import external_call

from turbokod.canvas import Canvas
from turbokod.colors import default_attr
from turbokod.desktop import Desktop
from turbokod.file_io import write_file
from turbokod.geometry import Point, Rect
from turbokod.posix import getenv_value, monotonic_ms
from turbokod.string_utils import codepoint_at
from turbokod.window import Window


comptime _COLS = 120
comptime _ROWS = 40
comptime _SCREEN = Rect(0, 0, _COLS, _ROWS)


def _bench(name: String, iters: Int, total_ms: Int):
    # us/frame = total_ms * 1000 / iters
    var us_per = (total_ms * 1000) // iters if iters > 0 else 0
    var at20 = us_per * 20  # us/sec at 20 Hz  -> /10000 = % of one core
    print(
        name,
        ": ",
        total_ms,
        " ms /",
        iters,
        " iters = ",
        us_per,
        " us/frame  (~",
        at20// 100,
        ".",
        (at20 // 10) % 10,
        "% of one core @20Hz)",
        sep="",
    )


def main() raises:
    # A real, large source file so highlighting (flush_highlights inside
    # paint) is exercised the way it is in the app. desktop.mojo is ~9k
    # lines; only _ROWS are visible, matching real paint cost.
    var d = Desktop()
    d.windows.add(
        Window.from_file(
            String("desktop.mojo"),
            Rect(0, 1, _COLS, _ROWS - 1),
            String("src/turbokod/desktop.mojo"),
        )
    )

    var canvas = Canvas(_COLS, _ROWS)

    # Warmup: first paint compiles the grammar + does the cold full
    # tokenize. We measure steady state, not cold start.
    for _ in range(5):
        canvas.clear(default_attr())
        d.paint(canvas, _SCREEN)

    # Spin mode: loop Desktop.paint for ~25 s so an external sampling
    # profiler (`sample <pid>`) can attach and get a function-level
    # breakdown of where paint's time goes. Enabled with TK_BENCH_SPIN=1.
    if len(getenv_value(String("TK_BENCH_SPIN")).as_bytes()) > 0:
        print("spin: looping Desktop.paint for ~25s (attach `sample` now)")
        var start = monotonic_ms()
        var frames = 0
        while monotonic_ms() - start < 25000:
            canvas.clear(default_attr())
            d.paint(canvas, _SCREEN)
            frames += 1
        print("spin done:", frames, "frames")
        return

    print(
        "highlights in buffer: ",
        len(d.windows.windows[0].editor.highlights),
        "  visible rows: ",
        _ROWS - 1,
        sep="",
    )
    print("=== per-frame drawing path (", _COLS, "x", _ROWS, ") ===", sep="")

    # ---- Phase 1: full steady-state paint (the hot path) -------------
    # Canvas reused; this is Desktop.paint = flush_highlights (clean ->
    # cheap) + all widget draw into the grid.
    var N = 2000
    var t0 = monotonic_ms()
    for _ in range(N):
        canvas.clear(default_attr())
        d.paint(canvas, _SCREEN)
    var t1 = monotonic_ms()
    _bench(String("paint (clear+Desktop.paint)"), N, t1 - t0)

    # ---- Phase 2: fresh Canvas alloc + clear -------------------------
    # tk_desktop_layout allocates a NEW Canvas every frame (3 u32... no:
    # Cell.glyph is String). Isolate that allocation cost.
    var t2 = monotonic_ms()
    for _ in range(N):
        var c = Canvas(_COLS, _ROWS)
        c.clear(default_attr())
        # touch a cell so the alloc can't be optimized away
        if len(c.cells) == 0:
            print("unreachable")
    var t3 = monotonic_ms()
    _bench(String("Canvas(cols,rows)+clear (per-frame alloc)"), N, t3 - t2)

    # ---- Phase 3: cell-pack loop (canvas -> u32 buffer) --------------
    var ncells = _COLS * _ROWS
    var out = List[UInt32]()
    for _ in range(ncells * 3):
        out.append(0)
    canvas.clear(default_attr())
    d.paint(canvas, _SCREEN)
    var P = 20000
    var t4 = monotonic_ms()
    for _ in range(P):
        for i in range(ncells):
            var cell = canvas.cells[i]
            var cp = codepoint_at(cell.glyph, 0)[0]
            if cp <= 0:
                cp = 0x20
            var attr = cell.attr
            out[i * 3] = UInt32(cp)
            out[i * 3 + 1] = (
                UInt32(Int(attr.fg))
                | (UInt32(Int(attr.bg)) << 8)
                | (UInt32(Int(attr.style)) << 16)
            )
            out[i * 3 + 2] = UInt32(0xFFFFFFFF) if attr.underline_color < 0 \
                else UInt32(Int(attr.underline_color))
    var t5 = monotonic_ms()
    _bench(String("cell-pack loop (codepoint_at + pack)"), P, t5 - t4)
    if out[0] == 0xDEADBEEF:
        print("unreachable")  # keep `out` live

    # ---- Phase 3b: pointer_shape_at (runs on every mouse move) -------
    # Used to deep-copy the hovered Window (whole Editor) per call.
    var Q = 20000
    var t8 = monotonic_ms()
    for _ in range(Q):
        _ = d.pointer_shape_at(Point(10, 10), _SCREEN)
    var t9 = monotonic_ms()
    _bench(String("pointer_shape_at (per mouse move)"), Q, t9 - t8)

    # ---- Phase 4: tk_desktop_tick housekeeping -----------------------
    var t6 = monotonic_ms()
    for _ in range(N):
        d.process_external_changes(_SCREEN)
        d.lsp_tick(_SCREEN)
        d.dap_tick(_SCREEN)
        d.terminal_tick()
        d.save_actions_tick()
    var t7 = monotonic_ms()
    _bench(String("tick (external+lsp+dap+term+save)"), N, t7 - t6)

    print("=== done ===")
