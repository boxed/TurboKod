"""Line-level Myers diff + unified-diff renderer + diff3 merge.

Used by:

* the editor's "Compare selection with clipboard" feature (unified diff)
* the editor's external-change handling: when a file changed on disk
  while the buffer is dirty, we run a 3-way merge against the on-disk
  text we last saw (``disk_baseline``) and apply the merged result. If
  the merge has conflicts, ``<<<<<<< / ======= / >>>>>>>`` markers are
  embedded in the output, mirroring git's conflict format.

The algorithm is the classic Myers O((N+M)D) shortest-edit-script with
the forward V-array; trace-back is reconstructed from snapshots of V at
each ``d``. We don't need the linear-space refinement — clipboard /
selection / file inputs are at most a few thousand lines, where the
snapshot approach (O(D·(N+M)) memory) is comfortable.

Output is GNU-style unified diff with three lines of context, including
``@@ -l,c +l,c @@`` hunk headers and ``--- ``/``+++ `` file labels.
"""

from std.collections.list import List

from .string_utils import split_lines


@fieldwise_init
struct DiffOp(ImplicitlyCopyable, Movable):
    """One step of a line-level edit script.

    ``kind``: 0 = equal, 1 = delete (line from a), 2 = insert (line from b).
    ``a_index`` / ``b_index`` are line indices into the inputs (-1 when not
    applicable, e.g. ``b_index`` for a delete).
    """
    var kind: Int
    var a_index: Int
    var b_index: Int


def diff_lines(a: List[String], b: List[String]) -> List[DiffOp]:
    """Myers diff over two line lists. Returns the edit script in
    forward (input-order) form: a sequence of equal / delete / insert
    operations whose application turns ``a`` into ``b``.
    """
    var n = len(a)
    var m = len(b)
    var max_d = n + m
    if max_d == 0:
        return List[DiffOp]()
    var offset = max_d
    var size = 2 * max_d + 1
    var v = List[Int]()
    for _ in range(size):
        v.append(0)
    # Snapshot of V *before* each d was computed; trace[d] is V at depth d-1.
    var trace = List[List[Int]]()
    var found_d = -1
    for d in range(max_d + 1):
        var snap = List[Int]()
        for i in range(size):
            snap.append(v[i])
        trace.append(snap^)
        var k = -d
        var done = False
        while k <= d:
            var x: Int
            if k == -d:
                x = v[k + 1 + offset]
            elif k == d:
                x = v[k - 1 + offset] + 1
            else:
                var down = v[k + 1 + offset]
                var right = v[k - 1 + offset] + 1
                if down > right:
                    x = down
                else:
                    x = right
            var y = x - k
            while x < n and y < m and a[x] == b[y]:
                x += 1
                y += 1
            v[k + offset] = x
            if x >= n and y >= m:
                found_d = d
                done = True
                break
            k += 2
        if done:
            break

    # Trace back. Emit ops in reverse, then reverse the list.
    var ops_rev = List[DiffOp]()
    var x_cur = n
    var y_cur = m
    var d_cur = found_d
    while d_cur > 0:
        var k_cur = x_cur - y_cur
        var prev_k: Int
        if k_cur == -d_cur:
            prev_k = k_cur + 1
        elif k_cur == d_cur:
            prev_k = k_cur - 1
        else:
            var down = trace[d_cur][k_cur + 1 + offset]
            var right = trace[d_cur][k_cur - 1 + offset] + 1
            if down > right:
                prev_k = k_cur + 1
            else:
                prev_k = k_cur - 1
        var prev_x = trace[d_cur][prev_k + offset]
        var prev_y = prev_x - prev_k
        # Snake first (in reverse): walk diagonally down-left until either
        # x or y reaches the predecessor's coordinate.
        while x_cur > prev_x and y_cur > prev_y:
            ops_rev.append(DiffOp(0, x_cur - 1, y_cur - 1))
            x_cur -= 1
            y_cur -= 1
        # Then the single non-diagonal step from (prev_x, prev_y).
        if x_cur > prev_x:
            ops_rev.append(DiffOp(1, prev_x, -1))    # delete a[prev_x]
        elif y_cur > prev_y:
            ops_rev.append(DiffOp(2, -1, prev_y))    # insert b[prev_y]
        x_cur = prev_x
        y_cur = prev_y
        d_cur -= 1
    # Common prefix (all equals) at d=0.
    while x_cur > 0 and y_cur > 0:
        ops_rev.append(DiffOp(0, x_cur - 1, y_cur - 1))
        x_cur -= 1
        y_cur -= 1

    var ops = List[DiffOp]()
    var i = len(ops_rev) - 1
    while i >= 0:
        ops.append(ops_rev[i])
        i -= 1
    return ops^


