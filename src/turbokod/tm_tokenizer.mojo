"""TextMate tokenizer driven by a loaded ``Grammar``.

Walk one line at a time, maintaining a stack of open ``begin``/``end``
scopes across lines. The output is a ``HighlightList``, the same data the
existing pipeline already paints.

Match-policy — simplified from the full TextMate spec to what the
bundled Rust grammar actually exercises:

1. **Earliest match wins**, with pattern-list order as tiebreak. We
   probe every candidate (top-of-stack ``end`` plus the active
   ``patterns`` list) and pick the smallest start offset.
2. **Empty-match guard**: when the chosen match's end equals the
   probe position, advance by one byte so we don't loop on patterns
   that match the empty string.
3. **End-vs-begin priority**: when an ``end`` match and a ``begin``
   match start at the same offset, ``end`` wins. This is what makes
   ``"abc"`` close cleanly when its content matches a nested rule
   that *also* matches ``"``.

Skipped: capture-group → scope mapping, ``while``-rules,
embedded-grammar includes, injections.

The scope chain is mapped to a single ``Attr`` via prefix matching
in ``_attr_for_scopes``: the tokenizer concatenates the open-frame
scopes with the matched pattern's scope and looks for a known
prefix. First hit wins.
"""

from std.collections.list import List
from std.collections.optional import Optional

from .colors import Attr
from .highlight import (
    Highlight, HighlightList,
    highlight_comment_attr, highlight_decorator_attr,
    highlight_ident_attr, highlight_keyword_attr,
    highlight_number_attr, highlight_operator_attr,
    highlight_string_attr,
)
from .onig import (
    OnigMatch, OnigRegex,
    ONIG_OPTION_NONE, ONIG_OPTION_NOT_BEGIN_POSITION,
)
from .search_options import regex_escape_literal
from .posix import monotonic_ms
from .string_utils import byte_slice
from .tm_grammar import (
    Capture, Grammar, Pattern,
    PATTERN_BEGIN_END, PATTERN_BEGIN_WHILE, PATTERN_GROUP,
    PATTERN_INCLUDE, PATTERN_MATCH,
)


# A stack frame: which pattern opened the scope, plus the resolved
# scope-chain string we'll append to when emitting Highlights inside.
struct Frame(ImplicitlyCopyable, Movable):
    """One open ``begin``/``end`` scope.

    ``pattern_idx`` indexes ``Grammar.patterns``; the tokenizer
    re-reads name/content_name/end_regex on demand rather than
    caching them in the frame, which keeps the frame tiny and
    obviates a cascade of __copyinit__ overrides.

    Public so ``HighlightCache`` can store per-line stack snapshots
    for incremental tokenization. ``frame_eq`` / ``stack_eq`` give
    the equality the early-exit logic needs without making us
    derive ``Eq`` on the trait list.
    """
    var pattern_idx: Int
    var scope_chain: String
    # Begin-match capture groups, populated only when the opening
    # pattern's end regex back-references them
    # (``Pattern.end_has_backref``) — empty for the overwhelming common
    # case, so it costs nothing then. Stored *packed* (length-prefixed,
    # see ``_pack_groups``) rather than as a ``List[String]`` so every
    # field stays ``ImplicitlyCopyable`` and the frame keeps its cheap
    # synthesized copy. Part of frame equality (the packed string
    # compares directly): two frames opened by the same pattern but
    # capturing different text (``<div>`` vs ``<span>``) have different
    # end regexes, so the incremental early-exit must keep them distinct.
    var begin_groups: String

    def __init__(
        out self, pattern_idx: Int, var scope_chain: String,
        var begin_groups: String = String(""),
    ):
        self.pattern_idx = pattern_idx
        self.scope_chain = scope_chain^
        self.begin_groups = begin_groups^


def frame_eq(a: Frame, b: Frame) -> Bool:
    return a.pattern_idx == b.pattern_idx \
        and a.scope_chain == b.scope_chain \
        and a.begin_groups == b.begin_groups


def stack_eq(a: List[Frame], b: List[Frame]) -> Bool:
    """Two scope stacks are equal iff they're the same depth and
    every frame matches. Used by the incremental tokenizer to
    detect "tokenizer state stabilized, the rest of the buffer
    can be left alone."
    """
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if not frame_eq(a[i], b[i]):
            return False
    return True


def copy_stack(s: List[Frame]) -> List[Frame]:
    var out = List[Frame]()
    for i in range(len(s)):
        out.append(s[i])
    return out^


struct StackTable(Copyable, Movable):
    """The distinct scope stacks of one buffer, so each line's end-of-line
    state is an index rather than a stack of its own. Consecutive lines
    nearly always end in the same state — a 20k-line file has a few dozen
    distinct stacks, not 20k."""
    var stacks: List[List[Frame]]

    def __init__(out self):
        self.stacks = List[List[Frame]]()

    def __copyinit__(mut self, copy: Self):
        self.stacks = List[List[Frame]]()
        for i in range(len(copy.stacks)):
            self.stacks.append(copy_stack(copy.stacks[i]))

    def intern(mut self, stack: List[Frame], hint: Int) -> Int:
        """The index of ``stack``, added if new. ``hint`` is the previous
        line's index (or -1), tried first: it is almost always the one."""
        if hint >= 0 and hint < len(self.stacks) \
                and stack_eq(stack, self.stacks[hint]):
            return hint
        for i in range(len(self.stacks)):
            if stack_eq(stack, self.stacks[i]):
                return i
        self.stacks.append(copy_stack(stack))
        return len(self.stacks) - 1


@fieldwise_init
struct _Cand(ImplicitlyCopyable, Movable):
    """One pattern under test at the current probe position.

    ``pattern_idx`` is the source pattern (a MATCH or BEGIN_END).
    ``regex_idx`` is which regex to fire — for BEGIN_END this is the
    *begin* regex; the end regex case is encoded with the special
    sentinel ``-1`` for ``pattern_idx`` and the frame's end regex
    placed in ``regex_idx``.
    """
    var pattern_idx: Int
    var regex_idx: Int
    var anchored: Bool
    """The regex mentions ``\\G`` (``Grammar.regex_has_g``): what it
    matches depends on ``ONIG_OPTION_NOT_BEGIN_POSITION``, so a cached
    result for it doesn't survive that option changing."""


