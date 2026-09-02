"""LSP position-encoding conversion: byte columns ↔ wire ``character``.

The editor reasons in **byte** columns (``Editor.cursor_col`` is a byte
offset into the line; see the cell↔byte converters in ``string_utils``).
LSP's ``Position.character`` is *not* a byte offset — it is an offset in
whatever unit the server and client negotiated:

* ``utf-8``  — code units are bytes. Identity; nothing to convert.
* ``utf-16`` — the **spec default**, and what every server that predates
  3.17's ``general.positionEncodings`` uses. One unit per BMP codepoint,
  **two** for anything astral (emoji, rare CJK, math alphanumerics).
* ``utf-32`` — one unit per codepoint.

Why this module exists: we advertise ``utf-8`` first in
``general.positionEncodings`` (``lsp.mojo``), but that is a *request*, not
a guarantee. A server that never implemented 3.17 capability negotiation
silently keeps ``utf-16``, and then every column we send or receive for a
line containing non-ASCII is off by the byte-vs-unit delta — an em dash in
a comment is 3 bytes but 1 UTF-16 unit, so a hover two tokens after it
asks the server about the wrong identifier, a diagnostic underlines the
wrong span, and a rename ``TextEdit`` splices at the wrong offset and
corrupts the line. Before this module the negotiated encoding was stashed
and *logged* and nothing else — correct only against the subset of servers
that honored the utf-8 request.

The conversion is per line, so callers need the line's text. ``LineTable``
indexes a document's line starts once so remapping a whole ``TextEdit[]``
costs one scan of the text rather than one per edit.

Clamping follows the spec: a ``character`` past the end of the line
"defaults back to the line length", and a value landing inside a
multi-byte codepoint snaps to that codepoint's start — you cannot address
half a character in either direction.
"""

from std.collections.list import List

from .string_utils import byte_slice, codepoint_at


comptime POS_UTF8  = UInt8(0)
comptime POS_UTF16 = UInt8(1)
comptime POS_UTF32 = UInt8(2)


def encoding_from_name(name: String) -> UInt8:
    """Map an LSP ``positionEncoding`` capability string to a tag.

    Unknown values fall back to ``utf-16``: that is the spec default, so
    a server answering with something we don't recognize is far more
    likely to be speaking the default than bytes."""
    if name == String("utf-8"):
        return POS_UTF8
    if name == String("utf-32"):
        return POS_UTF32
    return POS_UTF16


def encoding_name(enc: UInt8) -> String:
    if enc == POS_UTF8:
        return String("utf-8")
    if enc == POS_UTF32:
        return String("utf-32")
    return String("utf-16")


def _units_for_codepoint(cp: Int, enc: UInt8) -> Int:
    """Code units one codepoint occupies in ``enc``. UTF-16 needs a
    surrogate pair for anything outside the BMP; UTF-32 is always 1."""
    if enc == POS_UTF32:
        return 1
    if cp >= 0x10000:
        return 2
    return 1


def byte_to_units(line: String, byte_col: Int, enc: UInt8) -> Int:
    """Convert a byte column on ``line`` to a wire ``character`` offset.

    ``byte_col`` is clamped to the line length; a column landing inside a
    codepoint snaps down to that codepoint's start (its units are not
    counted) so we never report half a character."""
    if enc == POS_UTF8:
        var n8 = len(line.as_bytes())
        if byte_col < 0:
            return 0
        if byte_col > n8:
            return n8
        return byte_col
    var n = len(line.as_bytes())
    if byte_col <= 0:
        return 0
    var limit = byte_col
    if limit > n:
        limit = n
    var units = 0
    var i = 0
    while i < limit:
        var got = codepoint_at(line, i)
        var cp = got[0]
        var size = got[1]
        if i + size > limit:
            # ``byte_col`` fell inside this codepoint — snap to its start.
            break
        units += _units_for_codepoint(cp, enc)
        i += size
    return units


def units_to_byte(line: String, units: Int, enc: UInt8) -> Int:
    """Convert a wire ``character`` offset on ``line`` to a byte column.

    Past-end offsets clamp to the line length (per spec). An offset that
    lands between the two halves of a UTF-16 surrogate pair snaps to the
    start of that codepoint."""
    var n = len(line.as_bytes())
    if enc == POS_UTF8:
        if units < 0:
            return 0
        if units > n:
            return n
        return units
    if units <= 0:
        return 0
    var seen = 0
    var i = 0
    while i < n:
        if seen >= units:
            return i
        var got = codepoint_at(line, i)
        var cp = got[0]
        var size = got[1]
        var w = _units_for_codepoint(cp, enc)
        if seen + w > units:
            # ``units`` splits a surrogate pair — snap to the codepoint start.
            return i
        seen += w
        i += size
    return n


def line_units(line: String, enc: UInt8) -> Int:
    """Total code units in ``line`` under ``enc``."""
    return byte_to_units(line, len(line.as_bytes()), enc)


struct LineTable(Copyable, Movable):
    """Line-start byte offsets for a document, built in one scan.

    Remapping a response means asking for the text of an arbitrary set of
    rows. Doing that with ``split_lines`` allocates every line of the file
    per lookup; this indexes the ``\\n`` positions once and then slices.
    Line endings are excluded from the returned text, and a trailing
    ``\\r`` is dropped so CRLF documents convert the same as LF ones.
    """
    var text: String
    var starts: List[Int]

    def __init__(out self, var text: String):
        var starts = List[Int]()
        starts.append(0)
        var b = text.as_bytes()
        var n = len(b)
        for i in range(n):
            if b[i] == UInt8(0x0A):
                starts.append(i + 1)
        self.text = text^
        self.starts = starts^

    def __copyinit__(mut self, copy: Self):
        self.text = copy.text
        self.starts = copy.starts.copy()

    def row_count(self) -> Int:
        return len(self.starts)

    def line(self, row: Int) -> String:
        """Text of ``row`` without its line terminator. Out-of-range rows
        return empty — a stale response referring to a row the buffer no
        longer has must not trap or index out of bounds."""
        if row < 0 or row >= len(self.starts):
            return String("")
        var start = self.starts[row]
        var b = self.text.as_bytes()
        var end = len(b)
        if row + 1 < len(self.starts):
            end = self.starts[row + 1] - 1  # drop the '\n'
        if end > start and b[end - 1] == UInt8(0x0D):
            end -= 1  # drop a CRLF '\r'
        if end < start:
            end = start
        return byte_slice(self.text, start, end)

    def col_to_wire(self, row: Int, byte_col: Int, enc: UInt8) -> Int:
        """Byte column on ``row`` → wire ``character``. Identity fast path
        for utf-8 so a remap pass over a big edit list costs nothing when
        the server honored our encoding request."""
        if enc == POS_UTF8:
            return byte_col
        return byte_to_units(self.line(row), byte_col, enc)

    def wire_to_col(self, row: Int, units: Int, enc: UInt8) -> Int:
        """Wire ``character`` on ``row`` → byte column."""
        if enc == POS_UTF8:
            return units
        return units_to_byte(self.line(row), units, enc)
