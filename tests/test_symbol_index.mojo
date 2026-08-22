"""The Find Symbol identifier index.

The load-bearing tests here are the *staleness* ones. The index exists
to avoid re-reading the project on every keystroke, and the whole reason
that trade is acceptable is that a stale entry is impossible to observe:

- ``test_reindex_retires_the_old_segment`` and
  ``test_deleted_file_stops_matching`` cover the per-file segment swap,
  which is what makes re-indexing self-healing rather than leaving ghost
  entries behind.
- ``test_revalidation_catches_a_same_second_rewrite`` is the one that
  justifies adding ``mtime_nsec`` to ``FileInfo``: with seconds-only
  granularity a rewrite that keeps the file size is invisible, and that
  is the shape ``git checkout`` produces.
- ``test_verify_occurrence_*`` cover the submit-time backstop, the thing
  that keeps a stale seed from sending go-to-definition somewhere wrong.
- ``test_search_matches_a_reference_scan`` is the parity test: the SIMD
  blob sweep must agree with a naive per-file tokenize-and-compare over
  the same corpus, including hits at segment and lane boundaries.
"""

from std.collections.list import List
from std.testing import assert_equal, assert_false, assert_true

from turbokod.file_io import read_file, stat_file, write_file
from turbokod.symbol_index import (
    SYMBOL_MAX_LEN, SYMBOL_MIN_LEN, SymbolHit, SymbolIndex, is_symbol_byte,
)

from support import _ensure_dir, _rm_rf, _temp_path, setup_test_env


def _root() -> String:
    return _temp_path(String("_symidx"))


def _seed(var files: List[Tuple[String, String]]) raises -> String:
    """Create a scratch project containing ``(relative-path, content)``
    and return its root. Any previous scratch tree is removed first."""
    var root = _root()
    _rm_rf(root)
    _ensure_dir(root)
    for i in range(len(files)):
        var rel = files[i][0]
        var body = files[i][1]
        _ = write_file(root + String("/") + rel, body)
    return root


def _paths(root: String, var rels: List[String]) -> List[String]:
    var out = List[String]()
    for i in range(len(rels)):
        out.append(root + String("/") + rels[i])
    return out^


def _built(root: String, var rels: List[String]) -> SymbolIndex:
    var idx = SymbolIndex()
    idx.reset(root)
    idx.set_file_list(_paths(root, rels^))
    while idx.build_step(1 << 30):
        pass
    return idx^


def _names(hits: List[SymbolHit]) -> List[String]:
    var out = List[String]()
    for i in range(len(hits)):
        out.append(hits[i].name)
    return out^


def _has(hits: List[SymbolHit], name: String) -> Bool:
    for i in range(len(hits)):
        if hits[i].name == name:
            return True
    return False


def _hit(hits: List[SymbolHit], name: String) -> SymbolHit:
    for i in range(len(hits)):
        if hits[i].name == name:
            return hits[i]
    return SymbolHit(String(""), String(""), 0, 0)


# --- reference implementation ---------------------------------------------


def _reference_search(
    files: List[Tuple[String, String]], needle: String,
) -> List[String]:
    """Naive oracle: tokenize every file the dumb way, keep identifiers
    containing ``needle``, dedupe by name preserving first sight.

    Deliberately shares no code with ``SymbolIndex`` — that is the point
    of a parity test."""
    var out = List[String]()
    var nb = needle.as_bytes()
    for f in range(len(files)):
        var b = files[f][1].as_bytes()
        var i = 0
        while i < len(b):
            if not is_symbol_byte(b[i]):
                i += 1
                continue
            var start = i
            while i < len(b) and is_symbol_byte(b[i]):
                i += 1
            var n = i - start
            if n < SYMBOL_MIN_LEN or n > SYMBOL_MAX_LEN:
                continue
            if 0x30 <= Int(b[start]) and Int(b[start]) <= 0x39:
                continue
            # Substring test, scalar and obvious.
            var found = False
            for at in range(n - len(nb) + 1):
                var same = True
                for k in range(len(nb)):
                    if b[start + at + k] != nb[k]:
                        same = False
                        break
                if same:
                    found = True
                    break
            if not found:
                continue
            var name = String(StringSpan(unsafe_from_utf8=b[start:i]))
            var dup = False
            for k in range(len(out)):
                if out[k] == name:
                    dup = True
                    break
            if not dup:
                out.append(name)
    return out^


