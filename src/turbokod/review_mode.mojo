"""ReviewMode: a distraction-free, full-screen changeset reviewer.

Unlike ``LocalChanges`` (a lazygit-style multi-pane modal built for
*staging* individual lines), ReviewMode is built for *reading* a change
file-by-file. The user picks a changeset — unstaged, staged, a specific
commit (the picker's Commits tab), or a whole branch diffed against the
main line (the Branches tab) — and steps through it.

ReviewMode itself is only the **picker + navigation chrome + changeset
model**: it enumerates the changed files (path + before/after text per
file) and tracks which file is current. The *body* is a real, focused
``Editor`` window hosted by the ``Desktop`` (see ``_review_sync_window``
in ``desktop.mojo``) — so the review surface gets editing (for unstaged),
cmd+click jump-to-definition, hover, diagnostics, completion, the git
gutter, change-chunk navigation, line numbers, and the inline-diff revert
popup that shows removed lines, all for free from the normal editor path.

Per review type:
* **unstaged** — the real worktree file, editable + savable;
* **staged / commit / branch** — a read-only buffer of the historical blob.

The diff baseline is pinned to each file's "before" text so the gutter +
change navigation reflect the picked changeset rather than HEAD.

Cross-file jumps (a cmd+click resolving into another file) open a normal
editor and *suspend* review; re-entering review restores the remembered
changeset + file via the in-session position memory below.

This is a frontend-agnostic, in-grid surface (``Canvas`` out, ``Event``
in) like every other modal, so it works in both the terminal and native
macOS frontends with no host-specific code.
"""

from .canvas import Canvas, paint_drop_shadow
from .cell import Cell
from .colors import Attr, BLACK, CYAN, DARK_GRAY, GREEN, LIGHT_GRAY, WHITE
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE, KEY_TAB,
    KEY_DOWN, KEY_END, KEY_ENTER, KEY_ESC, KEY_HOME, KEY_LEFT, KEY_RIGHT,
    KEY_PAGEDOWN, KEY_PAGEUP, KEY_UP,
    MOD_CTRL, MOD_META, MOD_SHIFT,
    MOUSE_BUTTON_LEFT, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .diff import (
    DIFF_ROW_ADDED, DIFF_ROW_CONTEXT, DIFF_ROW_REMOVED, build_diff_rows,
)
from .file_io import join_path, read_file
from .geometry import Point, Rect
from .git_changes import (
    ChangedFile, compute_range_diff, compute_staged_diff,
    compute_unstaged_diff, compute_untracked_diff, fetch_blob_text,
    fetch_commit_show, fetch_git_branches, fetch_git_commits,
    fetch_git_status, main_line_branch, merge_base,
    parse_unified_diff_files, split_show_output,
)
from .painter import Painter
from .string_utils import display_columns, split_lines_no_trailing, starts_with


# --- sub-states -------------------------------------------------------------
comptime _MODE_PICKER: Int = 0
comptime _MODE_REVIEW: Int = 1

# --- changeset sources ------------------------------------------------------
comptime _SRC_UNSTAGED: Int = 0
comptime _SRC_STAGED:   Int = 1
comptime _SRC_COMMIT:   Int = 2
comptime _SRC_BRANCH:   Int = 3

# --- picker tabs ------------------------------------------------------------
comptime _TAB_COMMITS:  Int = 0
comptime _TAB_BRANCHES: Int = 1

# Number of recent commits offered in the picker.
comptime _COMMIT_LIMIT: Int = 30


def _extract_diff_part(show_text: String) -> String:
    """The multi-file unified diff part of ``git show`` output. Used only
    to recover the *file list* of a commit (the content comes from
    blobs); empty when the commit has no diff."""
    return split_show_output(show_text)[1]


def _diff_is_binary(diff_text: String) -> Bool:
    """``True`` when git reported this file as binary (no text diff to
    splice). Such files get a one-line placeholder instead of content."""
    var lines = split_lines_no_trailing(diff_text)
    for i in range(len(lines)):
        if starts_with(lines[i], String("Binary files ")):
            return True
        if starts_with(lines[i], String("GIT binary patch")):
            return True
    return False


def _diff_is_deletion(diff_text: String) -> Bool:
    """``True`` when this file's diff deletes it outright. The review body
    for such a file is a read-only empty buffer with the old content woven
    in as removed lines — there's no worktree file left to edit."""
    var lines = split_lines_no_trailing(diff_text)
    for i in range(len(lines)):
        if starts_with(lines[i], String("deleted file mode")):
            return True
        if lines[i] == String("+++ /dev/null"):
            return True
    return False


def _diff_is_addition(diff_text: String) -> Bool:
    """``True`` when this file's diff creates it (incl. untracked files,
    whose ``--no-index`` diff carries the same header)."""
    var lines = split_lines_no_trailing(diff_text)
    for i in range(len(lines)):
        if starts_with(lines[i], String("new file mode")):
            return True
        if lines[i] == String("--- /dev/null"):
            return True
        if starts_with(lines[i], String("@@")):
            return False
    return False


def _untracked_paths(root: String) -> List[String]:
    """Repo-relative paths of the untracked (``??``) files. ``git diff``
    never reports them, but to a reviewer a brand-new file is as much a
    part of the unstaged changes as an edited one."""
    var out = List[String]()
    var statuses = fetch_git_status(root)
    for i in range(len(statuses)):
        if Int(statuses[i].staged) == 0x3F and Int(statuses[i].worktree) == 0x3F:
            out.append(statuses[i].path)
    return out^


