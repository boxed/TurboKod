"""Which textual occurrence of a name Find Symbol should seed from.

The picker shows one row per identifier *name*, but a name occurs in
many files, and the row carries exactly one ``(path, line, column)``.
That location matters twice: it is the seed handed to the language
server's ``workspace/symbol`` lookup, and — when no server for that
language is running or ready — it is where the user *lands*.

Before this module the seed was whichever file the index (or ``rg``)
happened to scan first, which on a real project was the changelog: a
query for ``Column`` in iommi opened ``HISTORY.rst`` on a bullet point
mentioning the class, with ``class Column(Part)`` sitting untouched in
``iommi/table.py``. Ranking is heuristic by design — the LSP remains
the authority when it is available — but the heuristic only has to
beat "alphabetical order", and it does so on two signals:

1. **Does the occurrence look like a definition?** The previous token
   on the line is a definition keyword (``class``, ``def``, ``struct``,
   ``fn``, ``const``, …), or the name opens the line and is followed by
   a lone ``=``. Language-agnostic on purpose: the index tokenizes
   every file the same way and cannot afford a parser per language.
2. **What kind of file is it in?** Source beats test source beats
   prose and data (``.rst``, ``.md``, ``.json``, ``Makefile``,
   dotfiles). A ``class Column`` inside an ``.rst`` literal block is an
   example, not a definition, so a bare *mention* in real source still
   outranks it.

Shallower paths break the remaining ties, so ``iommi/table.py`` beats
``examples/examples/iommi.py`` when both define the class.

Both consumers — ``SymbolIndex`` (the fast path) and the streaming
``rg`` runner in ``find_symbol.mojo`` (the cold-index fallback) — rank
through ``seed_priority`` so the two paths agree on the seed.
"""

from .case_fold import fold_ascii
from .file_io import basename


comptime SEED_DEF_IN_SOURCE: Int = 0
"""Definition-shaped occurrence in a non-test source file."""
comptime SEED_DEF_IN_TEST: Int = 1
"""Definition-shaped occurrence in a test file."""
comptime SEED_MENTION_IN_SOURCE: Int = 2
comptime SEED_MENTION_IN_TEST: Int = 3
comptime SEED_DEF_IN_PROSE: Int = 4
"""Definition-shaped, but in documentation or data — an example."""
comptime SEED_MENTION_IN_PROSE: Int = 5

comptime _DEPTH_BITS: Int = 8
"""Bits reserved for the path-depth tiebreak below the bucket."""


def seed_priority(path: String, is_definition: Bool) -> Int:
    """Sort key for a seed candidate; **lower wins**.

    The bucket (see the ``SEED_*`` constants) dominates; path depth
    breaks ties within a bucket so the shallower, more central file
    wins. Depth is the count of ``/`` in ``path``, which compares
    correctly between files of one project because they share the
    root prefix."""
    var kind = file_kind(path)
    var bucket: Int
    if kind == _KIND_SOURCE:
        bucket = SEED_DEF_IN_SOURCE if is_definition \
            else SEED_MENTION_IN_SOURCE
    elif kind == _KIND_TEST:
        bucket = SEED_DEF_IN_TEST if is_definition \
            else SEED_MENTION_IN_TEST
    else:
        bucket = SEED_DEF_IN_PROSE if is_definition \
            else SEED_MENTION_IN_PROSE
    var depth = 0
    var b = path.as_bytes()
    for i in range(len(b)):
        if b[i] == 0x2F:
            depth += 1
    if depth >= (1 << _DEPTH_BITS):
        depth = (1 << _DEPTH_BITS) - 1
    return (bucket << _DEPTH_BITS) | depth


def seed_bucket(priority: Int) -> Int:
    """Recover the ``SEED_*`` bucket from a ``seed_priority`` value."""
    return priority >> _DEPTH_BITS


# --- occurrence shape --------------------------------------------------------