# --- unified diff *rows* (for an inline review view) ------------------------
# Row kinds for ``build_diff_rows``. The crucial distinction for the review
# editor: a REMOVED row exists only in the *before* file, so it has no
# after-file line number — it must render with a blank line-number gutter.
comptime DIFF_ROW_CONTEXT: Int = 0   # unchanged: carries its after-file number
comptime DIFF_ROW_ADDED:   Int = 1   # new line: carries its after-file number
comptime DIFF_ROW_REMOVED: Int = 2   # deleted line: NO after-file number


@fieldwise_init
struct DiffRow(ImplicitlyCopyable, Movable):
    """One visual row of a unified (inline) diff.

    ``after_row`` is the 0-based line index in the *after* file, or ``-1``
    for a REMOVED row — which is the whole point: removed lines have no
    after-file line number, so an editor rendering this row must leave the
    line-number gutter blank (see ``diff_row_line_label``). ``text`` is the
    content to paint; ``kind`` is one of ``DIFF_ROW_*`` for coloring.
    ``src_row`` is the line's index on its *own* side (after-file for
    context/added, before-file for removed) — used to map the row back to
    that side's syntax tokens.
    """
    var after_row: Int
    var text: String
    var kind: Int
    var src_row: Int


def diff_row_line_label(row: DiffRow) -> String:
    """The line-number gutter label for a diff row: the 1-based after-file
    number for context/added rows, and the empty string for removed rows
    (they have no line number)."""
    if row.after_row < 0:
        return String("")
    return String(row.after_row + 1)


def build_diff_rows(before: List[String], after: List[String]) -> List[DiffRow]:
    """Interleave ``before`` / ``after`` into unified-diff rows: unchanged
    lines as context, inserts as added, deletes as removed. Within each
    change run the removed lines are emitted *before* the added ones (the
    conventional old-above-new diff order). Removed rows carry
    ``after_row = -1`` — they have no line number — which is exactly the
    case the review editor must render as a no-line-number row.
    """
    var ops = diff_lines(before, after)
    var out = List[DiffRow]()
    var i = 0
    var n = len(ops)
    while i < n:
        if ops[i].kind == 0:
            out.append(DiffRow(
                ops[i].b_index, after[ops[i].b_index], DIFF_ROW_CONTEXT,
                ops[i].b_index,
            ))
            i += 1
            continue
        # Gather one change run, then emit removed (from before) then added
        # (from after) so the block reads old-above-new.
        var run_rem = List[Int]()
        var run_add = List[Int]()
        while i < n and ops[i].kind != 0:
            if ops[i].kind == 1:
                run_rem.append(ops[i].a_index)
            else:
                run_add.append(ops[i].b_index)
            i += 1
        for r in range(len(run_rem)):
            out.append(DiffRow(
                -1, before[run_rem[r]], DIFF_ROW_REMOVED, run_rem[r],
            ))
        for r in range(len(run_add)):
            out.append(DiffRow(
                run_add[r], after[run_add[r]], DIFF_ROW_ADDED, run_add[r],
            ))
    return out^


