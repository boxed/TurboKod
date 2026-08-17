"""Branchless / SIMD case folding and the search paths built on it.

One of the per-topic suites split out of the former
``test_basic.mojo``; shared fixtures live in ``tests/support.mojo``
and ``scripts/run_tests.sh`` runs every suite.

The load-bearing tests here are the *parity* ones: ``LineSearcher``
silently swaps libonig's ``(?i)`` for a SIMD byte scan whenever it can
prove the two agree, and the proof is only as good as
``test_line_searcher_matches_libonig_exactly``, which runs both against
the same corpus of ASCII and non-ASCII lines and demands identical
spans. ``test_fold_and_search_cross_simd_lane_boundary`` covers the other
easy way to get this wrong: an off-by-one in the 32-byte lane loop that
only shows up when a match straddles a lane edge.
"""

from std.collections.list import List
from std.collections.optional import Optional
from std.testing import assert_equal, assert_false, assert_true

from turbokod.case_fold import (
    contains_ci, eq_ci, find_ci, find_exact, find_folded, fold_ascii,
    fold_ascii_into, fold_byte, is_ascii, scan_folded, starts_with_ci,
)
from turbokod.editor import Editor
from turbokod.file_io import read_file, write_file
from turbokod.onig import OnigRegex, onig_global_init
from turbokod.project import find_in_project, replace_in_project
from turbokod.quick_open import (
    quick_open_match, quick_open_match_parts, split_query_parts,
)
from turbokod.search_options import (
    LineSearcher, SearchOptions, SearcherCache,
)

from support import _ensure_dir, _rm_rf, _temp_path, setup_test_env


# --- reference implementations ---------------------------------------------
#
# The branchy per-byte forms this module replaced, kept here as the
# oracle. If a fast path ever disagrees with these, the fast path is
# wrong.


def _ref_fold(s: String) -> String:
    var b = s.as_bytes()
    var out = List[UInt8]()
    for i in range(len(b)):
        var c = Int(b[i])
        if 0x41 <= c and c <= 0x5A:
            c += 0x20
        out.append(UInt8(c))
    return String(StringSpan(unsafe_from_utf8=out))


def _ref_find_ci(haystack: String, needle: String, start: Int) -> Int:
    var hb = haystack.as_bytes()
    var nb = needle.as_bytes()
    if len(nb) == 0:
        # An empty needle matches at ``start`` — but only if ``start`` is
        # a position that exists. The pre-``case_fold`` helper returned
        # ``start`` even past the end; nothing relied on it (query parts
        # are never empty) and the clamped answer is the defensible one.
        return start if start <= len(hb) else -1
    if start < 0:
        return -1
    var i = start
    while i + len(nb) <= len(hb):
        var ok = True
        for j in range(len(nb)):
            var a = Int(hb[i + j])
            var c = Int(nb[j])
            if 0x41 <= a and a <= 0x5A: a += 0x20
            if 0x41 <= c and c <= 0x5A: c += 0x20
            if a != c:
                ok = False
                break
        if ok:
            return i
        i += 1
    return -1


# --- fold ------------------------------------------------------------------


def test_fold_byte_covers_exactly_the_ascii_upper_range() raises:
    """The branchless ``(c - 0x41) <u 26`` test must fold exactly
    ``A``-``Z`` and nothing else — including no wraparound damage at the
    low end, which is the failure mode a signed compare would have."""
    for c in range(256):
        var got = Int(fold_byte(UInt8(c)))
        var want = c + 0x20 if (0x41 <= c and c <= 0x5A) else c
        assert_equal(got, want)
    # The neighbours of the range, spelled out for a readable failure.
    assert_equal(Int(fold_byte(UInt8(0x40))), 0x40)   # '@'
    assert_equal(Int(fold_byte(UInt8(0x41))), 0x61)   # 'A' -> 'a'
    assert_equal(Int(fold_byte(UInt8(0x5A))), 0x7A)   # 'Z' -> 'z'
    assert_equal(Int(fold_byte(UInt8(0x5B))), 0x5B)   # '['
    assert_equal(Int(fold_byte(UInt8(0x00))), 0x00)


