"""``git diff HEAD`` driver: spawn git, capture its unified diff of the
worktree against the last commit, return the raw text.

Untracked files are *not* included — they would show up in ``git status``
but ``git diff HEAD`` only walks the index. That's a deliberate choice for
a single-tier "Show local changes" view: the output is real unified-diff
content with a single hunk-header convention the editor's diff TextMate
grammar already paints. Mixing in ``+++ Untitled`` slabs for untracked
files would muddy that.

A repository with no commits at all (``git init`` but never committed)
makes ``git diff HEAD`` fail with a non-zero exit; the captured stderr is
discarded by ``capture_command`` and we return an empty string.
"""

from std.collections.list import List
from std.collections.optional import Optional

from .diff import DiffOp, diff_lines
from .file_io import find_git_project
from .lsp import capture_command
from .string_utils import (
    split_lines, split_lines_no_trailing, starts_with,
)


# Per-line change status for the editor's git-changes gutter.
# 0 = unchanged, 1 = added (run of +s with no preceding -),
# 2 = modified (run of +s following one or more -s).
comptime GIT_CHANGE_NONE: Int = 0
comptime GIT_CHANGE_ADDED: Int = 1
comptime GIT_CHANGE_MODIFIED: Int = 2


@fieldwise_init
struct ChangedFile(ImplicitlyCopyable, Movable):
    """One file's slice of a unified diff. ``path`` is relative to the
    project root (taken from the ``+++ b/<path>`` header so
    rename-detected diffs surface the destination, not the source);
    ``diff`` is the raw unified-diff text for just this file —
    ``diff --git`` header through the last hunk line — ready to feed to
    a colorizing renderer."""
    var path: String
    var diff: String


fn _strip_prefix_b(line: String) -> String:
    """Strip the leading ``+++ b/`` (or ``--- a/``) marker from a path
    header, leaving the bare relative path. The ``a/`` and ``b/``
    pseudo-roots are git's convention; not all renderers emit them, but
    ``git diff`` always does for the worktree path."""
    var bytes = line.as_bytes()
    var n = len(bytes)
    if n < 6:
        return line
    # ``+++ ``  or  ``--- ``
    var ofs = 4
    if ofs < n and bytes[ofs] == 0x62 and ofs + 1 < n and bytes[ofs + 1] == 0x2F:
        ofs += 2
    elif ofs < n and bytes[ofs] == 0x61 and ofs + 1 < n and bytes[ofs + 1] == 0x2F:
        ofs += 2
    return String(StringSlice(unsafe_from_utf8=bytes[ofs:n]))


