"""Tiny byte-level string helpers shared across modules.

These exist because we deliberately work in ``as_bytes()`` slices for
ASCII-prefix / digit / line-split work — the byte-wise form is faster
than a codepoint walk and avoids depending on whichever ``String`` API
shape ships in the current Mojo. Keeping all the duplicates in one
place stops them from drifting (the editorconfig copy used to differ
from the desktop copy by exactly one ``<`` vs. ``<=`` in a bounds check).
"""

from std.collections.list import List


def starts_with(s: String, prefix: String) -> Bool:
    """``True`` iff ``s`` begins with ``prefix`` byte-for-byte."""
    var sb = s.as_bytes()
    var pb = prefix.as_bytes()
    if len(pb) > len(sb):
        return False
    for i in range(len(pb)):
        if sb[i] != pb[i]:
            return False
    return True


def split_lines(text: String) -> List[String]:
    """Split on ``\\n``, keeping a final empty entry when ``text`` ends
    with a newline. This matches ``TextBuffer``'s "trailing newline →
    empty final line" convention used by the diff renderer and most of
    the editor surface."""
    var out = List[String]()
    var b = text.as_bytes()
    var start = 0
    var i = 0
    while i < len(b):
        if b[i] == 0x0A:
            out.append(String(StringSlice(unsafe_from_utf8=b[start:i])))
            start = i + 1
        i += 1
    out.append(String(StringSlice(unsafe_from_utf8=b[start:len(b)])))
    return out^


def split_lines_no_trailing(text: String) -> List[String]:
    """Split on ``\\n``, dropping a trailing-newline-only empty line.
    Use for line-oriented external command output (``git`` porcelain,
    ``ls``-style) where every record is newline-terminated and a phantom
    blank entry at the end is undesirable."""
    var out = List[String]()
    var b = text.as_bytes()
    var s = 0
    for i in range(len(b)):
        if b[i] == 0x0A:
            out.append(String(StringSlice(unsafe_from_utf8=b[s:i])))
            s = i + 1
    if s < len(b):
        out.append(String(StringSlice(unsafe_from_utf8=b[s:len(b)])))
    return out^


def shell_escape_path(path: String) -> String:
    """Backslash-escape the shell-significant ASCII characters in ``path`` so a
    file path dragged onto a terminal pane reaches the program running there
    intact — the same transformation a terminal emulator applies on
    drag-to-insert. Only the ASCII metacharacters are escaped; multi-byte
    UTF-8 bytes (>= 0x80) pass through untouched."""
    var specials = String(" \t\n\\'\"`$()[]{}<>|;&#*?!~").as_bytes()
    var b = path.as_bytes()
    var out = List[UInt8]()
    for i in range(len(b)):
        var special = False
        for j in range(len(specials)):
            if specials[j] == b[i]:
                special = True
                break
        if special:
            out.append(0x5C)  # backslash
        out.append(b[i])
    return String(StringSlice(unsafe_from_utf8=Span(out)))


def escape_drop_paths(paths: String) -> String:
    """Turn a newline-separated list of dropped file paths into the text a
    terminal pane should receive: each path shell-escaped (``shell_escape_path``),
    joined by single spaces, with a trailing space — matching a terminal
    emulator's drop, which leaves the cursor ready for the next token. Blank
    entries are skipped; an all-blank input yields the empty string."""
    var out = String("")
    var lines = split_lines_no_trailing(paths)
    for ref p in lines:
        if len(p.as_bytes()) == 0:
            continue
        if len(out.as_bytes()) > 0:
            out += " "
        out += shell_escape_path(p)
    if len(out.as_bytes()) > 0:
        out += " "
    return out