def test_fold_leaves_utf8_intact_and_length_unchanged() raises:
    """Folding must never touch a byte >= 0x80, which is what makes the
    fold byte-length-preserving on UTF-8 and lets match offsets map 1:1
    onto the original buffer."""
    var samples = List[String]()
    samples.append(String("Godkänn ÅÄÖ"))
    samples.append(String("MIXED — em dash"))
    samples.append(String("ΑΒΓ Ελληνικά"))
    samples.append(String("日本語 CAPS"))
    samples.append(String("🔥 EMOJI 🔥"))
    samples.append(String(""))
    for i in range(len(samples)):
        var folded = fold_ascii(samples[i])
        assert_equal(folded, _ref_fold(samples[i]))
        assert_equal(
            len(folded.as_bytes()), len(samples[i].as_bytes()),
        )
    # Non-ASCII case pairs are deliberately *not* folded.
    assert_equal(fold_ascii(String("Ä")), String("Ä"))


def test_is_ascii_scans_the_whole_buffer() raises:
    """``is_ascii`` has no early exit; a high byte anywhere — including
    in the sub-lane tail — has to be reported."""
    var ascii_long = String("")
    for _ in range(20):
        ascii_long += String("abcdefghij")           # 200 bytes
    assert_true(is_ascii(ascii_long.as_bytes()))
    assert_true(is_ascii(String("").as_bytes()))
    assert_false(is_ascii(String("ä").as_bytes()))
    # High byte in the first lane, a later lane, and the scalar tail.
    assert_false(is_ascii((String("ä") + ascii_long).as_bytes()))
    assert_false(is_ascii((ascii_long + String("ä")).as_bytes()))
    var mid = String("x") * 40 + String("ä") + String("y") * 40
    assert_false(is_ascii(mid.as_bytes()))


def test_fold_ascii_into_reports_ascii_purity() raises:
    var buf = List[UInt8]()
    assert_true(fold_ascii_into(String("PLAIN ascii 123").as_bytes(), buf))
    assert_equal(String(StringSpan(unsafe_from_utf8=buf)),
                 String("plain ascii 123"))
    assert_false(fold_ascii_into(String("HAS ä").as_bytes(), buf))
    assert_equal(String(StringSpan(unsafe_from_utf8=buf)),
                 String("has ä"))


# --- search primitives -----------------------------------------------------


def test_find_ci_matches_the_reference_implementation() raises:
    var haystacks = List[String]()
    haystacks.append(String(""))
    haystacks.append(String("a"))
    haystacks.append(String("Selection"))
    haystacks.append(String("the SelectionHistory here"))
    haystacks.append(String("aaaaab"))
    haystacks.append(String("Godkänn SELECTION änd more"))
    haystacks.append(String("x") * 100 + String("Needle") + String("y") * 100)
    var needles = List[String]()
    needles.append(String(""))
    needles.append(String("a"))
    needles.append(String("A"))
    needles.append(String("selection"))
    needles.append(String("SELECTION"))
    needles.append(String("needle"))
    needles.append(String("aab"))
    needles.append(String("zzz"))
    needles.append(String("änd"))
    for h in range(len(haystacks)):
        for n in range(len(needles)):
            for start in range(0, 4):
                var got = find_ci(haystacks[h], needles[n], start)
                var want = _ref_find_ci(haystacks[h], needles[n], start)
                assert_equal(got, want)


def test_fold_and_search_cross_simd_lane_boundary() raises:
    """A match must be found at every offset, especially the ones that
    straddle the 32-byte lane the SIMD prefilter works in. The needle's
    first and last byte land in different lanes for some of these, which
    is exactly what the two-ended prefilter has to handle."""
    var needle = String("MARKER")
    var folded = fold_ascii(needle)
    for offset in range(0, 70):
        var hay = String("-") * offset + needle + String("-") * 40
        assert_equal(find_ci(hay, needle, 0), offset)
        assert_equal(find_ci(hay, String("marker"), 0), offset)
        assert_equal(
            find_folded(hay.as_bytes(), folded.as_bytes(), 0), offset,
        )
        # ``start`` past the hit must not find it.
        assert_equal(find_ci(hay, needle, offset + 1), -1)
    # Single-byte needle (first byte == last byte in the prefilter).
    for offset in range(0, 70):
        var hay = String("-") * offset + String("Q") + String("-") * 40
        assert_equal(find_ci(hay, String("q"), 0), offset)