fn parse_unified_diff_files(diff: String) -> List[ChangedFile]:
    """Walk a multi-file unified diff and split it on ``diff --git``
    boundaries. Each ``ChangedFile`` carries its own complete chunk
    (header + hunks) so the right-pane renderer doesn't need to track
    where each file's text starts.

    Path resolution prefers the ``+++ b/<path>`` line because git emits
    it as the destination side — for a rename, that's the new name the
    user is interested in. Pure-deletion diffs (``+++ /dev/null``) fall
    back to the ``--- a/<path>`` source.
    """
    var out = List[ChangedFile]()
    var b = diff.as_bytes()
    var line_starts = List[Int]()
    line_starts.append(0)
    for i in range(len(b)):
        if b[i] == 0x0A and i + 1 < len(b):
            line_starts.append(i + 1)
    line_starts.append(len(b))

    # Walk ``diff --git`` headers. Each header opens a chunk that
    # extends until the next header (or end of input).
    var chunk_starts = List[Int]()      # byte offsets
    var i = 0
    while i < len(line_starts) - 1:
        var s = line_starts[i]
        var e = line_starts[i + 1] if i + 1 < len(line_starts) else len(b)
        var line = String(StringSlice(unsafe_from_utf8=b[s:e]))
        # Strip trailing LF for the prefix check.
        if starts_with(line, String("diff --git ")):
            chunk_starts.append(s)
        i += 1
    chunk_starts.append(len(b))    # sentinel

    for k in range(len(chunk_starts) - 1):
        var cs = chunk_starts[k]
        var ce = chunk_starts[k + 1]
        if ce <= cs:
            continue
        var chunk = String(StringSlice(unsafe_from_utf8=b[cs:ce]))
        # Find the ``+++ `` line for the path; fall back to ``--- ``.
        var path = String("")
        var cb = chunk.as_bytes()
        var ls = 0
        while ls < len(cb):
            var le = ls
            while le < len(cb) and cb[le] != 0x0A:
                le += 1
            var ln = String(StringSlice(unsafe_from_utf8=cb[ls:le]))
            if starts_with(ln, String("+++ ")):
                if ln != String("+++ /dev/null"):
                    path = _strip_prefix_b(ln)
                    break
                # ``+++ /dev/null`` → pure delete; remember the source
                # but keep scanning in case a later ``+++`` overrides
                # (shouldn't happen inside one chunk, but cheap).
            elif starts_with(ln, String("--- ")) \
                    and len(path.as_bytes()) == 0 \
                    and ln != String("--- /dev/null"):
                path = _strip_prefix_b(ln)
            ls = le + 1
        if len(path.as_bytes()) == 0:
            # Last-resort: pull the path out of ``diff --git a/X b/X``.
            # The first ``b/`` token after the header word is the
            # destination path; we just take everything after it.
            var hdr_end = 0
            while hdr_end < len(cb) and cb[hdr_end] != 0x0A:
                hdr_end += 1
            var hdr = String(StringSlice(unsafe_from_utf8=cb[:hdr_end]))
            var hb = hdr.as_bytes()
            var p = len(hb) - 1
            while p > 1 and not (hb[p - 1] == 0x20 and hb[p] == 0x62
                                  and p + 1 < len(hb) and hb[p + 1] == 0x2F):
                p -= 1
            if p > 1:
                path = String(StringSlice(unsafe_from_utf8=hb[p + 2:len(hb)]))
            else:
                path = String("(unknown)")
        out.append(ChangedFile(path^, chunk^))
    return out^


fn _relative_to_root(file_path: String, root: String) -> String:
    """Strip a leading ``<root>/`` (or ``<root>``) from ``file_path``;
    return the input unchanged if the prefix doesn't match. Used to
    feed ``git diff -- <pathspec>`` a path relative to the repo root,
    which ``git -C <root>`` interprets that way."""
    var fb = file_path.as_bytes()
    var rb = root.as_bytes()
    if len(rb) == 0 or len(fb) < len(rb):
        return file_path
    for i in range(len(rb)):
        if fb[i] != rb[i]:
            return file_path
    if len(fb) == len(rb):
        return String("")
    if fb[len(rb)] != 0x2F:    # not a directory boundary — bail
        return file_path
    return String(StringSlice(unsafe_from_utf8=fb[len(rb) + 1:len(fb)]))