def _codepoints_with_offsets(s: String) -> Tuple[List[String], List[Int]]:
    """Split ``s`` into single-codepoint strings plus a parallel list of byte
    offsets (length ``len(cps) + 1``; the last entry is the total byte count)."""
    var cps = List[String]()
    var offs = List[Int]()
    var b = s.as_bytes()
    var n = len(b)
    var i = 0
    while i < n:
        offs.append(i)
        var j = i + 1
        while j < n and (Int(b[j]) & 0xC0) == 0x80:
            j += 1
        var buf = List[UInt8]()
        for k in range(i, j):
            buf.append(b[k])
        cps.append(String(StringSpan(unsafe_from_utf8=Span(buf))))
        i = j
    offs.append(n)
    return (cps^, offs^)


def intraline_ranges(
    old: String, new: String,
    mut old_out: List[Tuple[Int, Int]], mut new_out: List[Tuple[Int, Int]],
):
    """Character-level diff of two lines. Appends the changed *byte* ranges
    (``[lo, hi)``) on the old side to ``old_out`` and on the new side to
    ``new_out`` — the spans an inline diff should emphasise within a modified
    line. Contiguous edits merge into one range."""
    var ao = _codepoints_with_offsets(old)
    ref a_cp = ao[0]
    ref a_off = ao[1]
    var bo = _codepoints_with_offsets(new)
    ref b_cp = bo[0]
    ref b_off = bo[1]
    var ops = diff_lines(a_cp, b_cp)
    var del_lo = -1
    var del_hi = -1
    var ins_lo = -1
    var ins_hi = -1
    for i in range(len(ops)):
        if ops[i].kind == 1:        # delete (old codepoint)
            var lo = a_off[ops[i].a_index]
            var hi = a_off[ops[i].a_index + 1]
            if del_lo >= 0 and del_hi == lo:
                del_hi = hi
            else:
                if del_lo >= 0:
                    old_out.append((del_lo, del_hi))
                del_lo = lo
                del_hi = hi
        elif ops[i].kind == 2:      # insert (new codepoint)
            var lo = b_off[ops[i].b_index]
            var hi = b_off[ops[i].b_index + 1]
            if ins_lo >= 0 and ins_hi == lo:
                ins_hi = hi
            else:
                if ins_lo >= 0:
                    new_out.append((ins_lo, ins_hi))
                ins_lo = lo
                ins_hi = hi
        else:                       # equal — flush both pending runs
            if del_lo >= 0:
                old_out.append((del_lo, del_hi))
                del_lo = -1
                del_hi = -1
            if ins_lo >= 0:
                new_out.append((ins_lo, ins_hi))
                ins_lo = -1
                ins_hi = -1
    if del_lo >= 0:
        old_out.append((del_lo, del_hi))
    if ins_lo >= 0:
        new_out.append((ins_lo, ins_hi))


def _lstrip_ws(s: String) -> String:
    """``s`` with leading spaces / tabs removed. Used by ``_line_similarity``
    so two lines aren't judged alike merely for sharing an indentation level —
    a deep indent would otherwise floor every same-depth pair's score near 0.5
    (8 shared spaces over a ~16-char line), which is enough to mis-pair
    unrelated lines in a restructured block."""
    var b = s.as_bytes()
    var i = 0
    while i < len(b) and (b[i] == 0x20 or b[i] == 0x09):
        i += 1
    return String(StringSpan(unsafe_from_utf8=b[i:len(b)]))


def _line_similarity(a: String, b: String) -> Float64:
    """Fraction of codepoints two lines share, by LCS length over the longer
    line (1.0 = identical, 0.0 = nothing in common). Used to pair the
    most-alike removed/added lines within a change run. Leading whitespace is
    stripped first so the score reflects shared *content*, not shared indent."""
    var ao = _codepoints_with_offsets(_lstrip_ws(a))
    var bo = _codepoints_with_offsets(_lstrip_ws(b))
    ref a_cp = ao[0]
    ref b_cp = bo[0]
    var denom = len(a_cp) if len(a_cp) > len(b_cp) else len(b_cp)
    if denom == 0:
        return 1.0
    var ops = diff_lines(a_cp, b_cp)
    var common = 0
    for i in range(len(ops)):
        if ops[i].kind == 0:
            common += 1
    return Float64(common) / Float64(denom)


