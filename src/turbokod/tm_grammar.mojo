"""TextMate grammar loader.

Parses ``.tmLanguage.json`` into a flat pattern table the tokenizer
can walk. The data model deliberately avoids recursive struct types
(Mojo's struct system makes ``var nested: List[Pattern]`` painful),
storing patterns in a single ``List[Pattern]`` and threading nested
patterns / repository references via integer indices.

Subset implemented (enough for ``rust.tmLanguage.json``-shape grammars):

* ``match`` + ``name`` — single-line regex matches a scope.
* ``begin`` + ``end`` (+ optional ``name`` / ``contentName`` /
  ``patterns``) — span scope delimited by two regexes; nested
  patterns apply to the body.
* ``include`` — ``"#repository_key"`` or ``"$self"``.
* Top-level ``patterns`` plus ``repository`` of named patterns.

Skipped for now (the most-likely "missing" features when an external
grammar misbehaves):

* ``captures`` / ``beginCaptures`` / ``endCaptures`` — group→scope
  mapping is the next thing to wire in once we want richer color.
* ``while`` / ``whileBegin`` — niche, used by Markdown blockquotes.
* External grammar references (``include: source.js``) — would need
  a registry of multiple loaded grammars.
* Injections (``injectionSelector`` / ``injections``).
"""

from std.collections.list import List

from .file_io import read_file
from .json import JsonValue, json_get_string, parse_json
from .onig import OnigRegex
from .string_utils import parse_int_all


# Pattern kind discriminant. ``MATCH`` / ``BEGIN_END`` / ``INCLUDE`` /
# ``GROUP`` — encoded as small ints so a Pattern stays a fixed-size
# value type. ``GROUP`` is a container that just owns a list of nested
# pattern indices (in ``nested``); the tokenizer expands it the same
# way it expands ``INCLUDE``. Real grammars (e.g., vscode-rust) wrap
# every repository entry in this shape: ``"keywords": { "patterns":
# [...] }`` — without GROUP support those entries silently drop their
# contents and you end up with no keyword highlights.
comptime PATTERN_MATCH    = UInt8(1)
comptime PATTERN_BEGIN_END = UInt8(2)
comptime PATTERN_INCLUDE  = UInt8(3)
comptime PATTERN_GROUP    = UInt8(4)
# ``BEGIN_WHILE``: ``begin`` regex opens the scope; on every
# subsequent line, the ``while`` regex must match at the start of
# the line for the scope to remain open. If it doesn't, the scope
# closes silently before the line's body is tokenized. Markdown
# (blockquotes, fenced-code-block bodies) and YAML use this idiom
# heavily; without it those grammars produce ~no highlights.
# ``end_idx`` slot stores the ``while`` regex — never has both.
comptime PATTERN_BEGIN_WHILE = UInt8(5)


struct Capture(Copyable, Movable):
    """One ``"<group>": { "name": "<scope>" }`` entry from a
    ``captures`` / ``beginCaptures`` / ``endCaptures`` block.

    ``group`` is the 1-based capture index (0 covers the whole
    match); ``scope`` is the TextMate scope to apply to that
    sub-range. ``nested`` (filled when the JSON entry carries a
    ``patterns`` array of its own) holds pattern indices to run
    against the *captured substring* — a mini-tokenize inside the
    capture's byte range. Empty list means "scope only, no
    re-tokenization."
    """
    var group: Int
    var scope: String
    var nested: List[Int]

    def __init__(
        out self, group: Int, var scope: String,
        var nested: List[Int] = List[Int](),
    ):
        self.group = group
        self.scope = scope^
        self.nested = nested^


