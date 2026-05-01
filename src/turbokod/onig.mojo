"""Oniguruma FFI: a thin Mojo wrapper over libonig.

The TextMate-grammar highlighter we're building toward uses
Oniguruma-syntax regex (look-behind, atomic groups, named captures,
``\\G``, etc.) — the same engine VS Code's ``vscode-textmate`` runs.
This module is the bottom of that stack: it owns the FFI to
``libonig`` and exposes a Mojo-side ``OnigRegex`` value type.

Linker-side, ``run.sh`` passes ``-Xlinker -lonig`` and the matching
``-L`` (the pixi env's ``lib/`` directory). At runtime, the same
script exports ``DYLD/LD_LIBRARY_PATH`` so the dylib resolves. The
two libonig globals we need (``OnigEncodingUTF8`` and
``OnigSyntaxRuby``) are fetched via ``dlsym(RTLD_DEFAULT, ...)``
because ``external_call`` only addresses *functions* — it can't take
the address of an external variable directly.

Lifecycle:
* ``OnigRegex(pattern)`` calls ``onig_init`` lazily (idempotent in
  libonig) and compiles the pattern; raises on bad pattern.
* ``regex.search(haystack)`` returns ``Optional[OnigMatch]``.
* The destructor frees the underlying ``regex_t`` plus the
  wrapper's region scratch.

What this *doesn't* do (deliberately, for now):
* Expose match captures past group 0. The TextMate runtime will
  need them; we'll add a ``match.group(i)`` API when we get there.
* Support encodings other than UTF-8.
* Cache the dlsym lookups in a module-level var — Mojo doesn't yet
  permit module-level mutable globals. The lookups are cheap (one
  hash probe each) and only fire once per ``OnigRegex`` construction.
"""

from std.collections.list import List
from std.collections.optional import Optional
from std.ffi import external_call
from std.sys.info import CompilationTarget


# Option flags for ``onig_search``. Values mirror the chain of
# left-shifts in ``oniguruma.h`` — laid out here so callers don't
# have to compute them from a header that mixes compile-time and
# search-time flags. Only the search-time ones we actually use are
# defined; the rest can be added as needed.
comptime ONIG_OPTION_NONE: Int = 0
# ``\\G`` won't match at the ``start`` position passed to
# ``onig_search``. The TextMate runtime sets this on every search
# whose ``pos`` doesn't equal its tracked ``\\G`` anchor — it's the
# mechanism that makes ``(?!\\G)`` embed-gating fire on a fresh
# line (where there's no previous match to anchor on).
comptime ONIG_OPTION_NOT_BEGIN_POSITION: Int = 1 << 24


fn _rtld_default() -> Int:
    """``RTLD_DEFAULT`` is one of those values the C preprocessor hides
    behind a cast. macOS defines it as ``((void*)-2)``; Linux as
    ``((void*)0)``. We pass it as a plain ``Int`` to ``dlsym``; the
    kernel doesn't care about the type, just the bit pattern."""
    comptime if CompilationTarget.is_macos():
        return -2
    else:
        return 0


fn _resolve_enc() raises -> Int:
    """Resolve ``OnigEncodingUTF8`` via ``dlsym``. Also runs
    ``onig_init`` (documented as idempotent in libonig) so callers
    don't have to remember a separate init step.

    Two single-return functions instead of one ``Tuple``-returning
    one because the per-call cost is two cheap dlsym hash probes,
    so the abstraction isn't worth carrying.
    """
    var rc = external_call["onig_init", Int32]()
    if rc != 0:
        raise Error("onig_init failed: " + String(rc))
    var name_enc = String("OnigEncodingUTF8\0")
    var enc = external_call["dlsym", Int](
        _rtld_default(), name_enc.unsafe_ptr(),
    )
    if enc == 0:
        raise Error("dlsym failed for OnigEncodingUTF8")
    return enc


fn _resolve_syntax() raises -> Int:
    var name_syn = String("OnigSyntaxRuby\0")
    var syn = external_call["dlsym", Int](
        _rtld_default(), name_syn.unsafe_ptr(),
    )
    if syn == 0:
        raise Error("dlsym failed for OnigSyntaxRuby")
    return syn


fn onig_global_init() raises:
    """Eagerly resolve libonig globals. Optional — ``OnigRegex.__init__``
    calls this lazily — but exposed for callers that want the dlsym
    error to surface at startup rather than the first regex compile."""
    _ = _resolve_enc()
    _ = _resolve_syntax()


