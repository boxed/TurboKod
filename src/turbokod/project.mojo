"""Project-wide file walking, searching, and replacement.

Operates on the directory returned by ``find_git_project``; consumers don't
need to know whether it's a Git checkout or just a parent of ``.git``. We
skip dotfile entries (``.git``, ``.pixi``, etc.) and any file whose first 4 KB
contains a NUL byte (treated as binary).
"""

from std.collections.list import List

from .file_io import (
    join_path, list_directory, read_file, stat_file, write_file,
)
from .string_utils import split_lines_no_trailing


@fieldwise_init
struct ProjectMatch(ImplicitlyCopyable, Movable):
    var path: String        # absolute path to the file
    var rel: String         # path relative to project root, for display
    var line_no: Int        # 1-based line number of the match
    var line_text: String


# --- .gitignore matching ---------------------------------------------------


@fieldwise_init
struct GitignorePattern(ImplicitlyCopyable, Movable):
    """A single gitignore line broken into its semantic parts.

    ``glob`` carries the body of the pattern minus any leading ``!`` (kept as
    ``negate``), leading ``/`` (kept as ``anchored``), and trailing ``/``
    (kept as ``dir_only``). Glob characters supported: ``*`` (any non-slash
    run, including empty) and ``?`` (any single non-slash byte). Character
    classes (``[abc]``) and ``**`` aren't recognized — that's a deliberate
    practical subset, not the full git semantics.
    """
    var glob: String
    var dir_only: Bool
    var anchored: Bool
    var negate: Bool


struct GitignoreMatcher(ImplicitlyCopyable, Movable):
    """Compiled set of gitignore patterns from a single ``.gitignore`` file.

    Match order follows git: later patterns override earlier ones, and a
    leading ``!`` re-includes a path that an earlier pattern excluded.
    """
    var patterns: List[GitignorePattern]

    fn __init__(out self):
        self.patterns = List[GitignorePattern]()

    fn __copyinit__(out self, copy: Self):
        self.patterns = copy.patterns.copy()

    @staticmethod
    fn from_text(text: String) -> Self:
        var m = GitignoreMatcher()
        var lines = split_lines_no_trailing(text)
        for li in range(len(lines)):
            var line = _strip(lines[li])
            var lb = line.as_bytes()
            if len(lb) == 0:
                continue
            if lb[0] == 0x23:  # '#'
                continue
            var negate = False
            var start = 0
            if lb[0] == 0x21:  # '!'
                negate = True
                start = 1
            var anchored = False
            if start < len(lb) and lb[start] == 0x2F:  # '/'
                anchored = True
                start += 1
            var end = len(lb)
            var dir_only = False
            if end > start and lb[end - 1] == 0x2F:
                dir_only = True
                end -= 1
            if end <= start:
                continue
            var glob = String(StringSlice(unsafe_from_utf8=lb[start:end]))
            m.patterns.append(GitignorePattern(glob, dir_only, anchored, negate))
        return m^

    fn ignored(self, rel_path: String, is_dir: Bool) -> Bool:
        """Is ``rel_path`` (relative to the gitignore's directory) ignored?

        ``rel_path`` should use ``/`` separators and not start with ``/``.
        """
        var result = False
        for i in range(len(self.patterns)):
            var p = self.patterns[i]
            if p.dir_only and not is_dir:
                continue
            if _gitignore_path_match(p, rel_path):
                result = not p.negate
        return result


fn _strip(s: String) -> String:
    var b = s.as_bytes()
    var n = len(b)
    var i = 0
    while i < n and (b[i] == 0x20 or b[i] == 0x09 or b[i] == 0x0D):
        i += 1
    var j = n
    while j > i and (b[j - 1] == 0x20 or b[j - 1] == 0x09 or b[j - 1] == 0x0D):
        j -= 1
    if i == 0 and j == n:
        return s
    return String(StringSlice(unsafe_from_utf8=b[i:j]))