def _has_cross_backref(src: String) -> Bool:
    """True if ``src`` contains a ``\\1``..``\\9`` numeric backreference.

    Only a cheap byte scan: a backslash followed by a digit 1-9, with
    ``\\\\`` (an escaped backslash) skipped so we don't misread the
    digit after a literal backslash. We don't try to tell apart a
    backref that targets a *begin* group from one that targets a group
    inside the end regex itself — a false positive just means we
    recompile a regex that libonig would have handled correctly, which
    is harmless. ``\\0`` is excluded (it means the whole begin match,
    which TextMate rarely uses in end patterns and our substituter
    leaves alone)."""
    var b = src.as_bytes()
    var i = 0
    while i < len(b):
        if Int(b[i]) == 0x5C:  # backslash
            if i + 1 < len(b):
                var c = Int(b[i + 1])
                if c >= 0x31 and c <= 0x39:  # '1'..'9'
                    return True
            i += 2  # skip the escaped char (handles "\\")
            continue
        i += 1
    return False


def _mentions_g_anchor(src: String) -> Bool:
    """Whether ``src`` contains a backslash followed by ``G``. An escaped
    backslash before a literal G reads as one too, which only costs the
    tokenizer a search it could have skipped."""
    var b = src.as_bytes()
    for i in range(len(b) - 1):
        if b[i] == 0x5C and b[i + 1] == 0x47:
            return True
    return False


struct Pattern(Copyable, Movable):
    """Flat representation of one TextMate pattern.

    Fields are populated based on ``kind``:

    * ``MATCH``: ``match_idx`` indexes ``Grammar.regexes``;
      ``name`` is the outer scope; ``captures`` (if any) refines
      colors per capture group.
    * ``BEGIN_END``: ``match_idx`` is the begin regex, ``end_idx``
      is the end regex; ``name`` is the surrounding scope;
      ``content_name`` is the inner scope (optional, "" when
      absent); ``nested`` lists the pattern indices that apply
      between begin and end. ``captures`` (if any) refines the
      *begin*'s color (TextMate's ``beginCaptures``); ``end_captures``
      refines the *end*'s.
    * ``INCLUDE``: ``include_target`` holds either ``"$self"`` or a
      repository key without the leading ``#`` (we strip it at load).
    * ``GROUP``: pure container; ``nested`` carries child indices.
    """
    var kind: UInt8
    var name: String              # scope name, "" if absent
    var content_name: String      # only for BEGIN_END
    var match_idx: Int            # Grammar.regexes index, -1 if N/A
    var end_idx: Int              # BEGIN_END only, -1 if N/A
    var nested: List[Int]         # BEGIN_END nested-pattern indices
    var include_target: String    # INCLUDE only
    var captures: List[Capture]   # MATCH or BEGIN_END's beginCaptures
    var end_captures: List[Capture]  # BEGIN_END's endCaptures
    # Raw source of the end (BEGIN_END) / while (BEGIN_WHILE) regex,
    # kept verbatim so the tokenizer can substitute begin-match
    # captures into it at runtime. TextMate lets an ``end`` pattern
    # reference the *begin* match's groups via ``\1``..``\9`` (e.g.
    # the django HTML grammar's ``end: "(>)(<)(/)(\\2)(>)"`` closes a
    # ``<tag>...</tag>`` by back-referencing the tag name captured in
    # the begin). libonig can't resolve those cross-regex backrefs on
    # its own — ``\2`` would bind to the end regex's *own* group 2 —
    # so when ``end_has_backref`` is set we rebuild and recompile the
    # end regex per open frame with the captures spliced in.
    var end_source: String
    var end_has_backref: Bool

    def __init__(
        out self,
        kind: UInt8,
        var name: String,
        var content_name: String,
        match_idx: Int,
        end_idx: Int,
        var nested: List[Int],
        var include_target: String,
        var captures: List[Capture] = List[Capture](),
        var end_captures: List[Capture] = List[Capture](),
        var end_source: String = String(""),
        end_has_backref: Bool = False,
    ):
        self.kind = kind
        self.name = name^
        self.content_name = content_name^
        self.match_idx = match_idx
        self.end_idx = end_idx
        self.nested = nested^
        self.include_target = include_target^
        self.captures = captures^
        self.end_captures = end_captures^
        self.end_source = end_source^
        self.end_has_backref = end_has_backref


