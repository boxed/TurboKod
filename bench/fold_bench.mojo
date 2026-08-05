"""Micro-benchmark for turbokod's case-insensitive search paths.

Three questions:

1. How fast is the ASCII case-fold itself, branchy vs branchless vs
   explicit SIMD -- and does the "stop early at the first non-ASCII
   byte" break actually cost us (the blog post's central claim)?
2. For a whole-file search, how does today's "split into lines, run
   libonig ``(?i)`` per line" compare with "fold the blob once, then a
   plain SIMD byte search over the blob"?
3. For the pickers (quick_open / find_symbol / type_ahead), how does
   folding both sides inside the innermost compare loop compare with
   pre-folding the candidate list once?
"""

from std.collections.list import List

from turbokod.file_io import read_file
from turbokod.onig import OnigRegex, onig_global_init
from turbokod.posix import monotonic_ms
from turbokod.quick_open import (
    _split_query_to_parts as split_query_to_parts_pub, quick_open_match,
)
from turbokod.search_options import LineSearcher, SearchOptions
from turbokod.string_utils import split_lines


comptime _W = 32


# ---------------------------------------------------------------- folds


def fold_branchy_into(b: Span[UInt8, _], mut out: List[UInt8]):
    """The idiom currently spread across quick_open / type_ahead /
    find_symbol / editorconfig: per-byte compare-and-branch."""
    for i in range(len(b)):
        var c = Int(b[i])
        if 0x41 <= c and c <= 0x5A:
            c += 0x20
        out.append(UInt8(c))


def fold_branchy_stop_early(b: Span[UInt8, _], mut out: List[UInt8]) -> Int:
    """Branchy *and* bails at the first non-ASCII byte -- the shape the
    blog post measured at 3.1 GiB/s. Returns where it stopped."""
    for i in range(len(b)):
        if b[i] >= 0x80:
            return i
        var c = Int(b[i])
        if 0x41 <= c and c <= 0x5A:
            c += 0x20
        out.append(UInt8(c))
    return len(b)


def fold_branchless_into(b: Span[UInt8, _], mut out: List[UInt8]) -> UInt8:
    """Scalar branchless: OR every byte into an accumulator, set bit 5
    unconditionally from a wrapping range test. Returns the high-bit
    accumulator (``& 0x80 != 0`` -> the input had non-ASCII)."""
    var n = len(b)
    out.resize(n, 0)
    var src = b.unsafe_ptr()
    var dst = out.unsafe_ptr()
    var acc = UInt8(0)
    for i in range(n):
        var c = src[i]
        acc |= c
        var is_upper = UInt8((c - UInt8(0x41)) < UInt8(26))
        dst[i] = c | (is_upper << 5)
    return acc


def fold_simd_into(b: Span[UInt8, _], mut out: List[UInt8]) -> UInt8:
    """Explicit SIMD, 32 bytes per iteration, same branchless formula."""
    var n = len(b)
    out.resize(n, 0)
    var src = b.unsafe_ptr()
    var dst = out.unsafe_ptr()
    var acc_v = SIMD[DType.uint8, _W](0)
    var i = 0
    while i + _W <= n:
        var v = (src + i).load[width=_W]()
        acc_v |= v
        var is_upper = (v - SIMD[DType.uint8, _W](0x41)).lt(
            SIMD[DType.uint8, _W](26)
        )
        (dst + i).store(v | (is_upper.cast[DType.uint8]() << 5))
        i += _W
    var acc = acc_v.reduce_or()
    while i < n:
        var c = src[i]
        acc |= c
        var is_upper = UInt8((c - UInt8(0x41)) < UInt8(26))
        dst[i] = c | (is_upper << 5)
        i += 1
    return acc


# ------------------------------------------------------------- searches


def find_bytes(hb: Span[UInt8, _], nb: Span[UInt8, _], start: Int) -> Int:
    """``project._contains_bytes`` / ``editor.find_next`` shape: nested
    loop, inner ``break`` on the first mismatching byte."""
    var n = len(nb)
    var h = len(hb)
    if n == 0:
        return start
    if n > h:
        return -1
    for i in range(start, h - n + 1):
        var hit = True
        for k in range(n):
            if hb[i + k] != nb[k]:
                hit = False
                break
        if hit:
            return i
    return -1


