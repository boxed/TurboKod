"""editorconfig support — see https://editorconfig.org/.

Walks up the filesystem from a file path, reading any ``.editorconfig`` files
along the way. Stops at the first one that declares ``root = true`` (or at
``/``). Closer files override more distant ones; within a single file, later
sections override earlier ones — same precedence rules as the reference
implementation.

Supported properties:

* ``indent_style``               ``tab`` | ``space``
* ``indent_size``                positive int (or ``tab`` → defer to tab_width)
* ``tab_width``                  positive int
* ``end_of_line``                ``lf`` | ``cr`` | ``crlf``
* ``charset``                    informational
* ``trim_trailing_whitespace``   ``true`` | ``false``
* ``insert_final_newline``       ``true`` | ``false``
* ``max_line_length``            positive int (informational)

Supported glob syntax: ``*``, ``**``, ``?``, ``[abc]``/``[!abc]``/``[a-z]``,
``{a,b,c}`` alternation. Numeric ranges (``{1..5}``) are not implemented —
they show up rarely and the spec marks them optional.
"""

from std.collections.list import List

from .file_io import join_path, parent_path, read_file, stat_file
from .posix import realpath


# --- helpers ---------------------------------------------------------------


fn _slice(s: String, start: Int, end: Int) -> String:
    var bytes = s.as_bytes()
    var s_start = start
    var s_end = end
    if s_start < 0: s_start = 0
    if s_end > len(bytes): s_end = len(bytes)
    if s_start >= s_end: return String("")
    return String(StringSlice(unsafe_from_utf8=bytes[s_start:s_end]))


fn _to_lower(s: String) -> String:
    var bytes = s.as_bytes()
    var out = List[UInt8]()
    for i in range(len(bytes)):
        var b = Int(bytes[i])
        if 0x41 <= b and b <= 0x5A:
            out.append(UInt8(b + 32))
        else:
            out.append(bytes[i])
    return String(StringSlice(ptr=out.unsafe_ptr(), length=len(out)))


fn _strip(s: String) -> String:
    var bytes = s.as_bytes()
    var n = len(bytes)
    var i = 0
    while i < n and (bytes[i] == 0x20 or bytes[i] == 0x09):
        i += 1
    var j = n
    while j > i and (bytes[j - 1] == 0x20 or bytes[j - 1] == 0x09):
        j -= 1
    return _slice(s, i, j)


fn _starts_with(s: String, prefix: String) -> Bool:
    var sb = s.as_bytes()
    var pb = prefix.as_bytes()
    if len(sb) < len(pb): return False
    for i in range(len(pb)):
        if sb[i] != pb[i]: return False
    return True


fn _ends_with_byte(s: String, b: UInt8) -> Bool:
    var sb = s.as_bytes()
    return len(sb) > 0 and sb[len(sb) - 1] == b


fn _parse_int(s: String) -> Int:
    """Returns the parsed positive int, or -1 on failure."""
    var bytes = s.as_bytes()
    if len(bytes) == 0:
        return -1
    var n = 0
    for i in range(len(bytes)):
        var b = Int(bytes[i])
        if b < 0x30 or b > 0x39:
            return -1
        n = n * 10 + (b - 0x30)
    return n


fn _parse_bool(s: String) -> Int:
    """Returns 1 for ``true``, 0 for ``false``, ``-1`` for anything else."""
    var lower = _to_lower(s)
    if lower == String("true"):
        return 1
    if lower == String("false"):
        return 0
    return -1


# --- EditorConfig ----------------------------------------------------------