struct Grammar(Copyable, Movable):
    """A loaded grammar: scope name + flat pattern/regex tables +
    repository lookup.

    External grammars (referenced via ``include: "source.X"`` from
    inside another grammar's patterns) are flattened into the same
    pattern/regex tables at load time. Their repo entries get
    prefixed with the embedded scope name and a ``#`` so they don't
    collide with the host's repo. Their root patterns are
    registered in ``external_scopes`` / ``external_roots`` so the
    tokenizer can route ``include: "source.X"`` to them.

    Resolves ``include`` references at tokenize time rather than
    load time so circular refs (which the Rust grammar's nested
    block comments use) don't trip an infinite loop here.

    Regexes are compiled the first time the tokenizer asks for one
    (``regex``), not at load: a grammar's compiled patterns are megabytes
    of libonig handles, and a file only reaches the ones in the scopes it
    actually opens — never, say, the CSS and JavaScript grammars an HTML
    file without a ``<style>`` or ``<script>`` embeds.
    """
    var scope_name: String
    var root_patterns: List[Int]
    var patterns: List[Pattern]
    var regexes: List[OnigRegex]
    """One slot per regex, matching nothing until ``regex`` compiles it."""
    var regex_sources: List[String]
    var regex_partner: List[Int]
    """The other regex of a ``begin``/``end`` (or ``while``) pair, -1 for
    a ``match``. A pair is compiled together, and is dead together when
    libonig rejects either half: a ``begin`` that could match with an
    ``end`` that never can would leave its scope open to the end of the
    file."""
    var _regex_done: List[UInt8]
    """1 once ``regex`` has settled a slot — compiled, or found dead."""
    var regex_has_g: List[Bool]
    """Whether a regex's source mentions ``\\G``. Only such a regex can
    match differently under ``ONIG_OPTION_NOT_BEGIN_POSITION`` (the option
    makes ``\\G`` fail and touches nothing else), which is what lets the
    tokenizer keep every other regex's cached result when it flips."""
    # Parallel arrays for the repository: ``repo_keys[i]`` resolves
    # to ``repo_pattern_idxs[i]``. Linear lookup; the table is small
    # (typically 50–200 entries even for a fat grammar) so a hash
    # map would be over-engineering.
    var repo_keys: List[String]
    var repo_pattern_idxs: List[Int]
    # External-scope routing: ``external_scopes[i]`` is the scope
    # name (e.g. ``"source.css"``) of an embedded grammar whose
    # root patterns are listed in ``external_roots[i]``.
    var external_scopes: List[String]
    var external_roots: List[List[Int]]

    def __init__(
        out self,
        var scope_name: String,
        var root_patterns: List[Int],
        var patterns: List[Pattern],
        var regex_sources: List[String],
        var regex_partner: List[Int],
        var repo_keys: List[String],
        var repo_pattern_idxs: List[Int],
        var external_scopes: List[String] = List[String](),
        var external_roots: List[List[Int]] = List[List[Int]](),
    ):
        self.scope_name = scope_name^
        self.root_patterns = root_patterns^
        self.patterns = patterns^
        self.regexes = List[OnigRegex](capacity=len(regex_sources))
        self._regex_done = List[UInt8](length=len(regex_sources), fill=0)
        self.regex_has_g = List[Bool](capacity=len(regex_sources))
        for i in range(len(regex_sources)):
            self.regexes.append(OnigRegex(never=True))
            self.regex_has_g.append(_mentions_g_anchor(regex_sources[i]))
        self.regex_sources = regex_sources^
        self.regex_partner = regex_partner^
        self.repo_keys = repo_keys^
        self.repo_pattern_idxs = repo_pattern_idxs^
        self.external_scopes = external_scopes^
        self.external_roots = external_roots^

    def __copyinit__(mut self, copy: Self):
        # Copy semantics: list-of-list fields deep-copy their
        # spines (we want each ``Grammar`` instance to own its own
        # vectors), but ``OnigRegex`` is itself bitwise-aliasing
        # so the regex_t handles are *shared* across copies. The Rust
        # shim's registry is the sole owner of those handles, so the
        # aliasing is benign — copies don't multiply the libonig
        # allocations. It does mean ``release`` is a whole-grammar
        # operation, not something a copy may do on its own. (A regex
        # neither side had compiled yet is compiled by each on its own.)
        self.scope_name = copy.scope_name
        self.root_patterns = copy.root_patterns.copy()
        self.patterns = copy.patterns.copy()
        self.regexes = copy.regexes.copy()
        self.regex_sources = copy.regex_sources.copy()
        self.regex_partner = copy.regex_partner.copy()
        self._regex_done = copy._regex_done.copy()
        self.regex_has_g = copy.regex_has_g.copy()
        self.repo_keys = copy.repo_keys.copy()
        self.repo_pattern_idxs = copy.repo_pattern_idxs.copy()
        var ext_roots_copy = List[List[Int]]()
        for i in range(len(copy.external_roots)):
            ext_roots_copy.append(copy.external_roots[i].copy())
        self.external_scopes = copy.external_scopes.copy()
        self.external_roots = ext_roots_copy^

    def release(mut self):
        """Give this grammar's compiled regexes back to the allocator.

        ``regexes`` is the grammar's one flat table — patterns hold
        indices into it — so this is the whole set. A fat grammar is
        125 KB to 12 MB of libonig handles, and nothing else reclaims
        them: they're owned by the shim's registry, not by Mojo, so the
        destructor can't help.

        Call this only when the grammar is being discarded *and* nothing
        can still tokenize through it — copies alias the same handles.
        ``GrammarRegistry.release`` is the sanctioned caller.
        """
        for i in range(len(self.regexes)):
            self.regexes[i].release()
            # Settled, as matching nothing: a use after this must not
            # compile the regex afresh and strand it.
            self._regex_done[i] = 1

    def regex(self, idx: Int) -> OnigRegex:
        """Regex ``idx``, compiled now if this is its first use (with its
        ``regex_partner``). One libonig rejects — look-behind quantifier
        weirdness, named-group syntax it doesn't recognize — matches
        nothing, so the pattern is dead rather than the whole grammar.

        Fills the slot in place through a raw pointer: the tokenizer
        holds the grammar immutably (and the store that owns it is shared
        by every window), and what's written is a cache of what
        ``regex_sources`` already says."""
        var done = Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=Int(self._regex_done.unsafe_ptr()),
        )
        var slots = Pointer[OnigRegex, MutUntrackedOrigin](
            unsafe_from_address=Int(self.regexes.unsafe_ptr()),
        )
        if done[unsafe_offset=idx] == 0:
            var other = self.regex_partner[idx]
            var a = OnigRegex(never=True)
            var b = OnigRegex(never=True)
            try:
                a = OnigRegex(self.regex_sources[idx])
                if other >= 0:
                    b = OnigRegex(self.regex_sources[other])
            except:
                a.release()
                b.release()
            slots[unsafe_offset=idx] = a
            done[unsafe_offset=idx] = 1
            if other >= 0:
                slots[unsafe_offset=other] = b
                done[unsafe_offset=other] = 1
        return slots[unsafe_offset=idx]

    def lookup_repo(self, key: String) -> Int:
        """Repository key → pattern index. Returns -1 if unknown."""
        for i in range(len(self.repo_keys)):
            if self.repo_keys[i] == key:
                return self.repo_pattern_idxs[i]
        return -1

    def lookup_external(self, scope: String) -> Int:
        """External-scope index → ``external_roots`` slot, or -1.

        The tokenizer uses this to follow ``include: "source.X"``
        references into an embedded grammar's root patterns.
        """
        for i in range(len(self.external_scopes)):
            if self.external_scopes[i] == scope:
                return i
        return -1