struct _CandidateMemo(Movable):
    """The candidate list for each stack top met during one tokenize
    call. A list depends only on the grammar and the top frame's pattern,
    and building one follows every ``include`` under it — for a C or Go
    file that expansion, redone at each scope change, was a seventh of
    the whole pass."""
    var tops: List[Int]
    var lists: List[List[_Cand]]

    def __init__(out self):
        self.tops = List[Int]()
        self.lists = List[List[_Cand]]()

    def slot(mut self, grammar: Grammar, top_pattern: Int) -> Int:
        """Index in ``lists`` of the candidates under ``top_pattern``
        (-1: the empty stack), built on first use."""
        for i in range(len(self.tops)):
            if self.tops[i] == top_pattern:
                return i
        self.tops.append(top_pattern)
        self.lists.append(_candidates_under(grammar, top_pattern))
        return len(self.tops) - 1


def tokenize_with_grammar(
    grammar: Grammar, lines: List[String],
) -> HighlightList:
    """Run the tokenizer over an entire buffer. The scope stack is
    threaded line-to-line, which is what makes block comments and
    multi-line strings color correctly. Convenience wrapper around
    ``tokenize_with_grammar_full`` for callers that don't need
    the per-line stack snapshots."""
    var table = StackTable()
    var post_ids = List[Int32]()
    return tokenize_with_grammar_full(grammar, lines, table, post_ids)


def tokenize_with_grammar_full(
    grammar: Grammar, lines: List[String],
    mut table: StackTable, mut post_ids: List[Int32],
    size_hint: Int = 0,
) -> HighlightList:
    """As ``tokenize_with_grammar``, but also fills ``post_ids`` with
    the scope stack at the *end* of each line, as an index into ``table``
    (which is reset). After the call, ``table.stacks[post_ids[i]]`` is the
    state that line ``i+1`` would start in. Used by ``HighlightCache`` to
    support incremental re-runs that pick up from a known-good row
    instead of restarting at the top of the buffer.

    ``size_hint`` is how many highlights to make room for up front."""
    post_ids.clear()
    post_ids.reserve(len(lines))
    table.stacks.clear()
    var out = HighlightList(capacity=size_hint)
    var stack = List[Frame]()
    var memo = _CandidateMemo()
    var last = -1
    for row in range(len(lines)):
        var next_line = String("")
        if row + 1 < len(lines):
            next_line = lines[row + 1]
        _tokenize_line(grammar, lines[row], next_line, row, stack, out, memo)
        last = table.intern(stack, last)
        post_ids.append(Int32(last))
    return out^


def tokenize_lines_from(
    grammar: Grammar, lines: List[String],
    start_row: Int, start_stack: List[Frame],
    cached_post_ids: List[Int32],
    mut table: StackTable,
    mut post_ids: List[Int32],
    mut stable_row: Int,
    mut rejoined: Bool,
    need_row: Int = -1,
    deadline_ms: Int = 0,
    size_hint: Int = 0,
) -> HighlightList:
    """Tokenize ``lines`` from ``start_row``, starting in ``start_stack``,
    until one of three things:

    * **It rejoins the cached trajectory** — the new post-stack at a row
      equals ``cached_post_ids[row]``, so every row below that was
      tokenized from this same state and is still right. This is what
      makes an edit cost its own rows rather than the file's.
      ``rejoined`` is set and ``stable_row`` is the row after. A cached
      id of -1 marks a row whose cached result is void (its text changed,
      or it was never tokenized) and equals nothing, so the pass can't
      stop there.
    * **It has done enough for now** — only with ``need_row >= 0``: once
      that row is done and ``deadline_ms`` (``monotonic_ms``; 0 means at
      once) has passed. ``stable_row`` is the first row *not* tokenized,
      where a later call resumes. Opening a big file colors what's on
      screen in the first frame this way and the rest over the next ones.
    * **The end of the buffer**: ``stable_row == len(lines)``.

    ``post_ids`` gets the post-stack of each row tokenized, as an index
    into ``table`` — ``post_ids[k]`` is the stack at the end of row
    ``start_row + k``. The highlights returned are those rows'.
    ``size_hint`` is how many to make room for up front.
    """
    post_ids.clear()
    rejoined = False
    var out = HighlightList(capacity=size_hint)
    var stack = copy_stack(start_stack)
    var memo = _CandidateMemo()
    var row = start_row
    var last = -1
    while row < len(lines):
        var next_line = String("")
        if row + 1 < len(lines):
            next_line = lines[row + 1]
        _tokenize_line(grammar, lines[row], next_line, row, stack, out, memo)
        last = table.intern(stack, last)
        post_ids.append(Int32(last))
        if row < len(cached_post_ids) and last == Int(cached_post_ids[row]):
            rejoined = True
            stable_row = row + 1
            return out^
        # The clock is read every 32 rows: a row is a few microseconds.
        if need_row >= 0 and row >= need_row and row + 1 < len(lines) and (
            deadline_ms <= 0 or (
                ((row - start_row) & 31) == 31 and monotonic_ms() >= deadline_ms
            )
        ):
            stable_row = row + 1
            return out^
        row += 1
    stable_row = len(lines)
    return out^


def _tokenize_line(
    grammar: Grammar, line: String, next_line: String, row: Int,
    mut stack: List[Frame], mut out: HighlightList,
    mut memo: _CandidateMemo,
):
    """Tokenize one line, owning the line-local dynamic regexes.

    Thin wrapper over ``_tokenize_line_scan`` for one reason: the
    back-reference end regexes it compiles are the only regexes in the
    system built from *data* rather than from a grammar file, so nothing
    else can ever reclaim them — the ``Frame`` that outlives the line
    holds a pattern index, not a handle. The release therefore has to
    happen on every exit from the scan, and a scan that raised (every
    function here is ``def``, so any of them may) used to skip it and
    strand that line's handles for the life of the process.
    """
    var dyn_keys = List[String]()
    var dyn_regexes = List[OnigRegex]()
    try:
        _tokenize_line_scan(
            grammar, line, next_line, row, stack, out, memo,
            dyn_keys, dyn_regexes,
        )
    finally:
        for i in range(len(dyn_regexes)):
            dyn_regexes[i].release()