struct EditorConfig(ImplicitlyCopyable, Movable):
    """Resolved editorconfig settings for a single file.

    Numeric / bool fields use ``-1`` as a sentinel for "unset" so the editor
    can distinguish "explicitly false" from "no preference" — important for
    ``insert_final_newline``, where the spec treats absence and ``false``
    differently (false: ensure there is *no* trailing newline; absent: leave
    whatever's already there).
    """
    var indent_style: String
    var indent_size: Int           # -1 = unset
    var tab_width: Int             # -1 = unset
    var end_of_line: String        # "lf" | "cr" | "crlf" | ""
    var charset: String
    var trim_trailing_whitespace: Int   # -1 unset, 0 false, 1 true
    var insert_final_newline: Int       # -1 unset, 0 false, 1 true
    var max_line_length: Int       # -1 = unset

    fn __init__(out self):
        self.indent_style = String("")
        self.indent_size = -1
        self.tab_width = -1
        self.end_of_line = String("")
        self.charset = String("")
        self.trim_trailing_whitespace = -1
        self.insert_final_newline = -1
        self.max_line_length = -1

    fn __copyinit__(out self, copy: Self):
        self.indent_style = copy.indent_style
        self.indent_size = copy.indent_size
        self.tab_width = copy.tab_width
        self.end_of_line = copy.end_of_line
        self.charset = copy.charset
        self.trim_trailing_whitespace = copy.trim_trailing_whitespace
        self.insert_final_newline = copy.insert_final_newline
        self.max_line_length = copy.max_line_length

    fn effective_indent_size(self) -> Int:
        """Width of one indentation level in spaces.

        Per the spec: if ``indent_size`` is unset and ``indent_style`` is
        ``tab``, fall back to ``tab_width``. If both are unset we default
        to 4, matching the editor's pre-editorconfig behavior.
        """
        if self.indent_size > 0:
            return self.indent_size
        if self.indent_style == String("tab") and self.tab_width > 0:
            return self.tab_width
        return 4

    fn indent_string(self) -> String:
        """Bytes to insert when the user presses Tab."""
        if self.indent_style == String("tab"):
            return String("\t")
        var n = self.effective_indent_size()
        if n < 1:
            n = 1
        var out = String("")
        for _ in range(n):
            out = out + String(" ")
        return out

    fn line_separator(self) -> String:
        """Byte sequence to use between lines on disk. ``\\n`` by default."""
        if self.end_of_line == String("crlf"):
            return String("\r\n")
        if self.end_of_line == String("cr"):
            return String("\r")
        return String("\n")

    fn _set(mut self, key: String, value: String):
        """Apply one ``key = value`` pair. Unknown keys are ignored."""
        var k = _to_lower(_strip(key))
        var v = _strip(value)
        var vl = _to_lower(v)
        if k == String("indent_style"):
            if vl == String("tab") or vl == String("space"):
                self.indent_style = vl
        elif k == String("indent_size"):
            if vl == String("tab"):
                # Special: indent_size=tab means "use tab_width". We leave
                # indent_size unset so effective_indent_size falls back.
                self.indent_size = -1
            else:
                var n = _parse_int(vl)
                if n > 0:
                    self.indent_size = n
        elif k == String("tab_width"):
            var n = _parse_int(vl)
            if n > 0:
                self.tab_width = n
        elif k == String("end_of_line"):
            if vl == String("lf") or vl == String("cr") \
                    or vl == String("crlf"):
                self.end_of_line = vl
        elif k == String("charset"):
            self.charset = vl
        elif k == String("trim_trailing_whitespace"):
            var b = _parse_bool(vl)
            if b >= 0:
                self.trim_trailing_whitespace = b
        elif k == String("insert_final_newline"):
            var b = _parse_bool(vl)
            if b >= 0:
                self.insert_final_newline = b
        elif k == String("max_line_length"):
            var n = _parse_int(vl)
            if n > 0:
                self.max_line_length = n


# --- INI-ish parsing -------------------------------------------------------


struct EditorConfigSection(ImplicitlyCopyable, Movable):
    """One ``[pattern]`` block from a ``.editorconfig`` file."""
    var pattern: String
    # Parallel lists keep this trivially Movable / Copyable without needing
    # a tuple-with-strings element type.
    var keys: List[String]
    var values: List[String]

    fn __init__(out self, var pattern: String):
        self.pattern = pattern^
        self.keys = List[String]()
        self.values = List[String]()

    fn __copyinit__(out self, copy: Self):
        self.pattern = copy.pattern
        self.keys = copy.keys.copy()
        self.values = copy.values.copy()


struct EditorConfigFile(ImplicitlyCopyable, Movable):
    """A parsed ``.editorconfig`` file with its source directory."""
    var dir: String
    var is_root: Bool
    var sections: List[EditorConfigSection]

    fn __init__(out self, var dir: String):
        self.dir = dir^
        self.is_root = False
        self.sections = List[EditorConfigSection]()

    fn __copyinit__(out self, copy: Self):
        self.dir = copy.dir
        self.is_root = copy.is_root
        self.sections = copy.sections.copy()