def _path_for_scope(scope: String) -> String:
    """Map a TextMate scope name to a bundled grammar JSON path.

    Used to resolve external ``include: "source.X"`` references at
    load time. Empty string means "we don't have that grammar
    bundled" — the include then becomes a no-op (highlights for the
    embedded language are skipped, the surrounding grammar still
    works). Add a row here to teach the loader about a new
    embedded grammar.
    """
    if scope == String("source.js"):
        return String("src/turbokod/grammars/javascript.tmLanguage.json")
    if scope == String("source.ts"):
        return String("src/turbokod/grammars/typescript.tmLanguage.json")
    if scope == String("source.css") or scope == String("source.css.django"):
        # ``source.css.django`` is the scope the vscode-django grammar
        # embeds ``<style>`` contents under, but it never ships a grammar
        # for it (a dangling include). Route it to the bundled CSS
        # grammar so style blocks in Django templates get full CSS
        # highlighting. The Django template tags (``{{ }}`` / ``{% %}`` /
        # ``{# #}``) that appear *inside* that CSS are painted by the
        # post-tokenize ``_apply_django_template_overlay`` pass — the
        # tokenizer can't reach them from grammar root patterns once
        # CSS's own ``{ }`` rule context is open, and we don't implement
        # TextMate injection grammars.
        return String("src/turbokod/grammars/css.tmLanguage.json")
    if scope == String("text.html.basic"):
        return String("src/turbokod/grammars/html.tmLanguage.json")
    if scope == String("source.json"):
        return String("src/turbokod/grammars/json.tmLanguage.json")
    if scope == String("source.python"):
        return String("src/turbokod/grammars/python.tmLanguage.json")
    return String("")