def _tokenize_line_scan(
    grammar: Grammar, line: String, next_line: String, row: Int,
    mut stack: List[Frame], mut out: HighlightList,
    mut memo: _CandidateMemo,
    mut dyn_keys: List[String], mut dyn_regexes: List[OnigRegex],
):
    var hb = line.as_bytes()
    var n = len(hb)
    var pos = 0
    # Where this row's highlights start in ``out``. The bracket post-pass
    # below (after the main tokenization loop) only inspects highlights
    # added in *this* call, so a previous row's highlights for the same
    # byte position can't accidentally suppress a paint here.
    var hl_start = len(out)
    # ``\\G`` anchor position. ``-1`` is a sentinel meaning "no
    # match has fired on this line yet"; libonig's ``\\G`` won't
    # match anywhere when we pass ``ONIG_OPTION_NOT_BEGIN_POSITION``,
    # which is what we want for ``(?!\\G)``-style transition begins
    # that gate on "we've moved past the start of the line." Once
    # any pattern matches, ``g_pos`` updates to that match's end
    # so subsequent searches with ``pos == g_pos`` allow ``\\G`` to
    # fire there.
    var g_pos: Int = -1

    # ``while``-rule prologue: at the start of each new line, every
    # ``BEGIN_WHILE`` frame on the top of the stack must have its
    # ``while`` regex match at the current position to stay open.
    # If it doesn't, the frame closes silently — no end-scope
    # highlight, no anything. We loop because nested while-frames
    # all need to be checked top-down. ``BEGIN_END`` frames in
    # between are left untouched (their lifetime isn't gated on
    # line starts).
    pos = _process_while_frames(grammar, line, row, stack, pos, out)
    if pos > 0:
        # The while-prefix counts as a real match for ``\\G`` purposes.
        g_pos = pos

    # The active candidate set depends only on the top frame's
    # ``pattern_idx`` (or the empty-stack root set), so it changes only
    # when the stack top does, and ``memo`` keeps each one built during
    # this tokenize call.
    var cands = List[_Cand]()
    var cands_top = -2  # sentinel: forces the first build (-1 == empty stack)
    # Dynamically recompiled end regexes for back-referencing ``end``
    # patterns (TextMate's ``end: "...\\2..."`` that targets a begin
    # capture). ``dyn_end`` is the top frame's substituted end regex, or
    # ``None`` when the top frame's end needs no substitution; it's
    # recomputed whenever the candidate set is rebuilt (i.e. when the
    # top frame changes). The keys/regexes lists cache compiles so a
    # line full of ``<td>..</td>`` rows doesn't recompile per cell.
    # ``dyn_keys`` / ``dyn_regexes`` are line-local but owned by the
    # caller, which releases them however this function exits — including
    # by raising (see ``_tokenize_line``).
    var dyn_end = Optional[OnigRegex]()
    # Per-candidate cached search result, reused across advancing positions
    # while the candidate set is unchanged. ``cached_start`` is the cached
    # match's start column, ``-1`` (no match in the rest of the line, valid
    # forever), or ``-2`` (unknown — must search). A cached match stays
    # valid while it's still at or ahead of ``pos``; once ``pos`` moves past
    # it we re-search. A ``\G``-anchored match has start == its search
    # start, so the "still ahead" test only reuses it at the identical
    # position. ``ONIG_OPTION_NOT_BEGIN_POSITION`` changes what ``\G`` can
    # match and nothing else, so when the option flips — it does on every
    # line, after the first match — only the ``anchored`` candidates'
    # results are dropped. (Dropping all of them searched every candidate
    # twice per line.)
    var cached_start = List[Int]()
    var cached_match = List[OnigMatch]()
    var cache_opts = ONIG_OPTION_NONE
    var cache_ready = False
    # The results of the candidate sets this line has left behind, by
    # ``memo`` slot. A set comes back whenever its scope does — after every
    # ``(...)`` or ``{...}`` that closes — and what its regexes found
    # further along the line still holds, so only the candidates that
    # depend on more than the text (``anchored`` ones, and the frame's own
    # end) are searched again. Starting each return from nothing made a
    # line cost its length times its scope changes: a second for one 9 KB
    # line of CSS.
    var cands_slot = -1
    var parked_slots = List[Int]()
    var parked_starts = List[List[Int]]()
    var parked_matches = List[List[OnigMatch]]()
    # Stuck guard: count consecutive iterations that don't advance ``pos``.
    # Zero-width begin pushes and zero-width end pops are legitimate
    # no-advance steps (bounded by grammar nesting depth), but a begin↔end
    # pair that both match zero-width at the same position would oscillate
    # forever. When the no-advance streak clearly exceeds any sane nesting
    # depth we force a one-byte step to guarantee progress.
    var stuck_pos = -1
    var stuck_iters = 0
    while pos < n:
        if pos == stuck_pos:
            stuck_iters += 1
        else:
            stuck_pos = pos
            stuck_iters = 0
        if stuck_iters > 2 * len(stack) + 16:
            # Pathological zero-width oscillation — step past this byte.
            pos += 1
            continue
        var cur_top = -1 if len(stack) == 0 \
            else stack[len(stack) - 1].pattern_idx
        if cur_top != cands_top:
            if cands_slot >= 0:
                parked_slots.append(cands_slot)
                parked_starts.append(cached_start^)
                parked_matches.append(cached_match^)
            cands_slot = memo.slot(grammar, cur_top)
            cands = memo.lists[cands_slot].copy()
            cands_top = cur_top
            # Recompute the top frame's substituted end regex (if its
            # end back-references begin captures). Empty stack or a
            # plain end leaves ``dyn_end`` cleared, so the loop below
            # uses the statically compiled regex.
            dyn_end = Optional[OnigRegex]()
            if len(stack) > 0:
                dyn_end = _dyn_end_regex(
                    grammar, stack[len(stack) - 1], dyn_keys, dyn_regexes,
                )
            var parked = -1
            for k in range(len(parked_slots)):
                if parked_slots[k] == cands_slot:
                    parked = k
                    break
            if parked >= 0:
                _ = parked_slots.pop(parked)
                cached_start = parked_starts.pop(parked)
                cached_match = parked_matches.pop(parked)
                for ci in range(len(cands)):
                    if cands[ci].anchored or cands[ci].pattern_idx < 0:
                        cached_start[ci] = -2
            else:
                cached_start = List[Int](length=len(cands), fill=-2)
                cached_match = List[OnigMatch](capacity=len(cands))
                for _ in range(len(cands)):
                    cached_match.append(
                        OnigMatch(-1, -1, List[Int](), List[Int]())
                    )
            cache_ready = False
        # Find the earliest match across all candidates. Among ties,
        # the candidate listed first in ``cands`` wins — this mirrors
        # TextMate's "first listed pattern" tie-break, with the
        # top-of-stack ``end`` deliberately placed at index 0 so
        # closing a scope wins ties against begins / matches.
        var search_options = ONIG_OPTION_NONE
        if pos != g_pos:
            search_options = ONIG_OPTION_NOT_BEGIN_POSITION
        if not cache_ready:
            cache_opts = search_options
            cache_ready = True
        elif search_options != cache_opts:
            for ci in range(len(cands)):
                if cands[ci].anchored:
                    cached_start[ci] = -2
            cache_opts = search_options
        var best_idx = -1
        var best_start = -1
        for ci in range(len(cands)):
            var cs = cached_start[ci]
            if cs == -2 or (cs >= 0 and cs < pos):
                # Unknown, or the cached match is now behind ``pos`` — search.
                # The end candidate (pattern_idx < 0) uses the top frame's
                # substituted end regex when one was built; everything else
                # (and a plain end) uses the statically compiled regex.
                var m_opt: Optional[OnigMatch]
                if cands[ci].pattern_idx < 0 and dyn_end:
                    m_opt = dyn_end.value().search_at(line, pos, search_options)
                else:
                    var rx = grammar.regex(cands[ci].regex_idx)
                    m_opt = rx.search_at(line, pos, search_options)
                if m_opt:
                    cached_match[ci] = m_opt.take()
                    cached_start[ci] = cached_match[ci].start
                else:
                    cached_start[ci] = -1  # no match in the rest of the line
                cs = cached_start[ci]
            # ``cs`` is now -1 (no match) or >= pos (match at/ahead of pos).
            if cs >= 0 and (best_idx < 0 or cs < best_start):
                best_idx = ci
                best_start = cs
        if best_idx < 0:
            # No match in the rest of the line — the body of an open
            # scope (or the unmatched tail outside any scope) just
            # gets the surrounding scope's content_name attr if any.
            _emit_unmatched(grammar, stack, line, row, pos, n, out)
            pos = n
            continue

        # Borrowed from the cache: nothing below replaces ``cached_match``
        # before the next iteration.
        ref best_match = cached_match[best_idx]
        var match_start = best_match.start
        var match_end = best_match.end
        # ``\\G`` anchor for the *next* search is the libonig
        # match end, even when zero-width. Update before any
        # empty-match guards bump ``match_end`` artificially.
        g_pos = match_end
        var was_zero_width = (match_end == match_start)
        # Empty match guard: bump ``match_end`` so a zero-width *match*
        # doesn't loop forever at the same pos.
        #
        # Two transitions are exempt from the bump:
        #   * zero-width begin transitions (``(?!\\G)``-style) — so the
        #     body of the pushed frame starts *at* the matched position
        #     rather than one byte past it.
        #   * zero-width ``end`` pops — the closing position belongs to
        #     the parent context, so popping must NOT consume the
        #     character. A construct like ``meta.property-name`` whose
        #     end is ``(?![-a-zA-Z])`` closes right *on* the ``:`` that
        #     the sibling property-value ``(:)\s*`` begin needs to see;
        #     bumping past it swallowed the colon and left the whole
        #     value (numbers, strings, …) untokenized.
        # ``stuck_iters`` below guards the resulting zero-advance pops
        # against a pathological begin↔end oscillation.
        var cand = cands[best_idx]
        var is_begin_push = False
        if cand.pattern_idx >= 0:
            var pat_kind = grammar.patterns[cand.pattern_idx].kind
            if pat_kind == PATTERN_BEGIN_END \
                    or pat_kind == PATTERN_BEGIN_WHILE:
                is_begin_push = True
        var is_end_pop = (cand.pattern_idx < 0)
        if was_zero_width and not is_begin_push and not is_end_pop:
            match_end = match_start + 1

        # Emit any unscoped run between ``pos`` and the match start.
        if match_start > pos:
            _emit_unmatched(grammar, stack, line, row, pos, match_start, out)

        if cand.pattern_idx < 0:
            # Top-frame ``end`` matched: paint the end run with the
            # frame's outer scope, then overlay any ``endCaptures``
            # on top, then pop.
            var top = stack[len(stack) - 1]
            ref pat = grammar.patterns[top.pattern_idx]
            var attr = _attr_for_scopes(top.scope_chain, pat.name)
            if match_end > match_start:
                out.append(Highlight(row, match_start, match_end, attr))
            _emit_captures(
                grammar, top.scope_chain, pat.name, pat.end_captures,
                best_match, line, row, out,
            )
            stack.resize(len(stack) - 1, _empty_frame())
            pos = match_end
            continue

        ref pat = grammar.patterns[cand.pattern_idx]
        if pat.kind == PATTERN_MATCH:
            var chain = _top_chain(stack)
            var attr = _attr_for_scopes(chain, pat.name)
            out.append(Highlight(row, match_start, match_end, attr))
            _emit_captures(
                grammar, chain, pat.name, pat.captures,
                best_match, line, row, out,
            )
            pos = match_end
            continue

        if pat.kind == PATTERN_BEGIN_END \
                or pat.kind == PATTERN_BEGIN_WHILE:
            # Paint the ``begin`` text with the outer ``name`` scope,
            # overlay ``beginCaptures`` on top, then push a new
            # frame so its ``contentName`` (or the outer name when
            # contentName is absent) governs what comes next.
            # ``BEGIN_END`` stays open until its end regex matches;
            # ``BEGIN_WHILE`` stays open as long as each new line
            # starts with its while regex (handled by
            # ``_process_while_frames``).
            var chain_outer = _top_chain(stack)
            var begin_attr = _attr_for_scopes(chain_outer, pat.name)
            out.append(Highlight(row, match_start, match_end, begin_attr))
            _emit_captures(
                grammar, chain_outer, pat.name, pat.captures,
                best_match, line, row, out,
            )
            var new_chain = chain_outer
            if len(pat.content_name.as_bytes()) > 0:
                new_chain = _join_scope(chain_outer, pat.content_name)
            elif len(pat.name.as_bytes()) > 0:
                new_chain = _join_scope(chain_outer, pat.name)
            # Remember the begin captures only when the end regex will
            # need them — otherwise the frame's group list stays empty
            # (and frame equality / incremental caching is unaffected).
            var begin_groups = String("")
            if pat.end_has_backref:
                begin_groups = _pack_groups(
                    _extract_group_texts(best_match, line)
                )
            stack.append(Frame(cand.pattern_idx, new_chain^, begin_groups^))
            pos = match_end
            continue

        # Unknown / INCLUDE shouldn't reach here because expansion
        # filters them out. Defensive advance.
        pos = match_end

    # End-of-line post-pass for ``\\n``-bearing end regexes. Several
    # grammars (Elm/Haskell ``import`` and ``module``, etc.) close a
    # scope with ``end: "\\n(?!\\s)"`` — read as "the construct ends
    # at the newline that's followed by a non-whitespace character on
    # the next line." Per-line tokenization would never see ``\\n``,
    # so without this pass the frame stays open forever and poisons
    # the rest of the file (everything inside it gets the wrong scope
    # — or no scope at all if no inner pattern matches).
    #
    # We synthesize a virtual ``line + "\\n" + next_line`` and try the
    # top frame's end regex at byte ``n`` (the position of the virtual
    # newline). If it matches there, we close the frame; we repeat
    # while the new top still wants to close on the same boundary.
    # ``next_line`` is empty on the last row of the buffer, which makes
    # ``(?!\\s)``-style lookaheads succeed against end-of-string —
    # treating EOF the same as "next line starts with non-whitespace,"
    # which closes any single-line construct. Highlight ranges are
    # clamped to ``n`` so the ``\\n`` itself doesn't paint past the
    # visible line. Built only once a begin/end frame is on top: most
    # rows end outside one, and concatenating two lines for every row of
    # every tokenize pass was pure allocation.
    var line_nl = String()
    var have_line_nl = False
    while len(stack) > 0:
        var top = stack[len(stack) - 1]
        ref top_pat = grammar.patterns[top.pattern_idx]
        if top_pat.kind != PATTERN_BEGIN_END:
            break
        if not have_line_nl:
            line_nl = line + String("\n") + next_line
            have_line_nl = True
        # Mirror the main loop: a back-referencing end uses the frame's
        # substituted regex so a ``\\n``-bearing close still resolves
        # against the begin captures.
        var dyn = _dyn_end_regex(grammar, top, dyn_keys, dyn_regexes)
        var m_opt: Optional[OnigMatch]
        if dyn:
            m_opt = dyn.value().search_at(line_nl, n)
        else:
            m_opt = grammar.regex(top_pat.end_idx).search_at(line_nl, n)
        if not m_opt:
            break
        var m = m_opt.value().copy()
        if m.start != n:
            break
        var clamp_end = m.end
        if clamp_end > n:
            clamp_end = n
        if clamp_end > m.start:
            var attr = _attr_for_scopes(top.scope_chain, top_pat.name)
            out.append(Highlight(row, m.start, clamp_end, attr))
            _emit_captures(
                grammar, top.scope_chain, top_pat.name, top_pat.end_captures,
                m, line_nl, row, out,
            )
        stack.resize(len(stack) - 1, _empty_frame())

    # Bracket post-pass. TextMate grammars vary wildly in whether they
    # tag ``()`` / ``[]`` / ``{}`` — Python's vendored grammar doesn't
    # tag them at all, so by default they fall through with no scope
    # and read as plain text. We treat brackets as operators (matching
    # how the generic per-language tokenizer in ``highlight.mojo``
    # already paints them), so any bracket byte not already covered
    # by a *meaningful* highlight from this row gets an explicit
    # operator paint.
    #
    # "Meaningful" = string / comment / operator: a bracket inside a
    # string or comment literal keeps the surrounding color, and one
    # already tagged as an operator needs no second paint. A bracket
    # covered only by the identifier / keyword fallback does NOT count
    # as covered — that fallback is what an embedded grammar's unnamed
    # begin span paints over the whole construct (e.g. the ``(`` in JS
    # ``if (expanded)`` inside an HTML ``<script>``), and brackets are
    # never identifiers. Leaving such brackets uncovered lets them pick
    # up the operator color like brackets everywhere else.
    if n > 0:
        var op_attr = highlight_operator_attr()
        var comment_fg = highlight_comment_attr().fg
        var string_fg = highlight_string_attr().fg
        for i in range(n):
            var c = Int(hb[i])
            if c != 0x28 and c != 0x29 and c != 0x5B and c != 0x5D \
                    and c != 0x7B and c != 0x7D:
                continue
            var covered = False
            for k in range(hl_start, len(out)):
                var h = out[k]
                if h.col_start <= i and i < h.col_end:
                    var f = h.attr.fg
                    if f == comment_fg or f == string_fg or f == op_attr.fg:
                        covered = True
                        break
            if not covered:
                out.append(Highlight(row, i, i + 1, op_attr))

    # No release here: ``_tokenize_line`` owns ``dyn_regexes`` and frees
    # them in a ``finally``, so a raise on any path above still hands
    # libonig's allocations back.