fn parse_editorconfig(dir: String, contents: String) -> EditorConfigFile:
    """Parse ``contents`` (the bytes of one ``.editorconfig`` file) into a
    structured form. ``dir`` is the directory the file lives in — needed
    later by the matcher to compute paths relative to it.

    The format is INI-ish: ``# / ;`` start comments, ``[pattern]`` opens a
    section, lines outside any section are global properties (only
    ``root = true`` is meaningful in the global block). Unknown keys and
    malformed lines are silently dropped — same behavior as the reference
    implementation, since editors are expected to be lenient about hand-
    edited config files.

    Sections are accumulated in three parallel locals (pattern + key list
    + value list) and committed to ``file.sections`` only at section
    boundaries (and at end of file). Building each section as a complete
    value before pushing avoids in-place mutation of list elements,
    which has fragile semantics in Mojo.
    """
    var file = EditorConfigFile(dir)
    var bytes = contents.as_bytes()
    var n = len(bytes)
    var i = 0
    var has_section = False
    var current_pat = String("")
    var current_keys = List[String]()
    var current_values = List[String]()
    while i < n:
        # Find end of line.
        var j = i
        while j < n and bytes[j] != 0x0A:
            j += 1
        var line_end = j
        # Strip trailing \r.
        if line_end > i and bytes[line_end - 1] == 0x0D:
            line_end -= 1
        var raw = _slice(contents, i, line_end)
        var line = _strip(raw)
        var lb = line.as_bytes()
        i = j + 1   # advance past the \n
        if len(lb) == 0:
            continue
        if lb[0] == 0x23 or lb[0] == 0x3B:    # '#' or ';'
            continue
        if lb[0] == 0x5B:    # '['
            # Find closing ']'.
            var k = len(lb) - 1
            while k > 0 and lb[k] != 0x5D:
                k -= 1
            if k <= 0:
                continue
            # Flush the previous section before starting a new one.
            if has_section:
                var prev = EditorConfigSection(current_pat^)
                prev.keys = current_keys^
                prev.values = current_values^
                file.sections.append(prev^)
                current_keys = List[String]()
                current_values = List[String]()
            current_pat = _slice(line, 1, k)
            has_section = True
            continue
        # key = value
        var eq = -1
        for k in range(len(lb)):
            if lb[k] == 0x3D:
                eq = k
                break
        if eq < 0:
            continue
        var key = _strip(_slice(line, 0, eq))
        var value = _strip(_slice(line, eq + 1, len(lb)))
        if not has_section:
            # Global block — only ``root`` is meaningful.
            if _to_lower(key) == String("root") \
                    and _to_lower(value) == String("true"):
                file.is_root = True
            continue
        current_keys.append(key^)
        current_values.append(value^)
    # Flush the final section, if any.
    if has_section:
        var last = EditorConfigSection(current_pat^)
        last.keys = current_keys^
        last.values = current_values^
        file.sections.append(last^)
    return file^


# --- glob matching ---------------------------------------------------------


fn _bytes_slice_to_string(
    bytes: List[UInt8], start: Int, end: Int,
) -> String:
    """Copy ``bytes[start:end]`` into a fresh ``String``.

    Constructed via ``ptr + length`` rather than the ``[a:b]`` slice
    form because ``List[UInt8]`` slicing semantics (does it return a
    Span or a List, in this Mojo version?) are version-sensitive in a
    way that the ``ptr/length`` form isn't — it's the same idiom
    ``editor.mojo`` uses for building a String from a freshly built
    ``List[UInt8]``.
    """
    if start >= end:
        return String("")
    var tmp = List[UInt8]()
    for i in range(start, end):
        tmp.append(bytes[i])
    return String(StringSlice(ptr=tmp.unsafe_ptr(), length=len(tmp)))


fn _split_alts(bytes: List[UInt8], start: Int, end: Int) -> List[String]:
    """Split the body of a ``{a,b,c}`` block on top-level commas."""
    var alts = List[String]()
    var depth = 0
    var seg_start = start
    var i = start
    while i < end:
        if bytes[i] == 0x7B:
            depth += 1
        elif bytes[i] == 0x7D:
            depth -= 1
        elif bytes[i] == 0x2C and depth == 0:
            alts.append(_bytes_slice_to_string(bytes, seg_start, i))
            seg_start = i + 1
        i += 1
    alts.append(_bytes_slice_to_string(bytes, seg_start, end))
    return alts^


