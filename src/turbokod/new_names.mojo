"""The names a changeset introduces: its new functions, variables and types.

Git ▸ Review new names (``NamesReview``) lists these instead of every
change, because naming is the part of a review
that's easiest to skim past while reading a diff for correctness.

A name is **new** when the changeset defines it on an added line and it
occurs nowhere — not even as a mention — in the "before" side of any file
in the changeset. So a function moved between two files of the change
isn't new, and neither is a variable that was renamed *to* a name the
file already used. Each new name is reported once, at its first
definition (files in changeset order, rows top to bottom).

"Defines" is a language-agnostic, line-shaped heuristic, like
``symbol_seed.is_definition_site`` — the editor has no parser per
language and a review can span many:

- the previous word is a definition keyword: ``def``/``fn``/``func``/
  ``function`` (a function), ``class``/``struct``/``trait``/``enum``/…
  (a type), ``var``/``let``/``const``/``val``/``comptime``/``alias``/
  ``for`` (a variable);
- the name opens its (indented) line and is assigned: ``x = …``,
  ``x := …``, ``x: int = …``. Assigned a ``lambda`` / ``function`` /
  arrow function, it's a function;
- a parameter of a function defined on an added line, including a
  parameter list that runs over several lines;
- in C-family files (no definition keywords there): ``Type name(`` is a
  function and ``Type name =`` / ``Type name;`` a variable.

Comments and string literals (triple-quoted ones across lines too) are
skipped, so prose in a docstring isn't mistaken for code.
"""

from std.collections.dict import Dict

from .diff import DIFF_ROW_ADDED, build_diff_rows
from .string_utils import is_ascii_ident_byte, split_lines_no_trailing


comptime NAME_FUNCTION: Int = 0
comptime NAME_VARIABLE: Int = 1
comptime NAME_TYPE: Int = 2


def name_kind_label(kind: Int) -> String:
    if kind == NAME_FUNCTION:
        return String("function")
    if kind == NAME_TYPE:
        return String("type")
    return String("variable")


@fieldwise_init
struct NameDef(ImplicitlyCopyable, Movable):
    """One definition on a line: ``name`` at byte ``col`` of ``row``.
    ``what`` is the specific kind shown to the user: ``function``,
    ``variable``, ``parameter``, ``constant``, or a type's keyword
    (``class``, ``struct``, ``enum``, …)."""
    var name: String
    var kind: Int
    var what: String
    var row: Int
    var col: Int


@fieldwise_init
struct NewName(ImplicitlyCopyable, Movable):
    """A new name in a changeset: its first definition, in file ``file``
    (an index into the changeset's file list)."""
    var name: String
    var kind: Int
    var what: String
    var file: Int
    var row: Int
    var col: Int


# --- keyword classes ---------------------------------------------------------


def _word_in(word: String, words: StringSpan) -> Bool:
    """``word`` is one of the space-separated ``words``."""
    var wb = word.as_bytes()
    var b = words.as_bytes()
    var n = len(b)
    var i = 0
    while i < n:
        var j = i
        while j < n and b[j] != 0x20:
            j += 1
        if j - i == len(wb):
            var same = True
            for k in range(len(wb)):
                if b[i + k] != wb[k]:
                    same = False
                    break
            if same:
                return True
        i = j + 1
    return False


def _is_function_keyword(w: String) -> Bool:
    return _word_in(w, "def fn func function fun proc defp sub macro defmacro")


def _is_type_keyword(w: String) -> Bool:
    return _word_in(
        w,
        "class struct trait interface enum type union record protocol"
        " object typedef newtype data",
    )


def _is_variable_keyword(w: String) -> Bool:
    return _word_in(
        w, "var let val const comptime alias for global local auto my our",
    )


def _is_param_modifier(w: String) -> Bool:
    """Words in a parameter that aren't its name."""
    return _word_in(
        w,
        "self cls this mut out var owned ref imm inout read deinit const"
        " final in let borrowed _ unsafe",
    )


def _is_c_non_type(w: String) -> Bool:
    """Words that can sit before a name in C-family code without being its
    type: ``return x;`` doesn't define ``x``."""
    return _word_in(
        w,
        "return else new delete throw case goto sizeof typeof await yield"
        " in is as not and or if while for switch do using namespace import"
        " package include define public private protected internal override"
        " abstract export default static extern inline virtual friend"
        " operator template typename struct class enum union",
    )


