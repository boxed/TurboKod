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
remembers the per-commit metadata it already saw. We cache the whole
metadata record per SHA in a parallel ``commits`` / ``metas`` list so the
second-and-later lines of a group still get the right attribution.

The result list has one entry per *source* line (1-indexed in the input,
0-indexed in our list). ``compute_blame`` raises only on spawn failure;
git exit codes are ignored — a non-zero exit (e.g., ``--`` not in repo)
yields an empty parse and the caller silently no-ops.
"""

from std.collections.dict import Dict
from std.collections.list import List
from std.collections.optional import Optional

from .file_io import find_git_project
from .git_changes import fetch_commit_message, git_base_argv
from .lsp import capture_command
from .posix import realpath
from .string_utils import (
    byte_slice, parse_int_all, parse_int_prefix, split_lines_no_trailing,
    hex_digit_value, starts_with,
)


comptime _ZERO_SHA = String("0000000000000000000000000000000000000000")


@fieldwise_init
struct BlameLine(ImplicitlyCopyable, Movable):
    """One source line's blame attribution.

    ``commit`` is the 8-char short SHA (or ``"0" * 8`` for not-yet-committed
    lines) and ``author`` the commit author name (or ``"Not Committed Yet"``)
    — those two are what the gutter paints. The rest is what the click-through
    popup shows: the full ``sha`` (also what a follow-up ``git show`` needs),
    ``author_mail`` as git emits it (angle brackets included), the author
    timestamp as unix seconds plus its ``+HHMM`` zone, and ``summary`` — the
    subject line of the commit message.
    """
    var commit: String
    var author: String
    var sha: String
    var author_mail: String
    var author_time: Int
    var author_tz: String
    var summary: String

    def __init__(out self):
        """Empty record — used to pad gaps in the per-source-line list."""
        self.commit = String("")
        self.author = String("")
        self.sha = String("")
        self.author_mail = String("")
        self.author_time = 0
        self.author_tz = String("")
        self.summary = String("")

    def is_uncommitted(self) -> Bool:
        """True for the all-zero SHA git uses for worktree-only lines.
        There is no object to ask git about, so the popup shows the
        placeholder rather than spawning a doomed ``git show``."""
        return self.sha == _ZERO_SHA


struct BlameTable(Copyable, Movable, Sized):
    """A file's blame, a line at a time, stored as one record per distinct
    commit and an index per line. A ``BlameLine`` is 152 bytes of string
    headers, and a file has a few hundred commits behind its thousands of
    lines: a list of them was 2.9 MB for a 19k-line file, kept for as long
    as the file stayed open.

    Reads like the list it replaces: ``len``, and ``table[row]`` gives the
    row's ``BlameLine``."""
    var commits: List[BlameLine]
    var line_commit: List[Int32]

    def __init__(out self):
        self.commits = List[BlameLine]()
        self.line_commit = List[Int32]()

    @staticmethod
    def from_lines(lines: List[BlameLine]) -> Self:
        var out = Self()
        out.line_commit = List[Int32](capacity=len(lines))
        var seen = Dict[String, Int]()
        var prev = -1
        for i in range(len(lines)):
            if prev >= 0 and _same_blame(lines[i], out.commits[prev]):
                # Blame comes in runs of lines from one commit.
                out.line_commit.append(Int32(prev))
                continue
            var key = _blame_key(lines[i])
            var at = seen.get(key, -1)
            if at < 0:
                at = len(out.commits)
                out.commits.append(lines[i])
                seen[key] = at
            out.line_commit.append(Int32(at))
            prev = at
        return out^

    def __len__(self) -> Int:
        return len(self.line_commit)

    def __getitem__(self, row: Int) -> BlameLine:
        return self.commits[Int(self.line_commit[row])]


def _same_blame(a: BlameLine, b: BlameLine) -> Bool:
    return a.sha == b.sha and a.commit == b.commit and a.author == b.author \
        and a.author_mail == b.author_mail and a.author_time == b.author_time \
        and a.author_tz == b.author_tz and a.summary == b.summary