def load_grammar_from_file(path: String) raises -> Grammar:
    """Read and parse a ``.tmLanguage.json`` from disk.

    Recursively follows external ``include: "source.X"`` references
    into other bundled grammars (mapped via ``_path_for_scope``);
    the result is a single ``Grammar`` whose ``external_scopes``
    list lets the tokenizer route into the embedded grammars'
    root patterns at runtime.
    """
    return _load_grammar_full(read_file(path))


def load_grammar_from_string(text: String) raises -> Grammar:
    """Parse a grammar JSON already loaded into a string. Useful for
    tests where embedding the grammar inline beats touching the
    filesystem. Does *not* follow external ``include`` references —
    those need a path resolver, which we don't have for raw-string
    callers. Use ``load_grammar_from_file`` if your grammar embeds
    others."""
    return _load_grammar_full(text)


struct _GrammarBuild(Movable):
    """The tables a grammar load fills in, threaded through every compile:
    the flat pattern and regex lists, the repository, the embedded
    grammars' roots, and the chain of scopes being loaded (so a circular
    external include can't recurse forever)."""
    var patterns: List[Pattern]
    var regex_sources: List[String]
    var regex_partner: List[Int]
    var repo_keys: List[String]
    var repo_idxs: List[Int]
    var external_scopes: List[String]
    var external_roots: List[List[Int]]
    var loaded_scopes: List[String]

    def __init__(out self):
        self.patterns = List[Pattern]()
        self.regex_sources = List[String]()
        self.regex_partner = List[Int]()
        self.repo_keys = List[String]()
        self.repo_idxs = List[Int]()
        self.external_scopes = List[String]()
        self.external_roots = List[List[Int]]()
        self.loaded_scopes = List[String]()

    def grammar(
        deinit self, var scope_name: String, var root_patterns: List[Int],
    ) -> Grammar:
        """The finished grammar, its tables moved out of the build."""
        return Grammar(
            scope_name^, root_patterns^, self.patterns^,
            self.regex_sources^, self.regex_partner^,
            self.repo_keys^, self.repo_idxs^, self.external_scopes^,
            self.external_roots^,
        )


def _load_grammar_full(text: String) raises -> Grammar:
    var doc = parse_json(text)
    if not doc.is_object():
        raise Error("grammar root is not an object")
    var scope_name = json_get_string(doc, String("scopeName"))
    var b = _GrammarBuild()
    if len(scope_name.as_bytes()) > 0:
        b.loaded_scopes.append(scope_name)
    var root_patterns = _compile_grammar(doc, b, String(""))
    return b^.grammar(scope_name^, root_patterns^)


