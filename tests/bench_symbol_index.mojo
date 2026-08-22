"""Does the identifier index actually beat a subprocess per keystroke?

Lives under ``tests/`` next to ``bench_draw.mojo`` rather than in
``bench/``: as a ``bench/`` entry point this file took over ten minutes
to compile (the query loop below, written as a loop over a
``List[String]`` of needles, tripped the same compile-time cliff that
split ``test_basic.mojo`` into per-topic suites). Unrolled and moved, it
builds in seconds. If you add cases here, add them unrolled.

Run against a real checkout — the bigger the better, since the whole
point is that the old design's cost scaled with the project while the
new one's scales with the project's *vocabulary*:

    ./run.sh tests/bench_symbol_index.mojo /path/to/some/large/repo

With no argument it benchmarks turbokod itself, which is too small to
show anything interesting (a few hundred files) — the numbers only mean
something on a repo of thousands.

What to compare it against: on a 10,844-file / 82 MB checkout, the
``rg`` invocation this replaces measured 160–490 ms of wall clock and
~2.7 s of CPU *per keystroke* (``rg --stats`` reported 2.67 s "spent
searching" for the old ``\\b[A-Za-z0-9_]*Q[A-Za-z0-9_]*\\b`` pattern
against 0.11 s for the equivalent ``-F`` literal — the regex was
vacuous and 25x the cost). So the bar for "query" below is
single-digit milliseconds, and the bar for "build" is "cheap enough to
amortize over one picker session".
"""

from std.collections.list import List
from std.sys import argv

from turbokod.file_io import join_path, list_directory_typed
from turbokod.posix import monotonic_ms
from turbokod.symbol_index import SymbolIndex


def _skip_dir(name: String) -> Bool:
    """Directories a project walk has no business entering. Hand-rolled
    rather than reusing ``project.walk_project_files`` on purpose: that
    module pulls most of the core into this entry point's import graph,
    and a fresh ``mojo build`` of it ran past eleven minutes. Every
    bench entry point is compiled by ``make check``, so keeping this one
    light is not optional."""
    return name == String(".git") or name == String("node_modules") \
        or name == String("target") or name == String(".venv") \
        or name == String("venv") or name == String("__pycache__") \
        or name == String(".build") or name == String("build") \
        or name == String(".pixi") or name == String("dist")


def _walk(root: String) -> List[String]:
    """Iterative DFS over ``root``, absolute paths of regular files."""
    var out = List[String]()
    var dirs = List[String]()
    dirs.append(root)
    while len(dirs) > 0:
        var dir = dirs.pop()
        var entries = list_directory_typed(dir)
        for i in range(len(entries)):
            var name = entries[i][0]
            var is_dir = entries[i][1]
            if is_dir:
                if not _skip_dir(name):
                    dirs.append(join_path(dir, name))
            else:
                out.append(join_path(dir, name))
    return out^


def _ms(v: Int) -> String:
    return String(v) + String(" ms")


def _per(total_ms: Int, reps: Int) -> String:
    """Microseconds per repetition — the unit a keystroke lives in."""
    if reps <= 0:
        return String("n/a")
    return String((total_ms * 1000) // reps) + String(" us")


def _query(mut idx: SymbolIndex, needle: String, reps: Int) -> Int:
    """Time ``reps`` queries for one needle and print the per-query cost.

    A function rather than a loop body: see the module docstring."""
    var t0 = monotonic_ms()
    var hits = 0
    for _ in range(reps):
        hits = len(idx.search(needle, 500))
    var t1 = monotonic_ms()
    print("  ", needle, _per(t1 - t0, reps), " hits:", hits)
    return hits


def main() raises:
    var root = String(".")
    var args = argv()
    if len(args) > 1:
        root = String(args[1])
    print("root:", root)

    var t0 = monotonic_ms()
    var files = _walk(root)
    var t1 = monotonic_ms()
    print("walk:                 ", _ms(t1 - t0), " files:", len(files))

    var idx = SymbolIndex()
    idx.reset(root)
    t0 = monotonic_ms()
    idx.set_file_list(files)
    while idx.build_step(1 << 30):
        pass
    t1 = monotonic_ms()
    print("build (read+tokenize):", _ms(t1 - t0))
    print("  entries:            ", idx.entry_count())
    print("  blob bytes:         ", idx.blob_bytes())

    # Incremental build: what the host actually does, a slice per frame.
    idx.reset(root)
    t0 = monotonic_ms()
    idx.set_file_list(files)
    var steps = 0
    while idx.build_step(1 << 20):    # 1 MiB of file content per frame
        steps += 1
    t1 = monotonic_ms()
    print("build, 1 MiB/frame:   ", _ms(t1 - t0), " frames:", steps + 1)

    # The number that matters: one keystroke.
    var reps = 20
    print("")
    print("--- query (cap 500), x", reps, "each ---")
    var sink = 0
    sink += _query(idx, String("as"), reps)
    sink += _query(idx, String("get"), reps)
    sink += _query(idx, String("self"), reps)
    sink += _query(idx, String("value"), reps)
    sink += _query(idx, String("handle_key"), reps)
    sink += _query(idx, String("zzz_definitely_absent"), reps)

    # Revalidation: the staleness sweep on an unchanged tree — what a
    # picker open costs when nothing moved.
    print("")
    t0 = monotonic_ms()
    idx.begin_revalidation()
    while idx.revalidate_step(1 << 30):
        pass
    t1 = monotonic_ms()
    print("revalidate, unchanged:", _ms(t1 - t0), " stats:", len(files))

    # And one file changing — the targeted patch path.
    if len(files) > 0:
        t0 = monotonic_ms()
        for _ in range(20):
            _ = idx.reindex_file(files[0])
        t1 = monotonic_ms()
        print("reindex one file:     ", _per(t1 - t0, 20))

    print("")
    print("(sink", sink, ")")
