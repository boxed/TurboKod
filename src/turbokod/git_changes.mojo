"""``git diff HEAD`` driver: spawn git, capture its unified diff of the
worktree against the last commit, return the raw text.

Untracked files are *not* included — they would show up in ``git status``
but ``git diff HEAD`` only walks the index. That's a deliberate choice for
a single-tier "Show local changes" view: the output is real unified-diff
content with a single hunk-header convention the editor's diff TextMate
grammar already paints. Mixing in ``+++ Untitled`` slabs for untracked
files would muddy that. The Local-changes modal, which lists untracked
files as their own rows, pulls their contents through
:func:`compute_untracked_diff` instead — one file at a time, in the same
unified-diff shape.

A repository with no commits at all (``git init`` but never committed)
makes ``git diff HEAD`` fail with a non-zero exit; the captured stderr is
discarded by ``capture_command`` and we return an empty string.
"""

from std.collections.list import List
from std.collections.optional import Optional

from .diff import DiffOp, diff_lines
from .file_io import find_git_project, join_path, project_relative, stat_file
from .lsp import capture_command
from .string_utils import (
    parse_int_all, split_lines, split_lines_no_trailing, starts_with,
)


# Per-line change status for the editor's git-changes gutter.
# 0 = unchanged, 1 = added (run of +s with no preceding -),
# 2 = modified (run of +s following one or more -s).
comptime GIT_CHANGE_NONE: Int = 0
comptime GIT_CHANGE_ADDED: Int = 1
comptime GIT_CHANGE_MODIFIED: Int = 2


@fieldwise_init
struct GitRevertRequest(Copyable, Movable):
    """Payload emitted when the user opens the git-gutter revert popup —
    by clicking the gutter change-bar of a modified row, or by jumping
    to a change chunk with Ctrl+Shift+Up/Down.

    ``row`` is the buffer row the request targets (used to recompute the
    revert block at submit time). ``anchor_x``/``anchor_y`` are a fallback
    screen cell to anchor the popup at.

    The remaining fields drive the inline "old code" preview the popup
    paints so the user can compare against the new code:

    * ``text_x`` — screen column where the editor's text content starts,
      so the old lines paint at the same column as the new code below
      them (column-aligned for easy comparison).
    * ``block_top_y`` — screen row of the first changed buffer row of the
      block; the old lines stack directly above it. ``-1`` when the block
      isn't on screen (then the popup falls back to ``anchor``).
    * ``new_count`` — number of buffer rows the change block spans (used
      to place the preview below the block when there's no room above).
    * ``head_lines`` — the file's content at HEAD for this block (the old
      code). Empty for a pure-insert block (nothing at HEAD to show)."""
    var row: Int
    var anchor_x: Int
    var anchor_y: Int
    var text_x: Int
    var block_top_y: Int
    var new_count: Int
    var head_lines: List[String]
    var is_deletion: Bool
    """True when the request targets a *pure deletion* marker (the ``_``
    underscore on the row above a removed run) rather than an added /
    modified change bar. ``row`` is then the row above the deletion, and
    the submit path recomputes the block via ``compute_deletion_revert_block``
    (which re-inserts the removed lines) instead of ``compute_revert_block``."""

    def __copyinit__(mut self, copy: Self):
        self.row = copy.row
        self.anchor_x = copy.anchor_x
        self.anchor_y = copy.anchor_y
        self.text_x = copy.text_x
        self.block_top_y = copy.block_top_y
        self.new_count = copy.new_count
        self.head_lines = copy.head_lines.copy()
        self.is_deletion = copy.is_deletion


@fieldwise_init
struct GitRevertBlock(Copyable, Movable):
    """Result of mapping a clicked buffer row back through a Myers diff
    against HEAD. ``buf_start``/``buf_end_excl`` are the buffer-row
    range covered by the change run; ``head_lines`` is the slice of
    HEAD that should replace it. For a pure-insert run ``head_lines``
    is empty (the run gets deleted); for a pure-modify run both ranges
    are non-empty."""
    var buf_start: Int
    var buf_end_excl: Int
    var head_lines: List[String]

    def __copyinit__(mut self, copy: Self):
        self.buf_start = copy.buf_start
        self.buf_end_excl = copy.buf_end_excl
        self.head_lines = copy.head_lines.copy()


def compute_revert_block(
    head_text: String, buffer_lines: List[String], target_row: Int,
) -> Optional[GitRevertBlock]:
    """Walk the Myers diff between ``head_text`` (the file at HEAD) and
    ``buffer_lines`` (the editor's in-memory text), find the change run
    that contains ``target_row`` in the buffer, and return the buffer
    range to replace plus the HEAD lines to put in its place.

    Returns an empty Optional when ``target_row`` falls outside any
    non-equal run (i.e. the line is unchanged from HEAD), or when the
    run is a pure deletion that doesn't actually cover any buffer rows.
    """
    if target_row < 0 or target_row >= len(buffer_lines):
        return Optional[GitRevertBlock]()
    var head_lines = split_lines(head_text)
    var ops = diff_lines(head_lines, buffer_lines)
    var i = 0
    var n = len(ops)
    while i < n:
        if ops[i].kind == 0:
            i += 1
            continue
        # Scan the whole non-equal run.
        var run_start = i
        while i < n and ops[i].kind != 0:
            i += 1
        # First buffer / head row in this run, plus length on each side.
        var buf_start = -1
        var buf_end_excl = -1
        var head_start = -1
        var head_end_excl = -1
        for j in range(run_start, i):
            if ops[j].kind == 1:    # delete from a (head)
                if head_start == -1:
                    head_start = ops[j].a_index
                head_end_excl = ops[j].a_index + 1
            else:                   # insert from b (buffer)
                if buf_start == -1:
                    buf_start = ops[j].b_index
                buf_end_excl = ops[j].b_index + 1
        if buf_start == -1:
            # Deletion-only run — the gutter shows nothing at this run, so
            # a click can't have landed here. Skip.
            continue
        if buf_start <= target_row and target_row < buf_end_excl:
            var head_slice = List[String]()
            if head_start != -1:
                for k in range(head_start, head_end_excl):
                    head_slice.append(head_lines[k])
            return Optional[GitRevertBlock](
                GitRevertBlock(buf_start, buf_end_excl, head_slice^)
            )
    return Optional[GitRevertBlock]()


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


def _strip_prefix_b(line: String) -> String:
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


