"""What the ``rg`` searches share: Find in Project and the Find Symbol
fallback run the same command line and read the same rows, so a flag one
of them needs (``--hidden`` once went missing from one) is the other's
too."""

from std.collections.list import List
from std.collections.optional import Optional

from .string_utils import parse_uint_range


def rg_base_argv() -> List[String]:
    """``rg`` with the flags every search here wants; the caller adds its
    own (case, globs, ``-e`` / ``--``, the pattern and the root)."""
    var argv = List[String]()
    argv.append(String("rg"))
    argv.append(String("--no-heading"))
    argv.append(String("--line-number"))
    argv.append(String("--column"))
    argv.append(String("--color=never"))
    # The path ends in a NUL rather than a ``:``, which a file name can
    # hold (``meeting: notes.md``).
    argv.append(String("--null"))
    # Search dot-prefixed files and directories. rg skips them by
    # default, which silently hid every hit under ``.github/``,
    # ``.gitlab-ci.yml``, ``.env``, ``.claude/`` and the rest of a
    # project's dot tree. ``walk_project_files`` (the non-rg walker, the
    # file picker and the symbol index built on it) has always included
    # dotfiles, so without this the surfaces disagreed about what "the
    # project" is.
    #
    # ``.git`` itself is the one exclusion: ``--hidden`` does descend
    # into it, and its packfiles, refs and COMMIT_EDITMSG are never what
    # a search is after. Negated globs beat include globs in rg's
    # override matcher regardless of order, so a caller's ``-g``
    # patterns can't accidentally re-admit it.
    argv.append(String("--hidden"))
    argv.append(String("-g"))
    argv.append(String("!.git/"))
    # Cap how much rg emits per matched line. Without this, a hit in a
    # minified JS / CSS bundle would push a multi-MB line into our pipe,
    # buffered whole before its ``\n`` turns up. The preview keeps the
    # matched substring visible, just truncated.
    argv.append(String("--max-columns"))
    argv.append(String("1024"))
    argv.append(String("--max-columns-preview"))
    return argv^


def parse_rg_row(line: String) -> Optional[Tuple[String, Int, Int, String]]:
    """Decode one ``rg_base_argv`` output row (``path\\0line:col:text``)
    into ``(path, line, column, text)``. ``None`` for any row that isn't a
    path, a NUL and ``digits:digits:`` (rg sometimes emits other
    informational lines)."""
    var b = line.as_bytes()
    if len(b) == 0:
        return None
    var i = 0
    while i < len(b) and b[i] != 0x00:
        i += 1
    var j = i + 1
    while j < len(b) and Int(b[j]) >= 0x30 and Int(b[j]) <= 0x39:
        j += 1
    if j == i + 1 or j >= len(b) or b[j] != 0x3A:
        return None
    var k = j + 1
    while k < len(b) and Int(b[k]) >= 0x30 and Int(b[k]) <= 0x39:
        k += 1
    if k == j + 1 or k >= len(b) or b[k] != 0x3A:
        return None
    var line_no = parse_uint_range(b, i + 1, j)
    var col_no = parse_uint_range(b, j + 1, k)
    if line_no <= 0 or col_no <= 0:
        return None
    var path = String(StringSpan(unsafe_from_utf8=b[0:i]))
    var text = String(StringSpan(unsafe_from_utf8=b[k + 1:len(b)]))
    return (path^, line_no, col_no, text^)
