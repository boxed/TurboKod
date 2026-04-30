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
from std.collections.optional import Optional

from .colors import (
    Attr, BLUE, CYAN, LIGHT_CYAN, LIGHT_GRAY, LIGHT_GREEN, LIGHT_YELLOW,
    RED, WHITE, STYLE_NONE,
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
fn highlight_decorator_attr() -> Attr:  return Attr(LIGHT_CYAN,    BLUE, STYLE_NONE)
fn highlight_operator_attr()  -> Attr:  return Attr(LIGHT_YELLOW,  BLUE, STYLE_NONE)


# Line-state passed between line tokenization calls so triple-quoted strings
# that span multiple lines stay highlighted. The DOC variants carry the same
# delimiter information as TRIPLE but mean "this triple-string opened at
# statement position, so it's a docstring — paint it with the comment attr."
comptime _HL_NORMAL          = 0
comptime _HL_IN_TRIPLE_DQ    = 1
comptime _HL_IN_TRIPLE_SQ    = 2
comptime _HL_IN_DOC_DQ       = 3
comptime _HL_IN_DOC_SQ       = 4


fn highlight_for_extension(
    ext: String, lines: List[String],
) -> List[Highlight]:
    """Dispatch on file extension. Unknown extensions return ``[]``.

    Takes a list of lines rather than the editor's ``TextBuffer`` so the
    module has no upward dependency — the editor simply passes
    ``self.buffer.lines``.

    Mojo/Python keep their bespoke tokenizer because they need
    docstring-aware triple-quote handling. Everything else routes through
    the registry-driven ``_highlight_generic`` so adding a new language
    is a one-liner in ``_lang_spec_for_ext``.
    """
    if ext == String("mojo") or ext == String("py") or ext == String("pyi"):
        return _highlight_mojo_python(lines)
    var spec_opt = _lang_spec_for_ext(ext)
    if spec_opt:
        return _highlight_generic(lines, spec_opt.value())
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

    # Continuation of a triple-quoted string from a prior line. The DOC
    # variants paint as comments; the TRIPLE variants paint as strings.
    if state == _HL_IN_TRIPLE_DQ or state == _HL_IN_DOC_DQ:
        var as_doc = state == _HL_IN_DOC_DQ
        var attr = highlight_comment_attr() if as_doc else highlight_string_attr()
        var end = _find_triple(line, 0, 0x22)
        if end < 0:
            if n > 0:
                out.append(Highlight(row, 0, n, attr))
            return state
        out.append(Highlight(row, 0, end + 3, attr))
        i = end + 3
        state = _HL_NORMAL
    elif state == _HL_IN_TRIPLE_SQ or state == _HL_IN_DOC_SQ:
        var as_doc = state == _HL_IN_DOC_SQ
        var attr = highlight_comment_attr() if as_doc else highlight_string_attr()
        var end = _find_triple(line, 0, 0x27)
        if end < 0:
            if n > 0:
                out.append(Highlight(row, 0, n, attr))
            return state
        out.append(Highlight(row, 0, end + 3, attr))
        i = end + 3
        state = _HL_NORMAL

    while i < n:
        var c = b[i]
        # Hash comment: rest of line.
        if c == 0x23:
            out.append(Highlight(row, i, n, highlight_comment_attr()))
            return state
        # Triple-quoted string opener (must precede the single-quote case).
        # If only whitespace precedes it on this line, it's at statement
        # position — i.e. a docstring — and is colored as a comment.
        if (c == 0x22 or c == 0x27) and i + 2 < n \
                and b[i + 1] == c and b[i + 2] == c:
            var start = i
            var as_doc = True
            for j in range(i):
                if b[j] != 0x20 and b[j] != 0x09:
                    as_doc = False
                    break
            var attr = highlight_comment_attr() if as_doc else highlight_string_attr()
            var end = _find_triple(line, i + 3, Int(c))
            if end < 0:
                out.append(Highlight(row, start, n, attr))
                if c == 0x22:
                    return _HL_IN_DOC_DQ if as_doc else _HL_IN_TRIPLE_DQ
                return _HL_IN_DOC_SQ if as_doc else _HL_IN_TRIPLE_SQ
            out.append(Highlight(row, start, end + 3, attr))
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
        # Operator run (`+`, `-`, `*`, `/`, `%`, `=`, `<`, `>`, `!`, `&`,
        # `|`, `^`, `~`, `@`, `(`, `)`, `.`, `:`, `[`, `]`, `{`, `}`).
        # Consecutive bytes coalesce so `==`, `->`, `**=`, `[]`, etc. render
        # as a single span. `@` followed by an identifier was already
        # consumed as a decorator above; `.` inside a numeric literal was
        # already consumed as part of the number.
        if _is_operator(c):
            var start = i
            while i < n and _is_operator(b[i]):
                i += 1
            out.append(Highlight(row, start, i, highlight_operator_attr()))
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


fn _is_operator(c: UInt8) -> Bool:
    var v = Int(c)
    return v == 0x2B or v == 0x2D or v == 0x2A or v == 0x2F \
        or v == 0x25 or v == 0x3D or v == 0x3C or v == 0x3E \
        or v == 0x21 or v == 0x26 or v == 0x7C or v == 0x5E \
        or v == 0x7E or v == 0x40 or v == 0x28 or v == 0x29 \
        or v == 0x2E or v == 0x3A or v == 0x5B or v == 0x5D \
        or v == 0x7B or v == 0x7D


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


# --- generic registry-driven tokenizer ------------------------------------
#
# Pragmatic stand-in for a TextMate / tree-sitter integration: a tiny
# config struct that captures the cross-language commonalities (line
# comment marker, block-comment delimiters, string quotes, keyword set)
# plus a single hand-rolled tokenizer that walks each line under that
# config. Adding a new language is one entry in ``_lang_spec_for_ext``.
#
# This is deliberately less expressive than TextMate. It nails the
# "looks like code, not a wall of text" job for the C/C++/Rust/Go/JS
# family plus shells, JSON, YAML — the languages whose lexical surface
# is very similar. Anything that needs context-sensitive parsing
# (template literals, string interpolation, heredocs, raw strings with
# variable hash counts) falls back to "good enough" — the unhandled
# construct usually still gets a sensible color, just not a perfect one.


comptime _HL_IN_BLOCK_COMMENT = 5
# Subset-of-keywords colored with the "operator" attr to make types stand
# out from control flow. Per-language; filled in by the spec.


struct LangSpec(ImplicitlyCopyable, Movable):
    """Per-language config for the generic tokenizer.

    All fields are byte-strings — the tokenizer compares them with
    ``as_bytes()`` rather than going through Mojo's string protocol.
    Empty strings are sentinel values: an empty ``line_comment`` means
    "this language has no line comments" and the tokenizer skips that
    branch entirely. ``quotes`` is a flat byte string; each byte in it
    independently opens/closes a string literal of that quote.
    """
    var keywords: List[String]
    var line_comment: String     # e.g. "//" or "#"
    var block_open: String       # e.g. "/*" or "" (no block comments)
    var block_close: String      # e.g. "*/" or ""
    var quotes: String           # e.g. "\"'`" — each byte is a quote

    fn __init__(
        out self, var keywords: List[String], var line_comment: String,
        var block_open: String, var block_close: String, var quotes: String,
    ):
        self.keywords = keywords^
        self.line_comment = line_comment^
        self.block_open = block_open^
        self.block_close = block_close^
        self.quotes = quotes^

    fn __copyinit__(out self, copy: Self):
        self.keywords = copy.keywords.copy()
        self.line_comment = copy.line_comment
        self.block_open = copy.block_open
        self.block_close = copy.block_close
        self.quotes = copy.quotes


fn _lang_spec_for_ext(ext: String) -> Optional[LangSpec]:
    """Registry: extension → spec, or ``None`` for unknown.

    Linear scan; the table is small. Languages that share lexical
    structure (C/C++, JS/TS, etc.) reuse the same spec under different
    extensions so a fix to keywords/strings benefits all of them at once.
    """
    # --- C-family (// + /*..*/, double + single quotes) ---------------
    if ext == String("rs"):
        return _spec_rust()
    if ext == String("c") or ext == String("h") or ext == String("cc") \
            or ext == String("cpp") or ext == String("cxx") \
            or ext == String("hpp") or ext == String("hh") \
            or ext == String("hxx"):
        return _spec_c()
    if ext == String("go"):
        return _spec_go()
    if ext == String("ts") or ext == String("tsx") or ext == String("js") \
            or ext == String("jsx") or ext == String("mjs") \
            or ext == String("cjs"):
        return _spec_ts()
    if ext == String("zig"):
        return _spec_zig()
    if ext == String("java") or ext == String("kt") or ext == String("kts") \
            or ext == String("scala") or ext == String("swift"):
        return _spec_jvm_like()
    # --- shell / Ruby (# comments, single + double + backtick) -------
    if ext == String("sh") or ext == String("bash"):
        return _spec_bash()
    if ext == String("rb"):
        return _spec_ruby()
    # --- data formats ------------------------------------------------
    if ext == String("json") or ext == String("jsonc"):
        return _spec_json()
    if ext == String("yaml") or ext == String("yml"):
        return _spec_yaml()
    if ext == String("toml"):
        return _spec_toml()
    return Optional[LangSpec]()


fn _kw(*words: String) -> List[String]:
    var out = List[String]()
    for w in words:
        out.append(String(w))
    return out^


fn _spec_rust() -> Optional[LangSpec]:
    return LangSpec(
        _kw(
            String("as"), String("async"), String("await"), String("break"),
            String("const"), String("continue"), String("crate"),
            String("dyn"), String("else"), String("enum"), String("extern"),
            String("false"), String("fn"), String("for"), String("if"),
            String("impl"), String("in"), String("let"), String("loop"),
            String("match"), String("mod"), String("move"), String("mut"),
            String("pub"), String("ref"), String("return"), String("self"),
            String("Self"), String("static"), String("struct"),
            String("super"), String("trait"), String("true"), String("type"),
            String("unsafe"), String("use"), String("where"), String("while"),
            # Common type names and "primitive" identifiers worth coloring.
            String("bool"), String("char"), String("str"), String("String"),
            String("i8"), String("i16"), String("i32"), String("i64"),
            String("i128"), String("isize"), String("u8"), String("u16"),
            String("u32"), String("u64"), String("u128"), String("usize"),
            String("f32"), String("f64"), String("Vec"), String("Option"),
            String("Result"), String("None"), String("Some"), String("Ok"),
            String("Err"), String("Box"),
        ),
        String("//"), String("/*"), String("*/"), String("\"'"),
    )


fn _spec_c() -> Optional[LangSpec]:
    return LangSpec(
        _kw(
            String("auto"), String("break"), String("case"), String("char"),
            String("class"), String("const"), String("constexpr"),
            String("continue"), String("default"), String("delete"),
            String("do"), String("double"), String("else"), String("enum"),
            String("explicit"), String("export"), String("extern"),
            String("false"), String("float"), String("for"), String("friend"),
            String("goto"), String("if"), String("inline"), String("int"),
            String("long"), String("namespace"), String("new"),
            String("noexcept"), String("nullptr"), String("operator"),
            String("private"), String("protected"), String("public"),
            String("register"), String("return"), String("short"),
            String("signed"), String("sizeof"), String("static"),
            String("struct"), String("switch"), String("template"),
            String("this"), String("throw"), String("true"), String("try"),
            String("typedef"), String("typename"), String("union"),
            String("unsigned"), String("using"), String("virtual"),
            String("void"), String("volatile"), String("while"),
            String("size_t"), String("ssize_t"), String("uint8_t"),
            String("uint16_t"), String("uint32_t"), String("uint64_t"),
            String("int8_t"), String("int16_t"), String("int32_t"),
            String("int64_t"), String("bool"),
        ),
        String("//"), String("/*"), String("*/"), String("\"'"),
    )


fn _spec_go() -> Optional[LangSpec]:
    return LangSpec(
        _kw(
            String("break"), String("case"), String("chan"), String("const"),
            String("continue"), String("default"), String("defer"),
            String("else"), String("fallthrough"), String("for"),
            String("func"), String("go"), String("goto"), String("if"),
            String("import"), String("interface"), String("map"),
            String("package"), String("range"), String("return"),
            String("select"), String("struct"), String("switch"),
            String("type"), String("var"), String("nil"), String("true"),
            String("false"), String("iota"),
            String("string"), String("int"), String("int8"), String("int16"),
            String("int32"), String("int64"), String("uint"), String("uint8"),
            String("uint16"), String("uint32"), String("uint64"),
            String("uintptr"), String("byte"), String("rune"),
            String("float32"), String("float64"), String("complex64"),
            String("complex128"), String("bool"), String("error"),
        ),
        String("//"), String("/*"), String("*/"), String("\"'`"),
    )


fn _spec_ts() -> Optional[LangSpec]:
    return LangSpec(
        _kw(
            String("abstract"), String("any"), String("as"), String("async"),
            String("await"), String("boolean"), String("break"),
            String("case"), String("catch"), String("class"),
            String("const"), String("constructor"), String("continue"),
            String("debugger"), String("declare"), String("default"),
            String("delete"), String("do"), String("else"), String("enum"),
            String("export"), String("extends"), String("false"),
            String("finally"), String("for"), String("from"),
            String("function"), String("get"), String("if"),
            String("implements"), String("import"), String("in"),
            String("instanceof"), String("interface"), String("is"),
            String("keyof"), String("let"), String("module"), String("namespace"),
            String("never"), String("new"), String("null"), String("number"),
            String("object"), String("of"), String("package"),
            String("private"), String("protected"), String("public"),
            String("readonly"), String("return"), String("set"),
            String("static"), String("string"), String("super"),
            String("switch"), String("symbol"), String("this"),
            String("throw"), String("true"), String("try"), String("type"),
            String("typeof"), String("undefined"), String("unknown"),
            String("var"), String("void"), String("while"), String("with"),
            String("yield"),
        ),
        String("//"), String("/*"), String("*/"), String("\"'`"),
    )


fn _spec_zig() -> Optional[LangSpec]:
    return LangSpec(
        _kw(
            String("addrspace"), String("align"), String("allowzero"),
            String("and"), String("anyframe"), String("anytype"),
            String("asm"), String("async"), String("await"), String("break"),
            String("callconv"), String("catch"), String("comptime"),
            String("const"), String("continue"), String("defer"),
            String("else"), String("enum"), String("errdefer"), String("error"),
            String("export"), String("extern"), String("fn"), String("for"),
            String("if"), String("inline"), String("noalias"), String("nosuspend"),
            String("null"), String("opaque"), String("or"), String("orelse"),
            String("packed"), String("pub"), String("resume"), String("return"),
            String("linksection"), String("struct"), String("suspend"),
            String("switch"), String("test"), String("threadlocal"),
            String("true"), String("false"), String("try"), String("union"),
            String("unreachable"), String("usingnamespace"), String("var"),
            String("volatile"), String("while"),
            String("void"), String("bool"), String("isize"), String("usize"),
            String("u8"), String("u16"), String("u32"), String("u64"),
            String("i8"), String("i16"), String("i32"), String("i64"),
            String("f32"), String("f64"), String("comptime_int"),
            String("comptime_float"), String("type"),
        ),
        String("//"), String(""), String(""), String("\"'"),
    )


fn _spec_jvm_like() -> Optional[LangSpec]:
    return LangSpec(
        _kw(
            String("abstract"), String("as"), String("break"), String("case"),
            String("catch"), String("class"), String("const"), String("continue"),
            String("data"), String("def"), String("default"), String("do"),
            String("else"), String("enum"), String("extends"), String("extension"),
            String("false"), String("final"), String("finally"), String("for"),
            String("fun"), String("if"), String("implements"), String("import"),
            String("in"), String("instanceof"), String("interface"), String("internal"),
            String("is"), String("lazy"), String("let"), String("match"), String("native"),
            String("new"), String("null"), String("object"), String("open"), String("operator"),
            String("override"), String("package"), String("private"), String("protected"),
            String("public"), String("return"), String("sealed"), String("static"),
            String("struct"), String("super"), String("switch"), String("synchronized"),
            String("this"), String("throw"), String("throws"), String("trait"),
            String("transient"), String("true"), String("try"), String("typealias"),
            String("val"), String("var"), String("void"), String("volatile"),
            String("when"), String("where"), String("while"), String("yield"),
        ),
        String("//"), String("/*"), String("*/"), String("\"'"),
    )


fn _spec_bash() -> Optional[LangSpec]:
    return LangSpec(
        _kw(
            String("if"), String("then"), String("else"), String("elif"),
            String("fi"), String("for"), String("in"), String("do"),
            String("done"), String("while"), String("until"), String("case"),
            String("esac"), String("function"), String("return"),
            String("break"), String("continue"), String("local"),
            String("export"), String("readonly"), String("declare"),
            String("typeset"), String("set"), String("unset"), String("trap"),
            String("source"), String("alias"), String("eval"), String("exec"),
            String("exit"), String("shift"),
        ),
        String("#"), String(""), String(""), String("\"'`"),
    )


fn _spec_ruby() -> Optional[LangSpec]:
    return LangSpec(
        _kw(
            String("alias"), String("and"), String("begin"), String("break"),
            String("case"), String("class"), String("def"), String("defined?"),
            String("do"), String("else"), String("elsif"), String("end"),
            String("ensure"), String("false"), String("for"), String("if"),
            String("in"), String("module"), String("next"), String("nil"),
            String("not"), String("or"), String("redo"), String("rescue"),
            String("retry"), String("return"), String("self"), String("super"),
            String("then"), String("true"), String("undef"), String("unless"),
            String("until"), String("when"), String("while"), String("yield"),
            String("require"), String("require_relative"), String("attr_reader"),
            String("attr_writer"), String("attr_accessor"),
        ),
        String("#"), String(""), String(""), String("\"'`"),
    )


fn _spec_json() -> Optional[LangSpec]:
    # JSONC supports // and /*..*/; plain JSON doesn't, but accepting them
    # is harmless on a strict file (they just won't appear).
    return LangSpec(
        _kw(String("true"), String("false"), String("null")),
        String("//"), String("/*"), String("*/"), String("\""),
    )


fn _spec_yaml() -> Optional[LangSpec]:
    return LangSpec(
        _kw(
            String("true"), String("false"), String("null"), String("yes"),
            String("no"), String("on"), String("off"),
        ),
        String("#"), String(""), String(""), String("\"'"),
    )


fn _spec_toml() -> Optional[LangSpec]:
    return LangSpec(
        _kw(String("true"), String("false")),
        String("#"), String(""), String(""), String("\"'"),
    )




fn _highlight_generic(
    lines: List[String], spec: LangSpec,
) -> List[Highlight]:
    var out = List[Highlight]()
    var state = _HL_NORMAL
    for row in range(len(lines)):
        state = _highlight_generic_line(lines[row], row, state, spec, out)
    return out^


fn _highlight_generic_line(
    line: String, row: Int, state_in: Int, spec: LangSpec,
    mut out: List[Highlight],
) -> Int:
    """Single-line tokenizer driven by ``spec``. Returns the post-line
    state so block comments can span multiple lines without us having
    to re-scan from the top of the buffer.

    The match order mirrors the existing Mojo/Python tokenizer: block
    comment continuation first, then per-character: line comment,
    block-comment open, string, identifier/keyword, number, operator
    run. Unknown bytes are skipped silently (i.e. left uncolored), so
    the editor still paints them as plain text.
    """
    var b = line.as_bytes()
    var n = len(b)
    var i = 0
    var state = state_in

    # Pre-extract needle byte strings as ``List[UInt8]``. We can't pass
    # ``Span`` around the helpers without drowning in origin parameters,
    # so we copy once up front (these are 0-3 bytes each) and check
    # prefix equality via ``_starts_with``.
    var bo = _to_bytes_list(spec.block_open)
    var bc = _to_bytes_list(spec.block_close)
    var lc = _to_bytes_list(spec.line_comment)
    var qb = _to_bytes_list(spec.quotes)

    # Continuation of a block comment from a prior line.
    if state == _HL_IN_BLOCK_COMMENT:
        var attr = highlight_comment_attr()
        if len(bc) == 0:
            # Spec changed under us? Bail out conservatively.
            return _HL_NORMAL
        var j = 0
        var found = -1
        while j + len(bc) <= n:
            if _starts_with(line, j, bc):
                found = j
                break
            j += 1
        if found < 0:
            if n > 0:
                out.append(Highlight(row, 0, n, attr))
            return state
        out.append(Highlight(row, 0, found + len(bc), attr))
        i = found + len(bc)
        state = _HL_NORMAL

    while i < n:
        var c = b[i]

        # Line comment: rest of line.
        if len(lc) > 0 and _starts_with(line, i, lc):
            out.append(Highlight(row, i, n, highlight_comment_attr()))
            return state

        # Block comment open (may span lines).
        if len(bo) > 0 and _starts_with(line, i, bo):
            var start = i
            var j = i + len(bo)
            var found = -1
            while j + len(bc) <= n:
                if _starts_with(line, j, bc):
                    found = j
                    break
                j += 1
            if found < 0:
                out.append(Highlight(row, start, n, highlight_comment_attr()))
                return _HL_IN_BLOCK_COMMENT
            out.append(Highlight(
                row, start, found + len(bc), highlight_comment_attr(),
            ))
            i = found + len(bc)
            continue

        # String literal. ``qb`` lists every byte that opens/closes a
        # string. Backslash escapes consume the next byte. Unterminated
        # strings color to end-of-line — same fallback as Mojo/Python.
        var is_quote = False
        for q in range(len(qb)):
            if c == qb[q]:
                is_quote = True
                break
        if is_quote:
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
                out.append(Highlight(row, start, n, highlight_string_attr()))
            continue

        # Identifier or keyword.
        if _is_ident_start(c):
            var start = i
            while i < n and _is_ident_part(b[i]):
                i += 1
            var word = String(StringSlice(unsafe_from_utf8=b[start:i]))
            if _is_keyword_in(word, spec.keywords):
                out.append(Highlight(row, start, i, highlight_keyword_attr()))
            else:
                out.append(Highlight(row, start, i, highlight_ident_attr()))
            continue

        # Number.
        if _is_digit(c):
            var start = i
            while i < n and (_is_digit(b[i]) or b[i] == 0x2E):
                i += 1
            out.append(Highlight(row, start, i, highlight_number_attr()))
            continue

        # Operator run.
        if _is_operator(c):
            var start = i
            while i < n and _is_operator(b[i]):
                i += 1
            out.append(Highlight(row, start, i, highlight_operator_attr()))
            continue

        i += 1
    return state


fn _is_keyword_in(word: String, keywords: List[String]) -> Bool:
    """Linear membership test. Keyword lists are short (a few dozen
    entries) and the call site already paid the identifier-extraction
    cost, so a hash table would be over-engineering."""
    for k in range(len(keywords)):
        if keywords[k] == word:
            return True
    return False


fn _to_bytes_list(s: String) -> List[UInt8]:
    """Copy a string's bytes into an owned list. Used for the few
    short needle strings the tokenizer compares against — keeps the
    hot path free of ``Span`` origin parameters that ``@fieldwise_init``
    structs make awkward to thread through helpers."""
    var b = s.as_bytes()
    var out = List[UInt8]()
    for k in range(len(b)):
        out.append(b[k])
    return out^


fn _starts_with(line: String, i: Int, needle: List[UInt8]) -> Bool:
    """Does ``line[i:]`` begin with ``needle``? Cheap byte-wise prefix
    compare. Returns ``False`` on out-of-bounds rather than raising —
    ``i`` may be at or past the end on the caller's last iteration."""
    var b = line.as_bytes()
    var n = len(needle)
    if i + n > len(b):
        return False
    for k in range(n):
        if b[i + k] != needle[k]:
            return False
    return True
