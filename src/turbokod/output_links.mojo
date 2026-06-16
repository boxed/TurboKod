"""Clickable file:line link detection for output panes.

Both the debug/run pane (``debug_pane.mojo``, ``TextLog``-backed) and the
test pane (``test_pane.mojo``, ``Vt``-backed) scan their output lines for
navigable spans — Python tracebacks (``File "<path>", line N``) and the bare
``<path>:<N>`` form (pytest / compilers / linters). The scanners are pure
String→spans functions with no rendering dependency, so they live here and
both panes overlay the results onto whatever grid they paint into.

``cell_start`` / ``cell_end`` are codepoint counts from the start of the
line, matching how ``Canvas.put_text`` advances columns — callers convert
directly to screen X without redoing the UTF-8 walk.
"""

from std.collections.list import List

from .string_utils import char_width, codepoint_at


@fieldwise_init
struct OutputLink(ImplicitlyCopyable, Movable):
    """One clickable file:line span painted into an output surface.

    Populated by a pane's ``paint`` whenever a recognized pattern appears
    in a visible line, and consumed by ``handle_mouse`` to map a click back
    to a file-open intent. The rect is in absolute screen coordinates so
    the click test doesn't need to know about the pane's own origin.
    """
    var y: Int
    var x_start: Int
    var x_end: Int     # exclusive
    var path: String
    var line: Int      # 1-based; matches Python traceback convention


@fieldwise_init
struct LinkHit(ImplicitlyCopyable, Movable):
    """Bytes-resolved match for a single link occurrence. ``cell_start`` /
    ``cell_end`` are codepoint counts from the start of the line, matching
    how ``Canvas.put_text`` advances columns — so callers can convert
    directly to screen X without redoing the UTF-8 walk."""
    var cell_start: Int
    var cell_end: Int    # exclusive
    var path: String
    var line: Int        # 1-based


def extract_python_traceback_links(line: String) -> List[LinkHit]:
    """Find every ``File "<path>", line <N>`` span in ``line``.

    Matches Python's traceback format. The trailing ``, in <name>`` is
    optional — the link covers ``File "<path>", line <N>`` itself,
    leaving any ``in module`` suffix unhighlighted so the visual focus
    is on the navigable part. Quoted paths only (no shell-escape
    handling); a literal ``"`` in a path would terminate the match
    early, which is fine for ~all real-world paths.
    """
    var out = List[LinkHit]()
    var bytes = line.as_bytes()
    var n = len(bytes)
    # Walk byte-by-byte, tracking the parallel codepoint count so we
    # can hand callers cell offsets directly. Continuation bytes
    # (10xx_xxxx) don't bump the cell counter.
    var i = 0
    var cell = 0
    while i < n:
        var b = Int(bytes[i])
        # Probe for the literal ``File "`` prefix on a codepoint
        # boundary. Always ASCII, so a byte compare is correct here.
        if b == 0x46 and i + 6 <= n \
                and bytes[i + 1] == 0x69 \
                and bytes[i + 2] == 0x6C \
                and bytes[i + 3] == 0x65 \
                and bytes[i + 4] == 0x20 \
                and bytes[i + 5] == 0x22:
            var match_start_cell = cell
            var p = i + 6
            var path_byte_start = p
            # Path runs until the next ``"``. Track cells alongside
            # bytes so the closing quote's cell offset is correct
            # even when the path contains multibyte characters.
            var path_cell_count = 0
            var found_quote = False
            while p < n:
                var pb = Int(bytes[p])
                if pb == 0x22:
                    found_quote = True
                    break
                if (pb & 0xC0) != 0x80:
                    path_cell_count += char_width(codepoint_at(line, p)[0])
                p += 1
            if not found_quote:
                # Drop out — no recognizable link starts here.
                cell += 1
                i += 1
                continue
            var path_byte_end = p
            # Past the closing quote.
            p += 1
            # Need exactly ``, line ``.
            if p + 7 > n \
                    or bytes[p] != 0x2C \
                    or bytes[p + 1] != 0x20 \
                    or bytes[p + 2] != 0x6C \
                    or bytes[p + 3] != 0x69 \
                    or bytes[p + 4] != 0x6E \
                    or bytes[p + 5] != 0x65 \
                    or bytes[p + 6] != 0x20:
                cell += 1
                i += 1
                continue
            p += 7
            # One or more ASCII digits — the line number.
            var digit_start = p
            var line_no = 0
            while p < n:
                var db = Int(bytes[p])
                if db >= 0x30 and db <= 0x39:
                    line_no = line_no * 10 + (db - 0x30)
                    p += 1
                else:
                    break
            if p == digit_start:
                cell += 1
                i += 1
                continue
            # Slice the path text out without re-decoding.
            var path = String(StringSlice(
                ptr=bytes.unsafe_ptr() + path_byte_start,
                length=path_byte_end - path_byte_start,
            ))
            # Cell offsets: prefix ``File "`` is 6 cells (all ASCII),
            # then the path, the closing ``"``, then ``, line `` (7
            # cells), then digit_count cells.
            var digit_count = p - digit_start
            var span_cells = 6 + path_cell_count + 1 + 7 + digit_count
            out.append(LinkHit(
                match_start_cell, match_start_cell + span_cells,
                path, line_no,
            ))
            # Advance past the matched span. We've already moved ``p``
            # to the byte after the last digit; sync ``cell`` to the
            # span end (every byte we consumed in the suffix was ASCII
            # except the path body, whose cell count we tracked).
            cell = match_start_cell + span_cells
            i = p
            continue
        # Default advance: one cell per narrow glyph, two for emoji,
        # counted only on UTF-8 leader bytes.
        if (b & 0xC0) != 0x80:
            cell += char_width(codepoint_at(line, i)[0])
        i += 1
    return out^


