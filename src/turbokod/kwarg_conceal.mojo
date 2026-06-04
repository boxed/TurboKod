"""Display-time "soft compress" of redundant keyword arguments.

In Python/Mojo it's idiomatic to forward locals by name — ``foo(a=a, b=b,
c=c, d=4)`` — and the ``name=name`` repetition is pure visual noise. When the
editor option is on, lines that don't hold the caret render the redundant
labels concealed and the separator repainted as ``≡`` (identical-to, U+2261)
so it reads as "value is its own name" rather than a half-finished assignment:
``foo(≡a, ≡b, ≡c, d=4)``. Swift collapses ``foo(a: a)`` → ``foo(≡ a)`` the same
way.

This module is pure data (no TTY / AppKit) so it's unit-testable directly:

* ``kwarg_separator_for_extension`` — which separator (if any) a language uses.
* ``kwarg_conceal_ranges`` — byte ranges of a line to hide.
* ``build_concealed_segment`` — turn a visible byte-slice + its hide ranges
  into the painted string plus a ``byte → cell`` map (the holed analogue of
  ``utf8_byte_to_cell``), so every existing overlay pass keeps aligning.

Detection is deliberately conservative (see ``kwarg_conceal_ranges``): the
label is hidden only when it is byte-identical to a bare-identifier value, the
pair sits at ``(``-depth ≥ 1, and the bytes aren't string/comment. Statement
``x = x`` and mismatched ``foo(a=b)`` are left alone. v1 only matches pairs
that live on a single physical line.
"""

from .canvas import TAB_WIDTH
from .string_utils import char_width, codepoint_at


def _is_ident_byte(b: Int) -> Bool:
    # A-Z, a-z, 0-9, '_' or any continuation/lead byte of a multi-byte
    # UTF-8 codepoint (so Unicode identifiers compare byte-wise too).
    return (b >= 0x41 and b <= 0x5A) or (b >= 0x61 and b <= 0x7A) \
        or (b >= 0x30 and b <= 0x39) or b == 0x5F or b >= 0x80


def _is_space_byte(b: Int) -> Bool:
    return b == 0x20 or b == 0x09  # space / tab


def _in_spans(pos: Int, spans: List[Tuple[Int, Int]]) -> Bool:
    """True when ``pos`` falls inside any half-open ``[lo, hi)`` span."""
    for s in spans:
        if pos >= s[0] and pos < s[1]:
            return True
    return False


def kwarg_separator_for_extension(ext: String) -> Int:
    """Separator byte for keyword arguments, or ``-1`` when the language
    has none we compress. ``=`` for Python/Mojo, ``:`` for Swift."""
    if ext == String("py") or ext == String("pyi") or ext == String("mojo"):
        return 0x3D  # '='
    if ext == String("swift"):
        return 0x3A  # ':'
    return -1


def kwarg_conceal_ranges(
    line: String, sep_byte: Int, string_comment_spans: List[Tuple[Int, Int]],
) -> List[Tuple[Int, Int]]:
    """Byte ranges of ``line`` to hide so that ``label SEP label`` collapses
    to ``SEP label``.

    Single left-to-right pass tracking ``(`` nesting depth (only ``()`` —
    dict/list brackets are ignored so we target call arguments precisely).
    Bytes inside ``string_comment_spans`` are skipped for both paren counting
    and pattern matching. At depth ≥ 1, recognizes

        <boundary> LABEL ws* SEP ws* VALUE <boundary>

    where LABEL and VALUE are byte-identical bare identifiers, SEP is a lone
    separator (``==`` / ``::`` are rejected), the left boundary is ``(`` /
    ``,`` / whitespace and the right boundary is ``,`` / ``)`` / whitespace /
    end-of-line. Emits ``[label_start, sep_pos)`` — the label plus any
    whitespace before the separator.
    """
    var out = List[Tuple[Int, Int]]()
    if sep_byte < 0:
        return out^
    var bytes = line.as_bytes()
    var n = len(bytes)
    var depth = 0
    var i = 0
    while i < n:
        if _in_spans(i, string_comment_spans):
            i += 1
            continue
        var b = Int(bytes[i])
        if b == 0x28:  # '('
            depth += 1
            i += 1
            continue
        if b == 0x29:  # ')'
            if depth > 0:
                depth -= 1
            i += 1
            continue
        if depth < 1 or not _is_ident_byte(b):
            i += 1
            continue
        # Left boundary: walking back over any whitespace, the byte that
        # opens this argument must be '(' or ','. Rejects attribute targets
        # ("x.y="), the tail of a longer identifier, and — crucially — an
        # identifier that's only part of a larger expression, e.g. the
        # ``None`` in ``name: str | None = None`` (preceded by '|', not a
        # real keyword-argument boundary).
        if i > 0:
            var w = i - 1
            while w >= 0 and _is_space_byte(Int(bytes[w])):
                w -= 1
            if w >= 0:
                var prev = Int(bytes[w])
                if not (prev == 0x28 or prev == 0x2C):
                    # Not an argument start — skip this identifier run.
                    var s = i + 1
                    while s < n and _is_ident_byte(Int(bytes[s])):
                        s += 1
                    i = s
                    continue
        # Read the label identifier.
        var label_start = i
        var j = i
        while j < n and _is_ident_byte(Int(bytes[j])):
            j += 1
        var label_end = j
        # Skip whitespace up to the separator.
        var k = j
        while k < n and _is_space_byte(Int(bytes[k])):
            k += 1
        if k >= n or Int(bytes[k]) != sep_byte:
            i = label_end
            continue
        var sep_pos = k
        # Reject doubled separators ('==', '::').
        if k + 1 < n and Int(bytes[k + 1]) == sep_byte:
            i = k + 1
            continue
        # Skip whitespace after the separator, then read the value.
        var m = k + 1
        while m < n and _is_space_byte(Int(bytes[m])):
            m += 1
        var value_start = m
        var p = m
        while p < n and _is_ident_byte(Int(bytes[p])):
            p += 1
        var value_end = p
        if value_end == value_start:
            i = label_end
            continue
        # Right boundary: end-of-line or ',' / ')' / whitespace.
        if p < n:
            var after = Int(bytes[p])
            if not (after == 0x2C or after == 0x29 or _is_space_byte(after)):
                i = label_end
                continue
        # Identical name?
        var equal = (label_end - label_start) == (value_end - value_start)
        if equal:
            for t in range(label_end - label_start):
                if bytes[label_start + t] != bytes[value_start + t]:
                    equal = False
                    break
        if equal:
            out.append((label_start, sep_pos))
            i = value_end
            continue
        i = label_end
    return out^