def char_width(cp: Int) -> Int:
    """Terminal columns a single codepoint occupies: ``2`` for emoji that
    terminals and our Swift host render double-wide, ``1`` for everything
    else.

    This is the single source of truth for cell width. Every loop that
    converts between a byte/codepoint position and a screen column — in
    ``Canvas.put_text``, the soft-wrap segmenter, the editor's
    byte↔cell converters, the overlay cell maps, and the Swift renderer
    (which ports the same ranges) — funnels through it, so the layout
    the editor reasons about always matches what is painted.

    The wide set is the standard ``wcwidth`` "wide emoji" table — the
    blocks where most terminal emulators advance the cursor by two. We
    deliberately leave a few things at width 1 to *agree* with terminals
    rather than be maximally pretty: regional-indicator letters
    (``0x1F1E6..0x1F1FF``) stay 1 so a two-codepoint flag reserves two
    cells total instead of four, and East-Asian fullwidth / combining
    marks are still unmodeled (a known limitation, see ``CLAUDE.md``)."""
    # Fast path: everything below the first wide codepoint (all ASCII,
    # Latin, Cyrillic, CJK punctuation up to the angle brackets, …) is
    # one cell.
    if cp < 0x231A:
        return 1
    # --- BMP emoji that render wide ---
    if cp == 0x231A or cp == 0x231B:
        return 2
    if cp == 0x2329 or cp == 0x232A:
        return 2
    if 0x23E9 <= cp and cp <= 0x23EC:
        return 2
    if cp == 0x23F0 or cp == 0x23F3:
        return 2
    if cp == 0x25FD or cp == 0x25FE:
        return 2
    if cp == 0x2614 or cp == 0x2615:
        return 2
    if 0x2648 <= cp and cp <= 0x2653:
        return 2
    if cp == 0x267F:
        return 2
    if cp == 0x2693:
        return 2
    if cp == 0x26A1:
        return 2
    if cp == 0x26AA or cp == 0x26AB:
        return 2
    if cp == 0x26BD or cp == 0x26BE:
        return 2
    if cp == 0x26C4 or cp == 0x26C5:
        return 2
    if cp == 0x26CE:
        return 2
    if cp == 0x26D4:
        return 2
    if cp == 0x26EA:
        return 2
    if cp == 0x26F2 or cp == 0x26F3:
        return 2
    if cp == 0x26F5:
        return 2
    if cp == 0x26FA:
        return 2
    if cp == 0x26FD:
        return 2
    if cp == 0x2705:
        return 2
    if cp == 0x270A or cp == 0x270B:
        return 2
    if cp == 0x2728:
        return 2
    if cp == 0x274C:
        return 2
    if cp == 0x274E:
        return 2
    if 0x2753 <= cp and cp <= 0x2755:
        return 2
    if cp == 0x2757:
        return 2
    if 0x2795 <= cp and cp <= 0x2797:
        return 2
    if cp == 0x27B0:
        return 2
    if cp == 0x27BF:
        return 2
    if cp == 0x2B1B or cp == 0x2B1C:
        return 2
    if cp == 0x2B50:
        return 2
    if cp == 0x2B55:
        return 2
    # --- SMP emoji blocks that render wide ---
    if cp == 0x1F004:
        return 2
    if cp == 0x1F0CF:
        return 2
    if cp == 0x1F18E:
        return 2
    if 0x1F191 <= cp and cp <= 0x1F19A:
        return 2
    if 0x1F200 <= cp and cp <= 0x1F2FF:
        return 2
    if 0x1F300 <= cp and cp <= 0x1F64F:
        return 2
    if 0x1F680 <= cp and cp <= 0x1F6FF:
        return 2
    if 0x1F900 <= cp and cp <= 0x1F9FF:
        return 2
    if 0x1FA70 <= cp and cp <= 0x1FAFF:
        return 2
    return 1


def display_columns(s: String) -> Int:
    """Count terminal cells ``s`` occupies when painted by
    ``Canvas.put_text`` — emoji count 2, everything else 1 (see
    ``char_width``).

    Use this (not ``len(s.as_bytes())``) anywhere the result is fed
    into layout: dropdown widths, title-bar offsets, status-bar
    right-alignment, ``put_text`` start positions computed by
    subtracting label width from a right edge. Byte length over-counts
    multi-byte glyphs (an em dash adds 3, ``ä`` adds 2), which used to
    reserve too many cells for non-ASCII labels and — in the menu's
    per-byte paint loop — emit one cell per continuation byte.

    East-Asian fullwidth is still not modeled (only emoji are
    double-width), so wide CJK glyphs still over-advance by one cell."""
    var b = s.as_bytes()
    var n = len(b)
    var i = 0
    var cols = 0
    while i < n:
        var info = codepoint_at(s, i)
        cols += char_width(info[0])
        i += info[1]
    return cols