fn _split_path_components(path: String) -> List[String]:
    var out = List[String]()
    var b = path.as_bytes()
    var start = 0
    var i = 0
    while i < len(b):
        if b[i] == 0x2F:
            if i > start:
                out.append(String(StringSlice(unsafe_from_utf8=b[start:i])))
            start = i + 1
        i += 1
    if start < len(b):
        out.append(String(StringSlice(unsafe_from_utf8=b[start:])))
    return out^


fn _glob_match(pattern: String, text: String) -> Bool:
    return _glob_match_at(pattern, 0, text, 0)


fn _glob_match_at(pattern: String, pi: Int, text: String, ti: Int) -> Bool:
    var pb = pattern.as_bytes()
    var tb = text.as_bytes()
    var p = pi
    var t = ti
    while p < len(pb):
        var c = pb[p]
        if c == 0x2A:  # '*' — any (possibly empty) run of non-slash bytes.
            while p < len(pb) and pb[p] == 0x2A:
                p += 1
            if p >= len(pb):
                while t < len(tb):
                    if tb[t] == 0x2F:
                        return False
                    t += 1
                return True
            while t <= len(tb):
                if _glob_match_at(pattern, p, text, t):
                    return True
                if t == len(tb):
                    return False
                if tb[t] == 0x2F:
                    return False
                t += 1
            return False
        if c == 0x3F:  # '?'
            if t >= len(tb) or tb[t] == 0x2F:
                return False
            p += 1
            t += 1
            continue
        if t >= len(tb) or tb[t] != c:
            return False
        p += 1
        t += 1
    return t == len(tb)


fn _has_byte(s: String, b: UInt8) -> Bool:
    var bs = s.as_bytes()
    for i in range(len(bs)):
        if bs[i] == b:
            return True
    return False


fn _gitignore_path_match(p: GitignorePattern, rel: String) -> Bool:
    if p.anchored:
        return _glob_match(p.glob, rel)
    var glob_has_slash = _has_byte(p.glob, 0x2F)
    if not glob_has_slash:
        # Match any single path component.
        var comps = _split_path_components(rel)
        for i in range(len(comps)):
            if _glob_match(p.glob, comps[i]):
                return True
        return False
    # Pattern with internal slash, not anchored: match any suffix that
    # starts at a path-component boundary.
    var comps2 = _split_path_components(rel)
    for s in range(len(comps2)):
        var suffix = comps2[s]
        for j in range(s + 1, len(comps2)):
            suffix = suffix + String("/") + comps2[j]
        if _glob_match(p.glob, suffix):
            return True
    return False


fn _maybe_load_gitignore(root: String) -> GitignoreMatcher:
    var path = join_path(root, String(".gitignore"))
    var info = stat_file(path)
    if not info.ok:
        return GitignoreMatcher()
    var text: String
    try:
        text = read_file(path)
    except:
        return GitignoreMatcher()
    return GitignoreMatcher.from_text(text)


fn walk_project_files(
    root: String, respect_gitignore: Bool = True,
) -> List[String]:
    """Iterative DFS — absolute paths of every regular file under ``root``.

    Always skips dotfile entries (so ``.git``, ``.pixi``, ``.gitignore``
    itself, etc. never enter the result). With ``respect_gitignore=True``
    (the default) the project's ``.gitignore`` is parsed and any path that
    matches is excluded; an ignored *directory* skips its entire subtree.
    """
    var matcher = _maybe_load_gitignore(root) if respect_gitignore \
        else GitignoreMatcher()
    var out = List[String]()
    var rel_dirs = List[String]()
    rel_dirs.append(String(""))
    while len(rel_dirs) > 0:
        var rel_dir = rel_dirs.pop()
        var dir = root if len(rel_dir.as_bytes()) == 0 \
            else join_path(root, rel_dir)
        var raw = list_directory(dir)
        for i in range(len(raw)):
            var name = raw[i]
            if name == String(".") or name == String(".."):
                continue
            var nbytes = name.as_bytes()
            if len(nbytes) > 0 and nbytes[0] == 0x2E:
                continue
            var rel = name if len(rel_dir.as_bytes()) == 0 \
                else join_path(rel_dir, name)
            var full = join_path(root, rel)
            var info = stat_file(full)
            if not info.ok:
                continue
            if matcher.ignored(rel, info.is_dir()):
                continue
            if info.is_dir():
                rel_dirs.append(rel)
            else:
                out.append(full)
    return out^


