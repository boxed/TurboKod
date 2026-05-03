"""LocalChanges: lazygit-style "what's going on with this repo?" view.

The left sidebar stacks three panels:

* **Modified files** — every entry from ``git status``: tracked files
  with staged or unstaged changes plus untracked files. Each row leads
  with the porcelain X (staged) and Y (worktree) columns colored green
  / red respectively, then the path. Enter opens the file; Space
  toggles whole-file staged status (``git add`` if there's anything in
  the worktree column, ``git restore --staged`` otherwise).
* **Branches** — local branches sorted by most recent commit, with the
  currently checked-out branch tagged ``*``.
* **Commits** — the last 50 commits on whichever ref is reachable from
  ``HEAD``.

A single right pane renders content for the focused row of the focused
panel:

* file row → two sections, "── STAGED ──" (``git diff --cached <file>``)
  and "── UNSTAGED ──" (``git diff <file>``). Right-arrow moves focus
  into the right pane; Up/Down moves a line cursor; Space stages /
  unstages the cursor's single ``+`` or ``-`` line by piping a minimal
  hand-rolled patch to ``git apply --cached`` (with ``--reverse`` when
  the cursor is in the staged section).
* branch row → ``git log -30`` against the branch
* commit row → ``git show <sha>`` (header + diff)

Tab / Shift+Tab cycle focus between sidebar panels. Up/Down/PgUp/PgDn,
Home/End operate on the focused panel; in the right pane the same keys
move the line cursor (Home/End jump to first/last line; PgUp/PgDn
scroll a page and bring the cursor along). Left-arrow returns focus
from the right pane to whichever sidebar panel was last active.
"""

from std.collections.list import List

from .canvas import Canvas
from .cell import Cell
from .colors import (
    Attr, BLACK, BLUE, CYAN, DARK_GRAY, LIGHT_GRAY, LIGHT_GREEN, LIGHT_RED,
    WHITE, YELLOW,
)
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_DOWN, KEY_END, KEY_ENTER, KEY_ESC, KEY_HOME, KEY_LEFT, KEY_PAGEDOWN,
    KEY_PAGEUP, KEY_RIGHT, KEY_SPACE, KEY_TAB, KEY_UP,
    MOD_SHIFT,
    MOUSE_BUTTON_LEFT, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .geometry import Point, Rect
from .git_changes import (
    ChangedFile, GitBranch, GitCommit, GitFileStatus,
    apply_patch_to_index,
    compute_staged_diff, compute_unstaged_diff,
    fetch_branch_log, fetch_commit_show, fetch_git_branches,
    fetch_git_commits, fetch_git_status, parse_unified_diff_files,
    stage_file, unstage_file,
)


comptime _SIDEBAR_MIN: Int = 28
comptime _SIDEBAR_MAX: Int = 56

comptime _PANE_FILES:    Int = 0
comptime _PANE_BRANCHES: Int = 1
comptime _PANE_COMMITS:  Int = 2
# Right pane is the fourth focusable area; reached with Right arrow from
# the sidebar, returns with Left arrow. Tab cycling stays on the three
# sidebar panels — landing in the right pane via Tab would be surprising
# when most rows there can't actually be acted on.
comptime _PANE_RIGHT:    Int = 3

# Which subsection a right-pane line belongs to. Drives both the section
# header rendering and the patch-construction logic in space-to-toggle.
comptime _SECTION_NONE:     Int = 0
comptime _SECTION_STAGED:   Int = 1
comptime _SECTION_UNSTAGED: Int = 2


@fieldwise_init
struct FileEntry(ImplicitlyCopyable, Movable):
    """One row of the Files panel. ``staged`` and ``worktree`` carry the
    porcelain X/Y status bytes (``' '`` for "no change in this column").
    ``staged_diff`` / ``unstaged_diff`` are the per-file slices of the
    whole-tree ``git diff --cached`` and ``git diff`` outputs — empty
    when this file has no change in that column. Untracked files (XY ==
    ``"??"``) carry empty diffs because git doesn't surface them through
    ``git diff``; staging them with Space turns them into ``A `` rows
    with a real staged diff on the next refresh."""
    var path: String
    var staged: UInt8
    var worktree: UInt8
    var staged_diff: String
    var unstaged_diff: String


fn _split_lines(text: String) -> List[String]:
    var out = List[String]()
    var b = text.as_bytes()
    var s = 0
    for i in range(len(b)):
        if b[i] == 0x0A:
            out.append(String(StringSlice(unsafe_from_utf8=b[s:i])))
            s = i + 1
    if s < len(b):
        out.append(String(StringSlice(unsafe_from_utf8=b[s:len(b)])))
    return out^


fn _line_starts_with_at_at(line: String) -> Bool:
    var b = line.as_bytes()
    return len(b) >= 2 and Int(b[0]) == 0x40 and Int(b[1]) == 0x40


fn _convert_to_context(line: String) -> String:
    """Swap the leading ``+`` / ``-`` prefix for a single space, leaving
    the rest of the line untouched. Used by ``_build_minimal_patch`` to
    demote unselected ± lines to context so they stay in the target
    file when the patch is applied."""
    var b = line.as_bytes()
    if len(b) == 0:
        return line
    var out = List[UInt8]()
    out.append(0x20)
    for i in range(1, len(b)):
        out.append(b[i])
    return String(StringSlice(unsafe_from_utf8=Span(out)))


fn _append_line(mut buf: List[UInt8], line: String):
    var b = line.as_bytes()
    for i in range(len(b)):
        buf.append(b[i])
    buf.append(0x0A)


fn build_minimal_patch(
    file_diff: String, target_line_idx: Int, reverse: Bool,
) -> String:
    """Construct a single-line stage/unstage patch.

    Walks the per-file diff to find the hunk containing
    ``target_line_idx`` (which must be a ``+`` or ``-`` body line), then
    emits a patch that:

    * keeps the file header (``diff --git`` / ``index`` / ``---`` /
      ``+++``);
    * keeps the hunk's ``@@`` header (``git apply --recount`` ignores
      the line counts but uses the start positions to locate the
      change);
    * keeps the target line as ``+`` / ``-``;
    * for ``reverse=False`` (forward staging from the unstaged
      section): drops other ``+`` lines and converts other ``-`` lines
      to context, so the LEFT side still matches the index;
    * for ``reverse=True`` (reverse-applied unstaging from the staged
      section): drops other ``-`` lines and converts other ``+`` lines
      to context, so the RIGHT side still matches the index;
    * keeps ``\\ No newline at end of file`` markers and context lines
      verbatim.

    Returns an empty string when the target line isn't a ``+``/``-``
    body line, or when no hunk contains it (the caller treats empty as
    "do nothing").
    """
    var lines = _split_lines(file_diff)
    if target_line_idx < 0 or target_line_idx >= len(lines):
        return String("")
    var target_line = lines[target_line_idx]
    var tb = target_line.as_bytes()
    if len(tb) == 0:
        return String("")
    var c0 = Int(tb[0])
    if c0 != 0x2B and c0 != 0x2D:
        return String("")
    var header_end = -1
    var i = 0
    while i < len(lines):
        if _line_starts_with_at_at(lines[i]):
            header_end = i
            break
        i += 1
    if header_end < 0:
        return String("")
    var hunk_start = -1
    var hunk_end = -1
    var j = header_end
    while j < len(lines):
        if _line_starts_with_at_at(lines[j]):
            var k = j + 1
            while k < len(lines):
                if _line_starts_with_at_at(lines[k]):
                    break
                var lb = lines[k].as_bytes()
                if len(lb) == 0:
                    k += 1
                    continue
                var fc = Int(lb[0])
                if fc != 0x20 and fc != 0x2B and fc != 0x2D and fc != 0x5C:
                    break
                k += 1
            if j <= target_line_idx and target_line_idx < k:
                hunk_start = j
                hunk_end = k
                break
            j = k
        else:
            j += 1
    if hunk_start < 0:
        return String("")
    var out = List[UInt8]()
    for k in range(header_end):
        _append_line(out, lines[k])
    _append_line(out, lines[hunk_start])
    for k in range(hunk_start + 1, hunk_end):
        var lk = lines[k]
        var lb = lk.as_bytes()
        if len(lb) == 0:
            _append_line(out, lk)
            continue
        var fc = Int(lb[0])
        if k == target_line_idx:
            _append_line(out, lk)
            continue
        if fc == 0x2B:
            if reverse:
                _append_line(out, _convert_to_context(lk))
            # else: drop entirely
            continue
        if fc == 0x2D:
            if not reverse:
                _append_line(out, _convert_to_context(lk))
            # else: drop entirely
            continue
        _append_line(out, lk)
    return String(StringSlice(unsafe_from_utf8=Span(out)))


