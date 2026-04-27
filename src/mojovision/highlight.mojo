"""Phase-1 syntax highlighter: in-process tokenizer for Mojo / Python files.

The render pipeline is intentionally minimal:

  1. ``highlight_for_extension(ext, buffer)`` returns a flat
     ``List[Highlight]`` for a buffer.
  2. ``Editor`` stores that list and overlays it during ``paint`` between
     the plain text pass and the selection pass.

This is the placeholder until a real LSP client lands. The data model
(``Highlight``: a per-row span with an ``Attr``) is identical to what
LSP semantic-token responses will eventually populate, so swapping the
producer in Phase 3 won't churn any consumers.
"""

from std.collections.list import List

from .colors import (
    Attr, BLUE, CYAN, LIGHT_CYAN, LIGHT_GRAY, LIGHT_GREEN, RED, WHITE,
    STYLE_NONE,
)


@fieldwise_init
struct Highlight(ImplicitlyCopyable, Movable):
    """A coloring rule for a contiguous byte span on a single buffer row.

    ``col_end`` is exclusive. ``attr`` replaces only the foreground/background
    on those cells — the underlying glyph is preserved by the editor's render
    pass, so highlights compose with plain text without re-typing it.
    """
    var row: Int
    var col_start: Int
    var col_end: Int
    var attr: Attr


# Public colors. They render against the editor's standard blue background.
fn highlight_keyword_attr() -> Attr:    return Attr(WHITE,       BLUE, STYLE_NONE)
fn highlight_string_attr()  -> Attr:    return Attr(RED,         BLUE, STYLE_NONE)
fn highlight_comment_attr() -> Attr:    return Attr(CYAN,        BLUE, STYLE_NONE)
fn highlight_number_attr()  -> Attr:    return Attr(LIGHT_GRAY,  BLUE, STYLE_NONE)
fn highlight_ident_attr()   -> Attr:    return Attr(LIGHT_GREEN, BLUE, STYLE_NONE)
fn highlight_decorator_attr() -> Attr:  return Attr(LIGHT_CYAN,  BLUE, STYLE_NONE)


# Line-state passed between line tokenization calls so triple-quoted strings
# that span multiple lines stay highlighted.
comptime _HL_NORMAL          = 0
comptime _HL_IN_TRIPLE_DQ    = 1
comptime _HL_IN_TRIPLE_SQ    = 2


fn highlight_for_extension(
    ext: String, lines: List[String],
) -> List[Highlight]:
    """Dispatch on file extension. Unknown extensions return ``[]``.

    Takes a list of lines rather than the editor's ``TextBuffer`` so the
    module has no upward dependency — the editor simply passes
    ``self.buffer.lines``.
    """
    if ext == String("mojo") or ext == String("py") or ext == String("pyi"):
        return _highlight_mojo_python(lines)
    return List[Highlight]()


fn _highlight_mojo_python(lines: List[String]) -> List[Highlight]:
    var out = List[Highlight]()
    var state = _HL_NORMAL
    for row in range(len(lines)):
        state = _highlight_line(lines[row], row, state, out)
    return out^


# --- per-line tokenizer ----------------------------------------------------


fn _highlight_line(
    line: String, row: Int, state_in: Int, mut out: List[Highlight],
) -> Int:
    var b = line.as_bytes()
    var n = len(b)
    var i = 0
    var state = state_in

    # Continuation of a triple-quoted string from a prior line.
    if state == _HL_IN_TRIPLE_DQ:
        var end = _find_triple(line, 0, 0x22)
        if end < 0:
            if n > 0:
                out.append(Highlight(row, 0, n, highlight_string_attr()))
            return state
        out.append(Highlight(row, 0, end + 3, highlight_string_attr()))
        i = end + 3
        state = _HL_NORMAL
    elif state == _HL_IN_TRIPLE_SQ:
        var end = _find_triple(line, 0, 0x27)
        if end < 0:
            if n > 0:
                out.append(Highlight(row, 0, n, highlight_string_attr()))
            return state
        out.append(Highlight(row, 0, end + 3, highlight_string_attr()))
        i = end + 3
        state = _HL_NORMAL

    while i < n:
        var c = b[i]
        # Hash comment: rest of line.
        if c == 0x23:
            out.append(Highlight(row, i, n, highlight_comment_attr()))
            return state
        # Triple-quoted string opener (must precede the single-quote case).
        if (c == 0x22 or c == 0x27) and i + 2 < n \
                and b[i + 1] == c and b[i + 2] == c:
            var start = i
            var end = _find_triple(line, i + 3, Int(c))
            if end < 0:
                out.append(Highlight(row, start, n, highlight_string_attr()))
                if c == 0x22:
                    return _HL_IN_TRIPLE_DQ
                return _HL_IN_TRIPLE_SQ
            out.append(Highlight(row, start, end + 3, highlight_string_attr()))
            i = end + 3
            continue
        # Single-line string. Backslash escapes are skipped so `"\""` parses.
        if c == 0x22 or c == 0x27:
            var quote = c
            var start = i
            i += 1
            var done = False
            while i < n:
                if b[i] == 0x5C and i + 1 < n:
                    i += 2
                    continue
                if b[i] == quote:
                    i += 1
                    done = True
                    break
                i += 1
            if done:
                out.append(Highlight(row, start, i, highlight_string_attr()))
            else:
                # Unterminated string — color the rest of the line.
                out.append(Highlight(row, start, n, highlight_string_attr()))
            continue
        # Decorator (``@name``). Highlights from ``@`` through the identifier.
        if c == 0x40 and i + 1 < n and _is_ident_start(b[i + 1]):
            var start = i
            i += 1
            while i < n and _is_ident_part(b[i]):
                i += 1
            out.append(Highlight(row, start, i, highlight_decorator_attr()))
            continue
        # Identifier or keyword.
        if _is_ident_start(c):
            var start = i
            while i < n and _is_ident_part(b[i]):
                i += 1
            var word = String(StringSlice(unsafe_from_utf8=b[start:i]))
            if _is_mojo_python_keyword(word):
                out.append(Highlight(row, start, i, highlight_keyword_attr()))
            else:
                out.append(Highlight(row, start, i, highlight_ident_attr()))
            continue
        # Number (decimal int or float — keeps it minimal).
        if _is_digit(c):
            var start = i
            while i < n and (_is_digit(b[i]) or b[i] == 0x2E):
                i += 1
            out.append(Highlight(row, start, i, highlight_number_attr()))
            continue
        i += 1
    return state


