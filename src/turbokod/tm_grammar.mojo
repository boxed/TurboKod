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
from std.collections.optional import Optional

from .file_io import read_file
from .json import JsonValue, parse_json
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


struct Capture(ImplicitlyCopyable, Movable):
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

    fn __init__(
        out self, group: Int, var scope: String,
        var nested: List[Int] = List[Int](),
    ):
        self.group = group
        self.scope = scope^
        self.nested = nested^

    fn __copyinit__(out self, copy: Self):
        self.group = copy.group
        self.scope = copy.scope
        self.nested = copy.nested.copy()


struct Pattern(ImplicitlyCopyable, Movable):
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

    fn __init__(
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

    fn __copyinit__(out self, copy: Self):
        self.kind = copy.kind
        self.name = copy.name
        self.content_name = copy.content_name
        self.match_idx = copy.match_idx
        self.end_idx = copy.end_idx
        self.nested = copy.nested.copy()
        self.include_target = copy.include_target
        self.captures = copy.captures.copy()
        self.end_captures = copy.end_captures.copy()


struct Grammar(ImplicitlyCopyable, Movable):
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
    """
    var scope_name: String
    var root_patterns: List[Int]
    var patterns: List[Pattern]
    var regexes: List[OnigRegex]
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

    fn __init__(
        out self,
        var scope_name: String,
        var root_patterns: List[Int],
        var patterns: List[Pattern],
        var regexes: List[OnigRegex],
        var repo_keys: List[String],
        var repo_pattern_idxs: List[Int],
        var external_scopes: List[String] = List[String](),
        var external_roots: List[List[Int]] = List[List[Int]](),
    ):
        self.scope_name = scope_name^
        self.root_patterns = root_patterns^
        self.patterns = patterns^
        self.regexes = regexes^
        self.repo_keys = repo_keys^
        self.repo_pattern_idxs = repo_pattern_idxs^
        self.external_scopes = external_scopes^
        self.external_roots = external_roots^

    fn __copyinit__(out self, copy: Self):
        # Copy semantics: list-of-list fields deep-copy their
        # spines (we want each ``Grammar`` instance to own its own
        # vectors), but ``OnigRegex`` is itself bitwise-aliasing
        # so the regex_t handles are *shared* across copies. Since
        # ``onig_shim.c`` is the sole owner of those handles
        # (process-wide registry, freed at exit) the aliasing is
        # benign — copies don't multiply the libonig allocations.
        self.scope_name = copy.scope_name
        self.root_patterns = copy.root_patterns.copy()
        self.patterns = copy.patterns.copy()
        self.regexes = copy.regexes.copy()
        self.repo_keys = copy.repo_keys.copy()
        self.repo_pattern_idxs = copy.repo_pattern_idxs.copy()
        var ext_roots_copy = List[List[Int]]()
        for i in range(len(copy.external_roots)):
            ext_roots_copy.append(copy.external_roots[i].copy())
        self.external_scopes = copy.external_scopes.copy()
        self.external_roots = ext_roots_copy^

    fn lookup_repo(self, key: String) -> Int:
        """Repository key → pattern index. Returns -1 if unknown."""
        for i in range(len(self.repo_keys)):
            if self.repo_keys[i] == key:
                return self.repo_pattern_idxs[i]
        return -1

    fn lookup_external(self, scope: String) -> Int:
        """External-scope index → ``external_roots`` slot, or -1.

        The tokenizer uses this to follow ``include: "source.X"``
        references into an embedded grammar's root patterns.
        """
        for i in range(len(self.external_scopes)):
            if self.external_scopes[i] == scope:
                return i
        return -1


fn _path_for_scope(scope: String) -> String:
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
    if scope == String("source.css"):
        return String("src/turbokod/grammars/css.tmLanguage.json")
    if scope == String("text.html.basic"):
        return String("src/turbokod/grammars/html.tmLanguage.json")
    if scope == String("source.json"):
        return String("src/turbokod/grammars/json.tmLanguage.json")
    if scope == String("source.python"):
        return String("src/turbokod/grammars/python.tmLanguage.json")
    return String("")


fn load_grammar_from_file(path: String) raises -> Grammar:
    """Read and parse a ``.tmLanguage.json`` from disk.

    Recursively follows external ``include: "source.X"`` references
    into other bundled grammars (mapped via ``_path_for_scope``);
    the result is a single ``Grammar`` whose ``external_scopes``
    list lets the tokenizer route into the embedded grammars'
    root patterns at runtime.
    """
    var text = read_file(path)
    var loaded = List[String]()
    return _load_grammar_full(text, loaded)


fn load_grammar_from_string(text: String) raises -> Grammar:
    """Parse a grammar JSON already loaded into a string. Useful for
    tests where embedding the grammar inline beats touching the
    filesystem. Does *not* follow external ``include`` references —
    those need a path resolver, which we don't have for raw-string
    callers. Use ``load_grammar_from_file`` if your grammar embeds
    others."""
    var loaded = List[String]()
    return _load_grammar_full(text, loaded)


fn _load_grammar_full(
    text: String, mut loaded_scopes: List[String],
) raises -> Grammar:
    """Inner loader. ``loaded_scopes`` tracks the chain of scopes
    currently being parsed so a circular external include doesn't
    drive us into infinite recursion."""
    var doc = parse_json(text)
    if not doc.is_object():
        raise Error("grammar root is not an object")

    var scope_v = doc.object_get(String("scopeName"))
    var scope_name = String("")
    if scope_v:
        var sv = scope_v.value()
        if sv.is_string():
            scope_name = sv.as_str()
    if len(scope_name.as_bytes()) > 0:
        loaded_scopes.append(scope_name)

    var patterns = List[Pattern]()
    var regexes = List[OnigRegex]()
    var external_scopes = List[String]()
    var external_roots = List[List[Int]]()

    # Parse the repository first so root patterns can reference it
    # via ``$self`` / ``#name`` indices that already exist.
    var repo_keys = List[String]()
    var repo_idxs = List[Int]()
    var repo_v = doc.object_get(String("repository"))
    if repo_v:
        var ro = repo_v.value()
        if ro.is_object():
            for i in range(len(ro.obj_v)):
                var member = ro.obj_v[i]
                var idx = _compile_pattern(
                    member.value, patterns, regexes,
                    external_scopes, external_roots, loaded_scopes,
                    repo_keys, repo_idxs,
                )
                repo_keys.append(member.key)
                repo_idxs.append(idx)

    # Top-level ``patterns`` array.
    var root_patterns = List[Int]()
    var top_v = doc.object_get(String("patterns"))
    if top_v:
        var tv = top_v.value()
        if tv.is_array():
            for i in range(tv.array_len()):
                var idx = _compile_pattern(
                    tv.array_at(i), patterns, regexes,
                    external_scopes, external_roots, loaded_scopes,
                    repo_keys, repo_idxs,
                )
                root_patterns.append(idx)

    return Grammar(
        scope_name^, root_patterns^, patterns^, regexes^,
        repo_keys^, repo_idxs^,
        external_scopes^, external_roots^,
    )


fn _maybe_load_external(
    target: String,
    mut patterns: List[Pattern], mut regexes: List[OnigRegex],
    mut external_scopes: List[String],
    mut external_roots: List[List[Int]],
    mut loaded_scopes: List[String],
    mut repo_keys: List[String],
    mut repo_idxs: List[Int],
) raises:
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
    var has_dot = False
    var tb = target.as_bytes()
    for i in range(len(tb)):
        if tb[i] == 0x2E:
            has_dot = True
            break
    if not has_dot:
        return
    # Already loading this scope (cycle) — leave include alone.
    for i in range(len(loaded_scopes)):
        if loaded_scopes[i] == target:
            return
    # Already loaded as an external — reuse, no extra work.
    for i in range(len(external_scopes)):
        if external_scopes[i] == target:
            return
    var sub_path = _path_for_scope(target)
    if len(sub_path.as_bytes()) == 0:
        return
    # Load the embedded grammar's JSON, then merge its patterns
    # and regexes into ours. We append its compiled patterns into
    # the same flat list so all pattern indices live in one
    # namespace; its root indices get shifted by ``len(patterns)``
    # at the time we begin appending.
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
    external_scopes.append(target)
    external_roots.append(List[Int]())
    var slot_idx = len(external_scopes) - 1
    loaded_scopes.append(target)

    # Compile the embedded grammar's repository entries into the
    # shared flat ``patterns`` / ``regexes`` lists, *and* register
    # their keys under ``"<scope>#<name>"`` in the host's repo so
    # ``#name`` references rewritten by ``_compile_pattern``'s
    # scope-prefix logic find them at lookup time. Without the
    # prefix, embedded keys would silently lose to identically-named
    # host keys (or worse, host lookups would resolve into embedded
    # entries).
    var sub_root = List[Int]()
    var sub_repo_v = sub_doc.object_get(String("repository"))
    if sub_repo_v:
        var sro = sub_repo_v.value()
        if sro.is_object():
            for i in range(len(sro.obj_v)):
                var sm = sro.obj_v[i]
                var sub_idx = _compile_pattern(
                    sm.value, patterns, regexes,
                    external_scopes, external_roots, loaded_scopes,
                    repo_keys, repo_idxs,
                    target,
                )
                repo_keys.append(target + String("#") + sm.key)
                repo_idxs.append(sub_idx)
    var sub_top_v = sub_doc.object_get(String("patterns"))
    if sub_top_v:
        var stv = sub_top_v.value()
        if stv.is_array():
            for i in range(stv.array_len()):
                var ridx = _compile_pattern(
                    stv.array_at(i), patterns, regexes,
                    external_scopes, external_roots, loaded_scopes,
                    repo_keys, repo_idxs,
                    target,
                )
                sub_root.append(ridx)
    external_roots[slot_idx] = sub_root^
    # Pop the loaded-scope marker so siblings can re-encounter
    # this scope later in the parse without being treated as
    # cycles.
    if len(loaded_scopes) > 0 \
            and loaded_scopes[len(loaded_scopes) - 1] == target:
        loaded_scopes.resize(
            len(loaded_scopes) - 1, String(""),
        )


fn _compile_pattern(
    node: JsonValue,
    mut patterns: List[Pattern],
    mut regexes: List[OnigRegex],
    mut external_scopes: List[String],
    mut external_roots: List[List[Int]],
    mut loaded_scopes: List[String],
    mut repo_keys: List[String],
    mut repo_idxs: List[Int],
    scope_prefix: String = String(""),
) raises -> Int:
    """Append a pattern (and any nested ones) to ``patterns``,
    compiling regexes into ``regexes`` along the way. Returns the
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
        # Append a no-op INCLUDE that points at a non-existent key
        # so the tokenizer skips it.
        patterns.append(Pattern(
            PATTERN_INCLUDE, String(""), String(""), -1, -1,
            List[Int](), String("__none__"),
        ))
        return len(patterns) - 1

    # ``include``: store and return; no regexes to compile.
    # Also: if the include's target is an external grammar scope
    # name (contains a ``.``), trigger a recursive load so the
    # tokenizer can route into the embedded grammar's roots.
    var inc_v = node.object_get(String("include"))
    if inc_v:
        var sv = inc_v.value()
        if sv.is_string():
            var raw = sv.as_str()
            var target = raw
            var rb = raw.as_bytes()
            var is_repo_ref = (len(rb) > 0 and rb[0] == 0x23)
            if is_repo_ref:
                target = String(StringSlice(unsafe_from_utf8=rb[1:len(rb)]))
            # Apply the embedded-grammar scope-prefix rewrite so
            # references inside an embedded grammar resolve to that
            # grammar's namespaced repo / roots in the merged tables.
            if len(scope_prefix.as_bytes()) > 0:
                if target == String("$self"):
                    target = scope_prefix
                elif is_repo_ref:
                    target = scope_prefix + String("#") + target
            # Copy the target before calling ``_maybe_load_external``
            # so we don't hold an aliasing read of ``patterns``
            # alongside the ``mut`` borrow it takes.
            var resolved_target = target
            patterns.append(Pattern(
                PATTERN_INCLUDE, String(""), String(""), -1, -1,
                List[Int](), target^,
            ))
            var idx = len(patterns) - 1
            _maybe_load_external(
                resolved_target,
                patterns, regexes,
                external_scopes, external_roots, loaded_scopes,
                repo_keys, repo_idxs,
            )
            return idx

    var name_str = _string_or_empty(node, String("name"))
    var content_name = _string_or_empty(node, String("contentName"))

    var match_v = node.object_get(String("match"))
    var begin_v = node.object_get(String("begin"))
    if match_v:
        var pat_str = match_v.value().as_str()
        # libonig occasionally rejects a regex from a real grammar
        # (look-behind quantifier weirdness, named-group syntax it
        # doesn't recognize, ...). Treat compile failure as "this
        # pattern is dead" rather than failing the whole load —
        # surrounding patterns still light up.
        try:
            var rx = OnigRegex(pat_str)
            regexes.append(rx^)
            var match_idx = len(regexes) - 1
            var caps = _parse_captures(
                node, String("captures"), patterns, regexes,
                external_scopes, external_roots, loaded_scopes,
                repo_keys, repo_idxs,
                scope_prefix,
            )
            patterns.append(Pattern(
                PATTERN_MATCH, name_str^, content_name^, match_idx, -1,
                List[Int](), String(""),
                caps^, List[Capture](),
            ))
            return len(patterns) - 1
        except:
            patterns.append(Pattern(
                PATTERN_INCLUDE, String(""), String(""), -1, -1,
                List[Int](), String("__none__"),
            ))
            return len(patterns) - 1

    if begin_v:
        var begin_str = begin_v.value().as_str()
        # A ``begin`` pattern is paired with either ``end`` or
        # ``while``; ``while``-rules anchor a scope that stays open
        # only as long as each new line starts with the regex.
        var end_v = node.object_get(String("end"))
        var while_v = node.object_get(String("while"))
        if not end_v and not while_v:
            # ``begin`` without either is malformed — skip.
            patterns.append(Pattern(
                PATTERN_INCLUDE, String(""), String(""), -1, -1,
                List[Int](), String("__none__"),
            ))
            return len(patterns) - 1
        var second_str: String
        var pattern_kind: UInt8
        if end_v:
            second_str = end_v.value().as_str()
            pattern_kind = PATTERN_BEGIN_END
        else:
            second_str = while_v.value().as_str()
            pattern_kind = PATTERN_BEGIN_WHILE
        # Same defensive compile as the ``match`` branch — if either
        # the begin or the second-side regex won't compile, drop the
        # pattern instead of failing the whole grammar load.
        var begin_idx: Int
        var end_idx: Int
        try:
            var begin_rx = OnigRegex(begin_str)
            regexes.append(begin_rx^)
            begin_idx = len(regexes) - 1
            var second_rx = OnigRegex(second_str)
            regexes.append(second_rx^)
            end_idx = len(regexes) - 1
        except:
            patterns.append(Pattern(
                PATTERN_INCLUDE, String(""), String(""), -1, -1,
                List[Int](), String("__none__"),
            ))
            return len(patterns) - 1

        # Nested patterns must be compiled before the parent is
        # appended so we know each child's index. Otherwise the
        # parent's slot ID would be ambiguous if children referenced
        # each other.
        var nested = List[Int]()
        var nested_v = node.object_get(String("patterns"))
        if nested_v:
            var nv = nested_v.value()
            if nv.is_array():
                for k in range(nv.array_len()):
                    var ci = _compile_pattern(
                        nv.array_at(k), patterns, regexes,
                        external_scopes, external_roots, loaded_scopes,
                        repo_keys, repo_idxs,
                        scope_prefix,
                    )
                    nested.append(ci)

        # ``captures`` (singular) on a begin/end pattern is shorthand
        # for "applies to both begin and end" in TextMate's spec.
        # ``beginCaptures`` / ``endCaptures`` override that per-side.
        # For ``while``-rules, ``whileCaptures`` is the per-side key
        # (we map it onto the same ``end_captures`` slot since each
        # pattern only has one tail-side anyway).
        var both_caps = _parse_captures(
            node, String("captures"), patterns, regexes,
            external_scopes, external_roots, loaded_scopes,
            repo_keys, repo_idxs,
            scope_prefix,
        )
        var begin_caps = _parse_captures(
            node, String("beginCaptures"), patterns, regexes,
            external_scopes, external_roots, loaded_scopes,
            repo_keys, repo_idxs,
            scope_prefix,
        )
        var end_caps = _parse_captures(
            node, String("endCaptures"), patterns, regexes,
            external_scopes, external_roots, loaded_scopes,
            repo_keys, repo_idxs,
            scope_prefix,
        )
        var while_caps = _parse_captures(
            node, String("whileCaptures"), patterns, regexes,
            external_scopes, external_roots, loaded_scopes,
            repo_keys, repo_idxs,
            scope_prefix,
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

        patterns.append(Pattern(
            pattern_kind, name_str^, content_name^,
            begin_idx, end_idx, nested^, String(""),
            begin_caps^, end_caps^,
        ))
        return len(patterns) - 1

    # No ``match`` / ``begin`` / ``include`` — but the entry may
    # carry a nested ``patterns`` array as a pure container ("group").
    # Real-world grammars wrap every repository entry this way:
    # ``"keywords": { "patterns": [...] }``. We compile the children
    # eagerly and store their indices in ``nested``; the tokenizer's
    # ``_expand_into`` walks GROUPs the same way it walks INCLUDEs.
    var grp_v = node.object_get(String("patterns"))
    var grp_children = List[Int]()
    if grp_v:
        var gv = grp_v.value()
        if gv.is_array():
            for k in range(gv.array_len()):
                var ci = _compile_pattern(
                    gv.array_at(k), patterns, regexes,
                    external_scopes, external_roots, loaded_scopes,
                    repo_keys, repo_idxs,
                    scope_prefix,
                )
                grp_children.append(ci)
    if len(grp_children) > 0:
        patterns.append(Pattern(
            PATTERN_GROUP, String(""), String(""), -1, -1,
            grp_children^, String(""),
        ))
        return len(patterns) - 1
    # Truly empty entry — fall back to a no-op include.
    patterns.append(Pattern(
        PATTERN_INCLUDE, String(""), String(""), -1, -1,
        List[Int](), String("__none__"),
    ))
    return len(patterns) - 1


fn _parse_captures(
    node: JsonValue, key: String,
    mut patterns: List[Pattern], mut regexes: List[OnigRegex],
    mut external_scopes: List[String],
    mut external_roots: List[List[Int]],
    mut loaded_scopes: List[String],
    mut repo_keys: List[String],
    mut repo_idxs: List[Int],
    scope_prefix: String = String(""),
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
    inside the group. Anything that isn't an object with at least
    a ``name`` or ``patterns`` field is skipped silently.

    Why ``raises``: nested ``patterns`` may contain regex patterns,
    so we have to push compilation through the same path used by
    top-level patterns, which can ``raise`` on bad regex. The
    parent loader threads ``raises`` through.
    """
    var out = List[Capture]()
    var v = node.object_get(key)
    if not v:
        return out^
    var ov = v.value()
    if not ov.is_object():
        return out^
    for i in range(len(ov.obj_v)):
        var member = ov.obj_v[i]
        if not member.value.is_object():
            continue
        var name_str = String("")
        var name_v = member.value.object_get(String("name"))
        if name_v:
            var sv = name_v.value()
            if sv.is_string():
                name_str = sv.as_str()
        # Parse a nested ``patterns`` array if present. The patterns
        # get compiled flat into the parent grammar's ``patterns`` /
        # ``regexes`` lists; we record their indices on the Capture
        # so the tokenizer's ``_emit_captures`` can apply them to
        # the captured byte range.
        var nested = List[Int]()
        var pats_v = member.value.object_get(String("patterns"))
        if pats_v:
            var pv = pats_v.value()
            if pv.is_array():
                for k in range(pv.array_len()):
                    var ci = _compile_pattern(
                        pv.array_at(k), patterns, regexes,
                        external_scopes, external_roots, loaded_scopes,
                        repo_keys, repo_idxs,
                        scope_prefix,
                    )
                    nested.append(ci)
        # Suppress "unused parameter" when these thread through but
        # the captured patterns array is empty.
        _ = scope_prefix
        if len(name_str.as_bytes()) == 0 and len(nested) == 0:
            continue
        var idx = parse_int_all(member.key)
        if idx < 0:
            continue
        out.append(Capture(idx, name_str^, nested^))
    return out^




fn _string_or_empty(node: JsonValue, key: String) -> String:
    var v = node.object_get(key)
    if not v:
        return String("")
    var sv = v.value()
    if not sv.is_string():
        return String("")
    return sv.as_str()