def _is_c_like(path: String) -> Bool:
    var b = path.as_bytes()
    var dot = -1
    for i in range(len(b) - 1, -1, -1):
        if b[i] == 0x2E:
            dot = i
            break
        if b[i] == 0x2F:
            break
    if dot < 0:
        return False
    var ext = String(StringSpan(unsafe_from_utf8=b[dot + 1 :]))
    return _word_in(ext, "c cc cpp cxx h hh hpp hxx java cs m mm dart")


# --- line scanning -----------------------------------------------------------


def _is_ident_start(c: UInt8) -> Bool:
    return is_ascii_ident_byte(c) and not (c >= 0x30 and c <= 0x39)


def _is_space(c: UInt8) -> Bool:
    return c == 0x20 or c == 0x09


def _code_mask(line: Span[UInt8, _], mut in_triple: Int, c_like: Bool) -> List[Bool]:
    """Per byte: is it code (not inside a comment or string literal)?
    ``in_triple`` carries an open triple-quoted string across lines — 0
    when none, else the quote byte — and ``-1`` an open ``/* */``."""
    var n = len(line)
    var mask = List[Bool](length=n, fill=False)
    var i = 0
    while i < n:
        var c = line[i]
        if in_triple == -1:
            if c == 0x2A and i + 1 < n and line[i + 1] == 0x2F:
                in_triple = 0
                i += 2
            else:
                i += 1
            continue
        if in_triple > 0:
            if c == UInt8(in_triple) and i + 2 < n \
                    and line[i + 1] == c and line[i + 2] == c:
                in_triple = 0
                i += 3
            else:
                i += 1
            continue
        if c == 0x2F and i + 1 < n and line[i + 1] == 0x2F:
            break   # // comment
        if c == 0x2F and i + 1 < n and line[i + 1] == 0x2A:
            in_triple = -1
            i += 2
            continue
        if c == 0x23 and not c_like:
            break   # # comment
        if c == 0x22 or c == 0x27 or c == 0x60:
            if i + 2 < n and line[i + 1] == c and line[i + 2] == c:
                in_triple = Int(c)
                i += 3
                continue
            # A single-line literal: skip to its unescaped close.
            i += 1
            while i < n and line[i] != c:
                if line[i] == 0x5C:
                    i += 1
                i += 1
            i += 1
            continue
        mask[i] = True
        i += 1
    return mask^


def _word(line: Span[UInt8, _], s: Int, e: Int) -> String:
    return String(StringSpan(unsafe_from_utf8=line[s:e]))


def _skip_space(line: Span[UInt8, _], i: Int) -> Int:
    var j = i
    while j < len(line) and _is_space(line[j]):
        j += 1
    return j


def _prev_word(line: Span[UInt8, _], mask: List[Bool], s: Int) -> Tuple[Int, Int]:
    """The word right before ``s`` with only whitespace between, as
    ``(start, end)``, or ``(-1, -1)``. A word preceded by ``.`` is a
    member, not a keyword, so it doesn't count."""
    var k = s
    while k > 0 and _is_space(line[k - 1]):
        k -= 1
    if k == s:
        return (-1, -1)
    var pe = k
    while k > 0 and is_ascii_ident_byte(line[k - 1]) and mask[k - 1]:
        k -= 1
    if k == pe or (k > 0 and line[k - 1] == 0x2E):
        return (-1, -1)
    return (k, pe)


def _first_code(line: Span[UInt8, _]) -> Int:
    return _skip_space(line, 0)


def _last_code_byte(line: Span[UInt8, _], mask: List[Bool]) -> UInt8:
    for i in range(len(line) - 1, -1, -1):
        if mask[i] and not _is_space(line[i]):
            return line[i]
    return 0


def _rhs_is_function(line: Span[UInt8, _], at: Int) -> Bool:
    """The right-hand side starting at ``at`` is a function value."""
    var j = _skip_space(line, at)
    var rest = _word(line, j, len(line))
    return rest.startswith("lambda") or rest.startswith("function") \
        or rest.startswith("async ") or rest.find("=>") >= 0


def _assignment_rhs(line: Span[UInt8, _], mask: List[Bool], e: Int) -> Int:
    """If the name ending at ``e`` is assigned (``x = …``, ``x := …``,
    ``x: T = …``), the byte where the right-hand side starts; else -1."""
    var n = len(line)
    var j = _skip_space(line, e)
    if j < n and line[j] == 0x3A and j + 1 < n and line[j + 1] == 0x3D:
        return j + 2   # :=
    if j < n and line[j] == 0x3A:
        # An annotation: look for a lone ``=`` further on.
        var k = j + 1
        while k < n:
            if mask[k] and line[k] == 0x3D:
                if (k + 1 < n and (line[k + 1] == 0x3D or line[k + 1] == 0x3E)) \
                        or line[k - 1] == 0x3D or line[k - 1] == 0x21 \
                        or line[k - 1] == 0x3C or line[k - 1] == 0x3E:
                    return -1
                return k + 1
            k += 1
        return -1
    if j < n and line[j] == 0x3D:
        if j + 1 < n and (line[j + 1] == 0x3D or line[j + 1] == 0x3E):
            return -1   # == / =>
        return j + 1
    return -1