fn diff_buffer_against_head(
    head_text: String, buffer_lines: List[String],
) -> List[Int]:
    """Run a Myers line-diff between ``head_text`` (the file at HEAD)
    and ``buffer_lines`` (the editor's in-memory text); return a list
    of length ``len(buffer_lines)`` where each entry is one of
    ``GIT_CHANGE_NONE/ADDED/MODIFIED``.

    Heuristic for added vs. modified: a run of inserts inside a single
    hunk is *modified* when at least one delete preceded it within the
    same run, otherwise *added*. This matches the VS Code / IntelliJ
    change-bar convention.
    """
    var out = List[Int]()
    var nb = len(buffer_lines)
    if nb == 0:
        return out^
    for _ in range(nb):
        out.append(GIT_CHANGE_NONE)
    var head_lines = split_lines(head_text)
    var ops = diff_lines(head_lines, buffer_lines)
    var i = 0
    var n = len(ops)
    while i < n:
        if ops[i].kind == 0:
            i += 1
            continue
        # Scan the whole non-equal run first — Myers can emit inserts
        # and deletes in either order within a run, so we can't classify
        # an insert as ADDED vs MODIFIED until we know how many deletes
        # share the run with it.
        var run_start = i
        var run_dels = 0
        var run_ins = 0
        while i < n and ops[i].kind != 0:
            if ops[i].kind == 1:
                run_dels += 1
            else:
                run_ins += 1
            i += 1
        # First ``min(run_dels, run_ins)`` inserts in the run pair up
        # with deletes → MODIFIED; surplus inserts (when run_ins >
        # run_dels) are pure ADDED. When the run was deletes-only
        # (run_ins == 0) there are no buffer rows to mark — the
        # deletion is invisible in the gutter, matching VS Code.
        var pair_count = run_dels if run_dels < run_ins else run_ins
        var ins_seen = 0
        for j in range(run_start, i):
            if ops[j].kind != 2:
                continue
            var bi = ops[j].b_index
            if 0 <= bi and bi < nb:
                if ins_seen < pair_count:
                    out[bi] = GIT_CHANGE_MODIFIED
                else:
                    out[bi] = GIT_CHANGE_ADDED
            ins_seen += 1
    return out^


fn fetch_head_text(project_root: String, file_path: String) -> Optional[String]:
    """Spawn ``git -C <root> show HEAD:<rel>`` and return its stdout.

    Empty Optional when git can't resolve the path at HEAD (file is
    untracked, brand new, or the spawn failed); callers treat that as
    "no baseline → mark every line added", which is the conventional
    change-bar behavior for a new file.
    """
    if len(project_root.as_bytes()) == 0 or len(file_path.as_bytes()) == 0:
        return Optional[String]()
    var rel = _relative_to_root(file_path, project_root)
    if len(rel.as_bytes()) == 0:
        return Optional[String]()
    var argv = List[String]()
    argv.append(String("git"))
    argv.append(String("-C"))
    argv.append(project_root)
    argv.append(String("show"))
    argv.append(String("HEAD:") + rel^)
    try:
        var result = capture_command(argv)
        # Non-zero exit = path not in HEAD; treat as "no baseline".
        if Int(result.status) != 0:
            return Optional[String]()
        return Optional[String](result.stdout)
    except:
        return Optional[String]()


fn project_is_git_repo(project_root: String) -> Bool:
    """Cheap check: ``True`` iff a ``.git`` entry exists at or above
    ``project_root``. Empty string short-circuits to False."""
    if len(project_root.as_bytes()) == 0:
        return False
    var found = find_git_project(project_root)
    return Bool(found)


fn compute_local_changes(project_root: String) raises -> String:
    """Spawn ``git -C <root> diff HEAD --no-color`` and return stdout.

    ``project_root`` should be the directory holding the ``.git`` entry —
    callers typically pass ``Desktop.project.value()``. Empty string when
    git exits non-zero (no commits, not a repo, …) or when stdout is
    empty (worktree clean).

    Raises only on spawn failure (e.g., git missing from PATH).
    """
    var argv = List[String]()
    argv.append(String("git"))
    argv.append(String("-C"))
    argv.append(project_root)
    argv.append(String("diff"))
    argv.append(String("HEAD"))
    argv.append(String("--no-color"))
    var result = capture_command(argv)
    return result.stdout


fn compute_staged_diff(project_root: String) -> String:
    """``git diff --cached --no-color`` — the index versus HEAD. Empty
    string on failure (no commits, not a repo, git missing)."""
    if len(project_root.as_bytes()) == 0:
        return String("")
    var argv = List[String]()
    argv.append(String("git"))
    argv.append(String("-C"))
    argv.append(project_root)
    argv.append(String("diff"))
    argv.append(String("--cached"))
    argv.append(String("--no-color"))
    try:
        var result = capture_command(argv)
        if Int(result.status) != 0:
            return String("")
        return result.stdout
    except:
        return String("")