def truncate_to_columns(s: String, max_cols: Int) -> String:
    """Longest codepoint-aligned *prefix* of ``s`` that fits in ``max_cols``
    display columns (``char_width``).

    Use this instead of slicing ``as_bytes()`` at a column offset: byte
    slicing over-counts multi-byte glyphs (so a label that would fit gets
    truncated early) and can cut mid-codepoint, producing invalid UTF-8 when
    the fragment is handed to ``StringSlice(unsafe_from_utf8=...)``. Returns
    ``""`` for ``max_cols <= 0`` and ``s`` unchanged when it already fits."""
    if max_cols <= 0:
        return String("")
    var b = s.as_bytes()
    var n = len(b)
    var cols = 0
    var i = 0
    while i < n:
        var info = codepoint_at(s, i)
        var w = char_width(info[0])
        if cols + w > max_cols:
            break
        cols += w
        i += info[1]
    if i >= n:
        return s
    return String(StringSlice(ptr=b.unsafe_ptr(), length=i))


def tail_to_columns(s: String, max_cols: Int) -> String:
    """Longest codepoint-aligned *suffix* of ``s`` that fits in ``max_cols``
    display columns.

    The right-aligned-truncation counterpart of ``truncate_to_columns``: use
    for paths and branch names shown with the tail visible, instead of a raw
    ``start = len(bytes) - max_cols`` byte offset (which over-counts wide
    glyphs and can slice mid-codepoint). Returns ``""`` for ``max_cols <= 0``
    and ``s`` unchanged when it already fits."""
    if max_cols <= 0:
        return String("")
    var b = s.as_bytes()
    var n = len(b)
    var total = display_columns(s)
    if total <= max_cols:
        return s
    var i = 0
    while i < n and total > max_cols:
        var info = codepoint_at(s, i)
        total -= char_width(info[0])
        i += info[1]
    return String(StringSlice(ptr=b.unsafe_ptr() + i, length=n - i))


def parse_int_all(s: String) -> Int:
    """Parse ``s`` as a non-negative decimal; return ``-1`` if any byte
    isn't a digit or the string is empty."""
    var b = s.as_bytes()
    if len(b) == 0:
        return -1
    var n = 0
    for i in range(len(b)):
        var c = Int(b[i])
        if c < 0x30 or c > 0x39:
            return -1
        n = n * 10 + (c - 0x30)
    return n


def codepoint_at(s: String, col: Int) -> Tuple[Int, Int]:
    """Decode one UTF-8 codepoint at byte ``col`` in ``s``.

    Returns ``(codepoint, byte_size)``. Past-EOL or truncated UTF-8
    returns ``(0, 1)`` so callers can advance one byte and try again
    rather than looping forever on malformed input."""
    var b = s.as_bytes()
    var n = len(b)
    if col < 0 or col >= n:
        return (0, 1)
    var c = Int(b[col])
    if c < 0x80:
        return (c, 1)
    var size = 1
    if (c & 0xE0) == 0xC0:
        size = 2
    elif (c & 0xF0) == 0xE0:
        size = 3
    elif (c & 0xF8) == 0xF0:
        size = 4
    if size == 1 or col + size > n:
        return (c, 1)
    # Validate the expected continuation bytes. A malformed sequence decodes
    # as the lead byte alone (advance 1) rather than masking garbage and
    # swallowing the following valid bytes, which would skew the cell↔byte map.
    for k in range(1, size):
        if (Int(b[col + k]) & 0xC0) != 0x80:
            return (c, 1)
    if size == 2:
        return (((c & 0x1F) << 6) | (Int(b[col + 1]) & 0x3F), 2)
    if size == 3:
        return (
            ((c & 0x0F) << 12)
            | ((Int(b[col + 1]) & 0x3F) << 6)
            | (Int(b[col + 2]) & 0x3F),
            3,
        )
    return (
        ((c & 0x07) << 18)
        | ((Int(b[col + 1]) & 0x3F) << 12)
        | ((Int(b[col + 2]) & 0x3F) << 6)
        | (Int(b[col + 3]) & 0x3F),
        4,
    )