struct _ParamState(Movable):
    """An open parameter list of a function defined on an added line.
    ``depth`` counts brackets inside the list; ``seg_*`` collects the
    current parameter's words up to its ``:`` / ``=``."""
    var open: Bool
    var depth: Int
    var seg_done: Bool
    var seg_words: List[NameDef]

    def __init__(out self):
        self.open = False
        self.depth = 0
        self.seg_done = False
        self.seg_words = List[NameDef]()


def _close_param(mut ps: _ParamState, c_like: Bool, mut out: List[NameDef]):
    """End the current parameter: its name is the first word that isn't a
    modifier (``name: T``, ``name T``), or the last one in C-family code
    (``T name``)."""
    var pick = -1
    for i in range(len(ps.seg_words)):
        if _is_param_modifier(ps.seg_words[i].name):
            continue
        pick = i
        if not c_like:
            break
    if pick >= 0:
        out.append(ps.seg_words[pick])
    ps.seg_words = List[NameDef]()
    ps.seg_done = False


def _scan_params(
    line: Span[UInt8, _], mask: List[Bool], start: Int, row: Int,
    mut ps: _ParamState, c_like: Bool, mut out: List[NameDef],
) -> Int:
    """Feed ``line[start:]`` to an open parameter list. Returns the byte
    just past where it closed (``len(line)`` while still open)."""
    var n = len(line)
    var i = start
    while i < n and ps.open:
        var c = line[i]
        if not mask[i]:
            i += 1
            continue
        if c == 0x28 or c == 0x5B or c == 0x7B or c == 0x3C:   # ( [ { <
            ps.depth += 1
            if ps.depth > 1:
                ps.seg_done = True   # a type's own brackets
        elif c == 0x29 or c == 0x5D or c == 0x7D or c == 0x3E:  # ) ] } >
            if c == 0x3E and i > 0 and line[i - 1] == 0x2D:
                pass   # -> isn't a bracket
            else:
                ps.depth -= 1
                if ps.depth == 0:
                    _close_param(ps, c_like, out)
                    ps.open = False
                    return i + 1
        elif c == 0x2C and ps.depth == 1:
            _close_param(ps, c_like, out)
        elif (c == 0x3A or c == 0x3D) and ps.depth == 1:
            ps.seg_done = True
        elif _is_ident_start(c) and ps.depth == 1 and not ps.seg_done:
            var e = i
            while e < n and is_ascii_ident_byte(line[e]):
                e += 1
            ps.seg_words.append(NameDef(
                _word(line, i, e), NAME_VARIABLE, String("parameter"), row, i,
            ))
            i = e
            continue
        i += 1
    return n


