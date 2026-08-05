"""Shared search-mode flags: case sensitive, whole word, regex.

Used by the in-file Find/Replace flow (``editor.find_next``,
``editor.find_prev``, ``editor.replace_all``) and the project-wide
search (``project_find.ProjectFind`` and ``project.find_in_project`` /
``project.replace_in_project``). The values map directly onto the
three toggle buttons on the Find prompt and the Find-in-Project
dialog (``Cc`` / ``W`` / ``.*``).

Default-constructed ``SearchOptions`` is "no flags" — case-sensitive,
literal substring match, no word boundary — which preserves the
behavior the codebase had before toggles existed.

``LineSearcher`` is the matcher every find/replace site goes through.
It picks between a branchless SIMD byte scan and libonig per *line*,
which is what lets the common case (a literal ASCII needle) skip the
regex engine without giving up libonig's Unicode case folding on the
lines that actually need it.
"""

from std.collections.optional import Optional

from .case_fold import find_exact, fold_ascii, is_ascii, scan_folded
from .onig import OnigRegex


struct SearchOptions(ImplicitlyCopyable, Movable):
    var case_sensitive: Bool
    var whole_word: Bool
    var regex: Bool

    def __init__(out self):
        self.case_sensitive = False
        self.whole_word = False
        self.regex = False

    def __init__(
        out self, case_sensitive: Bool, whole_word: Bool, regex: Bool,
    ):
        self.case_sensitive = case_sensitive
        self.whole_word = whole_word
        self.regex = regex

    def __copyinit__(mut self, copy: Self):
        self.case_sensitive = copy.case_sensitive
        self.whole_word = copy.whole_word
        self.regex = copy.regex

    def any_set(self) -> Bool:
        return self.case_sensitive or self.whole_word or self.regex


def default_search_options() -> SearchOptions:
    """Factory for the all-flags-off default. Used as the default
    argument value for ``find_next`` / ``find_prev`` / ``replace_all``
    and the project-wide variants so callers that don't care about
    toggles keep the literal, case-sensitive substring behavior the
    codebase had before search options existed."""
    return SearchOptions()


def regex_escape_literal(needle: String) -> String:
    """Escape ``needle`` so libonig treats every byte as literal. Used
    when the user has opted into whole-word or case-insensitive but
    *not* regex — we still need a regex to express the boundary or
    ``(?i)`` flag, so the literal needle is escaped first."""
    var out = String("")
    var b = needle.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        # Conservative set: every metachar libonig recognizes in the
        # default syntax, plus a backslash for the escape itself.
        if c == 0x5C or c == 0x5E or c == 0x24 or c == 0x2E \
                or c == 0x7C or c == 0x3F or c == 0x2A or c == 0x2B \
                or c == 0x28 or c == 0x29 or c == 0x5B or c == 0x5D \
                or c == 0x7B or c == 0x7D:
            out = out + String("\\")
        var ch = chr(c) if c < 0x80 else String(StringSlice(
            unsafe_from_utf8=b[i:i + 1],
        ))
        out = out + ch
    return out


def build_search_regex(
    needle: String, opts: SearchOptions,
) -> Optional[OnigRegex]:
    """Compile ``needle`` into a regex honoring ``opts`` flags, or
    return None when the byte-match fast path is sufficient. The
    fast path is reserved for ``case_sensitive=True`` + literal
    needle (W off, .* off): a plain case-sensitive substring scan.
    Every other configuration — including the all-off default
    (Cc off → case-insensitive) — funnels through libonig.

    Whole-word is implemented as ``\\b(?:...)\\b``. Case-insensitive
    via the ``(?i)`` modifier. Regex mode uses the user's pattern
    verbatim; literal mode escapes regex metacharacters first.
    Returns None for an unparseable pattern as well — callers should
    treat that the same as "no match" rather than crashing."""
    if opts.case_sensitive and not opts.whole_word and not opts.regex:
        return Optional[OnigRegex]()
    var pat: String
    if opts.regex:
        pat = needle
    else:
        pat = regex_escape_literal(needle)
    if opts.whole_word:
        pat = String("\\b(?:") + pat + String(")\\b")
    if not opts.case_sensitive:
        pat = String("(?i)") + pat
    try:
        return Optional[OnigRegex](OnigRegex(pat))
    except:
        return Optional[OnigRegex]()


comptime _NO_FAST_PATH: Int = -2
"""``LineSearcher._fast_find`` sentinel: this line needs libonig. Distinct
from ``-1``, which means the SIMD scan ran and found nothing."""


@fieldwise_init
struct MatchSpan(ImplicitlyCopyable, Movable):
    """Half-open ``[start, end)`` byte offsets of one match within a
    line. The same shape as ``OnigMatch``'s group 0, minus the group
    bookkeeping no find/replace caller uses."""
    var start: Int
    var end: Int


