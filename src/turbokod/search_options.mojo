"""Shared search-mode flags: case sensitive, whole word, regex.

Used by the in-file Find/Replace flow (``editor.find_next``,
``editor.find_prev``, ``editor.replace_all``) and the project-wide
search (``project_find.ProjectFind`` and ``project.find_in_project`` /
``project.replace_in_project``). The values map directly onto the
three toggle buttons on the Find prompt and the Find-in-Project
dialog (``Cc`` / ``W`` / ``.*``).

Default-constructed ``SearchOptions`` is "no flags" — case-sensitive,
literal substring match, no word boundary — which preserves the
behavior the codebase had before toggles existed.
"""

from std.collections.optional import Optional

from .onig import OnigRegex


struct SearchOptions(ImplicitlyCopyable, Movable):
    var case_sensitive: Bool
    var whole_word: Bool
    var regex: Bool

    fn __init__(out self):
        self.case_sensitive = False
        self.whole_word = False
        self.regex = False

    fn __init__(
        out self, case_sensitive: Bool, whole_word: Bool, regex: Bool,
    ):
        self.case_sensitive = case_sensitive
        self.whole_word = whole_word
        self.regex = regex

    fn __copyinit__(out self, copy: Self):
        self.case_sensitive = copy.case_sensitive
        self.whole_word = copy.whole_word
        self.regex = copy.regex

    fn any_set(self) -> Bool:
        return self.case_sensitive or self.whole_word or self.regex


fn default_search_options() -> SearchOptions:
    """Factory for the all-flags-off default. Used as the default
    argument value for ``find_next`` / ``find_prev`` / ``replace_all``
    and the project-wide variants so callers that don't care about
    toggles keep the literal, case-sensitive substring behavior the
    codebase had before search options existed."""
    return SearchOptions()


fn regex_escape_literal(needle: String) -> String:
    """Escape ``needle`` so libonig treats every byte as literal. Used
    when the user has opted into whole-word or case-insensitive but
    *not* regex — we still need a regex to express the boundary or
    ``(?i)`` flag, so the literal needle is escaped first."""
    var out = String("")
    var b = needle.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        # Conservative set: every metachar libonig recognizes in the
        # default syntax, plus a backslash for the escape itself.
        if c == 0x5C or c == 0x5E or c == 0x24 or c == 0x2E \
                or c == 0x7C or c == 0x3F or c == 0x2A or c == 0x2B \
                or c == 0x28 or c == 0x29 or c == 0x5B or c == 0x5D \
                or c == 0x7B or c == 0x7D:
            out = out + String("\\")
        var ch = chr(c) if c < 0x80 else String(StringSlice(
            unsafe_from_utf8=b[i:i + 1],
        ))
        out = out + ch
    return out


fn build_search_regex(
    needle: String, opts: SearchOptions,
) -> Optional[OnigRegex]:
    """Compile ``needle`` into a regex honoring ``opts`` flags, or
    return None when the byte-match fast path is sufficient. The
    fast path is reserved for ``case_sensitive=True`` + literal
    needle (W off, .* off): a plain case-sensitive substring scan.
    Every other configuration — including the all-off default
    (Cc off → case-insensitive) — funnels through libonig.

    Whole-word is implemented as ``\\b(?:...)\\b``. Case-insensitive
    via the ``(?i)`` modifier. Regex mode uses the user's pattern
    verbatim; literal mode escapes regex metacharacters first.
    Returns None for an unparseable pattern as well — callers should
    treat that the same as "no match" rather than crashing."""
    if opts.case_sensitive and not opts.whole_word and not opts.regex:
        return Optional[OnigRegex]()
    var pat: String
    if opts.regex:
        pat = needle
    else:
        pat = regex_escape_literal(needle)
    if opts.whole_word:
        pat = String("\\b(?:") + pat + String(")\\b")
    if not opts.case_sensitive:
        pat = String("(?i)") + pat
    try:
        return Optional[OnigRegex](OnigRegex(pat))
    except:
        return Optional[OnigRegex]()
