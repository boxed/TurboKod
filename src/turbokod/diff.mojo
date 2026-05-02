"""Line-level Myers diff + unified-diff renderer.

Used by the editor's "Compare selection with clipboard" feature. The
algorithm is the classic Myers O((N+M)D) shortest-edit-script with the
forward V-array; trace-back is reconstructed from snapshots of V at each
``d``. We don't need the linear-space refinement — clipboard / selection
inputs are at most a few thousand lines, where the snapshot approach
(O(D·(N+M)) memory) is comfortable.

Output is GNU-style unified diff with three lines of context, including
``@@ -l,c +l,c @@`` hunk headers and ``--- ``/``+++ `` file labels.
"""

from std.collections.list import List


fn _split_lines(text: String) -> List[String]:
    """Split on ``\\n``. A trailing newline produces an empty final line,
    matching ``TextBuffer``'s convention; the unified-diff hunk-header
    line counts assume the same convention."""
    var out = List[String]()
    var bytes = text.as_bytes()
    var start = 0
    var i = 0
    while i < len(bytes):
        if bytes[i] == 0x0A:
            out.append(String(StringSlice(unsafe_from_utf8=bytes[start:i])))
            start = i + 1
        i += 1
    out.append(String(StringSlice(unsafe_from_utf8=bytes[start:len(bytes)])))
    return out^


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
    var a_lines = _split_lines(a)
    var b_lines = _split_lines(b)
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