struct LineSearcher(ImplicitlyCopyable, Movable):
    """Matches one needle against one line at a time, under ``opts``.

    Every find/replace path in the editor and in project-wide search
    goes through this, and it exists to answer one question per line:
    *can this line be matched with a branchless SIMD byte scan, or does
    it need libonig?*

    The literal fast path (``case_fold.scan_folded`` / ``find_exact`` —
    a two-ended SIMD prefilter that folds the haystack in register)
    applies when the search is a plain substring search
    (no ``W``, no ``.*``) **and** either the search is case-sensitive,
    or both the needle and the line are pure ASCII. That last clause is
    the interesting one: an ASCII-only fold cannot reproduce libonig's
    Unicode case folding (``Ä``/``ä``, or ``ſ``->``s``), so a line
    carrying any non-ASCII byte falls back to the ``(?i)`` regex and
    keeps today's behavior exactly. Since the gate is per line rather
    than per file, one em dash in a comment costs one slow line instead
    of a slow file — see ``case_fold``'s "don't stop early" note, which
    is the same lesson one level up.

    Measured over a 1.7 MB corpus of real source, line by line
    (``bench/fold_bench.mojo``): the old per-line ``(?i)`` walk ran at
    ~270 MiB/s, this at ~1.1 GiB/s case-insensitive and ~3 GiB/s with
    Cc on (where no ASCII check is needed at all). At a typical ~46-byte
    line the remaining cost is per-call overhead, not bytes — the same
    scan over one flat blob hits 16 GiB/s. Line granularity is what buys
    the per-line libonig fallback and the result line numbers, and it is
    the reason this stops at ~4x rather than ~50x.

    ``fast`` and ``rx`` are not exclusive — a case-insensitive literal
    search sets both and decides per line. A case-sensitive literal
    search needs no regex at all (``rx`` is None), and regex / whole-word
    modes have no fast path (``fast`` is False)."""

    var needle: String
    """The needle, ASCII-folded when the search is case-insensitive.
    Folded once here, never per line or per candidate."""
    var fast: Bool
    var ci: Bool
    var rx: Optional[OnigRegex]

    def __init__(out self, needle: String, opts: SearchOptions):
        self.rx = build_search_regex(needle, opts)
        self.ci = not opts.case_sensitive
        var nb = needle.as_bytes()
        self.fast = (
            len(nb) > 0
            and not opts.regex
            and not opts.whole_word
            and (opts.case_sensitive or is_ascii(nb))
        )
        self.needle = fold_ascii(needle) if self.ci else needle

    def usable(self) -> Bool:
        """False when this searcher can never match — an empty needle,
        or a regex the user typed that libonig refused to compile.
        Callers treat it as "no matches" rather than erroring."""
        return self.fast or Bool(self.rx)

    def _fast_find(self, lb: Span[UInt8, _], start: Int) -> Int:
        """Fast-path result: a byte offset, ``-1`` for "no match here",
        or ``_NO_FAST_PATH`` when this line has to go to libonig.

        The case-insensitive branch gets its match and its "was this line
        pure ASCII?" verdict from a single pass (``scan_folded``) — asking
        ``is_ascii`` first and then searching reads every line twice."""
        if not self.fast:
            return _NO_FAST_PATH
        if not self.ci:
            return find_exact(lb, self.needle.as_bytes(), start)
        var scan = scan_folded(lb, self.needle.as_bytes(), start)
        if not scan.ascii_only:
            return _NO_FAST_PATH
        return scan.at

    def _span_of(self, at: Int) -> Optional[MatchSpan]:
        if at < 0:
            return Optional[MatchSpan]()
        return Optional[MatchSpan](
            MatchSpan(at, at + len(self.needle.as_bytes()))
        )

    def _regex_span(self, line: String, start: Int) -> Optional[MatchSpan]:
        if not self.rx:
            return Optional[MatchSpan]()
        var m = self.rx.value().search_at(line, start)
        if not m:
            return Optional[MatchSpan]()
        var mv = m.value().copy()
        if mv.start < 0 or mv.end < mv.start:
            return Optional[MatchSpan]()
        return Optional[MatchSpan](MatchSpan(mv.start, mv.end))

    def search(self, line: String, start: Int) -> Optional[MatchSpan]:
        """First match at or after byte offset ``start``, or None."""
        if start > len(line.as_bytes()):
            return Optional[MatchSpan]()
        var at = self._fast_find(line.as_bytes(), start)
        if at != _NO_FAST_PATH:
            return self._span_of(at)
        return self._regex_span(line, start)

    def search_span(self, lb: Span[UInt8, _], start: Int) -> Optional[MatchSpan]:
        """``search`` for callers that already hold bytes — a line range
        inside a file buffer, say. Only the libonig fallback materializes
        a ``String``, so a whole-file walk allocates nothing per line on
        the fast path. ``lb`` must start and end on UTF-8 boundaries."""
        if start > len(lb):
            return Optional[MatchSpan]()
        var at = self._fast_find(lb, start)
        if at != _NO_FAST_PATH:
            return self._span_of(at)
        if not self.rx:
            return Optional[MatchSpan]()
        return self._regex_span(String(StringSlice(unsafe_from_utf8=lb)), start)

    def rsearch(self, line: String, limit: Int) -> Optional[MatchSpan]:
        """Last match whose start is <= ``limit``, or None. Neither
        libonig nor the SIMD scan has a reverse search, so both walk
        forward keeping the right-most hit."""
        if limit < 0:
            return Optional[MatchSpan]()
        var best = Optional[MatchSpan]()
        var pos = 0
        var n = len(line.as_bytes())
        while pos <= n:
            var m = self.search(line, pos)
            if not m:
                break
            var mv = m.value()
            if mv.start > limit:
                break
            best = Optional[MatchSpan](mv)
            # Zero-width matches (possible in regex mode only) still have
            # to advance or this loop never terminates.
            pos = mv.end if mv.end > mv.start else mv.start + 1
        return best^
