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
    Attr, STYLE_NONE, STYLE_BOLD, STYLE_ITALIC, STYLE_UNDERLINE,
    EDITOR_BG, EDITOR_FG, SYN_KEYWORD, SYN_STRING, SYN_COMMENT, SYN_NUMBER,
    SYN_IDENT, SYN_DECORATOR, SYN_OPERATOR,
)
from .diff import DIFF_ROW_REMOVED, DiffRow
from .grammar_install import (
    built_in_downloadable_grammars,
    find_downloadable_grammar_by_language,
    user_grammar_path,
    user_grammar_path_for_ext,
)
from .project_grammars import GrammarOverride
from .string_utils import codepoint_at, is_word_codepoint, prev_codepoint_start, starts_with
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


# Public colors. They render against the editor background (``EDITOR_BG``) and
# use the reserved per-token slots, so the active theme controls every token
# hue independently of the chrome palette. The default ("Turbo C++ 3.0") theme
# sets these slots to the classic white/red/cyan/etc. RGB, so the look is
# unchanged until the user picks another theme.
def highlight_keyword_attr() -> Attr:    return Attr(SYN_KEYWORD,   EDITOR_BG, STYLE_NONE)
def highlight_string_attr()  -> Attr:    return Attr(SYN_STRING,    EDITOR_BG, STYLE_NONE)
def highlight_comment_attr() -> Attr:    return Attr(SYN_COMMENT,   EDITOR_BG, STYLE_NONE)
def highlight_number_attr()  -> Attr:    return Attr(SYN_NUMBER,    EDITOR_BG, STYLE_NONE)
def highlight_ident_attr()   -> Attr:    return Attr(SYN_IDENT,     EDITOR_BG, STYLE_NONE)
def highlight_decorator_attr() -> Attr:  return Attr(SYN_DECORATOR, EDITOR_BG, STYLE_NONE)
def highlight_operator_attr()  -> Attr:  return Attr(SYN_OPERATOR,  EDITOR_BG, STYLE_NONE)


# Per-line state passed between calls to ``_highlight_generic_line``.
# ``_HL_NORMAL`` is the default; ``_HL_IN_BLOCK_COMMENT`` (defined
# alongside the generic tokenizer below) means the line opened
# inside an unfinished ``/* ... */`` from a previous row.
comptime _HL_NORMAL          = 0