def test_scan_folded_reports_non_ascii_even_after_a_hit() raises:
    """``scan_folded`` deliberately keeps scanning past the match so its
    ``ascii_only`` verdict covers the whole region. If it stopped at the
    hit, a non-ASCII byte *after* the match would go unnoticed — and a
    real Unicode fold could have matched something starting earlier, so
    the hit we found would be the wrong answer."""
    var needle = fold_ascii(String("hit"))
    var clean = String("aa HIT bb")
    var s1 = scan_folded(clean.as_bytes(), needle.as_bytes(), 0)
    assert_equal(s1.at, 3)
    assert_true(s1.ascii_only)
    # Non-ASCII *after* the hit still has to flip the verdict.
    var trailing = String("aa HIT bb ä")
    var s2 = scan_folded(trailing.as_bytes(), needle.as_bytes(), 0)
    assert_equal(s2.at, 3)
    assert_false(s2.ascii_only)
    # ...including when it sits in the final ``n - 1`` bytes, which can't
    # start a match and so are never visited as candidate positions.
    var tail = String("aa HIT bbbä")
    var s3 = scan_folded(tail.as_bytes(), needle.as_bytes(), 0)
    assert_false(s3.ascii_only)
    # Non-ASCII *before* ``start`` cannot affect a literal match.
    var before = String("ä aa HIT")
    var s4 = scan_folded(before.as_bytes(), needle.as_bytes(), 3)
    assert_equal(s4.at, 6)
    assert_true(s4.ascii_only)
    # No match, and the verdict still covers the whole region.
    var s5 = scan_folded(String("nothing").as_bytes(), needle.as_bytes(), 0)
    assert_equal(s5.at, -1)
    assert_true(s5.ascii_only)
    # Needle longer than what's left, and start past the end.
    var s6 = scan_folded(String("hä").as_bytes(), needle.as_bytes(), 0)
    assert_equal(s6.at, -1)
    assert_false(s6.ascii_only)
    var s7 = scan_folded(String("hit").as_bytes(), needle.as_bytes(), 99)
    assert_equal(s7.at, -1)
    # And it agrees with the plain early-exiting search on ASCII input.
    for offset in range(0, 70):
        var hay = String("-") * offset + String("HIT") + String("-") * 40
        var sc = scan_folded(hay.as_bytes(), needle.as_bytes(), 0)
        assert_equal(sc.at, offset)
        assert_true(sc.ascii_only)
        assert_equal(sc.at, find_folded(hay.as_bytes(), needle.as_bytes(), 0))


def test_find_exact_is_case_sensitive() raises:
    assert_equal(find_exact(String("xxYYzz").as_bytes(),
                            String("YY").as_bytes(), 0), 2)
    assert_equal(find_exact(String("xxYYzz").as_bytes(),
                            String("yy").as_bytes(), 0), -1)
    # Needle longer than the haystack, and start past the end.
    assert_equal(find_exact(String("ab").as_bytes(),
                            String("abc").as_bytes(), 0), -1)
    assert_equal(find_exact(String("ab").as_bytes(),
                            String("a").as_bytes(), 5), -1)