def _blame_key(bl: BlameLine) -> String:
    """Every field, NUL-separated: two lines share a record only when all
    of it is the same."""
    var sep = String("\0")
    return bl.sha + sep + bl.commit + sep + bl.author + sep \
        + bl.author_mail + sep + String(bl.author_time) + sep \
        + bl.author_tz + sep + bl.summary


def _pad2(n: Int) -> String:
    var v = n if n >= 0 else 0
    if v < 10:
        return String("0") + String(v)
    return String(v)


def _civil_from_days(days: Int) -> Tuple[Int, Int, Int]:
    """``(year, month, day)`` for a count of days since 1970-01-01.

    Hinnant's ``civil_from_days`` with the era shifted so the algorithm's
    internal year starts in March. Only valid for ``days >= -719468``
    (i.e. year 0 onward), which every git timestamp comfortably is.
    """
    var z = days + 719468
    var era = z // 146097
    var doe = z - era * 146097                     # day of era, [0, 146096]
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var y = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153                  # month, March = 0
    var d = doy - (153 * mp + 2) // 5 + 1
    var m = (mp + 3) if mp < 10 else (mp - 9)
    if m <= 2:
        y += 1
    return (y, m, d)


def tz_offset_seconds(tz: String) -> Int:
    """Parse a git ``+HHMM`` / ``-HHMM`` zone into signed seconds. An
    unparseable or empty zone reads as UTC."""
    var b = tz.as_bytes()
    if len(b) < 5:
        return 0
    var sign = -1 if b[0] == 0x2D else 1
    var hours = parse_int_all(byte_slice(tz, 1, 3))
    var minutes = parse_int_all(byte_slice(tz, 3, 5))
    return sign * (hours * 3600 + minutes * 60)