def parse_unified_diff_files(diff: String) -> List[ChangedFile]:
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
            # Scan *forward* for the leading `` a/`` token, then the first
            # `` b/`` after it, and take everything past that as the
            # destination path. Scanning from the right would mis-split a
            # path that itself contains `` b/``. (Git quotes/escapes paths
            # with spaces in C-string form, so a `` b/`` embedded in such a
            # quoted path remains an ambiguity this simple scan can't fully
            # resolve — acceptable for the rename/mode-only fallback.)
            var hdr_end = 0
            while hdr_end < len(cb) and cb[hdr_end] != 0x0A:
                hdr_end += 1
            var hdr = String(StringSlice(unsafe_from_utf8=cb[:hdr_end]))
            var hb = hdr.as_bytes()
            # Locate `` a/``.
            var a = 0
            while a + 2 < len(hb) and not (hb[a] == 0x20 and hb[a + 1] == 0x61
                                            and hb[a + 2] == 0x2F):
                a += 1
            # Find the first `` b/`` after the `` a/`` token.
            var p = a + 3 if (a + 2 < len(hb)) else 0
            while p + 2 < len(hb) and not (hb[p] == 0x20 and hb[p + 1] == 0x62
                                            and hb[p + 2] == 0x2F):
                p += 1
            if p + 2 < len(hb):
                path = String(StringSlice(unsafe_from_utf8=hb[p + 3:len(hb)]))
            else:
                path = String("(unknown)")
        out.append(ChangedFile(path^, chunk^))
    return out^


def _line_pair_score(a: String, b: String) -> Int:
    """Similarity of two lines for delete↔insert pairing: bytes of shared
    leading prefix plus shared trailing suffix (non-overlapping). Two near-
    identical lines (e.g. one gained a kwarg) score near their full length;
    unrelated lines score only their shared indentation."""
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    var la = len(ab)
    var lb = len(bb)
    var maxn = la if la < lb else lb
    var pre = 0
    while pre < maxn and ab[pre] == bb[pre]:
        pre += 1
    var suf = 0
    while suf < (maxn - pre) and ab[la - 1 - suf] == bb[lb - 1 - suf]:
        suf += 1
    return pre + suf


@fieldwise_init
struct BufferDiffMarks(Copyable, Movable):
    """Result of :func:`diff_buffer_marks`: per-buffer-row change status
    plus the pure-deletion markers, both derived from a single Myers diff
    against HEAD. ``statuses[i]`` is one of ``GIT_CHANGE_NONE/ADDED/
    MODIFIED``; ``deleted_below[i]`` is True when one or more HEAD lines
    were deleted with no replacement immediately *after* buffer row ``i``
    (so the gutter flags the row above with a ``_`` underscore). A pure
    deletion before the very first buffer row has no "row above" to mark
    and is intentionally not surfaced."""
    var statuses: List[Int]
    var deleted_below: List[Bool]

    def __copyinit__(mut self, copy: Self):
        self.statuses = copy.statuses.copy()
        self.deleted_below = copy.deleted_below.copy()


def diff_buffer_against_head(
    head_text: String, buffer_lines: List[String],
) -> List[Int]:
    """Per-buffer-row change status against HEAD — thin wrapper over
    :func:`diff_buffer_marks` returning just the ``GIT_CHANGE_*`` list,
    for callers that don't need the deletion markers."""
    var marks = diff_buffer_marks(head_text, buffer_lines)
    return marks.statuses.copy()


def diff_buffer_marks(
    head_text: String, buffer_lines: List[String],
) -> BufferDiffMarks:
    """Run a Myers line-diff between ``head_text`` (the file at HEAD)
    and ``buffer_lines`` (the editor's in-memory text); return both the
    per-row change status (length ``len(buffer_lines)``, each entry one
    of ``GIT_CHANGE_NONE/ADDED/MODIFIED``) and the per-row pure-deletion
    markers in a single pass.

    Heuristic for added vs. modified: a run of inserts inside a single
    hunk is *modified* when at least one delete preceded it within the
    same run, otherwise *added*. This matches the VS Code / IntelliJ
    change-bar convention.

    A non-equal run that consists *only* of deletes (no inserts) is a
    pure deletion: there's no buffer row to colour, so we instead set
    ``deleted_below`` on the buffer row immediately preceding the run.
    """
    var out = List[Int]()
    var deleted_below = List[Bool]()
    var nb = len(buffer_lines)
    if nb == 0:
        return BufferDiffMarks(out^, deleted_below^)
    for _ in range(nb):
        out.append(GIT_CHANGE_NONE)
        deleted_below.append(False)
    var head_lines = split_lines(head_text)
    var ops = diff_lines(head_lines, buffer_lines)
    var i = 0
    var n = len(ops)
    # Highest buffer row consumed by an equal/insert op so far — the row
    # a following pure-deletion run sits just below. -1 before any row.
    var last_buf_row = -1
    while i < n:
        if ops[i].kind == 0:
            last_buf_row = ops[i].b_index
            i += 1
            continue
        # Buffer row immediately above this non-equal run (captured before
        # the run's own inserts advance ``last_buf_row``).
        var run_anchor = last_buf_row
        # Scan the whole non-equal run first — Myers can emit inserts
        # and deletes in either order within a run, so we can't classify
        # an insert as ADDED vs MODIFIED until we know how many deletes
        # share the run with it.
        var ins_bi = List[Int]()      # buffer rows inserted in this run
        var del_ai = List[Int]()      # head rows deleted in this run
        while i < n and ops[i].kind != 0:
            if ops[i].kind == 1:
                del_ai.append(ops[i].a_index)
            elif 0 <= ops[i].b_index and ops[i].b_index < nb:
                ins_bi.append(ops[i].b_index)
                last_buf_row = ops[i].b_index
            i += 1
        # Pure-deletion run (deletes, no inserts): flag the row above.
        if len(ins_bi) == 0 and len(del_ai) > 0 \
                and run_anchor >= 0 and run_anchor < nb:
            deleted_below[run_anchor] = True
        # ``min(#dels, #ins)`` inserts pair up with deletes → MODIFIED;
        # the surplus are pure ADDED. *Which* inserts pair matters: a
        # comment block inserted just before a genuinely-changed line
        # would, if we just took the first inserts, paint the comment red
        # and the changed line green. Instead pair each delete with the
        # most *similar* insert (longest shared prefix+suffix), so the
        # modified line gets the MODIFIED mark and the inserted block stays
        # ADDED — matching what git's diff anchors to. Deletes-only runs
        # (no inserts) leave no buffer row to mark, like VS Code.
        var pair_count = len(del_ai) if len(del_ai) < len(ins_bi) else len(ins_bi)
        for k in range(len(ins_bi)):
            out[ins_bi[k]] = GIT_CHANGE_ADDED
        if pair_count > 0:
            var scores = List[Int]()
            for k in range(len(ins_bi)):
                var best = -1
                for d in range(len(del_ai)):
                    var ai = del_ai[d]
                    if 0 <= ai and ai < len(head_lines):
                        var s = _line_pair_score(head_lines[ai], buffer_lines[ins_bi[k]])
                        if s > best:
                            best = s
                scores.append(best)
            var used = List[Bool]()
            for _ in range(len(ins_bi)):
                used.append(False)
            var marked = 0
            while marked < pair_count:
                var best_k = -1
                var best_score = -2
                for k in range(len(ins_bi)):
                    if not used[k] and scores[k] > best_score:
                        best_score = scores[k]
                        best_k = k
                if best_k < 0:
                    break
                used[best_k] = True
                out[ins_bi[best_k]] = GIT_CHANGE_MODIFIED
                marked += 1
    return BufferDiffMarks(out^, deleted_below^)