# Above this rem×add product we skip the O(n²) best-match search and fall back
# to positional pairing — change runs that large are rare and not worth the cost.
comptime _EMPHASIS_MATCH_BUDGET: Int = 400

# Don't pair a removed row with an added row below this content similarity
# (leading whitespace already stripped, see ``_line_similarity``): under half
# their content shared means they're more likely two *different* lines than one
# line modified. Pairing them anyway would yank the removed phantom row down to
# sit above an unrelated added line, scattering a restructured block into a
# confusing remove/add zigzag. Below the threshold we leave both unmatched, so
# the block degrades to the clean git-style "all removed, then all added".
comptime _PARTNER_MIN_SIMILARITY: Float64 = 0.5


def diff_row_partner(rows: List[DiffRow]) -> List[Int]:
    """For each row, the index of its matched counterpart within the same
    change run, or ``-1`` if unmatched. Within a run each removed row is
    greedily paired with the *most similar* added row (best match first) so a
    modified line is matched to its new version even when comments or other
    lines were inserted between them. Both ends of a pair point at each other;
    context rows and unmatched add/remove rows are ``-1``. Parallel to
    ``rows``. Drives both the intra-line emphasis pairing and the placement of
    a removed (phantom) row directly above its matched added line."""
    var partner = List[Int]()
    for _ in range(len(rows)):
        partner.append(-1)
    var i = 0
    var n = len(rows)
    while i < n:
        if rows[i].kind == DIFF_ROW_CONTEXT:
            i += 1
            continue
        var rem_idx = List[Int]()
        var add_idx = List[Int]()
        var j = i
        while j < n and rows[j].kind != DIFF_ROW_CONTEXT:
            if rows[j].kind == DIFF_ROW_REMOVED:
                rem_idx.append(j)
            else:
                add_idx.append(j)
            j += 1
        var n_pairs = len(rem_idx) if len(rem_idx) < len(add_idx) else len(add_idx)
        # Default to similarity-based matching so an inserted comment above a
        # modified line doesn't pair the code with the comment; fall back to
        # positional for huge runs (the O(n²) search isn't worth it there).
        if len(rem_idx) * len(add_idx) > _EMPHASIS_MATCH_BUDGET:
            for k in range(n_pairs):
                partner[rem_idx[k]] = add_idx[k]
                partner[add_idx[k]] = rem_idx[k]
        else:
            var used_add = List[Bool]()
            for _ in range(len(add_idx)):
                used_add.append(False)
            var used_rem = List[Bool]()
            for _ in range(len(rem_idx)):
                used_rem.append(False)
            for _ in range(n_pairs):
                var best = -1.0
                var best_r = -1
                var best_a = -1
                for ri in range(len(rem_idx)):
                    if used_rem[ri]:
                        continue
                    for ai in range(len(add_idx)):
                        if used_add[ai]:
                            continue
                        var sim = _line_similarity(
                            rows[rem_idx[ri]].text, rows[add_idx[ai]].text
                        )
                        if sim > best:
                            best = sim
                            best_r = ri
                            best_a = ai
                if best_r < 0:
                    break
                # The best remaining pair is too dissimilar to be one line
                # modified — and every later pair would be worse, so stop.
                # Leaving them unmatched groups them as removed-then-added.
                if best < _PARTNER_MIN_SIMILARITY:
                    break
                used_rem[best_r] = True
                used_add[best_a] = True
                partner[rem_idx[best_r]] = add_idx[best_a]
                partner[add_idx[best_a]] = rem_idx[best_r]
        i = j
    return partner^


