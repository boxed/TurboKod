"""Project-wide identifier index for the Find Symbol picker.

## Why this exists

``find_symbol`` used to spawn one ``rg`` per keystroke with the pattern
``\\b[A-Za-z0-9_]*<query>[A-Za-z0-9_]*\\b``. Three measured problems with
that (numbers from a 10,844-file / 82 MB checkout):

1. **The regex was vacuous.** With the query sanitized to identifier
   bytes, the greedy ``[A-Za-z0-9_]*`` on either side absorbs whatever
   the ``\\b`` would have anchored, so the pattern selects exactly the
   lines a plain literal substring search would. Verified as a set on
   six queries spanning 282–83,887 matching lines: identical, with one
   divergence in 1,503 matches (``r"'\\x1ó34'"``, where Rust's
   Unicode-aware ``\\b`` refuses to fire next to ``ó`` — and
   ``_extract_identifier`` walks ASCII-only bytes, so it yields ``x1``
   either way).
2. **It cost 25x the CPU of that literal.** ``rg --stats`` reported
   2.67 s of search CPU for the regex against 0.11 s for ``-F`` on the
   same corpus. A thread pool hid it in wall clock; it was still ~2.7
   CPU-seconds per keypress.
3. **``--smart-case`` was inert.** The ``A-Z`` inside the character
   class trips rg's uppercase detection, so every search ran
   case-sensitive no matter what the user typed. Case-sensitive is the
   behaviour we want, but it should be chosen, not an accident — see
   ``SYMBOL_SEARCH_CASE_SENSITIVE``.

So the win was never a faster matcher: it was not re-reading the whole
project on every keystroke. This module scans once, keeps the unique
identifiers, and answers a keystroke with a single SIMD pass over a few
MB instead of a subprocess over tens of MB.

## Layout, and why it is per-file

``blob`` is a NUL-separated run of identifier names grouped into
**per-file segments**, deduped only *within* a file. Cross-file dedupe
happens at query time, over the few hundred hits.

The obvious alternative — one globally-deduped table — is smaller
(2.1 MB vs 4.2 MB on the corpus above) but cannot be maintained. To
drop a re-indexed file's contribution you must know whether each of its
names still occurs in some *other* file, which needs a full inverted
index. Without one you either rebuild everything or leave ghost entries
for symbols that no longer exist. Per-file segments make re-indexing a
segment swap: one file changed, one segment replaced, nothing else
touched. The extra 2 MB costs ~0.5 ms a keystroke, against the
160–490 ms this replaces.

Segments are append-only. Re-indexing a file appends a fresh segment
and marks the old one dead; dead bytes are still swept by the SIMD pass
(harmless — hits landing in a dead segment are dropped) until
``compact`` reclaims them once they cross ``_COMPACT_DEAD_FRACTION``.

## Staleness

The index is a *cache*, never the authority. Five mechanisms, cheapest
first:

1. **Unsaved edits are indexed from the buffer**, via
   ``reindex_from_text``. This is strictly more correct than the ``rg``
   it replaces: rg reads disk, so a symbol you just typed and have not
   saved was invisible to the old picker.
2. **``reindex_file`` patches one segment** in microseconds, for a host
   that knows a specific file changed. The picker is modal, so nothing
   currently needs it — a save while the picker is closed is caught by
   (3) on the next open. It is kept because it is the cheap path any
   future non-modal surface will want, and because (3) is built out of
   it.
3. **A revalidation sweep on picker open** — ``begin_revalidation`` plus
   ``revalidate_step``, which re-``stat``s indexed files and re-indexes
   only those whose ``(size, mtime_sec, mtime_nsec)`` moved. 10.8k
   stats is ~16 ms, amortized over frames. Nanosecond precision matters
   here: ``mtime_sec`` alone misses a same-second same-size rewrite,
   which ``git checkout`` produces routinely.
4. **A cold or mid-sweep index falls back to ``rg``.** ``is_ready``
   gates the fast path, so a staleness bug can make the picker slow,
   never wrong.
5. **Submit-time verification** — ``verify_occurrence`` re-checks that
   the identifier really sits at the recorded ``(line, col)`` before the
   host hands that seed to ``textDocument/definition``, and re-scans the
   one file if it moved. A stale seed costs a file read, not a jump to
   the wrong place.

The residual gap, stated plainly: a file rewritten by an outside
process while the picker is already open is not noticed until the next
sweep. The old per-keystroke rg would have seen it. Mechanism 5 is what
keeps the consequence to a wasted read.
"""