fn _looks_binary(text: String) -> Bool:
    var bytes = text.as_bytes()
    var n = len(bytes)
    if n > 4096:
        n = 4096
    for i in range(n):
        if bytes[i] == 0:
            return True
    return False


fn _project_relative(root: String, full: String) -> String:
    var rb = root.as_bytes()
    var fb = full.as_bytes()
    if len(fb) <= len(rb) + 1:
        return full
    for k in range(len(rb)):
        if fb[k] != rb[k]:
            return full
    if fb[len(rb)] != 0x2F:
        return full
    return String(StringSlice(unsafe_from_utf8=fb[len(rb) + 1:]))


fn _replace_all_in_string(
    haystack: String, needle: String, replacement: String,
) -> String:
    var hb = haystack.as_bytes()
    var nb = needle.as_bytes()
    var n = len(nb)
    var h = len(hb)
    if n == 0 or n > h:
        return haystack
    var out = String("")
    var i = 0
    var seg_start = 0
    while i + n <= h:
        var hit = True
        for k in range(n):
            if hb[i + k] != nb[k]:
                hit = False
                break
        if hit:
            if i > seg_start:
                out = out + String(StringSlice(
                    unsafe_from_utf8=hb[seg_start:i]
                ))
            out = out + replacement
            i += n
            seg_start = i
        else:
            i += 1
    if seg_start < h:
        out = out + String(StringSlice(unsafe_from_utf8=hb[seg_start:h]))
    return out


fn _contains_bytes(line: String, needle: String) -> Bool:
    var lb = line.as_bytes()
    var nb = needle.as_bytes()
    var n = len(nb)
    var h = len(lb)
    if n == 0:
        return True
    if n > h:
        return False
    for i in range(h - n + 1):
        var hit = True
        for k in range(n):
            if lb[i + k] != nb[k]:
                hit = False
                break
        if hit:
            return True
    return False


fn find_in_project(root: String, needle: String) raises -> List[ProjectMatch]:
    """Return every line in every project file that contains ``needle``."""
    var out = List[ProjectMatch]()
    if len(needle.as_bytes()) == 0:
        return out^
    var paths = walk_project_files(root)
    for p in range(len(paths)):
        var full = paths[p]
        var text: String
        try:
            text = read_file(full)
        except:
            continue
        if _looks_binary(text):
            continue
        var lines = split_lines_no_trailing(text)
        var rel = _project_relative(root, full)
        for ln in range(len(lines)):
            if _contains_bytes(lines[ln], needle):
                out.append(ProjectMatch(full, rel, ln + 1, lines[ln]))
    return out^


fn replace_in_project(
    root: String, needle: String, replacement: String,
) raises -> Tuple[Int, Int]:
    """Replace ``needle`` with ``replacement`` across all project files.

    Returns ``(files_changed, total_replacements)``. Files that look binary
    or where the write fails are silently skipped.
    """
    var files_changed = 0
    var total = 0
    var nbytes = needle.as_bytes()
    var n = len(nbytes)
    if n == 0:
        return (0, 0)
    var paths = walk_project_files(root)
    for p in range(len(paths)):
        var full = paths[p]
        var text: String
        try:
            text = read_file(full)
        except:
            continue
        if _looks_binary(text):
            continue
        var hb = text.as_bytes()
        var h = len(hb)
        if h < n:
            continue
        var count = 0
        var i = 0
        while i + n <= h:
            var hit = True
            for k in range(n):
                if hb[i + k] != nbytes[k]:
                    hit = False
                    break
            if hit:
                count += 1
                i += n
            else:
                i += 1
        if count == 0:
            continue
        var new_text = _replace_all_in_string(text, needle, replacement)
        if write_file(full, new_text):
            files_changed += 1
            total += count
    return (files_changed, total)