def is_word_codepoint(cp: Int) -> Bool:
    """``True`` if ``cp`` should be treated as part of a word — for
    word-left/right movement, double-click selection, and spell-check
    tokenization. The three sites used to each have their own ASCII-only
    check, which split ``Godkänn`` into ``Godk``/``ä``/``nn`` because
    ``ä`` is two non-letter UTF-8 bytes; this helper unifies them on a
    pragmatic Unicode-letter set.

    Includes:

    * ASCII alphanumeric and underscore.
    * Latin-1 letters (À-ÿ, skipping ``×`` and ``÷``).
    * Latin Extended-A/B and IPA (0x100–0x2AF).
    * Greek (0x370–0x3FF), Cyrillic (0x400–0x4FF).
    * The bulk of the BMP letter range — Armenian / Hebrew / Arabic /
      Devanagari / Thai / Georgian / etc. (0x500–0x1FFF).
    * Hiragana, Katakana, CJK ideographs, Hangul (0x3040–0xD7AF) and
      CJK compatibility ideographs (0xF900–0xFAFF).

    Excluded: Latin-1 punctuation (¡-¿), math signs, NBSP, the rest of
    the BMP symbol/punctuation blocks, and everything in the SMP
    (emoji, less common scripts) — the SMP exclusion makes word
    boundaries break around emoji, which is what users expect."""
    if cp == 0x5F:
        return True
    if 0x30 <= cp and cp <= 0x39:
        return True
    if 0x41 <= cp and cp <= 0x5A:
        return True
    if 0x61 <= cp and cp <= 0x7A:
        return True
    if 0xC0 <= cp and cp <= 0xFF:
        return cp != 0xD7 and cp != 0xF7
    if 0x100 <= cp and cp <= 0x2AF:
        return True
    if 0x370 <= cp and cp <= 0x3FF:
        return True
    if 0x400 <= cp and cp <= 0x4FF:
        return True
    if 0x500 <= cp and cp <= 0x1FFF:
        return True
    if 0x3040 <= cp and cp <= 0xD7AF:
        return True
    if 0xF900 <= cp and cp <= 0xFAFF:
        return True
    return False


def word_char_step(s: String, col: Int) -> Tuple[Bool, Int]:
    """``(is_word_char, byte_advance)`` for the codepoint at byte ``col``.

    advance is the UTF-8 byte length of the codepoint, so callers walk
    a byte array one codepoint at a time:

    .. code-block:: mojo

        var c = col
        while c < n:
            var step = word_char_step(line, c)
            if not step[0]: break
            c += step[1]

    Past-EOL or invalid UTF-8 returns ``(False, 1)`` so a broken
    sequence advances one byte and the loop terminates."""
    var info = codepoint_at(s, col)
    return (is_word_codepoint(info[0]), info[1])


def prev_codepoint_start(s: String, col: Int) -> Int:
    """Byte offset of the codepoint that ends at ``col``. Use to walk
    a byte array backwards one codepoint at a time. ``col == 0`` returns
    ``0``."""
    if col <= 0:
        return 0
    var b = s.as_bytes()
    var c = col - 1
    while c > 0 and (Int(b[c]) & 0xC0) == 0x80:
        c -= 1
    return c


def utf8_cell_of_byte(line: String, byte_col: Int) -> Int:
    """Cell column for byte offset ``byte_col`` in ``line``. Emoji advance
    two cells (``char_width``); past-EOL bytes consume one virtual cell each
    so cursors parked to the right of the last character stay distinguishable
    in vertical-movement bookkeeping."""
    if byte_col <= 0:
        return 0
    var bytes = line.as_bytes()
    var n = len(bytes)
    var cell = 0
    var i = 0
    while i < n and i < byte_col:
        var info = codepoint_at(line, i)
        cell += char_width(info[0])
        i += info[1]
    if byte_col > n:
        cell += byte_col - n
    return cell


def utf8_byte_of_cell(line: String, cell_col: Int) -> Int:
    """Byte offset of the codepoint at cell column ``cell_col`` in ``line``,
    clamped to ``len(line)``. Used to translate a remembered cell column from
    one row to another during vertical movement. When ``cell_col`` lands on
    the right half of a wide (emoji) glyph there is no codepoint to point at,
    so we snap to the start of that glyph."""
    if cell_col <= 0:
        return 0
    var bytes = line.as_bytes()
    var n = len(bytes)
    var cell = 0
    var i = 0
    while i < n and cell < cell_col:
        var info = codepoint_at(line, i)
        var w = char_width(info[0])
        if cell + w > cell_col:
            # ``cell_col`` falls inside this wide glyph — snap to its start.
            break
        cell += w
        i += info[1]
    return i


def char_class(cp: Int) -> Int:
    """Three-way character class used by ``word_range_at``. Word chars
    cluster, whitespace clusters, everything else clusters as "punctuation"
    — so a double-click on punctuation selects the run of punctuation, not
    just the single byte. Operates on a codepoint (not a byte) so non-ASCII
    letters cluster correctly with their ASCII neighbors (``ä`` and ``n``
    end up in the same word)."""
    if is_word_codepoint(cp):
        return 1
    if cp == 0x20 or cp == 0x09:
        return 2
    return 3