def _process_while_frames(
    grammar: Grammar, line: String, row: Int,
    mut stack: List[Frame], pos_in: Int,
    mut out: HighlightList,
) -> Int:
    """Run the ``while``-rule check at the start of each line.

    Walks the top of the stack looking at consecutive
    ``BEGIN_WHILE`` frames (counted from the bottom up to the top).
    For each one:

    * If its ``while`` regex matches at the current position, emit
      the matched bytes with the frame's outer scope (and any
      ``whileCaptures`` overlays — stored in ``end_captures``),
      advance ``pos`` past the match, and move to the next frame
      above it.
    * If it doesn't match, pop the frame silently and every
      ``BEGIN_WHILE`` above it — TextMate's rule is that once a
      while-scope falls out, all of its descendants do too. No
      end-scope highlights get emitted.

    Stops at the first non-``BEGIN_WHILE`` frame from the bottom or
    when the stack empties. Returns the new ``pos``."""
    var pos = pos_in
    # Find the lowest BEGIN_WHILE frame (bottom-most). Skip any
    # BEGIN_END frames below it — they aren't gated by line starts.
    var idx = 0
    while idx < len(stack):
        ref pat = grammar.patterns[stack[idx].pattern_idx]
        if pat.kind == PATTERN_BEGIN_WHILE:
            break
        idx += 1
    # Walk upward through consecutive while-frames.
    while idx < len(stack):
        ref pat = grammar.patterns[stack[idx].pattern_idx]
        if pat.kind != PATTERN_BEGIN_WHILE:
            # Non-while frame between while-frames — leave the rest
            # alone (rare but legal).
            idx += 1
            continue
        var rx = grammar.regex(pat.end_idx)
        var m_opt = rx.search_at(line, pos)
        var matched = False
        if m_opt:
            var m = m_opt.value().copy()
            if m.start == pos:
                matched = True
                if m.end > m.start:
                    var attr = _attr_for_scopes(
                        stack[idx].scope_chain, pat.name,
                    )
                    out.append(Highlight(row, m.start, m.end, attr))
                    _emit_captures(
                        grammar, stack[idx].scope_chain, pat.name,
                        pat.end_captures, m, line, row, out,
                    )
                    pos = m.end
        if not matched:
            # Pop this frame plus everything above it.
            stack.resize(idx, _empty_frame())
            return pos
        idx += 1
    return pos


