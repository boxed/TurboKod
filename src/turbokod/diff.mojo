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


fn diff_lines(a: List[String], b: List[String]) -> List[DiffOp]:
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


fn _hunk_header(a_start: Int, a_count: Int, b_start: Int, b_count: Int) -> String:
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


fn unified_diff(
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


fn _equal_match_map(ops: List[DiffOp], a_len: Int) -> List[Int]:
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


fn _slice_eq(
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


fn diff3_merge(
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
    var ops_ours = diff_lines(base, ours)
    var ops_theirs = diff_lines(base, theirs)
    var match_ours = _equal_match_map(ops_ours, len(base))
    var match_theirs = _equal_match_map(ops_theirs, len(base))

    var out_lines = List[String]()
    var conflicts = 0
    var first_conflict_row = -1

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
        if not ours_changed and not theirs_changed:
            for k in range(b_lo, b_hi):
                out_lines.append(base[k])
        elif not ours_changed:
            for k in range(t_lo, t_hi):
                out_lines.append(theirs[k])
        elif not theirs_changed:
            for k in range(o_lo, o_hi):
                out_lines.append(ours[k])
        elif _slice_eq(ours, o_lo, o_hi, theirs, t_lo, t_hi):
            for k in range(o_lo, o_hi):
                out_lines.append(ours[k])
        else:
            if first_conflict_row < 0:
                first_conflict_row = len(out_lines)
            conflicts += 1
            out_lines.append(String("<<<<<<< ") + ours_label)
            for k in range(o_lo, o_hi):
                out_lines.append(ours[k])
            out_lines.append(String("======="))
            for k in range(t_lo, t_hi):
                out_lines.append(theirs[k])
            out_lines.append(String(">>>>>>> ") + theirs_label)
        if i < n:
            out_lines.append(base[i])
        i_prev = i
        oi_prev = oi
        ti_prev = ti
        i += 1
    return MergeResult(out_lines^, conflicts, first_conflict_row)