fn _find_triple(line: String, start: Int, quote: Int) -> Int:
    var b = line.as_bytes()
    var n = len(b)
    var i = start
    while i + 2 < n:
        if Int(b[i]) == quote and Int(b[i + 1]) == quote \
                and Int(b[i + 2]) == quote:
            return i
        i += 1
    return -1


fn _is_ident_start(c: UInt8) -> Bool:
    var v = Int(c)
    if v == 0x5F:  # _
        return True
    if 0x41 <= v and v <= 0x5A:
        return True
    if 0x61 <= v and v <= 0x7A:
        return True
    return False


fn _is_ident_part(c: UInt8) -> Bool:
    if _is_ident_start(c):
        return True
    var v = Int(c)
    return 0x30 <= v and v <= 0x39


fn _is_digit(c: UInt8) -> Bool:
    var v = Int(c)
    return 0x30 <= v and v <= 0x39


fn _is_mojo_python_keyword(word: String) -> Bool:
    return word == String("fn") or word == String("var") \
        or word == String("let") or word == String("alias") \
        or word == String("comptime") \
        or word == String("struct") or word == String("trait") \
        or word == String("class") or word == String("def") \
        or word == String("if") or word == String("elif") \
        or word == String("else") or word == String("while") \
        or word == String("for") or word == String("return") \
        or word == String("from") or word == String("import") \
        or word == String("as") or word == String("try") \
        or word == String("except") or word == String("finally") \
        or word == String("raise") or word == String("raises") \
        or word == String("True") or word == String("False") \
        or word == String("None") or word == String("pass") \
        or word == String("break") or word == String("continue") \
        or word == String("in") or word == String("not") \
        or word == String("and") or word == String("or") \
        or word == String("is") or word == String("with") \
        or word == String("lambda") or word == String("yield") \
        or word == String("mut") or word == String("out") \
        or word == String("owned") or word == String("self") \
        or word == String("Self") or word == String("inout") \
        or word == String("borrowed")


# --- editor-side helpers ---------------------------------------------------


fn extension_of(path: String) -> String:
    """Return the suffix after the last ``.`` in ``path`` (lowercase),
    or empty string when the basename has no extension."""
    var b = path.as_bytes()
    var n = len(b)
    var i = n - 1
    while i >= 0 and b[i] != 0x2E:
        if b[i] == 0x2F:
            return String("")
        i -= 1
    if i < 0:
        return String("")
    var ext_bytes = b[i + 1:n]
    var lower = String("")
    for k in range(len(ext_bytes)):
        var v = Int(ext_bytes[k])
        if 0x41 <= v and v <= 0x5A:
            v = v + 0x20
        lower = lower + chr(v)
    return lower


fn word_at(line: String, col: Int) -> String:
    """Return the identifier surrounding ``col`` (start ≤ col ≤ end), or
    empty string when ``col`` isn't on an identifier byte."""
    var b = line.as_bytes()
    var n = len(b)
    if col < 0 or col >= n:
        return String("")
    if not _is_ident_part(b[col]):
        return String("")
    var start = col
    while start > 0 and _is_ident_part(b[start - 1]):
        start -= 1
    var end = col
    while end < n and _is_ident_part(b[end]):
        end += 1
    return String(StringSlice(unsafe_from_utf8=b[start:end]))


@fieldwise_init
struct DefinitionRequest(ImplicitlyCopyable, Movable):
    """Payload emitted by the editor when the user Cmd+clicks an
    identifier (delivered by iTerm2 as Left+Alt). Hosts can poll
    ``Editor.consume_definition_request()`` and forward the request to
    whichever LSP client they end up wiring in."""
    var row: Int
    var col: Int
    var word: String