def _emit_captures(
    grammar: Grammar, chain: String, match_name: String,
    caps: List[Capture], m: OnigMatch,
    line: String, row: Int, mut out: HighlightList,
):
    """Overlay capture-group highlights on top of a previously-emitted
    whole-match Highlight. Each capture is a (group_idx, scope,
    nested-patterns) record from the grammar.

    Two layers per capture:

    1. A scope-only Highlight on the captured byte range (when
       ``cap.scope`` is non-empty). Last-write-wins puts these on
       top of the outer match's color.
    2. A *mini-tokenize* of the captured substring against
       ``cap.nested`` (when non-empty). The captured substring is
       walked once with the listed patterns as the active set; the
       resulting Highlights' columns are shifted by the capture's
       start so they line up in the original line.

    ``_attr_for_scopes`` is told the capture scope is the leaf, so
    its prefix lookup hits the most specific scope first.

    Skips groups that didn't participate (``start < 0``) and
    zero-width groups; both would produce useless highlights."""
    if len(caps) == 0:
        return
    # The chain inside the match also includes the match's own
    # ``name`` — we re-join it so capture lookups find it via the
    # walk-innermost-first logic in ``_attr_for_scopes``.
    var inner_chain = chain
    if len(match_name.as_bytes()) > 0:
        inner_chain = _join_scope(chain, match_name)
    for ci in range(len(caps)):
        ref cap = caps[ci]
        if cap.group < 0 or cap.group >= m.group_count():
            continue
        var gs = m.group_starts[cap.group]
        var ge = m.group_ends[cap.group]
        if gs < 0 or ge <= gs:
            continue
        if len(cap.scope.as_bytes()) > 0:
            var attr = _attr_for_scopes(inner_chain, cap.scope)
            out.append(Highlight(row, gs, ge, attr))
        if len(cap.nested) > 0:
            _emit_capture_subtokens(
                grammar, line, gs, ge, inner_chain, cap.nested,
                row, out,
            )