fn onig_global_end():
    """Optional: release libonig's internal tables. Not required for
    correctness — present for completeness."""
    _ = external_call["onig_end", Int]()


struct OnigMatch(ImplicitlyCopyable, Movable):
    """Half-open ``[start, end)`` byte offsets of a regex match
    plus per-group bounds.

    ``start`` / ``end`` are group 0 (the whole match) — the common
    case, called out for ergonomics. ``group_starts`` /
    ``group_ends`` are parallel lists for *every* group including
    group 0 at index 0; an unmatched optional group reports
    ``ONIG_REGION_NOTPOS = -1``.

    Indices are byte offsets into the haystack the search ran on.
    UTF-8 boundaries are guaranteed by libonig.
    """
    var start: Int
    var end: Int
    var group_starts: List[Int]
    var group_ends: List[Int]

    fn __init__(
        out self, start: Int, end: Int,
        var group_starts: List[Int],
        var group_ends: List[Int],
    ):
        self.start = start
        self.end = end
        self.group_starts = group_starts^
        self.group_ends = group_ends^

    fn __copyinit__(out self, copy: Self):
        self.start = copy.start
        self.end = copy.end
        self.group_starts = copy.group_starts.copy()
        self.group_ends = copy.group_ends.copy()

    fn group_count(self) -> Int:
        return len(self.group_starts)

    fn group(self, i: Int) -> OnigMatch:
        """Bounds of group ``i`` (0 = whole match) packaged as a
        plain ``OnigMatch``. Returns a zero-length match at offset
        ``-1`` when the group didn't participate. Convenient for
        callers that just want a span and don't care about nested
        groups."""
        if i < 0 or i >= len(self.group_starts):
            return OnigMatch(-1, -1, List[Int](), List[Int]())
        var gs = self.group_starts[i]
        var ge = self.group_ends[i]
        return OnigMatch(gs, ge, List[Int](), List[Int]())