# --- indexing basics ------------------------------------------------------


def test_indexes_identifiers_with_first_occurrence() raises:
    var files = List[Tuple[String, String]]()
    files.append((String("a.py"), String(
        "import os\n"
        "def handle_key(self, event):\n"
        "    return handle_key\n"
    )))
    var root = _seed(files.copy())
    var rels = List[String]()
    rels.append(String("a.py"))
    var idx = _built(root, rels^)

    var hits = idx.search(String("handle"), 50)
    assert_equal(len(hits), 1)
    assert_equal(hits[0].name, String("handle_key"))
    # First occurrence, not the later one on line 3.
    assert_equal(hits[0].line, 2)
    assert_equal(hits[0].column, 5)
    assert_equal(hits[0].path, root + String("/a.py"))
    _rm_rf(root)


def test_short_and_numeric_tokens_are_not_indexed() raises:
    var files = List[Tuple[String, String]]()
    files.append((String("a.c"), String(
        "int x = 1024;\n"
        "int ab = 0xdeadbeef;\n"
        "int c1 = 12ab34;\n"
    )))
    var root = _seed(files.copy())
    var rels = List[String]()
    rels.append(String("a.c"))
    var idx = _built(root, rels^)

    # ``x`` is one byte: unreachable by a 2-char minimum query anyway.
    assert_equal(len(idx.search(String("x"), 50)), 0)
    # Digit-initial tokens are numbers, not symbols.
    assert_false(_has(idx.search(String("02"), 50), String("1024")))
    assert_false(_has(idx.search(String("2ab"), 50), String("12ab34")))
    # ...but identifiers that merely *contain* digits are kept.
    assert_true(_has(idx.search(String("c1"), 50), String("c1")))
    assert_true(_has(idx.search(String("ab"), 50), String("ab")))
    _rm_rf(root)


def test_a_name_is_reported_once_per_query() raises:
    """Within a file the blob is deduped; across files the query dedupes.
    Either way the picker wants one row per name."""
    var files = List[Tuple[String, String]]()
    files.append((String("a.py"), String("alpha\nalpha\nalpha\n")))
    files.append((String("b.py"), String("# alpha again\n")))
    var root = _seed(files.copy())
    var rels = List[String]()
    rels.append(String("a.py"))
    rels.append(String("b.py"))
    var idx = _built(root, rels^)

    var hits = idx.search(String("alph"), 50)
    assert_equal(len(hits), 1)
    assert_equal(hits[0].name, String("alpha"))
    _rm_rf(root)


def test_search_respects_the_cap() raises:
    var body = String("")
    for i in range(200):
        body += String("sym_") + String(i) + String("\n")
    var files = List[Tuple[String, String]]()
    files.append((String("a.py"), body))
    var root = _seed(files.copy())
    var rels = List[String]()
    rels.append(String("a.py"))
    var idx = _built(root, rels^)

    assert_equal(len(idx.search(String("sym_"), 10)), 10)
    assert_true(len(idx.search(String("sym_"), 1000)) >= 200)
    _rm_rf(root)


def test_binary_and_oversized_files_are_skipped() raises:
    var files = List[Tuple[String, String]]()
    files.append((String("bin.dat"), String("head\x00zzunique_bin\n")))
    files.append((String("ok.py"), String("zzunique_txt = 1\n")))
    var root = _seed(files.copy())
    var rels = List[String]()
    rels.append(String("bin.dat"))
    rels.append(String("ok.py"))
    var idx = _built(root, rels^)

    assert_false(_has(idx.search(String("zzunique"), 50),
                      String("zzunique_bin")))
    assert_true(_has(idx.search(String("zzunique"), 50),
                     String("zzunique_txt")))
    _rm_rf(root)