fn _byte_to_string(b: UInt8) -> String:
    """Wrap a single byte as a one-char ``String``. Used for rendering
    porcelain status codes (always ASCII) one column at a time so the
    X column and Y column can take different colors."""
    var buf = List[UInt8]()
    buf.append(b)
    return String(StringSlice(unsafe_from_utf8=Span(buf)))


fn _take_first_char(s: String) -> String:
    """Return the first UTF-8 codepoint of ``s`` as its own ``String``,
    or empty when ``s`` is empty. Used by ``_author_abbrev`` so a
    multi-byte initial (``Ö``, ``É``, …) survives the abbreviation."""
    var b = s.as_bytes()
    if len(b) == 0:
        return String("")
    var c = Int(b[0])
    var n = 1
    if c >= 0xF0:    n = 4
    elif c >= 0xE0:  n = 3
    elif c >= 0xC0:  n = 2
    if n > len(b): n = len(b)
    return String(StringSlice(unsafe_from_utf8=b[:n]))


fn _take_after_first_char(s: String) -> String:
    """Counterpart of ``_take_first_char``: everything *after* the first
    codepoint. Lets us pull the second char out of a single-word author
    name (``Madonna`` → ``Ma``) without re-walking the string."""
    var b = s.as_bytes()
    if len(b) == 0:
        return String("")
    var c = Int(b[0])
    var n = 1
    if c >= 0xF0:    n = 4
    elif c >= 0xE0:  n = 3
    elif c >= 0xC0:  n = 2
    if n > len(b): n = len(b)
    return String(StringSlice(unsafe_from_utf8=b[n:len(b)]))


fn _ascii_upper_str(s: String) -> String:
    """Uppercase the leading ASCII letter of ``s`` and return the result.
    Non-ASCII chars are passed through unchanged — fine for the
    abbreviation pass, since author initials that are already uppercase
    in the source name (which is the common case) need no change."""
    var b = s.as_bytes()
    if len(b) == 0:
        return s
    var out = List[UInt8]()
    var first = b[0]
    if first >= 0x61 and first <= 0x7A:
        first = first - 32
    out.append(first)
    for i in range(1, len(b)):
        out.append(b[i])
    return String(StringSlice(unsafe_from_utf8=Span(out)))


fn _author_abbrev(author: String) -> String:
    """Two-character abbreviation: ``Anders Hovmöller`` → ``AH``,
    ``Madonna`` → ``MA``. Empty author yields two spaces so the column
    stays aligned. Only the first letter of the first/last whitespace-
    separated word is consulted; middle names / patronymics are
    ignored, mirroring the way GitHub renders short author tags."""
    var b = author.as_bytes()
    var n = len(b)
    var words = List[String]()
    var i = 0
    while i < n:
        while i < n and (b[i] == 0x20 or b[i] == 0x09):
            i += 1
        var s = i
        while i < n and not (b[i] == 0x20 or b[i] == 0x09):
            i += 1
        if s < i:
            words.append(String(StringSlice(unsafe_from_utf8=b[s:i])))
    if len(words) == 0:
        return String("  ")
    var first: String
    var second: String
    if len(words) == 1:
        first = _take_first_char(words[0])
        var rest = _take_after_first_char(words[0])
        second = _take_first_char(rest)
        if len(second.as_bytes()) == 0:
            second = String(" ")
    else:
        first = _take_first_char(words[0])
        second = _take_first_char(words[len(words) - 1])
    return _ascii_upper_str(first) + _ascii_upper_str(second)


fn _line_attr(line: String, default: Attr, add: Attr, rem: Attr,
              hunk: Attr, header: Attr) -> Attr:
    """Pick a color for a unified-diff line based on its prefix.

    Order matters: ``+++`` and ``---`` are *headers*, not adds /
    deletes, so they have to be checked before the bare ``+`` / ``-``
    test. Same with ``@@`` (hunk-marker) which would otherwise look
    like a normal context line. Also catches ``commit ``, ``Author:``,
    ``Date:`` lines from ``git show`` so they share the header color."""
    var b = line.as_bytes()
    if len(b) == 0:
        return default
    var c0 = Int(b[0])
    if len(b) >= 3:
        var c1 = Int(b[1])
        var c2 = Int(b[2])
        if c0 == 0x2B and c1 == 0x2B and c2 == 0x2B:    # +++
            return header
        if c0 == 0x2D and c1 == 0x2D and c2 == 0x2D:    # ---
            return header
        if c0 == 0x40 and c1 == 0x40:                   # @@
            return hunk
    if c0 == 0x2B:    # +
        return add
    if c0 == 0x2D:    # -
        return rem
    # ``diff --git``, ``index``, ``new file mode``, ``rename`` etc.
    if c0 == 0x64 and len(b) >= 4 \
            and Int(b[1]) == 0x69 and Int(b[2]) == 0x66 and Int(b[3]) == 0x66:
        return header
    if c0 == 0x69 and len(b) >= 6 \
            and Int(b[1]) == 0x6E and Int(b[2]) == 0x64 \
            and Int(b[3]) == 0x65 and Int(b[4]) == 0x78:
        return header
    # ``commit <sha>`` (start of ``git show`` output).
    if c0 == 0x63 and len(b) >= 7 \
            and Int(b[1]) == 0x6F and Int(b[2]) == 0x6D \
            and Int(b[3]) == 0x6D and Int(b[4]) == 0x69 \
            and Int(b[5]) == 0x74 and Int(b[6]) == 0x20:
        return header
    if c0 == 0x41 and len(b) >= 7 \
            and Int(b[1]) == 0x75 and Int(b[2]) == 0x74 \
            and Int(b[3]) == 0x68 and Int(b[4]) == 0x6F \
            and Int(b[5]) == 0x72 and Int(b[6]) == 0x3A:
        return header
    if c0 == 0x44 and len(b) >= 5 \
            and Int(b[1]) == 0x61 and Int(b[2]) == 0x74 \
            and Int(b[3]) == 0x65 and Int(b[4]) == 0x3A:
        return header
    return default