def _is_path_byte(b: Int) -> Bool:
    """Bytes that may appear inside a bare file path token. Any
    non-ASCII byte (UTF-8 leader or continuation) is allowed so unicode
    filenames survive; the ASCII set is letters, digits, and the handful
    of path punctuation characters that don't act as delimiters."""
    if b >= 0x80:
        return True
    # 0-9
    if b >= 0x30 and b <= 0x39:
        return True
    # A-Z
    if b >= 0x41 and b <= 0x5A:
        return True
    # a-z
    if b >= 0x61 and b <= 0x7A:
        return True
    # . _ - / ~ +
    return b == 0x2E or b == 0x5F or b == 0x2D or b == 0x2F \
        or b == 0x7E or b == 0x2B


def extract_path_line_links(line: String) -> List[LinkHit]:
    """Find every bare ``<path>:<N>`` span in ``line`` — the pytest /
    compiler convention (e.g. ``iommi/declarative/dispatch.py:123``).

    Heuristics keep this from underlining every ``host:port`` or
    ``HH:MM``: the path token must contain a dot whose trailing
    extension is 1–8 ASCII alphanumerics, and must not contain ``//``
    (which would be a URL). The link covers ``<path>:<N>`` only — a
    trailing ``:<col>`` is left for the next scan and never matches
    (the ``col`` token has no extension). Good enough for ~all real
    pytest / lint / grep output.
    """
    var out = List[LinkHit]()
    var bytes = line.as_bytes()
    var n = len(bytes)
    var i = 0
    var cell = 0
    # Current path-token state, or tok_start_byte < 0 when between
    # tokens. Cells are tracked alongside bytes so a multibyte filename
    # still yields correct screen offsets.
    var tok_start_byte = -1
    var tok_start_cell = 0
    var tok_has_dot = False
    var tok_last_dot_byte = -1
    var tok_double_slash = False
    var tok_prev_slash = False
    while i < n:
        var b = Int(bytes[i])
        if _is_path_byte(b):
            if tok_start_byte < 0:
                tok_start_byte = i
                tok_start_cell = cell
                tok_has_dot = False
                tok_last_dot_byte = -1
                tok_double_slash = False
                tok_prev_slash = False
            if b == 0x2E:  # '.'
                tok_has_dot = True
                tok_last_dot_byte = i
            if b == 0x2F:  # '/'
                if tok_prev_slash:
                    tok_double_slash = True
                tok_prev_slash = True
            else:
                tok_prev_slash = False
            if (b & 0xC0) != 0x80:
                cell += char_width(codepoint_at(line, i)[0])
            i += 1
            continue
        if b == 0x3A and tok_start_byte >= 0:  # ':'
            var tok_end_byte = i
            # Extension after the last dot: 1..8 ASCII alphanumerics.
            var ext_ok = False
            if tok_has_dot and not tok_double_slash \
                    and tok_last_dot_byte + 1 < tok_end_byte:
                var ext_len = tok_end_byte - (tok_last_dot_byte + 1)
                if ext_len >= 1 and ext_len <= 8:
                    ext_ok = True
                    for e in range(tok_last_dot_byte + 1, tok_end_byte):
                        var eb = Int(bytes[e])
                        var is_alnum = (eb >= 0x30 and eb <= 0x39) \
                            or (eb >= 0x41 and eb <= 0x5A) \
                            or (eb >= 0x61 and eb <= 0x7A)
                        if not is_alnum:
                            ext_ok = False
                            break
            if ext_ok:
                # Parse the line number after the colon.
                var p = i + 1
                var digit_start = p
                var line_no = 0
                while p < n:
                    var db = Int(bytes[p])
                    if db >= 0x30 and db <= 0x39:
                        line_no = line_no * 10 + (db - 0x30)
                        p += 1
                    else:
                        break
                if p > digit_start:
                    var path = String(StringSlice(
                        ptr=bytes.unsafe_ptr() + tok_start_byte,
                        length=tok_end_byte - tok_start_byte,
                    ))
                    # ``cell`` sits on the colon. Span = colon (1) plus
                    # the digits (all ASCII, one cell each).
                    var digit_count = p - digit_start
                    var span_end_cell = cell + 1 + digit_count
                    out.append(LinkHit(
                        tok_start_cell, span_end_cell, path, line_no,
                    ))
                    cell = span_end_cell
                    i = p
                    tok_start_byte = -1
                    continue
            # Colon that didn't complete a link ends the token.
            tok_start_byte = -1
            cell += 1
            i += 1
            continue
        # Any other byte ends the current token.
        tok_start_byte = -1
        if (b & 0xC0) != 0x80:
            cell += char_width(codepoint_at(line, i)[0])
        i += 1
    return out^