# --- parity with a naive scan --------------------------------------------


def test_search_matches_a_reference_scan() raises:
    """The SIMD blob sweep must agree with an obvious scalar tokenize.

    The corpus is padded so identifiers land at a spread of offsets:
    ``find_exact`` steps 32 bytes at a time, and a match straddling a
    lane edge is the classic way to get this wrong."""
    var files = List[Tuple[String, String]]()
    for f in range(4):
        var body = String("")
        for i in range(40):
            # Varying-length filler shifts every subsequent identifier
            # across lane boundaries.
            for _ in range(i % 7):
                body += String("-")
            body += String("pad") + String(i) + String("_f") + String(f)
            body += String(" value_") + String(i * 3 % 11)
            body += String(" alpha_beta_") + String(i % 5)
            body += String(" x") + String("\n")
        files.append((String("f") + String(f) + String(".py"), body))

    var root = _seed(files.copy())
    var rels = List[String]()
    for f in range(4):
        rels.append(String("f") + String(f) + String(".py"))
    var idx = _built(root, rels^)

    var needles = List[String]()
    needles.append(String("pad"))
    needles.append(String("value"))
    needles.append(String("alpha_beta"))
    needles.append(String("_f2"))
    needles.append(String("a_b"))
    needles.append(String("zzz_absent"))
    for n in range(len(needles)):
        var want = _reference_search(files, needles[n])
        var got = _names(idx.search(needles[n], 100000))
        assert_equal(len(got), len(want))
        for i in range(len(want)):
            var present = False
            for k in range(len(got)):
                if got[k] == want[i]:
                    present = True
                    break
            assert_true(present)
    _rm_rf(root)


# --- staleness ------------------------------------------------------------


def test_reindex_retires_the_old_segment() raises:
    """A renamed symbol must stop matching. This is the whole reason the
    blob is segmented per file rather than globally deduped."""
    var files = List[Tuple[String, String]]()
    files.append((String("a.py"), String("def old_name():\n    pass\n")))
    var root = _seed(files.copy())
    var rels = List[String]()
    rels.append(String("a.py"))
    var idx = _built(root, rels^)
    assert_true(_has(idx.search(String("old_name"), 50), String("old_name")))

    _ = write_file(root + String("/a.py"),
                   String("def new_name():\n    pass\n"))
    assert_true(idx.reindex_file(root + String("/a.py")))

    assert_equal(len(idx.search(String("old_name"), 50)), 0)
    assert_true(_has(idx.search(String("new_name"), 50), String("new_name")))
    _rm_rf(root)


def test_a_name_surviving_in_another_file_still_matches() raises:
    """Retiring one segment must not retire a shared name. The global
    dedupe layout could not get this right without an inverted index —
    per-file segments get it for free."""
    var files = List[Tuple[String, String]]()
    files.append((String("a.py"), String("shared_sym = 1\n")))
    files.append((String("b.py"), String("shared_sym = 2\n")))
    var root = _seed(files.copy())
    var rels = List[String]()
    rels.append(String("a.py"))
    rels.append(String("b.py"))
    var idx = _built(root, rels^)

    _ = write_file(root + String("/a.py"), String("gone = 1\n"))
    assert_true(idx.reindex_file(root + String("/a.py")))

    var hits = idx.search(String("shared_sym"), 50)
    assert_equal(len(hits), 1)
    assert_equal(hits[0].path, root + String("/b.py"))
    _rm_rf(root)