from std.collections.list import List
from std.collections.optional import Optional

from .case_fold import find_exact
from .file_io import read_file, stat_file


comptime SYMBOL_MIN_LEN: Int = 2
"""Shortest identifier worth storing.

``find_symbol`` refuses to search for a query under 2 characters, and a
2-character query cannot be a substring of a 1-character name, so
length-1 identifiers are unreachable by construction. Dropping them is
free."""

comptime SYMBOL_MAX_LEN: Int = 128
"""Longest identifier worth storing. Past this we are looking at
minified output or base64 embedded in a source file, not a symbol
anyone will pick from a list."""

comptime SYMBOL_SEARCH_CASE_SENSITIVE: Bool = True
"""Find Symbol matches case-sensitively.

This preserves what the picker has always actually done — the old
``rg --smart-case`` was overridden by the ``A-Z`` in its own character
class — but states it as a decision. The switch is a real one:
``case_fold`` offers ``find_folded`` at the same throughput as
``find_exact``, so flipping this costs a pre-folded blob and nothing
else."""

comptime _MAX_FILE_BYTES: Int = 4 * 1024 * 1024
"""Files larger than this are skipped. A 4 MB source file is generated
or vendored; indexing it buys nothing and its identifiers are noise."""

comptime _BINARY_SNIFF_BYTES: Int = 1024
"""How much of a file's head we scan for a NUL before deciding it is
binary. Same heuristic ``rg`` uses, and for the same reason: a NUL in
the first block is a near-perfect binary tell and costs nothing."""

comptime _COMPACT_DEAD_FRACTION: Int = 50
"""Percent of ``blob`` that must be dead segments before ``compact``
bothers rewriting it."""


def is_symbol_byte(b: UInt8) -> Bool:
    """``[A-Za-z0-9_]`` — the identifier alphabet the picker works in.

    Deliberately ASCII-only, matching ``find_symbol._is_ident_byte``.
    The two must agree: this decides what lands in the index, that one
    decides what the host extracts from a line, and a disagreement
    shows up as a picker entry that cannot be navigated to."""
    var c = Int(b)
    return (0x61 <= c and c <= 0x7A) \
        or (0x41 <= c and c <= 0x5A) \
        or (0x30 <= c and c <= 0x39) \
        or c == 0x5F


def _starts_with_digit(b: Span[UInt8, _]) -> Bool:
    if len(b) == 0:
        return False
    return 0x30 <= Int(b[0]) and Int(b[0]) <= 0x39


def _looks_binary(b: Span[UInt8, _]) -> Bool:
    var n = _BINARY_SNIFF_BYTES
    if len(b) < n:
        n = len(b)
    for i in range(n):
        if b[i] == 0:
            return True
    return False


def _hash_bytes(b: Span[UInt8, _]) -> UInt64:
    """FNV-1a. Used for both of this module's lookup tables.

    Both tables replaced linear scans that were quietly quadratic: the
    path roster was O(files^2) on a re-listing (117M string compares on
    a 10.8k-file checkout — enough to make the picker's own index build
    the slowest thing in the program), and the within-file dedupe was
    O(unique^2 * len) in a re-scan of the growing segment, which a
    single large generated file could stretch into seconds."""
    var h = UInt64(0xCBF29CE484222325)
    for i in range(len(b)):
        h = (h ^ UInt64(b[i])) * UInt64(0x100000001B3)
    return h