def diff_row_emphasis(rows: List[DiffRow]) -> List[List[Tuple[Int, Int]]]:
    """For each diff row, the changed byte ranges *within* its text (empty for
    context / pure add / pure delete rows). Each removed row is char-diffed
    against its matched added row (see ``diff_row_partner``), so a modified
    line shows exactly which characters changed — even when comments or other
    lines were inserted between the old and new version. Parallel to ``rows``."""
    var out = List[List[Tuple[Int, Int]]]()
    for _ in range(len(rows)):
        out.append(List[Tuple[Int, Int]]())
    var partner = diff_row_partner(rows)
    for r in range(len(rows)):
        if rows[r].kind != DIFF_ROW_REMOVED:
            continue
        var a = partner[r]
        if a < 0:
            continue
        var old_ranges = List[Tuple[Int, Int]]()
        var new_ranges = List[Tuple[Int, Int]]()
        intraline_ranges(rows[r].text, rows[a].text, old_ranges, new_ranges)
        # If the two lines differ in more than a handful of spans they're most
        # likely unrelated — an intra-line diff that highlights the few
        # characters they happen to share by chance is noise, not signal. Give
        # up and leave the rows as a plain remove/add pair.
        if len(old_ranges) + len(new_ranges) > 4:
            continue
        out[r] = old_ranges^
        out[a] = new_ranges^
    return out^


def _hunk_header(a_start: Int, a_count: Int, b_start: Int, b_count: Int) -> String:
    """Render ``@@ -l,c +l,c @@``. When the count is 1, GNU diff omits the
    ``,c`` — match that so output reads like ``diff -u``. Empty ranges are
    rendered with display-line one less than the start (GNU convention)."""
    var a_disp = a_start + 1 if a_count > 0 else a_start
    var b_disp = b_start + 1 if b_count > 0 else b_start
    var a_part = String("-") + String(a_disp)
    if a_count != 1:
        a_part += String(",") + String(a_count)
    var b_part = String("+") + String(b_disp)
    if b_count != 1:
        b_part += String(",") + String(b_count)
    return String("@@ ") + a_part + String(" ") + b_part + String(" @@")


def unified_diff(
    a: String,
    b: String,
    a_label: String,
    b_label: String,
    context: Int = 3,
) -> String:
    """Compare two texts and return a unified-diff string. ``context`` is
    the number of unchanged lines shown around each hunk (3 is the GNU
    default).

    When the two texts are identical the result is just the file headers —
    callers that want to detect "no changes" can grep for the absence of
    ``@@`` in the output.
    """
    var a_lines = split_lines(a)
    var b_lines = split_lines(b)
    var ops = diff_lines(a_lines, b_lines)

    var out = String("--- ") + a_label + String("\n")
    out += String("+++ ") + b_label + String("\n")

    var i = 0
    var n = len(ops)
    while i < n:
        # Skip leading equals.
        while i < n and ops[i].kind == 0:
            i += 1
        if i >= n:
            break
        # Found a change. Back up to include up to ``context`` equal lines.
        var hunk_start = i
        var leading = 0
        while leading < context and hunk_start > 0 \
                and ops[hunk_start - 1].kind == 0:
            hunk_start -= 1
            leading += 1
        # Extend forward, swallowing runs of equals shorter than 2*context.
        var hunk_end = i + 1
        while hunk_end < n:
            if ops[hunk_end].kind != 0:
                hunk_end += 1
                continue
            var run_start = hunk_end
            while hunk_end < n and ops[hunk_end].kind == 0:
                hunk_end += 1
            var run_len = hunk_end - run_start
            if hunk_end >= n or run_len > 2 * context:
                # Trailing equals: keep at most ``context`` of them.
                var keep = context
                if run_len < keep:
                    keep = run_len
                hunk_end = run_start + keep
                break
        # Compute display ranges from the operations in [hunk_start, hunk_end).
        var a_first = -1
        var b_first = -1
        var a_count = 0
        var b_count = 0
        for j in range(hunk_start, hunk_end):
            var op = ops[j]
            if op.kind == 0:
                if a_first < 0:
                    a_first = op.a_index
                if b_first < 0:
                    b_first = op.b_index
                a_count += 1
                b_count += 1
            elif op.kind == 1:
                if a_first < 0:
                    a_first = op.a_index
                a_count += 1
            else:
                if b_first < 0:
                    b_first = op.b_index
                b_count += 1
        if a_first < 0:
            a_first = 0
        if b_first < 0:
            b_first = 0
        out += _hunk_header(a_first, a_count, b_first, b_count) + String("\n")
        # Emit ops, but within each contiguous run of non-equal ops put
        # all deletes before all inserts. Myers' trace-back emits them in
        # an arbitrary interleaving — ``diff -u`` and ``git diff`` always
        # group them, and tooling that parses unified diffs expects that.
        var j = hunk_start
        while j < hunk_end:
            var op = ops[j]
            if op.kind == 0:
                out += String(" ") + a_lines[op.a_index] + String("\n")
                j += 1
                continue
            var run_end = j
            while run_end < hunk_end and ops[run_end].kind != 0:
                run_end += 1
            for k in range(j, run_end):
                if ops[k].kind == 1:
                    out += String("-") + a_lines[ops[k].a_index] + String("\n")
            for k in range(j, run_end):
                if ops[k].kind == 2:
                    out += String("+") + b_lines[ops[k].b_index] + String("\n")
            j = run_end
        i = hunk_end
    return out^