def highlight_for_extension(
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

    After the base tokenization, we run the IntelliJ-style language-
    injection pass — ``# language=html`` / ``// language=html``
    markers re-tokenize the *next* string literal's body with the
    named grammar.
    """
    var hls: List[Highlight]
    var tm_opt = _try_textmate(ext, lines)
    if tm_opt:
        hls = tm_opt.value().copy()
    else:
        hls = _fallback_for_extension(ext, lines)
    var injection_registry = GrammarRegistry()
    _apply_intellij_injections(ext, lines, hls, injection_registry)
    return hls^


def bundled_grammar_languages() -> List[String]:
    """The ``language_id`` of every grammar shipped in-tree. Keep in
    sync with ``_bundled_grammar_path_for_language`` below — this is the
    list form of the same source of truth, used to populate the
    project-grammar override picker. Downloadable-but-unbundled
    languages (elm, django-html) come from
    ``built_in_downloadable_grammars`` and are merged in by the picker."""
    var out = List[String]()
    out.append(String("python"))
    out.append(String("mojo"))
    out.append(String("rust"))
    out.append(String("json"))
    out.append(String("go"))
    out.append(String("typescript"))
    out.append(String("javascript"))
    out.append(String("ruby"))
    out.append(String("cpp"))
    out.append(String("shell"))
    out.append(String("sql"))
    out.append(String("yaml"))
    out.append(String("html"))
    out.append(String("css"))
    out.append(String("diff"))
    out.append(String("markdown"))
    out.append(String("rst"))
    return out^


def _bundled_grammar_path_for_language(lang: String) -> String:
    """Return the bundled grammar JSON path for ``language_id``
    (``"python"``, ``"rust"``, ``"django-html"``, …), or ``""`` when
    no grammar with that id is shipped in-tree. Same source of truth
    as ``_grammar_path_for_ext``; the two functions exist because the
    bundled map is keyed by *extension* (one language can own
    several) while overrides resolve by *language_id*.
    """
    if lang == String("python"):
        return String("src/turbokod/grammars/python.tmLanguage.json")
    if lang == String("mojo"):
        return String("src/turbokod/grammars/mojo.tmLanguage.json")
    if lang == String("rust"):
        return String("src/turbokod/grammars/rust.tmLanguage.json")
    if lang == String("json"):
        return String("src/turbokod/grammars/json.tmLanguage.json")
    if lang == String("go"):
        return String("src/turbokod/grammars/go.tmLanguage.json")
    if lang == String("typescript"):
        return String("src/turbokod/grammars/typescript.tmLanguage.json")
    if lang == String("javascript"):
        return String("src/turbokod/grammars/javascript.tmLanguage.json")
    if lang == String("ruby"):
        return String("src/turbokod/grammars/ruby.tmLanguage.json")
    if lang == String("cpp"):
        return String("src/turbokod/grammars/cpp.tmLanguage.json")
    if lang == String("shell"):
        return String("src/turbokod/grammars/shell.tmLanguage.json")
    if lang == String("sql"):
        return String("src/turbokod/grammars/sql.tmLanguage.json")
    if lang == String("yaml"):
        return String("src/turbokod/grammars/yaml.tmLanguage.json")
    if lang == String("html"):
        return String("src/turbokod/grammars/html.tmLanguage.json")
    if lang == String("css"):
        return String("src/turbokod/grammars/css.tmLanguage.json")
    if lang == String("diff"):
        return String("src/turbokod/grammars/diff.tmLanguage.json")
    if lang == String("markdown"):
        return String("src/turbokod/grammars/markdown.tmLanguage.json")
    if lang == String("rst"):
        return String("src/turbokod/grammars/rst.tmLanguage.json")
    return String("")


def _grammar_path_for_language(lang: String) -> String:
    """Resolve a ``language_id`` to an on-disk grammar JSON path:
    bundled first, then a user-installed grammar at
    ``~/.config/turbokod/languages/<lang>/<lang>.tmLanguage.json``.
    Empty string when the language is not known anywhere."""
    var bundled = _bundled_grammar_path_for_language(lang)
    if len(bundled.as_bytes()) > 0:
        return bundled
    var user = user_grammar_path(lang)
    if len(user.as_bytes()) == 0:
        return String("")
    return user


def _grammar_path_for_ext(ext: String) -> String:
    """Map extension → grammar JSON path, relative to project root.

    Empty string means "no grammar for this extension." Adding a
    new grammar is one entry here plus the JSON file under
    ``src/turbokod/grammars/``. The companion
    ``_bundled_grammar_path_for_language`` resolves by ``language_id``
    for the project-override path; keep the two in sync.
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
    if ext == String("sql"):
        return String("src/turbokod/grammars/sql.tmLanguage.json")
    if ext == String("yaml") or ext == String("yml"):
        return String("src/turbokod/grammars/yaml.tmLanguage.json")
    if ext == String("html") or ext == String("htm"):
        return String("src/turbokod/grammars/html.tmLanguage.json")
    if ext == String("css"):
        return String("src/turbokod/grammars/css.tmLanguage.json")
    if ext == String("diff") or ext == String("patch"):
        return String("src/turbokod/grammars/diff.tmLanguage.json")
    if ext == String("rst") or ext == String("rest"):
        return String("src/turbokod/grammars/rst.tmLanguage.json")
    # Markdown — the vscode grammar is dominated by ``while`` rules
    # (block-context tracking) and external-grammar embedding (code
    # fences). Without those, leaving it on the generic fallback
    # actually produces nothing for ``.md`` today; keeping the
    # grammar bundled but unmapped lets a follow-up wire it up once
    # we grow ``while`` support.
    #
    # Final fallback: a downloadable grammar the user already
    # accepted the install prompt for, sitting at
    # ``~/.config/turbokod/languages/<lang>/<lang>.tmLanguage.json``.
    # Returns empty if the registry doesn't know this extension or
    # the file isn't on disk yet, in which case the highlighter
    # degrades to its generic per-language fallback.
    return user_grammar_path_for_ext(ext)


@fieldwise_init
struct _ResolvedGrammar(Copyable, Movable):
    """Output of ``_resolve_grammar_path``: the JSON path to load and
    the registry key the resulting ``Grammar`` should be cached under.
    Empty ``path`` means no grammar is available for the extension.
    ``cache_key`` is the override's language_id when an override
    fires, the bare extension otherwise — distinct keys so an
    override-bound editor doesn't share a compiled grammar with one
    that wasn't.
    """
    var path: String
    var cache_key: String


def _resolve_grammar_path(
    ext: String, registry: GrammarRegistry,
) -> _ResolvedGrammar:
    """Pick the grammar JSON path for ``ext``, honouring per-project
    overrides held on ``registry``."""
    var lang = registry.lookup_override(ext)
    if len(lang.as_bytes()) > 0:
        var p = _grammar_path_for_language(lang)
        if len(p.as_bytes()) > 0:
            return _ResolvedGrammar(p, lang)
    return _ResolvedGrammar(_grammar_path_for_ext(ext), ext)


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
    var overrides: List[GrammarOverride]

    def __init__(out self):
        self.keys = List[String]()
        self.grammars = List[Grammar]()
        self.overrides = List[GrammarOverride]()

    def lookup_idx(self, key: String) -> Int:
        """Index of the cached grammar for ``key``, or -1.
        ``key`` is whatever the caller wants to key on — typically
        the file extension (``"rs"``, ``"py"``).
        """
        for i in range(len(self.keys)):
            if self.keys[i] == key:
                return i
        return -1

    def lookup_override(self, ext: String) -> String:
        """Return the configured ``language_id`` for ``ext``, or the
        empty string when no per-project override applies. Used by
        ``_resolve_grammar_path`` to swap the default grammar for the
        one named in ``.turbokod/grammars.json``.
        """
        for i in range(len(self.overrides)):
            if self.overrides[i].ext == ext:
                return self.overrides[i].language_id
        return String("")

    def set_overrides(mut self, var overrides: List[GrammarOverride]):
        """Replace the per-project override map and drop the grammar
        cache so the next paint reloads against the new mapping.

        Clearing the whole cache (rather than surgically evicting just
        the entries whose extension changed) is fine because this only
        runs on project open / close, not on every keystroke."""
        self.overrides = overrides^
        self.keys = List[String]()
        self.grammars = List[Grammar]()


struct HighlightCache(Copyable, Movable):
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

    def __init__(out self):
        self.ext = String("")
        self.highlights = List[Highlight]()
        self.post_stacks = List[List[Frame]]()

    def __copyinit__(mut self, copy: Self):
        # Deep-copy the cached state. Editor's ``Copyable`` declaration
        # exists for snapshotting; in the live path editors are grown via
        # ``^`` transfer so this branch is rare.
        self.ext = copy.ext
        self.highlights = copy.highlights.copy()
        self.post_stacks = List[List[Frame]]()
        for i in range(len(copy.post_stacks)):
            self.post_stacks.append(copy.post_stacks[i].copy())

    def invalidate(mut self):
        """Drop the per-line state — used when the line count or
        extension shifts in a way the incremental path can't
        reconcile."""
        self.highlights = List[Highlight]()
        self.post_stacks = List[List[Frame]]()


def highlight_for_extension_cached(
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


def _hl_buckets(hls: List[Highlight], n: Int) -> List[List[Highlight]]:
    """Bucket a flat highlight list by source row (one list per row)."""
    var buckets = List[List[Highlight]]()
    for _ in range(n):
        buckets.append(List[Highlight]())
    for h in range(len(hls)):
        var r = hls[h].row
        if 0 <= r and r < n:
            buckets[r].append(hls[h])
    return buckets^


def diff_row_highlights(
    rows: List[DiffRow],
    before_lines: List[String], after_lines: List[String],
    file_path: String, mut registry: GrammarRegistry,
) -> List[List[Highlight]]:
    """Per-diff-row syntax spans for the inline diff view. Tokenizes both
    sides once (multi-line scopes resolve correctly per side), then maps each
    row to its own side's tokens: context/added rows pull from the after-file
    tokenization, removed rows from the before-file. Returns a list parallel
    to ``rows``; each inner list's ``col_start``/``col_end`` are byte offsets
    into that row's text."""
    var out = List[List[Highlight]]()
    var ext = extension_of(file_path)
    var after_cache = HighlightCache()
    var after_hl = highlight_for_extension_cached(
        ext, after_lines, registry, after_cache,
    )
    var before_cache = HighlightCache()
    var before_hl = highlight_for_extension_cached(
        ext, before_lines, registry, before_cache,
    )
    var after_buckets = _hl_buckets(after_hl, len(after_lines))
    var before_buckets = _hl_buckets(before_hl, len(before_lines))
    for i in range(len(rows)):
        var sr = rows[i].src_row
        if rows[i].kind == DIFF_ROW_REMOVED:
            if 0 <= sr and sr < len(before_buckets):
                out.append(before_buckets[sr].copy())
            else:
                out.append(List[Highlight]())
        else:
            if 0 <= sr and sr < len(after_buckets):
                out.append(after_buckets[sr].copy())
            else:
                out.append(List[Highlight]())
    return out^


def highlight_incremental(
    ext: String, lines: List[String], dirty_row: Int,
    mut registry: GrammarRegistry, mut cache: HighlightCache,
    dirty_max_row: Int = -1,
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

    ``dirty_max_row`` is the *highest* row the triggering edit
    touched. For a single-row edit it equals ``dirty_row`` (or is
    left ``-1``) and changes nothing. For an in-place multi-row edit
    that doesn't change the line count — toggle-comment, indent, a
    multi-caret type — it's the bottom of the edited range, and we
    forbid the post-stack early-exit from firing before that row.
    Otherwise the tokenizer would rejoin the cached trajectory at the
    *first* edited row (a single-line comment returns to the base
    stack immediately) and splice stale highlights over the edited
    rows below it.

    Falls back to a full retokenize when the cache is cold, the
    extension changed, the line count changed, or ``dirty_row``
    is 0. Falls through to the generic tokenizer when there's no
    bundled grammar for the extension.
    """
    var resolved = _resolve_grammar_path(ext, registry)
    var path = resolved.path
    var cache_key = resolved.cache_key
    if len(path.as_bytes()) == 0:
        var fb = _fallback_for_extension(ext, lines)
        _apply_intellij_injections(ext, lines, fb, registry)
        _apply_django_template_overlay(cache_key, lines, fb)
        return fb^

    # Grammar load — registry hit if the cache_key is already known,
    # else cold load + register. The registry is process-shared so
    # the next ``Editor`` for the same language reuses the same
    # ``Grammar`` instance instead of re-parsing the JSON and
    # re-allocating libonig handles. ``cache_key`` is the language_id
    # when an override fires, the bare extension otherwise — keeping
    # them distinct prevents an override-bound editor from sharing a
    # grammar with one that wasn't.
    var grammar_idx = registry.lookup_idx(cache_key)
    if grammar_idx < 0:
        try:
            var g = load_grammar_from_file(path)
            registry.keys.append(cache_key)
            registry.grammars.append(g^)
            grammar_idx = len(registry.keys) - 1
        except:
            var fb = _fallback_for_extension(ext, lines)
            _apply_intellij_injections(ext, lines, fb, registry)
            _apply_django_template_overlay(cache_key, lines, fb)
            return fb^

    # Per-Editor state: invalidate when the cache key changes (either
    # the extension itself moved or the project's override map did).
    if cache.ext != cache_key:
        cache.invalidate()
        cache.ext = cache_key

    # Decide whether we can incrementalize. Conditions for "yes":
    #   * cache is warm: we already tokenized this extension before
    #     and have ``post_stacks`` of the right length;
    #   * eff_dirty > 0 (else there's nothing to skip — full retokenize);
    #   * eff_dirty is in range.
    # Anything else collapses to a full retokenize.
    var n_lines = len(lines)
    # An edit on row R can stale row R-1's cached result, not just R's: a
    # grammar with a multi-line end regex (``end: "\\n..."``) tokenizes row
    # R-1 against ``line[R-1] + "\n" + line[R]``, so row R-1's highlights and
    # post-stack depend on row R's text. Back the incremental window up one
    # row so that coupling can't leave stale highlights above the edit.
    # Costs one extra row of tokenizing; an edit at row 1 collapses to a full
    # retokenize (eff_dirty == 0), which is correct.
    var eff_dirty = dirty_row - 1
    var can_incr = (eff_dirty > 0
                    and eff_dirty <= n_lines
                    and len(cache.post_stacks) == n_lines)
    if not can_incr:
        var hls = _full_retokenize(
            registry.grammars[grammar_idx], cache, lines,
        )
        if len(hls) == 0 and _has_nonempty_line(lines):
            var fb = _fallback_for_extension(ext, lines)
            _apply_intellij_injections(ext, lines, fb, registry)
            _apply_django_template_overlay(cache_key, lines, fb)
            return fb^
        _apply_intellij_injections(ext, lines, hls, registry)
        _apply_django_template_overlay(cache_key, lines, hls)
        return hls^

    # Incremental path. Start state = post-state at end of line
    # (eff_dirty - 1), i.e. what eff_dirty was tokenized against
    # last time. The tokenizer itself stops as soon as state
    # rejoins the cached trajectory and reports back via
    # ``stable_row``.
    var start_stack = cache.post_stacks[eff_dirty - 1].copy()
    var new_post = List[List[Frame]]()
    var stable_row: Int = 0
    # Earliest row the tokenizer may early-exit on: the bottom of the
    # edited range, so every in-place-edited row is re-tokenized before
    # we trust the cached tail. Defaults to ``dirty_row`` (classic
    # single-row behaviour) when no high-water mark was supplied.
    var min_row = dirty_row
    if dirty_max_row > min_row:
        min_row = dirty_max_row
    var new_hls = tokenize_lines_from(
        registry.grammars[grammar_idx], lines, eff_dirty, min_row,
        start_stack, cache.post_stacks, new_post, stable_row,
    )

    # Splice highlights:
    #   1. Keep cached highlights with row < eff_dirty.
    #   2. Append re-tokenized highlights (rows ``[eff_dirty,
    #      stable_row)``).
    #   3. Append cached highlights with row >= stable_row.
    # ``new_hls`` already contains only rows up to ``stable_row``
    # because that's where the tokenizer stopped.
    var out = List[Highlight]()
    for i in range(len(cache.highlights)):
        if cache.highlights[i].row < eff_dirty:
            out.append(cache.highlights[i])
    for i in range(len(new_hls)):
        out.append(new_hls[i])
    if stable_row < n_lines:
        for i in range(len(cache.highlights)):
            if cache.highlights[i].row >= stable_row:
                out.append(cache.highlights[i])

    # Update cached post_stacks: replace ``[eff_dirty, stable_row)``
    # with the new ones, keep cached entries below eff_dirty and
    # at-or-above stable_row.
    var updated_stacks = List[List[Frame]]()
    for i in range(eff_dirty):
        updated_stacks.append(cache.post_stacks[i].copy())
    for k in range(len(new_post)):
        updated_stacks.append(new_post[k].copy())
    if stable_row < len(cache.post_stacks):
        for i in range(stable_row, len(cache.post_stacks)):
            updated_stacks.append(cache.post_stacks[i].copy())
    cache.post_stacks = updated_stacks^
    cache.highlights = out.copy()

    if len(out) == 0 and _has_nonempty_line(lines):
        var fb = _fallback_for_extension(ext, lines)
        _apply_intellij_injections(ext, lines, fb, registry)
        _apply_django_template_overlay(cache_key, lines, fb)
        return fb^
    _apply_intellij_injections(ext, lines, out, registry)
    _apply_django_template_overlay(cache_key, lines, out)
    return out^


def _full_retokenize(
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


def _fallback_for_extension(
    ext: String, lines: List[String],
) -> List[Highlight]:
    """The "no TextMate grammar usable" branch shared by the
    incremental + non-incremental cached entry points: defer to
    the generic per-language tokenizer registry, then return
    empty if even that doesn't cover the extension."""
    if _is_markdown_ext(ext):
        return _highlight_markdown(lines)
    var spec_opt = _lang_spec_for_ext(ext)
    if spec_opt:
        return _highlight_generic(lines, spec_opt.value())
    return List[Highlight]()


def _try_textmate(
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


def _has_nonempty_line(lines: List[String]) -> Bool:
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


def _is_ident_start(c: UInt8) -> Bool:
    var v = Int(c)
    if v == 0x5F:  # _
        return True
    if 0x41 <= v and v <= 0x5A:
        return True
    if 0x61 <= v and v <= 0x7A:
        return True
    return False


def _is_ident_part(c: UInt8) -> Bool:
    if _is_ident_start(c):
        return True
    var v = Int(c)
    return 0x30 <= v and v <= 0x39


def _is_digit(c: UInt8) -> Bool:
    var v = Int(c)
    return 0x30 <= v and v <= 0x39


def _is_operator(c: UInt8) -> Bool:
    var v = Int(c)
    return v == 0x2B or v == 0x2D or v == 0x2A or v == 0x2F \
        or v == 0x25 or v == 0x3D or v == 0x3C or v == 0x3E \
        or v == 0x21 or v == 0x26 or v == 0x7C or v == 0x5E \
        or v == 0x7E or v == 0x40 or v == 0x28 or v == 0x29 \
        or v == 0x2E or v == 0x3A or v == 0x5B or v == 0x5D \
        or v == 0x7B or v == 0x7D



# --- editor-side helpers ---------------------------------------------------


def extension_of(path: String) -> String:
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


def line_comment_for_extension(ext: String) -> String:
    """Return the line-comment prefix (with trailing space) for ``ext``,
    or empty when the language has no single-line comment syntax.

    Covers the languages our highlighter knows about plus the common
    config-file extensions. Empty result is a signal — callers fall
    back to a sensible default rather than producing invalid syntax.
    """
    # `//` family — C, C++, Rust, Go, JS/TS, Zig, JVM family, Swift, etc.
    if ext == String("rs") or ext == String("c") or ext == String("h") \
            or ext == String("cc") or ext == String("cpp") \
            or ext == String("cxx") or ext == String("hpp") \
            or ext == String("hh") or ext == String("hxx") \
            or ext == String("go") or ext == String("ts") \
            or ext == String("tsx") or ext == String("js") \
            or ext == String("jsx") or ext == String("mjs") \
            or ext == String("cjs") or ext == String("zig") \
            or ext == String("java") or ext == String("kt") \
            or ext == String("kts") or ext == String("scala") \
            or ext == String("swift") or ext == String("dart") \
            or ext == String("cs") or ext == String("m") \
            or ext == String("mm") or ext == String("php") \
            or ext == String("jsonc") or ext == String("groovy"):
        return String("// ")
    # `#` family — Python, Mojo, shells, Ruby, Perl, R, YAML, TOML, configs.
    if ext == String("py") or ext == String("mojo") \
            or ext == String("sh") or ext == String("bash") \
            or ext == String("zsh") or ext == String("fish") \
            or ext == String("rb") or ext == String("pl") \
            or ext == String("pm") or ext == String("r") \
            or ext == String("yaml") or ext == String("yml") \
            or ext == String("toml") or ext == String("conf") \
            or ext == String("ini") or ext == String("cfg") \
            or ext == String("dockerfile") or ext == String("mk") \
            or ext == String("makefile") or ext == String("gitignore") \
            or ext == String("ps1"):
        return String("# ")
    # `--` family — SQL, Lua, Haskell, Elm, Ada.
    if ext == String("sql") or ext == String("lua") \
            or ext == String("hs") or ext == String("elm") \
            or ext == String("ada"):
        return String("-- ")
    # `;` family — Lisp dialects, Scheme, assembly.
    if ext == String("clj") or ext == String("cljs") \
            or ext == String("edn") or ext == String("lisp") \
            or ext == String("scm") or ext == String("rkt") \
            or ext == String("asm") or ext == String("s"):
        return String("; ")
    # `%` — TeX/LaTeX, Erlang, Prolog.
    if ext == String("tex") or ext == String("latex") \
            or ext == String("erl") or ext == String("prolog"):
        return String("% ")
    return String("")


def word_at(line: String, col: Int) -> String:
    """Return the identifier surrounding ``col`` (start ≤ col ≤ end), or
    empty string when ``col`` isn't on an identifier codepoint. Walks
    by UTF-8 codepoint so non-ASCII letters (``ä``, Cyrillic, CJK)
    cluster with their neighbors rather than splitting the word."""
    var b = line.as_bytes()
    var n = len(b)
    if col < 0 or col >= n:
        return String("")
    var here = codepoint_at(line, col)
    if not is_word_codepoint(here[0]):
        return String("")
    var start = col
    while start > 0:
        var prev = prev_codepoint_start(line, start)
        var info = codepoint_at(line, prev)
        if not is_word_codepoint(info[0]):
            break
        start = prev
    var end = col + here[1]
    while end < n:
        var info = codepoint_at(line, end)
        if not is_word_codepoint(info[0]):
            break
        end += info[1]
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


@fieldwise_init
struct EditorContextMenuRequest(ImplicitlyCopyable, Movable):
    """Payload emitted when the user right-clicks plain identifier text
    (not a diagnostic squiggle or a breakpoint gutter dot). Hosts poll
    ``Editor.consume_context_menu_request()`` and open a popup of
    symbol actions (Rename / Go to Definition / Find References) anchored
    at ``(anchor_x, anchor_y)``. ``row`` / ``col`` are the buffer
    coordinates under the click and ``word`` is the identifier there, so
    the host can act without re-resolving the hit."""
    var row: Int
    var col: Int
    var word: String
    var anchor_x: Int
    var anchor_y: Int


@fieldwise_init
struct CompletionRequest(ImplicitlyCopyable, Movable):
    """Payload emitted by the editor when the user invokes completion
    (Ctrl+Space). Hosts poll ``Editor.consume_completion_request()`` and
    forward to whichever LSP client owns the file's language.

    ``row`` / ``col`` are the cursor position when the request was
    triggered; ``prefix_start_col`` is where the identifier currently
    under the cursor begins, so the host can replace that span with
    the selected completion text without re-scanning the line.

    ``manual`` is True when the user explicitly invoked completion
    (Ctrl+Space / bound action), False when the request was stamped by
    the as-you-type auto-trigger. Hosts use it to decide whether an
    empty response should surface a ``<no completion found>`` message
    (manual: yes — the user is waiting on feedback) or be silently
    dropped (auto: noise)."""
    var row: Int
    var col: Int
    var prefix_start_col: Int
    var manual: Bool


@fieldwise_init
struct HoverRequest(ImplicitlyCopyable, Movable):
    """Payload emitted by the editor when the user dwell-hovers over an
    identifier. Hosts poll ``Editor.consume_hover_request()`` and forward
    to ``LspManager.request_hover`` for the matching language; the
    response is routed back via ``Editor.set_hover_result``."""
    var row: Int
    var col: Int


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


struct LangSpec(Copyable, Movable):
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

    def __init__(
        out self, var keywords: List[String], var line_comment: String,
        var block_open: String, var block_close: String, var quotes: String,
    ):
        self.keywords = keywords^
        self.line_comment = line_comment^
        self.block_open = block_open^
        self.block_close = block_close^
        self.quotes = quotes^

    def __copyinit__(mut self, copy: Self):
        self.keywords = copy.keywords.copy()
        self.line_comment = copy.line_comment
        self.block_open = copy.block_open
        self.block_close = copy.block_close
        self.quotes = copy.quotes


def _lang_spec_for_ext(ext: String) -> Optional[LangSpec]:
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


def _kw(*words: String) -> List[String]:
    var out = List[String]()
    for w in words:
        out.append(String(w))
    return out^


def _spec_rust() -> Optional[LangSpec]:
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


def _spec_c() -> Optional[LangSpec]:
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


def _spec_go() -> Optional[LangSpec]:
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


def _spec_ts() -> Optional[LangSpec]:
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


def _spec_zig() -> Optional[LangSpec]:
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


def _spec_jvm_like() -> Optional[LangSpec]:
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


def _spec_bash() -> Optional[LangSpec]:
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


def _spec_ruby() -> Optional[LangSpec]:
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


def _spec_json() -> Optional[LangSpec]:
    # JSONC supports // and /*..*/; plain JSON doesn't, but accepting them
    # is harmless on a strict file (they just won't appear).
    return LangSpec(
        _kw(String("true"), String("false"), String("null")),
        String("//"), String("/*"), String("*/"), String("\""),
    )


def _spec_yaml() -> Optional[LangSpec]:
    return LangSpec(
        _kw(
            String("true"), String("false"), String("null"), String("yes"),
            String("no"), String("on"), String("off"),
        ),
        String("#"), String(""), String(""), String("\"'"),
    )


def _spec_toml() -> Optional[LangSpec]:
    return LangSpec(
        _kw(String("true"), String("false")),
        String("#"), String(""), String(""), String("\"'"),
    )


# --- Markdown -------------------------------------------------------------
#
# Markdown isn't keyword/comment/string-shaped, so the generic ``LangSpec``
# tokenizer produces nothing useful for it, and the vscode TextMate grammar
# leans on ``while``-rules our runtime doesn't implement (which is why
# ``.md`` rendered uncolored before this). This is a small bespoke
# tokenizer covering the constructs that actually carry meaning in a
# ``.md`` file: fenced code blocks (the one cross-line state), ATX
# headings, blockquotes, list markers, thematic breaks, and the inline run
# of ``code``, ``**bold**``, ``*italic*``, and ``[links](url)``. Spans are
# byte offsets like every other highlighter here.


def _is_markdown_ext(ext: String) -> Bool:
    return (ext == String("md") or ext == String("markdown")
            or ext == String("mdown") or ext == String("mkd")
            or ext == String("mkdn") or ext == String("mdx"))


def _md_heading_attr()   -> Attr: return Attr(SYN_KEYWORD, EDITOR_BG, STYLE_BOLD)
def _md_code_attr()      -> Attr: return Attr(SYN_STRING,  EDITOR_BG, STYLE_NONE)
def _md_fence_attr()     -> Attr: return Attr(SYN_COMMENT, EDITOR_BG, STYLE_NONE)
def _md_quote_attr()     -> Attr: return Attr(SYN_COMMENT, EDITOR_BG, STYLE_ITALIC)
def _md_marker_attr()    -> Attr: return Attr(SYN_OPERATOR, EDITOR_BG, STYLE_NONE)
def _md_bold_attr()      -> Attr: return Attr(EDITOR_FG,   EDITOR_BG, STYLE_BOLD)
def _md_italic_attr()    -> Attr: return Attr(EDITOR_FG,   EDITOR_BG, STYLE_ITALIC)
def _md_link_text_attr() -> Attr: return Attr(SYN_IDENT,   EDITOR_BG, STYLE_UNDERLINE)
def _md_link_url_attr()  -> Attr: return Attr(SYN_STRING,  EDITOR_BG, STYLE_NONE)


@fieldwise_init
struct _MdRun(Copyable, Movable):
    """A run of identical bytes: which byte, and how many."""
    var char: UInt8
    var length: Int


def _md_fence_run(line: String, start: Int) -> _MdRun:
    """Run of backticks/tildes at ``start`` — the fence opener shape.
    ``length`` is 0 when ``start`` isn't a backtick or tilde."""
    var b = line.as_bytes()
    var n = len(b)
    if start >= n:
        return _MdRun(0, 0)
    var c = b[start]
    if c != 0x60 and c != 0x7E:  # ` or ~
        return _MdRun(c, 0)
    var i = start
    while i < n and b[i] == c:
        i += 1
    return _MdRun(c, i - start)


def _md_only_ws_after(line: String, frm: Int) -> Bool:
    """Is everything from ``frm`` to end-of-line whitespace? Used to
    validate a closing fence (no info string allowed after it)."""
    var b = line.as_bytes()
    var k = frm
    while k < len(b):
        if b[k] != 0x20 and b[k] != 0x09:
            return False
        k += 1
    return True


def _md_is_hr(line: String, indent: Int) -> Bool:
    """Thematic break: 3+ of ``-``/``*``/``_`` and nothing else but
    spaces (e.g. ``---``, ``* * *``)."""
    var b = line.as_bytes()
    var n = len(b)
    if indent >= n:
        return False
    var c = b[indent]
    if c != 0x2D and c != 0x2A and c != 0x5F:  # - * _
        return False
    var count = 0
    var k = indent
    while k < n:
        var ch = b[k]
        if ch == c:
            count += 1
        elif ch != 0x20 and ch != 0x09:
            return False
        k += 1
    return count >= 3


def _md_list_marker_len(line: String, indent: Int) -> Int:
    """Length of the list marker at ``indent`` (the ``-``/``*``/``+`` or
    the ``1.``/``2)`` run, not counting the required trailing space), or
    0 when there's no marker."""
    var b = line.as_bytes()
    var n = len(b)
    if indent >= n:
        return 0
    var c = b[indent]
    # Bullet: - * + then a space/tab.
    if c == 0x2D or c == 0x2A or c == 0x2B:
        if indent + 1 < n and (b[indent + 1] == 0x20 or b[indent + 1] == 0x09):
            return 1
        return 0
    # Ordered: digits then . or ) then a space/tab.
    if _is_digit(c):
        var k = indent
        while k < n and _is_digit(b[k]):
            k += 1
        if k < n and (b[k] == 0x2E or b[k] == 0x29):  # . or )
            var mk = k + 1
            if mk < n and (b[mk] == 0x20 or b[mk] == 0x09):
                return mk - indent
    return 0


def _md_find_tick_close(line: String, frm: Int, ticks: Int) -> Int:
    """Index of the next run of exactly ``ticks`` backticks at/after
    ``frm`` (the inline-code closer), or -1."""
    var b = line.as_bytes()
    var n = len(b)
    var i = frm
    while i < n:
        if b[i] == 0x60:
            var run = 0
            var k = i
            while k < n and b[k] == 0x60:
                run += 1
                k += 1
            if run == ticks:
                return i
            i = k
        else:
            i += 1
    return -1


def _md_try_emphasis(
    line: String, row: Int, i: Int, mut out: List[Highlight],
) -> Int:
    """Try to color a ``*``/``_`` emphasis span starting at ``i``. Two
    markers → bold, one → italic. Returns bytes consumed, or 0 if it
    isn't a well-formed span (no closer, or wraps whitespace)."""
    var b = line.as_bytes()
    var n = len(b)
    var c = b[i]
    var run = 0
    var k = i
    while k < n and b[k] == c:
        run += 1
        k += 1
    var marker = 2 if run >= 2 else 1
    var open_end = i + marker
    # An opener can't be followed by whitespace (``* not emphasis``).
    if open_end >= n or b[open_end] == 0x20 or b[open_end] == 0x09:
        return 0
    var j = open_end
    while j < n:
        if b[j] == 0x5C and j + 1 < n:  # backslash escape
            j += 2
            continue
        if b[j] == c:
            var crun = 0
            var m = j
            while m < n and b[m] == c:
                crun += 1
                m += 1
            # A closer can't be preceded by whitespace.
            if crun >= marker and b[j - 1] != 0x20 and b[j - 1] != 0x09:
                var attr = _md_bold_attr() if marker == 2 else _md_italic_attr()
                out.append(Highlight(row, i, j + marker, attr))
                return (j + marker) - i
            j = m
            continue
        j += 1
    return 0


def _md_try_link(
    line: String, row: Int, i: Int, mut out: List[Highlight],
) -> Int:
    """Try to color a ``[text](url)`` or ``![alt](url)`` link starting at
    ``i``: link text gets the link-text attr, the URL the url attr.
    Returns bytes consumed, or 0 if the shape doesn't match."""
    var b = line.as_bytes()
    var n = len(b)
    var p = i
    if b[p] == 0x21:  # ! (image)
        p += 1
    if p >= n or b[p] != 0x5B:  # [
        return 0
    var text_start = p + 1
    var q = text_start
    var depth = 1
    while q < n:
        if b[q] == 0x5C and q + 1 < n:
            q += 2
            continue
        if b[q] == 0x5B:
            depth += 1
        elif b[q] == 0x5D:  # ]
            depth -= 1
            if depth == 0:
                break
        q += 1
    if q >= n or b[q] != 0x5D:
        return 0
    var text_end = q
    var paren = q + 1
    if paren >= n or b[paren] != 0x28:  # (
        return 0
    var url_start = paren + 1
    var r = url_start
    while r < n and b[r] != 0x29:  # )
        r += 1
    if r >= n:
        return 0
    if text_end > text_start:
        out.append(Highlight(row, text_start, text_end, _md_link_text_attr()))
    if r > url_start:
        out.append(Highlight(row, url_start, r, _md_link_url_attr()))
    return (r + 1) - i


def _md_inline(
    line: String, row: Int, start: Int, mut out: List[Highlight],
):
    """Scan the inline span ``[start, eol)`` for code, emphasis, and
    links. Plain text is left uncolored (the editor paints it as the
    default foreground)."""
    var b = line.as_bytes()
    var n = len(b)
    var i = start
    while i < n:
        var c = b[i]
        if c == 0x5C and i + 1 < n:  # backslash escape
            i += 2
            continue
        if c == 0x60:  # inline code `...`
            var ticks = 0
            var k = i
            while k < n and b[k] == 0x60:
                ticks += 1
                k += 1
            var close = _md_find_tick_close(line, k, ticks)
            if close >= 0:
                out.append(Highlight(row, i, close + ticks, _md_code_attr()))
                i = close + ticks
                continue
            i = k
            continue
        if c == 0x5B or (c == 0x21 and i + 1 < n and b[i + 1] == 0x5B):
            var used = _md_try_link(line, row, i, out)
            if used > 0:
                i += used
                continue
        if c == 0x2A or c == 0x5F:  # * or _
            var used = _md_try_emphasis(line, row, i, out)
            if used > 0:
                i += used
                continue
        i += 1


def _highlight_markdown(lines: List[String]) -> List[Highlight]:
    """Bespoke Markdown highlighter — see the section comment above."""
    var out = List[Highlight]()
    var in_fence = False
    var fence_char = UInt8(0)
    var fence_len = 0
    for row in range(len(lines)):
        var line = lines[row]
        var b = line.as_bytes()
        var n = len(b)

        var indent = 0
        while indent < n and (b[indent] == 0x20 or b[indent] == 0x09):
            indent += 1

        var fc = _md_fence_run(line, indent)

        # Inside a fenced code block: every line is code until the
        # matching closing fence (same char, length >= opener, only
        # whitespace after).
        if in_fence:
            if (fc.char == fence_char and fc.length >= fence_len
                    and _md_only_ws_after(line, indent + fc.length)):
                in_fence = False
                fence_char = 0
                fence_len = 0
                if n > 0:
                    out.append(Highlight(row, 0, n, _md_fence_attr()))
            elif n > 0:
                out.append(Highlight(row, 0, n, _md_code_attr()))
            continue

        # Opening fence (``` or ~~~, optionally with an info string).
        if fc.length >= 3:
            in_fence = True
            fence_char = fc.char
            fence_len = fc.length
            if n > 0:
                out.append(Highlight(row, 0, n, _md_fence_attr()))
            continue

        # ATX heading: 1-6 '#' then a space or end-of-line.
        if indent < n and b[indent] == 0x23:  # '#'
            var h = indent
            while h < n and b[h] == 0x23:
                h += 1
            var hashes = h - indent
            if hashes <= 6 and (h >= n or b[h] == 0x20 or b[h] == 0x09):
                out.append(Highlight(row, 0, n, _md_heading_attr()))
                continue

        # Thematic break (checked before list markers so ``* * *`` and
        # ``---`` don't read as a bullet).
        if _md_is_hr(line, indent):
            out.append(Highlight(row, 0, n, _md_fence_attr()))
            continue

        # Blockquote: whole line tinted; quoted markup still reads.
        if indent < n and b[indent] == 0x3E:  # '>'
            out.append(Highlight(row, 0, n, _md_quote_attr()))
            continue

        # List marker, then inline scan over the rest.
        var content_start = indent
        var ml = _md_list_marker_len(line, indent)
        if ml > 0:
            out.append(Highlight(row, indent, indent + ml, _md_marker_attr()))
            content_start = indent + ml

        _md_inline(line, row, content_start, out)
    return out^


def _highlight_generic(
    lines: List[String], spec: LangSpec,
) -> List[Highlight]:
    var out = List[Highlight]()
    var state = _HL_NORMAL
    for row in range(len(lines)):
        state = _highlight_generic_line(lines[row], row, state, spec, out)
    return out^


def _highlight_generic_line(
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


def _is_keyword_in(word: String, keywords: List[String]) -> Bool:
    """Linear membership test. Keyword lists are short (a few dozen
    entries) and the call site already paid the identifier-extraction
    cost, so a hash table would be over-engineering."""
    for k in range(len(keywords)):
        if keywords[k] == word:
            return True
    return False


def _to_bytes_list(s: String) -> List[UInt8]:
    """Copy a string's bytes into an owned list. Used for the few
    short needle strings the tokenizer compares against — keeps the
    hot path free of ``Span`` origin parameters that ``@fieldwise_init``
    structs make awkward to thread through helpers."""
    var b = s.as_bytes()
    var out = List[UInt8]()
    for k in range(len(b)):
        out.append(b[k])
    return out^


def _starts_with(line: String, i: Int, needle: List[UInt8]) -> Bool:
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


# --- Django template-tag overlay ------------------------------------------
#
# The django-html grammar (vscode-django) threads its template tags
# (``{{ }}`` / ``{% %}`` / ``{# #}``) through the HTML structure by hand,
# so they colour correctly in markup, attributes, and text nodes. But it
# embeds ``<style>`` / ``<script>`` bodies via ``source.css.django`` /
# ``source.js`` — and once the CSS (or JS) grammar's own ``{ }`` context
# opens, no root-level django pattern can fire inside it (we don't
# implement TextMate injection grammars). So a tag like
# ``color: {{ theme }}`` inside a style block gets no django colour from
# the grammar.
#
# This post-tokenize pass fills that gap: for django-language buffers it
# scans every line for the three tag forms and overlays a colour on any
# tag the grammar left untinted. Tags the grammar already coloured (the
# whole HTML surface) are skipped, so its finer per-token colouring
# (tag-name vs. filter vs. variable) is preserved — the overlay only
# reaches the embedded CSS/JS regions, which would otherwise be plain.


@fieldwise_init
struct _DjangoTag(ImplicitlyCopyable, Movable):
    """An opener/closer byte-pair for one Django template-tag form.
    ``comment`` selects the comment colour (for ``{# #}``) over the
    keyword colour (for ``{{ }}`` / ``{% %}``)."""
    var open1: UInt8
    var close1: UInt8
    var comment: Bool


def _apply_django_template_overlay(
    lang_key: String, lines: List[String], mut hls: List[Highlight],
):
    """Overlay Django template-tag colours on ``hls`` for django-language
    buffers (``lang_key`` like ``"django-html"``). No-op for any other
    language. Only tags the base grammar left uncoloured are painted, so
    the django-html grammar's own (finer) tinting in the HTML surface is
    untouched and only embedded CSS/JS regions get filled in.

    Single-line tags are handled fully; an unterminated opener colours to
    end-of-line (rare for the embedded case this targets, and never worse
    than the plain text it replaces)."""
    if not starts_with(lang_key, String("django")):
        return
    # ``{{`` and ``{%`` read as keyword; ``{#`` as comment — matching the
    # scope→attr mapping the grammar uses for the same tags in markup.
    var forms = List[_DjangoTag]()
    forms.append(_DjangoTag(0x7B, 0x7D, False))  # {{ ... }}
    forms.append(_DjangoTag(0x25, 0x25, False))  # {% ... %}  (second byte)
    forms.append(_DjangoTag(0x23, 0x23, True))   # {# ... #}
    var kw = highlight_keyword_attr()
    var cm = highlight_comment_attr()
    var n = len(lines)
    var buckets = _hl_buckets(hls, n)
    for row in range(n):
        var b = lines[row].as_bytes()
        var L = len(b)
        ref row_hls = buckets[row]
        var col = 0
        while col + 1 < L:
            if b[col] != 0x7B:  # '{'
                col += 1
                continue
            var nb = b[col + 1]
            var matched = -1
            for fi in range(len(forms)):
                # First form opens on ``{{``; the other two on ``{%`` /
                # ``{#`` where ``open1`` is the *second* byte.
                if fi == 0:
                    if nb == 0x7B:
                        matched = 0
                        break
                elif nb == forms[fi].open1:
                    matched = fi
                    break
            if matched < 0:
                col += 1
                continue
            var form = forms[matched]
            # Find the matching two-byte closer after the opener.
            var c1: UInt8
            if matched == 0:
                c1 = 0x7D  # '}'
            else:
                c1 = form.close1
            var end = -1
            var j = col + 2
            while j + 1 < L:
                if b[j] == c1 and b[j + 1] == 0x7D:
                    end = j + 2
                    break
                j += 1
            var span_end = end if end >= 0 else L
            # Skip if the grammar already coloured this tag (its opener
            # cell carries the same django attr) — preserves the markup
            # surface's finer per-token colouring.
            var want = cm if form.comment else kw
            var already = False
            for hi in range(len(row_hls)):
                var h = row_hls[hi]
                if h.col_start <= col and col < h.col_end and h.attr == want:
                    already = True
                    break
            if not already:
                # Appended at the end of ``hls`` (after every grammar
                # span) so the editor's per-cell overlay — which applies
                # highlights in list order, later winning — paints the
                # django colour over whatever CSS/JS left underneath.
                # Consumers bucket by row, so the non-monotonic append is
                # fine; the overlay is re-derived each paint and never
                # enters the incremental cache.
                hls.append(Highlight(row, col, span_end, want))
            col = span_end


# --- IntelliJ-style language injection ------------------------------------
#
# IntelliJ recognizes a marker comment like ``# language=html`` or
# ``// language=html`` as a hint that the *next* string literal's body
# should be tokenized as the named language. We do the same: after the
# base TextMate / generic tokenizer runs, we scan for the marker, find
# the following string's body, and re-tokenize the body with the
# injected grammar — overlaying its highlights on top of (and
# replacing the body-internal portion of) the host's string highlights.
#
# Recognized markers (anywhere on a line; we just substring-match on
# ``language=NAME``):
#
#   * ``# language=html``        (Python, Ruby, shell)
#   * ``// language=html``       (JS/TS/Rust/Go/C/C++)
#   * ``<!-- language=html -->`` (HTML/XML)
#   * ``/* language=html */``    (CSS, C-family)
#
# Recognized string openings: ``"..."``, ``'...'``, `````...`````, plus
# triple variants ``"""..."""`` / ``'''...'''``. Backslash escapes are
# honored for single-char strings; triple-quoted strings span lines.
# Unterminated strings extend to end-of-buffer (single) / end-of-line
# (single-char) — same fallback the host tokenizer uses, just without
# the escape-counting bookkeeping.


@fieldwise_init
struct _LangMarker(ImplicitlyCopyable, Movable):
    """Result of ``_find_language_marker``. ``end_col`` is the byte
    offset on the same line just past the language name, so the
    string-search can start there."""
    var lang: String
    var end_col: Int


@fieldwise_init
struct _StringBody(ImplicitlyCopyable, Movable):
    """Byte-position bounds of an injected string's *body* (inside
    the quotes). ``end_col`` is exclusive (= the position of the
    closing quote)."""
    var start_row: Int
    var start_col: Int
    var end_row: Int
    var end_col: Int


def _apply_intellij_injections(
    ext: String, lines: List[String], mut hls: List[Highlight],
    mut registry: GrammarRegistry,
):
    """Scan ``lines`` for IntelliJ-style ``language=NAME`` markers and
    re-tokenize the next string literal's body with the named
    grammar. Multiple markers per buffer are honored; each marker
    consumes the string it points at, so a marker can't double-apply
    to a string already injected by a prior marker.

    For Markdown buffers we additionally run the fenced-code-block
    injection pass — same overlay mechanism, keyed off the ```` ``` ````
    fence info string instead of a marker comment."""
    if _is_markdown_ext(ext):
        _apply_markdown_fence_injections(lines, hls, registry)
    var n = len(lines)
    var i = 0
    while i < n:
        var marker_opt = _find_language_marker(lines[i])
        if marker_opt:
            var marker = marker_opt.value()
            # Look at the rest of the marker line first so an inline
            # form (``/* language=html */ "..."``) finds the string on
            # the same line. Falls through to subsequent lines via
            # ``_find_string_body_after``.
            var body_opt = _find_string_body_after(
                lines, i, marker.end_col,
            )
            if body_opt:
                var body = body_opt.value()
                _inject_grammar(
                    marker.lang, lines, body, hls, registry,
                )
                # Skip past the body so a marker inside the injected
                # body can't re-trigger.
                i = body.end_row
        i += 1


def _md_fence_info(line: String, start: Int) -> String:
    """The first whitespace-delimited token of a fence's info string
    (the language in ```` ```lang ````), or empty when the fence has
    none. Handles trailing attributes like ``js title="x"`` by taking
    only the leading word."""
    var b = line.as_bytes()
    var n = len(b)
    var i = start
    while i < n and (b[i] == 0x20 or b[i] == 0x09):
        i += 1
    var s = i
    while i < n and b[i] != 0x20 and b[i] != 0x09:
        i += 1
    if i <= s:
        return String("")
    return String(StringSlice(unsafe_from_utf8=b[s:i]))


def _apply_markdown_fence_injections(
    lines: List[String], mut hls: List[Highlight],
    mut registry: GrammarRegistry,
):
    """For each fenced code block that carries an info string
    (```` ```python ````), re-tokenize its body with that language's
    grammar and overlay the result, replacing the uniform code-color
    paint underneath. Same overlay path as the IntelliJ ``language=``
    injection, keyed off the fence info string. Fences whose language
    has no bundled (or installed) grammar are left as plain code."""
    var n = len(lines)
    var row = 0
    while row < n:
        var indent = 0
        var b = lines[row].as_bytes()
        var ln = len(b)
        while indent < ln and (b[indent] == 0x20 or b[indent] == 0x09):
            indent += 1
        var fc = _md_fence_run(lines[row], indent)
        if fc.length < 3:
            row += 1
            continue

        # Opening fence — its info string names the embedded language.
        var info = _md_fence_info(lines[row], indent + fc.length)

        # Find the matching close (same char, length >= opener, only
        # whitespace after). Unterminated fences run to end-of-buffer.
        var close = -1
        var r = row + 1
        while r < n:
            var bb = lines[r].as_bytes()
            var ind2 = 0
            while ind2 < len(bb) and (bb[ind2] == 0x20 or bb[ind2] == 0x09):
                ind2 += 1
            var fc2 = _md_fence_run(lines[r], ind2)
            if (fc2.char == fc.char and fc2.length >= fc.length
                    and _md_only_ws_after(lines[r], ind2 + fc2.length)):
                close = r
                break
            r += 1
        var body_last = (close - 1) if close >= 0 else (n - 1)

        if len(info.as_bytes()) > 0 and body_last >= row + 1:
            var last_len = len(lines[body_last].as_bytes())
            var body = _StringBody(row + 1, 0, body_last, last_len)
            _inject_grammar(_to_lower_ascii(info), lines, body, hls, registry)

        row = (close + 1) if close >= 0 else n


def _find_language_marker(line: String) -> Optional[_LangMarker]:
    """Find a ``language=NAME`` substring in ``line``. Returns the
    lowercased language name plus the byte offset just past it.

    No comment-marker check: we accept the substring anywhere on the
    line. False positives are rare in practice (the literal string
    ``language=`` followed by an identifier is uncommon outside of a
    deliberate injection comment), and gating on per-language comment
    syntax would tie this helper to the host file's extension."""
    var b = line.as_bytes()
    var n = len(b)
    var needle = String("language=")
    var nb = needle.as_bytes()
    var nlen = len(nb)
    var i = 0
    while i + nlen <= n:
        var matched = True
        for k in range(nlen):
            if b[i + k] != nb[k]:
                matched = False
                break
        if matched:
            var j = i + nlen
            while j < n and _is_lang_char(b[j]):
                j += 1
            if j > i + nlen:
                var raw = String(StringSlice(unsafe_from_utf8=b[i + nlen:j]))
                return Optional[_LangMarker](_LangMarker(
                    _to_lower_ascii(raw), j,
                ))
        i += 1
    return Optional[_LangMarker]()


def _is_lang_char(c: UInt8) -> Bool:
    var v = Int(c)
    if 0x30 <= v and v <= 0x39:
        return True
    if 0x41 <= v and v <= 0x5A:
        return True
    if 0x61 <= v and v <= 0x7A:
        return True
    if v == 0x2D or v == 0x5F or v == 0x2B:
        return True
    return False


def _to_lower_ascii(s: String) -> String:
    var b = s.as_bytes()
    var out = String("")
    for k in range(len(b)):
        var v = Int(b[k])
        if 0x41 <= v and v <= 0x5A:
            v = v + 0x20
        out = out + chr(v)
    return out^


def _find_string_body_after(
    lines: List[String], start_row: Int, start_col: Int,
) -> Optional[_StringBody]:
    """Find the body bounds of the next string literal at or after
    ``(start_row, start_col)``.

    A "string" here is anything opened by ``"``, ``'``, or `````,
    optionally tripled. The scan walks bytes forward until it hits an
    opening quote; everything before that is treated as inert — we do
    *not* try to skip nested comments or attribute-equals signs.
    Worst case: a quote inside an unrelated comment looks like the
    string, and the injection points at the wrong range. The
    correctness cost is the wrong attr on a few cells; the alternative
    (host-aware comment tracking) doesn't scale across file types."""
    var row = start_row
    var col = start_col
    if col < 0:
        col = 0
    while row < len(lines):
        var b = lines[row].as_bytes()
        var n = len(b)
        if col > n:
            col = n
        while col < n:
            var ch = b[col]
            if ch == 0x22 or ch == 0x27 or ch == 0x60:
                if col + 3 <= n and b[col + 1] == ch and b[col + 2] == ch:
                    return _scan_triple_string(lines, row, col, ch)
                return _scan_single_string(lines, row, col, ch)
            col += 1
        row += 1
        col = 0
    return Optional[_StringBody]()


def _scan_triple_string(
    lines: List[String], open_row: Int, open_col: Int, ch: UInt8,
) -> Optional[_StringBody]:
    var body_start_row = open_row
    var body_start_col = open_col + 3
    var row = body_start_row
    var col = body_start_col
    while row < len(lines):
        var b = lines[row].as_bytes()
        var n = len(b)
        # On the opening row only, ``col`` may be at or past EOL when
        # ``"""`` sits at column 0/1/2 of the next line. The inner
        # loop's bound handles that.
        var c = col
        while c + 3 <= n:
            if b[c] == ch and b[c + 1] == ch and b[c + 2] == ch:
                return Optional[_StringBody](_StringBody(
                    body_start_row, body_start_col, row, c,
                ))
            c += 1
        row += 1
        col = 0
    # Unterminated triple: body extends to end of buffer.
    var last_row = len(lines) - 1
    var last_col = 0
    if last_row >= 0:
        last_col = len(lines[last_row].as_bytes())
    if last_row < body_start_row:
        last_row = body_start_row
        last_col = body_start_col
    return Optional[_StringBody](_StringBody(
        body_start_row, body_start_col, last_row, last_col,
    ))


def _scan_single_string(
    lines: List[String], open_row: Int, open_col: Int, ch: UInt8,
) -> Optional[_StringBody]:
    """Single-character string: stays on one line. Backslash escapes
    consume the next byte. Unterminated strings end at end-of-line —
    same fallback the generic tokenizer uses."""
    var body_start_row = open_row
    var body_start_col = open_col + 1
    var b = lines[body_start_row].as_bytes()
    var n = len(b)
    var col = body_start_col
    while col < n:
        if b[col] == 0x5C and col + 1 < n:
            col += 2
            continue
        if b[col] == ch:
            return Optional[_StringBody](_StringBody(
                body_start_row, body_start_col, body_start_row, col,
            ))
        col += 1
    return Optional[_StringBody](_StringBody(
        body_start_row, body_start_col, body_start_row, n,
    ))


def _ext_for_language(lang: String) -> String:
    """Map an IntelliJ language name to the file extension our
    grammar registry keys on. Empty string means "we don't have a
    grammar bundled for this language" — the marker becomes a
    no-op."""
    if lang == String("html") or lang == String("htm"):
        return String("html")
    if lang == String("css"):
        return String("css")
    if lang == String("javascript") or lang == String("js"):
        return String("js")
    if lang == String("typescript") or lang == String("ts"):
        return String("ts")
    if lang == String("json"):
        return String("json")
    if lang == String("python") or lang == String("py"):
        return String("py")
    if lang == String("rust") or lang == String("rs"):
        return String("rs")
    if lang == String("go") or lang == String("golang"):
        return String("go")
    if lang == String("c"):
        return String("c")
    if lang == String("cpp") or lang == String("c++") \
            or lang == String("cxx"):
        return String("cpp")
    if lang == String("ruby") or lang == String("rb"):
        return String("rb")
    if lang == String("shell") or lang == String("bash") \
            or lang == String("sh"):
        return String("sh")
    if lang == String("sql"):
        return String("sql")
    if lang == String("yaml") or lang == String("yml"):
        return String("yaml")
    if lang == String("mojo"):
        return String("mojo")
    if lang == String("diff") or lang == String("patch"):
        return String("diff")
    # Fall through to the downloadable-grammar registry: if the user
    # has installed (or could install) a grammar whose ``language_id``
    # matches, use that spec's first file_type as the extension. Lets
    # ``# language=elm`` resolve to ``"elm"`` once the registered Elm
    # grammar is installed under ``~/.config/turbokod/languages/``.
    var specs = built_in_downloadable_grammars()
    var idx = find_downloadable_grammar_by_language(specs, lang)
    if idx >= 0 and len(specs[idx].file_types) > 0:
        return specs[idx].file_types[0]
    return String("")


def embedded_language_extensions(lines: List[String]) -> List[String]:
    """Return the unique extensions of every IntelliJ-style
    ``language=NAME`` marker found in ``lines``. Languages that don't
    map to a known grammar (neither bundled nor downloadable) are
    skipped.

    Used by ``Desktop`` after a file open to surface the grammar-
    install prompt for embedded languages — same mechanism that
    fires when opening a file whose primary extension isn't
    bundled. The returned extensions are exactly the keys
    ``_maybe_prompt_grammar_install`` accepts.
    """
    var out = List[String]()
    for r in range(len(lines)):
        var marker_opt = _find_language_marker(lines[r])
        if not marker_opt:
            continue
        var ext = _ext_for_language(marker_opt.value().lang)
        if len(ext.as_bytes()) == 0:
            continue
        var already = False
        for k in range(len(out)):
            if out[k] == ext:
                already = True
                break
        if not already:
            out.append(ext)
    return out^


def _inject_grammar(
    lang: String, lines: List[String], body: _StringBody,
    mut hls: List[Highlight], mut registry: GrammarRegistry,
):
    """Tokenize ``body`` with the grammar for ``lang`` and overlay the
    resulting highlights onto ``hls``. Drops any existing highlights
    whose range falls entirely inside the body so the injected
    grammar's colors aren't muddied by the host's string-attr paint
    underneath."""
    var ext = _ext_for_language(lang)
    if len(ext.as_bytes()) == 0:
        return
    var resolved = _resolve_grammar_path(ext, registry)
    var path = resolved.path
    var cache_key = resolved.cache_key
    if len(path.as_bytes()) == 0:
        return
    var grammar_idx = registry.lookup_idx(cache_key)
    if grammar_idx < 0:
        try:
            var g = load_grammar_from_file(path)
            registry.keys.append(cache_key)
            registry.grammars.append(g^)
            grammar_idx = len(registry.keys) - 1
        except:
            return

    var sub_lines = _slice_body_lines(lines, body)
    var sub_post = List[List[Frame]]()
    var sub_hls = tokenize_with_grammar_full(
        registry.grammars[grammar_idx], sub_lines, sub_post,
    )

    _drop_highlights_in_body(hls, body)

    # Map sub-buffer coordinates back to the host buffer. Row 0 of
    # the sub-buffer aligns with ``body.start_row`` and its columns
    # are offset by ``body.start_col``; rows >= 1 share columns with
    # the host (we kept those lines verbatim) but their host row is
    # ``body.start_row + sh.row``.
    var first_row_offset = body.start_col
    for k in range(len(sub_hls)):
        var sh = sub_hls[k]
        var orig_row = body.start_row + sh.row
        var col_off = 0
        if sh.row == 0:
            col_off = first_row_offset
        hls.append(Highlight(
            orig_row, sh.col_start + col_off, sh.col_end + col_off,
            sh.attr,
        ))


def _slice_body_lines(
    lines: List[String], body: _StringBody,
) -> List[String]:
    """Build the sub-buffer the injected grammar tokenizes against:
    the body bytes only, with the open/close quotes excluded. Single-
    line bodies become a single string; multi-line bodies put the
    head fragment first, full middle rows verbatim, then the tail
    fragment."""
    var out = List[String]()
    if body.start_row == body.end_row:
        var b = lines[body.start_row].as_bytes()
        var s = body.start_col
        var e = body.end_col
        if s < 0:
            s = 0
        if e > len(b):
            e = len(b)
        if e < s:
            e = s
        out.append(String(StringSlice(unsafe_from_utf8=b[s:e])))
        return out^
    var b0 = lines[body.start_row].as_bytes()
    var s0 = body.start_col
    if s0 < 0:
        s0 = 0
    if s0 > len(b0):
        s0 = len(b0)
    out.append(String(StringSlice(unsafe_from_utf8=b0[s0:len(b0)])))
    for r in range(body.start_row + 1, body.end_row):
        out.append(lines[r])
    var bN = lines[body.end_row].as_bytes()
    var eN = body.end_col
    if eN < 0:
        eN = 0
    if eN > len(bN):
        eN = len(bN)
    out.append(String(StringSlice(unsafe_from_utf8=bN[0:eN])))
    return out^


def _drop_highlights_in_body(
    mut hls: List[Highlight], body: _StringBody,
):
    """Filter out highlights whose range lies inside the body. We
    keep the open/close quote highlights (they sit *outside* the
    body bounds by construction) so the visual cue that ``" ... "``
    is a string is preserved on the surrounding bytes; the body
    itself is wiped so the injected grammar's highlights don't
    composite over a uniform string-red underneath."""
    var kept = List[Highlight]()
    for i in range(len(hls)):
        var hl = hls[i]
        if hl.row < body.start_row or hl.row > body.end_row:
            kept.append(hl)
            continue
        if body.start_row == body.end_row:
            # Single-row body: drop highlights that overlap
            # ``[start_col, end_col)``.
            if hl.col_end <= body.start_col \
                    or hl.col_start >= body.end_col:
                kept.append(hl)
            continue
        if hl.row == body.start_row:
            if hl.col_end <= body.start_col:
                kept.append(hl)
            continue
        if hl.row == body.end_row:
            if hl.col_start >= body.end_col:
                kept.append(hl)
            continue
        # Row strictly between the body's first and last — entire
        # row is inside the body, drop unconditionally.
    hls.clear()
    for i in range(len(kept)):
        hls.append(kept[i])