def _emit_capture_subtokens(
    grammar: Grammar, line: String,
    sub_start: Int, sub_end: Int,
    chain: String, pattern_idxs: List[Int],
    row: Int, mut out: HighlightList,
):
    """Mini-tokenize the captured byte range ``[sub_start, sub_end)``
    of ``line`` against the listed patterns. Output column offsets
    are shifted by ``sub_start`` so they're absolute within
    ``line``.

    No scope stack is carried — capture-group ``patterns`` are
    documented as flat-only (they re-tokenize the inner text), so
    we don't push begin/end frames here. A ``begin`` pattern listed
    inside a capture's ``patterns`` would still match its own
    range, but its end would have to be on the same line.
    """
    var sub = byte_slice(line, sub_start, sub_end)
    var sb = sub.as_bytes()
    var n = len(sb)
    var pos = 0
    while pos < n:
        var best_idx = -1
        var best_match = OnigMatch(-1, -1, List[Int](), List[Int]())
        for ci in range(len(pattern_idxs)):
            ref pat = grammar.patterns[pattern_idxs[ci]]
            if pat.kind != PATTERN_MATCH:
                # Capture-group ``patterns`` only run a single
                # tokenization pass; ``begin``/``end`` and INCLUDE
                # are out of scope for this minimal path. Skip
                # gracefully — most grammars use match-only here.
                continue
            var rx = grammar.regex(pat.match_idx)
            var m_opt = rx.search_at(sub, pos)
            if not m_opt:
                continue
            var m = m_opt.take()
            if best_idx < 0 or m.start < best_match.start:
                best_idx = ci
                best_match = m^
        if best_idx < 0:
            return
        var ms = best_match.start
        var me = best_match.end
        if me == ms:
            me = ms + 1
        ref pat = grammar.patterns[pattern_idxs[best_idx]]
        var attr = _attr_for_scopes(chain, pat.name)
        out.append(Highlight(
            row, sub_start + ms, sub_start + me, attr,
        ))
        # Capture's nested ``captures`` (rare) — skip; recursing
        # would need to refit OnigMatch offsets and isn't worth
        # the complexity for the handful of grammars that do it.
        pos = me


def _emit_unmatched(
    grammar: Grammar, stack: List[Frame], line: String, row: Int,
    start: Int, end: Int, mut out: HighlightList,
):
    """Color a span that no pattern matched. Inside an open scope
    we still want the surrounding ``contentName`` to paint —
    otherwise the body of a string or comment ends up uncolored
    between escape-sequence highlights."""
    if end <= start:
        return
    var chain = _top_chain(stack)
    if len(chain.as_bytes()) == 0:
        return
    # Walk the chain innermost-first: an open ``string`` / ``comment``
    # frame nests under wrapper scopes (``meta.property-value.css`` …),
    # so a prefix match against the *whole* chain would miss it — the
    # chain starts with the unmapped ``meta.*`` scope. Only paint when
    # some scope in the chain maps; truly-unscoped runs stay uncolored.
    var attr_opt = _scope_attr_in_chain(chain)
    if attr_opt:
        out.append(Highlight(row, start, end, attr_opt.value()))


def _empty_frame() -> Frame:
    return Frame(0, String(""), String(""))


def _pack_groups(groups: List[String]) -> String:
    """Serialize capture groups into one string as ``<bytelen>:<bytes>``
    per group, concatenated. Length-prefixing keeps it unambiguous for
    any group content (which can hold ``:`` or arbitrary bytes). The
    inverse is ``_unpack_groups``."""
    var out = String("")
    for g in range(len(groups)):
        out += String(len(groups[g].as_bytes()))
        out += ":"
        out += groups[g]
    return out^


def _unpack_groups(packed: String) -> List[String]:
    """Inverse of ``_pack_groups``."""
    var out = List[String]()
    var b = packed.as_bytes()
    var i = 0
    while i < len(b):
        var num = 0
        while i < len(b) and Int(b[i]) >= 0x30 and Int(b[i]) <= 0x39:
            num = num * 10 + (Int(b[i]) - 0x30)
            i += 1
        if i >= len(b) or Int(b[i]) != 0x3A:  # ':'
            break
        i += 1  # skip ':'
        out.append(byte_slice(packed, i, i + num))
        i += num
    return out^


def _extract_group_texts(m: OnigMatch, line: String) -> List[String]:
    """Pull each capture group's matched substring out of ``line``,
    indexed by group number (0 = whole match). Groups that didn't
    participate (start < 0) become empty strings so the index stays
    aligned with the group number. Used to remember a begin match's
    captures for later substitution into a back-referencing end regex."""
    var out = List[String]()
    var lb = line.as_bytes()
    for g in range(m.group_count()):
        var gs = m.group_starts[g]
        var ge = m.group_ends[g]
        if gs < 0 or ge < gs or ge > len(lb):
            out.append(String(""))
            continue
        out.append(byte_slice(line, gs, ge))
    return out^