# --- diff3 merge ------------------------------------------------------------
#
# 3-way line merge using two Myers diffs against a common base. The
# classical diff3 algorithm — find lines that match across all three
# inputs ("stable anchors"), divide the inputs into chunks between
# anchors, and resolve each chunk by comparing ours/theirs against
# base. Chunks where only one side changed auto-merge; chunks where
# both sides changed but produced identical results auto-merge; chunks
# where the two sides diverged become conflicts.
#
# The output is a flat ``List[String]``. Conflicts are surfaced as
# git-style ``<<<<<<< / ======= / >>>>>>>`` marker lines so the user
# resolves them in a normal editor view — no separate merge widget
# needed.


@fieldwise_init
struct MergeResult(Copyable, Movable):
    """Result of ``diff3_merge``.

    ``lines`` is the merged buffer; ``conflicts`` counts how many
    conflict regions were emitted; ``first_conflict_row`` is the row of
    the first ``<<<<<<<`` marker in ``lines`` (so callers can jump the
    cursor there) or -1 when the merge is clean.
    """
    var lines: List[String]
    var conflicts: Int
    var first_conflict_row: Int


comptime REGION_STABLE   = 0
comptime REGION_CONFLICT = 1


@fieldwise_init
struct MergeRegion(Copyable, Movable):
    """One run in a structured 3-way merge (see ``diff3_regions``).

    ``REGION_STABLE``: ``lines`` holds the agreed (auto-merged) text;
    the ours/theirs/base fields are empty. ``REGION_CONFLICT``:
    ``ours_lines`` and ``theirs_lines`` are the two competing versions
    of the chunk, ``base_lines`` the common-ancestor slice. This struct
    is UI-state-free — no resolution choice lives here; that's the
    ``MergeView``'s job.
    """
    var kind: Int
    var lines: List[String]
    var ours_lines: List[String]
    var theirs_lines: List[String]
    var base_lines: List[String]


def _equal_match_map(ops: List[DiffOp], a_len: Int) -> List[Int]:
    """For each index ``i`` in the ``a`` input of a Myers diff, return
    the matching index in ``b`` (when ``ops`` contains a kind==0 op for
    ``a_index == i``), else -1."""
    var out = List[Int]()
    for _ in range(a_len):
        out.append(-1)
    for i in range(len(ops)):
        if ops[i].kind == 0 and ops[i].a_index >= 0:
            out[ops[i].a_index] = ops[i].b_index
    return out^


def _slice_eq(
    a: List[String], a_lo: Int, a_hi: Int,
    b: List[String], b_lo: Int, b_hi: Int,
) -> Bool:
    """Element-wise equality of two slices ``a[a_lo:a_hi]`` and
    ``b[b_lo:b_hi]``. Used to decide which side(s) of a chunk changed
    relative to the base."""
    if (a_hi - a_lo) != (b_hi - b_lo):
        return False
    var n = a_hi - a_lo
    for i in range(n):
        if a[a_lo + i] != b[b_lo + i]:
            return False
    return True


# Per-chunk classification produced by ``_diff3_walk`` — which input's
# slice the chunk resolves to, or that it's a genuine conflict.
comptime CHUNK_BASE     = 0  # neither side changed → take base slice
comptime CHUNK_THEIRS   = 1  # only theirs changed → take theirs slice
comptime CHUNK_OURS     = 2  # only ours changed (or both changed alike)
comptime CHUNK_CONFLICT = 3  # both sides changed differently


