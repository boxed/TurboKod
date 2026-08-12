"""Branchless / SIMD ASCII case folding and case-insensitive byte search.

This is the single source of truth for "compare these bytes ignoring
ASCII case" — the operation the pickers (``quick_open``, ``find_symbol``,
``type_ahead``, ``dir_browser``, ``dropdown``), the editor's Find, and
project-wide find/replace all need. Before this module the same
``if 0x41 <= c and c <= 0x5A: c += 0x20`` was hand-inlined in half a
dozen places, each one branching per byte and each one *inside* the
innermost compare loop.

Two ideas from GitHub's Blackbird write-up ("Don't stop early:
case-folding source code at memory speed") carry the whole module:

1. **Branchless.** ``(c - 0x41) <u 26`` is an unsigned range test with no
   conditional, and ``c | (is_upper << 5)`` applies the fold with no
   conditional store. That alone is ~3x the branchy version, and it's
   what makes the loop vectorizable — which is where the real win is
   (~47x, measured below).
2. **Don't stop early.** The tempting "bail at the first non-ASCII byte
   and hand off to a Unicode path" turns a straight-line sweep into a
   data-dependent loop exit, which nothing vectorizes. Instead ``OR``
   every byte into an accumulator and test it *once*, after the loop.
   In this repo that isn't just a speed argument: em dashes in comments
   mean a typical source file's first non-ASCII byte shows up within the
   first couple of hundred bytes, so an early-exit fold would give up on
   essentially every real file.

Measured on this machine over a 1.7 MB corpus of ten real
``src/turbokod/*.mojo`` files (``bench/fold_bench.mojo``):

    branchy per-byte fold (what this replaces)     1173 MiB/s
    scalar branchless (accumulator + bit-5 OR)     3253 MiB/s
    explicit 32-byte SIMD, same formula           54766 MiB/s

and for case-insensitive literal search, where the shipped callers work
line by line and the flat-blob figure is the ceiling they leave on the
table:

    per-line libonig ``(?i)`` (what this replaces)    282 MiB/s
    per-line SIMD folding scan (what ships)          1169 MiB/s
    same scan over one flat blob                    16429 MiB/s

Worth stressing: folding alone buys almost nothing — a *scalar* byte
search over a pre-folded buffer clocks 714 MiB/s, slower than the branchy
fused version. The fold's value is that it turns case-insensitive
matching into plain byte matching, which then vectorizes. That's why the
search functions here fold the haystack **in register** (two extra SIMD
ops per 32 bytes) rather than materializing a folded copy: no allocation,
no second buffer, same speed.

Why ASCII-only folding is safe on UTF-8
---------------------------------------
The fold only ever rewrites bytes ``0x41..0x5A``. Those bytes never occur
inside a multi-byte UTF-8 sequence (lead bytes are >= 0xC2, continuation
bytes are 0x80..0xBF), so folding a UTF-8 buffer:

* cannot corrupt it,
* is byte-length-preserving, so match offsets map 1:1 onto the original
  buffer — no re-decoding, no offset translation, and the editor's
  selection columns stay correct, and
* cannot produce a spurious match: since a folded needle byte is ASCII,
  any byte it matches is ASCII too, so a hit can never start or end
  mid-codepoint.

What it deliberately does *not* do is fold non-ASCII case pairs
(``Ä``/``ä``, and the exotic ASCII-adjacent ones like ``ſ``->``s`` or
``K`` U+212A -> ``k``). Callers that need exact parity with libonig's
``(?i)`` use :func:`scan_folded`, which reports both the match and
whether the region was pure ASCII, and fall back to the regex when it
wasn't — see ``LineSearcher`` in
``search_options.mojo``. Callers that were already ASCII-only by policy
(every picker) just use these helpers directly.
"""

from std.collections.list import List


comptime FOLD_W: Int = 32
"""Bytes per SIMD iteration. 32 is one NEON pair / one AVX2 register and
measured no worse than 16 or 64 on Apple Silicon."""


# --- scalar primitives -----------------------------------------------------