def format_commit_time(unix_time: Int, tz: String) -> String:
    """``YYYY-MM-DD HH:MM +HHMM`` in the *author's* zone, which is what
    ``git blame`` / ``git log`` show by default — the wall-clock the commit
    was actually made at, not the reader's local rendering of it. Returns
    an empty string when there's no timestamp."""
    if unix_time <= 0:
        return String("")
    var shifted = unix_time + tz_offset_seconds(tz)
    var days = shifted // 86400
    var secs = shifted - days * 86400
    var ymd = _civil_from_days(days)
    var out = String(ymd[0]) + String("-") + _pad2(ymd[1]) \
        + String("-") + _pad2(ymd[2]) \
        + String(" ") + _pad2(secs // 3600) \
        + String(":") + _pad2((secs // 60) % 60)
    if len(tz.as_bytes()) > 0:
        out += String(" ") + tz
    return out^




def _looks_like_header(line: String) -> Bool:
    """A header line begins with 40 hex digits + space."""
    var b = line.as_bytes()
    if len(b) < 41:
        return False
    for i in range(40):
        if hex_digit_value(Int(b[i])) < 0:
            return False
    return b[40] == 0x20


def _metadata_value(line: String, key: String) -> Optional[String]:
    """``key value`` → ``value``, or nothing when ``line`` isn't that key.
    Matches ``key`` followed by a space, so ``author`` doesn't swallow
    ``author-mail``."""
    var prefix = key + String(" ")
    if not starts_with(line, prefix):
        return Optional[String]()
    var b = line.as_bytes()
    var off = len(prefix.as_bytes())
    return Optional[String](String(StringSpan(unsafe_from_utf8=b[off:len(b)])))


def parse_blame_porcelain(text: String) -> List[BlameLine]:
    """Walk porcelain lines, emit one ``BlameLine`` per source line.

    State machine:

    * Top: expect a header (``<sha> <orig> <final> [count]``). Parse
      SHA + final-line-num, then find-or-create this SHA's slot in the
      ``commits`` / ``metas`` cache and point ``cur`` at it.
    * Header consumed → read metadata lines (``key value``) until we
      hit the ``\\t<content>`` marker, folding each recognized key into
      the cached record. Because the record lives in the cache, the
      metadata-free repeat headers of a same-commit group inherit it.
    * On ``\\t...`` marker: store a copy of the cached record at index
      ``current_final - 1``, growing the list with empty entries if
      needed (one-based source lines aren't always contiguous in a
      single forward sweep, but git emits them in order).
    """
    var lines = split_lines_no_trailing(text)
    var commits = List[String]()       # parallel SHA cache
    var metas = List[BlameLine]()      # ↳ metadata record for that SHA
    var out = List[BlameLine]()

    var cur = -1                       # index into commits/metas, -1 = none
    var current_final = -1
    var in_header = False

    for li in range(len(lines)):
        var ln = lines[li]
        var lb = ln.as_bytes()
        if in_header and cur >= 0 and len(lb) > 0 and lb[0] == 0x09:
            # ``\t<content>`` — flush a record for current_final.
            var rec = metas[cur]
            if len(rec.author.as_bytes()) == 0:
                rec.author = String("Not Committed Yet")
            # Pad ``out`` so index = current_final - 1.
            while len(out) < current_final:
                out.append(BlameLine())
            if current_final >= 1:
                out[current_final - 1] = rec^
            in_header = False
            continue
        if _looks_like_header(ln):
            var sha = String(StringSpan(unsafe_from_utf8=lb[:40]))
            # Skip past sha + space, parse orig, then final.
            var space2 = 41
            while space2 < len(lb) and lb[space2] != 0x20:
                space2 += 1
            # space2 now at the space after orig.
            var fin_start = space2 + 1
            var fin_end = fin_start
            while fin_end < len(lb) and lb[fin_end] != 0x20:
                fin_end += 1
            current_final = parse_int_prefix(ln, fin_start, fin_end)
            # Find-or-create this SHA's metadata slot. A repeated SHA
            # reuses the slot, which is what carries the metadata across
            # the header-only lines of a group.
            cur = -1
            for i in range(len(commits)):
                if commits[i] == sha:
                    cur = i
                    break
            if cur < 0:
                var fresh = BlameLine()
                fresh.sha = sha
                fresh.commit = String(StringSpan(unsafe_from_utf8=lb[:8]))
                commits.append(sha^)
                metas.append(fresh^)
                cur = len(commits) - 1
            in_header = True
            continue
        if in_header and cur >= 0:
            var author = _metadata_value(ln, String("author"))
            if author:
                metas[cur].author = author.value()
                continue
            var mail = _metadata_value(ln, String("author-mail"))
            if mail:
                metas[cur].author_mail = mail.value()
                continue
            var when = _metadata_value(ln, String("author-time"))
            if when:
                metas[cur].author_time = parse_int_all(when.value())
                continue
            var tz = _metadata_value(ln, String("author-tz"))
            if tz:
                metas[cur].author_tz = tz.value()
                continue
            var summary = _metadata_value(ln, String("summary"))
            if summary:
                metas[cur].summary = summary.value()
                continue
        # Other metadata (committer, previous, filename, boundary, ...)
        # is intentionally ignored — nothing displays it.
    return out^


def compute_blame(file_path: String) raises -> List[BlameLine]:
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
    var argv = git_base_argv(root)
    argv.append(String("blame"))
    argv.append(String("--porcelain"))
    argv.append(String("--"))
    argv.append(abs_path)
    var result = capture_command(argv)
    return parse_blame_porcelain(result.stdout)


def blame_commit_message(file_path: String, sha: String) -> String:
    """Full commit message body for ``sha``, resolving the repository from
    ``file_path``.

    The porcelain blame stream only carries ``summary`` (the subject line),
    so the click-through popup fetches the body on demand — one short-lived
    git per click, not one per blamed line. An empty result (no repo,
    uncommitted line, unknown object, git missing) means "show the summary
    instead" to the caller.
    """
    if len(sha.as_bytes()) == 0 or sha == _ZERO_SHA:
        return String("")
    var abs_path = realpath(file_path)
    if len(abs_path.as_bytes()) == 0:
        abs_path = file_path
    var maybe_root = find_git_project(abs_path)
    if not maybe_root:
        return String("")
    return fetch_commit_message(maybe_root.value(), sha)