def _compile_grammar(
    doc: JsonValue, mut b: _GrammarBuild, scope_prefix: String,
) raises -> List[Int]:
    """Compile a grammar document's ``repository`` and then its top-level
    ``patterns`` into ``b``, returning the root pattern indices. The
    repository goes first so the roots can reference it by indices that
    already exist. An embedded grammar's (``scope_prefix`` its scope
    name) repo keys register as ``"<scope>#<name>"``, which is what
    ``_compile_pattern``'s rewrite of its ``#name`` references looks up:
    without the prefix they would lose to identically-named host keys (or
    host lookups would resolve into them)."""
    var ri = doc.object_index(String("repository"))
    if ri >= 0 and doc.obj_v[ri].value.is_object():
        for ref member in doc.obj_v[ri].value.obj_v:
            var idx = _compile_pattern(member.value, b, scope_prefix)
            if len(scope_prefix.as_bytes()) > 0:
                b.repo_keys.append(scope_prefix + String("#") + member.key)
            else:
                b.repo_keys.append(member.key)
            b.repo_idxs.append(idx)
    return _compile_patterns(doc, b, scope_prefix)


def _compile_patterns(
    node: JsonValue, mut b: _GrammarBuild, scope_prefix: String,
) raises -> List[Int]:
    """Compile each entry of ``node``'s ``patterns`` array, returning
    their indices (none when it has no such array)."""
    var out = List[Int]()
    var pi = node.object_index(String("patterns"))
    if pi < 0 or not node.obj_v[pi].value.is_array():
        return out^
    for ref child in node.obj_v[pi].value.arr_v:
        out.append(_compile_pattern(child, b, scope_prefix))
    return out^


def _maybe_load_external(target: String, mut b: _GrammarBuild) raises:
    """If ``target`` is an external grammar scope (contains a
    ``.`` and isn't ``$self`` or ``__none__``) and we know how to
    load it (``_path_for_scope`` returns a path), recursively load
    the embedded grammar and append its patterns/regexes to ours,
    registering its root indices under ``target`` in
    ``external_scopes`` / ``external_roots``.

    Cycle protection: if the target scope is already being loaded
    (anywhere in ``loaded_scopes``) or already loaded as an
    external, this is a no-op — the existing or in-progress entry
    will resolve the include at tokenize time.
    """
    # Skip ``$self``, ``__none__``, and repo-local refs (no ``.``
    # in the target). External-scope targets always contain a dot.
    if target == String("$self") or target == String("__none__"):
        return
    if target.find(String(".")) < 0:
        return
    # Already loading this scope (cycle), or already loaded as an
    # external — the existing entry resolves the include.
    if target in b.loaded_scopes or target in b.external_scopes:
        return
    var sub_path = _path_for_scope(target)
    if len(sub_path.as_bytes()) == 0:
        return
    var sub_text: String
    try:
        sub_text = read_file(sub_path)
    except:
        return
    var sub_doc = parse_json(sub_text)
    if not sub_doc.is_object():
        return
    # Allocate a placeholder slot in external_scopes/roots before
    # recursing, so a cycle from the embedded grammar back to us
    # would find the placeholder rather than re-loading.
    b.external_scopes.append(target)
    b.external_roots.append(List[Int]())
    var slot_idx = len(b.external_scopes) - 1
    b.loaded_scopes.append(target)
    # Its patterns land in the same flat tables, so every pattern index
    # lives in one namespace. Into a local first: compiling can grow
    # ``external_roots`` (a nested embed), moving the slot.
    var roots = _compile_grammar(sub_doc, b, target)
    b.external_roots[slot_idx] = roots^
    # Pop the loaded-scope marker so siblings can re-encounter
    # this scope later in the parse without being treated as
    # cycles.
    if len(b.loaded_scopes) > 0 \
            and b.loaded_scopes[len(b.loaded_scopes) - 1] == target:
        _ = b.loaded_scopes.pop()