def _add_untracked(mut changed: List[ChangedFile], root: String):
    """Merge the untracked files into ``changed`` as all-additions diffs,
    keeping the list in path order (both git sources are already sorted)."""
    var paths = _untracked_paths(root)
    for i in range(len(paths)):
        var cf = ChangedFile(paths[i], compute_untracked_diff(root, paths[i]))
        var at = len(changed)
        for j in range(len(changed)):
            if changed[j].path > paths[i]:
                at = j
                break
        changed.insert(at, cf)


def _count_changed_lines(before: String, after: String, is_binary: Bool) -> Int:
    """Number of changed (added + removed) rows in the unified diff between
    ``before`` and ``after`` — the same rows the diff view renders as
    changes. Drives each file's share of the line-weighted progress bar.
    Binary files count 0 (no line-level diff)."""
    if is_binary:
        return 0
    var rows = build_diff_rows(
        split_lines_no_trailing(before), split_lines_no_trailing(after),
    )
    var c = 0
    for i in range(len(rows)):
        if rows[i].kind != DIFF_ROW_CONTEXT:
            c += 1
    return c


struct ReviewMode(Movable):
    var active: Bool
    var mode: Int
    var root: String

    # Picker state. Two tabs (Commits, Branches), each three parallel
    # lists: option label, source kind, and ref — a commit SHA, a branch
    # name, or empty for the unstaged / staged rows. ``picker_*`` is the
    # *shown* tab's lists; ``_tab_*`` hold both, indexed by tab.
    var picker_labels: List[String]
    var picker_kind: List[Int]
    var picker_sha: List[String]
    var picker_cursor: Int
    var picker_tab: Int
    var _tab_labels: List[List[String]]
    var _tab_kind: List[List[Int]]
    var _tab_sha: List[List[String]]
    var _tab_cursor: List[Int]
    # The main line (``main`` / ``master``) branches are diffed against;
    # empty when the repo has neither.
    var main_branch: String

    # Current changeset. ``src`` / ``sha`` identify it; the parallel
    # ``file_*`` lists hold one entry per changed file. ``cur_file`` is
    # the file currently hosted in the editor body.
    var src: Int
    var sha: String
    var title: String
    var file_paths: List[String]    # repo-relative
    var file_before: List[String]
    var file_after: List[String]
    var file_binary: List[Bool]
    # True for a file the changeset deletes — its body is read-only.
    var file_deleted: List[Bool]
    # True for a file the changeset creates (incl. untracked files).
    var file_added: List[Bool]
    # Bumped whenever the file list is rebuilt, so the host can tell when
    # anything derived from it (the review file tree) is stale.
    var model_gen: Int
    # Changed (added + modified) line count per file, computed once at build.
    # Drives the line-weighted progress bar: a file's / change's share of the
    # bar is proportional to how many lines it touches, not just its count.
    var file_changed_lines: List[Int]
    var cur_file: Int

    # In-file change counter, fed by the host each frame from the hosted
    # editor's git-change chunks so the toolbar can show "change z of w".
    # ``cur_file_cum_lines`` is the changed-line count from the file's top
    # through the *current* change chunk — the within-file part of the
    # line-weighted progress.
    var change_index: Int
    var change_total: Int
    var cur_file_cum_lines: Int
    # Cache for ``changed_lines_through``: a prefix-sum of changed diff rows
    # (added + removed, the same basis as ``file_changed_lines``) by after-file
    # row, rebuilt only when the hosted file changes. ``_cum_file`` is the file
    # index the cache is valid for (-1 = stale); ``_cum_prefix[b]`` is the number
    # of changed rows anchored at after-rows ``< b``, so ``_cum_prefix[last]``
    # equals the file's total (→ the bar hits 100% on the final change).
    var _cum_file: Int
    var _cum_prefix: List[Int]
    # Navigation intent set by the toolbar / keys and drained by the host:
    # +1 = next change, -1 = previous change. The host walks change-to-
    # change in the hosted editor and rolls into the next/prev file when a
    # file's changes run out (the editor itself can't cross files).
    var pending_nav: Int

    # In-session position memory, keyed *per changeset* (root + src + sha):
    # picking a changeset again — e.g. after a cross-file jump suspended
    # review — lands back on the file you were on. The picker is always
    # shown on open; memory only restores the file *within* a chosen
    # changeset. ``mem_keys`` / ``mem_files`` are parallel.
    var mem_keys: List[String]
    var mem_files: List[Int]
    # Key of the most-recently-entered changeset, so the picker can
    # pre-select it on re-open — making it one Enter to resume the review
    # you were in the middle of. Empty until the first review.
    var last_key: String

    # Geometry stamped by ``paint`` so event handling can hit-test the
    # toolbar buttons. ``-1`` until painted.
    var tb_y: Int
    var tb_prev_lo: Int
    var tb_prev_hi: Int
    var tb_next_lo: Int
    var tb_next_hi: Int
    var pk_y0: Int
    var pk_x0: Int
    var pk_x1: Int
    var pk_first: Int   # first label index shown (the list scrolls)
    var pk_rows: Int    # label rows that fit in the box
    var pk_tab_y: Int   # tab-header row
    var pk_tab_lo: List[Int]  # per-tab header x-span [lo, hi)
    var pk_tab_hi: List[Int]

    def __init__(out self):
        self.active = False
        self.mode = _MODE_PICKER
        self.root = String("")
        self.picker_labels = List[String]()
        self.picker_kind = List[Int]()
        self.picker_sha = List[String]()
        self.picker_cursor = 0
        self.picker_tab = _TAB_COMMITS
        self._tab_labels = List[List[String]]()
        self._tab_kind = List[List[Int]]()
        self._tab_sha = List[List[String]]()
        self._tab_cursor = List[Int]()
        self.main_branch = String("")
        self.src = _SRC_UNSTAGED
        self.sha = String("")
        self.title = String("")
        self.file_paths = List[String]()
        self.file_before = List[String]()
        self.file_after = List[String]()
        self.file_binary = List[Bool]()
        self.file_deleted = List[Bool]()
        self.file_added = List[Bool]()
        self.model_gen = 0
        self.file_changed_lines = List[Int]()
        self.cur_file = 0
        self.change_index = 0
        self.change_total = 0
        self.cur_file_cum_lines = 0
        self._cum_file = -1
        self._cum_prefix = List[Int]()
        self.pending_nav = 0
        self.mem_keys = List[String]()
        self.mem_files = List[Int]()
        self.last_key = String("")
        self.tb_y = -1
        self.tb_prev_lo = -1
        self.tb_prev_hi = -1
        self.tb_next_lo = -1
        self.tb_next_hi = -1
        self.pk_y0 = -1
        self.pk_x0 = -1
        self.pk_x1 = -1
        self.pk_first = 0
        self.pk_rows = 0
        self.pk_tab_y = -1
        self.pk_tab_lo = List[Int]()
        self.pk_tab_hi = List[Int]()

    # --- lifecycle --------------------------------------------------------

    def open(mut self, var root: String):
        """Arm review for ``root``. Always shows the picker — the user
        chooses which changeset every time. Position memory only restores
        the file *within* a changeset once it's picked (see
        ``_start_review``)."""
        self.root = root^
        self.active = True
        self.mode = _MODE_PICKER
        self._reset_review()
        self._build_picker()
        # Pre-select the changeset we last reviewed (if it's still listed,
        # on whichever tab), so Enter resumes it; otherwise start at the top
        # of the Commits tab.
        var tab = _TAB_COMMITS
        for t in range(len(self._tab_labels)):
            for i in range(len(self._tab_labels[t])):
                if self._key_for(self._tab_kind[t][i], self._tab_sha[t][i]) \
                        == self.last_key:
                    tab = t
                    self._tab_cursor[t] = i
        self.picker_tab = -1   # nothing shown yet — keep the pre-selection
        self._show_tab(tab)

    def close(mut self):
        """Deactivate, remembering the current file for this changeset so a
        later re-pick of the same changeset restores it. Host-side window
        cleanup is separate (see ``_review_teardown`` in ``desktop.mojo``)."""
        self._remember()
        self.active = False
        self.picker_labels = List[String]()
        self.picker_kind = List[Int]()
        self.picker_sha = List[String]()
        self._tab_labels = List[List[String]]()
        self._tab_kind = List[List[Int]]()
        self._tab_sha = List[List[String]]()
        self._tab_cursor = List[Int]()
        self._reset_review()

    def _key_for(self, kind: Int, sha: String) -> String:
        return (
            self.root + String("\x00") + String(kind) + String("\x00") + sha
        )

    def _mem_key(self) -> String:
        return self._key_for(self.src, self.sha)

    def _remember(mut self):
        """Record the current file index for the current changeset."""
        if self.mode != _MODE_REVIEW or self.file_count() == 0:
            return
        var k = self._mem_key()
        for i in range(len(self.mem_keys)):
            if self.mem_keys[i] == k:
                self.mem_files[i] = self.cur_file
                return
        self.mem_keys.append(k)
        self.mem_files.append(self.cur_file)

    def _recall_file(self) -> Int:
        """Remembered file index for the current changeset, or 0."""
        var k = self._mem_key()
        for i in range(len(self.mem_keys)):
            if self.mem_keys[i] == k:
                return self.mem_files[i]
        return 0

    def _reset_review(mut self):
        self.title = String("")
        self.file_paths = List[String]()
        self.file_before = List[String]()
        self.file_after = List[String]()
        self.file_binary = List[Bool]()
        self.file_deleted = List[Bool]()
        self.file_added = List[Bool]()
        self.model_gen += 1
        # Must be cleared too — ``_build_model`` *appends* to it, so leaving
        # stale entries here would misalign it with ``file_paths`` and inflate
        # the progress-bar denominator on every re-opened review.
        self.file_changed_lines = List[Int]()
        self.cur_file = 0
        self.change_index = 0
        self.change_total = 0
        self.cur_file_cum_lines = 0
        self._cum_file = -1
        self._cum_prefix = List[Int]()

    def _build_picker(mut self):
        self.picker_labels = List[String]()
        self.picker_kind = List[Int]()
        self.picker_sha = List[String]()
        # Commits tab: unstaged / staged + recent commits.
        # Only offer the unstaged / staged entries when there's actually a
        # diff on that side — an empty ``git diff`` would just open a blank
        # reviewer, so don't list it. New untracked files count as unstaged.
        if len(compute_unstaged_diff(self.root).as_bytes()) > 0 \
                or len(_untracked_paths(self.root)) > 0:
            self.picker_labels.append(String("Unstaged changes"))
            self.picker_kind.append(_SRC_UNSTAGED)
            self.picker_sha.append(String(""))
        if len(compute_staged_diff(self.root).as_bytes()) > 0:
            self.picker_labels.append(String("Staged changes"))
            self.picker_kind.append(_SRC_STAGED)
            self.picker_sha.append(String(""))
        var commits = fetch_git_commits(self.root, _COMMIT_LIMIT)
        for i in range(len(commits)):
            var c = commits[i]
            self.picker_labels.append(c.short_sha + String("  ") + c.subject)
            self.picker_kind.append(_SRC_COMMIT)
            self.picker_sha.append(c.short_sha)
        self._tab_labels = List[List[String]]()
        self._tab_kind = List[List[Int]]()
        self._tab_sha = List[List[String]]()
        self._tab_cursor = List[Int]()
        self._tab_labels.append(self.picker_labels.copy())
        self._tab_kind.append(self.picker_kind.copy())
        self._tab_sha.append(self.picker_sha.copy())
        self._tab_cursor.append(0)
        # Branches tab: every local branch but the main line, each diffed
        # as a whole against where it forked from main.
        var b_labels = List[String]()
        var b_kind = List[Int]()
        var b_sha = List[String]()
        self.main_branch = main_line_branch(self.root)
        if len(self.main_branch.as_bytes()) > 0:
            var branches = fetch_git_branches(self.root)
            for i in range(len(branches)):
                if branches[i].name == self.main_branch:
                    continue
                b_labels.append(
                    branches[i].name + String("  ") + branches[i].subject
                )
                b_kind.append(_SRC_BRANCH)
                b_sha.append(branches[i].name)
        self._tab_labels.append(b_labels^)
        self._tab_kind.append(b_kind^)
        self._tab_sha.append(b_sha^)
        self._tab_cursor.append(0)

    def _show_tab(mut self, tab: Int):
        """Make ``tab`` the shown picker tab, remembering the cursor of the
        one it replaces so flipping back and forth keeps each tab's place."""
        if tab < 0 or tab >= len(self._tab_labels):
            return
        if 0 <= self.picker_tab and self.picker_tab < len(self._tab_cursor):
            self._tab_cursor[self.picker_tab] = self.picker_cursor
        self.picker_tab = tab
        self.picker_labels = self._tab_labels[tab].copy()
        self.picker_kind = self._tab_kind[tab].copy()
        self.picker_sha = self._tab_sha[tab].copy()
        self.picker_cursor = self._tab_cursor[tab]
        if self.picker_cursor >= len(self.picker_labels):
            self.picker_cursor = 0

    def _start_review(mut self):
        if self.picker_cursor < 0 or self.picker_cursor >= len(self.picker_labels):
            return
        self.src = self.picker_kind[self.picker_cursor]
        self.sha = self.picker_sha[self.picker_cursor]
        self.title = self.picker_labels[self.picker_cursor]
        if self.src == _SRC_BRANCH:
            self.title = self.sha + String(" vs ") + self.main_branch
        self.last_key = self._mem_key()
        self._build_model()
        # Restore the file we were last on for this changeset (if any).
        self.cur_file = self._recall_file()
        if self.cur_file < 0 or self.cur_file >= self.file_count():
            self.cur_file = 0
        self.change_index = 0
        self.change_total = 0
        self.mode = _MODE_REVIEW

    # --- model build ------------------------------------------------------

    def _build_model(mut self):
        """Enumerate the changed files for ``src`` / ``sha`` and capture
        each file's before/after text. The body editor is built from these
        by the host."""
        self._reset_review()
        var diff_text: String
        # A branch is diffed from its fork point with the main line, so
        # main's own later commits don't show up as reverse changes.
        var base = String("")
        if self.src == _SRC_BRANCH:
            base = merge_base(self.root, self.main_branch, self.sha)
            if len(base.as_bytes()) == 0:
                base = self.main_branch
        if self.src == _SRC_UNSTAGED:
            diff_text = compute_unstaged_diff(self.root)
        elif self.src == _SRC_STAGED:
            diff_text = compute_staged_diff(self.root)
        elif self.src == _SRC_BRANCH:
            diff_text = compute_range_diff(self.root, base, self.sha)
        else:
            diff_text = _extract_diff_part(fetch_commit_show(self.root, self.sha))
        var changed = parse_unified_diff_files(diff_text)
        if self.src == _SRC_UNSTAGED:
            _add_untracked(changed, self.root)
        for fi in range(len(changed)):
            var cf = changed[fi]
            var is_binary = _diff_is_binary(cf.diff)
            var before = String("")
            var after = String("")
            if not is_binary:
                if self.src == _SRC_UNSTAGED:
                    # after = worktree file, before = index blob.
                    before = fetch_blob_text(self.root, String(""), cf.path)
                    try:
                        after = read_file(join_path(self.root, cf.path))
                    except:
                        after = String("")
                elif self.src == _SRC_STAGED:
                    # after = index blob, before = HEAD blob.
                    before = fetch_blob_text(self.root, String("HEAD"), cf.path)
                    after = fetch_blob_text(self.root, String(""), cf.path)
                elif self.src == _SRC_BRANCH:
                    # after = branch tip blob, before = fork-point blob.
                    before = fetch_blob_text(self.root, base, cf.path)
                    after = fetch_blob_text(self.root, self.sha, cf.path)
                else:
                    # after = commit blob, before = parent blob (empty for
                    # a file's first appearance → shows as all-added).
                    before = fetch_blob_text(
                        self.root, self.sha + String("~1"), cf.path,
                    )
                    after = fetch_blob_text(self.root, self.sha, cf.path)
            self.file_paths.append(cf.path)
            self.file_before.append(before)
            self.file_after.append(after)
            self.file_binary.append(is_binary)
            self.file_deleted.append(_diff_is_deletion(cf.diff))
            self.file_added.append(_diff_is_addition(cf.diff))
            self.file_changed_lines.append(
                _count_changed_lines(before, after, is_binary)
            )

    def build_from_pairs(
        mut self,
        paths: List[String], befores: List[String], afters: List[String],
    ):
        """Populate the changeset model from explicit before/after texts —
        the deterministic, git-free entry point for tests. ``paths`` /
        ``befores`` / ``afters`` are parallel."""
        self._reset_review()
        for i in range(len(paths)):
            self.file_paths.append(paths[i])
            self.file_before.append(befores[i])
            self.file_after.append(afters[i])
            self.file_binary.append(False)
            self.file_deleted.append(
                len(afters[i].as_bytes()) == 0
                and len(befores[i].as_bytes()) > 0
            )
            self.file_added.append(
                len(befores[i].as_bytes()) == 0
                and len(afters[i].as_bytes()) > 0
            )
            self.file_changed_lines.append(
                _count_changed_lines(befores[i], afters[i], False)
            )

    # --- host-facing API --------------------------------------------------

    def is_reviewing(self) -> Bool:
        """True when active and past the picker (the body editor is live)."""
        return self.active and self.mode == _MODE_REVIEW

    def file_count(self) -> Int:
        return len(self.file_paths)

    def current_path(self) -> String:
        """Repo-relative path of the current file (empty when none)."""
        if 0 <= self.cur_file and self.cur_file < len(self.file_paths):
            return self.file_paths[self.cur_file]
        return String("")

    def current_before(self) -> String:
        if 0 <= self.cur_file and self.cur_file < len(self.file_before):
            return self.file_before[self.cur_file]
        return String("")

    def current_after(self) -> String:
        if 0 <= self.cur_file and self.cur_file < len(self.file_after):
            return self.file_after[self.cur_file]
        return String("")

    def current_is_binary(self) -> Bool:
        if 0 <= self.cur_file and self.cur_file < len(self.file_binary):
            return self.file_binary[self.cur_file]
        return False

    def current_is_deleted(self) -> Bool:
        if 0 <= self.cur_file and self.cur_file < len(self.file_deleted):
            return self.file_deleted[self.cur_file]
        return False

    def current_changed_lines(self) -> Int:
        if 0 <= self.cur_file and self.cur_file < len(self.file_changed_lines):
            return self.file_changed_lines[self.cur_file]
        return 0

    def is_editable(self) -> Bool:
        """Only unstaged reviews edit the live worktree file."""
        return self.src == _SRC_UNSTAGED

    def set_change_counter(mut self, index: Int, total: Int, cum_lines: Int):
        self.change_index = index
        self.change_total = total
        self.cur_file_cum_lines = cum_lines

    def _ensure_cum_cache(mut self):
        """Build ``_cum_prefix`` for ``cur_file`` if stale. ``_cum_prefix[b]``
        is the count of changed diff rows (added + removed) anchored at
        after-file rows ``< b``. A removed (deleted) row is anchored to the
        after-row it renders before — pure-deletion runs to the next surviving
        row, trailing deletions to end-of-file — so every deletion is counted
        exactly once and ``_cum_prefix`` is non-decreasing. Built from the same
        ``build_diff_rows`` pass as ``file_changed_lines`` (``_count_changed_lines``),
        so ``_cum_prefix[-1]`` equals this file's ``file_changed_lines`` entry
        exactly — no drift between the bar's numerator and denominator."""
        if self._cum_file == self.cur_file and len(self._cum_prefix) > 0:
            return
        self._cum_file = self.cur_file
        var prefix = List[Int]()
        prefix.append(0)
        if self.cur_file < 0 or self.cur_file >= len(self.file_before):
            self._cum_prefix = prefix^
            return
        var before_lines = split_lines_no_trailing(self.file_before[self.cur_file])
        var after_lines = split_lines_no_trailing(self.file_after[self.cur_file])
        var n_after = len(after_lines)
        var drows = build_diff_rows(before_lines, after_lines)
        # delta[a] = changed rows anchored at after-row a (index n_after = EOF).
        var delta = List[Int]()
        for _ in range(n_after + 1):
            delta.append(0)
        var pending = 0
        for j in range(len(drows)):
            var k = drows[j].kind
            if k == DIFF_ROW_REMOVED:
                pending += 1
                continue
            var ar = drows[j].after_row
            if ar < 0 or ar > n_after:
                ar = n_after
            # Pending removed rows anchor just before this surviving row.
            delta[ar] += pending
            pending = 0
            if k == DIFF_ROW_ADDED:
                delta[ar] += 1
        delta[n_after] += pending  # trailing deletions
        var run = 0
        for a in range(n_after + 1):
            run += delta[a]
            prefix.append(run)  # prefix[a + 1] = changed rows anchored <= a
        self._cum_prefix = prefix^

    def changed_lines_through(mut self, boundary: Int) -> Int:
        """Changed lines (added + removed) in the current file from its top
        through ``boundary`` — the within-file part of the changeset-wide
        progress bar. ``boundary`` is the after-file row just past the cursor's
        change chunk (supplied by the host from the git gutter); ``< 0`` means
        "through end of file", used on the last change so the file's share fills
        completely."""
        self._ensure_cum_cache()
        var last = len(self._cum_prefix) - 1
        if last < 0:
            return 0
        var b = boundary
        if b < 0 or b > last:
            b = last
        return self._cum_prefix[b]

    def file_is_added(self, idx: Int) -> Bool:
        if 0 <= idx and idx < len(self.file_added):
            return self.file_added[idx]
        return False

    def file_is_deleted(self, idx: Int) -> Bool:
        if 0 <= idx and idx < len(self.file_deleted):
            return self.file_deleted[idx]
        return False

    def goto_file(mut self, idx: Int) -> Bool:
        """Jump straight to file ``idx`` (the review file tree's click).
        Returns True if the current file actually changed."""
        var before = self.cur_file
        self._goto_file(idx)
        return self.cur_file != before

    def consume_nav(mut self) -> Int:
        var n = self.pending_nav
        self.pending_nav = 0
        return n

    def goto_file_rel(mut self, direction: Int) -> Bool:
        """Move to the adjacent file (host calls this when a file's changes
        run out). Returns True if the file actually changed."""
        var before = self.cur_file
        self._goto_file(self.cur_file + direction)
        return self.cur_file != before

    def _goto_file(mut self, idx: Int):
        if self.file_count() == 0:
            return
        var i = idx
        if i < 0:
            i = 0
        if i >= self.file_count():
            i = self.file_count() - 1
        self.cur_file = i
        self.change_index = 0
        self.change_total = 0

    # --- paint ------------------------------------------------------------

    def paint(mut self, mut canvas: Canvas, screen: Rect, top_y: Int):
        if not self.active:
            return
        if self.mode == _MODE_PICKER:
            self._paint_picker(canvas, screen, top_y)
        else:
            # The body editor is painted by the host; review only owns the
            # bottom navigation toolbar.
            self._paint_toolbar(canvas, screen)

    def body_rect(self, screen: Rect, top_y: Int) -> Rect:
        """Region the hosted editor window occupies: full width, from
        ``top_y`` down to the row above the toolbar."""
        return Rect(screen.a.x, top_y, screen.b.x, screen.b.y - 1)

    def _paint_picker(mut self, mut canvas: Canvas, screen: Rect, top_y: Int):
        var dialog_bg = Attr(BLACK, LIGHT_GRAY)
        var cursor_attr = Attr(BLACK, CYAN)
        var tab_on = Attr(WHITE, BLACK)
        var title = String(" Review changes ")
        var tab_names = List[String]()
        tab_names.append(String(" Commits "))
        tab_names.append(String(" Branches "))
        var hint = String("←/→")
        var n = len(self.picker_labels)
        # Size the box over *both* tabs so flipping tabs doesn't make it jump.
        var maxw = display_columns(title)
        var tabs_w = display_columns(hint) + 2
        for t in range(len(tab_names)):
            tabs_w += display_columns(tab_names[t]) + 1
        if tabs_w > maxw:
            maxw = tabs_w
        var max_rows = 1
        for t in range(len(self._tab_labels)):
            if len(self._tab_labels[t]) > max_rows:
                max_rows = len(self._tab_labels[t])
            for i in range(len(self._tab_labels[t])):
                var w = display_columns(self._tab_labels[t][i])
                if w > maxw:
                    maxw = w
        var box_w = maxw + 4
        if box_w > screen.width() - 2:
            box_w = screen.width() - 2
        if box_w < 12:
            box_w = 12
        # Border, tab row, rule, list rows, border.
        var box_h = max_rows + 4
        var avail = screen.b.y - top_y
        if box_h > avail:
            box_h = avail
        var x0 = screen.a.x + (screen.width() - box_w) // 2
        var y0 = top_y + (avail - box_h) // 2
        if y0 < top_y:
            y0 = top_y
        if x0 < screen.a.x:
            x0 = screen.a.x
        var box = Rect(x0, y0, x0 + box_w, y0 + box_h)
        paint_drop_shadow(canvas, box)
        canvas.fill(box, String(" "), dialog_bg)
        var painter = Painter(box)
        painter.draw_box(canvas, box, dialog_bg)
        var tx = x0 + (box_w - display_columns(title)) // 2
        _ = painter.put_text(canvas, Point(tx, y0), title, dialog_bg)
        # Tab header + a rule under it.
        self.pk_tab_y = y0 + 1
        self.pk_tab_lo = List[Int]()
        self.pk_tab_hi = List[Int]()
        var hx = x0 + 2
        for t in range(len(tab_names)):
            var w = display_columns(tab_names[t])
            self.pk_tab_lo.append(hx)
            self.pk_tab_hi.append(hx + w)
            _ = painter.put_text(
                canvas, Point(hx, self.pk_tab_y), tab_names[t],
                tab_on if t == self.picker_tab else dialog_bg,
            )
            hx += w + 1
        _ = painter.put_text(
            canvas,
            Point(x0 + box_w - 2 - display_columns(hint), self.pk_tab_y),
            hint, Attr(DARK_GRAY, LIGHT_GRAY),
        )
        for x in range(x0, x0 + box_w):
            var g = String("─")
            if x == x0:
                g = String("├")
            elif x == x0 + box_w - 1:
                g = String("┤")
            painter.set(canvas, x, y0 + 2, Cell(g, dialog_bg, 1))
        self.pk_y0 = y0 + 3
        self.pk_x0 = x0 + 1
        self.pk_x1 = x0 + box_w - 1
        var rows_shown = max(0, box_h - 4)
        if n == 0 and rows_shown > 0:
            var empty = String("No commits to review")
            if self.picker_tab == _TAB_BRANCHES:
                empty = String("No branches to compare") \
                    if len(self.main_branch.as_bytes()) > 0 \
                    else String("No main/master branch to compare with")
            _ = painter.put_text(
                canvas, Point(x0 + 2, self.pk_y0), empty,
                Attr(DARK_GRAY, LIGHT_GRAY),
            )
        # Scroll just far enough to keep the cursor on screen when the
        # list is taller than the box (a short terminal).
        var first = 0
        if self.picker_cursor >= rows_shown:
            first = self.picker_cursor - rows_shown + 1
        self.pk_first = first
        self.pk_rows = rows_shown
        for r in range(rows_shown):
            var i = first + r
            if i >= n:
                break
            var y = self.pk_y0 + r
            var row_attr = cursor_attr if i == self.picker_cursor else dialog_bg
            painter.fill(
                canvas, Rect(self.pk_x0, y, self.pk_x1, y + 1),
                String(" "), row_attr,
            )
            # Clip inside the frame so a long commit subject can't overwrite
            # the right border.
            _ = painter.sub(Rect(self.pk_x0, y, self.pk_x1 - 1, y + 1)).put_text(
                canvas, Point(x0 + 2, y), self.picker_labels[i], row_attr,
            )

    def _paint_toolbar(mut self, mut canvas: Canvas, screen: Rect):
        var y = screen.b.y - 1
        self.tb_y = y
        var row = Rect(screen.a.x, y, screen.b.x, y + 1)
        var bar_bg = Attr(BLACK, LIGHT_GRAY)
        canvas.fill(row, String(" "), bar_bg)
        var painter = Painter(row)
        var total = self.file_count()
        # Prev/Next walk change-to-change and roll across files, so a button
        # is live when there's an earlier/later change *or* file to reach.
        var have_prev = self.cur_file > 0 or self.change_index > 1
        var have_next = (
            (total > 0 and self.cur_file < total - 1)
            or self.change_index < self.change_total
        )
        var enabled = Attr(BLACK, CYAN)
        var disabled = Attr(DARK_GRAY, LIGHT_GRAY)
        # Buttons advertise their keyboard shortcut (⇧⌘← / ⇧⌘→).
        var prev_label = String(" ‹ Prev change ⇧⌘← ")
        var next_label = String(" ⇧⌘→ Next change › ")
        var prev_w = display_columns(prev_label)
        self.tb_prev_lo = screen.a.x
        self.tb_prev_hi = screen.a.x + prev_w
        _ = painter.put_text(
            canvas, Point(self.tb_prev_lo, y), prev_label,
            enabled if have_prev else disabled,
        )
        var next_w = display_columns(next_label)
        self.tb_next_lo = screen.b.x - next_w
        self.tb_next_hi = screen.b.x
        _ = painter.put_text(
            canvas, Point(self.tb_next_lo, y), next_label,
            enabled if have_next else disabled,
        )
        # Progress bar fills the gap between the two buttons (no padding),
        # with the counter centred on top.
        var mid_lo = self.tb_prev_hi
        var mid_hi = self.tb_next_lo
        if mid_hi <= mid_lo:
            return
        var mid_w = mid_hi - mid_lo
        var cur_file = self.cur_file + 1 if total > 0 else 0
        # Line-weighted fill: each file's / change's share of the bar is
        # proportional to how many lines it touches. ``num`` = changed lines
        # through the current change (all prior files + the current file up
        # to the current chunk); ``den`` = changed lines across the review.
        var num = self.cur_file_cum_lines
        for i in range(self.cur_file):
            if i < len(self.file_changed_lines):
                num += self.file_changed_lines[i]
        var den = 0
        for i in range(len(self.file_changed_lines)):
            den += self.file_changed_lines[i]
        var filled = 0
        if den > 0:
            if num > den:
                num = den
            filled = mid_w * num // den
        var filled_bg = Attr(BLACK, GREEN)
        var empty_bg = Attr(WHITE, DARK_GRAY)
        if filled > 0:
            canvas.fill(
                Rect(mid_lo, y, mid_lo + filled, y + 1), String(" "), filled_bg,
            )
        if filled < mid_w:
            canvas.fill(
                Rect(mid_lo + filled, y, mid_hi, y + 1), String(" "), empty_bg,
            )
        var counter = (
            String("file ") + String(cur_file) + String(" of ")
            + String(total)
        )
        if self.change_total > 0:
            counter = (
                counter + String("  ·  change ") + String(self.change_index)
                + String(" of ") + String(self.change_total)
            )
        var cw = display_columns(counter)
        var cx = mid_lo + (mid_w - cw) // 2
        if cx < mid_lo:
            cx = mid_lo
        # Paint the counter twice through complementary clips so each half
        # takes the color of the bar segment beneath it.
        var split = mid_lo + filled
        _ = painter.sub(Rect(mid_lo, y, split, y + 1)).put_text(
            canvas, Point(cx, y), counter, Attr(WHITE, GREEN),
        )
        _ = painter.sub(Rect(split, y, mid_hi, y + 1)).put_text(
            canvas, Point(cx, y), counter, Attr(BLACK, DARK_GRAY),
        )

    # --- input ------------------------------------------------------------

    def handle_event(
        mut self, event: Event, screen: Rect, top_y: Int,
    ) -> Bool:
        """Route one event. In picker mode ReviewMode is fully modal and
        always consumes. In review mode it only claims its own chrome
        (Esc, toolbar buttons, file-to-file navigation) and returns False
        for everything else so the host can forward it to the editor."""
        if not self.active:
            return False
        if self.mode == _MODE_PICKER:
            if event.kind == EVENT_KEY:
                self._handle_picker_key(event)
            elif event.kind == EVENT_MOUSE:
                self._handle_picker_mouse(event)
            return True
        # Review mode — chrome only.
        if event.kind == EVENT_KEY:
            return self._handle_review_key(event)
        if event.kind == EVENT_MOUSE:
            return self._handle_review_mouse(event)
        return False

    def _handle_picker_key(mut self, event: Event):
        if event.key == KEY_ESC:
            self.close()
            return
        var n = len(self.picker_labels)
        if event.key == KEY_LEFT:
            self._show_tab(self.picker_tab - 1)
        elif event.key == KEY_RIGHT:
            self._show_tab(self.picker_tab + 1)
        elif event.key == KEY_TAB:
            self._show_tab((self.picker_tab + 1) % 2)
        elif event.key == KEY_UP:
            if self.picker_cursor > 0:
                self.picker_cursor -= 1
        elif event.key == KEY_DOWN:
            if self.picker_cursor < n - 1:
                self.picker_cursor += 1
        elif event.key == KEY_HOME:
            self.picker_cursor = 0
        elif event.key == KEY_END:
            self.picker_cursor = n - 1 if n > 0 else 0
        elif event.key == KEY_ENTER:
            self._start_review()

    def _handle_picker_mouse(mut self, event: Event):
        if event.button == MOUSE_WHEEL_UP:
            if self.picker_cursor > 0:
                self.picker_cursor -= 1
        elif event.button == MOUSE_WHEEL_DOWN:
            if self.picker_cursor < len(self.picker_labels) - 1:
                self.picker_cursor += 1
        elif event.button == MOUSE_BUTTON_LEFT and event.pressed \
                and not event.motion:
            var px = event.pos.x
            var py = event.pos.y
            if py == self.pk_tab_y:
                for t in range(len(self.pk_tab_lo)):
                    if self.pk_tab_lo[t] <= px and px < self.pk_tab_hi[t]:
                        self._show_tab(t)
                return
            var idx = self.pk_first + (py - self.pk_y0)
            if self.pk_x0 <= px and px < self.pk_x1 \
                    and self.pk_y0 <= py and py < self.pk_y0 + self.pk_rows \
                    and idx < len(self.picker_labels):
                self.picker_cursor = idx
                self._start_review()

    def _handle_review_key(mut self, event: Event) -> Bool:
        if event.key == KEY_ESC:
            self.close()
            return True
        # Cmd+Shift+Right / Left step change-to-change, rolling into the
        # next/prev file when this file's changes run out — the host drains
        # ``pending_nav``. Consuming them here also stops them falling
        # through to the tab-rotate hotkey (which would yank focus out of
        # review). Ctrl+Shift+PageDown / PageUp are a terminal-friendly
        # alias (no Cmd there). Plain keys would type into an editable
        # unstaged buffer, so navigation always carries a modifier.
        var has_shift = (event.mods & MOD_SHIFT) != 0
        var has_meta = (event.mods & MOD_META) != 0
        var has_ctrl = (event.mods & MOD_CTRL) != 0
        if has_shift and has_meta and event.key == KEY_RIGHT:
            self.pending_nav = 1
            return True
        if has_shift and has_meta and event.key == KEY_LEFT:
            self.pending_nav = -1
            return True
        if has_shift and has_ctrl and event.key == KEY_PAGEDOWN:
            self.pending_nav = 1
            return True
        if has_shift and has_ctrl and event.key == KEY_PAGEUP:
            self.pending_nav = -1
            return True
        return False

    def _handle_review_mouse(mut self, event: Event) -> Bool:
        if event.button == MOUSE_BUTTON_LEFT and event.pressed \
                and not event.motion and event.pos.y == self.tb_y:
            var px = event.pos.x
            if self.tb_prev_lo <= px and px < self.tb_prev_hi:
                self.pending_nav = -1
                return True
            if self.tb_next_lo <= px and px < self.tb_next_hi:
                self.pending_nav = 1
                return True
        return False