def test_eq_ci_and_starts_with_ci_agree_with_reference() raises:
    var pairs = List[String]()
    pairs.append(String(""))
    pairs.append(String("a"))
    pairs.append(String("A"))
    pairs.append(String("Project"))
    pairs.append(String("project"))
    pairs.append(String("projecT"))
    pairs.append(String("projects"))
    pairs.append(String("Godkänn"))
    pairs.append(String("godkänn"))
    # 40+ bytes so the SIMD lane loop runs, plus a one-byte difference
    # in the scalar tail.
    pairs.append(String("The_Quick_Brown_Fox_Jumps_Over_The_Lazy_Dog"))
    pairs.append(String("the_quick_brown_fox_jumps_over_the_lazy_dog"))
    pairs.append(String("the_quick_brown_fox_jumps_over_the_lazy_doh"))
    for i in range(len(pairs)):
        for j in range(len(pairs)):
            assert_equal(
                eq_ci(pairs[i], pairs[j]),
                _ref_fold(pairs[i]) == _ref_fold(pairs[j]),
            )
            var a = pairs[i]
            var b = pairs[j]
            var want = len(b.as_bytes()) <= len(a.as_bytes())
            if want:
                var head = String(StringSpan(
                    unsafe_from_utf8=a.as_bytes()[0:len(b.as_bytes())]
                ))
                want = _ref_fold(head) == _ref_fold(b)
            assert_equal(starts_with_ci(a, b), want)
    assert_true(contains_ci(String("xxYYzz"), String("yy")))
    assert_false(contains_ci(String("xxYYzz"), String("ya")))


# --- LineSearcher parity ---------------------------------------------------


def _libonig_spans(pattern: String, line: String) raises -> List[Int]:
    """Every ``(start, end)`` libonig reports for ``pattern`` in ``line``,
    flattened. The oracle for the fast path."""
    var out = List[Int]()
    var rx = OnigRegex(pattern)
    var pos = 0
    var n = len(line.as_bytes())
    while pos <= n:
        var m = rx.search_at(line, pos)
        if not m:
            break
        var mv = m.value().copy()
        if mv.start < 0 or mv.end < mv.start:
            break
        out.append(mv.start)
        out.append(mv.end)
        pos = mv.end if mv.end > mv.start else mv.start + 1
    return out^


def _searcher_spans(
    searcher: LineSearcher, line: String,
) -> List[Int]:
    var out = List[Int]()
    var pos = 0
    var n = len(line.as_bytes())
    while pos <= n:
        var m = searcher.search(line, pos)
        if not m:
            break
        var mv = m.value()
        out.append(mv.start)
        out.append(mv.end)
        pos = mv.end if mv.end > mv.start else mv.start + 1
    return out^


def test_line_searcher_matches_libonig_exactly() raises:
    """The whole point of the fast path: on every line it accepts, it
    must report the same spans libonig's ``(?i)`` would. Lines with
    non-ASCII bytes are the interesting ones — those must fall through to
    the regex so ``Ä``/``ä`` folding still happens."""
    onig_global_init()
    var lines = List[String]()
    lines.append(String(""))
    lines.append(String("selection"))
    lines.append(String("SELECTION"))
    lines.append(String("var Selection = selection + SELECTION"))
    lines.append(String("no hit on this line at all"))
    lines.append(String("selectionselection"))
    lines.append(String("Godkänn — SELECTION with non-ASCII"))
    lines.append(String("ÄÖÜ selection äöü SELECTION"))
    lines.append(String("x") * 50 + String("Selection") + String("y") * 50)
    lines.append(String("emoji 🔥 SELECTION 🔥 tail"))
    var needles = List[String]()
    needles.append(String("selection"))
    needles.append(String("SELECTION"))
    needles.append(String("Selection"))
    needles.append(String("s"))
    needles.append(String("zzz"))
    for n in range(len(needles)):
        var searcher = LineSearcher(
            needles[n], SearchOptions(False, False, False),
        )
        for i in range(len(lines)):
            var got = _searcher_spans(searcher, lines[i])
            var want = _libonig_spans(
                String("(?i)") + needles[n], lines[i],
            )
            assert_equal(len(got), len(want))
            for k in range(len(got)):
                assert_equal(got[k], want[k])


def test_line_searcher_honors_case_sensitive_and_word_and_regex() raises:
    onig_global_init()
    var line = String("Selection selection selections")
    # Cc on: literal, case-sensitive, no regex needed at all.
    var cs = LineSearcher(String("selection"), SearchOptions(True, False, False))
    var cs_spans = _searcher_spans(cs, line)
    assert_equal(len(cs_spans), 4)          # two lowercase hits
    assert_equal(cs_spans[0], 10)
    assert_equal(cs_spans[2], 20)
    # Whole word: "selections" must not match.
    var ww = LineSearcher(String("selection"), SearchOptions(True, True, False))
    var ww_spans = _searcher_spans(ww, line)
    assert_equal(len(ww_spans), 2)
    assert_equal(ww_spans[0], 10)
    # Regex mode.
    var rx = LineSearcher(String("sel[a-z]+n"), SearchOptions(True, False, True))
    assert_true(len(_searcher_spans(rx, line)) > 0)
    # An unparseable regex is "no matches", not a crash.
    var bad = LineSearcher(String("(unclosed"), SearchOptions(True, False, True))
    assert_false(bad.usable())
    assert_false(Bool(bad.search(line, 0)))