def is_definition_site(line: Span[UInt8, _], start: Int, end: Int) -> Bool:
    """Does the identifier occupying ``line[start:end]`` look like it is
    being *defined* there, rather than used?

    Two shapes, both cheap enough for the indexer's inner loop:

    - The previous token on the line is a definition keyword and only
      horizontal whitespace separates them: ``class Column``,
      ``pub fn run``, ``type alias Model``, ``const X``. A separator
      other than whitespace breaks the pairing, so ``type(x)`` and
      ``foo.def`` do not count.
    - The identifier opens the line (no indentation) and is followed by
      whitespace and a single ``=``: the module-level constant / alias /
      Elm-Haskell top-level binding shape. Indented ``x = …`` is not
      counted; that is mostly locals and keyword arguments.
    """
    if start < 0 or end > len(line) or start >= end:
        return False
    if start == 0:
        var j = end
        while j < len(line) and (line[j] == 0x20 or line[j] == 0x09):
            j += 1
        if j < len(line) and line[j] == 0x3D:
            if j + 1 >= len(line) or line[j + 1] != 0x3D:
                return True
    # Walk back over horizontal whitespace to the previous token.
    var k = start
    while k > 0 and (line[k - 1] == 0x20 or line[k - 1] == 0x09):
        k -= 1
    if k == start or k == 0:
        # No gap at all (cannot happen for a tokenized identifier, but
        # a caller with rg's column may hand us one), or the identifier
        # is the first thing on the line.
        return False
    var prev_end = k
    while k > 0 and _is_word_byte(line[k - 1]):
        k -= 1
    if k == prev_end:
        return False
    # ``obj.def Name`` — a member named like a keyword is not the
    # keyword. Anything else in front of it (line start, whitespace,
    # ``(``, ``@``, ``;``) leaves the keyword standing on its own.
    if k > 0 and line[k - 1] == 0x2E:
        return False
    return is_definition_keyword(line[k:prev_end])


def is_definition_keyword(word: Span[UInt8, _]) -> Bool:
    """Keywords that introduce a named definition in the languages the
    editor highlights. Deliberately excludes ``import`` / ``from`` /
    ``use`` (those *reference* a name) and ``return`` / ``new`` / ``as``.
    Length-switched so the hot path is one or two byte compares."""
    var n = len(word)
    if n == 2:
        return _eq(word, "fn")
    if n == 3:
        return _eq(word, "def") or _eq(word, "let") or _eq(word, "var") \
            or _eq(word, "fun") or _eq(word, "val") or _eq(word, "mod")
    if n == 4:
        return _eq(word, "func") or _eq(word, "type") or _eq(word, "enum") \
            or _eq(word, "impl") or _eq(word, "data") or _eq(word, "proc") \
            or _eq(word, "defp")
    if n == 5:
        return _eq(word, "class") or _eq(word, "const") \
            or _eq(word, "trait") or _eq(word, "alias") \
            or _eq(word, "macro") or _eq(word, "union")
    if n == 6:
        return _eq(word, "struct") or _eq(word, "module") \
            or _eq(word, "object") or _eq(word, "record")
    if n == 7:
        return _eq(word, "typedef") or _eq(word, "newtype")
    if n == 8:
        return _eq(word, "function") or _eq(word, "protocol") \
            or _eq(word, "comptime") or _eq(word, "delegate") \
            or _eq(word, "defmacro")
    if n == 9:
        return _eq(word, "interface") or _eq(word, "extension") \
            or _eq(word, "namespace") or _eq(word, "defmodule")
    return False


def _eq(word: Span[UInt8, _], lit: StringSpan) -> Bool:
    var lb = lit.as_bytes()
    if len(word) != len(lb):
        return False
    for i in range(len(lb)):
        if word[i] != lb[i]:
            return False
    return True


def _is_word_byte(b: UInt8) -> Bool:
    var c = Int(b)
    return (0x30 <= c and c <= 0x39) or (0x41 <= c and c <= 0x5A) \
        or (0x61 <= c and c <= 0x7A) or c == 0x5F


# --- file kind ---------------------------------------------------------------


comptime _KIND_SOURCE: Int = 0
comptime _KIND_TEST: Int = 1
comptime _KIND_PROSE: Int = 2