def compute_deletion_revert_block(
    head_text: String, buffer_lines: List[String], marker_row: Int,
) -> Optional[GitRevertBlock]:
    """Counterpart to :func:`compute_revert_block` for the pure-deletion
    marker (the ``_`` underscore). ``marker_row`` is the buffer row the
    underscore sits on — i.e. the row immediately *above* a deleted run.
    Walk the Myers diff, find the pure-deletion run anchored just below
    ``marker_row``, and return a block that re-inserts the removed HEAD
    lines there: an empty buffer range ``[marker_row+1, marker_row+1)``
    (so ``apply_revert_block`` inserts rather than replaces) carrying the
    deleted lines.

    Empty Optional when ``marker_row`` has no pure deletion below it.
    """
    if marker_row < 0:
        return Optional[GitRevertBlock]()
    var head_lines = split_lines(head_text)
    var ops = diff_lines(head_lines, buffer_lines)
    var i = 0
    var n = len(ops)
    var last_buf_row = -1
    while i < n:
        if ops[i].kind == 0:
            last_buf_row = ops[i].b_index
            i += 1
            continue
        var run_anchor = last_buf_row
        var head_start = -1
        var head_end_excl = -1
        var has_ins = False
        while i < n and ops[i].kind != 0:
            if ops[i].kind == 1:
                if head_start == -1:
                    head_start = ops[i].a_index
                head_end_excl = ops[i].a_index + 1
            else:
                has_ins = True
                last_buf_row = ops[i].b_index
            i += 1
        if (not has_ins) and head_start != -1 \
                and run_anchor == marker_row:
            var head_slice = List[String]()
            for k in range(head_start, head_end_excl):
                head_slice.append(head_lines[k])
            return Optional[GitRevertBlock](
                GitRevertBlock(marker_row + 1, marker_row + 1, head_slice^)
            )
    return Optional[GitRevertBlock]()


def fetch_blob_text(
    project_root: String, git_ref: String, rel_path: String,
) -> String:
    """Spawn ``git -C <root> show <git_ref>:<rel_path>`` and return
    stdout.

    Empty string when git can't resolve the blob — ``git_ref`` not
    present, ``rel_path`` not in that ref, or the spawn failed.
    ``git_ref`` can be a commit SHA, ``HEAD``, or empty string (the
    empty ref is git's shorthand for the index — equivalent to ``:0``).

    Callers use this to obtain the "full file" text on the *after* side
    of a diff (so a partial-file diff can be highlighted with full
    multi-line scope context). Untracked files have no after-blob in
    git's eye; for those the worktree file on disk is the right source
    instead.
    """
    if len(project_root.as_bytes()) == 0 or len(rel_path.as_bytes()) == 0:
        return String("")
    var args = List[String]()
    args.append(String("show"))
    args.append(git_ref + String(":") + rel_path)
    return _git_stdout(project_root, args^)


def _git_argv(project_root: String, var args: List[String]) -> List[String]:
    """Build ``git -C <project_root> <args...>`` — the prefix every git
    invocation in this module shares."""
    var argv = List[String]()
    argv.append(String("git"))
    argv.append(String("-C"))
    argv.append(project_root)
    for i in range(len(args)):
        argv.append(args[i])
    return argv^


def _git_stdout(project_root: String, var args: List[String]) -> String:
    """Run ``git -C <root> <args...>``; return stdout, or ``""`` on a
    non-zero exit or spawn failure. The common shape for the read-only
    queries (diffs, status, log, show)."""
    try:
        var r = capture_command(_git_argv(project_root, args^))
        if Int(r.status) != 0:
            return String("")
        return r.stdout
    except:
        return String("")


def _git_ok(
    project_root: String, var args: List[String],
    stdin_text: String = String(""),
) -> Bool:
    """Run ``git -C <root> <args...>`` (optionally feeding ``stdin_text``);
    return ``True`` iff git exited 0. The common shape for the mutating
    commands that only care whether they succeeded."""
    try:
        var r = capture_command(_git_argv(project_root, args^), stdin_text)
        return Int(r.status) == 0
    except:
        return False


def fetch_head_text(project_root: String, file_path: String) -> Optional[String]:
    """Spawn ``git -C <root> show HEAD:<rel>`` and return its stdout.

    Empty Optional when git can't resolve the path at HEAD (file is
    untracked, brand new, or the spawn failed); callers treat that as
    "no baseline → mark every line added", which is the conventional
    change-bar behavior for a new file.
    """
    if len(project_root.as_bytes()) == 0 or len(file_path.as_bytes()) == 0:
        return Optional[String]()
    var rel = project_relative(
        project_root, file_path, canonicalize=True, empty_on_exact=True
    )
    if len(rel.as_bytes()) == 0:
        return Optional[String]()
    var args = List[String]()
    args.append(String("show"))
    args.append(String("HEAD:") + rel^)
    try:
        var result = capture_command(_git_argv(project_root, args^))
        # Non-zero exit = path not in HEAD; treat as "no baseline".
        if Int(result.status) != 0:
            return Optional[String]()
        return Optional[String](result.stdout)
    except:
        return Optional[String]()


def project_is_git_repo(project_root: String) -> Bool:
    """Cheap check: ``True`` iff a ``.git`` entry exists at or above
    ``project_root``. Empty string short-circuits to False."""
    if len(project_root.as_bytes()) == 0:
        return False
    var found = find_git_project(project_root)
    return Bool(found)


@fieldwise_init
struct GitStateMtimes(ImplicitlyCopyable, Movable):
    """Fingerprint of the git state that decides what ``git show
    HEAD:<path>`` returns, polled (~1 Hz) to notice external git operations
    on an open file.

    The subtlety is that ``.git/HEAD`` is only the *symref*
    (``ref: refs/heads/main``) — a plain commit never rewrites it, so
    watching HEAD alone misses commits entirely. The signal that always
    moves on a commit (and on reset / amend / checkout / merge / rebase) is
    the HEAD reflog ``.git/logs/HEAD``, appended to on every HEAD update
    under the default ``core.logAllRefUpdates``. We track its ``mtime`` *and*
    ``size``: the size guards the same-second case (mtime has 1 s
    resolution, but the reflog only ever grows, so two commits in one second
    still differ by size). ``.git/HEAD`` mtime still catches branch switches;
    ``.git/index`` mtime is a backstop (it moves on commit too, and covers
    the rare reflog-disabled repo). All fields are 0 when the file is missing
    or the project isn't a git repo — callers treat ``is_zero()`` as "no
    baseline yet" and skip the first-observation invalidation."""
    var head_mtime: Int64
    var index_mtime: Int64
    var reflog_mtime: Int64
    var reflog_size: Int64

    @staticmethod
    def zero() -> GitStateMtimes:
        return GitStateMtimes(Int64(0), Int64(0), Int64(0), Int64(0))

    def equals(self, other: GitStateMtimes) -> Bool:
        return self.head_mtime == other.head_mtime \
            and self.index_mtime == other.index_mtime \
            and self.reflog_mtime == other.reflog_mtime \
            and self.reflog_size == other.reflog_size

    def is_zero(self) -> Bool:
        return self.head_mtime == Int64(0) and self.index_mtime == Int64(0)