fn compute_unstaged_diff(project_root: String) -> String:
    """``git diff --no-color`` — worktree versus index. Empty on failure."""
    if len(project_root.as_bytes()) == 0:
        return String("")
    var argv = List[String]()
    argv.append(String("git"))
    argv.append(String("-C"))
    argv.append(project_root)
    argv.append(String("diff"))
    argv.append(String("--no-color"))
    try:
        var result = capture_command(argv)
        if Int(result.status) != 0:
            return String("")
        return result.stdout
    except:
        return String("")


@fieldwise_init
struct GitFileStatus(ImplicitlyCopyable, Movable):
    """One row of ``git status --porcelain=v1 -z``. ``staged`` (X) and
    ``worktree`` (Y) are single-byte status codes — space (0x20) means
    "no change in this column"; ``M``/``A``/``D``/``R``/``C`` are the
    common cases; ``?`` shows in both columns for untracked entries.
    ``orig_path`` is empty unless this is a rename or copy (X is ``R``
    or ``C``), in which case it carries the source path."""
    var path: String
    var staged: UInt8
    var worktree: UInt8
    var orig_path: String


fn fetch_git_status(project_root: String) -> List[GitFileStatus]:
    """Run ``git status --porcelain=v1 -z`` and parse one entry per row.

    The ``-z`` framing keeps paths unquoted and NUL-terminated, so a
    filename containing whitespace or a ``\\n`` survives intact. Renames
    and copies append a second NUL-terminated source path; we capture it
    in ``orig_path``. Empty list when git exits non-zero (not a repo,
    git missing, etc.).
    """
    var out = List[GitFileStatus]()
    if len(project_root.as_bytes()) == 0:
        return out^
    var argv = List[String]()
    argv.append(String("git"))
    argv.append(String("-C"))
    argv.append(project_root)
    argv.append(String("status"))
    argv.append(String("--porcelain=v1"))
    argv.append(String("-z"))
    var stdout: String
    try:
        var result = capture_command(argv)
        if Int(result.status) != 0:
            return out^
        stdout = result.stdout
    except:
        return out^
    var b = stdout.as_bytes()
    var i = 0
    while i + 3 <= len(b):
        var x = b[i]
        var y = b[i + 1]
        # Third byte is the separator space (0x20) before the path.
        i += 3
        var s = i
        while i < len(b) and b[i] != 0x00:
            i += 1
        var path = String(StringSlice(unsafe_from_utf8=b[s:i]))
        if i < len(b):
            i += 1   # consume the path's trailing NUL
        var orig = String("")
        if Int(x) == 0x52 or Int(x) == 0x43:    # 'R' (rename) or 'C' (copy)
            var os = i
            while i < len(b) and b[i] != 0x00:
                i += 1
            orig = String(StringSlice(unsafe_from_utf8=b[os:i]))
            if i < len(b):
                i += 1
        out.append(GitFileStatus(path^, x, y, orig^))
    return out^


fn stage_file(project_root: String, path: String) -> Bool:
    """``git add -- <path>``. Returns False when git is unavailable, the
    path is empty, or git exited non-zero. ``path`` is taken as-is —
    callers should pass repo-relative paths (the same shape ``git
    status`` produces)."""
    if len(project_root.as_bytes()) == 0 or len(path.as_bytes()) == 0:
        return False
    var argv = List[String]()
    argv.append(String("git"))
    argv.append(String("-C"))
    argv.append(project_root)
    argv.append(String("add"))
    argv.append(String("--"))
    argv.append(path)
    try:
        var r = capture_command(argv)
        return Int(r.status) == 0
    except:
        return False


fn unstage_file(project_root: String, path: String) -> Bool:
    """``git restore --staged -- <path>`` (git ≥ 2.23). For pre-existing
    repos this restores the index entry to its HEAD content without
    touching the worktree. Returns False on failure."""
    if len(project_root.as_bytes()) == 0 or len(path.as_bytes()) == 0:
        return False
    var argv = List[String]()
    argv.append(String("git"))
    argv.append(String("-C"))
    argv.append(project_root)
    argv.append(String("restore"))
    argv.append(String("--staged"))
    argv.append(String("--"))
    argv.append(path)
    try:
        var r = capture_command(argv)
        return Int(r.status) == 0
    except:
        return False


