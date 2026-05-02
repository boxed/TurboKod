"""``git blame --porcelain`` driver: spawn git, parse the porcelain stream,
return one ``BlameLine`` per line of the source file.

Porcelain layout (one source line per record):

    <40-hex-sha> <orig-line> <final-line> [<group-len>]
    [author <Name>]
    [author-mail <addr>]
    [author-time <unix>]
    ... (committer, summary, previous, filename, etc.)
    \\t<source line content>

For lines after the first inside a group sharing the same SHA, only the
header + tab line are emitted (no metadata) — git assumes the consumer
remembers the per-commit metadata it already saw. We cache author per SHA
in a parallel ``commits`` / ``authors`` list so the second-and-later lines
of a group still get the right author.

The result list has one entry per *source* line (1-indexed in the input,
0-indexed in our list). ``compute_blame`` raises only on spawn failure;
git exit codes are ignored — a non-zero exit (e.g., ``--`` not in repo)
yields an empty parse and the caller silently no-ops.
"""

from std.collections.list import List
from std.collections.optional import Optional

from .file_io import find_git_project, parent_path
from .lsp import capture_command
from .posix import realpath


@fieldwise_init
struct BlameLine(ImplicitlyCopyable, Movable):
    """One source line's blame attribution. ``commit`` is the 8-char
    short SHA (or ``"0" * 8`` for not-yet-committed lines); ``author``
    is the commit author name (or ``"Not Committed Yet"``)."""
    var commit: String
    var author: String


fn _is_hex(b: Int) -> Bool:
    if 0x30 <= b and b <= 0x39: return True
    if 0x61 <= b and b <= 0x66: return True
    if 0x41 <= b and b <= 0x46: return True
    return False


fn _parse_int(s: String, start: Int, stop: Int) -> Int:
    """Parse a non-negative decimal substring; -1 on no digits."""
    var b = s.as_bytes()
    var i = start
    var n = 0
    var saw = False
    while i < stop and i < len(b):
        var c = Int(b[i])
        if c < 0x30 or c > 0x39:
            break
        n = n * 10 + (c - 0x30)
        saw = True
        i += 1
    if not saw:
        return -1
    return n


fn _split_porcelain_lines(text: String) -> List[String]:
    """Split on LF, keeping empty trailing line out. Porcelain output has
    no CR — git writes plain LF — so we don't need to strip CRs."""
    var out = List[String]()
    var b = text.as_bytes()
    var start = 0
    for i in range(len(b)):
        if b[i] == 0x0A:
            out.append(String(StringSlice(unsafe_from_utf8=b[start:i])))
            start = i + 1
    if start < len(b):
        out.append(String(StringSlice(unsafe_from_utf8=b[start:len(b)])))
    return out^


fn _starts_with(s: String, prefix: String) -> Bool:
    var sb = s.as_bytes()
    var pb = prefix.as_bytes()
    if len(pb) > len(sb):
        return False
    for i in range(len(pb)):
        if sb[i] != pb[i]:
            return False
    return True


fn _looks_like_header(line: String) -> Bool:
    """A header line begins with 40 hex digits + space."""
    var b = line.as_bytes()
    if len(b) < 41:
        return False
    for i in range(40):
        if not _is_hex(Int(b[i])):
            return False
    return b[40] == 0x20


fn parse_blame_porcelain(text: String) -> List[BlameLine]:
    """Walk porcelain lines, emit one ``BlameLine`` per source line.

    State machine:

    * Top: expect a header (``<sha> <orig> <final> [count]``). Parse
      SHA + final-line-num. Mark ``current_sha`` / ``current_final``;
      reset ``pending_author`` to whatever we cached for this sha
      (or empty if never seen).
    * Header consumed → read metadata lines (``key value``) until we
      hit the ``\\t<content>`` marker. ``author <name>`` updates
      ``pending_author``; everything else is ignored.
    * On ``\\t...`` marker: store ``BlameLine(short_sha, author)`` at
      index ``current_final - 1``, growing the list with empty entries
      if needed (one-based source lines aren't always contiguous in a
      single forward sweep, but git emits them in order).
    """
    var lines = _split_porcelain_lines(text)
    var commits = List[String]()       # parallel SHA cache
    var authors = List[String]()       # ↳ author for that SHA
    var out = List[BlameLine]()

    var current_sha = String("")
    var current_short = String("")
    var current_final = -1
    var pending_author = String("")
    var in_header = False

    for li in range(len(lines)):
        var ln = lines[li]
        var lb = ln.as_bytes()
        if in_header and len(lb) > 0 and lb[0] == 0x09:
            # ``\t<content>`` — flush a record for current_final.
            var au = pending_author
            if len(au.as_bytes()) == 0:
                au = String("Not Committed Yet")
            var rec = BlameLine(current_short, au)
            # Pad ``out`` so index = current_final - 1.
            while len(out) < current_final:
                out.append(BlameLine(String(""), String("")))
            if current_final >= 1:
                out[current_final - 1] = rec
            in_header = False
            continue
        if _looks_like_header(ln):
            current_sha = String(StringSlice(unsafe_from_utf8=lb[:40]))
            current_short = String(StringSlice(unsafe_from_utf8=lb[:8]))
            # Skip past sha + space, parse orig, then final.
            var space2 = 41
            while space2 < len(lb) and lb[space2] != 0x20:
                space2 += 1
            # space2 now at the space after orig.
            var fin_start = space2 + 1
            var fin_end = fin_start
            while fin_end < len(lb) and lb[fin_end] != 0x20:
                fin_end += 1
            current_final = _parse_int(ln, fin_start, fin_end)
            # Look up cached author for this sha; reset to empty if new.
            pending_author = String("")
            for i in range(len(commits)):
                if commits[i] == current_sha:
                    pending_author = authors[i]
                    break
            in_header = True
            continue
        if in_header and _starts_with(ln, String("author ")):
            var author = String(StringSlice(unsafe_from_utf8=lb[7:len(lb)]))
            pending_author = author
            # Cache against the SHA so subsequent same-commit lines pick
            # it up without re-reading metadata.
            var found = False
            for i in range(len(commits)):
                if commits[i] == current_sha:
                    authors[i] = author
                    found = True
                    break
            if not found:
                commits.append(current_sha)
                authors.append(author)
            continue
        # Other metadata (committer, summary, previous, filename, ...)
        # is intentionally ignored — we only display sha + author.
    return out^


fn compute_blame(file_path: String) raises -> List[BlameLine]:
    """Spawn ``git -C <repo> blame --porcelain -- <abs_path>`` and parse.

    ``file_path`` may be relative or absolute; we ``realpath`` it so git's
    cwd doesn't matter. Returns an empty list when the file isn't in a
    git repository, when git isn't installed, or when git exits non-zero
    for any reason — a missing blame is a soft failure, not a crash.
    """
    var abs_path = realpath(file_path)
    if len(abs_path.as_bytes()) == 0:
        abs_path = file_path
    var maybe_root = find_git_project(abs_path)
    if not maybe_root:
        return List[BlameLine]()
    var root = maybe_root.value()
    var argv = List[String]()
    argv.append(String("git"))
    argv.append(String("-C"))
    argv.append(root)
    argv.append(String("blame"))
    argv.append(String("--porcelain"))
    argv.append(String("--"))
    argv.append(abs_path)
    var result = capture_command(argv)
    return parse_blame_porcelain(result.stdout)