struct LocalChanges(Movable):
    var active: Bool
    var submitted: Bool
    var root: String
    # Sidebar data, one list per panel.
    var files: List[FileEntry]
    var branches: List[GitBranch]
    var commits: List[GitCommit]
    # Currently-focused sidebar panel: _PANE_FILES / _BRANCHES / _COMMITS
    # / _PANE_RIGHT. ``last_sidebar_focus`` remembers which sidebar pane
    # to return to when the user presses Left from the right pane.
    var focus: Int
    var last_sidebar_focus: Int
    # Selection + scroll state, per panel.
    var sel_file: Int
    var sel_branch: Int
    var sel_commit: Int
    var scroll_files: Int
    var scroll_branches: Int
    var scroll_commits: Int
    # Right-pane content cache. ``_right_key`` is "f:<idx>" / "b:<idx>"
    # / "c:<idx>" so we know when the focused selection changed and we
    # need to recompute / re-split. Storing both the raw text *and* the
    # split lines means scrolling doesn't pay the split cost.
    var _right_lines: List[String]
    # Per-line metadata for the right pane (parallel to _right_lines):
    #   _right_section[i]   ∈ {_SECTION_NONE / _STAGED / _UNSTAGED}
    #   _right_diff_line[i] = line index into the source per-file diff
    #                         text for that section, or -1 for headings
    #                         and other synthetic lines that aren't part
    #                         of any patch.
    # Used by space-to-toggle to map a cursor row back to the patch line
    # it represents so we can build a minimal patch from it.
    var _right_section: List[UInt8]
    var _right_diff_line: List[Int]
    var _right_key: String
    var right_scroll: Int
    var right_scroll_x: Int
    var right_cursor: Int
    # Submission contract — same shape as the previous file-only
    # version: ``selected_path`` carries the project-relative file path
    # when a file row was Enter'd, ``selected_line`` is 0 ("no jump").
    var selected_path: String
    var selected_line: Int
    # Banner shown at the top when git failed entirely. Empty means
    # "render normally" (per-panel placeholders take over inside each
    # section if its data list is empty).
    var status_message: String

    fn __init__(out self):
        self.active = False
        self.submitted = False
        self.root = String("")
        self.files = List[FileEntry]()
        self.branches = List[GitBranch]()
        self.commits = List[GitCommit]()
        self.focus = _PANE_FILES
        self.last_sidebar_focus = _PANE_FILES
        self.sel_file = 0
        self.sel_branch = 0
        self.sel_commit = 0
        self.scroll_files = 0
        self.scroll_branches = 0
        self.scroll_commits = 0
        self._right_lines = List[String]()
        self._right_section = List[UInt8]()
        self._right_diff_line = List[Int]()
        self._right_key = String("")
        self.right_scroll = 0
        self.right_scroll_x = 0
        self.right_cursor = 0
        self.selected_path = String("")
        self.selected_line = 0
        self.status_message = String("")

    fn open(mut self, var root: String):
        """Populate all three panels synchronously. Diff/branches/log
        for a real project are sub-millisecond `git` invocations each,
        and tearing down the modal is the user's "refresh" gesture so a
        debounced re-run isn't worth the complexity."""
        self.root = root^
        self.active = True
        self.submitted = False
        self.focus = _PANE_FILES
        self.last_sidebar_focus = _PANE_FILES
        self.sel_file = 0
        self.sel_branch = 0
        self.sel_commit = 0
        self.scroll_files = 0
        self.scroll_branches = 0
        self.scroll_commits = 0
        self._right_lines = List[String]()
        self._right_section = List[UInt8]()
        self._right_diff_line = List[Int]()
        self._right_key = String("")
        self.right_scroll = 0
        self.right_scroll_x = 0
        self.right_cursor = 0
        self.selected_path = String("")
        self.selected_line = 0
        self.status_message = String("")
        self._reload_files()
        self.branches = fetch_git_branches(self.root)
        self.commits = fetch_git_commits(self.root, 50)
        # If the worktree is clean *and* there are no commits / branches
        # at all the modal isn't really useful — leave the banner up.
        if len(self.files) == 0 \
                and len(self.branches) == 0 and len(self.commits) == 0:
            self.status_message = \
                String("No git data (empty repo or git unavailable).")

    fn _reload_files(mut self):
        """Re-fetch ``git status`` plus the staged + unstaged whole-tree
        diffs and rebuild ``self.files``. Called from ``open`` and after
        every staging mutation. Keeps ``status_message`` populated when
        git failed outright; otherwise leaves it empty."""
        self.files = List[FileEntry]()
        var statuses = fetch_git_status(self.root)
        var staged_text = compute_staged_diff(self.root)
        var unstaged_text = compute_unstaged_diff(self.root)
        var staged_files = List[ChangedFile]()
        var unstaged_files = List[ChangedFile]()
        if len(staged_text.as_bytes()) > 0:
            staged_files = parse_unified_diff_files(staged_text)
        if len(unstaged_text.as_bytes()) > 0:
            unstaged_files = parse_unified_diff_files(unstaged_text)
        for si in range(len(statuses)):
            var st = statuses[si]
            var sd = String("")
            var ud = String("")
            for k in range(len(staged_files)):
                if staged_files[k].path == st.path:
                    sd = staged_files[k].diff
                    break
            for k in range(len(unstaged_files)):
                if unstaged_files[k].path == st.path:
                    ud = unstaged_files[k].diff
                    break
            self.files.append(
                FileEntry(st.path, st.staged, st.worktree, sd^, ud^),
            )

    fn close(mut self):
        self.active = False
        self.submitted = False
        self.root = String("")
        self.files = List[FileEntry]()
        self.branches = List[GitBranch]()
        self.commits = List[GitCommit]()
        self.focus = _PANE_FILES
        self.last_sidebar_focus = _PANE_FILES
        self.sel_file = 0
        self.sel_branch = 0
        self.sel_commit = 0
        self.scroll_files = 0
        self.scroll_branches = 0
        self.scroll_commits = 0
        self._right_lines = List[String]()
        self._right_section = List[UInt8]()
        self._right_diff_line = List[Int]()
        self._right_key = String("")
        self.right_scroll = 0
        self.right_scroll_x = 0
        self.right_cursor = 0
        self.selected_path = String("")
        self.selected_line = 0
        self.status_message = String("")

    # --- geometry ---------------------------------------------------------

    fn _sidebar_width(self, screen: Rect) -> Int:
        var w = screen.width() // 3
        if w < _SIDEBAR_MIN: w = _SIDEBAR_MIN
        if w > _SIDEBAR_MAX: w = _SIDEBAR_MAX
        # Don't eat more than half the screen on a narrow terminal.
        if w > screen.width() // 2:
            w = screen.width() // 2
        if w < 16:
            w = 16
        return w

    fn _list_top(self, screen: Rect) -> Int:
        return screen.a.y + 2

    fn _list_bottom(self, screen: Rect) -> Int:
        return screen.b.y - 1

    fn _list_height(self, screen: Rect) -> Int:
        var h = self._list_bottom(screen) - self._list_top(screen)
        return 0 if h < 0 else h

    fn _diff_left(self, screen: Rect) -> Int:
        return screen.a.x + self._sidebar_width(screen) + 1

    fn _diff_right(self, screen: Rect) -> Int:
        return screen.b.x - 1

    fn _diff_width(self, screen: Rect) -> Int:
        var w = self._diff_right(screen) - self._diff_left(screen) - 1
        return 0 if w < 0 else w

    fn _diff_height(self, screen: Rect) -> Int:
        return self._list_height(screen)

    fn _pane_rows(self, screen: Rect) -> List[Int]:
        """Return the y-row layout for the three sidebar panels:
        ``[files_top, files_height, branches_top, branches_height,
        commits_top, commits_height]``. Each panel reserves its first
        row for a section heading; the body rows host the list.
        Splitting by thirds with the remainder going to the last panel
        keeps things predictable on small terminals."""
        var top = self._list_top(screen)
        var bottom = self._list_bottom(screen)
        var total = bottom - top
        if total < 6:
            total = 6
        var third = total // 3
        var f_h = third
        var b_h = third
        var c_h = total - f_h - b_h
        var out = List[Int]()
        out.append(top)
        out.append(f_h)
        out.append(top + f_h)
        out.append(b_h)
        out.append(top + f_h + b_h)
        out.append(c_h)
        return out^

    fn is_input_at(self, pos: Point, screen: Rect) -> Bool:
        return False

    # --- right-pane refresh ----------------------------------------------

    fn _focus_key(self) -> String:
        var driving: Int
        if self.focus == _PANE_RIGHT:
            driving = self.last_sidebar_focus
        else:
            driving = self.focus
        if driving == _PANE_FILES:
            return String("f:") + String(self.sel_file)
        if driving == _PANE_BRANCHES:
            return String("b:") + String(self.sel_branch)
        return String("c:") + String(self.sel_commit)

    fn _focus_pane_key(self) -> Int:
        """For ``_focus_key``: when focus is on the right pane, the key
        still depends on whichever sidebar selection drove the right-pane
        content (so the cache hits when the user only flipped focus
        between sidebar and right pane)."""
        if self.focus == _PANE_RIGHT:
            return self.last_sidebar_focus
        return self.focus

    fn _ensure_right_lines(mut self):
        """Recompute the right-pane line cache when the focus or the
        focused-panel selection changed. For files we synthesize a
        two-section view (STAGED then UNSTAGED) so per-line space
        toggling has unambiguous semantics; the per-line section +
        source-diff-line metadata is what ``_toggle_right_line`` uses to
        rebuild a minimal patch. The keying is by *index*, not by
        content, so re-opening on a fresh tree pulls fresh data."""
        var key = self._focus_key()
        if key == self._right_key and len(self._right_lines) > 0:
            return
        self._right_key = key
        self._right_lines = List[String]()
        self._right_section = List[UInt8]()
        self._right_diff_line = List[Int]()
        self.right_scroll = 0
        self.right_scroll_x = 0
        self.right_cursor = 0
        var driving_pane = self._focus_pane_key()
        if driving_pane == _PANE_FILES:
            if 0 <= self.sel_file and self.sel_file < len(self.files):
                self._build_files_right_pane()
            return
        if driving_pane == _PANE_BRANCHES:
            if 0 <= self.sel_branch and self.sel_branch < len(self.branches):
                var b_name = self.branches[self.sel_branch].name
                var lines = _split_lines(
                    fetch_branch_log(self.root, b_name, 30),
                )
                for li in range(len(lines)):
                    self._right_lines.append(lines[li])
                    self._right_section.append(UInt8(_SECTION_NONE))
                    self._right_diff_line.append(-1)
            return
        # commits
        if 0 <= self.sel_commit and self.sel_commit < len(self.commits):
            var sha = self.commits[self.sel_commit].short_sha
            var lines = _split_lines(
                fetch_commit_show(self.root, sha),
            )
            for li in range(len(lines)):
                self._right_lines.append(lines[li])
                self._right_section.append(UInt8(_SECTION_NONE))
                self._right_diff_line.append(-1)

    fn _build_files_right_pane(mut self):
        """Lay out the file-focus right pane: two section banners
        ("── STAGED ──" / "── UNSTAGED ──"), each followed by the
        relevant per-file diff lines. Empty sections still get a banner
        so the user can tell at a glance whether the staging operation
        moved a line into the other side."""
        var fe = self.files[self.sel_file]
        # Staged section
        self._append_section_banner(String("── STAGED ──"))
        self._append_section_lines(fe.staged_diff, _SECTION_STAGED)
        if len(fe.staged_diff.as_bytes()) == 0:
            self._right_lines.append(String("    (no staged changes)"))
            self._right_section.append(UInt8(_SECTION_NONE))
            self._right_diff_line.append(-1)
        # Spacer
        self._right_lines.append(String(""))
        self._right_section.append(UInt8(_SECTION_NONE))
        self._right_diff_line.append(-1)
        # Unstaged section
        self._append_section_banner(String("── UNSTAGED ──"))
        self._append_section_lines(fe.unstaged_diff, _SECTION_UNSTAGED)
        if len(fe.unstaged_diff.as_bytes()) == 0:
            # Untracked files (XY == "??") have no diff because git diff
            # ignores them; nudge the user toward Space-on-the-file-row.
            if Int(fe.staged) == 0x3F and Int(fe.worktree) == 0x3F:
                self._right_lines.append(
                    String("    (untracked — press Space on the file to stage it)"),
                )
            else:
                self._right_lines.append(String("    (no unstaged changes)"))
            self._right_section.append(UInt8(_SECTION_NONE))
            self._right_diff_line.append(-1)

    fn _append_section_banner(mut self, title: String):
        self._right_lines.append(title)
        self._right_section.append(UInt8(_SECTION_NONE))
        self._right_diff_line.append(-1)

    fn _append_section_lines(mut self, diff_text: String, section: Int):
        """Split ``diff_text`` and tag each line with ``section`` plus
        its index inside ``diff_text`` (so we can later locate it for
        patch construction). Empty input contributes nothing."""
        if len(diff_text.as_bytes()) == 0:
            return
        var lines = _split_lines(diff_text)
        for li in range(len(lines)):
            self._right_lines.append(lines[li])
            self._right_section.append(UInt8(section))
            self._right_diff_line.append(li)

    # --- paint ------------------------------------------------------------

    fn paint(mut self, mut canvas: Canvas, screen: Rect):
        if not self.active:
            return
        var bg          = Attr(YELLOW, BLUE)
        var border      = Attr(WHITE,  BLUE)
        var title_attr  = Attr(WHITE,  BLUE)
        var sep_attr    = Attr(WHITE,  BLUE)
        var hint_attr   = Attr(BLACK,  LIGHT_GRAY)
        var list_attr   = Attr(YELLOW, BLUE)
        var list_dim    = Attr(LIGHT_GRAY, BLUE)
        var sel_attr    = Attr(BLACK,  YELLOW)
        var sel_inactive = Attr(BLACK, LIGHT_GRAY)
        var section_attr = Attr(WHITE, DARK_GRAY)
        var ctx_attr    = Attr(LIGHT_GRAY, BLUE)
        var add_attr    = Attr(LIGHT_GREEN, BLUE)
        var rem_attr    = Attr(LIGHT_RED,   BLUE)
        var hunk_attr   = Attr(CYAN,  BLUE)
        var header_attr = Attr(WHITE, BLUE)
        canvas.fill(screen, String(" "), bg)
        canvas.draw_box(screen, border, True)
        # Title row.
        var title = String(" Local changes ")
        var tx = screen.a.x + (screen.width() - len(title.as_bytes())) // 2
        _ = canvas.put_text(Point(tx, screen.a.y), title, title_attr)
        # Sub-title: project root (or status banner).
        var sub_y = screen.a.y + 1
        var sub: String
        if len(self.status_message.as_bytes()) > 0:
            sub = String(" ") + self.status_message
        else:
            sub = String(" ") + self.root
        _ = canvas.put_text(
            Point(screen.a.x + 1, sub_y), sub, list_dim, screen.b.x - 1,
        )
        # Vertical separator between sidebar and right pane.
        var sw = self._sidebar_width(screen)
        var sep_x = screen.a.x + sw
        for y in range(self._list_top(screen), self._list_bottom(screen)):
            canvas.set(sep_x, y, Cell(String("│"), sep_attr, 1))
        # Sidebar: three stacked panels.
        var rows = self._pane_rows(screen)
        var left = screen.a.x + 1
        var right = screen.a.x + sw - 1
        self._paint_section(
            canvas, left, right, rows[0], rows[1],
            String("Modified files"), _PANE_FILES,
            section_attr, list_attr, sel_attr, sel_inactive, list_dim,
        )
        self._paint_section(
            canvas, left, right, rows[2], rows[3],
            String("Branches"), _PANE_BRANCHES,
            section_attr, list_attr, sel_attr, sel_inactive, list_dim,
        )
        self._paint_section(
            canvas, left, right, rows[4], rows[5],
            String("Commits"), _PANE_COMMITS,
            section_attr, list_attr, sel_attr, sel_inactive, list_dim,
        )
        # Right pane.
        self._ensure_right_lines()
        self._paint_right(
            canvas, screen,
            ctx_attr, add_attr, rem_attr, hunk_attr, header_attr,
        )
        # Bottom hint.
        var hint: String
        if self.focus == _PANE_RIGHT:
            hint = String(
                " Up/Down: line  Space: stage/unstage  Left: back  ESC: close ",
            )
        else:
            hint = String(
                " Tab: pane  Up/Down: select  Right: diff  Space: stage  Enter: open  ESC: close ",
            )
        var hx = screen.b.x - len(hint.as_bytes()) - 1
        if hx < screen.a.x + 1:
            hx = screen.a.x + 1
        _ = canvas.put_text(Point(hx, screen.b.y - 1), hint, hint_attr)

    fn _paint_section(
        self, mut canvas: Canvas,
        left: Int, right: Int, top: Int, height: Int,
        title: String, pane: Int,
        section_attr: Attr, list_attr: Attr, sel_active: Attr,
        sel_inactive: Attr, dim_attr: Attr,
    ):
        if right <= left or height <= 1:
            return
        # Section header row — a bright bar across the panel width.
        canvas.fill(
            Rect(left, top, right + 1, top + 1), String(" "), section_attr,
        )
        var marker = String("> ") if self.focus == pane else String("  ")
        _ = canvas.put_text(
            Point(left, top), marker + title, section_attr, right + 1,
        )
        var body_top = top + 1
        var body_h = height - 1
        if body_h <= 0:
            return
        var is_focused = (self.focus == pane)
        if pane == _PANE_FILES:
            self._paint_files(
                canvas, left, right, body_top, body_h, is_focused,
                list_attr, sel_active, sel_inactive, dim_attr,
            )
        elif pane == _PANE_BRANCHES:
            self._paint_branches(
                canvas, left, right, body_top, body_h, is_focused,
                list_attr, sel_active, sel_inactive, dim_attr,
            )
        else:
            self._paint_commits(
                canvas, left, right, body_top, body_h, is_focused,
                list_attr, sel_active, sel_inactive, dim_attr,
            )

    fn _row_attr(
        self, is_sel: Bool, is_focused: Bool,
        list_attr: Attr, sel_active: Attr, sel_inactive: Attr,
    ) -> Attr:
        if not is_sel:
            return list_attr
        return sel_active if is_focused else sel_inactive

    fn _paint_truncated(
        self, mut canvas: Canvas, x: Int, y: Int, right_excl: Int,
        text: String, attr: Attr,
    ):
        """Right-truncate ``text`` so it fits in ``[x, right_excl)``,
        marking truncation with a leading ``…`` so the basename / sha
        / subject end stays visible."""
        var avail = right_excl - x
        if avail <= 0:
            return
        var bytes = text.as_bytes()
        if len(bytes) <= avail:
            _ = canvas.put_text(Point(x, y), text, attr, right_excl)
            return
        canvas.set(x, y, Cell(String("…"), attr, 1))
        var start = len(bytes) - avail + 1
        _ = canvas.put_text(
            Point(x + 1, y),
            String(StringSlice(unsafe_from_utf8=bytes[start:len(bytes)])),
            attr, right_excl,
        )

    fn _paint_files(
        self, mut canvas: Canvas,
        left: Int, right: Int, top: Int, height: Int, is_focused: Bool,
        list_attr: Attr, sel_active: Attr, sel_inactive: Attr,
        dim_attr: Attr,
    ):
        if len(self.files) == 0:
            _ = canvas.put_text(
                Point(left + 1, top), String("(no modified files)"),
                dim_attr, right + 1,
            )
            return
        # Per-column status colors. Selected rows always use the row attr
        # so the selection bar reads as one block (same trick as the
        # commits pane). Untracked entries (XY == "??") get a single
        # red ``?`` in both columns; the path stays normal so the eye
        # picks up "this is new" without losing the path.
        var staged_attr   = Attr(LIGHT_GREEN, BLUE)
        var unstaged_attr = Attr(LIGHT_RED,   BLUE)
        for i in range(height):
            var idx = self.scroll_files + i
            if idx >= len(self.files):
                break
            var y = top + i
            var is_sel = (idx == self.sel_file)
            var row_attr = self._row_attr(
                is_sel, is_focused, list_attr, sel_active, sel_inactive,
            )
            canvas.fill(
                Rect(left, y, right + 1, y + 1), String(" "), row_attr,
            )
            var fe = self.files[idx]
            var stop = right + 1
            var x = left + 1
            # Two status chars: X (staged column, green) then Y
            # (worktree column, red). Spaces stay invisible against the
            # row background.
            var x_char = _byte_to_string(fe.staged)
            var y_char = _byte_to_string(fe.worktree)
            var x_attr = row_attr if is_sel else staged_attr
            var y_attr = row_attr if is_sel else unstaged_attr
            x += canvas.put_text(Point(x, y), x_char, x_attr, stop)
            if x >= stop: continue
            x += canvas.put_text(Point(x, y), y_char, y_attr, stop)
            if x >= stop: continue
            x += canvas.put_text(Point(x, y), String(" "), row_attr, stop)
            if x >= stop: continue
            self._paint_truncated(
                canvas, x, y, stop, fe.path, row_attr,
            )

    fn _paint_branches(
        self, mut canvas: Canvas,
        left: Int, right: Int, top: Int, height: Int, is_focused: Bool,
        list_attr: Attr, sel_active: Attr, sel_inactive: Attr,
        dim_attr: Attr,
    ):
        if len(self.branches) == 0:
            _ = canvas.put_text(
                Point(left + 1, top), String("(no branches)"),
                dim_attr, right + 1,
            )
            return
        for i in range(height):
            var idx = self.scroll_branches + i
            if idx >= len(self.branches):
                break
            var y = top + i
            var is_sel = (idx == self.sel_branch)
            var attr = self._row_attr(
                is_sel, is_focused, list_attr, sel_active, sel_inactive,
            )
            canvas.fill(
                Rect(left, y, right + 1, y + 1), String(" "), attr,
            )
            var br = self.branches[idx]
            var marker = String("* ") if br.is_current else String("  ")
            self._paint_truncated(
                canvas, left + 1, y, right + 1,
                marker + br.name, attr,
            )

    fn _paint_commits(
        self, mut canvas: Canvas,
        left: Int, right: Int, top: Int, height: Int, is_focused: Bool,
        list_attr: Attr, sel_active: Attr, sel_inactive: Attr,
        dim_attr: Attr,
    ):
        if len(self.commits) == 0:
            _ = canvas.put_text(
                Point(left + 1, top), String("(no commits)"),
                dim_attr, right + 1,
            )
            return
        # Per-segment colors (only used when the row isn't selected; on
        # the selection the row attr wins so the selection bar reads as
        # one continuous block — the same way git log's ``--color`` is
        # suppressed inside lazygit's selection highlight).
        var sha_attr    = Attr(YELLOW,      BLUE)
        var author_attr = Attr(CYAN,        BLUE)
        var subject_attr = Attr(LIGHT_GRAY, BLUE)
        for i in range(height):
            var idx = self.scroll_commits + i
            if idx >= len(self.commits):
                break
            var y = top + i
            var is_sel = (idx == self.sel_commit)
            var row_attr = self._row_attr(
                is_sel, is_focused, list_attr, sel_active, sel_inactive,
            )
            canvas.fill(
                Rect(left, y, right + 1, y + 1), String(" "), row_attr,
            )
            var co = self.commits[idx]
            var seg_sha    = sha_attr
            var seg_author = author_attr
            var seg_subj   = subject_attr
            if is_sel:
                seg_sha = row_attr
                seg_author = row_attr
                seg_subj = row_attr
            # Layout: ``<sha> <AB> <subject>`` painted in three
            # passes; each ``put_text`` clips at ``right + 1`` so a
            # segment that runs out of room is hard-cut at the edge
            # and the next segment simply doesn't paint. ``put_text``
            # returns columns advanced, which is what we use to walk
            # the cursor forward — codepoint width, not byte width.
            var x = left + 1
            var stop = right + 1
            x += canvas.put_text(
                Point(x, y), co.short_sha, seg_sha, stop,
            )
            if x >= stop: continue
            x += canvas.put_text(Point(x, y), String(" "), row_attr, stop)
            if x >= stop: continue
            x += canvas.put_text(
                Point(x, y), _author_abbrev(co.author), seg_author, stop,
            )
            if x >= stop: continue
            x += canvas.put_text(Point(x, y), String(" "), row_attr, stop)
            if x >= stop: continue
            _ = canvas.put_text(
                Point(x, y), co.subject, seg_subj, stop,
            )

    fn _paint_right(
        self, mut canvas: Canvas, screen: Rect,
        ctx_attr: Attr, add_attr: Attr, rem_attr: Attr,
        hunk_attr: Attr, header_attr: Attr,
    ):
        var top = self._list_top(screen)
        var height = self._diff_height(screen)
        var left = self._diff_left(screen)
        var right = self._diff_right(screen)
        if right <= left:
            return
        if len(self._right_lines) == 0:
            var msg: String
            var driving = self._focus_pane_key()
            if driving == _PANE_FILES:
                msg = String(" (select a file to see its diff)")
            elif driving == _PANE_BRANCHES:
                msg = String(" (select a branch to see its log)")
            else:
                msg = String(" (select a commit to see its details)")
            _ = canvas.put_text(Point(left, top), msg, ctx_attr, right)
            return
        var section_banner_attr = Attr(WHITE, DARK_GRAY)
        var cursor_active = Attr(BLACK, YELLOW)
        var cursor_inactive = Attr(BLACK, LIGHT_GRAY)
        var pane_focused = (self.focus == _PANE_RIGHT)
        for i in range(height):
            var idx = self.right_scroll + i
            if idx >= len(self._right_lines):
                break
            var y = top + i
            var line = self._right_lines[idx]
            var section = Int(self._right_section[idx])
            var is_cursor = (idx == self.right_cursor and pane_focused)
            var attr: Attr
            if is_cursor:
                attr = cursor_active
            elif section == _SECTION_NONE \
                    and self._looks_like_section_banner(line):
                attr = section_banner_attr
            else:
                attr = _line_attr(
                    line, ctx_attr, add_attr, rem_attr,
                    hunk_attr, header_attr,
                )
            # When the cursor row is highlighted, paint the entire row
            # background so the gap to the right reads as part of the
            # selection bar, matching the file-list behavior.
            if is_cursor:
                canvas.fill(
                    Rect(left, y, right, y + 1), String(" "), attr,
                )
            var bytes = line.as_bytes()
            var start = self.right_scroll_x
            if start >= len(bytes):
                continue
            var visible = String(StringSlice(
                unsafe_from_utf8=bytes[start:len(bytes)],
            ))
            _ = canvas.put_text(Point(left, y), visible, attr, right)
        _ = cursor_inactive   # reserved for future "cursor while focus elsewhere"

    fn _looks_like_section_banner(self, line: String) -> Bool:
        """Cheap detector for the synthetic ``── STAGED ──`` /
        ``── UNSTAGED ──`` banners. Splits the painting code from the
        builder by checking the prefix instead of carrying a richer per-
        line tag — works because the banner glyph is unmistakable."""
        var b = line.as_bytes()
        if len(b) < 3:
            return False
        # ``─`` (U+2500) encodes as 0xE2 0x94 0x80 in UTF-8.
        return Int(b[0]) == 0xE2 and Int(b[1]) == 0x94 and Int(b[2]) == 0x80

    # --- events -----------------------------------------------------------

    fn _focused_count(self) -> Int:
        if self.focus == _PANE_FILES: return len(self.files)
        if self.focus == _PANE_BRANCHES: return len(self.branches)
        return len(self.commits)

    fn _focused_selection(self) -> Int:
        if self.focus == _PANE_FILES: return self.sel_file
        if self.focus == _PANE_BRANCHES: return self.sel_branch
        return self.sel_commit

    fn _focused_scroll(self) -> Int:
        if self.focus == _PANE_FILES: return self.scroll_files
        if self.focus == _PANE_BRANCHES: return self.scroll_branches
        return self.scroll_commits

    fn _focused_panel_height(self, screen: Rect) -> Int:
        var rows = self._pane_rows(screen)
        var h: Int
        if self.focus == _PANE_FILES:
            h = rows[1] - 1
        elif self.focus == _PANE_BRANCHES:
            h = rows[3] - 1
        else:
            h = rows[5] - 1
        return 0 if h < 0 else h

    fn _set_focused_selection(mut self, new_idx: Int, screen: Rect):
        var n = self._focused_count()
        if n == 0:
            return
        var new = new_idx
        if new < 0: new = 0
        if new >= n: new = n - 1
        var h = self._focused_panel_height(screen)
        if h < 1: h = 1
        if self.focus == _PANE_FILES:
            self.sel_file = new
            if self.sel_file < self.scroll_files:
                self.scroll_files = self.sel_file
            elif self.sel_file >= self.scroll_files + h:
                self.scroll_files = self.sel_file - h + 1
            if self.scroll_files < 0: self.scroll_files = 0
        elif self.focus == _PANE_BRANCHES:
            self.sel_branch = new
            if self.sel_branch < self.scroll_branches:
                self.scroll_branches = self.sel_branch
            elif self.sel_branch >= self.scroll_branches + h:
                self.scroll_branches = self.sel_branch - h + 1
            if self.scroll_branches < 0: self.scroll_branches = 0
        else:
            self.sel_commit = new
            if self.sel_commit < self.scroll_commits:
                self.scroll_commits = self.sel_commit
            elif self.sel_commit >= self.scroll_commits + h:
                self.scroll_commits = self.sel_commit - h + 1
            if self.scroll_commits < 0: self.scroll_commits = 0

    fn _cycle_focus(mut self, direction: Int):
        """Move focus by ``direction`` (+1 / -1) within the sidebar
        (0..2), wrapping. From the right pane, snap back to whichever
        sidebar pane was active last and *then* advance — the right
        pane isn't part of the Tab cycle because most rows there can't
        be acted on, so landing there via Tab would be surprising."""
        var base: Int
        if self.focus == _PANE_RIGHT:
            base = self.last_sidebar_focus
        else:
            base = self.focus
        var f = base + direction
        if f < 0: f = 2
        if f > 2: f = 0
        self.focus = f
        self.last_sidebar_focus = f

    fn _scroll_right(mut self, delta: Int, screen: Rect):
        var n = len(self._right_lines)
        var h = self._diff_height(screen)
        var max_scroll = n - h
        if max_scroll < 0: max_scroll = 0
        var s = self.right_scroll + delta
        if s < 0: s = 0
        if s > max_scroll: s = max_scroll
        self.right_scroll = s
        # Drag the cursor along so it stays inside the visible window;
        # otherwise PgDn would orphan the highlight off-screen.
        self._clamp_cursor_to_view(screen)

    fn _clamp_cursor_to_view(mut self, screen: Rect):
        var h = self._diff_height(screen)
        var n = len(self._right_lines)
        if n == 0:
            self.right_cursor = 0
            return
        if self.right_cursor < self.right_scroll:
            self.right_cursor = self.right_scroll
        var bottom = self.right_scroll + h - 1
        if bottom >= n:
            bottom = n - 1
        if self.right_cursor > bottom:
            self.right_cursor = bottom

    fn _move_right_cursor(mut self, delta: Int, screen: Rect):
        var n = len(self._right_lines)
        if n == 0:
            return
        var c = self.right_cursor + delta
        if c < 0: c = 0
        if c >= n: c = n - 1
        self.right_cursor = c
        # Auto-scroll so cursor stays visible.
        var h = self._diff_height(screen)
        if h < 1: h = 1
        if self.right_cursor < self.right_scroll:
            self.right_scroll = self.right_cursor
        elif self.right_cursor >= self.right_scroll + h:
            self.right_scroll = self.right_cursor - h + 1
        if self.right_scroll < 0:
            self.right_scroll = 0

    fn _enter_right_pane(mut self, screen: Rect):
        """Move focus from sidebar → right pane. Snap the cursor to the
        first line that's actually part of a stageable diff section
        (skipping the synthetic banners) so a single ``Space`` after
        ``Right`` does something useful instead of landing on a header."""
        if self.focus == _PANE_RIGHT:
            return
        self.last_sidebar_focus = self.focus
        self.focus = _PANE_RIGHT
        self._ensure_right_lines()
        # Find the first line that's part of a real diff section.
        var found = -1
        for i in range(len(self._right_lines)):
            if Int(self._right_section[i]) != _SECTION_NONE:
                found = i
                break
        if found < 0:
            self.right_cursor = 0
        else:
            self.right_cursor = found
        # Scroll so it's visible.
        var h = self._diff_height(screen)
        if h < 1: h = 1
        if self.right_cursor < self.right_scroll:
            self.right_scroll = self.right_cursor
        elif self.right_cursor >= self.right_scroll + h:
            self.right_scroll = self.right_cursor - h + 1
        if self.right_scroll < 0:
            self.right_scroll = 0

    fn _leave_right_pane(mut self):
        if self.focus != _PANE_RIGHT:
            return
        self.focus = self.last_sidebar_focus

    fn handle_key(mut self, event: Event, screen: Rect) -> Bool:
        if not self.active or event.kind != EVENT_KEY:
            return False
        var k = event.key
        if k == KEY_ESC:
            self.close()
            return True
        if k == KEY_TAB:
            if (event.mods & MOD_SHIFT) != 0:
                self._cycle_focus(-1)
            else:
                self._cycle_focus(1)
            return True
        if k == KEY_RIGHT:
            self._enter_right_pane(screen)
            return True
        if k == KEY_LEFT:
            self._leave_right_pane()
            return True
        if k == KEY_SPACE:
            self._handle_space(screen)
            return True
        if self.focus == _PANE_RIGHT:
            if k == KEY_UP:
                self._move_right_cursor(-1, screen)
                return True
            if k == KEY_DOWN:
                self._move_right_cursor(1, screen)
                return True
            if k == KEY_HOME:
                self._move_right_cursor(-len(self._right_lines), screen)
                return True
            if k == KEY_END:
                self._move_right_cursor(len(self._right_lines), screen)
                return True
            if k == KEY_PAGEUP:
                self._scroll_right(-self._diff_height(screen), screen)
                self._move_right_cursor(-self._diff_height(screen), screen)
                return True
            if k == KEY_PAGEDOWN:
                self._scroll_right(self._diff_height(screen), screen)
                self._move_right_cursor(self._diff_height(screen), screen)
                return True
            return False
        if k == KEY_UP:
            self._set_focused_selection(self._focused_selection() - 1, screen)
            return True
        if k == KEY_DOWN:
            self._set_focused_selection(self._focused_selection() + 1, screen)
            return True
        if k == KEY_HOME:
            self._set_focused_selection(0, screen)
            return True
        if k == KEY_END:
            self._set_focused_selection(self._focused_count() - 1, screen)
            return True
        if k == KEY_PAGEUP:
            self._scroll_right(-self._diff_height(screen), screen)
            return True
        if k == KEY_PAGEDOWN:
            self._scroll_right(self._diff_height(screen), screen)
            return True
        if k == KEY_ENTER:
            # Enter only does something for file rows — open the file.
            # On branches/commits there's no obvious "open" action, so
            # we ignore Enter rather than fake a non-reversible action
            # like ``git checkout``.
            if self.focus == _PANE_FILES \
                    and 0 <= self.sel_file \
                    and self.sel_file < len(self.files):
                self.selected_path = self.files[self.sel_file].path
                self.selected_line = 0
                self.submitted = True
            return True
        return False

    fn _handle_space(mut self, screen: Rect):
        """Stage / unstage the focused thing.

        * On the Files panel: toggle whole-file staged status — stage if
          the worktree column shows any change, unstage if only the
          staged column does. (For an entry with both, prefer staging
          the rest of the worktree changes; the user can press Space
          again to unstage.)
        * On the right pane: build a minimal patch from the cursor's
          single line and apply it (forward to stage from the unstaged
          section, ``--reverse`` to unstage from the staged section).

        Anywhere else (branches / commits or a non-actionable line) it's
        a no-op rather than an error so the keystroke doesn't grab
        focus from a future binding.
        """
        if self.focus == _PANE_FILES:
            if 0 <= self.sel_file and self.sel_file < len(self.files):
                self._toggle_file_at(self.sel_file)
            return
        if self.focus == _PANE_RIGHT:
            self._toggle_right_line()
            return

    fn _toggle_file_at(mut self, idx: Int):
        """Stage everything if the worktree column has any unstaged
        change (including untracked ``??``); otherwise unstage what's in
        the index. ``add`` covers the first case across modified and
        untracked uniformly, so we don't branch on the file kind."""
        var fe = self.files[idx]
        var path = fe.path
        var ok: Bool
        if Int(fe.worktree) != 0x20:    # has unstaged change → stage
            ok = stage_file(self.root, path)
        elif Int(fe.staged) != 0x20:    # only staged → unstage
            ok = unstage_file(self.root, path)
        else:
            return
        if not ok:
            return
        self._refresh_after_mutation(path)

    fn _toggle_right_line(mut self):
        """Cursor is on a single line of the staged or unstaged section.
        Build a minimal patch and pipe it to ``git apply --cached``;
        ``--reverse`` for staged-section lines so applying it removes
        them from the index. No-op when cursor is on a banner / context
        line / heading where there's nothing to toggle."""
        if self.right_cursor < 0 \
                or self.right_cursor >= len(self._right_lines):
            return
        var section = Int(self._right_section[self.right_cursor])
        if section == _SECTION_NONE:
            return
        var diff_line_idx = self._right_diff_line[self.right_cursor]
        if diff_line_idx < 0:
            return
        if self.sel_file < 0 or self.sel_file >= len(self.files):
            return
        var fe = self.files[self.sel_file]
        var source_diff: String
        var reverse: Bool
        if section == _SECTION_STAGED:
            source_diff = fe.staged_diff
            reverse = True
        else:
            source_diff = fe.unstaged_diff
            reverse = False
        var patch = build_minimal_patch(source_diff, diff_line_idx, reverse)
        if len(patch.as_bytes()) == 0:
            return
        if not apply_patch_to_index(self.root, patch, reverse):
            return
        self._refresh_after_mutation(fe.path)

    fn _refresh_after_mutation(mut self, kept_path: String):
        """Re-fetch files after a stage/unstage. Try to keep the user's
        place: prefer the index of the path we just acted on; if it's
        no longer in the list (e.g. a fully-staged file with a clean
        worktree drops out the moment we run ``git add`` on its last
        unstaged change), fall back to the same numeric index clamped."""
        var prev_idx = self.sel_file
        self._reload_files()
        var new_idx = -1
        for i in range(len(self.files)):
            if self.files[i].path == kept_path:
                new_idx = i
                break
        if new_idx < 0:
            new_idx = prev_idx
        if new_idx >= len(self.files):
            new_idx = len(self.files) - 1
        if new_idx < 0:
            new_idx = 0
        self.sel_file = new_idx
        if self.sel_file < self.scroll_files:
            self.scroll_files = self.sel_file
        # Force right-pane recompute next paint.
        self._right_key = String("")
        self._right_lines = List[String]()
        self._right_section = List[UInt8]()
        self._right_diff_line = List[Int]()
        self.right_scroll = 0
        self.right_cursor = 0

    fn _pane_at(self, pos: Point, screen: Rect) -> Int:
        """Return which sidebar pane (or -1 for "right pane / outside")
        the cursor position falls in."""
        var sw = self._sidebar_width(screen)
        var sidebar_right = screen.a.x + sw
        if pos.x >= sidebar_right or pos.x < screen.a.x:
            return -1
        var rows = self._pane_rows(screen)
        if pos.y >= rows[0] and pos.y < rows[0] + rows[1]:
            return _PANE_FILES
        if pos.y >= rows[2] and pos.y < rows[2] + rows[3]:
            return _PANE_BRANCHES
        if pos.y >= rows[4] and pos.y < rows[4] + rows[5]:
            return _PANE_COMMITS
        return -1

    fn handle_mouse(mut self, event: Event, screen: Rect) -> Bool:
        if not self.active or event.kind != EVENT_MOUSE:
            return False
        var pos = event.pos
        var sw = self._sidebar_width(screen)
        var sidebar_right = screen.a.x + sw
        # Wheel: forward to whichever pane the cursor sits over. In the
        # sidebar, scroll the focused list that's under the cursor; in
        # the right pane, scroll the diff body.
        if event.button == MOUSE_WHEEL_UP \
                or event.button == MOUSE_WHEEL_DOWN:
            var dy = -1 if event.button == MOUSE_WHEEL_UP else 1
            if pos.x >= sidebar_right:
                self._scroll_right(3 * dy, screen)
                return True
            var pane = self._pane_at(pos, screen)
            if pane < 0:
                return True
            # Scroll the list rows under the cursor regardless of focus,
            # but bring focus along so the right pane updates accordingly.
            self.focus = pane
            self.last_sidebar_focus = pane
            self._set_focused_selection(
                self._focused_selection() + dy, screen,
            )
            return True
        if event.button == MOUSE_BUTTON_LEFT and event.pressed:
            # Right-pane click: jump the line cursor and focus the
            # right pane so the next Space stages/unstages that line.
            if pos.x >= sidebar_right:
                var top = self._list_top(screen)
                var bottom = self._list_bottom(screen)
                if pos.y < top or pos.y >= bottom:
                    return True
                if self.focus != _PANE_RIGHT:
                    self.last_sidebar_focus = self.focus
                    self.focus = _PANE_RIGHT
                self._ensure_right_lines()
                var line_idx = self.right_scroll + (pos.y - top)
                if 0 <= line_idx and line_idx < len(self._right_lines):
                    self.right_cursor = line_idx
                return True
            var pane = self._pane_at(pos, screen)
            if pane < 0:
                return True
            var rows = self._pane_rows(screen)
            var top: Int
            var height: Int
            if pane == _PANE_FILES:
                top = rows[0]
                height = rows[1]
            elif pane == _PANE_BRANCHES:
                top = rows[2]
                height = rows[3]
            else:
                top = rows[4]
                height = rows[5]
            # Click on the section header row just shifts focus.
            self.focus = pane
            self.last_sidebar_focus = pane
            if pos.y == top:
                return True
            var body_offset = pos.y - top - 1
            if body_offset < 0 or body_offset >= height - 1:
                return True
            var scroll: Int
            if pane == _PANE_FILES:
                scroll = self.scroll_files
            elif pane == _PANE_BRANCHES:
                scroll = self.scroll_branches
            else:
                scroll = self.scroll_commits
            self._set_focused_selection(scroll + body_offset, screen)
            return True
        return False