fn apply_patch_to_index(
    project_root: String, patch: String, reverse: Bool = False,
) -> Bool:
    """Pipe ``patch`` to ``git apply --cached --recount`` (with
    ``--reverse`` when unstaging). ``--recount`` lets us hand-roll
    minimal hunks without bookkeeping the @@ counts exactly — git fixes
    them up. Returns False on any non-zero exit; we don't surface the
    stderr because the only legitimate failures are "patch doesn't
    apply" (already handled by the caller's refresh) and "git missing"
    (already handled by the surrounding repo gate)."""
    if len(project_root.as_bytes()) == 0 or len(patch.as_bytes()) == 0:
        return False
    var argv = List[String]()
    argv.append(String("git"))
    argv.append(String("-C"))
    argv.append(project_root)
    argv.append(String("apply"))
    argv.append(String("--cached"))
    argv.append(String("--recount"))
    if reverse:
        argv.append(String("--reverse"))
    argv.append(String("-"))
    try:
        var r = capture_command(argv, patch)
        return Int(r.status) == 0
    except:
        return False


@fieldwise_init
struct GitOpResult(ImplicitlyCopyable, Movable):
    """Outcome of a one-shot git command (commit / pull / push / etc).
    ``ok`` is True iff the process exited 0; ``message`` is a short
    human-readable summary the caller can flash in the UI — populated
    from stderr (for failures) or stdout (for successes), trimmed and
    de-newlined so it fits one row."""
    var ok: Bool
    var message: String


fn _trim_one_line(s: String) -> String:
    """Collapse ``s`` to its first non-empty line, stripped of trailing
    whitespace. Falls back to the empty string when ``s`` is all blank.
    Used to render git's stdout/stderr inside a single overlay row."""
    var b = s.as_bytes()
    var i = 0
    while i < len(b):
        # skip leading whitespace
        while i < len(b) and (b[i] == 0x20 or b[i] == 0x09 \
                or b[i] == 0x0A or b[i] == 0x0D):
            i += 1
        var s_start = i
        while i < len(b) and b[i] != 0x0A and b[i] != 0x0D:
            i += 1
        var line = String(StringSlice(unsafe_from_utf8=b[s_start:i]))
        # trim trailing whitespace
        var lb = line.as_bytes()
        var end = len(lb)
        while end > 0 and (lb[end - 1] == 0x20 or lb[end - 1] == 0x09):
            end -= 1
        if end > 0:
            return String(StringSlice(unsafe_from_utf8=lb[:end]))
    return String("")


fn git_commit(project_root: String, message: String) -> GitOpResult:
    """``git commit -m <message>``. Reports the first stdout line on
    success (``[main abc1234] subject``) and the first stderr line on
    failure (typically ``nothing to commit`` or a hook complaint)."""
    if len(project_root.as_bytes()) == 0 or len(message.as_bytes()) == 0:
        return GitOpResult(False, String("empty message"))
    var argv = List[String]()
    argv.append(String("git"))
    argv.append(String("-C"))
    argv.append(project_root)
    argv.append(String("commit"))
    argv.append(String("-m"))
    argv.append(message)
    try:
        var r = capture_command(argv)
        var ok = Int(r.status) == 0
        var msg: String
        if ok:
            msg = _trim_one_line(r.stdout)
            if len(msg.as_bytes()) == 0:
                msg = String("commit ok")
        else:
            msg = _trim_one_line(r.stderr)
            if len(msg.as_bytes()) == 0:
                msg = _trim_one_line(r.stdout)
            if len(msg.as_bytes()) == 0:
                msg = String("commit failed")
        return GitOpResult(ok, msg^)
    except:
        return GitOpResult(False, String("git unavailable"))