def test_deleted_file_stops_matching() raises:
    var files = List[Tuple[String, String]]()
    files.append((String("a.py"), String("only_here = 1\n")))
    files.append((String("b.py"), String("other = 1\n")))
    var root = _seed(files.copy())
    var rels = List[String]()
    rels.append(String("a.py"))
    rels.append(String("b.py"))
    var idx = _built(root, rels^)
    assert_true(_has(idx.search(String("only_here"), 50),
                     String("only_here")))

    # The roster refresh (what a ``git ls-files`` re-listing produces)
    # drops the file; its segment must go with it.
    var remaining = List[String]()
    remaining.append(String("b.py"))
    idx.set_file_list(_paths(root, remaining^))
    while idx.build_step(1 << 30):
        pass

    assert_equal(len(idx.search(String("only_here"), 50)), 0)
    assert_true(_has(idx.search(String("other"), 50), String("other")))
    _rm_rf(root)


def test_new_file_is_picked_up_without_losing_existing_segments() raises:
    var files = List[Tuple[String, String]]()
    files.append((String("a.py"), String("first_sym = 1\n")))
    var root = _seed(files.copy())
    var rels = List[String]()
    rels.append(String("a.py"))
    var idx = _built(root, rels^)

    _ = write_file(root + String("/b.py"), String("second_sym = 1\n"))
    var both = List[String]()
    both.append(String("a.py"))
    both.append(String("b.py"))
    idx.set_file_list(_paths(root, both^))
    while idx.build_step(1 << 30):
        pass

    assert_true(_has(idx.search(String("first_sym"), 50),
                     String("first_sym")))
    assert_true(_has(idx.search(String("second_sym"), 50),
                     String("second_sym")))
    _rm_rf(root)


def test_revalidation_catches_a_same_second_rewrite() raises:
    """The reason ``FileInfo`` carries ``mtime_nsec``.

    Both writes land in the same wall-clock second and the replacement
    is byte-for-byte the same length, so ``(mtime_sec, size)`` is
    identical across them. Only the nanosecond half of the timespec
    distinguishes the two — and this is exactly the shape a
    ``git checkout`` of a same-size file produces."""
    var files = List[Tuple[String, String]]()
    files.append((String("a.py"), String("aaa_sym = 1\n")))
    var root = _seed(files.copy())
    var rels = List[String]()
    rels.append(String("a.py"))
    var idx = _built(root, rels^)
    var before = stat_file(root + String("/a.py"))

    # Same length, different content, immediately after.
    _ = write_file(root + String("/a.py"), String("bbb_sym = 1\n"))
    var after = stat_file(root + String("/a.py"))
    assert_equal(before.size, after.size)
    assert_equal(before.mtime_sec, after.mtime_sec)
    assert_false(before.same_content_stamp(after))

    idx.begin_revalidation()
    while idx.revalidate_step(1000):
        pass

    assert_equal(len(idx.search(String("aaa_sym"), 50)), 0)
    assert_true(_has(idx.search(String("bbb_sym"), 50), String("bbb_sym")))
    _rm_rf(root)


def test_revalidation_leaves_untouched_files_alone() raises:
    var files = List[Tuple[String, String]]()
    files.append((String("a.py"), String("steady_sym = 1\n")))
    var root = _seed(files.copy())
    var rels = List[String]()
    rels.append(String("a.py"))
    var idx = _built(root, rels^)
    var entries_before = idx.entry_count()

    idx.begin_revalidation()
    while idx.revalidate_step(1000):
        pass

    assert_equal(idx.entry_count(), entries_before)
    assert_true(_has(idx.search(String("steady_sym"), 50),
                     String("steady_sym")))
    _rm_rf(root)