def _byte_slice(s: String, lo: Int, hi: Int) -> String:
    if hi <= lo:
        return String("")
    var bytes = s.as_bytes()
    return String(StringSlice(ptr=bytes.unsafe_ptr() + lo, length=hi - lo))


def build_concealed_segment(
    seg: String, hide_ranges: List[Tuple[Int, Int]], sep_glyph: String,
) -> Tuple[String, List[Int], Int]:
    """Render ``seg`` with ``hide_ranges`` (byte ranges, in *segment*
    coordinates) removed.

    Each hide range covers ``[label_start, sep_pos)`` — the redundant label up
    to (but not including) the separator. The single byte at ``sep_pos`` (the
    first visible byte after a hidden range) is repainted as ``sep_glyph``
    instead of the literal ``=`` / ``:`` — pass ``"≡"`` to get the
    identical-to marker, or ``""`` to keep the original separator byte.

    Returns ``(display, byte_to_cell, cell_count)``. ``byte_to_cell`` has one
    entry per byte of ``seg`` (matching ``utf8_byte_to_cell``'s contract) so
    overlay passes can index it by raw buffer byte: hidden bytes collapse to
    the current display cell (zero width), visible codepoints advance it. The
    separator byte keeps its single ``byte_to_cell`` entry and advances one
    cell even though ``sep_glyph`` may be multi-byte (``≡`` is 3 UTF-8 bytes,
    one cell). ``cell_count`` is the cell just past the last glyph — the value
    overlays use when a span reaches end-of-segment.
    """
    var bytes = seg.as_bytes()
    var n = len(bytes)
    var byte_to_cell = List[Int]()
    var disp = List[UInt8]()
    var sep_bytes = sep_glyph.as_bytes()
    var cell = 0
    var i = 0
    var prev_hidden = False
    while i < n:
        if _in_spans(i, hide_ranges):
            byte_to_cell.append(cell)  # collapsed — no glyph, no advance
            i += 1
            prev_hidden = True
            continue
        # The first visible byte after a concealed label is the separator;
        # repaint it as the distinct marker (one cell, possibly multi-byte).
        if prev_hidden and len(sep_bytes) > 0:
            byte_to_cell.append(cell)
            for sb in range(len(sep_bytes)):
                disp.append(sep_bytes[sb])
            cell += 1
            i += 1
            prev_hidden = False
            continue
        prev_hidden = False
        var b = Int(bytes[i])
        if b == 0x09:  # tab expands to the next TAB_WIDTH boundary
            byte_to_cell.append(cell)
            disp.append(bytes[i])
            cell += TAB_WIDTH - (cell % TAB_WIDTH)
            i += 1
            continue
        var seq_len: Int
        if b < 0x80:
            seq_len = 1
        elif (b & 0xE0) == 0xC0:
            seq_len = 2
        elif (b & 0xF0) == 0xE0:
            seq_len = 3
        elif (b & 0xF8) == 0xF0:
            seq_len = 4
        else:
            seq_len = 1
        if i + seq_len > n:
            seq_len = n - i
        var glyph_start = i
        for _ in range(seq_len):
            byte_to_cell.append(cell)
            disp.append(bytes[i])
            i += 1
        cell += char_width(codepoint_at(seg, glyph_start)[0])
    var display: String
    if len(disp) == 0:
        display = String("")
    else:
        display = String(StringSlice(ptr=disp.unsafe_ptr(), length=len(disp)))
    return (display, byte_to_cell^, cell)