fn git_amend_no_edit(project_root: String) -> GitOpResult:
    """``git commit --amend --no-edit``: fold staged changes (or just
    re-touch the commit) into HEAD without prompting for a new message."""
    if len(project_root.as_bytes()) == 0:
        return GitOpResult(False, String("no project"))
    var argv = List[String]()
    argv.append(String("git"))
    argv.append(String("-C"))
    argv.append(project_root)
    argv.append(String("commit"))
    argv.append(String("--amend"))
    argv.append(String("--no-edit"))
    try:
        var r = capture_command(argv)
        var ok = Int(r.status) == 0
        var msg: String
        if ok:
            msg = _trim_one_line(r.stdout)
            if len(msg.as_bytes()) == 0:
                msg = String("amend ok")
        else:
            msg = _trim_one_line(r.stderr)
            if len(msg.as_bytes()) == 0:
                msg = String("amend failed")
        return GitOpResult(ok, msg^)
    except:
        return GitOpResult(False, String("git unavailable"))


fn git_revert_file(
    project_root: String, path: String,
    staged: UInt8, worktree: UInt8,
) -> GitOpResult:
    """Discard *all* local changes for ``path``. For tracked files runs
    ``git checkout HEAD -- <path>`` which restores both index and
    worktree to HEAD. For untracked files (``??``) runs ``git clean -f
    -- <path>`` since there's no HEAD version to restore from."""
    if len(project_root.as_bytes()) == 0 or len(path.as_bytes()) == 0:
        return GitOpResult(False, String("empty path"))
    var untracked = (Int(staged) == 0x3F and Int(worktree) == 0x3F)
    var argv = List[String]()
    argv.append(String("git"))
    argv.append(String("-C"))
    argv.append(project_root)
    if untracked:
        argv.append(String("clean"))
        argv.append(String("-f"))
        argv.append(String("--"))
        argv.append(path)
    else:
        argv.append(String("checkout"))
        argv.append(String("HEAD"))
        argv.append(String("--"))
        argv.append(path)
    try:
        var r = capture_command(argv)
        var ok = Int(r.status) == 0
        var msg: String
        if ok:
            if untracked:
                msg = String("removed untracked file")
            else:
                msg = String("reverted ") + path
        else:
            msg = _trim_one_line(r.stderr)
            if len(msg.as_bytes()) == 0:
                msg = String("revert failed")
        return GitOpResult(ok, msg^)
    except:
        return GitOpResult(False, String("git unavailable"))


fn git_pull(project_root: String) -> GitOpResult:
    """``git pull`` (uses repo defaults — branch tracking, ff/rebase
    settings, etc.). This is a synchronous network call; the surrounding
    UI blocks until it returns."""
    if len(project_root.as_bytes()) == 0:
        return GitOpResult(False, String("no project"))
    var argv = List[String]()
    argv.append(String("git"))
    argv.append(String("-C"))
    argv.append(project_root)
    argv.append(String("pull"))
    try:
        var r = capture_command(argv)
        var ok = Int(r.status) == 0
        var msg: String
        if ok:
            msg = _trim_one_line(r.stdout)
            if len(msg.as_bytes()) == 0:
                msg = String("pull ok")
        else:
            msg = _trim_one_line(r.stderr)
            if len(msg.as_bytes()) == 0:
                msg = _trim_one_line(r.stdout)
            if len(msg.as_bytes()) == 0:
                msg = String("pull failed")
        return GitOpResult(ok, msg^)
    except:
        return GitOpResult(False, String("git unavailable"))


fn git_push(project_root: String) -> GitOpResult:
    """``git push`` (uses repo defaults — remote, branch, upstream).
    Same blocking caveat as ``git_pull``."""
    if len(project_root.as_bytes()) == 0:
        return GitOpResult(False, String("no project"))
    var argv = List[String]()
    argv.append(String("git"))
    argv.append(String("-C"))
    argv.append(project_root)
    argv.append(String("push"))
    try:
        var r = capture_command(argv)
        var ok = Int(r.status) == 0
        var msg: String
        if ok:
            msg = _trim_one_line(r.stderr)  # push reports progress on stderr
            if len(msg.as_bytes()) == 0:
                msg = _trim_one_line(r.stdout)
            if len(msg.as_bytes()) == 0:
                msg = String("push ok")
        else:
            msg = _trim_one_line(r.stderr)
            if len(msg.as_bytes()) == 0:
                msg = _trim_one_line(r.stdout)
            if len(msg.as_bytes()) == 0:
                msg = String("push failed")
        return GitOpResult(ok, msg^)
    except:
        return GitOpResult(False, String("git unavailable"))