@fieldwise_init
struct _Diff3Region(Copyable, Movable):
    """One anchor-to-anchor chunk of a 3-way merge, classified but not
    yet emitted. The shared ``_diff3_walk`` returns a list of these;
    ``diff3_merge`` and ``diff3_regions`` each render them their own way.

    ``kind`` is one of the ``CHUNK_*`` constants. The ``*_lo``/``*_hi``
    pairs are half-open ranges into base/ours/theirs for the chunk
    between the previous anchor and this one. ``anchor_line`` is the
    base index of the agreed anchor line that follows the chunk, or -1
    for the trailing sentinel (no anchor line to emit)."""
    var kind: Int
    var b_lo: Int
    var b_hi: Int
    var o_lo: Int
    var o_hi: Int
    var t_lo: Int
    var t_hi: Int
    var anchor_line: Int


def _diff3_walk(
    base: List[String],
    ours: List[String],
    theirs: List[String],
) -> List[_Diff3Region]:
    """Shared anchor-walk for the two public 3-way-merge entry points.

    Diffs ``ours`` and ``theirs`` against ``base``, finds the lines that
    match unchanged across all three (anchors), and classifies each
    chunk between anchors (see the ``CHUNK_*`` constants). A leading
    sentinel anchor at index -1 and a trailing sentinel at ``len(base)``
    cover the chunks before the first and after the last real anchor.
    The trailing sentinel carries ``anchor_line == -1`` (no line to
    emit); every other region's ``anchor_line`` is the agreed base line
    that follows its chunk."""
    var ops_ours = diff_lines(base, ours)
    var ops_theirs = diff_lines(base, theirs)
    var match_ours = _equal_match_map(ops_ours, len(base))
    var match_theirs = _equal_match_map(ops_theirs, len(base))

    var regions = List[_Diff3Region]()

    var i_prev = -1
    var oi_prev = -1
    var ti_prev = -1
    var i = 0
    var n = len(base)
    while i <= n:
        var is_anchor = False
        var oi = 0
        var ti = 0
        if i == n:
            is_anchor = True
            oi = len(ours)
            ti = len(theirs)
        elif match_ours[i] >= 0 and match_theirs[i] >= 0:
            is_anchor = True
            oi = match_ours[i]
            ti = match_theirs[i]
        if not is_anchor:
            i += 1
            continue
        var b_lo = i_prev + 1
        var b_hi = i
        var o_lo = oi_prev + 1
        var o_hi = oi
        var t_lo = ti_prev + 1
        var t_hi = ti
        var ours_changed = not _slice_eq(ours, o_lo, o_hi, base, b_lo, b_hi)
        var theirs_changed = not _slice_eq(theirs, t_lo, t_hi, base, b_lo, b_hi)
        var kind: Int
        if not ours_changed and not theirs_changed:
            kind = CHUNK_BASE
        elif not ours_changed:
            kind = CHUNK_THEIRS
        elif not theirs_changed:
            kind = CHUNK_OURS
        elif _slice_eq(ours, o_lo, o_hi, theirs, t_lo, t_hi):
            kind = CHUNK_OURS
        else:
            kind = CHUNK_CONFLICT
        var anchor_line = i if i < n else -1
        regions.append(_Diff3Region(
            kind, b_lo, b_hi, o_lo, o_hi, t_lo, t_hi, anchor_line,
        ))
        i_prev = i
        oi_prev = oi
        ti_prev = ti
        i += 1
    return regions^