@always_inline
def fold_byte(c: UInt8) -> UInt8:
    """ASCII-fold one byte, branchlessly. Bytes outside ``A``-``Z`` are
    returned unchanged, including every byte >= 0x80 (see the module
    docstring on why that keeps UTF-8 intact).

    ``c - 0x41`` wraps for bytes below ``A``, landing them well above 26,
    so the single unsigned compare covers both ends of the range."""
    var is_upper = UInt8((c - UInt8(0x41)) < UInt8(26))
    return c | (is_upper << 5)


@always_inline
def _fold_vec(v: SIMD[DType.uint8, FOLD_W]) -> SIMD[DType.uint8, FOLD_W]:
    """:func:`fold_byte` over a whole register. ``lt`` rather than ``<``
    because Mojo's comparison operators are ``Scalar``-only."""
    var is_upper = (v - SIMD[DType.uint8, FOLD_W](0x41)).lt(
        SIMD[DType.uint8, FOLD_W](26)
    )
    return v | (is_upper.cast[DType.uint8]() << 5)


def is_ascii(b: Span[UInt8, _]) -> Bool:
    """True when every byte of ``b`` is < 0x80.

    The "don't stop early" shape: OR everything into an accumulator and
    test the high bit once at the end, so the loop has no data-dependent
    exit and vectorizes. A ``return False`` on the first high byte would
    look like a win and cost ~40x on the (common) all-ASCII input this is
    a gate for."""
    var n = len(b)
    var p = b.unsafe_ptr()
    var acc_v = SIMD[DType.uint8, FOLD_W](0)
    var i = 0
    while i + FOLD_W <= n:
        acc_v |= p.unsafe_offset(i).unsafe_load[width=FOLD_W]()
        i += FOLD_W
    var acc = acc_v.reduce_or()
    while i < n:
        acc |= p[unsafe_offset=i]
        i += 1
    return (acc & 0x80) == 0


def fold_ascii_into(b: Span[UInt8, _], mut out: List[UInt8]) -> Bool:
    """ASCII-fold ``b`` into ``out`` (resized to ``len(b)``), returning
    whether the input was pure ASCII. Same length in, same length out.

    Used where a folded copy genuinely is the product (sort keys, config
    tokens). The search functions below don't need it — they fold in
    register."""
    var n = len(b)
    out.resize(n, 0)
    var src = b.unsafe_ptr()
    var dst = out.unsafe_ptr()
    var acc_v = SIMD[DType.uint8, FOLD_W](0)
    var i = 0
    while i + FOLD_W <= n:
        var v = src.unsafe_offset(i).unsafe_load[width=FOLD_W]()
        acc_v |= v
        dst.unsafe_offset(i).unsafe_store(_fold_vec(v))
        i += FOLD_W
    var acc = acc_v.reduce_or()
    while i < n:
        var c = src[unsafe_offset=i]
        acc |= c
        dst[unsafe_offset=i] = fold_byte(c)
        i += 1
    return (acc & 0x80) == 0


def fold_ascii(s: String) -> String:
    """``s`` with every ASCII ``A``-``Z`` lowered; everything else — the
    whole non-ASCII range included — passed through byte for byte."""
    var buf = List[UInt8](capacity=len(s.as_bytes()) + 1)
    _ = fold_ascii_into(s.as_bytes(), buf)
    return String(StringSpan(unsafe_from_utf8=buf))


# --- search ----------------------------------------------------------------
#
# One implementation, specialized at compile time on whether to fold.
# ``fold=False`` is a plain literal byte search, which the case-sensitive
# search path wants and gets the same SIMD prefilter for free.


@always_inline
def _needle_at[fold: Bool](
    p: Pointer[UInt8, _], at: Int, nb: Span[UInt8, _], from_: Int,
) -> Bool:
    """Verify ``nb[from_:]`` against the haystack at ``at + from_``.
    ``nb`` is already folded when ``fold`` is set, so only the haystack
    side needs folding."""
    for j in range(from_, len(nb)):
        var c = p[unsafe_offset=at + j]

        comptime if fold:
            c = fold_byte(c)
        if c != nb[j]:
            return False
    return True


