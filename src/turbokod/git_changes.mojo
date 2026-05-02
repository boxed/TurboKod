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


fn _starts_with(s: String, prefix: String) -> Bool:
    var sb = s.as_bytes()
    var pb = prefix.as_bytes()
    if len(pb) > len(sb):
        return False
    for i in range(len(pb)):
        if sb[i] != pb[i]:
            return False
    return True


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
        if _starts_with(line, String("diff --git ")):
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
            if _starts_with(ln, String("+++ ")):
                if ln != String("+++ /dev/null"):
                    path = _strip_prefix_b(ln)
                    break
                # ``+++ /dev/null`` → pure delete; remember the source
                # but keep scanning in case a later ``+++`` overrides
                # (shouldn't happen inside one chunk, but cheap).
            elif _starts_with(ln, String("--- ")) \
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


fn _split_lines(text: String) -> List[String]:
    """Split ``text`` on ``\\n``. A trailing newline produces an empty
    final line, matching ``TextBuffer``'s convention. Used so the diff
    against HEAD treats both inputs identically (the HEAD content from
    ``git show`` always ends in ``\\n`` for normal files; the buffer's
    ``text_snapshot`` does too whenever the user kept the trailing
    newline)."""
    var out = List[String]()
    var bytes = text.as_bytes()
    var start = 0
    var i = 0
    while i < len(bytes):
        if bytes[i] == 0x0A:
            out.append(String(StringSlice(unsafe_from_utf8=bytes[start:i])))
            start = i + 1
        i += 1
    out.append(String(StringSlice(unsafe_from_utf8=bytes[start:len(bytes)])))
    return out^


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
    var head_lines = _split_lines(head_text)
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