def _substitute_backrefs(src: String, groups: List[String]) -> String:
    """Replace ``\\1``..``\\9`` in ``src`` with the regex-escaped text of
    the corresponding begin-match group, leaving ``\\\\`` (escaped
    backslash) and every other escape untouched. A backref to a group
    that didn't participate (or is out of range) becomes empty — the
    same as TextMate, where an absent capture contributes nothing."""
    var b = src.as_bytes()
    var out = List[UInt8]()
    var i = 0
    while i < len(b):
        var c = Int(b[i])
        if c == 0x5C and i + 1 < len(b):
            var d = Int(b[i + 1])
            if d >= 0x31 and d <= 0x39:  # '1'..'9'
                var gi = d - 0x30
                if gi < len(groups):
                    out.extend(regex_escape_literal(groups[gi]).as_bytes())
                # else: out of range → empty substitution
                i += 2
                continue
            # Any other escape (incl. "\\") passes through verbatim.
            out.append(b[i])
            out.append(b[i + 1])
            i += 2
            continue
        out.append(b[i])
        i += 1
    return String(StringSpan(unsafe_from_utf8=Span(out)))


def _dyn_end_regex(
    grammar: Grammar, frame: Frame,
    mut dyn_keys: List[String], mut dyn_regexes: List[OnigRegex],
) -> Optional[OnigRegex]:
    """The end regex to use for ``frame`` when its opening pattern's end
    back-references begin captures: ``frame.begin_groups`` spliced into
    the raw end source, compiled (and cached for the rest of this line's
    tokenize). Returns ``None`` when the frame doesn't need substitution
    — the caller then falls back to the statically compiled end regex —
    or when the rebuilt regex fails to compile."""
    ref pat = grammar.patterns[frame.pattern_idx]
    if not pat.end_has_backref or len(frame.begin_groups.as_bytes()) == 0:
        return Optional[OnigRegex]()
    var src = _substitute_backrefs(
        pat.end_source, _unpack_groups(frame.begin_groups),
    )
    for k in range(len(dyn_keys)):
        if dyn_keys[k] == src:
            return Optional[OnigRegex](dyn_regexes[k])
    try:
        var rx = OnigRegex(src)
        dyn_keys.append(src)
        dyn_regexes.append(rx)
        return Optional[OnigRegex](rx)
    except:
        return Optional[OnigRegex]()


def _top_chain(stack: List[Frame]) -> String:
    if len(stack) == 0:
        return String("")
    return stack[len(stack) - 1].scope_chain


def _join_scope(chain: String, leaf: String) -> String:
    """Append a scope to an existing chain, space-separated as
    TextMate conventionally writes them."""
    var cb = chain.as_bytes()
    if len(cb) == 0:
        return leaf
    return chain + String(" ") + leaf


def _candidates_under(
    grammar: Grammar, top_pattern: Int,
) -> List[_Cand]:
    """Build the list of patterns to probe while ``top_pattern`` is the
    top frame's pattern (-1: the stack is empty).

    The order is:
    1. The top frame's ``end`` regex (if there is a frame), so that a
       closing match wins on ties.
    2. The patterns listed inside the top frame (or the grammar's
       ``root_patterns`` when the stack is empty), with ``include``
       references expanded transitively.

    Cycle protection: we track which pattern indices have already
    been pulled in via ``include`` and stop following an ``include``
    that revisits one. The Rust grammar's ``comment_block`` includes
    itself; without the guard that's an infinite loop.
    """
    var out = List[_Cand]()
    var seen = List[Int]()
    if top_pattern < 0:
        for k in range(len(grammar.root_patterns)):
            _expand_into(grammar, grammar.root_patterns[k], out, seen)
        return out^
    ref top_pat = grammar.patterns[top_pattern]
    # ``BEGIN_WHILE`` frames don't have an end-regex candidate —
    # their lifetime is gated by the per-line ``while`` check
    # in ``_process_while_frames``, not an inline match.
    if top_pat.kind == PATTERN_BEGIN_END:
        out.append(_Cand(-1, top_pat.end_idx, _has_g(grammar, top_pat.end_idx)))
    for k in range(len(top_pat.nested)):
        _expand_into(grammar, top_pat.nested[k], out, seen)
    return out^


def _has_g(grammar: Grammar, regex_idx: Int) -> Bool:
    return regex_idx >= 0 and regex_idx < len(grammar.regex_has_g) \
        and grammar.regex_has_g[regex_idx]


def _expand_into(
    grammar: Grammar, pattern_idx: Int,
    mut out: List[_Cand], mut seen: List[Int],
):
    """Resolve a pattern index to its concrete ``MATCH`` /
    ``BEGIN_END`` candidate(s), following ``include`` references."""
    if pattern_idx < 0 or pattern_idx >= len(grammar.patterns):
        return
    for s in range(len(seen)):
        if seen[s] == pattern_idx:
            return
    seen.append(pattern_idx)
    ref pat = grammar.patterns[pattern_idx]
    if pat.kind == PATTERN_INCLUDE:
        var t = pat.include_target
        if t == String("$self"):
            for k in range(len(grammar.root_patterns)):
                _expand_into(
                    grammar, grammar.root_patterns[k], out, seen,
                )
            return
        # Repository lookup ("#name" with the leading "#" already
        # stripped at load time).
        var idx = grammar.lookup_repo(t)
        if idx >= 0:
            _expand_into(grammar, idx, out, seen)
            return
        # External-scope ("source.X" / "text.Y") — fall into the
        # embedded grammar's roots if we loaded it. Unknown scopes
        # become a no-op (matches the prior behavior, just with
        # the new external table not catching the include).
        var ext_idx = grammar.lookup_external(t)
        if ext_idx >= 0:
            ref ext_roots = grammar.external_roots[ext_idx]
            for k in range(len(ext_roots)):
                _expand_into(grammar, ext_roots[k], out, seen)
        return
    if pat.kind == PATTERN_GROUP:
        # Container: expand to its children. Same shape as INCLUDE
        # follow-through; the cycle guard (``seen``) is shared so a
        # group that transitively references itself terminates.
        for k in range(len(pat.nested)):
            _expand_into(grammar, pat.nested[k], out, seen)
        return
    if pat.kind == PATTERN_MATCH:
        out.append(
            _Cand(pattern_idx, pat.match_idx, _has_g(grammar, pat.match_idx))
        )
        return
    if pat.kind == PATTERN_BEGIN_END or pat.kind == PATTERN_BEGIN_WHILE:
        # Probe the begin regex; the end-or-while regex is consulted
        # later — for ``BEGIN_END`` via the top-of-stack candidate
        # in ``_candidates_under``, for ``BEGIN_WHILE`` via the
        # per-line check in ``_process_while_frames``.
        out.append(
            _Cand(pattern_idx, pat.match_idx, _has_g(grammar, pat.match_idx))
        )
        return


# --- scope → Attr mapping ----------------------------------------------------