def _slot_capacity_for(n: Int) -> Int:
    """Power-of-two table size holding ``n`` keys under a 0.7 load
    factor, with a floor that keeps tiny projects off the growth path."""
    var cap = 64
    while cap * 7 < n * 10:
        cap *= 2
    return cap


@fieldwise_init
struct SymbolHit(ImplicitlyCopyable, Movable):
    """One query result: the identifier plus where it was first seen."""
    var name: String
    var path: String
    var line: Int      # 1-based
    var column: Int    # 1-based byte column


@fieldwise_init
struct _Segment(ImplicitlyCopyable, Movable):
    """One file's contribution to ``blob``.

    ``live`` going False is how a re-index retires the old contents
    without disturbing any other segment's offsets."""
    var file_id: Int32
    var blob_start: Int32
    var blob_end: Int32
    var ent_start: Int32    # first entry ordinal owned by this segment
    var ent_end: Int32      # one past the last
    var live: Bool


struct SymbolIndex(Movable):
    """Per-project identifier index. Built incrementally, queried with
    one SIMD pass. See the module docstring for layout and staleness."""

    var root: String

    # --- the searchable corpus ---
    # NUL-separated identifier names. A leading NUL keeps every name
    # both preceded and followed by a separator, so a needle can never
    # straddle two names.
    var blob: List[UInt8]
    # Entry ordinal -> offset of its first byte in ``blob``. Sorted
    # ascending (segments only ever append), which is what lets
    # ``_entry_at`` binary-search a raw hit offset back to an entry.
    var ent_off: List[Int32]
    var ent_len: List[Int32]
    var ent_line: List[Int32]
    var ent_col: List[Int32]
    var ent_seg: List[Int32]

    # --- per-file bookkeeping ---
    var files: List[String]
    var file_size: List[Int64]
    var file_mtime_sec: List[Int64]
    var file_mtime_nsec: List[Int64]
    # Index into ``segments``, or -1 when the file is known but has no
    # live segment (never indexed, unreadable, binary, or too large).
    var file_seg: List[Int32]
    # Open-addressed path -> ``file id + 1`` (0 means empty), sized to a
    # power of two so the probe is a mask rather than a modulo. Exists
    # only so ``_file_id`` is not a linear scan; see ``_hash_bytes``.
    var _path_slots: List[Int32]
    var segments: List[_Segment]
    var dead_bytes: Int

    # --- build / revalidation progress ---
    # Files still to index for the initial build. Popped from the back.
    var pending: List[Int32]
    var built: Bool
    # Files still to re-stat for the current revalidation sweep.
    var recheck: List[Int32]

    def __init__(out self):
        self.root = String("")
        self.blob = List[UInt8]()
        self.blob.append(0)
        self.ent_off = List[Int32]()
        self.ent_len = List[Int32]()
        self.ent_line = List[Int32]()
        self.ent_col = List[Int32]()
        self.ent_seg = List[Int32]()
        self.files = List[String]()
        self.file_size = List[Int64]()
        self.file_mtime_sec = List[Int64]()
        self.file_mtime_nsec = List[Int64]()
        self.file_seg = List[Int32]()
        self._path_slots = List[Int32]()
        self.segments = List[_Segment]()
        self.dead_bytes = 0
        self.pending = List[Int32]()
        self.built = False
        self.recheck = List[Int32]()

    # --- lifecycle --------------------------------------------------------

    def reset(mut self, var root: String):
        """Drop everything and re-root. Called on project open/switch."""
        self.root = root^
        self.blob = List[UInt8]()
        self.blob.append(0)
        self.ent_off = List[Int32]()
        self.ent_len = List[Int32]()
        self.ent_line = List[Int32]()
        self.ent_col = List[Int32]()
        self.ent_seg = List[Int32]()
        self.files = List[String]()
        self.file_size = List[Int64]()
        self.file_mtime_sec = List[Int64]()
        self.file_mtime_nsec = List[Int64]()
        self.file_seg = List[Int32]()
        self._path_slots = List[Int32]()
        self.segments = List[_Segment]()
        self.dead_bytes = 0
        self.pending = List[Int32]()
        self.built = False
        self.recheck = List[Int32]()

    def is_ready(self) -> Bool:
        """True once the initial build has finished and no revalidation
        sweep is outstanding.

        ``find_symbol`` gates its fast path on this: while it is False
        the picker falls back to spawning ``rg``, so a cold or
        mid-sweep index is slow rather than incomplete."""
        return self.built and len(self.pending) == 0 \
            and len(self.recheck) == 0

    def entry_count(self) -> Int:
        """Live entries. Retired segments' entries are excluded, so this
        is what a query can actually return."""
        var n = 0
        for i in range(len(self.segments)):
            if self.segments[i].live:
                n += Int(self.segments[i].ent_end) \
                    - Int(self.segments[i].ent_start)
        return n

    def blob_bytes(self) -> Int:
        """Bytes the per-keystroke SIMD pass has to sweep, dead segments
        included. The figure to watch if queries ever feel slow."""
        return len(self.blob)

    # --- file roster ------------------------------------------------------

    def _file_id(self, path: String) -> Int:
        """File id for ``path``, or -1. O(1) via ``_path_slots``."""
        if len(self._path_slots) == 0:
            return -1
        var mask = len(self._path_slots) - 1
        var i = Int(_hash_bytes(path.as_bytes())) & mask
        while True:
            var v = Int(self._path_slots[i])
            if v == 0:
                return -1
            if self.files[v - 1] == path:
                return v - 1
            i = (i + 1) & mask

    def _register_path(mut self, fid: Int):
        """Insert ``fid``'s path into the lookup table, growing first if
        the table is getting full."""
        if (len(self.files) + 1) * 10 > len(self._path_slots) * 7:
            self._rehash_paths(_slot_capacity_for(len(self.files) + 1))
        var mask = len(self._path_slots) - 1
        var i = Int(_hash_bytes(self.files[fid].as_bytes())) & mask
        while Int(self._path_slots[i]) != 0:
            i = (i + 1) & mask
        self._path_slots[i] = Int32(fid + 1)

    def _rehash_paths(mut self, cap: Int):
        var slots = List[Int32](capacity=cap)
        for _ in range(cap):
            slots.append(Int32(0))
        var mask = cap - 1
        for fid in range(len(self.files)):
            var i = Int(_hash_bytes(self.files[fid].as_bytes())) & mask
            while Int(slots[i]) != 0:
                i = (i + 1) & mask
            slots[i] = Int32(fid + 1)
        self._path_slots = slots^

    def set_file_list(mut self, paths: List[String]):
        """Install the project's file roster and queue everything for
        indexing.

        Files already present keep their segments (so a re-listing after
        a ``git ls-files`` refresh doesn't throw away work); files that
        disappeared have their segments retired; new files are queued.
        """
        var keep = List[Bool](capacity=len(self.files))
        for _ in range(len(self.files)):
            keep.append(False)
        var queued = List[Int32]()
        for i in range(len(paths)):
            var existing = self._file_id(paths[i])
            if existing >= 0:
                keep[existing] = True
                if self.file_seg[existing] < 0:
                    queued.append(Int32(existing))
                continue
            self.files.append(paths[i])
            self.file_size.append(Int64(0))
            self.file_mtime_sec.append(Int64(-1))
            self.file_mtime_nsec.append(Int64(-1))
            self.file_seg.append(Int32(-1))
            self._register_path(len(self.files) - 1)
            keep.append(True)
            queued.append(Int32(len(self.files) - 1))
        # Retire whatever vanished from the roster.
        for i in range(len(keep)):
            if not keep[i]:
                self._retire_segment(i)
                self.file_mtime_sec[i] = Int64(-1)
                self.file_mtime_nsec[i] = Int64(-1)
        self.pending = queued^
        self.built = len(self.pending) == 0

    def build_step(mut self, budget_bytes: Int) -> Bool:
        """Index queued files until ``budget_bytes`` of file content has
        been read, then return. True while work remains.

        Called from the host's per-frame hook so a first open of a large
        project fills in over a few frames instead of stalling one.
        """
        var spent = 0
        while len(self.pending) > 0 and spent < budget_bytes:
            var fid = Int(self.pending.pop())
            spent += self._index_file(fid)
        if len(self.pending) == 0:
            self.built = True
            return False
        return True

    # --- staleness --------------------------------------------------------

    def begin_revalidation(mut self):
        """Queue every known file for a ``stat`` comparison. Cheap to
        call — the work happens in ``revalidate_step``."""
        var all = List[Int32](capacity=len(self.files))
        for i in range(len(self.files)):
            all.append(Int32(i))
        self.recheck = all^

    def revalidate_step(mut self, budget_files: Int) -> Bool:
        """``stat`` up to ``budget_files`` queued files and re-index the
        ones whose stamp moved. True while work remains.

        The comparison is ``(size, mtime_sec, mtime_nsec)``. Seconds
        alone would miss a same-second same-size rewrite, which is
        exactly the shape ``git checkout`` and code generators produce.
        """
        var n = 0
        while len(self.recheck) > 0 and n < budget_files:
            var fid = Int(self.recheck.pop())
            n += 1
            var info = stat_file(self.files[fid])
            if not info.ok:
                # Gone or unreadable: retire it but leave it on the
                # roster, so a file that comes back is picked up by the
                # next ``set_file_list``.
                self._retire_segment(fid)
                self.file_mtime_sec[fid] = Int64(-1)
                self.file_mtime_nsec[fid] = Int64(-1)
                continue
            if self.file_seg[fid] >= 0 \
                    and info.size == self.file_size[fid] \
                    and info.mtime_sec == self.file_mtime_sec[fid] \
                    and info.mtime_nsec == self.file_mtime_nsec[fid]:
                continue
            _ = self._index_file(fid)
        if len(self.recheck) == 0:
            self.compact()
            return False
        return True

    def reindex_file(mut self, path: String) -> Bool:
        """Re-index one file from disk. Call on save and on any known
        out-of-band write. False when ``path`` isn't in the roster."""
        var fid = self._file_id(path)
        if fid < 0:
            return False
        _ = self._index_file(fid)
        return True

    def reindex_from_text(mut self, path: String, text: String) -> Bool:
        """Re-index one file from an in-memory buffer rather than disk.

        This is how unsaved editor content reaches the picker. The
        stamp is set to ``-1`` so the next revalidation sweep re-reads
        from disk unconditionally — a buffer-derived segment must never
        be mistaken for a verified on-disk one.
        """
        var fid = self._file_id(path)
        if fid < 0:
            self.files.append(path)
            self.file_size.append(Int64(0))
            self.file_mtime_sec.append(Int64(-1))
            self.file_mtime_nsec.append(Int64(-1))
            self.file_seg.append(Int32(-1))
            self._register_path(len(self.files) - 1)
            fid = len(self.files) - 1
        self._retire_segment(fid)
        self._add_segment(fid, text.as_bytes())
        self.file_size[fid] = Int64(0)
        self.file_mtime_sec[fid] = Int64(-1)
        self.file_mtime_nsec[fid] = Int64(-1)
        return True

    # --- indexing ---------------------------------------------------------

    def _index_file(mut self, fid: Int) -> Int:
        """Read and tokenize one file, replacing its segment. Returns
        the bytes read, for the caller's budget accounting."""
        var info = stat_file(self.files[fid])
        self._retire_segment(fid)
        if not info.ok or info.is_dir() \
                or Int(info.size) > _MAX_FILE_BYTES:
            self.file_mtime_sec[fid] = Int64(-1)
            self.file_mtime_nsec[fid] = Int64(-1)
            return 0
        var text: String
        try:
            text = read_file(self.files[fid])
        except:
            self.file_mtime_sec[fid] = Int64(-1)
            self.file_mtime_nsec[fid] = Int64(-1)
            return 0
        var b = text.as_bytes()
        # Record the stamp we actually indexed, not a fresh stat: if the
        # file is rewritten between the stat and the read we want the
        # next sweep to see a mismatch and try again.
        self.file_size[fid] = info.size
        self.file_mtime_sec[fid] = info.mtime_sec
        self.file_mtime_nsec[fid] = info.mtime_nsec
        if _looks_binary(b):
            return len(b)
        self._add_segment(fid, b)
        return len(b)

    def _retire_segment(mut self, fid: Int):
        """Mark this file's segment dead. Its bytes stay in ``blob``
        (offsets of every other segment must not move) and are reclaimed
        by ``compact``."""
        var sid = Int(self.file_seg[fid])
        if sid < 0:
            return
        if self.segments[sid].live:
            self.segments[sid].live = False
            self.dead_bytes += Int(self.segments[sid].blob_end) \
                - Int(self.segments[sid].blob_start)
        self.file_seg[fid] = Int32(-1)

    def _add_segment(mut self, fid: Int, b: Span[UInt8, _]):
        """Tokenize ``b`` and append its unique identifiers as a fresh
        segment owned by ``fid``."""
        var seg_id = len(self.segments)
        var blob_start = len(self.blob)
        var ent_start = len(self.ent_off)
        # Within-file dedupe table, discarded when the segment closes.
        # Holds ``entry ordinal + 1``. Sized from the byte count because
        # no distinct-identifier estimate is available up front, and one
        # identifier per four bytes is a safe over-estimate for source.
        var slot_cap = _slot_capacity_for(len(b) // 4 + 1)
        var slots = List[Int32](capacity=slot_cap)
        for _ in range(slot_cap):
            slots.append(Int32(0))
        var mask = slot_cap - 1
        var line = 1
        var line_start = 0
        var i = 0
        var n = len(b)
        while i < n:
            var c = b[i]
            if c == 0x0A:
                line += 1
                i += 1
                line_start = i
                continue
            if not is_symbol_byte(c):
                i += 1
                continue
            var start = i
            while i < n and is_symbol_byte(b[i]):
                i += 1
            var span = b[start:i]
            if len(span) < SYMBOL_MIN_LEN or len(span) > SYMBOL_MAX_LEN:
                continue
            # A token that opens with a digit is a number or a hex
            # literal, not a symbol. Dropping them cut this corpus's
            # entry count by 15% and removes the noise a numeric query
            # used to surface.
            if _starts_with_digit(span):
                continue
            var h = Int(_hash_bytes(span)) & mask
            var dup = False
            while Int(slots[h]) != 0:
                var e = Int(slots[h]) - 1
                if Int(self.ent_len[e]) == len(span) \
                        and self._entry_equals(e, span):
                    dup = True
                    break
                h = (h + 1) & mask
            if dup:
                continue
            slots[h] = Int32(len(self.ent_off) + 1)
            self.ent_off.append(Int32(len(self.blob)))
            self.ent_len.append(Int32(len(span)))
            self.ent_line.append(Int32(line))
            self.ent_col.append(Int32(start - line_start + 1))
            self.ent_seg.append(Int32(seg_id))
            for k in range(len(span)):
                self.blob.append(span[k])
            self.blob.append(0)
        self.segments.append(_Segment(
            Int32(fid), Int32(blob_start), Int32(len(self.blob)),
            Int32(ent_start), Int32(len(self.ent_off)), True,
        ))
        self.file_seg[fid] = Int32(seg_id)

    def _entry_equals(self, e: Int, name: Span[UInt8, _]) -> Bool:
        """Byte-compare entry ``e``'s name against ``name``. The caller
        checks lengths first — that is the cheap discriminator."""
        var off = Int(self.ent_off[e])
        for k in range(len(name)):
            if self.blob[off + k] != name[k]:
                return False
        return True

    def compact(mut self):
        """Rewrite ``blob`` without dead segments, once they are more
        than ``_COMPACT_DEAD_FRACTION`` percent of it.

        Every offset in ``ent_off`` and ``segments`` is rebuilt, so this
        must not run while a query is mid-scan — it is called from the
        end of a revalidation sweep, never from ``search``.
        """
        if len(self.blob) <= 1:
            return
        if self.dead_bytes * 100 < len(self.blob) * _COMPACT_DEAD_FRACTION:
            return
        var new_blob = List[UInt8](capacity=len(self.blob) - self.dead_bytes)
        new_blob.append(0)
        var new_off = List[Int32]()
        var new_len = List[Int32]()
        var new_line = List[Int32]()
        var new_col = List[Int32]()
        var new_seg = List[Int32]()
        var new_segments = List[_Segment]()
        for s in range(len(self.segments)):
            if not self.segments[s].live:
                continue
            var seg = self.segments[s]
            var new_sid = len(new_segments)
            var blob_start = len(new_blob)
            var ent_start = len(new_off)
            for e in range(Int(seg.ent_start), Int(seg.ent_end)):
                var off = Int(self.ent_off[e])
                var ln = Int(self.ent_len[e])
                new_off.append(Int32(len(new_blob)))
                new_len.append(self.ent_len[e])
                new_line.append(self.ent_line[e])
                new_col.append(self.ent_col[e])
                new_seg.append(Int32(new_sid))
                for k in range(off, off + ln):
                    new_blob.append(self.blob[k])
                new_blob.append(0)
            new_segments.append(_Segment(
                seg.file_id, Int32(blob_start), Int32(len(new_blob)),
                Int32(ent_start), Int32(len(new_off)), True,
            ))
            self.file_seg[Int(seg.file_id)] = Int32(new_sid)
        self.blob = new_blob^
        self.ent_off = new_off^
        self.ent_len = new_len^
        self.ent_line = new_line^
        self.ent_col = new_col^
        self.ent_seg = new_seg^
        self.segments = new_segments^
        self.dead_bytes = 0

    # --- query ------------------------------------------------------------

    def _entry_at(self, off: Int) -> Int:
        """Entry ordinal whose name contains blob offset ``off``.

        ``ent_off`` is ascending because segments only append, so this
        is a binary search. Off the hot path — it runs once per hit, not
        once per byte."""
        var lo = 0
        var hi = len(self.ent_off)
        while lo + 1 < hi:
            var mid = (lo + hi) // 2
            if Int(self.ent_off[mid]) <= off:
                lo = mid
            else:
                hi = mid
        return lo

    def search(self, needle: String, cap: Int) -> List[SymbolHit]:
        """Every indexed identifier containing ``needle``, deduped by
        name, first occurrence wins, up to ``cap`` results.

        One SIMD pass over ``blob``. After each hit we resume past the
        entry we landed in: a name can only be reported once, so this
        both avoids re-reporting and skips the rest of a long name.
        """
        var out = List[SymbolHit]()
        var nb = needle.as_bytes()
        if len(nb) == 0 or len(self.ent_off) == 0:
            return out^
        # Dedupe across segments: the blob is deduped only within a file,
        # so a name legitimately appears once per file that mentions it,
        # and the picker wants one row per name. A table rather than a
        # rescan of the emitted names — at ``cap`` = 500 the rescan cost
        # about as much as the blob sweep it was riding on.
        var slot_cap = _slot_capacity_for(cap)
        var slots = List[Int32](capacity=slot_cap)
        for _ in range(slot_cap):
            slots.append(Int32(0))
        var mask = slot_cap - 1
        var pos = 0
        while len(out) < cap:
            var at = find_exact(Span(self.blob), nb, pos)
            if at < 0:
                break
            var e = self._entry_at(at)
            var off = Int(self.ent_off[e])
            var ln = Int(self.ent_len[e])
            # Resume past this entry's terminating NUL whether or not we
            # keep it, so progress is guaranteed.
            pos = off + ln + 1
            # A needle of identifier bytes cannot straddle the NUL
            # separator, so this is defensive rather than load-bearing —
            # but a hit *can* land in a retired segment, and those are
            # not results.
            if at < off or at + len(nb) > off + ln:
                continue
            var seg = Int(self.ent_seg[e])
            if not self.segments[seg].live:
                continue
            var name_span = Span(self.blob)[off:off + ln]
            var h = Int(_hash_bytes(name_span)) & mask
            var dup = False
            while Int(slots[h]) != 0:
                var prev = Int(slots[h]) - 1
                if Int(self.ent_len[prev]) == ln \
                        and self._entry_equals(prev, name_span):
                    dup = True
                    break
                h = (h + 1) & mask
            if dup:
                continue
            slots[h] = Int32(e + 1)
            var fid = Int(self.segments[seg].file_id)
            out.append(SymbolHit(
                String(StringSpan(unsafe_from_utf8=name_span)),
                self.files[fid],
                Int(self.ent_line[e]),
                Int(self.ent_col[e]),
            ))
        return out^

    # --- submit-time verification ----------------------------------------

    def verify_occurrence(
        self, name: String, path: String, line: Int, column: Int,
    ) -> Optional[Tuple[Int, Int]]:
        """``verify_occurrence_in`` against ``path``'s on-disk contents.

        Only correct for a file whose segment came from disk. A file
        open and modified in an editor was indexed from the *buffer*
        (see ``reindex_from_text``), so checking it against disk would
        report a spurious miss — hosts with a live buffer must pass it
        to ``verify_occurrence_in`` instead."""
        var text: String
        try:
            text = read_file(path)
        except:
            return Optional[Tuple[Int, Int]]()
        return self.verify_occurrence_in(name, text, line, column)

    def verify_occurrence_in(
        self, name: String, text: String, line: Int, column: Int,
    ) -> Optional[Tuple[Int, Int]]:
        """Confirm ``name`` really sits at ``(line, column)`` in ``text``,
        relocating it within the same text if it moved.

        Returns the verified ``(line, column)``, or ``None`` when the
        name is not there at all — the host's cue to distrust the seed
        rather than navigate to it.

        This is the backstop that makes an out-of-date index harmless:
        the worst a stale entry can cost is one text scan on submit.
        """
        var b = text.as_bytes()
        var nb = name.as_bytes()
        if len(nb) == 0:
            return Optional[Tuple[Int, Int]]()
        # ``scan`` only ever moves forward, so counting newlines this
        # way is O(len(b)) across every hit rather than per hit.
        var from_ = 0
        var scan = 0
        var cur_line = 1
        var line_start = 0
        var best_line = -1
        var best_col = -1
        while True:
            var at = find_exact(b, nb, from_)
            if at < 0:
                break
            from_ = at + 1
            while scan < at:
                if b[scan] == 0x0A:
                    cur_line += 1
                    line_start = scan + 1
                scan += 1
            # Whole-identifier only: the picker's entries are whole
            # identifiers, so a hit inside a longer name is a different
            # symbol and must not satisfy the check.
            if at > 0 and is_symbol_byte(b[at - 1]):
                continue
            var after = at + len(nb)
            if after < len(b) and is_symbol_byte(b[after]):
                continue
            var col = at - line_start + 1
            if cur_line == line and col == column:
                return Optional[Tuple[Int, Int]]((line, column))
            if best_line < 0:
                best_line = cur_line
                best_col = col
        if best_line >= 0:
            return Optional[Tuple[Int, Int]]((best_line, best_col))
        return Optional[Tuple[Int, Int]]()