def find_definitions(
    path: String, text: String, rows_wanted: List[Bool],
) -> List[NameDef]:
    """The definitions on the rows of ``text`` flagged in ``rows_wanted``
    (the changeset's added rows). The whole text is walked — triple-quoted
    strings and parameter lists open across rows — but only flagged rows
    report."""
    var out = List[NameDef]()
    var c_like = _is_c_like(path)
    var lines = split_lines_no_trailing(text)
    var in_triple = 0
    var ps = _ParamState()
    for row in range(len(lines)):
        var line = lines[row].as_bytes()
        var n = len(line)
        var mask = _code_mask(line, in_triple, c_like)
        var wanted = row < len(rows_wanted) and rows_wanted[row]
        var found = List[NameDef]()
        var start = 0
        if ps.open:
            start = _scan_params(line, mask, 0, row, ps, c_like, found)
        var first = _first_code(line)
        var i = start
        while i < n:
            if not mask[i] or not _is_ident_start(line[i]) \
                    or (i > 0 and is_ascii_ident_byte(line[i - 1])):
                i += 1
                continue
            var s = i
            var e = i
            while e < n and is_ascii_ident_byte(line[e]):
                e += 1
            i = e
            var name = _word(line, s, e)
            var kind = -1
            var what = String("")
            var pw = _prev_word(line, mask, s)
            if pw[0] >= 0:
                var prev = _word(line, pw[0], pw[1])
                if _is_function_keyword(prev):
                    kind = NAME_FUNCTION
                elif _is_type_keyword(prev):
                    kind = NAME_TYPE
                    what = prev
                elif _is_variable_keyword(prev):
                    kind = NAME_VARIABLE
                    if _word_in(prev, "const comptime alias"):
                        what = String("constant")
                    var rhs = _assignment_rhs(line, mask, e)
                    if rhs >= 0 and _rhs_is_function(line, rhs):
                        kind = NAME_FUNCTION
                elif prev == "mut":
                    var pp = _prev_word(line, mask, pw[0])
                    if pp[0] >= 0 and _word_in(
                        _word(line, pp[0], pp[1]), "let static",
                    ):
                        kind = NAME_VARIABLE
                elif c_like and not _is_c_non_type(prev) \
                        and not _is_c_non_type(name):
                    var j = _skip_space(line, e)
                    if j < n and line[j] == 0x28:
                        kind = NAME_FUNCTION
                    elif j >= n or line[j] == 0x3B or line[j] == 0x2C \
                            or line[j] == 0x5B or line[j] == 0x7B \
                            or (line[j] == 0x3D
                                and (j + 1 >= n or line[j + 1] != 0x3D)):
                        kind = NAME_VARIABLE
            elif s == first:
                var rhs = _assignment_rhs(line, mask, e)
                # A trailing comma means a keyword argument on a
                # continuation line, not a statement.
                if rhs >= 0 and _last_code_byte(line, mask) != 0x2C:
                    kind = NAME_FUNCTION if _rhs_is_function(line, rhs) \
                        else NAME_VARIABLE
            if kind < 0:
                continue
            if kind == NAME_FUNCTION or len(what.as_bytes()) == 0:
                what = name_kind_label(kind)
            found.append(NameDef(name, kind, what, row, s))
            if kind == NAME_FUNCTION:
                # Its parameters: skip generic brackets to the ``(``.
                var j = _skip_space(line, e)
                if j < n and (line[j] == 0x5B or line[j] == 0x3C):
                    var depth = 0
                    while j < n:
                        if line[j] == 0x5B or line[j] == 0x3C:
                            depth += 1
                        elif line[j] == 0x5D or line[j] == 0x3E:
                            depth -= 1
                            if depth == 0:
                                j += 1
                                break
                        j += 1
                    j = _skip_space(line, j)
                if j < n and line[j] == 0x28 and mask[j]:
                    ps = _ParamState()
                    ps.open = True
                    ps.depth = 1
                    i = _scan_params(line, mask, j + 1, row, ps, c_like, found)
        if wanted:
            for k in range(len(found)):
                out.append(found[k])
    return out^


def identifier_set(text: String, mut into: Dict[String, Bool]):
    """Add every ASCII identifier in ``text`` to ``into``."""
    var b = text.as_bytes()
    var n = len(b)
    var i = 0
    while i < n:
        if _is_ident_start(b[i]) and (i == 0 or not is_ascii_ident_byte(b[i - 1])):
            var e = i
            while e < n and is_ascii_ident_byte(b[e]):
                e += 1
            into[_word(b, i, e)] = True
            i = e
        else:
            i += 1


def added_rows(before: String, after: String) -> List[Bool]:
    """Per after-file row: did the change add it?"""
    var after_lines = split_lines_no_trailing(after)
    var out = List[Bool](length=len(after_lines), fill=False)
    var rows = build_diff_rows(split_lines_no_trailing(before), after_lines)
    for i in range(len(rows)):
        if rows[i].kind == DIFF_ROW_ADDED and 0 <= rows[i].after_row \
                and rows[i].after_row < len(out):
            out[rows[i].after_row] = True
    return out^


def new_names_in(
    paths: List[String], befores: List[String], afters: List[String],
) -> List[NewName]:
    """The distinct new names of a changeset given as parallel per-file
    ``paths`` / ``befores`` / ``afters``, in file then row order."""
    var known = Dict[String, Bool]()
    for i in range(len(befores)):
        identifier_set(befores[i], known)
    var out = List[NewName]()
    for f in range(len(paths)):
        var defs = find_definitions(
            paths[f], afters[f], added_rows(befores[f], afters[f]),
        )
        for k in range(len(defs)):
            if defs[k].name in known or defs[k].name == "_":
                continue
            known[defs[k].name] = True
            out.append(NewName(
                defs[k].name, defs[k].kind, defs[k].what, f, defs[k].row,
                defs[k].col,
            ))
    return out^
