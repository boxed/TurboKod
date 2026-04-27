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


@fieldwise_init
struct ProjectMatch(ImplicitlyCopyable, Movable):
    var path: String        # absolute path to the file
    var rel: String         # path relative to project root, for display
    var line_no: Int        # 1-based line number of the match
    var line_text: String


fn walk_project_files(root: String) -> List[String]:
    """Iterative DFS — return absolute paths of every regular file under
    ``root``. Skips dotfile entries and unreadable nodes."""
    var out = List[String]()
    var dirs = List[String]()
    dirs.append(root)
    while len(dirs) > 0:
        var dir = dirs.pop()
        var raw = list_directory(dir)
        for i in range(len(raw)):
            var name = raw[i]
            if name == String(".") or name == String(".."):
                continue
            var nbytes = name.as_bytes()
            if len(nbytes) > 0 and nbytes[0] == 0x2E:
                continue
            var full = join_path(dir, name)
            var info = stat_file(full)
            if not info.ok:
                continue
            if info.is_dir():
                dirs.append(full)
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


fn _split_lines(text: String) -> List[String]:
    var lines = List[String]()
    var bytes = text.as_bytes()
    var line_start = 0
    var i = 0
    while i < len(bytes):
        if bytes[i] == 0x0A:
            lines.append(String(StringSlice(
                unsafe_from_utf8=bytes[line_start:i]
            )))
            line_start = i + 1
        i += 1
    if line_start < len(bytes):
        lines.append(String(StringSlice(
            unsafe_from_utf8=bytes[line_start:]
        )))
    return lines^


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
        var lines = _split_lines(text)
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