def word_range_at(line: String, col: Int) -> Tuple[Int, Int]:
    """Return the (start, end) byte range of the contiguous run of the same
    character class around ``col``. Empty range when ``col`` is at or past
    end of line. Walks by UTF-8 codepoint so a multibyte letter (``ä``)
    groups with its ASCII neighbors instead of breaking the selection in
    the middle of the codepoint."""
    var bytes = line.as_bytes()
    var n = len(bytes)
    if col < 0 or col >= n:
        return (col, col)
    var here = codepoint_at(line, col)
    var cls = char_class(here[0])
    var start = col
    while start > 0:
        var prev = prev_codepoint_start(line, start)
        var info = codepoint_at(line, prev)
        if char_class(info[0]) != cls:
            break
        start = prev
    var end = col + here[1]
    while end < n:
        var info = codepoint_at(line, end)
        if char_class(info[0]) != cls:
            break
        end += info[1]
    return (start, end)


def utf8_codepoint_size(b: Int) -> Int:
    """Byte length of a UTF-8 codepoint with lead byte ``b``. Returns 1
    on invalid leads / continuation bytes so a stray byte never traps a
    walker in an infinite no-op loop. Single source for both editor
    cursor stepping and ``text_view`` soft-wrap segmentation."""
    if b < 0x80:
        return 1
    if (b & 0xE0) == 0xC0:
        return 2
    if (b & 0xF0) == 0xE0:
        return 3
    if (b & 0xF8) == 0xF0:
        return 4
    return 1


def leading_indent_bytes(line: String) -> Int:
    """Byte count of leading ASCII spaces and tabs. Each space/tab
    counts as one byte under the editor's byte-as-cell column model,
    so the return is also the leading-whitespace cell width. Used by
    soft-wrap to compute hanging indent and by the editor's
    smart-indent paths to copy a parent line's indentation."""
    var bytes = line.as_bytes()
    var i = 0
    while i < len(bytes) and (bytes[i] == 0x20 or bytes[i] == 0x09):
        i += 1
    return i


def slice_codepoints(s: String, lo_cell: Int, hi_cell: Int) -> String:
    """Substring of ``s`` covering codepoints ``[lo_cell, hi_cell)``.

    Cells correspond to codepoints under ``Canvas.put_text``'s layout —
    one cell per codepoint, no East-Asian width handling. Tolerates
    out-of-range bounds by clamping (``hi_cell`` past the last
    codepoint truncates to the end; negative ``lo_cell`` starts at 0).
    Returns an empty string when ``hi_cell <= lo_cell`` or ``s`` is
    empty.
    """
    if hi_cell <= lo_cell:
        return String("")
    var bytes = s.as_bytes()
    var n = len(bytes)
    if n == 0:
        return String("")
    var lo = lo_cell
    if lo < 0:
        lo = 0
    var cell = 0
    var byte_lo = 0
    var byte_hi = n
    var found_lo = (lo == 0)
    var i = 0
    while i < n:
        var b = Int(bytes[i])
        var seq_len = utf8_codepoint_size(b)
        if i + seq_len > n:
            seq_len = 1
        if not found_lo and cell == lo:
            byte_lo = i
            found_lo = True
        if cell == hi_cell:
            byte_hi = i
            break
        cell += 1
        i += seq_len
    if not found_lo:
        return String("")
    if byte_hi <= byte_lo:
        return String("")
    return String(StringSlice(
        ptr=bytes.unsafe_ptr() + byte_lo, length=byte_hi - byte_lo,
    ))


def parse_int_prefix(s: String, start: Int, stop: Int) -> Int:
    """Parse digits in ``s[start:stop]`` until the first non-digit (or
    ``stop``). Returns ``-1`` when ``start`` is already past a non-digit
    so callers can distinguish "no number" from "number that happens to
    be 0"."""
    var b = s.as_bytes()
    var i = start
    var n = 0
    var saw = False
    while i < stop and i < len(b):
        var c = Int(b[i])
        if c < 0x30 or c > 0x39:
            break
        n = n * 10 + (c - 0x30)
        saw = True
        i += 1
    if not saw:
        return -1
    return n