fn _expand_alternations(pat: String) -> List[String]:
    """Expand ``{a,b,c}`` alternations into one pattern per alternative.

    Recurses so nested alternations like ``{x,{y,z}}`` flatten correctly.
    Output is a list of patterns containing only ``*``, ``**``, ``?`` and
    ``[...]`` — no more ``{}``.
    """
    var bytes = List[UInt8]()
    var pb = pat.as_bytes()
    for x in range(len(pb)):
        bytes.append(pb[x])
    var i = 0
    while i < len(bytes):
        if bytes[i] == 0x7B:    # '{'
            var depth = 1
            var end = i + 1
            while end < len(bytes) and depth > 0:
                if bytes[end] == 0x7B:
                    depth += 1
                elif bytes[end] == 0x7D:
                    depth -= 1
                    if depth == 0:
                        break
                end += 1
            if end >= len(bytes):
                break    # unclosed brace; treat the rest as literal
            var alts = _split_alts(bytes, i + 1, end)
            var prefix = _slice(pat, 0, i)
            var suffix = _slice(pat, end + 1, len(bytes))
            var out = List[String]()
            for k in range(len(alts)):
                var combined = prefix + alts[k] + suffix
                var sub = _expand_alternations(combined)
                for jj in range(len(sub)):
                    out.append(sub[jj])
            return out^
        i += 1
    var single = List[String]()
    single.append(pat)
    return single^


fn _gm(
    pat: List[UInt8], pi: Int, path: List[UInt8], ti: Int,
) -> Bool:
    """Recursive glob matcher (no alternation — that's expanded upstream)."""
    var pn = len(pat)
    var tn = len(path)
    if pi == pn:
        return ti == tn
    var c = pat[pi]
    if c == 0x2A:    # '*'
        if pi + 1 < pn and pat[pi + 1] == 0x2A:
            # ``**`` matches anything (including ``/``). A following ``/``
            # is allowed to consume zero directories — i.e. ``**/foo``
            # matches ``foo`` at the top.
            var rest = pi + 2
            if rest < pn and pat[rest] == 0x2F:
                if _gm(pat, rest + 1, path, ti):
                    return True
            for j in range(ti, tn + 1):
                if _gm(pat, rest, path, j):
                    return True
            return False
        else:
            # ``*`` matches anything except ``/``.
            var j = ti
            while True:
                if _gm(pat, pi + 1, path, j):
                    return True
                if j >= tn:
                    return False
                if path[j] == 0x2F:
                    return False
                j += 1
    elif c == 0x3F:    # '?'
        if ti >= tn or path[ti] == 0x2F:
            return False
        return _gm(pat, pi + 1, path, ti + 1)
    elif c == 0x5B:    # '['
        var k = pi + 1
        var negated = False
        if k < pn and pat[k] == 0x21:    # '!'
            negated = True
            k += 1
        var cls_start = k
        while k < pn and pat[k] != 0x5D:    # ']'
            k += 1
        if k >= pn:
            # malformed — fall through to literal match of '['
            if ti >= tn or path[ti] != c:
                return False
            return _gm(pat, pi + 1, path, ti + 1)
        if ti >= tn or path[ti] == 0x2F:
            return False
        var ch = path[ti]
        var matched = False
        var m = cls_start
        while m < k:
            if m + 2 < k and pat[m + 1] == 0x2D:    # 'a-z'
                if pat[m] <= ch and ch <= pat[m + 2]:
                    matched = True
                m += 3
            else:
                if pat[m] == ch:
                    matched = True
                m += 1
        if matched == negated:
            return False
        return _gm(pat, k + 1, path, ti + 1)
    else:
        if ti >= tn or path[ti] != c:
            return False
        return _gm(pat, pi + 1, path, ti + 1)


fn _glob_match_one(pat: String, path: String) -> Bool:
    """Match a single (alternation-expanded) glob against ``path``."""
    var pb = List[UInt8]()
    var pat_bytes = pat.as_bytes()
    for i in range(len(pat_bytes)):
        pb.append(pat_bytes[i])
    var tb = List[UInt8]()
    var path_bytes = path.as_bytes()
    for i in range(len(path_bytes)):
        tb.append(path_bytes[i])
    return _gm(pb, 0, tb, 0)


fn _pattern_has_internal_slash(pat: String) -> Bool:
    """A path separator anywhere except a single trailing slash. Trailing
    slashes are stripped by the caller, so this stays simple."""
    var bytes = pat.as_bytes()
    for i in range(len(bytes)):
        if bytes[i] == 0x2F:
            return True
    return False


