"""How long does a full tokenize of a file take, and did it change?

Opening a file — and any edit that changes a scope from the top (an
unclosed string or comment) — tokenizes the whole buffer in one go, so
this is the latency of both. For each file given: the best of ``reps``
full passes, the highlight count and a checksum over every highlight
(row, columns and colors), so an optimization can be shown to leave the
output byte-for-byte alone.

    ./run.sh bench/tokenize_bench.mojo src/turbokod/desktop.mojo app/swift/TurboKod.swift
    TK_BENCH_REPS=20 ./run.sh bench/tokenize_bench.mojo <files…>
    TK_BENCH_DUMP=1 ./run.sh bench/tokenize_bench.mojo <file>   # every highlight

Run from the repository root: grammars load relative to the working
directory.
"""

from std.sys import argv

from turbokod.file_io import read_file
from turbokod.highlight import (
    GrammarRegistry, HighlightCache, HighlightList, extension_of,
    sync_highlights,
)
from std.time import perf_counter_ns

from turbokod.posix import getenv_value
from turbokod.string_utils import parse_int_all, split_lines


def _checksum(hls: HighlightList) -> UInt64:
    """FNV-1a over every highlight's position and colors."""
    var h: UInt64 = 0xCBF29CE484222325
    for i in range(len(hls)):
        var hl = hls[i]
        var words = [
            hl.row, hl.col_start, hl.col_end, Int(hl.attr.fg),
            Int(hl.attr.bg), Int(hl.attr.style),
        ]
        for w in words:
            h = (h ^ UInt64(w)) * 0x100000001B3
    return h


def main() raises:
    var args = argv()
    if len(args) < 2:
        print("usage: tokenize_bench <file>…")
        return
    var reps = 5
    var reps_env = getenv_value(String("TK_BENCH_REPS"))
    if len(reps_env.as_bytes()) > 0:
        reps = parse_int_all(reps_env)
    var dump = len(getenv_value(String("TK_BENCH_DUMP")).as_bytes()) > 0
    var registry = GrammarRegistry()
    for a in range(1, len(args)):
        var path = String(args[a])
        var lines = split_lines(read_file(path))
        var ext = extension_of(path)
        var best_ns = 0
        var count = 0
        var sum: UInt64 = 0
        # Distinct end-of-line scope stacks, and the deepest: a grammar
        # that loses track of a scope shows up as both running away.
        var states = 0
        var deepest = 0
        # One extra pass first: it compiles the grammar's regexes.
        for rep in range(reps + 1):
            var cache = HighlightCache()
            var hls = HighlightList()
            var t0 = Int(perf_counter_ns())
            sync_highlights(ext, lines, 0, registry, cache, hls, -1)
            var took = Int(perf_counter_ns()) - t0
            if rep == 1 or (rep > 1 and took < best_ns):
                best_ns = took
            count = len(hls)
            sum = _checksum(hls)
            states = len(cache.stacks.stacks)
            deepest = 0
            for k in range(states):
                if len(cache.stacks.stacks[k]) > deepest:
                    deepest = len(cache.stacks.stacks[k])
        if dump:
            var cache = HighlightCache()
            var hls = HighlightList()
            sync_highlights(ext, lines, 0, registry, cache, hls, -1)
            for i in range(len(hls)):
                var hl = hls[i]
                print(
                    hl.row, hl.col_start, hl.col_end, Int(hl.attr.fg),
                    Int(hl.attr.bg), Int(hl.attr.style),
                )
        print(
            path, ": ", len(lines), " lines, ", count, " highlights, ",
            best_ns // 1000, " us, checksum ", sum, ", ", states,
            " states, deepest ", deepest, sep="",
        )
    registry.release()