def test_searcher_cache_reuses_the_compiled_regex() raises:
    """Repeating a search must not recompile its regex.

    A compiled ``OnigRegex`` is never freed — its libonig handles live
    until the process exits (see the ``OnigRegex`` doc comment) — so a
    recompile per F3 is a leak, not just wasted work. The identity check
    is on the raw ``regex_t*``: same needle and toggles must hand back
    the very same handle, a changed needle must not.
    """
    onig_global_init()
    var opts = SearchOptions(False, False, False)   # case-insensitive
    var cache = SearcherCache()
    var first = cache.get(String("selection"), opts)
    assert_true(Bool(first.rx))
    var reg = first.rx.value()._reg
    for _ in range(5):
        var again = cache.get(String("selection"), opts)
        assert_equal(again.rx.value()._reg, reg)
    # A different needle is a miss, and so is the same needle under
    # different toggles.
    var other = cache.get(String("other"), opts)
    assert_true(other.rx.value()._reg != reg)
    var reworded = cache.get(String("other"), SearchOptions(False, True, False))
    assert_true(reworded.rx.value()._reg != other.rx.value()._reg)


def test_searcher_matches_whole_drives_the_replace_button() raises:
    """``matches_whole`` is what Replace asks before replacing the
    selection: true only for a match anchored at 0 that consumes every
    byte, under whichever toggles are live."""
    onig_global_init()
    var ci = LineSearcher(String("selection"), SearchOptions(False, False, False))
    assert_true(ci.matches_whole(String("SELECTION")))
    assert_false(ci.matches_whole(String("selections")))
    assert_false(ci.matches_whole(String("")))
    var cs = LineSearcher(String("selection"), SearchOptions(True, False, False))
    assert_true(cs.matches_whole(String("selection")))
    assert_false(cs.matches_whole(String("SELECTION")))
    var rx = LineSearcher(String("sel[a-z]+n"), SearchOptions(True, False, True))
    assert_true(rx.matches_whole(String("selection")))
    assert_false(rx.matches_whole(String("selection ")))


def test_line_searcher_non_ascii_needle_uses_regex() raises:
    """A needle with non-ASCII bytes can't take the ASCII-fold fast path
    — the fold wouldn't relate ``Ä`` to ``ä`` — so it must route to
    libonig and still match case-insensitively."""
    onig_global_init()
    var searcher = LineSearcher(
        String("godkänn"), SearchOptions(False, False, False),
    )
    assert_false(searcher.fast)
    var spans = _searcher_spans(searcher, String("Godkänn once"))
    assert_equal(len(spans), 2)
    assert_equal(spans[0], 0)


def test_line_searcher_rsearch_finds_rightmost_before_limit() raises:
    onig_global_init()
    var line = String("ab-AB-ab-AB")
    var searcher = LineSearcher(
        String("ab"), SearchOptions(False, False, False),
    )
    var last = searcher.rsearch(line, 99)
    assert_true(Bool(last))
    assert_equal(last.value().start, 9)
    var mid = searcher.rsearch(line, 5)
    assert_true(Bool(mid))
    assert_equal(mid.value().start, 3)
    var first = searcher.rsearch(line, 0)
    assert_true(Bool(first))
    assert_equal(first.value().start, 0)
    assert_false(Bool(searcher.rsearch(line, -1)))


# --- editor find / replace -------------------------------------------------