def find_ci_branchy(hb: Span[UInt8, _], nb: Span[UInt8, _], start: Int) -> Int:
    """``quick_open._find_substring_ci`` shape: fold both sides *inside*
    the innermost loop."""
    var n = len(nb)
    var h = len(hb)
    if n == 0:
        return start
    if n > h:
        return -1
    for i in range(start, h - n + 1):
        var hit = True
        for k in range(n):
            var a = Int(hb[i + k])
            var c = Int(nb[k])
            if 0x41 <= a and a <= 0x5A: a += 0x20
            if 0x41 <= c and c <= 0x5A: c += 0x20
            if a != c:
                hit = False
                break
        if hit:
            return i
    return -1


def find_simd(hb: Span[UInt8, _], nb: Span[UInt8, _], start: Int) -> Int:
    """First+last byte SIMD prefilter, then verify. Haystack and needle
    are both already folded, so this is a plain byte search."""
    var n = len(nb)
    var h = len(hb)
    if n == 0:
        return start
    if n > h:
        return -1
    var p = hb.unsafe_ptr()
    var first = SIMD[DType.uint8, _W](nb[0])
    var last = SIMD[DType.uint8, _W](nb[n - 1])
    var last_i = h - n
    var i = start
    while i + _W <= last_i + 1:
        var v0 = (p + i).load[width=_W]()
        var v1 = (p + i + n - 1).load[width=_W]()
        var m = v0.eq(first) & v1.eq(last)
        if m.reduce_or():
            for k in range(_W):
                if m[k]:
                    var at = i + k
                    var ok = True
                    for j in range(1, n - 1):
                        if p[at + j] != nb[j]:
                            ok = False
                            break
                    if ok:
                        return at
        i += _W
    while i <= last_i:
        if p[i] == nb[0]:
            var ok = True
            for j in range(1, n):
                if p[i + j] != nb[j]:
                    ok = False
                    break
            if ok:
                return i
        i += 1
    return -1


def count_newlines(b: Span[UInt8, _], upto: Int) -> Int:
    """Line number of a byte offset: SIMD popcount of ``\\n``."""
    var p = b.unsafe_ptr()
    var acc = SIMD[DType.uint8, _W](0)
    var i = 0
    var total = 0
    var chunks = 0
    while i + _W <= upto:
        var v = (p + i).load[width=_W]()
        acc += v.eq(SIMD[DType.uint8, _W](0x0A)).cast[DType.uint8]() & 1
        i += _W
        chunks += 1
        # Drain before the u8 lanes could overflow at 255 hits.
        if chunks % 255 == 0:
            total += Int(acc.reduce_add())
            acc = SIMD[DType.uint8, _W](0)
    total += Int(acc.reduce_add())
    while i < upto:
        if p[i] == 0x0A:
            total += 1
        i += 1
    return total


# ----------------------------------------------------------------- main


def _rate(bytes_done: Int, ms: Int) -> String:
    if ms <= 0:
        return String("  (unmeasurable)")
    var mbs = (Float64(bytes_done) / 1048576.0) / (Float64(ms) / 1000.0)
    var s = String(Int(mbs)) + String(" MiB/s")
    while len(s.as_bytes()) < 14:
        s = String(" ") + s
    return s


def _ms(ms: Int) -> String:
    var s = String(ms) + String(" ms")
    while len(s.as_bytes()) < 8:
        s = String(" ") + s
    return s