def diff3_merge(
    base: List[String],
    ours: List[String],
    theirs: List[String],
    ours_label: String = String("ours"),
    theirs_label: String = String("theirs"),
) -> MergeResult:
    """Three-way line merge.

    Walks anchor-to-anchor through ``base``: a base line is an *anchor*
    when it appears unchanged in both ``ours`` and ``theirs``. Each
    chunk between anchors is resolved as:

    * ours unchanged from base → take theirs
    * theirs unchanged from base → take ours
    * both changed but identical → take either
    * otherwise → emit ``<<<<<<<`` / ``=======`` / ``>>>>>>>`` block

    A leading sentinel anchor at index -1 and a trailing sentinel at
    ``len(base)`` (mapped to the corresponding ours/theirs ends) cover
    chunks before the first real anchor and after the last.
    """
    var regions = _diff3_walk(base, ours, theirs)

    var out_lines = List[String]()
    var conflicts = 0
    var first_conflict_row = -1

    for r in regions:
        if r.kind == CHUNK_BASE:
            for k in range(r.b_lo, r.b_hi):
                out_lines.append(base[k])
        elif r.kind == CHUNK_THEIRS:
            for k in range(r.t_lo, r.t_hi):
                out_lines.append(theirs[k])
        elif r.kind == CHUNK_OURS:
            for k in range(r.o_lo, r.o_hi):
                out_lines.append(ours[k])
        else:
            if first_conflict_row < 0:
                first_conflict_row = len(out_lines)
            conflicts += 1
            out_lines.append(String("<<<<<<< ") + ours_label)
            for k in range(r.o_lo, r.o_hi):
                out_lines.append(ours[k])
            out_lines.append(String("======="))
            for k in range(r.t_lo, r.t_hi):
                out_lines.append(theirs[k])
            out_lines.append(String(">>>>>>> ") + theirs_label)
        if r.anchor_line >= 0:
            out_lines.append(base[r.anchor_line])
    return MergeResult(out_lines^, conflicts, first_conflict_row)


def diff3_regions(
    base: List[String],
    ours: List[String],
    theirs: List[String],
) -> List[MergeRegion]:
    """Structured 3-way merge.

    Same anchor-walk as ``diff3_merge``, but instead of emitting
    ``<<<<<<<`` marker lines it returns a list of ``MergeRegion``s:
    agreed chunks (and the anchors between them) coalesce into
    ``REGION_STABLE`` runs; a chunk that both sides changed differently
    becomes a ``REGION_CONFLICT`` carrying the two competing slices and
    the base slice. Reassembling the stable runs with the *ours* (resp.
    *theirs*) slice of each conflict reproduces ``ours`` (resp.
    ``theirs``); the regression tests pin this to ``diff3_merge``.
    """
    var regions = _diff3_walk(base, ours, theirs)

    var out = List[MergeRegion]()
    # Accumulator for the current run of agreed text; flushed as one
    # STABLE region whenever a conflict interrupts it or at the end.
    var pending = List[String]()

    for r in regions:
        if r.kind == CHUNK_BASE:
            for k in range(r.b_lo, r.b_hi):
                pending.append(base[k])
        elif r.kind == CHUNK_THEIRS:
            for k in range(r.t_lo, r.t_hi):
                pending.append(theirs[k])
        elif r.kind == CHUNK_OURS:
            for k in range(r.o_lo, r.o_hi):
                pending.append(ours[k])
        else:
            # Genuine conflict — flush the pending stable run first so
            # region order matches document order.
            if len(pending) > 0:
                out.append(MergeRegion(
                    REGION_STABLE, pending^,
                    List[String](), List[String](), List[String](),
                ))
                pending = List[String]()
            var ours_slice = List[String]()
            for k in range(r.o_lo, r.o_hi):
                ours_slice.append(ours[k])
            var theirs_slice = List[String]()
            for k in range(r.t_lo, r.t_hi):
                theirs_slice.append(theirs[k])
            var base_slice = List[String]()
            for k in range(r.b_lo, r.b_hi):
                base_slice.append(base[k])
            out.append(MergeRegion(
                REGION_CONFLICT, List[String](),
                ours_slice^, theirs_slice^, base_slice^,
            ))
        # The anchor line itself is agreed text.
        if r.anchor_line >= 0:
            pending.append(base[r.anchor_line])
    if len(pending) > 0:
        out.append(MergeRegion(
            REGION_STABLE, pending^,
            List[String](), List[String](), List[String](),
        ))
    return out^