fn match_section(pattern: String, rel_path: String) -> Bool:
    """Return True iff ``rel_path`` matches ``pattern`` per editorconfig rules.

    ``rel_path`` is the path of the file relative to the ``.editorconfig``
    file's directory, with forward-slash separators and no leading ``/``.

    Patterns without an internal ``/`` match the file's basename at any
    depth (per the spec — ``*.py`` matches ``foo.py`` and ``a/b/foo.py``).
    Patterns with an internal ``/`` are anchored to ``rel_path`` from the
    start. A leading ``/`` on the pattern is consumed as an explicit
    anchor.
    """
    var pat = pattern
    # Trailing slash isn't significant for matching files; drop it.
    if _ends_with_byte(pat, 0x2F):
        pat = _slice(pat, 0, len(pat.as_bytes()) - 1)
    var has_slash: Bool
    if _starts_with(pat, String("/")):
        pat = _slice(pat, 1, len(pat.as_bytes()))
        has_slash = True
    else:
        has_slash = _pattern_has_internal_slash(pat)
    if not has_slash:
        pat = String("**/") + pat
    var alts = _expand_alternations(pat)
    for i in range(len(alts)):
        if _glob_match_one(alts[i], rel_path):
            return True
    return False


# --- filesystem walk -------------------------------------------------------


fn _abs_dir(file_path: String) -> String:
    """Realpath of the directory containing ``file_path`` (or the file
    itself if it's a directory). Falls back to lexical resolution when the
    path doesn't exist on disk yet — supports Save As to a new file."""
    var info = stat_file(file_path)
    var dir: String
    if info.ok and info.is_dir():
        dir = file_path
    else:
        dir = parent_path(file_path)
    var rp = realpath(dir)
    if len(rp.as_bytes()) > 0:
        return rp
    return dir


fn _abs_file(file_path: String) -> String:
    """Best-effort absolute path of ``file_path`` even when it doesn't exist."""
    var rp = realpath(file_path)
    if len(rp.as_bytes()) > 0:
        return rp
    var parent = parent_path(file_path)
    var parent_abs = realpath(parent)
    if len(parent_abs.as_bytes()) > 0:
        # basename(): inline a simple last-segment extraction so we don't
        # need to widen file_io's surface here.
        var bytes = file_path.as_bytes()
        var n = len(bytes)
        var i = n - 1
        while i >= 0 and bytes[i] != 0x2F:
            i -= 1
        var name = _slice(file_path, i + 1, n)
        return join_path(parent_abs, name)
    return file_path


fn _relative_path(abs_file: String, ec_dir: String) -> String:
    var prefix = ec_dir
    if not _ends_with_byte(prefix, 0x2F):
        prefix = prefix + String("/")
    if not _starts_with(abs_file, prefix):
        return abs_file
    return _slice(abs_file, len(prefix.as_bytes()),
                  len(abs_file.as_bytes()))


fn load_editorconfig_for_path(file_path: String) -> EditorConfig:
    """Compute the resolved ``EditorConfig`` for ``file_path``.

    Walks up the filesystem from the file's directory, collecting any
    ``.editorconfig`` files; stops at the first one declaring ``root =
    true`` (or at ``/``). Files closer to ``file_path`` win — we apply
    them last so their settings overwrite anything set further up. An
    empty ``EditorConfig`` is returned when no ``.editorconfig`` files
    are found anywhere up the tree (so the caller's defaults apply).
    """
    var resolved = EditorConfig()
    if len(file_path.as_bytes()) == 0:
        return resolved^
    var abs_file = _abs_file(file_path)
    var dir = _abs_dir(file_path)
    var collected = List[EditorConfigFile]()
    while True:
        var ec_path = join_path(dir, String(".editorconfig"))
        var info = stat_file(ec_path)
        if info.ok and not info.is_dir():
            var contents: String
            try:
                contents = read_file(ec_path)
            except:
                contents = String("")
            var parsed = parse_editorconfig(dir, contents)
            var stop = parsed.is_root
            collected.append(parsed^)
            if stop:
                break
        var parent = parent_path(dir)
        if parent == dir:
            break
        dir = parent
    # Apply furthest-from-file first, closest last (so closer wins).
    var i = len(collected) - 1
    while i >= 0:
        var f = collected[i]
        var rel = _relative_path(abs_file, f.dir)
        for s in range(len(f.sections)):
            var sec = f.sections[s]
            if not match_section(sec.pattern, rel):
                continue
            for kv in range(len(sec.keys)):
                resolved._set(sec.keys[kv], sec.values[kv])
        i -= 1
    return resolved^