def git_state_mtimes(project_root: String) -> GitStateMtimes:
    """Stat ``.git/HEAD`` and ``.git/index`` and return their mtimes —
    the cheap proxy the desktop polls (~1 Hz) to notice external git
    operations on an open file. Returns zeros for non-repos and for
    ``.git`` entries that are pointer files (submodules / linked
    worktrees) — we don't yet follow ``gitdir:`` redirects."""
    var zero = GitStateMtimes.zero()
    if len(project_root.as_bytes()) == 0:
        return zero
    var found = find_git_project(project_root)
    if not found:
        return zero
    var git_dir = join_path(found.value(), String(".git"))
    var info = stat_file(git_dir)
    if not info.ok or not info.is_dir():
        return zero
    var head = stat_file(join_path(git_dir, String("HEAD")))
    var index = stat_file(join_path(git_dir, String("index")))
    # ``.git/logs/HEAD`` — the HEAD reflog, appended on every commit / reset /
    # amend / checkout, which is what actually changes ``git show HEAD:`` (the
    # symref ``HEAD`` file above does not move on a commit).
    var reflog = stat_file(join_path(git_dir, String("logs/HEAD")))
    var head_mt = head.mtime_sec if head.ok else Int64(0)
    var index_mt = index.mtime_sec if index.ok else Int64(0)
    var reflog_mt = reflog.mtime_sec if reflog.ok else Int64(0)
    var reflog_sz = reflog.size if reflog.ok else Int64(0)
    return GitStateMtimes(head_mt, index_mt, reflog_mt, reflog_sz)


def compute_local_changes(project_root: String) raises -> String:
    """Spawn ``git -C <root> diff HEAD --no-color`` and return stdout.

    ``project_root`` should be the directory holding the ``.git`` entry —
    callers typically pass ``Desktop.project.value()``. Empty string when
    git exits non-zero (no commits, not a repo, …) or when stdout is
    empty (worktree clean).

    Raises only on spawn failure (e.g., git missing from PATH).
    """
    var args = List[String]()
    args.append(String("diff"))
    args.append(String("HEAD"))
    args.append(String("--no-color"))
    var result = capture_command(_git_argv(project_root, args^))
    return result.stdout


def compute_staged_diff(project_root: String) -> String:
    """``git diff --cached --no-color`` — the index versus HEAD. Empty
    string on failure (no commits, not a repo, git missing)."""
    if len(project_root.as_bytes()) == 0:
        return String("")
    var args = List[String]()
    args.append(String("diff"))
    args.append(String("--cached"))
    args.append(String("--no-color"))
    return _git_stdout(project_root, args^)


def compute_unstaged_diff(project_root: String) -> String:
    """``git diff --no-color`` — worktree versus index. Empty on failure."""
    if len(project_root.as_bytes()) == 0:
        return String("")
    var args = List[String]()
    args.append(String("diff"))
    args.append(String("--no-color"))
    return _git_stdout(project_root, args^)


def compute_untracked_diff(project_root: String, rel_path: String) -> String:
    """``git diff --no-index -- /dev/null <rel_path>`` — one untracked
    file's whole contents as an all-additions unified diff.

    Untracked files are invisible to every ``git diff`` that consults the
    index, so this is the only way the changes panel gets real diff text
    for them. Diffing against ``/dev/null`` makes git emit exactly the
    shape it uses for a newly-added tracked file (``new file mode``
    header, ``--- /dev/null``, one ``@@ -0,0 +1,N @@`` hunk), so the
    output drops straight into ``parse_unified_diff_files`` /
    ``build_minimal_patch`` alongside the index-derived diffs.

    ``--no-index`` implies ``--exit-code``, so git returns 1 whenever it
    found a difference — i.e. on every success — which is why this
    can't go through ``_git_stdout``. We take stdout regardless of the
    status and let an empty result mean "nothing to show".

    A zero-byte file yields the ``diff --git`` / ``new file mode`` /
    ``index`` header with no ``---``/``+++`` pair and no hunk — there's
    no content to differ. Renderers already skip those header lines, so
    it displays as a file banner with nothing under it, which is what an
    empty new file is.

    Empty string when the spawn fails, or when ``rel_path`` names a
    directory: ``git status --porcelain`` collapses a wholly-untracked
    directory to a single ``dir/`` entry, and a directory has no diff.
    """
    if len(project_root.as_bytes()) == 0 or len(rel_path.as_bytes()) == 0:
        return String("")
    var pb = rel_path.as_bytes()
    if pb[len(pb) - 1] == 0x2F:      # collapsed untracked directory
        return String("")
    var args = List[String]()
    args.append(String("diff"))
    args.append(String("--no-color"))
    args.append(String("--no-index"))
    args.append(String("--"))
    args.append(String("/dev/null"))
    args.append(rel_path)
    try:
        return capture_command(_git_argv(project_root, args^)).stdout
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


def fetch_git_status(project_root: String) -> List[GitFileStatus]:
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
    var args = List[String]()
    args.append(String("status"))
    args.append(String("--porcelain=v1"))
    args.append(String("-z"))
    var stdout = _git_stdout(project_root, args^)
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


def count_unpushed_commits(project_root: String) -> Int:
    """Number of commits on the current branch that are ahead of its
    upstream — i.e. committed locally but not yet pushed. Runs
    ``git rev-list --count @{upstream}..HEAD``.

    Returns 0 when there's no upstream configured (the branch was never
    pushed / has no tracking remote), when the branch is up to date, or
    when git is unavailable — git exits non-zero in the no-upstream case,
    which ``_git_stdout`` maps to ``""`` → 0. So this is conservatively
    "commits we know are unpushed", not "commits that might be unpushed".
    """
    if len(project_root.as_bytes()) == 0:
        return 0
    var args = List[String]()
    args.append(String("rev-list"))
    args.append(String("--count"))
    args.append(String("@{upstream}..HEAD"))
    var stdout = _git_stdout(project_root, args^)
    var s = stdout.strip()
    if len(s.as_bytes()) == 0:
        return 0
    try:
        return Int(s)
    except:
        return 0