def _compile_pattern(
    node: JsonValue, mut b: _GrammarBuild, scope_prefix: String = String(""),
) raises -> Int:
    """Append a pattern (and any nested ones) to ``b.patterns``,
    compiling regexes into ``b.regexes`` along the way. Returns the
    index of the newly added pattern.

    Nested ``patterns`` arrays are flattened: each child pattern
    becomes its own entry in the flat list, and the parent's
    ``nested`` field carries their indices. This means a nested
    pattern table is just a pre-existing slice of the flat
    ``patterns`` list — exactly what the tokenizer expects.

    ``scope_prefix`` (non-empty when compiling patterns from an
    embedded grammar — e.g. ``"source.css"``) rewrites two kinds
    of intra-grammar references so the embedded grammar's repo
    entries, registered in the merged repo under
    ``"<prefix>#<name>"``, can be found at lookup time:

    * ``include: "#name"`` → ``include: "<prefix>#name"``
    * ``include: "$self"`` → ``include: "<prefix>"`` — which the
      tokenizer routes through ``external_scopes`` to the embedded
      grammar's roots.

    External-scope ``include``s and ``include: "__none__"`` pass
    through untouched.
    """
    if not node.is_object():
        # Defensive: a malformed grammar shouldn't crash the editor.
        return _append_dead_pattern(b.patterns)

    # ``include``: store and return; no regexes to compile.
    # Also: if the include's target is an external grammar scope
    # name (contains a ``.``), trigger a recursive load so the
    # tokenizer can route into the embedded grammar's roots.
    var ii = node.object_index(String("include"))
    if ii >= 0 and node.obj_v[ii].value.is_string():
        var raw = node.obj_v[ii].value.as_str()
        var target = raw
        var rb = raw.as_bytes()
        var is_repo_ref = (len(rb) > 0 and rb[0] == 0x23)
        if is_repo_ref:
            target = String(StringSpan(unsafe_from_utf8=rb[1:len(rb)]))
        # Apply the embedded-grammar scope-prefix rewrite so
        # references inside an embedded grammar resolve to that
        # grammar's namespaced repo / roots in the merged tables.
        if len(scope_prefix.as_bytes()) > 0:
            if target == String("$self"):
                target = scope_prefix
            elif is_repo_ref:
                target = scope_prefix + String("#") + target
        b.patterns.append(Pattern(
            PATTERN_INCLUDE, String(""), String(""), -1, -1,
            List[Int](), target,
        ))
        var idx = len(b.patterns) - 1
        _maybe_load_external(target, b)
        return idx

    var name_str = json_get_string(node, String("name"))
    var content_name = json_get_string(node, String("contentName"))

    var mi = node.object_index(String("match"))
    if mi >= 0:
        var pat_str = node.obj_v[mi].value.as_str()
        # Not compiled here: ``Grammar.regex`` does that on first use,
        # and a regex libonig rejects then just never matches — "this
        # pattern is dead" rather than a failed load, with the
        # surrounding patterns still lighting up.
        b.regex_sources.append(pat_str)
        b.regex_partner.append(-1)
        var match_idx = len(b.regex_sources) - 1
        var caps = _parse_captures(
            node, String("captures"), b, scope_prefix,
        )
        b.patterns.append(Pattern(
            PATTERN_MATCH, name_str^, content_name^, match_idx, -1,
            List[Int](), String(""),
            caps^, List[Capture](),
        ))
        return len(b.patterns) - 1

    var bi = node.object_index(String("begin"))
    if bi >= 0:
        var begin_str = node.obj_v[bi].value.as_str()
        # A ``begin`` pattern is paired with either ``end`` or
        # ``while``; ``while``-rules anchor a scope that stays open
        # only as long as each new line starts with the regex.
        var ei = node.object_index(String("end"))
        var wi = node.object_index(String("while"))
        if ei < 0 and wi < 0:
            # ``begin`` without either is malformed — skip.
            return _append_dead_pattern(b.patterns)
        var second_str: String
        var pattern_kind: UInt8
        if ei >= 0:
            second_str = node.obj_v[ei].value.as_str()
            pattern_kind = PATTERN_BEGIN_END
        else:
            second_str = node.obj_v[wi].value.as_str()
            pattern_kind = PATTERN_BEGIN_WHILE
        # A pair: compiled together on first use, and dead together if
        # libonig rejects either side (``Grammar.regex_partner``).
        var begin_idx = len(b.regex_sources)
        var end_idx = begin_idx + 1
        b.regex_sources.append(begin_str)
        b.regex_partner.append(end_idx)
        b.regex_sources.append(second_str)
        b.regex_partner.append(begin_idx)

        # Nested patterns must be compiled before the parent is
        # appended so we know each child's index.
        var nested = _compile_patterns(node, b, scope_prefix)

        # ``captures`` (singular) on a begin/end pattern is shorthand
        # for "applies to both begin and end" in TextMate's spec.
        # ``beginCaptures`` / ``endCaptures`` override that per-side.
        # For ``while``-rules, ``whileCaptures`` is the per-side key
        # (we map it onto the same ``end_captures`` slot since each
        # pattern only has one tail-side anyway).
        var both_caps = _parse_captures(
            node, String("captures"), b, scope_prefix,
        )
        var begin_caps = _parse_captures(
            node, String("beginCaptures"), b, scope_prefix,
        )
        var end_caps = _parse_captures(
            node, String("endCaptures"), b, scope_prefix,
        )
        var while_caps = _parse_captures(
            node, String("whileCaptures"), b, scope_prefix,
        )
        if len(begin_caps) == 0 and len(both_caps) > 0:
            begin_caps = both_caps.copy()
        if pattern_kind == PATTERN_BEGIN_END:
            if len(end_caps) == 0 and len(both_caps) > 0:
                end_caps = both_caps.copy()
        else:
            if len(while_caps) > 0:
                end_caps = while_caps^
            elif len(both_caps) > 0:
                end_caps = both_caps.copy()

        b.patterns.append(Pattern(
            pattern_kind, name_str^, content_name^,
            begin_idx, end_idx, nested^, String(""),
            begin_caps^, end_caps^,
            second_str, _has_cross_backref(second_str),
        ))
        return len(b.patterns) - 1

    # No ``match`` / ``begin`` / ``include`` — but the entry may
    # carry a nested ``patterns`` array as a pure container ("group").
    # Real-world grammars wrap every repository entry this way:
    # ``"keywords": { "patterns": [...] }``. We compile the children
    # eagerly and store their indices in ``nested``; the tokenizer's
    # ``_expand_into`` walks GROUPs the same way it walks INCLUDEs.
    var grp_children = _compile_patterns(node, b, scope_prefix)
    if len(grp_children) > 0:
        b.patterns.append(Pattern(
            PATTERN_GROUP, String(""), String(""), -1, -1,
            grp_children^, String(""),
        ))
        return len(b.patterns) - 1
    # Truly empty entry — fall back to a no-op include.
    return _append_dead_pattern(b.patterns)