def test_editor_find_is_case_insensitive_by_default() raises:
    onig_global_init()
    var ed = Editor(String(
        "alpha BETA gamma\nBeta again\nlast line"
    ))
    ed.move_to(0, 0, False)
    assert_true(ed.find_next(String("beta")))
    assert_equal(ed.selections[0].anchor_row, 0)
    assert_equal(ed.selections[0].anchor_col, 6)
    assert_equal(ed.selections[0].col, 10)
    assert_true(ed.find_next(String("beta")))
    assert_equal(ed.selections[0].anchor_row, 1)
    assert_equal(ed.selections[0].anchor_col, 0)
    # Wraps back to the first hit.
    assert_true(ed.find_next(String("beta")))
    assert_equal(ed.selections[0].anchor_row, 0)
    assert_false(ed.find_next(String("nowhere")))


def test_editor_find_prev_walks_backwards() raises:
    onig_global_init()
    var ed = Editor(String(
        "one HIT two hit\nthree Hit four\nfive"
    ))
    ed.move_to(2, 4, False)
    assert_true(ed.find_prev(String("hit")))
    assert_equal(ed.selections[0].anchor_row, 1)
    assert_equal(ed.selections[0].anchor_col, 6)
    assert_true(ed.find_prev(String("hit")))
    assert_equal(ed.selections[0].anchor_row, 0)
    assert_equal(ed.selections[0].anchor_col, 12)
    assert_true(ed.find_prev(String("hit")))
    assert_equal(ed.selections[0].anchor_row, 0)
    assert_equal(ed.selections[0].anchor_col, 4)


def test_editor_find_on_non_ascii_line_still_folds_unicode() raises:
    """The line-level gate has to keep libonig's Unicode folding for
    lines it can't handle: the fast path never sees this line, so
    ``Ä`` still matches ``ä``."""
    onig_global_init()
    var ed = Editor(String("prefix GODKÄNN suffix"))
    ed.move_to(0, 0, False)
    assert_true(ed.find_next(String("godkänn")))
    assert_equal(ed.selections[0].anchor_col, 7)


def test_editor_replace_all_case_insensitive_and_offsets() raises:
    onig_global_init()
    var ed = Editor(String(
        "Foo foo FOO\nbar\nfoo — Foo"
    ))
    var n = ed.replace_all(String("foo"), String("X"))
    assert_equal(n, 5)
    assert_equal(ed.buffer.line(0), String("X X X"))
    assert_equal(ed.buffer.line(1), String("bar"))
    # The em-dash line goes through libonig; byte offsets must still be
    # right on both sides of the multi-byte character.
    assert_equal(ed.buffer.line(2), String("X — X"))
    assert_true(ed.dirty)
    # A replace that finds nothing must not report a change.
    var ed2 = Editor(String("nothing here"))
    assert_equal(ed2.replace_all(String("zzz"), String("y")), 0)
    assert_false(ed2.dirty)


def test_editor_replace_all_case_sensitive_only_hits_exact() raises:
    onig_global_init()
    var ed = Editor(String("Foo foo FOO"))
    var n = ed.replace_all(
        String("foo"), String("X"), SearchOptions(True, False, False),
    )
    assert_equal(n, 1)
    assert_equal(ed.buffer.line(0), String("Foo X FOO"))


# --- project find / replace ------------------------------------------------


def test_project_replace_preserves_line_endings() raises:
    """``_replace_by_line`` chunks the file at newlines and reassembles
    by concatenation, so CRLF, a missing final newline, and a trailing
    blank line all have to survive untouched."""
    onig_global_init()
    var root = _temp_path(String("case_fold_proj"))
    _rm_rf(root)
    _ensure_dir(root)
    assert_true(write_file(
        root + String("/crlf.txt"),
        String("first FOO line\r\nsecond foo line\r\n"),
    ))
    assert_true(write_file(
        root + String("/no_eol.txt"), String("only Foo here"),
    ))
    assert_true(write_file(
        root + String("/blank_tail.txt"), String("foo\n\n"),
    ))
    assert_true(write_file(
        root + String("/nonascii.txt"),
        String("ä FOO ä\nplain foo\n"),
    ))
    var summary = replace_in_project(root, String("foo"), String("BAR"))
    assert_equal(summary[0], 4)          # files changed
    assert_equal(summary[1], 6)          # replacements
    assert_equal(read_file(root + String("/crlf.txt")),
                 String("first BAR line\r\nsecond BAR line\r\n"))
    assert_equal(read_file(root + String("/no_eol.txt")),
                 String("only BAR here"))
    assert_equal(read_file(root + String("/blank_tail.txt")),
                 String("BAR\n\n"))
    assert_equal(read_file(root + String("/nonascii.txt")),
                 String("ä BAR ä\nplain BAR\n"))
    _rm_rf(root)