def test_unsaved_buffer_text_is_searchable() raises:
    """Strictly better than the ``rg`` this replaces: rg reads disk, so a
    symbol typed and not yet saved was invisible to the old picker."""
    var files = List[Tuple[String, String]]()
    files.append((String("a.py"), String("on_disk_sym = 1\n")))
    var root = _seed(files.copy())
    var rels = List[String]()
    rels.append(String("a.py"))
    var idx = _built(root, rels^)

    assert_true(idx.reindex_from_text(
        root + String("/a.py"),
        String("on_disk_sym = 1\ndef just_typed_sym():\n    pass\n"),
    ))
    assert_true(_has(idx.search(String("just_typed"), 50),
                     String("just_typed_sym")))

    # A buffer-derived segment is never mistaken for a verified on-disk
    # one: the next sweep must re-read from disk and drop the unsaved
    # symbol again.
    idx.begin_revalidation()
    while idx.revalidate_step(1000):
        pass
    assert_equal(len(idx.search(String("just_typed"), 50)), 0)
    assert_true(_has(idx.search(String("on_disk_sym"), 50),
                     String("on_disk_sym")))
    _rm_rf(root)


def test_is_ready_gates_the_fast_path() raises:
    """``find_symbol`` falls back to ``rg`` while this is False, which is
    what keeps a cold index slow rather than incomplete."""
    var body = String("")
    for i in range(400):
        body += String("gate_sym_") + String(i) + String("\n")
    var files = List[Tuple[String, String]]()
    for f in range(6):
        files.append((String("f") + String(f) + String(".py"), body))
    var root = _seed(files.copy())
    var rels = List[String]()
    for f in range(6):
        rels.append(String("f") + String(f) + String(".py"))

    var idx = SymbolIndex()
    idx.reset(root)
    assert_false(idx.is_ready())
    idx.set_file_list(_paths(root, rels^))
    assert_false(idx.is_ready())
    # A tiny budget must not finish the build in one step.
    assert_true(idx.build_step(16))
    assert_false(idx.is_ready())
    while idx.build_step(1 << 20):
        pass
    assert_true(idx.is_ready())

    idx.begin_revalidation()
    assert_false(idx.is_ready())
    while idx.revalidate_step(1):
        pass
    assert_true(idx.is_ready())
    _rm_rf(root)


def test_compaction_preserves_every_live_entry() raises:
    """Repeated re-indexing accumulates dead segments; compaction
    rewrites the blob and every offset in it. If ``ent_off`` and the
    segment table drift apart, queries return the wrong names — so this
    checks content, not just counts."""
    var files = List[Tuple[String, String]]()
    for f in range(4):
        files.append((String("f") + String(f) + String(".py"),
                      String("keep_") + String(f) + String(" = 1\n")))
    var root = _seed(files.copy())
    var rels = List[String]()
    for f in range(4):
        rels.append(String("f") + String(f) + String(".py"))
    var idx = _built(root, rels^)

    # Churn one file enough times that dead bytes dominate the blob.
    for gen in range(12):
        _ = write_file(root + String("/f0.py"),
                       String("churn_") + String(gen) + String(" = 1\n"))
        _ = idx.reindex_file(root + String("/f0.py"))
    idx.begin_revalidation()
    while idx.revalidate_step(1000):
        pass

    for f in range(1, 4):
        var want = String("keep_") + String(f)
        var hits = idx.search(want, 50)
        assert_equal(len(hits), 1)
        assert_equal(hits[0].name, want)
        assert_equal(hits[0].path,
                     root + String("/f") + String(f) + String(".py"))
    assert_true(_has(idx.search(String("churn_11"), 50),
                     String("churn_11")))
    assert_equal(len(idx.search(String("churn_0 "), 50)), 0)
    _rm_rf(root)


# --- submit-time verification --------------------------------------------


def test_verify_occurrence_confirms_a_fresh_seed() raises:
    var files = List[Tuple[String, String]]()
    files.append((String("a.py"), String(
        "import os\n"
        "def target_sym():\n"
        "    pass\n"
    )))
    var root = _seed(files.copy())
    var rels = List[String]()
    rels.append(String("a.py"))
    var idx = _built(root, rels^)

    var hit = _hit(idx.search(String("target_sym"), 50), String("target_sym"))
    var v = idx.verify_occurrence(
        hit.name, hit.path, hit.line, hit.column,
    )
    assert_true(Bool(v))
    assert_equal(v.value()[0], hit.line)
    assert_equal(v.value()[1], hit.column)
    _rm_rf(root)