def _append_dead_pattern(mut patterns: List[Pattern]) -> Int:
    """Append a no-op INCLUDE of the non-existent ``__none__`` key — what
    a malformed or uncompilable entry becomes, so the tokenizer skips it
    instead of the whole grammar failing to load — and return its index."""
    patterns.append(Pattern(
        PATTERN_INCLUDE, String(""), String(""), -1, -1,
        List[Int](), String("__none__"),
    ))
    return len(patterns) - 1


def _parse_captures(
    node: JsonValue, key: String, mut b: _GrammarBuild, scope_prefix: String,
) raises -> List[Capture]:
    """Parse a ``captures``-style block:

        "captures": {
            "1": { "name": "scope.foo" },
            "2": {
                "name": "scope.bar",
                "patterns": [ { "match": "...", "name": "..." } ]
            }
        }

    Each key is a stringified group index (``"0"`` covers the whole
    match). The optional ``patterns`` array under a capture re-runs
    the listed patterns on the captured substring — a "mini-tokenize"
    inside the group, compiled flat into the grammar's tables with
    their indices on the ``Capture`` for the tokenizer's
    ``_emit_captures``. Anything that isn't an object with at least a
    ``name`` or ``patterns`` field is skipped silently.
    """
    var out = List[Capture]()
    var ci = node.object_index(key)
    if ci < 0 or not node.obj_v[ci].value.is_object():
        return out^
    for ref member in node.obj_v[ci].value.obj_v:
        if not member.value.is_object():
            continue
        var name_str = json_get_string(member.value, String("name"))
        var nested = _compile_patterns(member.value, b, scope_prefix)
        if len(name_str.as_bytes()) == 0 and len(nested) == 0:
            continue
        var idx = parse_int_all(member.key)
        if idx < 0:
            continue
        out.append(Capture(idx, name_str^, nested^))
    return out^