@fieldwise_init
struct GitBranch(ImplicitlyCopyable, Movable):
    """One row of ``git for-each-ref refs/heads``: branch ``name``, the
    short sha its tip points at, the tip commit's subject, and whether
    this is the currently checked-out branch (``HEAD``)."""
    var name: String
    var short_sha: String
    var subject: String
    var is_current: Bool


@fieldwise_init
struct GitCommit(ImplicitlyCopyable, Movable):
    """One row of ``git log --pretty=format``. ``date`` is YYYY-MM-DD.
    ``is_pushed`` is True when the commit is reachable from at least one
    remote-tracking ref (i.e. already pushed somewhere); False when it
    only exists locally. With no remotes configured, every commit is
    treated as unpushed."""
    var short_sha: String
    var author: String
    var date: String
    var subject: String
    var is_pushed: Bool


fn _split_tab_fields(line: String, n: Int) -> List[String]:
    """Split ``line`` on ``\\t`` into at most ``n`` fields. The last
    field absorbs any further tabs verbatim, so a commit subject that
    happens to include a tab survives unmangled. Output is padded to
    length ``n`` with empty strings if the line had fewer separators."""
    var out = List[String]()
    var b = line.as_bytes()
    var s = 0
    var produced = 0
    for i in range(len(b)):
        if produced + 1 >= n:
            break
        if b[i] == 0x09:
            out.append(String(StringSlice(unsafe_from_utf8=b[s:i])))
            s = i + 1
            produced += 1
    out.append(String(StringSlice(unsafe_from_utf8=b[s:len(b)])))
    while len(out) < n:
        out.append(String(""))
    return out^


fn fetch_git_branches(project_root: String) -> List[GitBranch]:
    """Run ``git for-each-ref refs/heads`` and parse the output.

    Branches are returned sorted by most recent commit date first. Empty
    list when git is unavailable or the repo has no local branches yet
    (fresh ``git init``)."""
    var out = List[GitBranch]()
    if len(project_root.as_bytes()) == 0:
        return out^
    var argv = List[String]()
    argv.append(String("git"))
    argv.append(String("-C"))
    argv.append(project_root)
    argv.append(String("for-each-ref"))
    argv.append(String("--sort=-committerdate"))
    argv.append(
        String("--format=%(HEAD)%09%(refname:short)%09%(objectname:short)%09%(subject)"),
    )
    argv.append(String("refs/heads"))
    var stdout: String
    try:
        var result = capture_command(argv)
        if Int(result.status) != 0:
            return out^
        stdout = result.stdout
    except:
        return out^
    var lines = split_lines_no_trailing(stdout)
    for li in range(len(lines)):
        var line = lines[li]
        if len(line.as_bytes()) == 0:
            continue
        var fields = _split_tab_fields(line, 4)
        var marker = fields[0]
        var is_cur = (len(marker.as_bytes()) > 0
                      and marker.as_bytes()[0] == 0x2A)
        out.append(GitBranch(fields[1], fields[2], fields[3], is_cur))
    return out^