def _find[fold: Bool](
    hb: Span[UInt8, _], nb: Span[UInt8, _], start: Int,
) -> Int:
    """Earliest offset >= ``start`` where ``nb`` occurs in ``hb``, or -1.

    ``nb`` must already be folded when ``fold`` is set (fold it once with
    :func:`fold_ascii`, not once per candidate).

    A first-byte-plus-last-byte SIMD prefilter rejects 32 positions per
    iteration; only lanes that agree on both ends pay for a full compare.
    Two-ended rather than first-byte-only because source code is full of
    runs sharing a first letter."""
    var n = len(nb)
    var h = len(hb)
    if n == 0:
        return start if start <= h else -1
    if start < 0:
        return -1
    if n > h - start:
        return -1
    var p = hb.unsafe_ptr()
    var last_i = h - n
    var first = SIMD[DType.uint8, FOLD_W](nb[0])
    var last = SIMD[DType.uint8, FOLD_W](nb[n - 1])
    var i = start
    while i + FOLD_W <= last_i + 1:
        var v0 = p.unsafe_offset(i).unsafe_load[width=FOLD_W]()
        var v1 = p.unsafe_offset(i + n - 1).unsafe_load[width=FOLD_W]()

        comptime if fold:
            v0 = _fold_vec(v0)
            v1 = _fold_vec(v1)
        var m = v0.eq(first) & v1.eq(last)
        if m.reduce_or():
            for k in range(FOLD_W):
                if m[k] and _needle_at[fold](p, i + k, nb, 1):
                    return i + k
        i += FOLD_W
    while i <= last_i:
        var c = p[unsafe_offset=i]

        comptime if fold:
            c = fold_byte(c)
        if c == nb[0] and _needle_at[fold](p, i, nb, 1):
            return i
        i += 1
    return -1


def find_folded(hb: Span[UInt8, _], nb: Span[UInt8, _], start: Int) -> Int:
    """Case-insensitive search for a **pre-folded** needle. Returns the
    byte offset of the first hit at or after ``start``, or -1.

    Stops at the first hit. Callers that need to know whether the region
    was pure ASCII — i.e. whether this result is equivalent to what a
    Unicode-aware engine would say — want :func:`scan_folded` instead."""
    return _find[True](hb, nb, start)


@fieldwise_init
struct FoldScan(ImplicitlyCopyable, Movable):
    """Result of :func:`scan_folded`: where the match is, and whether the
    answer can be trusted as Unicode-correct."""
    var at: Int
    """First match offset at or after ``start``, or -1."""
    var ascii_only: Bool
    """Every byte in ``[start, len(haystack))`` was < 0x80. When False the
    caller must redo the search with a Unicode-aware engine — ``at`` may
    be a hit that a real case fold would have found *earlier*."""


def scan_folded(hb: Span[UInt8, _], nb: Span[UInt8, _], start: Int) -> FoldScan:
    """Search for a pre-folded needle *and* report whether the region was
    pure ASCII, in one pass.

    This is the module's thesis in one function. The obvious way to write
    it is two passes — ``is_ascii(line)`` to decide whether the fast path
    is valid, then the search — and that's what this replaced. One pass
    always touches fewer bytes than two; on ~46-byte source lines, where
    per-call overhead rather than bandwidth is the limit, it measured
    ~15%.

    The subtle part is that the scan **does not stop at the first
    match**. It keeps accumulating high bits to the end of the haystack,
    because a hit is only trustworthy if the *whole* region is ASCII:
    with non-ASCII in play, a Unicode fold could match something starting
    *before* our hit (``İ`` folding to ``i``, say) and the right answer
    would be that earlier position. Stopping at the hit would leave the
    tail unexamined and the accumulator lying. Only the matching work is
    skipped after a hit — the OR keeps running, which costs one
    instruction per lane.

    ``ascii_only`` covers ``[start, len(hb))`` rather than the whole
    haystack: bytes before ``start`` can't affect a literal match."""
    var n = len(nb)
    var h = len(hb)
    if start < 0 or start > h:
        return FoldScan(-1, True)
    var p = hb.unsafe_ptr()
    if n == 0 or n > h - start:
        return FoldScan(
            start if n == 0 else -1, is_ascii(hb[start:h]),
        )
    var first = SIMD[DType.uint8, FOLD_W](nb[0])
    var last = SIMD[DType.uint8, FOLD_W](nb[n - 1])
    var last_i = h - n
    var acc_v = SIMD[DType.uint8, FOLD_W](0)
    var found = -1
    var i = start
    while i + FOLD_W <= last_i + 1:
        var v0 = p.unsafe_offset(i).unsafe_load[width=FOLD_W]()
        acc_v |= v0
        if found < 0:
            var v1 = _fold_vec(p.unsafe_offset(i + n - 1).unsafe_load[width=FOLD_W]())
            var m = _fold_vec(v0).eq(first) & v1.eq(last)
            if m.reduce_or():
                for k in range(FOLD_W):
                    if m[k] and _needle_at[True](p, i + k, nb, 1):
                        found = i + k
                        break
        i += FOLD_W
    var acc = acc_v.reduce_or()
    # Tail positions that can still start a match.
    while i <= last_i:
        var c = p[unsafe_offset=i]
        acc |= c
        if found < 0 and fold_byte(c) == nb[0] \
                and _needle_at[True](p, i, nb, 1):
            found = i
        i += 1
    # The final ``n - 1`` bytes can't start a match but still decide
    # whether the whole region was ASCII.
    while i < h:
        acc |= p[unsafe_offset=i]
        i += 1
    return FoldScan(found, (acc & 0x80) == 0)