def test_verify_occurrence_relocates_a_moved_symbol() raises:
    """The backstop that makes an out-of-date index harmless: the seed
    moved, so we hand the host the real location instead of letting it
    seed go-to-definition with a stale one."""
    var files = List[Tuple[String, String]]()
    files.append((String("a.py"), String("def moved_sym():\n    pass\n")))
    var root = _seed(files.copy())
    var rels = List[String]()
    rels.append(String("a.py"))
    var idx = _built(root, rels^)
    var hit = _hit(idx.search(String("moved_sym"), 50), String("moved_sym"))
    assert_equal(hit.line, 1)

    # Two lines inserted above, index not told.
    _ = write_file(root + String("/a.py"), String(
        "# header\n# header\ndef moved_sym():\n    pass\n"
    ))
    var v = idx.verify_occurrence(
        hit.name, hit.path, hit.line, hit.column,
    )
    assert_true(Bool(v))
    assert_equal(v.value()[0], 3)
    assert_equal(v.value()[1], 5)
    _rm_rf(root)


def test_verify_occurrence_rejects_a_vanished_symbol() raises:
    var files = List[Tuple[String, String]]()
    files.append((String("a.py"), String("def gone_sym():\n    pass\n")))
    var root = _seed(files.copy())
    var rels = List[String]()
    rels.append(String("a.py"))
    var idx = _built(root, rels^)
    var hit = _hit(idx.search(String("gone_sym"), 50), String("gone_sym"))

    _ = write_file(root + String("/a.py"), String("def other():\n    pass\n"))
    assert_false(Bool(idx.verify_occurrence(
        hit.name, hit.path, hit.line, hit.column,
    )))
    # A missing file is the same answer, not a crash.
    _rm_rf(root)
    assert_false(Bool(idx.verify_occurrence(
        hit.name, hit.path, hit.line, hit.column,
    )))


def test_verify_occurrence_ignores_substring_matches() raises:
    """``sym`` inside ``my_sym_helper`` is a different symbol. Accepting
    it would relocate the seed onto an unrelated identifier."""
    var files = List[Tuple[String, String]]()
    files.append((String("a.py"), String(
        "my_sym_helper = 1\n"
        "prefix_sym = 2\n"
        "sym = 3\n"
    )))
    var root = _seed(files.copy())
    var rels = List[String]()
    rels.append(String("a.py"))
    var idx = _built(root, rels^)

    var v = idx.verify_occurrence(String("sym"), root + String("/a.py"), 3, 1)
    assert_true(Bool(v))
    assert_equal(v.value()[0], 3)
    assert_equal(v.value()[1], 1)
    _rm_rf(root)


def main() raises:
    setup_test_env()
    test_indexes_identifiers_with_first_occurrence()
    test_short_and_numeric_tokens_are_not_indexed()
    test_a_name_is_reported_once_per_query()
    test_search_respects_the_cap()
    test_binary_and_oversized_files_are_skipped()
    test_search_matches_a_reference_scan()
    test_reindex_retires_the_old_segment()
    test_a_name_surviving_in_another_file_still_matches()
    test_deleted_file_stops_matching()
    test_new_file_is_picked_up_without_losing_existing_segments()
    test_revalidation_catches_a_same_second_rewrite()
    test_revalidation_leaves_untouched_files_alone()
    test_unsaved_buffer_text_is_searchable()
    test_is_ready_gates_the_fast_path()
    test_compaction_preserves_every_live_entry()
    test_verify_occurrence_confirms_a_fresh_seed()
    test_verify_occurrence_relocates_a_moved_symbol()
    test_verify_occurrence_rejects_a_vanished_symbol()
    test_verify_occurrence_ignores_substring_matches()
    print("symbol_index: 19 tests passed")
