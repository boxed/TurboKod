"""Where in the saved file an on-save action says it failed.

A formatter that can't parse a file says so with a file name and a line
number, in one of a handful of conventions:

* ``path:LINE:COL: message`` — ruff, gofmt, gcc/clang, mypy, rustc's
  ``--> path:LINE:COL``; the path may sit mid-line (ruff's
  ``error: Failed to parse path:LINE:COL: message``).
* ``path(LINE,COL): message`` — tsc, MSVC.
* ``File "path", line LINE`` — a Python traceback; the message is the
  traceback's last line.
* ``path ... LINE:COL ...`` — black (``cannot format path: Cannot parse:
  LINE:COL: text``) and prettier (``path: SyntaxError: ... (LINE:COL)``).

Only a location in the file that was saved counts: a path token matches
when it is the saved path, or a relative path the saved path ends with
(the action's cwd needn't be the project root). ``locate_on_save_error``
is pure, so the conventions are tested without spawning anything.
"""

from std.collections.list import List

from .string_utils import is_ascii_digit


@fieldwise_init
struct OnSaveLocation(ImplicitlyCopyable, Movable):
    """``line`` / ``col`` are 1-based as the tool printed them; ``col``
    is 0 when it gave none. ``line`` is 0 when nothing was found."""
    var line: Int
    var col: Int
    var message: String


def _is_path_byte(b: UInt8) -> Bool:
    # Letters, digits, non-ASCII, and the path punctuation that isn't a
    # delimiter in any of the conventions above.
    if b >= 0x80 or is_ascii_digit(b):
        return True
    if (b >= 0x41 and b <= 0x5A) or (b >= 0x61 and b <= 0x7A):
        return True
    return b == 0x2E or b == 0x5F or b == 0x2D or b == 0x2F \
        or b == 0x7E or b == 0x2B or b == 0x40


def _matches_saved(token: String, saved_path: String) -> Bool:
    var t = token
    if t.startswith("./"):
        var stripped = String(t[byte=2:])
        t = stripped^
    if len(t.as_bytes()) == 0:
        return False
    if t == saved_path:
        return True
    # A relative path naming the saved file from wherever the tool ran.
    return not t.startswith("/") and saved_path.endswith(String("/") + t)


def _digits(bytes: Span[UInt8, _], mut p: Int) -> Int:
    """The decimal at ``bytes[p:]``, advancing ``p`` past it; -1 (``p``
    unchanged) when there's no digit there."""
    var start = p
    var v = 0
    while p < len(bytes) and is_ascii_digit(bytes[p]):
        v = v * 10 + Int(bytes[p] - 0x30)
        p += 1
    return v if p > start else -1


def _rest(line: String, p: Int) -> String:
    """``line[p:]`` without the ``:`` / whitespace that separates a
    location from its message."""
    var bytes = line.as_bytes()
    var i = p
    while i < len(bytes) and (bytes[i] == 0x3A or bytes[i] == 0x20
                              or bytes[i] == 0x09):
        i += 1
    var j = len(bytes)
    while j > i and (bytes[j - 1] == 0x20 or bytes[j - 1] == 0x0D):
        j -= 1
    return String(line[byte=i:j])


def _line_col_after(bytes: Span[UInt8, _], start: Int) -> Tuple[Int, Int, Int]:
    """The first ``LINE:COL`` at or after ``start`` that follows a space
    or ``(``, as ``(line, col, end)``; line is -1 when there's none."""
    var i = start
    while i < len(bytes):
        if is_ascii_digit(bytes[i]) and i > 0 \
                and (bytes[i - 1] == 0x20 or bytes[i - 1] == 0x28):
            var p = i
            var ln = _digits(bytes, p)
            if p < len(bytes) and bytes[p] == 0x3A:
                p += 1
                var col = _digits(bytes, p)
                if col >= 0:
                    return (ln, col, p)
            i = p
            continue
        i += 1
    return (-1, 0, 0)


def _locate_in_line(line: String, saved_path: String) -> OnSaveLocation:
    var bytes = line.as_bytes()
    var n = len(bytes)
    var i = 0
    while i < n:
        if not _is_path_byte(bytes[i]):
            i += 1
            continue
        var tok_start = i
        while i < n and _is_path_byte(bytes[i]):
            i += 1
        var token = String(line[byte=tok_start:i])
        if not _matches_saved(token, saved_path):
            continue
        var p = i
        # path:LINE[:COL]
        if p < n and bytes[p] == 0x3A:
            p += 1
            var ln = _digits(bytes, p)
            if ln > 0:
                var col = 0
                if p + 1 < n and bytes[p] == 0x3A and is_ascii_digit(bytes[p + 1]):
                    p += 1
                    col = _digits(bytes, p)
                return OnSaveLocation(ln, col, _rest(line, p))
        p = i
        # path(LINE[,COL])
        if p < n and bytes[p] == 0x28:
            p += 1
            var ln = _digits(bytes, p)
            if ln > 0:
                var col = 0
                if p < n and bytes[p] == 0x2C:
                    p += 1
                    col = max(_digits(bytes, p), 0)
                if p < n and bytes[p] == 0x29:
                    p += 1
                return OnSaveLocation(ln, col, _rest(line, p))
        # File "path", line LINE — a traceback frame; what follows is
        # the function name, so the message is left to the caller.
        p = i
        if p < n and (bytes[p] == 0x22 or bytes[p] == 0x27):
            p += 1
        if line[byte=p:].startswith(", line "):
            p += 7
            var ln = _digits(bytes, p)
            if ln > 0:
                return OnSaveLocation(ln, 0, String(""))
        # path ... LINE:COL (black, prettier)
        var lc = _line_col_after(bytes, i)
        if lc[0] > 0:
            return OnSaveLocation(lc[0], lc[1], _rest(line, lc[2]))
    return OnSaveLocation(0, 0, String(""))


def locate_on_save_error(output: String, saved_path: String) -> OnSaveLocation:
    """The first location in ``output`` that names ``saved_path``, with
    the message the tool gave for it. A location without a message on
    its own line (a Python traceback) takes the output's last non-empty
    line, which is where a traceback says what went wrong."""
    var lines = output.split("\n")
    var last = String("")
    for k in range(len(lines)):
        var s = String(lines[k].strip())
        if len(s.as_bytes()) > 0:
            last = s^
    for k in range(len(lines)):
        var loc = _locate_in_line(String(lines[k]), saved_path)
        if loc.line > 0:
            if len(loc.message.as_bytes()) == 0:
                loc.message = last
            return loc^
    return OnSaveLocation(0, 0, String(""))