def _scope_attr_in_chain(chain: String) -> Optional[Attr]:
    """Walk a space-separated scope chain innermost-first and return the
    first scope that maps to an Attr (or ``None`` if none do). Walks the
    chain's bytes in place — this runs for every token, and splitting
    the chain into a list of strings allocated per token."""
    var sb = chain.as_bytes()
    var end = len(sb)
    while end > 0:
        var start = end
        while start > 0 and sb[start - 1] != 0x20:  # space
            start -= 1
        if start < end:
            var ao = _scope_attr_bytes(sb[start:end])
            if ao:
                return ao
        end = start - 1
    return Optional[Attr]()


def _attr_for_scopes(chain: String, leaf: String) -> Attr:
    """Pick an Attr by inspecting the leaf scope first, then walking
    the chain from innermost to outermost. First known prefix wins.
    Falls back to the identifier color if nothing matches — better
    than uncolored, which is what we'd get otherwise."""
    if len(leaf.as_bytes()) > 0:
        var ao = _scope_attr(leaf)
        if ao:
            return ao.value()
    var co = _scope_attr_in_chain(chain)
    if co:
        return co.value()
    return highlight_ident_attr()


def _has_prefix(sb: Span[UInt8, _], lit: StaticString) -> Bool:
    var pb = lit.as_bytes()
    if len(pb) > len(sb):
        return False
    for i in range(len(pb)):
        if sb[i] != pb[i]:
            return False
    return True


def _scope_attr(scope: String) -> Optional[Attr]:
    """Map a single TextMate scope to an Attr by prefix."""
    return _scope_attr_bytes(scope.as_bytes())


def _scope_attr_bytes(scope: Span[UInt8, _]) -> Optional[Attr]:
    """Map a single TextMate scope to an Attr by prefix. Compares
    against static literals, so no per-call ``String`` is built.

    The list mirrors what the existing Mojo/Python tokenizer paints,
    plus a few TextMate-isms. Order matters only when one prefix is
    a prefix of another (e.g. ``keyword.operator`` before
    ``keyword`` would matter — listed first here).
    """
    if _has_prefix(scope, "keyword.operator"):
        return Optional[Attr](highlight_operator_attr())
    if _has_prefix(scope, "keyword"):
        return Optional[Attr](highlight_keyword_attr())
    # The django-html grammar scopes bare variable references inside
    # ``{% ... %}`` tags as ``string.unquoted.tag-string.django`` (e.g.
    # ``companies`` in ``{% if companies %}``). They're identifiers, not
    # strings — color them like idents (green) before the generic
    # ``string`` prefix below would paint them string-red.
    if _has_prefix(scope, "string.unquoted.tag-string"):
        return Optional[Attr](highlight_ident_attr())
    if _has_prefix(scope, "string"):
        return Optional[Attr](highlight_string_attr())
    if _has_prefix(scope, "comment"):
        return Optional[Attr](highlight_comment_attr())
    if _has_prefix(scope, "constant.numeric"):
        return Optional[Attr](highlight_number_attr())
    if _has_prefix(scope, "constant.character"):
        return Optional[Attr](highlight_string_attr())
    if _has_prefix(scope, "constant.language"):
        return Optional[Attr](highlight_keyword_attr())
    if _has_prefix(scope, "storage.type"):
        return Optional[Attr](highlight_keyword_attr())
    if _has_prefix(scope, "storage.modifier"):
        return Optional[Attr](highlight_keyword_attr())
    if _has_prefix(scope, "support.type"):
        return Optional[Attr](highlight_keyword_attr())
    if _has_prefix(scope, "support.function"):
        return Optional[Attr](highlight_ident_attr())
    if _has_prefix(scope, "entity.name.function"):
        return Optional[Attr](highlight_ident_attr())
    if _has_prefix(scope, "entity.name.type"):
        return Optional[Attr](highlight_keyword_attr())
    if _has_prefix(scope, "meta.attribute"):
        return Optional[Attr](highlight_decorator_attr())
    # Prose markup (rST / Markdown): pick the closest palette color
    # for each kind. ``markup.deleted/inserted/changed`` below are
    # the diff-specific subset and must keep their distinct mappings.
    if _has_prefix(scope, "markup.heading"):
        return Optional[Attr](highlight_keyword_attr())
    if _has_prefix(scope, "markup.bold"):
        return Optional[Attr](highlight_keyword_attr())
    if _has_prefix(scope, "markup.italic"):
        return Optional[Attr](highlight_ident_attr())
    if _has_prefix(scope, "markup.inline.raw") \
            or _has_prefix(scope, "markup.raw"):
        return Optional[Attr](highlight_string_attr())
    if _has_prefix(scope, "markup.underline"):
        return Optional[Attr](highlight_ident_attr())
    if _has_prefix(scope, "markup.list"):
        return Optional[Attr](highlight_operator_attr())
    if _has_prefix(scope, "markup.quote"):
        return Optional[Attr](highlight_comment_attr())
    # Diff scopes: render like ``git diff`` does in a color terminal —
    # deleted lines red, inserted lines green, hunk-range hints cyan,
    # file headers white-on-blue (the keyword color, which is the most
    # eye-catching cell in our palette).
    if _has_prefix(scope, "markup.deleted"):
        return Optional[Attr](highlight_string_attr())
    if _has_prefix(scope, "markup.inserted"):
        return Optional[Attr](highlight_ident_attr())
    if _has_prefix(scope, "markup.changed"):
        return Optional[Attr](highlight_decorator_attr())
    if _has_prefix(scope, "meta.diff.range") \
            or _has_prefix(scope, "meta.toc-list.line-number"):
        return Optional[Attr](highlight_decorator_attr())
    if _has_prefix(scope, "meta.diff"):
        return Optional[Attr](highlight_keyword_attr())
    if _has_prefix(scope, "punctuation.definition.string"):
        return Optional[Attr](highlight_string_attr())
    # ``punctuation.definition.comment`` is the comment *marker* itself
    # (``//``, ``/*``, ``#``) — it must read as comment, not as the
    # generic punctuation→operator below. Without this the ``//`` of an
    # embedded-JS line comment gets painted operator on top of the
    # comment body (the marker's scope wins on those two cells).
    if _has_prefix(scope, "punctuation.definition.comment"):
        return Optional[Attr](highlight_comment_attr())
    if _has_prefix(scope, "punctuation"):
        return Optional[Attr](highlight_operator_attr())
    # ``variable.*`` covers generic variables, function parameters,
    # ``self`` / ``this`` (variable.language), and assigned-name
    # references. Without this mapping these tokens fall through with
    # no highlight and read as plain text — which is the editor's
    # default ``YELLOW`` on ``BLUE``, making every identifier look
    # like a syntax error against the green-on-blue idents the rest
    # of the palette already paints (functions, type names, etc.).
    if _has_prefix(scope, "variable"):
        return Optional[Attr](highlight_ident_attr())
    return Optional[Attr]()