def main() raises:
    onig_global_init()

    # Corpus: a slice of the Mojo package concatenated, as one blob and
    # as its lines. A few files carry non-ASCII (em dashes in comments).
    var names = List[String]()
    names.append(String("desktop.mojo"))
    names.append(String("editor.mojo"))
    names.append(String("project.mojo"))
    names.append(String("find_symbol.mojo"))
    names.append(String("quick_open.mojo"))
    names.append(String("highlight.mojo"))
    names.append(String("tm_tokenizer.mojo"))
    names.append(String("terminal.mojo"))
    names.append(String("native_api.mojo"))
    names.append(String("vt.mojo"))
    var blob = String("")
    for i in range(len(names)):
        blob += read_file(String("src/turbokod/") + names[i])
    var nbytes = len(blob.as_bytes())
    var lines = split_lines(blob)
    print("corpus:", nbytes, "bytes,", len(lines), "lines")

    var bb = blob.as_bytes()
    var first_non_ascii = -1
    for i in range(nbytes):
        if bb[i] >= 0x80:
            first_non_ascii = i
            break
    print("first non-ASCII byte at:", first_non_ascii)
    print("")

    var needle = String("SelectionHistory")
    var needle_lc = String("selectionhistory")
    var nb = needle_lc.as_bytes()

    # --- 1. raw fold throughput ---------------------------------------
    print("--- 1. case-fold throughput (", nbytes, "bytes x 200 reps) ---")
    var reps = 200
    var scratch = List[UInt8](capacity=nbytes)
    var sink = 0

    var t0 = monotonic_ms()
    for _ in range(reps):
        scratch.clear()
        fold_branchy_into(blob.as_bytes(), scratch)
    var t1 = monotonic_ms()
    sink += len(scratch)
    print("branchy, whole buffer:      ", _ms(t1 - t0),
          _rate(nbytes * reps, t1 - t0))

    t0 = monotonic_ms()
    for _ in range(reps):
        scratch.clear()
        sink += fold_branchy_stop_early(blob.as_bytes(), scratch)
    t1 = monotonic_ms()
    print("branchy + stop-early break: ", _ms(t1 - t0),
          _rate(first_non_ascii * reps, t1 - t0),
          " (bailed at byte", first_non_ascii, "of", nbytes, ")")

    t0 = monotonic_ms()
    for _ in range(reps):
        sink += Int(fold_branchless_into(blob.as_bytes(), scratch))
    t1 = monotonic_ms()
    print("scalar branchless:          ", _ms(t1 - t0),
          _rate(nbytes * reps, t1 - t0))

    t0 = monotonic_ms()
    for _ in range(reps):
        sink += Int(fold_simd_into(blob.as_bytes(), scratch))
    t1 = monotonic_ms()
    print("explicit SIMD (32B lanes):  ", _ms(t1 - t0),
          _rate(nbytes * reps, t1 - t0))
    print("")

    # --- 2. whole-file case-insensitive search ------------------------
    print("--- 2. find every case-insensitive hit in the corpus (x10) ---")
    reps = 10

    # 2a. today: split_lines + libonig (?i) per line
    var rx = OnigRegex(String("(?i)") + needle)
    t0 = monotonic_ms()
    var hits = 0
    for _ in range(reps):
        var ls = split_lines(blob)
        for i in range(len(ls)):
            var m = rx.search(ls[i])
            if m and m.value().start >= 0:
                hits += 1
    t1 = monotonic_ms()
    print("today: split + libonig (?i):", _ms(t1 - t0),
          _rate(nbytes * reps, t1 - t0), " hits:", hits // reps)

    # 2b. same, but lines pre-split (isolate the regex cost)
    t0 = monotonic_ms()
    hits = 0
    for _ in range(reps):
        for i in range(len(lines)):
            var m = rx.search(lines[i])
            if m and m.value().start >= 0:
                hits += 1
    t1 = monotonic_ms()
    print("  libonig (?i) alone:       ", _ms(t1 - t0),
          _rate(nbytes * reps, t1 - t0), " hits:", hits // reps)

    # 2c. per-line branchy ci scan, no allocation
    t0 = monotonic_ms()
    hits = 0
    for _ in range(reps):
        for i in range(len(lines)):
            if find_ci_branchy(lines[i].as_bytes(), needle.as_bytes(), 0) >= 0:
                hits += 1
    t1 = monotonic_ms()
    print("  per-line branchy ci scan: ", _ms(t1 - t0),
          _rate(nbytes * reps, t1 - t0), " hits:", hits // reps)

    # 2d. fold the blob once (SIMD), then SIMD byte search over the blob,
    #     deriving line numbers from hit offsets.
    t0 = monotonic_ms()
    hits = 0
    for _ in range(reps):
        sink += Int(fold_simd_into(blob.as_bytes(), scratch))
        var pos = 0
        while True:
            var at = find_simd(scratch, nb, pos)
            if at < 0:
                break
            hits += 1
            sink += count_newlines(scratch, at)
            pos = at + len(nb)
    t1 = monotonic_ms()
    print("  fold once + SIMD search:  ", _ms(t1 - t0),
          _rate(nbytes * reps, t1 - t0), " hits:", hits // reps)

    # 2e. same but scalar byte search (no SIMD in the search)
    t0 = monotonic_ms()
    hits = 0
    for _ in range(reps):
        sink += Int(fold_simd_into(blob.as_bytes(), scratch))
        var pos = 0
        while True:
            var at = find_bytes(scratch, nb, pos)
            if at < 0:
                break
            hits += 1
            pos = at + len(nb)
    t1 = monotonic_ms()
    print("  fold once + scalar search:", _ms(t1 - t0),
          _rate(nbytes * reps, t1 - t0), " hits:", hits // reps)
    print("")

    # --- 3. picker filtering ------------------------------------------
    print("--- 3. picker: ci substring over a candidate list (x10) ---")
    var cands = List[String]()
    for i in range(len(lines)):
        if len(cands) >= 20000:
            break
        var s = lines[i]
        if len(s.as_bytes()) >= 8 and len(s.as_bytes()) <= 90:
            cands.append(s)
    var cand_bytes = 0
    for i in range(len(cands)):
        cand_bytes += len(cands[i].as_bytes())
    print("candidates:", len(cands), " total bytes:", cand_bytes)
    var q = String("Selection")
    var q_lc = String("selection")
    var keystrokes = 10

    t0 = monotonic_ms()
    hits = 0
    for _ in range(keystrokes):
        for i in range(len(cands)):
            if find_ci_branchy(cands[i].as_bytes(), q.as_bytes(), 0) >= 0:
                hits += 1
    t1 = monotonic_ms()
    print("branchy ci per keystroke:   ", _ms(t1 - t0),
          _rate(cand_bytes * keystrokes, t1 - t0), " hits:",
          hits // keystrokes)

    var folded_cands = List[String]()
    t0 = monotonic_ms()
    for i in range(len(cands)):
        var buf = List[UInt8](capacity=len(cands[i].as_bytes()))
        sink += Int(fold_simd_into(cands[i].as_bytes(), buf))
        folded_cands.append(String(StringSlice(unsafe_from_utf8=buf)))
    t1 = monotonic_ms()
    print("  one-time prefold cost:    ", _ms(t1 - t0))

    t0 = monotonic_ms()
    hits = 0
    for _ in range(keystrokes):
        for i in range(len(folded_cands)):
            if find_bytes(folded_cands[i].as_bytes(), q_lc.as_bytes(), 0) >= 0:
                hits += 1
    t1 = monotonic_ms()
    print("  prefolded + byte search:  ", _ms(t1 - t0),
          _rate(cand_bytes * keystrokes, t1 - t0), " hits:",
          hits // keystrokes)

    # Prefolded, but with the SIMD first+last-byte prefilter per
    # candidate (candidates are short, so lanes are underfilled).
    t0 = monotonic_ms()
    hits = 0
    for _ in range(keystrokes):
        for i in range(len(folded_cands)):
            if find_simd(folded_cands[i].as_bytes(), q_lc.as_bytes(), 0) >= 0:
                hits += 1
    t1 = monotonic_ms()
    print("  prefolded + SIMD per cand:", _ms(t1 - t0),
          _rate(cand_bytes * keystrokes, t1 - t0), " hits:",
          hits // keystrokes)

    # One flat folded blob for the whole candidate list, NUL-separated,
    # swept in a single SIMD pass; hit offset -> candidate index via a
    # prefix-offset table (binary search, off the hot path).
    var flat = List[UInt8](capacity=cand_bytes + len(cands))
    var starts = List[Int](capacity=len(cands) + 1)
    t0 = monotonic_ms()
    for i in range(len(cands)):
        starts.append(len(flat))
        var buf = List[UInt8](capacity=len(cands[i].as_bytes()))
        sink += Int(fold_simd_into(cands[i].as_bytes(), buf))
        for j in range(len(buf)):
            flat.append(buf[j])
        flat.append(0)
    starts.append(len(flat))
    t1 = monotonic_ms()
    print("  one-time flat-blob build: ", _ms(t1 - t0))

    t0 = monotonic_ms()
    hits = 0
    for _ in range(keystrokes):
        var pos = 0
        while True:
            var at = find_simd(flat, q_lc.as_bytes(), pos)
            if at < 0:
                break
            hits += 1
            # Which candidate did we land in? binary search `starts`.
            var lo = 0
            var hi = len(starts) - 1
            while lo + 1 < hi:
                var mid = (lo + hi) // 2
                if starts[mid] <= at:
                    lo = mid
                else:
                    hi = mid
            sink += lo
            pos = starts[lo + 1]   # skip the rest of this candidate
    t1 = monotonic_ms()
    print("  flat blob + one SIMD pass:", _ms(t1 - t0),
          _rate(cand_bytes * keystrokes, t1 - t0), " hits:",
          hits // keystrokes)

    # --- 4. the real quick_open_match on a project-sized path list ----
    print("")
    print("--- 4. quick_open filtering, 20k candidates (x10) ---")
    var qq = String("des/sel")
    t0 = monotonic_ms()
    hits = 0
    for _ in range(keystrokes):
        for i in range(len(cands)):
            if quick_open_match(cands[i], qq):
                hits += 1
    t1 = monotonic_ms()
    print("per-candidate query split:  ", _ms(t1 - t0),
          " per keystroke:", (t1 - t0) // keystrokes, "ms  hits:",
          hits // keystrokes)

    # Same work with the query split hoisted out of the per-candidate
    # loop (it currently re-splits + re-allocates for every candidate).
    var parts = split_query_to_parts_pub(qq)
    t0 = monotonic_ms()
    hits = 0
    for _ in range(keystrokes):
        for i in range(len(cands)):
            var pos = 0
            var ok = True
            for pi in range(len(parts)):
                var found = find_ci_branchy(
                    cands[i].as_bytes(), parts[pi].as_bytes(), pos,
                )
                if found < 0:
                    ok = False
                    break
                pos = found + len(parts[pi].as_bytes())
            if ok:
                hits += 1
    t1 = monotonic_ms()
    print("  hoisted (what ships now): ", _ms(t1 - t0),
          " per keystroke:", (t1 - t0) // keystrokes, "ms  hits:",
          hits // keystrokes)

    # ... and hoisted + prefolded candidates + SIMD prefilter.
    var folded_parts = List[String]()
    for pi in range(len(parts)):
        var pbuf = List[UInt8](capacity=len(parts[pi].as_bytes()))
        sink += Int(fold_simd_into(parts[pi].as_bytes(), pbuf))
        folded_parts.append(String(StringSlice(unsafe_from_utf8=pbuf)))
    t0 = monotonic_ms()
    hits = 0
    for _ in range(keystrokes):
        for i in range(len(folded_cands)):
            var pos = 0
            var ok = True
            for pi in range(len(folded_parts)):
                var found = find_simd(
                    folded_cands[i].as_bytes(),
                    folded_parts[pi].as_bytes(),
                    pos,
                )
                if found < 0:
                    ok = False
                    break
                pos = found + len(folded_parts[pi].as_bytes())
            if ok:
                hits += 1
    t1 = monotonic_ms()
    print("  + prefold + SIMD:         ", _ms(t1 - t0),
          " per keystroke:", (t1 - t0) // keystrokes, "ms  hits:",
          hits // keystrokes)

    # --- 5. regex compile cost, paid per find_next/find_prev keypress -
    print("")
    print("--- 5. OnigRegex compile (build_search_regex per keypress) ---")
    t0 = monotonic_ms()
    for i in range(1000):
        var r = OnigRegex(String("(?i)Selection") + String(i))
        sink += Int(Bool(r.search(String("x"))))
    t1 = monotonic_ms()
    print("1000 compiles:              ", _ms(t1 - t0),
          " per compile (us):", ((t1 - t0) * 1000) // 1000)

    # --- 6. shipped path: LineSearcher vs the libonig walk it replaced -
    print("")
    print("--- 6. shipped: LineSearcher vs old per-line (?i) (x10) ---")
    reps = 10
    var opts = SearchOptions(False, False, False)
    var ls = LineSearcher(needle, opts)
    t0 = monotonic_ms()
    hits = 0
    for _ in range(reps):
        for i in range(len(lines)):
            if ls.search(lines[i], 0):
                hits += 1
    t1 = monotonic_ms()
    print("LineSearcher (new):         ", _ms(t1 - t0),
          _rate(nbytes * reps, t1 - t0), " hits:", hits // reps)

    var rx2 = OnigRegex(String("(?i)") + needle)
    t0 = monotonic_ms()
    hits = 0
    for _ in range(reps):
        for i in range(len(lines)):
            var m = rx2.search(lines[i])
            if m and m.value().start >= 0:
                hits += 1
    t1 = monotonic_ms()
    print("raw libonig (?i) (old):     ", _ms(t1 - t0),
          _rate(nbytes * reps, t1 - t0), " hits:", hits // reps)

    # Case-sensitive literal: old path was a scalar nested-loop byte scan.
    var ls_cs = LineSearcher(needle, SearchOptions(True, False, False))
    t0 = monotonic_ms()
    hits = 0
    for _ in range(reps):
        for i in range(len(lines)):
            if ls_cs.search(lines[i], 0):
                hits += 1
    t1 = monotonic_ms()
    print("LineSearcher Cc-on (new):   ", _ms(t1 - t0),
          _rate(nbytes * reps, t1 - t0), " hits:", hits // reps)

    t0 = monotonic_ms()
    hits = 0
    for _ in range(reps):
        for i in range(len(lines)):
            if find_bytes(lines[i].as_bytes(), needle.as_bytes(), 0) >= 0:
                hits += 1
    t1 = monotonic_ms()
    print("scalar byte scan (old):     ", _ms(t1 - t0),
          _rate(nbytes * reps, t1 - t0), " hits:", hits // reps)

    print("")
    print("(sink", sink, ")")
