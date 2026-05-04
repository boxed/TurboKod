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