fn _fetch_unpushed_short_shas(
    project_root: String, limit: Int,
) -> List[String]:
    """Short SHAs of commits reachable from HEAD that are *not* in any
    remote-tracking ref. Used to flag local-only commits in the commits
    pane. ``--abbrev-commit`` matches the abbreviation length used by
    ``git log %h`` in :func:`fetch_git_commits`, so the strings line up
    for direct equality membership checks."""
    var out = List[String]()
    if len(project_root.as_bytes()) == 0:
        return out^
    var argv = List[String]()
    argv.append(String("git"))
    argv.append(String("-C"))
    argv.append(project_root)
    argv.append(String("rev-list"))
    argv.append(String("-") + String(limit))
    argv.append(String("HEAD"))
    argv.append(String("--not"))
    argv.append(String("--remotes"))
    argv.append(String("--abbrev-commit"))
    var stdout: String
    try:
        var result = capture_command(argv)
        if Int(result.status) != 0:
            return out^
        stdout = result.stdout
    except:
        return out^
    var lines = split_lines_no_trailing(stdout)
    for li in range(len(lines)):
        var line = lines[li]
        if len(line.as_bytes()) > 0:
            out.append(line)
    return out^


fn _list_contains(shas: List[String], sha: String) -> Bool:
    for i in range(len(shas)):
        if shas[i] == sha:
            return True
    return False


fn fetch_git_commits(
    project_root: String, limit: Int = 50,
) -> List[GitCommit]:
    """Run ``git log -<limit> --pretty=format``. The newest commit is
    first. Empty list on failure. Each entry's ``is_pushed`` is set
    based on whether the commit is reachable from any remote-tracking
    ref (cross-checked via :func:`_fetch_unpushed_short_shas`)."""
    var out = List[GitCommit]()
    if len(project_root.as_bytes()) == 0:
        return out^
    var argv = List[String]()
    argv.append(String("git"))
    argv.append(String("-C"))
    argv.append(project_root)
    argv.append(String("log"))
    argv.append(String("-") + String(limit))
    argv.append(String("--no-color"))
    argv.append(String("--date=short"))
    argv.append(String("--pretty=format:%h%x09%an%x09%ad%x09%s"))
    var stdout: String
    try:
        var result = capture_command(argv)
        if Int(result.status) != 0:
            return out^
        stdout = result.stdout
    except:
        return out^
    var unpushed = _fetch_unpushed_short_shas(project_root, limit)
    var lines = split_lines_no_trailing(stdout)
    for li in range(len(lines)):
        var line = lines[li]
        if len(line.as_bytes()) == 0:
            continue
        var fields = _split_tab_fields(line, 4)
        var pushed = not _list_contains(unpushed, fields[0])
        out.append(
            GitCommit(
                fields[0], fields[1], fields[2], fields[3], pushed,
            ),
        )
    return out^


fn fetch_commit_show(project_root: String, sha: String) -> String:
    """Run ``git show <sha> --no-color`` and return its full output
    (header + unified diff). Used as the right-pane content when the
    user focuses a commit in the local-changes view."""
    if len(project_root.as_bytes()) == 0 or len(sha.as_bytes()) == 0:
        return String("")
    var argv = List[String]()
    argv.append(String("git"))
    argv.append(String("-C"))
    argv.append(project_root)
    argv.append(String("show"))
    argv.append(String("--no-color"))
    argv.append(sha)
    try:
        var result = capture_command(argv)
        if Int(result.status) != 0:
            return String("")
        return result.stdout
    except:
        return String("")


fn fetch_branch_log(
    project_root: String, branch: String, limit: Int = 30,
) -> String:
    """Run ``git log -<limit> --no-color <branch>`` and return stdout.

    Used as the right-pane content when a branch is focused. We render
    the raw ``git log`` output so the user gets author / date / subject
    in one paint, the same shape they'd see at the shell."""
    if len(project_root.as_bytes()) == 0 or len(branch.as_bytes()) == 0:
        return String("")
    var argv = List[String]()
    argv.append(String("git"))
    argv.append(String("-C"))
    argv.append(project_root)
    argv.append(String("log"))
    argv.append(String("-") + String(limit))
    argv.append(String("--no-color"))
    argv.append(String("--date=short"))
    argv.append(
        String("--pretty=format:%h  %ad  %an%n    %s%n"),
    )
    argv.append(branch)
    try:
        var result = capture_command(argv)
        if Int(result.status) != 0:
            return String("")
        return result.stdout
    except:
        return String("")