struct OnigRegex(ImplicitlyCopyable, Movable):
    """A compiled Oniguruma regex.

    Construction copies the pattern bytes into the engine's internal
    representation; the original ``pattern`` ``String`` is no longer
    needed after ``__init__`` returns.

    Copy semantics are *bitwise / aliasing*: a copied ``OnigRegex``
    shares the same underlying ``regex_t*`` and ``OnigRegion*`` as
    its source. We don't run ``onig_free`` from a per-instance
    ``__del__`` — that path was tried two ways (plain ``__del__``
    and refcounted ``ArcPointer``) and both interacted badly with
    Mojo's destructor sequencing in this version (the refcount
    variant hung the next ``onig_search``).

    Cleanup happens via a process-wide registry (``onig_shim.c``):
    every ``__init__`` calls ``tk_onig_track`` to record the
    handle pair, and a ``__attribute__((destructor))`` runs at
    program exit to free them all in one batch. So we don't leak
    *between* sessions — leak detectors stay quiet — and the
    in-session footprint is bounded by ``HighlightCache``'s grammar
    reuse (one regex per pattern per loaded grammar).

    The aliasing means concurrent ``search`` calls across copies
    *do* race on the shared region scratch, so don't share an
    instance across threads — build one regex per thread if you
    need that.
    """
    var _reg: Int       # OnigRegex (regex_t*) value
    var _region: Int    # OnigRegion* scratch, allocated once

    fn __copyinit__(out self, copy: Self):
        self._reg = copy._reg
        self._region = copy._region

    fn __init__(out self, pattern: String) raises:
        var enc = _resolve_enc()
        var syn = _resolve_syntax()
        var pb = pattern.as_bytes()
        var pp = pattern.unsafe_ptr()
        var pe = pp + len(pb)
        # ``onig_new`` writes the freshly compiled regex_t* into the
        # 8-byte slot. We allocate 16 to be safe against a future
        # libonig that grows the out-arg.
        var slot = List[UInt8]()
        for _ in range(16):
            slot.append(0)
        var einfo = List[UInt8]()
        for _ in range(64):
            einfo.append(0)
        # ``Int32`` for the return because libonig's ``int`` is 32-bit;
        # specifying ``Int`` (Mojo's 64-bit) skips the sign-extension
        # the C ABI usually inserts and we end up with a garbled rc on
        # error. Same fix is applied to ``onig_search`` below.
        var rc = external_call["onig_new", Int32](
            slot.unsafe_ptr(), pp, pe,
            Int(0),                         # ONIG_OPTION_NONE
            enc, syn,
            einfo.unsafe_ptr(),
        )
        if rc != 0:
            raise Error("onig_new failed: " + String(rc))
        self._reg = slot.unsafe_ptr().bitcast[Int]()[0]
        self._region = external_call["onig_region_new", Int]()
        if self._region == 0:
            raise Error("onig_region_new failed (out of memory)")
        # Register the (regex_t*, OnigRegion*) pair with the C-side
        # process registry (``onig_shim.c``). At program exit a
        # ``__attribute__((destructor))`` walks the registry and
        # frees everything in one shot — the substitute for the
        # per-instance ``__del__`` we couldn't safely run from
        # Mojo (see the struct doc-comment for the lifecycle saga).
        _ = external_call["tk_onig_track", Int](self._reg, self._region)

    fn search(self, haystack: String) -> Optional[OnigMatch]:
        """Search ``haystack`` for the first match. Returns the match
        bounds or ``None`` if there's no match."""
        return self.search_at(haystack, 0, ONIG_OPTION_NONE)

    fn search_at(
        self, haystack: String, start: Int,
    ) -> Optional[OnigMatch]:
        """Search starting from byte offset ``start`` with default
        options. Convenience wrapper around the four-arg form."""
        return self.search_at(haystack, start, ONIG_OPTION_NONE)

    fn search_at(
        self, haystack: String, start: Int, options: Int,
    ) -> Optional[OnigMatch]:
        """Search ``haystack`` starting from byte offset ``start``.

        ``options`` is the OR of any libonig search-time flags
        (see ``ONIG_OPTION_*`` in ``oniguruma.h``). The TextMate
        runtime uses ``ONIG_OPTION_NOT_BEGIN_POSITION`` to disable
        the ``\\G`` anchor when the current scan position doesn't
        match the previous match's end — that's how ``(?!\\G)``
        embed-gates work in HTML / Markdown grammars.

        ``start`` doubles as the position where ``\\G`` anchors
        (when the option flag is *not* set) — that's libonig's
        contract, and the tokenizer leans on it.
        """
        var hb = haystack.as_bytes()
        if start < 0 or start > len(hb):
            return Optional[OnigMatch]()
        var hp = haystack.unsafe_ptr()
        var he = hp + len(hb)
        var hs = hp + start
        var rc = external_call["onig_search", Int32](
            self._reg, hp, he, hs, he, self._region, options,
        )
        if Int(rc) < 0:
            return Optional[OnigMatch]()
        # ``OnigRegion`` layout (64-bit):
        #   offset 0:  int  allocated
        #   offset 4:  int  num_regs
        #   offset 8:  int* beg
        #   offset 16: int* end
        # ``beg``/``end`` are parallel 4-byte-int arrays, one entry
        # per group (group 0 = whole match). Copy them out eagerly:
        # the next call to ``onig_search`` reuses this region, so a
        # match value that outlives this call can't trust the buffer.
        var num_regs = _read_int32(self._region + 4)
        var beg_arr = _read_ptr(self._region + 8)
        var end_arr = _read_ptr(self._region + 16)
        var starts = List[Int]()
        var ends = List[Int]()
        for i in range(num_regs):
            starts.append(_read_int32(beg_arr + i * 4))
            ends.append(_read_int32(end_arr + i * 4))
        var beg0 = -1
        var end0 = -1
        if num_regs > 0:
            beg0 = starts[0]
            end0 = ends[0]
        return Optional[OnigMatch](
            OnigMatch(beg0, end0, starts^, ends^),
        )


fn _read_ptr(addr: Int) -> Int:
    """Read an 8-byte pointer-sized value at the given address."""
    var buf = List[UInt8]()
    for _ in range(8):
        buf.append(0)
    _ = external_call["memcpy", Int](buf.unsafe_ptr(), addr, Int(8))
    return buf.unsafe_ptr().bitcast[Int]()[0]


fn _read_int32(addr: Int) -> Int:
    """Read a 4-byte signed int at the given address, sign-extended."""
    var buf = List[UInt8]()
    for _ in range(4):
        buf.append(0)
    _ = external_call["memcpy", Int](buf.unsafe_ptr(), addr, Int(4))
    return Int(buf.unsafe_ptr().bitcast[Int32]()[0])