def find_exact(hb: Span[UInt8, _], nb: Span[UInt8, _], start: Int) -> Int:
    """Case-*sensitive* literal byte search — same SIMD prefilter."""
    return _find[False](hb, nb, start)


# Reverse search (Find Previous) has no dedicated primitive here: libonig
# has no reverse search either, so ``LineSearcher.rsearch`` walks forward
# keeping the right-most hit and both paths share that one loop.


# --- String-level conveniences ---------------------------------------------
#
# These are what the pickers call. Each folds the needle once and hands
# the haystack to the SIMD search unfolded.


def find_ci(haystack: String, needle: String, start: Int) -> Int:
    """Earliest byte offset >= ``start`` where ``needle`` occurs in
    ``haystack``, ASCII case-insensitively; -1 if absent.

    Folds ``needle`` on every call. When the same needle is tested
    against many candidates (a picker filtering thousands of rows), fold
    it once with :func:`fold_ascii` and call :func:`find_folded`
    directly."""
    var folded = List[UInt8](capacity=len(needle.as_bytes()) + 1)
    _ = fold_ascii_into(needle.as_bytes(), folded)
    return find_folded(haystack.as_bytes(), folded, start)


def contains_ci(haystack: String, needle: String) -> Bool:
    """``needle`` occurs somewhere in ``haystack``, ignoring ASCII case.
    An empty needle is contained in everything."""
    return find_ci(haystack, needle, 0) >= 0


def eq_ci(a: String, b: String) -> Bool:
    """ASCII case-insensitive string equality."""
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    var n = len(ab)
    if n != len(bb):
        return False
    var pa = ab.unsafe_ptr()
    var pb = bb.unsafe_ptr()
    var diff = SIMD[DType.uint8, FOLD_W](0)
    var i = 0
    while i + FOLD_W <= n:
        diff |= _fold_vec(pa.unsafe_offset(i).unsafe_load[width=FOLD_W]()) ^ _fold_vec(
            pb.unsafe_offset(i).unsafe_load[width=FOLD_W]()
        )
        i += FOLD_W
    var acc = diff.reduce_or()
    while i < n:
        acc |= fold_byte(pa[unsafe_offset=i]) ^ fold_byte(pb[unsafe_offset=i])
        i += 1
    return acc == 0


def starts_with_ci(name: String, prefix: String) -> Bool:
    """``name`` begins with ``prefix``, ignoring ASCII case."""
    var nb = name.as_bytes()
    var pb = prefix.as_bytes()
    var n = len(pb)
    if n > len(nb):
        return False
    var pa = nb.unsafe_ptr()
    var pp = pb.unsafe_ptr()
    var diff = SIMD[DType.uint8, FOLD_W](0)
    var i = 0
    while i + FOLD_W <= n:
        diff |= _fold_vec(pa.unsafe_offset(i).unsafe_load[width=FOLD_W]()) ^ _fold_vec(
            pp.unsafe_offset(i).unsafe_load[width=FOLD_W]()
        )
        i += FOLD_W
    var acc = diff.reduce_or()
    while i < n:
        acc |= fold_byte(pa[unsafe_offset=i]) ^ fold_byte(pp[unsafe_offset=i])
        i += 1
    return acc == 0