def test_project_find_reports_case_insensitive_hits() raises:
    onig_global_init()
    var root = _temp_path(String("case_fold_find"))
    _rm_rf(root)
    _ensure_dir(root)
    assert_true(write_file(
        root + String("/a.txt"),
        String("nope\nhas NEEDLE here\nnope again\nneedle twice needle\n"),
    ))
    var hits = find_in_project(root, String("needle"))
    assert_equal(len(hits), 2)
    assert_equal(hits[0].line_no, 2)
    assert_equal(hits[1].line_no, 4)
    # Cc on: only the exact-case line.
    var cs = find_in_project(
        root, String("needle"), SearchOptions(True, False, False),
    )
    assert_equal(len(cs), 1)
    assert_equal(cs[0].line_no, 4)
    _rm_rf(root)


# --- quick open ------------------------------------------------------------


def test_quick_open_match_parts_matches_the_unhoisted_form() raises:
    """``split_query_parts`` + ``quick_open_match_parts`` is what the
    per-keystroke filter calls now; it must agree with the original
    single-shot ``quick_open_match`` on every input."""
    var paths = List[String]()
    paths.append(String("src/turbokod/cell.mojo"))
    paths.append(String("src/turbokod/Case_Fold.mojo"))
    paths.append(String("myapp/homepage/cms/migrations/0003_snippet.py"))
    paths.append(String(""))
    paths.append(String("README.md"))
    var queries = List[String]()
    queries.append(String(""))
    queries.append(String("k/c"))
    queries.append(String("k c"))
    queries.append(String("km/"))
    queries.append(String("CASE"))
    queries.append(String("case_fold"))
    queries.append(String("pro/views"))
    queries.append(String("  "))
    for p in range(len(paths)):
        for q in range(len(queries)):
            var parts = split_query_parts(queries[q])
            assert_equal(
                quick_open_match_parts(paths[p], parts),
                quick_open_match(paths[p], queries[q]),
            )
    # Spot-check the documented examples.
    var path = String("src/turbokod/cell.mojo")
    assert_true(quick_open_match(path, String("k/c")))
    assert_true(quick_open_match(path, String("k c")))
    assert_false(quick_open_match(path, String("km/")))


def main() raises:
    setup_test_env()
    test_fold_byte_covers_exactly_the_ascii_upper_range()
    test_fold_leaves_utf8_intact_and_length_unchanged()
    test_is_ascii_scans_the_whole_buffer()
    test_fold_ascii_into_reports_ascii_purity()
    test_find_ci_matches_the_reference_implementation()
    test_fold_and_search_cross_simd_lane_boundary()
    test_scan_folded_reports_non_ascii_even_after_a_hit()
    test_find_exact_is_case_sensitive()
    test_eq_ci_and_starts_with_ci_agree_with_reference()
    test_line_searcher_matches_libonig_exactly()
    test_line_searcher_honors_case_sensitive_and_word_and_regex()
    test_line_searcher_non_ascii_needle_uses_regex()
    test_searcher_cache_reuses_the_compiled_regex()
    test_searcher_matches_whole_drives_the_replace_button()
    test_line_searcher_rsearch_finds_rightmost_before_limit()
    test_editor_find_is_case_insensitive_by_default()
    test_editor_find_prev_walks_backwards()
    test_editor_find_on_non_ascii_line_still_folds_unicode()
    test_editor_replace_all_case_insensitive_and_offsets()
    test_editor_replace_all_case_sensitive_only_hits_exact()
    test_project_replace_preserves_line_endings()
    test_project_find_reports_case_insensitive_hits()
    test_quick_open_match_parts_matches_the_unhoisted_form()
    print("case_fold: 23 tests passed")
