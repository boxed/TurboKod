"""Tiny byte-level string helpers shared across modules.

These exist because we deliberately work in ``as_bytes()`` slices for
ASCII-prefix / digit / line-split work — the byte-wise form is faster
than a codepoint walk and avoids depending on whichever ``String`` API
shape ships in the current Mojo. Keeping all the duplicates in one
place stops them from drifting (the editorconfig copy used to differ
from the desktop copy by exactly one ``<`` vs. ``<=`` in a bounds check).
"""

from std.collections.list import List


fn starts_with(s: String, prefix: String) -> Bool:
    """``True`` iff ``s`` begins with ``prefix`` byte-for-byte."""
    var sb = s.as_bytes()
    var pb = prefix.as_bytes()
    if len(pb) > len(sb):
        return False
    for i in range(len(pb)):
        if sb[i] != pb[i]:
            return False
    return True


fn split_lines(text: String) -> List[String]:
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


fn split_lines_no_trailing(text: String) -> List[String]:
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


fn parse_int_all(s: String) -> Int:
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


fn codepoint_at(s: String, col: Int) -> Tuple[Int, Int]:
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


fn is_word_codepoint(cp: Int) -> Bool:
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


fn word_char_step(s: String, col: Int) -> Tuple[Bool, Int]:
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


fn prev_codepoint_start(s: String, col: Int) -> Int:
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


fn parse_int_prefix(s: String, start: Int, stop: Int) -> Int:
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