def file_kind(path: String) -> Int:
    """Classify ``path`` as source, test source, or prose/data.

    Prose/data is decided by extension (documentation, markup, config
    and data formats) plus two shapes that carry no extension at all:
    dotfiles (``.gitignore``, ``.env``) and bare names (``Makefile``,
    ``LICENSE``, ``Dockerfile``). Anything else is source, and source
    is test source when a path segment is a conventional test directory
    or the file name carries a conventional test affix (``test_x.py``,
    ``x__tests.py``, ``x_test.go``, ``x.spec.ts``, ``FooTests.swift``).
    """
    var name = basename(path)
    var nb = name.as_bytes()
    if len(nb) == 0:
        return _KIND_PROSE
    var dot = -1
    for i in range(len(nb)):
        if nb[i] == 0x2E:
            dot = i
    if dot <= 0:
        # Dotfile or no extension at all.
        return _KIND_PROSE
    var ext = String(StringSpan(unsafe_from_utf8=nb[dot + 1:len(nb)]))
    if _is_prose_extension(fold_ascii(ext)):
        return _KIND_PROSE
    if _looks_like_test_path(path, name):
        return _KIND_TEST
    return _KIND_SOURCE


def _is_prose_extension(ext: String) -> Bool:
    var e = ext.as_bytes()
    var n = len(e)
    if n == 2:
        return _eq(e, "md") or _eq(e, "po")
    if n == 3:
        return _eq(e, "rst") or _eq(e, "txt") or _eq(e, "mdx") \
            or _eq(e, "org") or _eq(e, "tex") or _eq(e, "htm") \
            or _eq(e, "xml") or _eq(e, "yml") or _eq(e, "ini") \
            or _eq(e, "cfg") or _eq(e, "csv") or _eq(e, "tsv") \
            or _eq(e, "log") or _eq(e, "pot") or _eq(e, "svg") \
            or _eq(e, "bib")
    if n == 4:
        return _eq(e, "text") or _eq(e, "adoc") or _eq(e, "html") \
            or _eq(e, "json") or _eq(e, "yaml") or _eq(e, "toml") \
            or _eq(e, "lock") or _eq(e, "conf")
    if n == 8:
        return _eq(e, "markdown") or _eq(e, "asciidoc")
    return False


def _looks_like_test_path(path: String, name: String) -> Bool:
    # Directory segments: ``tests/``, ``test/``, ``__tests__/``,
    # ``spec/``, ``testing/``. The basename is excluded from this scan.
    var pb = path.as_bytes()
    var seg_start = 0
    var last_slash = -1
    for i in range(len(pb)):
        if pb[i] == 0x2F:
            last_slash = i
    for i in range(len(pb)):
        if pb[i] == 0x2F:
            if i > seg_start and i <= last_slash \
                    and _is_test_dir_segment(pb[seg_start:i]):
                return True
            seg_start = i + 1
    var nb = name.as_bytes()
    var dot = -1
    for i in range(len(nb)):
        if nb[i] == 0x2E:
            dot = i
    var stem = nb[0:dot] if dot > 0 else nb
    if _starts(stem, "test_") or _eq(stem, "test") or _eq(stem, "tests") \
            or _eq(stem, "conftest"):
        return True
    if _ends(stem, "_test") or _ends(stem, "_tests") \
            or _ends(stem, "__tests") or _ends(stem, ".test") \
            or _ends(stem, ".spec") or _ends(stem, "_spec") \
            or _ends(stem, "Test") or _ends(stem, "Tests") \
            or _ends(stem, "Spec"):
        return True
    return False


def _is_test_dir_segment(seg: Span[UInt8, _]) -> Bool:
    return _eq(seg, "test") or _eq(seg, "tests") or _eq(seg, "__tests__") \
        or _eq(seg, "spec") or _eq(seg, "specs") or _eq(seg, "testing")


def _starts(b: Span[UInt8, _], lit: StringSpan) -> Bool:
    var lb = lit.as_bytes()
    if len(b) < len(lb):
        return False
    for i in range(len(lb)):
        if b[i] != lb[i]:
            return False
    return True


def _ends(b: Span[UInt8, _], lit: StringSpan) -> Bool:
    var lb = lit.as_bytes()
    if len(b) < len(lb):
        return False
    var off = len(b) - len(lb)
    for i in range(len(lb)):
        if b[off + i] != lb[i]:
            return False
    return True