def stage_file(project_root: String, path: String) -> Bool:
    """``git add -- <path>``. Returns False when git is unavailable, the
    path is empty, or git exited non-zero. ``path`` is taken as-is —
    callers should pass repo-relative paths (the same shape ``git
    status`` produces)."""
    if len(project_root.as_bytes()) == 0 or len(path.as_bytes()) == 0:
        return False
    var args = List[String]()
    args.append(String("add"))
    args.append(String("--"))
    args.append(path)
    return _git_ok(project_root, args^)


def unstage_file(project_root: String, path: String) -> Bool:
    """``git restore --staged -- <path>`` (git ≥ 2.23). For pre-existing
    repos this restores the index entry to its HEAD content without
    touching the worktree. Returns False on failure."""
    if len(project_root.as_bytes()) == 0 or len(path.as_bytes()) == 0:
        return False
    var args = List[String]()
    args.append(String("restore"))
    args.append(String("--staged"))
    args.append(String("--"))
    args.append(path)
    return _git_ok(project_root, args^)


def apply_patch_to_index(
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
    var args = List[String]()
    args.append(String("apply"))
    args.append(String("--cached"))
    args.append(String("--recount"))
    if reverse:
        args.append(String("--reverse"))
    args.append(String("-"))
    return _git_ok(project_root, args^, patch)


def apply_patch_to_worktree(
    project_root: String, patch: String, reverse: Bool = False,
) -> Bool:
    """Pipe ``patch`` to ``git apply --recount`` (no ``--cached``) so it
    lands on the working tree instead of the index. Used to discard a
    single unstaged line: build the line's minimal patch and reverse-apply
    it, undoing that worktree change while leaving the rest of the file —
    and the index — untouched. ``--recount`` lets us hand-roll minimal
    hunks without exact @@ counts. Returns False on any non-zero exit
    (the only legitimate failure is "patch doesn't apply", which the
    caller's refresh already reconciles)."""
    if len(project_root.as_bytes()) == 0 or len(patch.as_bytes()) == 0:
        return False
    var args = List[String]()
    args.append(String("apply"))
    args.append(String("--recount"))
    if reverse:
        args.append(String("--reverse"))
    args.append(String("-"))
    return _git_ok(project_root, args^, patch)


@fieldwise_init
struct GitOpResult(ImplicitlyCopyable, Movable):
    """Outcome of a one-shot git command (commit / pull / push / etc).
    ``ok`` is True iff the process exited 0; ``message`` is a short
    human-readable summary the caller can flash in the UI — populated
    from stderr (for failures) or stdout (for successes), trimmed and
    de-newlined so it fits one row."""
    var ok: Bool
    var message: String


def _trim_one_line(s: String) -> String:
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


def git_commit(project_root: String, message: String) -> GitOpResult:
    """``git commit -m <message>``. Reports the first stdout line on
    success (``[main abc1234] subject``) and the first stderr line on
    failure (typically ``nothing to commit`` or a hook complaint)."""
    if len(project_root.as_bytes()) == 0 or len(message.as_bytes()) == 0:
        return GitOpResult(False, String("empty message"))
    var args = List[String]()
    args.append(String("commit"))
    args.append(String("-m"))
    args.append(message)
    try:
        var r = capture_command(_git_argv(project_root, args^))
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


def git_amend_no_edit(project_root: String) -> GitOpResult:
    """``git commit --amend --no-edit``: fold staged changes (or just
    re-touch the commit) into HEAD without prompting for a new message."""
    if len(project_root.as_bytes()) == 0:
        return GitOpResult(False, String("no project"))
    var args = List[String]()
    args.append(String("commit"))
    args.append(String("--amend"))
    args.append(String("--no-edit"))
    try:
        var r = capture_command(_git_argv(project_root, args^))
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


def git_revert_file(
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
    var args = List[String]()
    if untracked:
        args.append(String("clean"))
        args.append(String("-f"))
        args.append(String("--"))
        args.append(path)
    else:
        args.append(String("checkout"))
        args.append(String("HEAD"))
        args.append(String("--"))
        args.append(path)
    try:
        var r = capture_command(_git_argv(project_root, args^))
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


def git_pull(project_root: String) -> GitOpResult:
    """``git pull`` (uses repo defaults — branch tracking, ff/rebase
    settings, etc.). This is a synchronous network call; the surrounding
    UI blocks until it returns."""
    if len(project_root.as_bytes()) == 0:
        return GitOpResult(False, String("no project"))
    var args = List[String]()
    args.append(String("pull"))
    try:
        var r = capture_command(_git_argv(project_root, args^))
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


def git_push(project_root: String) -> GitOpResult:
    """``git push`` (uses repo defaults — remote, branch, upstream).
    Same blocking caveat as ``git_pull``."""
    if len(project_root.as_bytes()) == 0:
        return GitOpResult(False, String("no project"))
    var args = List[String]()
    args.append(String("push"))
    try:
        var r = capture_command(_git_argv(project_root, args^))
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
    short sha its tip points at, the tip commit's subject, whether this
    is the currently checked-out branch (``HEAD``), and the tip commit's
    committer date as a Unix timestamp (seconds).

    ``committer_unix`` is what the branch pane's age column renders and
    what the list is sorted by; it's ``0`` when git didn't report a
    parseable date (never for a real ref, but synthetic rows in tests
    leave it unset)."""
    var name: String
    var short_sha: String
    var subject: String
    var is_current: Bool
    var committer_unix: Int


def format_age(seconds: Int) -> String:
    """Render an age in seconds as the compact form the branch pane
    shows: ``45s``, ``5m``, ``3h``, ``20d``, ``2y``.

    One unit only, truncated toward zero — the column is a glance-level
    "how stale is this branch", not a duration. Minutes take ``m``, so
    months would collide; the ladder goes straight from days to years at
    365 days. A negative age (clock skew, a commit dated in the future)
    clamps to ``0s``."""
    if seconds < 60:
        return String(seconds if seconds > 0 else 0) + String("s")
    if seconds < 3600:
        return String(seconds // 60) + String("m")
    if seconds < 86400:
        return String(seconds // 3600) + String("h")
    if seconds < 86400 * 365:
        return String(seconds // 86400) + String("d")
    return String(seconds // (86400 * 365)) + String("y")


@fieldwise_init
struct GitCommit(ImplicitlyCopyable, Movable):
    """One row of ``git log --pretty=format``. ``date`` is YYYY-MM-DD.
    ``is_pushed`` is True when the commit is reachable from at least one
    remote-tracking ref (i.e. already pushed somewhere); False when it
    only exists locally. With no remotes configured, every commit is
    treated as unpushed. ``tags`` is the space-separated list of tag
    names pointing at this commit (empty when none), parsed from the
    ``%D`` ref decoration. ``parents`` is ``%p`` verbatim — the
    space-separated short SHAs of this commit's parents, which is how
    the view tells a merge from an ordinary commit without a second
    git call."""
    var short_sha: String
    var author: String
    var date: String
    var subject: String
    var is_pushed: Bool
    var tags: String
    var parents: String

    def is_merge(self) -> Bool:
        """True when this commit has more than one parent. ``%p`` is
        space-separated, so counting separators counts parents; the root
        commit has an empty ``parents`` and is not a merge."""
        var b = self.parents.as_bytes()
        for i in range(len(b)):
            if b[i] == 0x20:
                return True
        return False

    def first_parent(self) -> String:
        """The first short SHA in ``parents`` — the mainline side of a
        merge. Empty for a root commit."""
        var b = self.parents.as_bytes()
        for i in range(len(b)):
            if b[i] == 0x20:
                return String(StringSlice(unsafe_from_utf8=b[0:i]))
        return self.parents


@fieldwise_init
struct LineHistoryEntry(ImplicitlyCopyable, Movable):
    """One commit from ``git log -L`` over a selected line range: the
    commit metadata for the left-pane list, plus the unified-diff
    ``patch`` (scoped to that line range) shown in the right pane.
    ``date`` is YYYY-MM-DD; newest commit first. ``is_pushed`` is True
    when the commit is reachable from a remote-tracking ref (already
    pushed); False when it only exists locally — same meaning as on
    :struct:`GitCommit`. ``parse_line_history`` leaves it True; the
    fetch wrapper fills it in from the unpushed-SHA set."""
    var short_sha: String
    var author: String
    var date: String
    var subject: String
    var patch: String
    var is_pushed: Bool


def _split_on_byte(s: String, sep: UInt8) -> List[String]:
    """Split ``s`` into fields on every occurrence of byte ``sep``. The
    result has one more element than there are separators (an empty
    leading/trailing field when ``s`` begins/ends with ``sep``)."""
    var out = List[String]()
    var b = s.as_bytes()
    var start = 0
    for i in range(len(b)):
        if b[i] == sep:
            out.append(String(StringSlice(unsafe_from_utf8=b[start:i])))
            start = i + 1
    out.append(String(StringSlice(unsafe_from_utf8=b[start:len(b)])))
    return out^


def _split_tab_fields(line: String, n: Int) -> List[String]:
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


def fetch_git_branches(project_root: String) -> List[GitBranch]:
    """Run ``git for-each-ref refs/heads`` and parse the output.

    Branches are returned sorted by most recent commit date first. Empty
    list when git is unavailable or the repo has no local branches yet
    (fresh ``git init``)."""
    var out = List[GitBranch]()
    if len(project_root.as_bytes()) == 0:
        return out^
    var args = List[String]()
    args.append(String("for-each-ref"))
    args.append(String("--sort=-committerdate"))
    args.append(
        String(
            "--format=%(HEAD)%09%(refname:short)%09%(objectname:short)"
            "%09%(committerdate:unix)%09%(subject)"
        ),
    )
    args.append(String("refs/heads"))
    var stdout = _git_stdout(project_root, args^)
    var lines = split_lines_no_trailing(stdout)
    for li in range(len(lines)):
        var line = lines[li]
        if len(line.as_bytes()) == 0:
            continue
        var fields = _split_tab_fields(line, 5)
        var marker = fields[0]
        var is_cur = (len(marker.as_bytes()) > 0
                      and marker.as_bytes()[0] == 0x2A)
        # ``%(committerdate:unix)`` is plain seconds; anything else (an
        # ancient git that doesn't know the ``:unix`` modifier and echoes
        # the format back) parses to -1 and shows no age.
        var when = parse_int_all(fields[3])
        out.append(
            GitBranch(fields[1], fields[2], fields[4], is_cur,
                      when if when > 0 else 0),
        )
    return out^


def main_line_branch(project_root: String) -> String:
    """Name of the repo's main line — ``main`` if a local branch by that
    name exists, else ``master``, else the empty string.

    Deliberately local-branch-only: this drives "is it safe to delete
    this branch?", and a remote-tracking ref the user hasn't fetched in
    a month is a bad thing to measure "already merged" against."""
    if len(project_root.as_bytes()) == 0:
        return String("")
    var args = List[String]()
    args.append(String("for-each-ref"))
    args.append(String("--format=%(refname:short)"))
    args.append(String("refs/heads/main"))
    args.append(String("refs/heads/master"))
    var lines = split_lines_no_trailing(_git_stdout(project_root, args^))
    var found_master = False
    for i in range(len(lines)):
        if lines[i] == String("main"):
            return String("main")
        if lines[i] == String("master"):
            found_master = True
    return String("master") if found_master else String("")


comptime _SQUASH_SCAN_COMMITS: Int = 500
"""How far back down the main line :func:`_change_already_landed` will
look for a squash commit. A bound rather than a correctness limit — past
it we just fall through to "ask the user", which is the safe answer."""

comptime _SQUASH_SCAN_MAX_FILES: Int = 512
"""Skip the squash scan for branches touching more files than this,
rather than build an unbounded pathspec argv."""


def _git_stdout_stdin(
    project_root: String, var args: List[String], stdin_text: String,
) -> String:
    """:func:`_git_stdout` with something piped into the child's stdin —
    the shape ``git patch-id`` needs, since it reads a diff rather than
    taking a revision."""
    try:
        var r = capture_command(_git_argv(project_root, args^), stdin_text)
        if Int(r.status) != 0:
            return String("")
        return r.stdout
    except:
        return String("")


def _first_field(line: String) -> String:
    """Everything up to the first space. ``git patch-id`` prints
    ``<patch-id> <commit-id>``; we only ever want the first."""
    var b = line.as_bytes()
    for i in range(len(b)):
        if b[i] == 0x20:
            return String(StringSlice(unsafe_from_utf8=b[0:i]))
    return line


def _merge_base(project_root: String, a: String, b: String) -> String:
    var args = List[String]()
    args.append(String("merge-base"))
    args.append(a)
    args.append(b)
    var lines = split_lines_no_trailing(_git_stdout(project_root, args^))
    return lines[0] if len(lines) > 0 else String("")


def _every_commit_landed(
    project_root: String, main: String, branch: String,
) -> Bool:
    """True when every commit on ``branch`` has an equivalent already on
    ``main``, compared by *patch-id* rather than SHA.

    This is ``git cherry``, which prefixes each commit with ``-`` when an
    equivalent patch is upstream and ``+`` when it isn't. Patch-ids are
    what make a **rebased** or **cherry-picked** branch recognizable:
    the commits were replayed under new SHAs, so ancestry says
    "unmerged", but the content is all there.

    Empty output means git told us nothing about any commit; treated as
    "unknown" (False) rather than as a vacuous yes."""
    var args = List[String]()
    args.append(String("cherry"))
    args.append(main)
    args.append(branch)
    var lines = split_lines_no_trailing(_git_stdout(project_root, args^))
    var saw_one = False
    for i in range(len(lines)):
        var b = lines[i].as_bytes()
        if len(b) == 0:
            continue
        saw_one = True
        if b[0] != 0x2D:            # '-' == equivalent found upstream
            return False
    return saw_one


def _change_already_landed(
    project_root: String, main: String, branch: String, base: String,
) -> Bool:
    """True when the branch's changes, taken as *one* combined diff, are
    already present on ``main`` as a single commit.

    This is the **squash-merge** case, which ``git cherry`` can't see: a
    squash collapses N commits into one, so none of the individual
    patch-ids survive — only their sum does. So we patch-id the branch's
    whole ``base..branch`` diff and look for a commit on main carrying
    exactly that patch.

    The search is restricted to commits touching the files the branch
    touched, which is what keeps it cheap (~40 ms across a 600-commit
    divergence) — a squash commit containing the branch's work must
    touch those paths by definition. Both the file count and the search
    depth are capped; overrunning either returns False, i.e. "ask the
    user"."""
    var name_args = List[String]()
    name_args.append(String("diff"))
    name_args.append(String("--name-only"))
    name_args.append(base)
    name_args.append(branch)
    var files = split_lines_no_trailing(
        _git_stdout(project_root, name_args^),
    )
    if len(files) == 0:
        # The branch's net change against the merge base is empty, so
        # there is by definition nothing in it to lose.
        return True
    if len(files) > _SQUASH_SCAN_MAX_FILES:
        return False
    var diff_args = List[String]()
    diff_args.append(String("diff"))
    diff_args.append(base)
    diff_args.append(branch)
    var combined = _git_stdout(project_root, diff_args^)
    if len(combined.as_bytes()) == 0:
        return False
    var pid_args = List[String]()
    pid_args.append(String("patch-id"))
    pid_args.append(String("--stable"))
    var want_lines = split_lines_no_trailing(
        _git_stdout_stdin(project_root, pid_args^, combined),
    )
    if len(want_lines) == 0:
        return False
    var want = _first_field(want_lines[0])
    if len(want.as_bytes()) == 0:
        return False
    var log_args = List[String]()
    log_args.append(String("log"))
    log_args.append(String("-n"))
    log_args.append(String(_SQUASH_SCAN_COMMITS))
    log_args.append(String("--format=%H"))
    log_args.append(String("-p"))
    log_args.append(base + String("..") + main)
    log_args.append(String("--"))
    for i in range(len(files)):
        log_args.append(files[i])
    var sweep = _git_stdout(project_root, log_args^)
    if len(sweep.as_bytes()) == 0:
        return False
    var scan_args = List[String]()
    scan_args.append(String("patch-id"))
    scan_args.append(String("--stable"))
    var got = split_lines_no_trailing(
        _git_stdout_stdin(project_root, scan_args^, sweep),
    )
    for i in range(len(got)):
        if _first_field(got[i]) == want:
            return True
    return False


def branch_is_merged(project_root: String, branch: String) -> Bool:
    """True when deleting ``branch`` would throw away no work, because
    its changes are already on the repo's main line
    (:func:`main_line_branch`).

    Three checks, cheapest first, stopping at the first yes:

    1. **Ancestry** (``merge-base --is-ancestor``) — an ordinary merge or
       fast-forward, where the branch's commits are literally in main.
    2. **Per-commit patch-ids** (``git cherry``) — catches a **rebased**
       or **cherry-picked** branch, whose commits were replayed under new
       SHAs. Also catches a squash-merge of a single-commit branch, since
       one commit squashed is the same patch.
    3. **Combined patch-id** — catches a **squash-merge** of a
       multi-commit branch, where only the sum of the commits survived.

    Everything is content-based from step 2 on, so this answers "is this
    work in main?" rather than git's own "is this commit in main?" —
    which is why ``git branch -d`` refuses branches this function
    happily calls merged.

    Conservative in every uncertain direction, because False just means
    "make the user confirm": no ``main`` / ``master`` to measure against,
    the main line *itself* (trivially its own ancestor, and never
    something to delete on a bare keystroke), an unreadable merge base,
    or a branch too large for the squash scan's caps all report False."""
    if len(project_root.as_bytes()) == 0 or len(branch.as_bytes()) == 0:
        return False
    var main = main_line_branch(project_root)
    if len(main.as_bytes()) == 0 or main == branch:
        return False
    var anc = List[String]()
    anc.append(String("merge-base"))
    anc.append(String("--is-ancestor"))
    anc.append(branch)
    anc.append(main)
    if _git_ok(project_root, anc^):
        return True
    if _every_commit_landed(project_root, main, branch):
        return True
    var base = _merge_base(project_root, main, branch)
    if len(base.as_bytes()) == 0:
        return False
    return _change_already_landed(project_root, main, branch, base)


def _fetch_unpushed_short_shas(
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
    var args = List[String]()
    args.append(String("rev-list"))
    args.append(String("-") + String(limit))
    args.append(String("HEAD"))
    args.append(String("--not"))
    args.append(String("--remotes"))
    args.append(String("--abbrev-commit"))
    var stdout = _git_stdout(project_root, args^)
    var lines = split_lines_no_trailing(stdout)
    for li in range(len(lines)):
        var line = lines[li]
        if len(line.as_bytes()) > 0:
            out.append(line)
    return out^


def _list_contains(shas: List[String], sha: String) -> Bool:
    for i in range(len(shas)):
        if shas[i] == sha:
            return True
    return False


def _extract_tags(decoration: String) -> String:
    """Pull tag names out of a ``%D`` ref decoration string. ``%D`` is a
    comma+space separated list of refs like
    ``HEAD -> main, tag: v1.0, tag: v1.1, origin/main``; we keep only the
    ``tag: <name>`` entries and return their names joined by a single
    space (empty string when the commit carries no tags)."""
    var tags = String("")
    var parts = _split_on_byte(decoration, 0x2C)  # ','
    for i in range(len(parts)):
        var p = String(parts[i].strip())
        if not p.startswith("tag: "):
            continue
        var pb = p.as_bytes()
        var name = String(
            StringSlice(unsafe_from_utf8=pb[5:len(pb)]),
        ).strip()
        if len(name.as_bytes()) == 0:
            continue
        if len(tags.as_bytes()) > 0:
            tags += String(" ")
        tags += String(name)
    return tags^


def fetch_git_commits(
    project_root: String, limit: Int = 50,
) -> List[GitCommit]:
    """Run ``git log -<limit> --pretty=format``. The newest commit is
    first. Empty list on failure. Each entry's ``is_pushed`` is set
    based on whether the commit is reachable from any remote-tracking
    ref (cross-checked via :func:`_fetch_unpushed_short_shas`)."""
    var out = List[GitCommit]()
    if len(project_root.as_bytes()) == 0:
        return out^
    var args = List[String]()
    args.append(String("log"))
    args.append(String("-") + String(limit))
    args.append(String("--no-color"))
    args.append(String("--date=short"))
    # ``%D`` (ref decoration) and ``%p`` (parents) sit before ``%s`` so the
    # subject stays the tab-absorbing last field; neither ever contains a
    # tab itself.
    args.append(String("--pretty=format:%h%x09%an%x09%ad%x09%D%x09%p%x09%s"))
    var stdout = _git_stdout(project_root, args^)
    var unpushed = _fetch_unpushed_short_shas(project_root, limit)
    var lines = split_lines_no_trailing(stdout)
    for li in range(len(lines)):
        var line = lines[li]
        if len(line.as_bytes()) == 0:
            continue
        var fields = _split_tab_fields(line, 6)
        var pushed = not _list_contains(unpushed, fields[0])
        var tags = _extract_tags(fields[3])
        out.append(
            GitCommit(
                fields[0], fields[1], fields[2], fields[5], pushed, tags,
                fields[4],
            ),
        )
    return out^


def fetch_commit_show(project_root: String, sha: String) -> String:
    """Run ``git show <sha> --no-color`` and return its full output
    (header + unified diff). Used as the right-pane content when the
    user focuses a commit in the local-changes view.

    ``--first-parent`` is what makes merge commits show anything at all.
    Bare ``git show`` on a merge prints the header and then *stops*: with
    several parents there's no single "before" to diff against, so git
    declines to guess and the right pane came up empty — the one commit
    in the log you most want to inspect rendered as the one commit with
    no content. ``--first-parent`` picks the mainline parent, which makes
    the diff exactly "what this merge brought into this branch". On an
    ordinary single-parent commit the flag is a no-op."""
    if len(project_root.as_bytes()) == 0 or len(sha.as_bytes()) == 0:
        return String("")
    var args = List[String]()
    args.append(String("show"))
    args.append(String("--no-color"))
    args.append(String("--first-parent"))
    args.append(sha)
    return _git_stdout(project_root, args^)


def fetch_merged_commits(
    project_root: String, sha: String, limit: Int = 200,
) -> String:
    """The commits a merge commit brought in, newest first, formatted the
    same way :func:`fetch_branch_log` formats a branch log.

    ``git log <sha>^@ --not <sha>^1`` reads as "everything reachable from
    any parent, minus everything reachable from the mainline parent" —
    i.e. the side branch's own commits, without the merge commit itself
    and without the mainline history it was merged into. ``^@`` covers
    every parent, so an octopus merge lists all of its sides.

    Empty string for a non-merge commit (its ``^2`` doesn't resolve, git
    exits non-zero, and :func:`_git_stdout` maps that to ``""``)."""
    if len(project_root.as_bytes()) == 0 or len(sha.as_bytes()) == 0:
        return String("")
    var args = List[String]()
    args.append(String("log"))
    args.append(String("-") + String(limit))
    args.append(String("--no-color"))
    args.append(String("--date=short"))
    args.append(String("--pretty=format:%h  %ad  %an%n    %s%n"))
    args.append(sha + String("^@"))
    args.append(String("--not"))
    args.append(sha + String("^1"))
    return _git_stdout(project_root, args^)


def fetch_line_history(
    project_root: String, rel_path: String,
    start_line: Int, end_line: Int, limit: Int = 200,
) -> List[LineHistoryEntry]:
    """Run ``git -C <root> log -L<start>,<end>:<rel>`` and return the
    history of the selected line range, newest first — the "show history
    for selection" feature. ``git log -L`` follows the lines across
    renames automatically.

    The ``--format`` below makes each commit's header
    ``\\x1e<sha>\\x1f<author>\\x1f<date>\\x1f<subject>\\n``: an ASCII RS
    (0x1e) prefixes every commit and US (0x1f) separates the fields, so
    the blocks parse cleanly regardless of what the diff body contains.
    The range-scoped patch follows the header up to the next RS.

    Empty list when the file is untracked, has no history in this range,
    or the path lies outside a git repo."""
    var out = List[LineHistoryEntry]()
    if len(project_root.as_bytes()) == 0 or len(rel_path.as_bytes()) == 0:
        return out^
    var lo = start_line if start_line >= 1 else 1
    var hi = end_line if end_line >= lo else lo
    var args = List[String]()
    args.append(String("log"))
    args.append(
        String("-L") + String(lo) + String(",") + String(hi)
        + String(":") + rel_path
    )
    args.append(String("--no-color"))
    args.append(String("--date=short"))
    args.append(String("-") + String(limit))
    args.append(String("--format=%x1e%h%x1f%an%x1f%ad%x1f%s"))
    var entries = parse_line_history(_git_stdout(project_root, args^))
    # Flag local-only commits so the list can mark them — same
    # unpushed set the commits pane uses, abbreviated to match ``%h``.
    var unpushed = _fetch_unpushed_short_shas(project_root, limit)
    for i in range(len(entries)):
        entries[i].is_pushed = not _list_contains(unpushed, entries[i].short_sha)
    return entries^


def parse_line_history(stdout: String) -> List[LineHistoryEntry]:
    """Parse ``git log -L`` output formatted by :func:`fetch_line_history`
    into per-commit entries. Factored out so it's unit-testable without a
    repo. Each commit block starts at an RS (0x1E) byte; its header (up to
    the first newline) holds four US-separated (0x1F) fields, and the
    range-scoped patch is the remainder of the block."""
    var out = List[LineHistoryEntry]()
    # The first split element is the empty text before the leading RS, so
    # blank blocks are skipped.
    var blocks = _split_on_byte(stdout, 0x1E)
    for bi in range(len(blocks)):
        var bb = blocks[bi].as_bytes()
        if len(bb) == 0:
            continue
        var nl = -1
        for i in range(len(bb)):
            if bb[i] == 0x0A:
                nl = i
                break
        var header: String
        var patch: String
        if nl < 0:
            header = String(StringSlice(unsafe_from_utf8=bb[0:len(bb)]))
            patch = String("")
        else:
            header = String(StringSlice(unsafe_from_utf8=bb[0:nl]))
            patch = String(StringSlice(unsafe_from_utf8=bb[nl + 1:len(bb)]))
        var fields = _split_on_byte(header, 0x1F)
        while len(fields) < 4:
            fields.append(String(""))
        out.append(
            LineHistoryEntry(
                fields[0], fields[1], fields[2], fields[3], patch^, True,
            ),
        )
    return out^


def fetch_branch_log(
    project_root: String, branch: String, limit: Int = 30,
) -> String:
    """Run ``git log -<limit> --no-color <branch>`` and return stdout.

    Used as the right-pane content when a branch is focused. We render
    the raw ``git log`` output so the user gets author / date / subject
    in one paint, the same shape they'd see at the shell."""
    if len(project_root.as_bytes()) == 0 or len(branch.as_bytes()) == 0:
        return String("")
    var args = List[String]()
    args.append(String("log"))
    args.append(String("-") + String(limit))
    args.append(String("--no-color"))
    args.append(String("--date=short"))
    args.append(
        String("--pretty=format:%h  %ad  %an%n    %s%n"),
    )
    args.append(branch)
    return _git_stdout(project_root, args^)
