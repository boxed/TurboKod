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
from .tm_grammar import Grammar, load_grammar_from_file
from .tm_tokenizer import (
    Frame, copy_stack, stack_eq,
    tokenize_lines_from, tokenize_with_grammar,
    tokenize_with_grammar_full,
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


# Per-line state passed between calls to ``_highlight_generic_line``.
# ``_HL_NORMAL`` is the default; ``_HL_IN_BLOCK_COMMENT`` (defined
# alongside the generic tokenizer below) means the line opened
# inside an unfinished ``/* ... */`` from a previous row.
comptime _HL_NORMAL          = 0


fn highlight_for_extension(
    ext: String, lines: List[String],
) -> List[Highlight]:
    """Dispatch on file extension. Unknown extensions return ``[]``.

    Takes a list of lines rather than the editor's ``TextBuffer`` so the
    module has no upward dependency — the editor simply passes
    ``self.buffer.lines``.

    Three tiers:
    1. Mojo/Python use a bespoke tokenizer because they need
       docstring-aware triple-quote handling.
    2. Languages with a TextMate grammar bundled under
       ``src/turbokod/grammars/`` go through that runtime — same
       data path VS Code / Sublime use.
    3. Everything else falls back to ``_highlight_generic``, the
       small per-language config registry. Crude but pure-Mojo and
       always available.

    The TextMate path can fail (grammar file missing, regex
    compile error in the bundled JSON, runtime exception inside
    the tokenizer); when that happens we silently fall through to
    the generic tokenizer rather than letting an exception kill the
    editor's render pass.
    """
    var tm_opt = _try_textmate(ext, lines)
    if tm_opt:
        return tm_opt.value().copy()
    var spec_opt = _lang_spec_for_ext(ext)
    if spec_opt:
        return _highlight_generic(lines, spec_opt.value())
    return List[Highlight]()


fn _grammar_path_for_ext(ext: String) -> String:
    """Map extension → grammar JSON path, relative to project root.

    Empty string means "no grammar for this extension." Adding a
    new grammar is one entry here plus the JSON file under
    ``src/turbokod/grammars/``.
    """
    if ext == String("py") or ext == String("pyi") or ext == String("pyw"):
        return String("src/turbokod/grammars/python.tmLanguage.json")
    if ext == String("mojo") or ext == String("🔥"):
        return String("src/turbokod/grammars/mojo.tmLanguage.json")
    if ext == String("rs"):
        return String("src/turbokod/grammars/rust.tmLanguage.json")
    if ext == String("json") or ext == String("jsonc"):
        return String("src/turbokod/grammars/json.tmLanguage.json")
    if ext == String("go"):
        return String("src/turbokod/grammars/go.tmLanguage.json")
    if ext == String("ts") or ext == String("tsx"):
        return String("src/turbokod/grammars/typescript.tmLanguage.json")
    if ext == String("js") or ext == String("jsx") \
            or ext == String("mjs") or ext == String("cjs"):
        return String("src/turbokod/grammars/javascript.tmLanguage.json")
    if ext == String("rb"):
        return String("src/turbokod/grammars/ruby.tmLanguage.json")
    if ext == String("c") or ext == String("h") or ext == String("cc") \
            or ext == String("cpp") or ext == String("cxx") \
            or ext == String("hpp") or ext == String("hh") \
            or ext == String("hxx"):
        return String("src/turbokod/grammars/cpp.tmLanguage.json")
    if ext == String("sh") or ext == String("bash"):
        return String("src/turbokod/grammars/shell.tmLanguage.json")
    if ext == String("yaml") or ext == String("yml"):
        return String("src/turbokod/grammars/yaml.tmLanguage.json")
    if ext == String("html") or ext == String("htm"):
        return String("src/turbokod/grammars/html.tmLanguage.json")
    if ext == String("css"):
        return String("src/turbokod/grammars/css.tmLanguage.json")
    if ext == String("diff") or ext == String("patch"):
        return String("src/turbokod/grammars/diff.tmLanguage.json")
    # Markdown — the vscode grammar is dominated by ``while`` rules
    # (block-context tracking) and external-grammar embedding (code
    # fences). Without those, leaving it on the generic fallback
    # actually produces nothing for ``.md`` today; keeping the
    # grammar bundled but unmapped lets a follow-up wire it up once
    # we grow ``while`` support.
    return String("")


struct GrammarRegistry(Movable):
    """Process-wide loaded-grammar cache.

    Multiple ``Editor``s share one ``GrammarRegistry``, so opening
    a second ``.rs`` file after closing the first reuses the
    already-compiled grammar instead of re-parsing the JSON and
    re-allocating ~125 KB-12 MB of regex handles. The natural
    owner is ``Desktop`` (the top-level UI controller); editor
    methods that need it take it as a ``mut`` parameter.

    Storage is parallel ``keys`` / ``grammars`` arrays. A linear
    scan suffices — sessions rarely load more than a handful of
    distinct languages, so the constant factor beats a hash map
    plus the bookkeeping it'd require.

    Not ``ImplicitlyCopyable``: ``Grammar`` isn't copyable (its
    ``OnigRegex`` list aliases libonig handles). The struct is
    intended to live in exactly one place per process; owners
    that copy themselves should construct a fresh registry rather
    than try to copy this one.
    """
    var keys: List[String]
    var grammars: List[Grammar]

    fn __init__(out self):
        self.keys = List[String]()
        self.grammars = List[Grammar]()

    fn lookup_idx(self, key: String) -> Int:
        """Index of the cached grammar for ``key``, or -1.
        ``key`` is whatever the caller wants to key on — typically
        the file extension (``"rs"``, ``"py"``).
        """
        for i in range(len(self.keys)):
            if self.keys[i] == key:
                return i
        return -1


struct HighlightCache(Movable):
    """Per-``Editor`` incremental tokenizer state.

    Holds the most recently produced highlights and the per-line
    tokenizer stack at end-of-line so the next ``_refresh_highlights``
    can re-tokenize starting from the dirty row instead of from the
    top of the buffer. Lives on ``Editor`` (one per buffer);
    ``GrammarRegistry`` carries the actual loaded grammars and is
    owned at a higher layer (``Desktop``).

    ``ext`` records the extension the cached state was produced
    against — when it changes (file_path swap), the per-line state
    is invalidated and the next refresh does a full retokenize.
    """
    var ext: String
    var highlights: List[Highlight]
    var post_stacks: List[List[Frame]]

    fn __init__(out self):
        self.ext = String("")
        self.highlights = List[Highlight]()
        self.post_stacks = List[List[Frame]]()

    fn invalidate(mut self):
        """Drop the per-line state — used when the line count or
        extension shifts in a way the incremental path can't
        reconcile."""
        self.highlights = List[Highlight]()
        self.post_stacks = List[List[Frame]]()


fn highlight_for_extension_cached(
    ext: String, lines: List[String],
    mut registry: GrammarRegistry, mut cache: HighlightCache,
) -> List[Highlight]:
    """Non-incremental cached entry point. Always re-tokenizes the
    whole buffer, but reuses the registry's grammars across calls.
    Suitable for callers that don't track which row was edited.

    For the incremental path used by ``Editor`` — re-tokenize only
    from the dirty row down, with early-exit when the tokenizer
    state rejoins the cached state — call
    ``highlight_incremental`` instead.
    """
    return highlight_incremental(ext, lines, 0, registry, cache)


fn highlight_incremental(
    ext: String, lines: List[String], dirty_row: Int,
    mut registry: GrammarRegistry, mut cache: HighlightCache,
) -> List[Highlight]:
    """Cached + incremental TextMate path.

    ``dirty_row`` is a hint: rows ``< dirty_row`` are guaranteed
    unchanged from the last call, so we can skip re-tokenizing
    them and just fix up rows from ``dirty_row`` down. After
    re-tokenizing those, we compare each line's post-stack against
    the cached one — when they match, we know the tokenizer has
    rejoined its previous trajectory and the rest of the buffer's
    cached highlights are still valid, so we splice rather than
    re-emit them.

    Falls back to a full retokenize when the cache is cold, the
    extension changed, the line count changed, or ``dirty_row``
    is 0. Falls through to the generic tokenizer when there's no
    bundled grammar for the extension.
    """
    var path = _grammar_path_for_ext(ext)
    if len(path.as_bytes()) == 0:
        return _fallback_for_extension(ext, lines)

    # Grammar load — registry hit if the extension is already known,
    # else cold load + register. The registry is process-shared so
    # the next ``Editor`` for the same language reuses the same
    # ``Grammar`` instance instead of re-parsing the JSON and
    # re-allocating libonig handles.
    var grammar_idx = registry.lookup_idx(ext)
    if grammar_idx < 0:
        try:
            var g = load_grammar_from_file(path)
            registry.keys.append(ext)
            registry.grammars.append(g^)
            grammar_idx = len(registry.keys) - 1
        except:
            return _fallback_for_extension(ext, lines)

    # Per-Editor state: invalidate when the extension changes.
    if cache.ext != ext:
        cache.invalidate()
        cache.ext = ext

    # Decide whether we can incrementalize. Conditions for "yes":
    #   * cache is warm: we already tokenized this extension before
    #     and have ``post_stacks`` of the right length;
    #   * dirty_row > 0 (else there's nothing to skip);
    #   * dirty_row is in range.
    # Anything else collapses to a full retokenize.
    var n_lines = len(lines)
    var can_incr = (dirty_row > 0
                    and dirty_row <= n_lines
                    and len(cache.post_stacks) == n_lines)
    if not can_incr:
        var hls = _full_retokenize(
            registry.grammars[grammar_idx], cache, lines,
        )
        if len(hls) == 0 and _has_nonempty_line(lines):
            return _fallback_for_extension(ext, lines)
        return hls^

    # Incremental path. Start state = post-state at end of line
    # (dirty_row - 1), i.e. what dirty_row was tokenized against
    # last time. The tokenizer itself stops as soon as state
    # rejoins the cached trajectory and reports back via
    # ``stable_row``.
    var start_stack = cache.post_stacks[dirty_row - 1].copy()
    var new_post = List[List[Frame]]()
    var stable_row: Int = 0
    var new_hls = tokenize_lines_from(
        registry.grammars[grammar_idx], lines, dirty_row, start_stack,
        cache.post_stacks, new_post, stable_row,
    )

    # Splice highlights:
    #   1. Keep cached highlights with row < dirty_row.
    #   2. Append re-tokenized highlights (rows ``[dirty_row,
    #      stable_row)``).
    #   3. Append cached highlights with row >= stable_row.
    # ``new_hls`` already contains only rows up to ``stable_row``
    # because that's where the tokenizer stopped.
    var out = List[Highlight]()
    for i in range(len(cache.highlights)):
        if cache.highlights[i].row < dirty_row:
            out.append(cache.highlights[i])
    for i in range(len(new_hls)):
        out.append(new_hls[i])
    if stable_row < n_lines:
        for i in range(len(cache.highlights)):
            if cache.highlights[i].row >= stable_row:
                out.append(cache.highlights[i])

    # Update cached post_stacks: replace ``[dirty_row, stable_row)``
    # with the new ones, keep cached entries below dirty_row and
    # at-or-above stable_row.
    var updated_stacks = List[List[Frame]]()
    for i in range(dirty_row):
        updated_stacks.append(cache.post_stacks[i].copy())
    for k in range(len(new_post)):
        updated_stacks.append(new_post[k].copy())
    if stable_row < len(cache.post_stacks):
        for i in range(stable_row, len(cache.post_stacks)):
            updated_stacks.append(cache.post_stacks[i].copy())
    cache.post_stacks = updated_stacks^
    cache.highlights = out.copy()

    if len(out) == 0 and _has_nonempty_line(lines):
        return _fallback_for_extension(ext, lines)
    return out^


fn _full_retokenize(
    grammar: Grammar, mut cache: HighlightCache, lines: List[String],
) -> List[Highlight]:
    """Re-tokenize ``lines`` from scratch, refreshing both
    ``cache.highlights`` and ``cache.post_stacks``. Caller owns
    the decision of whether to call us versus the incremental
    path — we just do the work."""
    var post = List[List[Frame]]()
    var hls = tokenize_with_grammar_full(grammar, lines, post)
    cache.highlights = hls.copy()
    cache.post_stacks = post^
    return hls^


fn _fallback_for_extension(
    ext: String, lines: List[String],
) -> List[Highlight]:
    """The "no TextMate grammar usable" branch shared by the
    incremental + non-incremental cached entry points: defer to
    the generic per-language tokenizer registry, then return
    empty if even that doesn't cover the extension."""
    var spec_opt = _lang_spec_for_ext(ext)
    if spec_opt:
        return _highlight_generic(lines, spec_opt.value())
    return List[Highlight]()


fn _try_textmate(
    ext: String, lines: List[String],
) -> Optional[List[Highlight]]:
    """Load the matching TextMate grammar (if any) and tokenize.

    Returns ``None`` to signal "fall back to the generic tokenizer"
    on three conditions:

    1. No bundled grammar for this extension.
    2. Loading or tokenizing raised (malformed JSON, regex libonig
       can't compile, etc.) — better degrade than crash the editor.
    3. The grammar ran cleanly but emitted *zero* highlights against
       non-empty input. That's the signal that the grammar relies on
       a feature our runtime doesn't implement (typically ``while``
       rules); the generic tokenizer is a better answer than blank.
    """
    var path = _grammar_path_for_ext(ext)
    if len(path.as_bytes()) == 0:
        return Optional[List[Highlight]]()
    try:
        var g = load_grammar_from_file(path)
        var hls = tokenize_with_grammar(g, lines)
        if len(hls) == 0 and _has_nonempty_line(lines):
            return Optional[List[Highlight]]()
        return Optional[List[Highlight]](hls^)
    except:
        return Optional[List[Highlight]]()


fn _has_nonempty_line(lines: List[String]) -> Bool:
    """Returns True if ``lines`` contains at least one non-empty
    line. Used to disambiguate "grammar produced nothing" from
    "input was empty so of course nothing was produced."""
    for i in range(len(lines)):
        if len(lines[i].as_bytes()) > 0:
            return True
    return False


# --- shared lexical helpers ------------------------------------------------
#
# Used by ``_highlight_generic_line`` (the fallback per-language
# tokenizer) and ``word_at`` (the editor's identifier-around-cursor
# helper). The bespoke Mojo/Python tokenizer that previously lived
# here was retired in favor of TextMate grammars in
# ``src/turbokod/grammars/{python,mojo}.tmLanguage.json``.


# --- bespoke Mojo/Python per-line tokenizer (retired) ----------------------
# The block that lived here was the original triple-quote/docstring-aware
# tokenizer for ``.mojo`` / ``.py``. It was removed once those file types
# moved onto TextMate grammars (``grammars/{python,mojo}.tmLanguage.json``).
# What remains below is the lexical-classification helpers
# (``_is_ident_start`` etc.) that the *generic* fallback tokenizer and
# ``word_at`` still depend on.


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
