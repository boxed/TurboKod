"""TextMate tokenizer driven by a loaded ``Grammar``.

Walk one line at a time, maintaining a stack of open ``begin``/``end``
scopes across lines. The output is the same ``List[Highlight]`` the
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
    Highlight,
    highlight_comment_attr, highlight_decorator_attr,
    highlight_ident_attr, highlight_keyword_attr,
    highlight_number_attr, highlight_operator_attr,
    highlight_string_attr,
)
from .onig import (
    OnigMatch, OnigRegex,
    ONIG_OPTION_NONE, ONIG_OPTION_NOT_BEGIN_POSITION,
)
from .string_utils import starts_with
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


def tokenize_with_grammar(
    grammar: Grammar, lines: List[String],
) -> List[Highlight]:
    """Run the tokenizer over an entire buffer. The scope stack is
    threaded line-to-line, which is what makes block comments and
    multi-line strings color correctly. Convenience wrapper around
    ``tokenize_with_grammar_full`` for callers that don't need
    the per-line stack snapshots."""
    var post_stacks = List[List[Frame]]()
    return tokenize_with_grammar_full(grammar, lines, post_stacks)


def tokenize_with_grammar_full(
    grammar: Grammar, lines: List[String],
    mut post_stacks: List[List[Frame]],
) -> List[Highlight]:
    """As ``tokenize_with_grammar``, but also fills ``post_stacks``
    with the scope stack at the *end* of each line. After the call,
    ``post_stacks[i]`` is the state that line ``i+1`` would start
    in. Used by ``HighlightCache`` to support incremental re-runs
    that pick up from a known-good row instead of restarting at
    the top of the buffer."""
    post_stacks.clear()
    var out = List[Highlight]()
    var stack = List[Frame]()
    for row in range(len(lines)):
        var next_line = String("")
        if row + 1 < len(lines):
            next_line = lines[row + 1]
        _tokenize_line(grammar, lines[row], next_line, row, stack, out)
        post_stacks.append(copy_stack(stack))
    return out^


def tokenize_lines_from(
    grammar: Grammar, lines: List[String],
    start_row: Int, min_row: Int, start_stack: List[Frame],
    cached_post_stacks: List[List[Frame]],
    mut post_stacks: List[List[Frame]],
    mut stable_row: Int,
) -> List[Highlight]:
    """Tokenize ``lines[start_row:]`` starting from ``start_stack``.

    The early-exit lives inside this loop so we don't burn cycles
    re-tokenizing a long tail that we'll throw away — as soon as
    the new post-stack at row ``r`` matches ``cached_post_stacks[r]``
    we know everything from ``r+1`` onward is identical to last
    time and we can stop.

    Early-exit is suppressed for rows ``< min_row``: the caller begins
    one row *above* the edited row because rows are coupled by multi-line
    ``\\n`` end-regexes (row R-1 is tokenized against
    ``line[R-1] + "\\n" + line[R]``), and without this guard the loop would
    match the unchanged starting row's post-stack and quit before reaching
    the actual edit. Pass ``min_row == start_row`` for the classic behaviour.

    On return:

    * ``post_stacks`` holds the post-stack for each row we *did*
      tokenize — i.e. ``post_stacks[k]`` is the stack at end of
      row ``start_row + k``.
    * ``stable_row`` is the first row whose cached state we trust.
      Highlights for ``[start_row, stable_row)`` came from this
      call; rows ``>= stable_row`` should be spliced in from the
      caller's cached highlights.

    When ``cached_post_stacks`` is empty (cold load) or
    insufficient, we tokenize the whole tail and ``stable_row``
    ends up at ``len(lines)`` — i.e. nothing to splice.
    """
    post_stacks.clear()
    var out = List[Highlight]()
    var stack = copy_stack(start_stack)
    var row = start_row
    while row < len(lines):
        var next_line = String("")
        if row + 1 < len(lines):
            next_line = lines[row + 1]
        _tokenize_line(grammar, lines[row], next_line, row, stack, out)
        post_stacks.append(copy_stack(stack))
        if row >= min_row \
                and row < len(cached_post_stacks) \
                and stack_eq(stack, cached_post_stacks[row]):
            stable_row = row + 1
            return out^
        row += 1
    stable_row = len(lines)
    return out^


def _tokenize_line(
    grammar: Grammar, line: String, next_line: String, row: Int,
    mut stack: List[Frame], mut out: List[Highlight],
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
    # ``pattern_idx`` (or the empty-stack root set), so recompute it only
    # when the stack top changes rather than rebuilding the list — with its
    # pattern copies and include expansion — at every position.
    var cands = List[_Cand]()
    var cands_top = -2  # sentinel: forces the first build (-1 == empty stack)
    # Dynamically recompiled end regexes for back-referencing ``end``
    # patterns (TextMate's ``end: "...\\2..."`` that targets a begin
    # capture). ``dyn_end`` is the top frame's substituted end regex, or
    # ``None`` when the top frame's end needs no substitution; it's
    # recomputed whenever the candidate set is rebuilt (i.e. when the
    # top frame changes). The keys/regexes lists cache compiles so a
    # line full of ``<td>..</td>`` rows doesn't recompile per cell.
    var dyn_keys = List[String]()
    var dyn_regexes = List[OnigRegex]()
    var dyn_end = Optional[OnigRegex]()
    # Per-candidate cached search result, reused across advancing positions
    # while the candidate set and search options are unchanged. ``cached_start``
    # is the cached match's start column, ``-1`` (no match in the rest of the
    # line, valid forever), or ``-2`` (unknown — must search). A cached match
    # stays valid while it's still at or ahead of ``pos``; once ``pos`` moves
    # past it we re-search. A ``\G``-anchored match has start == its search
    # start, so the "still ahead" test only reuses it at the identical
    # position, which keeps the anchor semantics correct.
    var cached_start = List[Int]()
    var cached_match = List[OnigMatch]()
    var cache_opts = ONIG_OPTION_NONE
    var cache_ready = False
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
            cands = _active_candidates(grammar, stack)
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
            # New candidate set → the by-index cache is stale; rebuild empty.
            cached_start = List[Int]()
            cached_match = List[OnigMatch]()
            for _ in range(len(cands)):
                cached_start.append(-2)
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
        if (not cache_ready) or search_options != cache_opts:
            # First pass for this candidate set, or the NOT_BEGIN_POSITION
            # option flipped — anchors (\G, \A, ^) at the search start can
            # then match differently, so drop the cache and re-search here.
            for ci in range(len(cached_start)):
                cached_start[ci] = -2
            cache_opts = search_options
            cache_ready = True
        var best_idx = -1
        var best_match = OnigMatch(-1, -1, List[Int](), List[Int]())
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
                    ref rx = grammar.regexes[cands[ci].regex_idx]
                    m_opt = rx.search_at(line, pos, search_options)
                if m_opt:
                    cached_match[ci] = m_opt.value().copy()
                    cached_start[ci] = cached_match[ci].start
                else:
                    cached_start[ci] = -1  # no match in the rest of the line
                cs = cached_start[ci]
            # ``cs`` is now -1 (no match) or >= pos (match at/ahead of pos).
            if cs >= 0:
                if best_idx < 0 or cs < best_match.start:
                    best_idx = ci
                    best_match = cached_match[ci].copy()
        if best_idx < 0:
            # No match in the rest of the line — the body of an open
            # scope (or the unmatched tail outside any scope) just
            # gets the surrounding scope's content_name attr if any.
            _emit_unmatched(grammar, stack, line, row, pos, n, out)
            pos = n
            continue

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
            var pat = grammar.patterns[top.pattern_idx].copy()
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

        var pat = grammar.patterns[cand.pattern_idx].copy()
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
    # visible line.
    var line_nl = line + String("\n") + next_line
    while len(stack) > 0:
        var top = stack[len(stack) - 1]
        var top_pat = grammar.patterns[top.pattern_idx].copy()
        if top_pat.kind != PATTERN_BEGIN_END:
            break
        # Mirror the main loop: a back-referencing end uses the frame's
        # substituted regex so a ``\\n``-bearing close still resolves
        # against the begin captures.
        var dyn = _dyn_end_regex(grammar, top, dyn_keys, dyn_regexes)
        var m_opt: Optional[OnigMatch]
        if dyn:
            m_opt = dyn.value().search_at(line_nl, n)
        else:
            m_opt = grammar.regexes[top_pat.end_idx].search_at(line_nl, n)
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


def _process_while_frames(
    grammar: Grammar, line: String, row: Int,
    mut stack: List[Frame], pos_in: Int,
    mut out: List[Highlight],
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
        var pat = grammar.patterns[stack[idx].pattern_idx].copy()
        if pat.kind == PATTERN_BEGIN_WHILE:
            break
        idx += 1
    # Walk upward through consecutive while-frames.
    while idx < len(stack):
        var pat = grammar.patterns[stack[idx].pattern_idx].copy()
        if pat.kind != PATTERN_BEGIN_WHILE:
            # Non-while frame between while-frames — leave the rest
            # alone (rare but legal).
            idx += 1
            continue
        var rx = grammar.regexes[pat.end_idx]
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
    line: String, row: Int, mut out: List[Highlight],
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
        var cap = caps[ci].copy()
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
    row: Int, mut out: List[Highlight],
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
    var sub = _slice_string(line, sub_start, sub_end)
    var sb = sub.as_bytes()
    var n = len(sb)
    var pos = 0
    while pos < n:
        var best_idx = -1
        var best_match = OnigMatch(-1, -1, List[Int](), List[Int]())
        for ci in range(len(pattern_idxs)):
            var pat = grammar.patterns[pattern_idxs[ci]].copy()
            if pat.kind != PATTERN_MATCH:
                # Capture-group ``patterns`` only run a single
                # tokenization pass; ``begin``/``end`` and INCLUDE
                # are out of scope for this minimal path. Skip
                # gracefully — most grammars use match-only here.
                continue
            var rx = grammar.regexes[pat.match_idx]
            var m_opt = rx.search_at(sub, pos)
            if not m_opt:
                continue
            var m = m_opt.value().copy()
            if best_idx < 0 or m.start < best_match.start:
                best_idx = ci
                best_match = m^
        if best_idx < 0:
            return
        var ms = best_match.start
        var me = best_match.end
        if me == ms:
            me = ms + 1
        var pat = grammar.patterns[pattern_idxs[best_idx]].copy()
        var attr = _attr_for_scopes(chain, pat.name)
        out.append(Highlight(
            row, sub_start + ms, sub_start + me, attr,
        ))
        # Capture's nested ``captures`` (rare) — skip; recursing
        # would need to refit OnigMatch offsets and isn't worth
        # the complexity for the handful of grammars that do it.
        pos = me


def _slice_string(s: String, start: Int, end: Int) -> String:
    """Byte-slice helper. Mojo's StringSlice accepts unsafe-from-utf8
    construction; the caller guarantees the bounds are codepoint-
    aligned (libonig matches at codepoint boundaries)."""
    var b = s.as_bytes()
    var s_clamped = start
    var e_clamped = end
    if s_clamped < 0:
        s_clamped = 0
    if e_clamped > len(b):
        e_clamped = len(b)
    if e_clamped <= s_clamped:
        return String("")
    return String(StringSlice(unsafe_from_utf8=b[s_clamped:e_clamped]))


def _emit_unmatched(
    grammar: Grammar, stack: List[Frame], line: String, row: Int,
    start: Int, end: Int, mut out: List[Highlight],
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
        var piece = String("")
        for k in range(num):
            if i + k < len(b):
                piece += chr(Int(b[i + k]))
        out.append(piece^)
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
        var piece = String("")
        for i in range(gs, ge):
            piece += chr(Int(lb[i]))
        out.append(piece^)
    return out^


def _escape_regex_literal(s: String) -> String:
    """Escape the regex metacharacters in ``s`` so it matches literally
    when spliced into a pattern. A captured tag name is normally bare
    word characters, but escaping keeps a capture that happens to hold
    ``.``/``(``/etc. from changing the recompiled end regex's meaning."""
    var out = String("")
    for b in s.as_bytes():
        var c = Int(b)
        # ASCII metacharacters that need a backslash in libonig.
        if c == 0x5C or c == 0x2E or c == 0x5E or c == 0x24 \
                or c == 0x2A or c == 0x2B or c == 0x3F or c == 0x28 \
                or c == 0x29 or c == 0x5B or c == 0x5D or c == 0x7B \
                or c == 0x7D or c == 0x7C or c == 0x2F:
            out += "\\"
        out += chr(c)
    return out^


def _substitute_backrefs(src: String, groups: List[String]) -> String:
    """Replace ``\\1``..``\\9`` in ``src`` with the regex-escaped text of
    the corresponding begin-match group, leaving ``\\\\`` (escaped
    backslash) and every other escape untouched. A backref to a group
    that didn't participate (or is out of range) becomes empty — the
    same as TextMate, where an absent capture contributes nothing."""
    var b = src.as_bytes()
    var out = String("")
    var i = 0
    while i < len(b):
        var c = Int(b[i])
        if c == 0x5C and i + 1 < len(b):
            var d = Int(b[i + 1])
            if d >= 0x31 and d <= 0x39:  # '1'..'9'
                var gi = d - 0x30
                if gi < len(groups):
                    out += _escape_regex_literal(groups[gi])
                # else: out of range → empty substitution
                i += 2
                continue
            # Any other escape (incl. "\\") passes through verbatim.
            out += chr(c)
            out += chr(d)
            i += 2
            continue
        out += chr(c)
        i += 1
    return out^


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


def _active_candidates(
    grammar: Grammar, stack: List[Frame],
) -> List[_Cand]:
    """Build the list of patterns to probe at the current position.

    The order is:
    1. The top-of-stack ``end`` regex (if the stack is non-empty),
       so that a closing match wins on ties.
    2. The patterns listed inside the top frame (or the grammar's
       ``root_patterns`` when the stack is empty), with ``include``
       references expanded transitively.

    Cycle protection: we track which pattern indices have already
    been pulled in via ``include`` and stop following an ``include``
    that revisits one. The Rust grammar's ``comment_block`` includes
    itself; without the guard that's an infinite loop.
    """
    var out = List[_Cand]()
    if len(stack) > 0:
        var top = stack[len(stack) - 1]
        var top_pat = grammar.patterns[top.pattern_idx].copy()
        # ``BEGIN_WHILE`` frames don't have an end-regex candidate —
        # their lifetime is gated by the per-line ``while`` check
        # in ``_process_while_frames``, not an inline match.
        if top_pat.kind == PATTERN_BEGIN_END:
            out.append(_Cand(-1, top_pat.end_idx))

    var roots: List[Int]
    if len(stack) == 0:
        roots = grammar.root_patterns.copy()
    else:
        var top = stack[len(stack) - 1]
        roots = grammar.patterns[top.pattern_idx].nested.copy()

    var seen = List[Int]()
    for k in range(len(roots)):
        _expand_into(grammar, roots[k], out, seen)
    return out^


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
    var pat = grammar.patterns[pattern_idx].copy()
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
            var ext_roots = grammar.external_roots[ext_idx].copy()
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
        out.append(_Cand(pattern_idx, pat.match_idx))
        return
    if pat.kind == PATTERN_BEGIN_END or pat.kind == PATTERN_BEGIN_WHILE:
        # Probe the begin regex; the end-or-while regex is consulted
        # later — for ``BEGIN_END`` via the top-of-stack candidate
        # in ``_active_candidates``, for ``BEGIN_WHILE`` via the
        # per-line check in ``_process_while_frames``.
        out.append(_Cand(pattern_idx, pat.match_idx))
        return


# --- scope → Attr mapping ----------------------------------------------------


def _scope_attr_in_chain(chain: String) -> Optional[Attr]:
    """Walk a space-separated scope chain innermost-first and return the
    first scope that maps to an Attr (or ``None`` if none do). Cheap —
    chains are short (typically 0-3 scopes deep for the bundled
    grammars)."""
    if len(chain.as_bytes()) == 0:
        return Optional[Attr]()
    var parts = _split_scopes(chain)
    var i = len(parts) - 1
    while i >= 0:
        var ao = _scope_attr(parts[i])
        if ao:
            return ao
        i -= 1
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


def _scope_attr(scope: String) -> Optional[Attr]:
    """Map a single TextMate scope to an Attr by prefix.

    The list mirrors what the existing Mojo/Python tokenizer paints,
    plus a few TextMate-isms. Order matters only when one prefix is
    a prefix of another (e.g. ``keyword.operator`` before
    ``keyword`` would matter — listed first here).
    """
    if starts_with(scope, String("keyword.operator")):
        return Optional[Attr](highlight_operator_attr())
    if starts_with(scope, String("keyword")):
        return Optional[Attr](highlight_keyword_attr())
    # The django-html grammar scopes bare variable references inside
    # ``{% ... %}`` tags as ``string.unquoted.tag-string.django`` (e.g.
    # ``companies`` in ``{% if companies %}``). They're identifiers, not
    # strings — color them like idents (green) before the generic
    # ``string`` prefix below would paint them string-red.
    if starts_with(scope, String("string.unquoted.tag-string")):
        return Optional[Attr](highlight_ident_attr())
    if starts_with(scope, String("string")):
        return Optional[Attr](highlight_string_attr())
    if starts_with(scope, String("comment")):
        return Optional[Attr](highlight_comment_attr())
    if starts_with(scope, String("constant.numeric")):
        return Optional[Attr](highlight_number_attr())
    if starts_with(scope, String("constant.character")):
        return Optional[Attr](highlight_string_attr())
    if starts_with(scope, String("constant.language")):
        return Optional[Attr](highlight_keyword_attr())
    if starts_with(scope, String("storage.type")):
        return Optional[Attr](highlight_keyword_attr())
    if starts_with(scope, String("storage.modifier")):
        return Optional[Attr](highlight_keyword_attr())
    if starts_with(scope, String("support.type")):
        return Optional[Attr](highlight_keyword_attr())
    if starts_with(scope, String("support.function")):
        return Optional[Attr](highlight_ident_attr())
    if starts_with(scope, String("entity.name.function")):
        return Optional[Attr](highlight_ident_attr())
    if starts_with(scope, String("entity.name.type")):
        return Optional[Attr](highlight_keyword_attr())
    if starts_with(scope, String("meta.attribute")):
        return Optional[Attr](highlight_decorator_attr())
    # Prose markup (rST / Markdown): pick the closest palette color
    # for each kind. ``markup.deleted/inserted/changed`` below are
    # the diff-specific subset and must keep their distinct mappings.
    if starts_with(scope, String("markup.heading")):
        return Optional[Attr](highlight_keyword_attr())
    if starts_with(scope, String("markup.bold")):
        return Optional[Attr](highlight_keyword_attr())
    if starts_with(scope, String("markup.italic")):
        return Optional[Attr](highlight_ident_attr())
    if starts_with(scope, String("markup.inline.raw")) \
            or starts_with(scope, String("markup.raw")):
        return Optional[Attr](highlight_string_attr())
    if starts_with(scope, String("markup.underline")):
        return Optional[Attr](highlight_ident_attr())
    if starts_with(scope, String("markup.list")):
        return Optional[Attr](highlight_operator_attr())
    if starts_with(scope, String("markup.quote")):
        return Optional[Attr](highlight_comment_attr())
    # Diff scopes: render like ``git diff`` does in a color terminal —
    # deleted lines red, inserted lines green, hunk-range hints cyan,
    # file headers white-on-blue (the keyword color, which is the most
    # eye-catching cell in our palette).
    if starts_with(scope, String("markup.deleted")):
        return Optional[Attr](highlight_string_attr())
    if starts_with(scope, String("markup.inserted")):
        return Optional[Attr](highlight_ident_attr())
    if starts_with(scope, String("markup.changed")):
        return Optional[Attr](highlight_decorator_attr())
    if starts_with(scope, String("meta.diff.range")) \
            or starts_with(scope, String("meta.toc-list.line-number")):
        return Optional[Attr](highlight_decorator_attr())
    if starts_with(scope, String("meta.diff")):
        return Optional[Attr](highlight_keyword_attr())
    if starts_with(scope, String("punctuation.definition.string")):
        return Optional[Attr](highlight_string_attr())
    # ``punctuation.definition.comment`` is the comment *marker* itself
    # (``//``, ``/*``, ``#``) — it must read as comment, not as the
    # generic punctuation→operator below. Without this the ``//`` of an
    # embedded-JS line comment gets painted operator on top of the
    # comment body (the marker's scope wins on those two cells).
    if starts_with(scope, String("punctuation.definition.comment")):
        return Optional[Attr](highlight_comment_attr())
    if starts_with(scope, String("punctuation")):
        return Optional[Attr](highlight_operator_attr())
    # ``variable.*`` covers generic variables, function parameters,
    # ``self`` / ``this`` (variable.language), and assigned-name
    # references. Without this mapping these tokens fall through with
    # no highlight and read as plain text — which is the editor's
    # default ``YELLOW`` on ``BLUE``, making every identifier look
    # like a syntax error against the green-on-blue idents the rest
    # of the palette already paints (functions, type names, etc.).
    if starts_with(scope, String("variable")):
        return Optional[Attr](highlight_ident_attr())
    return Optional[Attr]()




def _split_scopes(chain: String) -> List[String]:
    """Split a space-separated scope chain into individual scopes."""
    var out = List[String]()
    var sb = chain.as_bytes()
    var n = len(sb)
    var start = 0
    var i = 0
    while i < n:
        if sb[i] == 0x20:  # space
            if i > start:
                out.append(String(StringSlice(unsafe_from_utf8=sb[start:i])))
            start = i + 1
        i += 1
    if start < n:
        out.append(String(StringSlice(unsafe_from_utf8=sb[start:n])))
    return out^
