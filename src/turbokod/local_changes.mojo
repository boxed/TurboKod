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

The right side is split: when a file is selected it shows two stacked
panels — **Unstaged** on top, **Staged** below — each scrolling
independently with its own cursor. For a branch / commit selection it
collapses to a single info panel showing the log / show output. Right-
arrow enters the right side (lands on Unstaged for files); Tab cycles
between Unstaged and Staged when both are visible. Within a right
panel, Up/Down moves the line cursor and Space stages / unstages the
single ``+`` / ``-`` line under the cursor (forward from Unstaged,
``--reverse`` from Staged).

Tab / Shift+Tab cycle focus between the three sidebar panels, or
between the two right-side panels when focus is on the right.
Up/Down/PgUp/PgDn, Home/End operate on the focused panel; Left-arrow
returns focus from the right side to whichever sidebar panel was last
active.

All three sidebar splitters and the right-side splitter are
**draggable** — click on a splitter row (the thin ``─`` bar between
panels, or the ``│`` column between sidebar and right) and drag to
resize. The vertical separator resizes sidebar / right; horizontal
splitters resize the panels above / below. Sizes are remembered until
the modal closes.
"""

from collections import Optional

from std.collections.list import List

from .canvas import Canvas
from .cell import Cell
from .colors import (
    Attr, BLACK, BLUE, CYAN, DARK_GRAY, LIGHT_GRAY, LIGHT_GREEN, LIGHT_RED,
    WHITE, YELLOW,
)
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_BACKSPACE, KEY_DOWN, KEY_END, KEY_ENTER, KEY_ESC, KEY_HOME, KEY_LEFT,
    KEY_PAGEDOWN, KEY_PAGEUP, KEY_RIGHT, KEY_SPACE, KEY_TAB, KEY_UP,
    MOD_SHIFT,
    MOUSE_BUTTON_LEFT, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .geometry import Point, Rect
from .painter import Painter
from .git_changes import (
    ChangedFile, GitBranch, GitCommit, GitFileStatus, GitOpResult,
    apply_patch_to_index,
    compute_staged_diff, compute_unstaged_diff,
    fetch_branch_log, fetch_commit_show, fetch_git_branches,
    fetch_git_commits, fetch_git_status, parse_unified_diff_files,
    git_amend_no_edit, git_commit, git_pull, git_push, git_revert_file,
    stage_file, unstage_file,
)
from .text_field import text_field_clipboard_key
from .window import paint_drop_shadow


comptime _SIDEBAR_MIN: Int = 28
comptime _SIDEBAR_MAX: Int = 56

comptime _PANE_FILES:           Int = 0
comptime _PANE_BRANCHES:        Int = 1
comptime _PANE_COMMITS:         Int = 2
# Right side. Splits into UNSTAGED (top) + STAGED (bottom) for file
# selections; collapses to a single INFO panel for branch / commit
# selections (where there's no concept of staging).
comptime _PANE_RIGHT_UNSTAGED:  Int = 3
comptime _PANE_RIGHT_STAGED:    Int = 4
comptime _PANE_RIGHT_INFO:      Int = 5

# Drag identifiers — which splitter is currently being dragged.
comptime _DRAG_NONE:        Int = 0
comptime _DRAG_SIDEBAR:     Int = 1   # vertical: sidebar / right
comptime _DRAG_SPLIT_FB:    Int = 2   # horizontal: files / branches
comptime _DRAG_SPLIT_BC:    Int = 3   # horizontal: branches / commits
comptime _DRAG_SPLIT_US:    Int = 4   # horizontal: unstaged / staged

# Minimum body rows for any panel (header is one row on top of this).
comptime _PANEL_MIN_BODY:   Int = 1

# Overlay modes — when non-zero, an inline modal (commit prompt /
# confirmation / status flash) is on top of the normal LocalChanges UI
# and intercepts key events.
comptime _OVERLAY_NONE:           Int = 0
comptime _OVERLAY_COMMIT:         Int = 1   # type a commit message
comptime _OVERLAY_AMEND_CONFIRM:  Int = 2   # y/n: amend HEAD with --no-edit
comptime _OVERLAY_REVERT_CONFIRM: Int = 3   # y/n: discard changes for file
comptime _OVERLAY_STATUS:         Int = 4   # transient git pull/push/etc result


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


struct RightPanel(Movable):
    """One scrollable subpane on the right side. ``diff_line`` parallels
    ``lines``: the index into the source per-file diff text for body
    rows that can be staged / unstaged, and ``-1`` for synthetic lines
    (placeholder messages) that aren't part of any patch."""
    var lines: List[String]
    var diff_line: List[Int]
    var scroll: Int
    var scroll_x: Int
    var cursor: Int

    fn __init__(out self):
        self.lines = List[String]()
        self.diff_line = List[Int]()
        self.scroll = 0
        self.scroll_x = 0
        self.cursor = 0

    fn reset(mut self):
        self.lines = List[String]()
        self.diff_line = List[Int]()
        self.scroll = 0
        self.scroll_x = 0
        self.cursor = 0


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


fn _scroll_panel(mut panel: RightPanel, delta: Int, h_in: Int):
    """Free-function scroller: avoids Mojo's mut-self / mut-self.field
    aliasing rejection. Caller passes the focused panel's body height."""
    var n = len(panel.lines)
    var h = h_in
    if h < 1: h = 1
    var max_scroll = n - h
    if max_scroll < 0: max_scroll = 0
    var s = panel.scroll + delta
    if s < 0: s = 0
    if s > max_scroll: s = max_scroll
    panel.scroll = s
    if panel.cursor < panel.scroll:
        panel.cursor = panel.scroll
    var bottom = panel.scroll + h - 1
    if bottom >= n: bottom = n - 1
    if panel.cursor > bottom and bottom >= 0:
        panel.cursor = bottom


fn _move_panel_cursor(mut panel: RightPanel, delta: Int, h_in: Int):
    var n = len(panel.lines)
    if n == 0:
        return
    var c = panel.cursor + delta
    if c < 0: c = 0
    if c >= n: c = n - 1
    panel.cursor = c
    var h = h_in
    if h < 1: h = 1
    if panel.cursor < panel.scroll:
        panel.scroll = panel.cursor
    elif panel.cursor >= panel.scroll + h:
        panel.scroll = panel.cursor - h + 1
    if panel.scroll < 0:
        panel.scroll = 0


struct LocalChanges(Movable):
    var active: Bool
    var submitted: Bool
    var root: String
    # Sidebar data, one list per panel.
    var files: List[FileEntry]
    var branches: List[GitBranch]
    var commits: List[GitCommit]
    # Currently-focused pane (one of the six _PANE_* values).
    # ``last_sidebar_focus`` remembers which sidebar pane to return to
    # when the user presses Left from the right side.
    var focus: Int
    var last_sidebar_focus: Int
    # Selection + scroll state, per sidebar panel.
    var sel_file: Int
    var sel_branch: Int
    var sel_commit: Int
    var scroll_files: Int
    var scroll_branches: Int
    var scroll_commits: Int
    # Three right-side panel buckets. ``unstaged`` and ``staged`` are
    # populated for file selections; ``info`` is populated for branch /
    # commit selections (and shown as a single panel that takes the
    # full right side).
    var unstaged: RightPanel
    var staged: RightPanel
    var info: RightPanel
    # Cache key for the right-side content. ``"f:N"`` / ``"b:N"`` /
    # ``"c:N"`` — when the driving sidebar selection changes, all three
    # right panels are rebuilt.
    var _right_key: String
    # Splitter overrides. ``-1`` means "use the auto-computed default";
    # any positive value is the user's dragged setpoint and gets
    # clamped to the available space on each frame so resizing the
    # terminal doesn't break the layout.
    var sidebar_width_user: Int
    var files_height_user: Int
    var branches_height_user: Int
    var unstaged_height_user: Int
    # Which splitter (if any) the mouse is currently dragging. Cleared
    # on release. Drives the mouse-motion path in ``handle_mouse``.
    var _drag_kind: Int
    # Submission contract — same shape as the previous file-only
    # version: ``selected_path`` carries the project-relative file path
    # when a file row was Enter'd, ``selected_line`` is 0 ("no jump").
    var selected_path: String
    var selected_line: Int
    # Banner shown at the top when git failed entirely. Empty means
    # "render normally" (per-panel placeholders take over inside each
    # section if its data list is empty).
    var status_message: String
    # Inline modal overlay state. When ``overlay != _OVERLAY_NONE`` the
    # overlay intercepts key events. ``overlay_input`` is the typed
    # commit message; ``overlay_message`` is the static body text shown
    # for confirmations / status flashes; ``overlay_ok`` carries the
    # success/failure of a finished git op so the status flash can be
    # colored accordingly.
    var overlay: Int
    var overlay_input: String
    var overlay_message: String
    var overlay_ok: Bool

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
        self.unstaged = RightPanel()
        self.staged = RightPanel()
        self.info = RightPanel()
        self._right_key = String("")
        self.sidebar_width_user = -1
        self.files_height_user = -1
        self.branches_height_user = -1
        self.unstaged_height_user = -1
        self._drag_kind = _DRAG_NONE
        self.selected_path = String("")
        self.selected_line = 0
        self.status_message = String("")
        self.overlay = _OVERLAY_NONE
        self.overlay_input = String("")
        self.overlay_message = String("")
        self.overlay_ok = False

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
        self.unstaged.reset()
        self.staged.reset()
        self.info.reset()
        self._right_key = String("")
        self.sidebar_width_user = -1
        self.files_height_user = -1
        self.branches_height_user = -1
        self.unstaged_height_user = -1
        self._drag_kind = _DRAG_NONE
        self.selected_path = String("")
        self.selected_line = 0
        self.status_message = String("")
        self.overlay = _OVERLAY_NONE
        self.overlay_input = String("")
        self.overlay_message = String("")
        self.overlay_ok = False
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
        self.unstaged.reset()
        self.staged.reset()
        self.info.reset()
        self._right_key = String("")
        self.sidebar_width_user = -1
        self.files_height_user = -1
        self.branches_height_user = -1
        self.unstaged_height_user = -1
        self._drag_kind = _DRAG_NONE
        self.selected_path = String("")
        self.selected_line = 0
        self.status_message = String("")
        self.overlay = _OVERLAY_NONE
        self.overlay_input = String("")
        self.overlay_message = String("")
        self.overlay_ok = False

    # --- geometry ---------------------------------------------------------

    fn _sidebar_width(self, screen: Rect) -> Int:
        var max_w = screen.width() // 2
        if max_w > _SIDEBAR_MAX:
            max_w = _SIDEBAR_MAX
        if max_w < 16:
            max_w = 16
        var w: Int
        if self.sidebar_width_user > 0:
            w = self.sidebar_width_user
        else:
            w = screen.width() // 3
            if w < _SIDEBAR_MIN: w = _SIDEBAR_MIN
            if w > _SIDEBAR_MAX: w = _SIDEBAR_MAX
        if w < 16: w = 16
        if w > max_w: w = max_w
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
        ``[files_top, files_h, branches_top, branches_h, commits_top,
        commits_h]``. Each panel's first row is a section heading; the
        body fills the rest. Two splitter rows (``─``) sit between the
        three panels and are not counted in any panel's height — caller
        renders them at ``files_top + files_h`` and
        ``branches_top + branches_h``.

        Honors ``files_height_user`` / ``branches_height_user`` when
        they're set, clamping so every panel keeps at least one body
        row (``_min_h = 2``)."""
        var top = self._list_top(screen)
        var bottom = self._list_bottom(screen)
        var total = bottom - top
        if total < 6:
            total = 6
        var splitters = 2  # two horizontal splitters between three panels
        var content = total - splitters
        if content < 6:
            content = 6
        var min_h = 1 + _PANEL_MIN_BODY  # header row + body row
        var f_h: Int
        var b_h: Int
        if self.files_height_user > 0:
            f_h = self.files_height_user
        else:
            f_h = content // 3
        if self.branches_height_user > 0:
            b_h = self.branches_height_user
        else:
            b_h = content // 3
        if f_h < min_h: f_h = min_h
        if b_h < min_h: b_h = min_h
        # Make sure commits panel keeps at least min_h rows.
        if f_h + b_h > content - min_h:
            # Trim branches first (most recently sized), then files.
            var over = f_h + b_h - (content - min_h)
            var b_trim = b_h - min_h
            if over <= b_trim:
                b_h -= over
                _ = over
            else:
                over -= b_trim
                b_h = min_h
                var f_trim = f_h - min_h
                if over <= f_trim:
                    f_h -= over
                else:
                    f_h = min_h
        var c_h = content - f_h - b_h
        if c_h < min_h: c_h = min_h
        var out = List[Int]()
        out.append(top)
        out.append(f_h)
        out.append(top + f_h + 1)            # +1 for splitter row
        out.append(b_h)
        out.append(top + f_h + 1 + b_h + 1)  # +1 for second splitter row
        out.append(c_h)
        return out^

    fn _right_panes(self, screen: Rect) -> List[Int]:
        """Returns ``[unstaged_top, unstaged_h, staged_top, staged_h]``
        when the right side is split for a file selection. Same min-
        height clamping logic as ``_pane_rows`` so dragging never
        squashes a panel below one body row. Honors
        ``unstaged_height_user`` when set."""
        var top = self._list_top(screen)
        var bottom = self._list_bottom(screen)
        var total = bottom - top
        if total < 4:
            total = 4
        var splitters = 1  # one splitter between two panels
        var content = total - splitters
        if content < 4:
            content = 4
        var min_h = 1 + _PANEL_MIN_BODY
        var u_h: Int
        if self.unstaged_height_user > 0:
            u_h = self.unstaged_height_user
        else:
            u_h = content // 2
        if u_h < min_h: u_h = min_h
        if u_h > content - min_h: u_h = content - min_h
        if u_h < min_h: u_h = min_h
        var s_h = content - u_h
        if s_h < min_h: s_h = min_h
        var out = List[Int]()
        out.append(top)
        out.append(u_h)
        out.append(top + u_h + 1)   # +1 for splitter row
        out.append(s_h)
        return out^

    fn is_input_at(self, pos: Point, screen: Rect) -> Bool:
        return False

    # --- right-pane refresh ----------------------------------------------

    fn _focus_key(self) -> String:
        var driving = self._driving_pane()
        if driving == _PANE_FILES:
            return String("f:") + String(self.sel_file)
        if driving == _PANE_BRANCHES:
            return String("b:") + String(self.sel_branch)
        return String("c:") + String(self.sel_commit)

    fn _driving_pane(self) -> Int:
        """Which sidebar selection drives what shows on the right side.
        When focus is on a right-pane subpane, ``last_sidebar_focus``
        carries it; otherwise it's the focused pane itself."""
        if self.focus == _PANE_RIGHT_UNSTAGED \
                or self.focus == _PANE_RIGHT_STAGED \
                or self.focus == _PANE_RIGHT_INFO:
            return self.last_sidebar_focus
        return self.focus

    fn _is_right_focus(self) -> Bool:
        return self.focus == _PANE_RIGHT_UNSTAGED \
            or self.focus == _PANE_RIGHT_STAGED \
            or self.focus == _PANE_RIGHT_INFO

    fn _ensure_right_panels(mut self):
        """Recompute the three right-side panel caches when the driving
        sidebar selection changed. Keying by index (not content) means
        re-opening on a fresh tree pulls fresh data; staging mutations
        explicitly reset ``_right_key`` to force a rebuild."""
        var key = self._focus_key()
        if key == self._right_key \
                and (len(self.unstaged.lines) > 0
                     or len(self.staged.lines) > 0
                     or len(self.info.lines) > 0):
            return
        self._right_key = key
        self.unstaged.reset()
        self.staged.reset()
        self.info.reset()
        var driving = self._driving_pane()
        if driving == _PANE_FILES:
            if 0 <= self.sel_file and self.sel_file < len(self.files):
                self._build_files_right_panels()
            return
        if driving == _PANE_BRANCHES:
            if 0 <= self.sel_branch and self.sel_branch < len(self.branches):
                var b_name = self.branches[self.sel_branch].name
                var lines = _split_lines(
                    fetch_branch_log(self.root, b_name, 30),
                )
                for li in range(len(lines)):
                    self.info.lines.append(lines[li])
                    self.info.diff_line.append(-1)
            return
        # commits
        if 0 <= self.sel_commit and self.sel_commit < len(self.commits):
            var sha = self.commits[self.sel_commit].short_sha
            var lines = _split_lines(
                fetch_commit_show(self.root, sha),
            )
            for li in range(len(lines)):
                self.info.lines.append(lines[li])
                self.info.diff_line.append(-1)

    fn _build_files_right_panels(mut self):
        """Populate the unstaged + staged panels from the focused file's
        diffs. Untracked files (XY == ``"??"``) get a hint in the
        unstaged panel so the user knows to press Space on the file row
        to start tracking them."""
        var fe = self.files[self.sel_file]
        # Unstaged panel.
        if len(fe.unstaged_diff.as_bytes()) > 0:
            var u_lines = _split_lines(fe.unstaged_diff)
            for li in range(len(u_lines)):
                self.unstaged.lines.append(u_lines[li])
                self.unstaged.diff_line.append(li)
        else:
            if Int(fe.staged) == 0x3F and Int(fe.worktree) == 0x3F:
                self.unstaged.lines.append(
                    String(" (untracked — press Space on the file to stage it)"),
                )
            else:
                self.unstaged.lines.append(String(" (no unstaged changes)"))
            self.unstaged.diff_line.append(-1)
        # Staged panel.
        if len(fe.staged_diff.as_bytes()) > 0:
            var s_lines = _split_lines(fe.staged_diff)
            for li in range(len(s_lines)):
                self.staged.lines.append(s_lines[li])
                self.staged.diff_line.append(li)
        else:
            self.staged.lines.append(String(" (no staged changes)"))
            self.staged.diff_line.append(-1)

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
        var splitter_attr = Attr(LIGHT_GRAY, BLUE)
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
        # Vertical separator (also the sidebar/right splitter target).
        var sw = self._sidebar_width(screen)
        var sep_x = screen.a.x + sw
        for y in range(self._list_top(screen), self._list_bottom(screen)):
            canvas.set(sep_x, y, Cell(String("│"), sep_attr, 1))
        # Sidebar: three stacked panels with horizontal splitters between.
        var rows = self._pane_rows(screen)
        var left = screen.a.x + 1
        var right = screen.a.x + sw - 1
        self._paint_section(
            canvas, left, right, rows[0], rows[1],
            String("Modified files"), _PANE_FILES,
            section_attr, list_attr, sel_attr, sel_inactive, list_dim,
        )
        self._paint_horizontal_splitter(
            canvas, left, right, rows[0] + rows[1], splitter_attr,
        )
        self._paint_section(
            canvas, left, right, rows[2], rows[3],
            String("Branches"), _PANE_BRANCHES,
            section_attr, list_attr, sel_attr, sel_inactive, list_dim,
        )
        self._paint_horizontal_splitter(
            canvas, left, right, rows[2] + rows[3], splitter_attr,
        )
        self._paint_section(
            canvas, left, right, rows[4], rows[5],
            String("Commits"), _PANE_COMMITS,
            section_attr, list_attr, sel_attr, sel_inactive, list_dim,
        )
        # Right side: split (file mode) or single info panel.
        self._ensure_right_panels()
        self._paint_right_side(
            canvas, screen,
            section_attr, splitter_attr,
            ctx_attr, add_attr, rem_attr, hunk_attr, header_attr,
        )
        # Bottom hint.
        var hint: String
        if self._is_right_focus():
            hint = String(
                " Up/Down: line  Tab: panel  Space: stage/unstage  Left: back  ESC: close ",
            )
        elif self.focus == _PANE_FILES:
            hint = String(
                " c:commit A:amend d:revert p:pull P:push  Space:stage  Enter:open  ESC:close ",
            )
        else:
            hint = String(
                " Tab: pane  Up/Down: select  Right: diff  Space: stage  Enter: open  ESC: close ",
            )
        var hx = screen.b.x - len(hint.as_bytes()) - 1
        if hx < screen.a.x + 1:
            hx = screen.a.x + 1
        _ = canvas.put_text(Point(hx, screen.b.y - 1), hint, hint_attr)
        # Overlay last so it sits on top of everything else.
        if self.overlay != _OVERLAY_NONE:
            self._paint_overlay(canvas, screen)

    fn _paint_overlay(self, mut canvas: Canvas, screen: Rect):
        """Render the active overlay (commit prompt / confirmation /
        status flash) as a small drop-shadowed box centered on the
        modal area."""
        var border = Attr(BLACK, LIGHT_GRAY)
        var body   = Attr(BLACK, LIGHT_GRAY)
        var input_attr = Attr(BLACK, LIGHT_GRAY)
        var ok_attr   = Attr(WHITE, LIGHT_GREEN)
        var err_attr  = Attr(WHITE, LIGHT_RED)
        # Box geometry — 60 cols wide, 5 rows tall by default; clamps
        # to the modal area on tiny terminals.
        var max_w = screen.width() - 4
        var box_w = 64 if max_w >= 64 else max_w
        if box_w < 24:
            box_w = 24
        var box_h = 5
        var bx = screen.a.x + (screen.width() - box_w) // 2
        var by = screen.a.y + (screen.height() - box_h) // 2
        var rect = Rect(bx, by, bx + box_w, by + box_h)
        paint_drop_shadow(canvas, rect)
        canvas.fill(rect, String(" "), body)
        canvas.draw_box(rect, border, False)
        var title: String
        var prompt_text: String
        if self.overlay == _OVERLAY_COMMIT:
            title = String(" Commit ")
            prompt_text = String("message: ")
        elif self.overlay == _OVERLAY_AMEND_CONFIRM:
            title = String(" Amend ")
            prompt_text = String("")
        elif self.overlay == _OVERLAY_REVERT_CONFIRM:
            title = String(" Revert ")
            prompt_text = String("")
        else:
            title = String(" Status ")
            prompt_text = String("")
        var tx = bx + 2
        _ = canvas.put_text(Point(tx, by), title, border)
        if self.overlay == _OVERLAY_COMMIT:
            var label_x = bx + 2
            _ = canvas.put_text(
                Point(label_x, by + 2), prompt_text, body, bx + box_w - 1,
            )
            var input_x = label_x + len(prompt_text.as_bytes())
            _ = canvas.put_text(
                Point(input_x, by + 2), self.overlay_input, input_attr,
                bx + box_w - 1,
            )
            var cur_x = input_x + len(self.overlay_input.as_bytes())
            if cur_x < bx + box_w - 1:
                canvas.set(
                    cur_x, by + 2,
                    Cell(String(" "), Attr(LIGHT_GRAY, BLACK), 1),
                )
            var hint = String("Enter: commit   ESC: cancel")
            _ = canvas.put_text(
                Point(bx + 2, by + box_h - 2), hint, body, bx + box_w - 1,
            )
            return
        if self.overlay == _OVERLAY_STATUS:
            var attr = ok_attr if self.overlay_ok else err_attr
            canvas.fill(
                Rect(bx + 1, by + 2, bx + box_w - 1, by + 3),
                String(" "), attr,
            )
            _ = canvas.put_text(
                Point(bx + 2, by + 2), self.overlay_message, attr,
                bx + box_w - 1,
            )
            var hint = String("Press any key to dismiss")
            _ = canvas.put_text(
                Point(bx + 2, by + box_h - 2), hint, body, bx + box_w - 1,
            )
            return
        # Confirmation overlays.
        _ = canvas.put_text(
            Point(bx + 2, by + 1), self.overlay_message, body,
            bx + box_w - 1,
        )
        var hint = String("[y] confirm   [n] / ESC: cancel")
        _ = canvas.put_text(
            Point(bx + 2, by + box_h - 2), hint, body, bx + box_w - 1,
        )

    fn _paint_horizontal_splitter(
        self, mut canvas: Canvas, left: Int, right: Int, y: Int,
        attr: Attr,
    ):
        if right < left:
            return
        for x in range(left, right + 1):
            canvas.set(x, y, Cell(String("─"), attr, 1))

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
        # suppressed inside lazygit's selection highlight). The SHA
        # itself is green for commits that have been pushed to a remote
        # and red for commits that only exist locally — at-a-glance
        # signal of "what would I lose if this branch went away."
        var sha_pushed   = Attr(LIGHT_GREEN, BLUE)
        var sha_local    = Attr(LIGHT_RED,   BLUE)
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
            var seg_sha    = sha_pushed if co.is_pushed else sha_local
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

    fn _paint_right_side(
        mut self, mut canvas: Canvas, screen: Rect,
        section_attr: Attr, splitter_attr: Attr,
        ctx_attr: Attr, add_attr: Attr, rem_attr: Attr,
        hunk_attr: Attr, header_attr: Attr,
    ):
        var top = self._list_top(screen)
        var bottom = self._list_bottom(screen)
        var left = self._diff_left(screen)
        var right = self._diff_right(screen)
        if right <= left:
            return
        var driving = self._driving_pane()
        if driving == _PANE_FILES:
            var rp = self._right_panes(screen)
            self._paint_panel_with_header(
                canvas,
                Rect(left, rp[0], right + 1, rp[0] + rp[1]),
                String("Unstaged"), _PANE_RIGHT_UNSTAGED,
                self.unstaged,
                section_attr,
                ctx_attr, add_attr, rem_attr, hunk_attr, header_attr,
            )
            self._paint_horizontal_splitter(
                canvas, left, right, rp[0] + rp[1], splitter_attr,
            )
            self._paint_panel_with_header(
                canvas,
                Rect(left, rp[2], right + 1, rp[2] + rp[3]),
                String("Staged"), _PANE_RIGHT_STAGED,
                self.staged,
                section_attr,
                ctx_attr, add_attr, rem_attr, hunk_attr, header_attr,
            )
            return
        # Branch / commit info — single panel filling the right side.
        var info_title: String
        if driving == _PANE_BRANCHES:
            info_title = String("Branch log")
        else:
            info_title = String("Commit details")
        self._paint_panel_with_header(
            canvas,
            Rect(left, top, right + 1, bottom),
            info_title, _PANE_RIGHT_INFO,
            self.info,
            section_attr,
            ctx_attr, add_attr, rem_attr, hunk_attr, header_attr,
        )

    fn _paint_panel_with_header(
        self, mut canvas: Canvas,
        area: Rect,
        title: String, pane: Int,
        panel: RightPanel,
        section_attr: Attr,
        ctx_attr: Attr, add_attr: Attr, rem_attr: Attr,
        hunk_attr: Attr, header_attr: Attr,
    ):
        # Bind every write to ``area`` via a Painter — a long diff line
        # or an over-wide title can't bleed into the neighbour panel,
        # the splitter row, or off-screen. Children paint without
        # needing to thread a clip arg through every primitive call.
        if area.width() < 1 or area.height() < 1:
            return
        var painter = Painter(area)
        var header_rect = Rect(
            area.a.x, area.a.y, area.b.x, area.a.y + 1,
        )
        painter.fill(canvas, header_rect, String(" "), section_attr)
        var marker = String("> ") if self.focus == pane else String("  ")
        _ = painter.put_text(
            canvas, Point(area.a.x, area.a.y),
            marker + title, section_attr,
        )
        if area.height() <= 1:
            return
        var body_rect = Rect(
            area.a.x, area.a.y + 1, area.b.x, area.b.y,
        )
        self._paint_panel_body(
            canvas, body_rect, pane, panel,
            ctx_attr, add_attr, rem_attr, hunk_attr, header_attr,
        )

    fn _paint_panel_body(
        self, mut canvas: Canvas,
        area: Rect,
        pane: Int, panel: RightPanel,
        ctx_attr: Attr, add_attr: Attr, rem_attr: Attr,
        hunk_attr: Attr, header_attr: Attr,
    ):
        if area.is_empty() or len(panel.lines) == 0:
            return
        var painter = Painter(area)
        var cursor_active = Attr(BLACK, YELLOW)
        var cursor_inactive = Attr(BLACK, LIGHT_GRAY)
        var pane_focused = (self.focus == pane)
        var height = area.height()
        for i in range(height):
            var idx = panel.scroll + i
            if idx >= len(panel.lines):
                break
            var y = area.a.y + i
            var line = panel.lines[idx]
            var is_cursor = (idx == panel.cursor and pane_focused)
            var attr: Attr
            if is_cursor:
                attr = cursor_active
            else:
                attr = _line_attr(
                    line, ctx_attr, add_attr, rem_attr,
                    hunk_attr, header_attr,
                )
            # When the cursor row is highlighted, paint the entire row
            # background so the gap to the right reads as part of the
            # selection bar, matching the file-list behavior.
            if is_cursor:
                painter.fill(
                    canvas,
                    Rect(area.a.x, y, area.b.x, y + 1),
                    String(" "), attr,
                )
            var bytes = line.as_bytes()
            var start = panel.scroll_x
            if start >= len(bytes):
                continue
            var visible = String(StringSlice(
                unsafe_from_utf8=bytes[start:len(bytes)],
            ))
            _ = painter.put_text(
                canvas, Point(area.a.x, y), visible, attr,
            )
        _ = cursor_inactive   # reserved for future "cursor while focus elsewhere"

    # --- events -----------------------------------------------------------

    fn _focused_count(self) -> Int:
        if self.focus == _PANE_FILES: return len(self.files)
        if self.focus == _PANE_BRANCHES: return len(self.branches)
        if self.focus == _PANE_COMMITS: return len(self.commits)
        return 0

    fn _focused_selection(self) -> Int:
        if self.focus == _PANE_FILES: return self.sel_file
        if self.focus == _PANE_BRANCHES: return self.sel_branch
        if self.focus == _PANE_COMMITS: return self.sel_commit
        return 0

    fn _focused_panel_height(self, screen: Rect) -> Int:
        var rows = self._pane_rows(screen)
        var h: Int
        if self.focus == _PANE_FILES:
            h = rows[1] - 1
        elif self.focus == _PANE_BRANCHES:
            h = rows[3] - 1
        elif self.focus == _PANE_COMMITS:
            h = rows[5] - 1
        else:
            h = 0
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
        elif self.focus == _PANE_COMMITS:
            self.sel_commit = new
            if self.sel_commit < self.scroll_commits:
                self.scroll_commits = self.sel_commit
            elif self.sel_commit >= self.scroll_commits + h:
                self.scroll_commits = self.sel_commit - h + 1
            if self.scroll_commits < 0: self.scroll_commits = 0

    fn _cycle_focus(mut self, direction: Int):
        """Tab / Shift+Tab. In the sidebar (files/branches/commits)
        cycles through the three sidebar panels. In the right side
        cycles between Unstaged and Staged when both are visible (file
        mode); a no-op when on the single Info panel."""
        if self._is_right_focus():
            if self.focus == _PANE_RIGHT_INFO:
                return
            if self.focus == _PANE_RIGHT_UNSTAGED:
                self.focus = _PANE_RIGHT_STAGED
            else:
                self.focus = _PANE_RIGHT_UNSTAGED
            return
        var f = self.focus + direction
        if f < 0: f = 2
        if f > 2: f = 0
        self.focus = f
        self.last_sidebar_focus = f

    fn _focused_right_panel_height(self, screen: Rect) -> Int:
        if self.focus == _PANE_RIGHT_INFO:
            return self._diff_height(screen) - 1
        var rp = self._right_panes(screen)
        if self.focus == _PANE_RIGHT_UNSTAGED:
            return rp[1] - 1
        return rp[3] - 1

    fn _scroll_focused_right(mut self, delta: Int, screen: Rect):
        """Scroll the focused right panel and clamp its cursor.

        Dispatches to a free function (rather than a method) because
        Mojo's borrow checker rejects passing ``self.unstaged`` as a
        ``mut`` arg from a method that already holds ``mut self``."""
        var h = self._focused_right_panel_height(screen)
        if self.focus == _PANE_RIGHT_UNSTAGED:
            _scroll_panel(self.unstaged, delta, h)
        elif self.focus == _PANE_RIGHT_STAGED:
            _scroll_panel(self.staged, delta, h)
        elif self.focus == _PANE_RIGHT_INFO:
            _scroll_panel(self.info, delta, h)

    fn _move_focused_right_cursor(mut self, delta: Int, screen: Rect):
        var h = self._focused_right_panel_height(screen)
        if self.focus == _PANE_RIGHT_UNSTAGED:
            _move_panel_cursor(self.unstaged, delta, h)
        elif self.focus == _PANE_RIGHT_STAGED:
            _move_panel_cursor(self.staged, delta, h)
        elif self.focus == _PANE_RIGHT_INFO:
            _move_panel_cursor(self.info, delta, h)

    fn _enter_right_pane(mut self, screen: Rect):
        """Move focus from sidebar → right side. For file selections we
        land on Unstaged and snap the cursor to the first stageable
        ``+``/``-`` line so a single Space after Right does something
        useful. For branch/commit selections we land on Info."""
        if self._is_right_focus():
            return
        self.last_sidebar_focus = self.focus
        self._ensure_right_panels()
        var driving = self.last_sidebar_focus
        if driving == _PANE_FILES:
            self.focus = _PANE_RIGHT_UNSTAGED
            # Find first stageable line in unstaged; fall back to 0.
            var found = -1
            for i in range(len(self.unstaged.lines)):
                if self.unstaged.diff_line[i] >= 0:
                    var lb = self.unstaged.lines[i].as_bytes()
                    if len(lb) > 0:
                        var c0 = Int(lb[0])
                        if c0 == 0x2B or c0 == 0x2D:
                            found = i
                            break
            if found < 0:
                self.unstaged.cursor = 0
            else:
                self.unstaged.cursor = found
            var h = self._focused_right_panel_height(screen)
            if h < 1: h = 1
            if self.unstaged.cursor < self.unstaged.scroll:
                self.unstaged.scroll = self.unstaged.cursor
            elif self.unstaged.cursor >= self.unstaged.scroll + h:
                self.unstaged.scroll = self.unstaged.cursor - h + 1
            if self.unstaged.scroll < 0:
                self.unstaged.scroll = 0
            return
        # Branch / commit selection → single info panel.
        self.focus = _PANE_RIGHT_INFO

    fn _leave_right_pane(mut self):
        if not self._is_right_focus():
            return
        self.focus = self.last_sidebar_focus

    fn handle_key(mut self, event: Event, screen: Rect) -> Bool:
        if not self.active or event.kind != EVENT_KEY:
            return False
        if self.overlay != _OVERLAY_NONE:
            return self._handle_overlay_key(event)
        var k = event.key
        if k == KEY_ESC:
            self.close()
            return True
        # File-pane git operations: c / A / d / p / P. These are
        # repo-level (or selected-file-level) actions that only make
        # sense when the user is browsing the modified-files list, so
        # gate on focus to avoid surprising the user when typing through
        # branches / commits / right-pane scrolling.
        if self.focus == _PANE_FILES:
            if k == UInt32(0x63):       # 'c' → commit
                self._open_commit_prompt()
                return True
            if k == UInt32(0x41):       # 'A' → amend
                self._open_amend_confirm()
                return True
            if k == UInt32(0x64):       # 'd' → revert (discard) selected
                self._open_revert_confirm()
                return True
            if k == UInt32(0x70):       # 'p' → pull
                self._run_pull()
                return True
            if k == UInt32(0x50):       # 'P' → push
                self._run_push()
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
        if self._is_right_focus():
            if k == KEY_UP:
                self._move_focused_right_cursor(-1, screen)
                return True
            if k == KEY_DOWN:
                self._move_focused_right_cursor(1, screen)
                return True
            if k == KEY_HOME:
                self._move_focused_right_cursor(-100000, screen)
                return True
            if k == KEY_END:
                self._move_focused_right_cursor(100000, screen)
                return True
            if k == KEY_PAGEUP:
                var h = self._focused_right_panel_height(screen)
                self._scroll_focused_right(-h, screen)
                self._move_focused_right_cursor(-h, screen)
                return True
            if k == KEY_PAGEDOWN:
                var h = self._focused_right_panel_height(screen)
                self._scroll_focused_right(h, screen)
                self._move_focused_right_cursor(h, screen)
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
            self._set_focused_selection(
                self._focused_selection() - self._focused_panel_height(screen),
                screen,
            )
            return True
        if k == KEY_PAGEDOWN:
            self._set_focused_selection(
                self._focused_selection() + self._focused_panel_height(screen),
                screen,
            )
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
        * On Unstaged / Staged right panels: build a minimal patch from
          the cursor's single line and apply it (forward to stage from
          Unstaged, ``--reverse`` to unstage from Staged).

        Anywhere else (branches / commits / info / non-actionable line)
        it's a no-op rather than an error so the keystroke doesn't grab
        focus from a future binding.
        """
        if self.focus == _PANE_FILES:
            if 0 <= self.sel_file and self.sel_file < len(self.files):
                self._toggle_file_at(self.sel_file)
            return
        if self.focus == _PANE_RIGHT_UNSTAGED:
            var cursor = self.unstaged.cursor
            var n = len(self.unstaged.lines)
            if 0 <= cursor and cursor < n:
                var diff_idx = self.unstaged.diff_line[cursor]
                self._toggle_diff_line(diff_idx, False)
            return
        if self.focus == _PANE_RIGHT_STAGED:
            var cursor = self.staged.cursor
            var n = len(self.staged.lines)
            if 0 <= cursor and cursor < n:
                var diff_idx = self.staged.diff_line[cursor]
                self._toggle_diff_line(diff_idx, True)
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

    fn _toggle_diff_line(
        mut self, diff_line_idx: Int, reverse: Bool,
    ):
        """Build a minimal patch for ``diff_line_idx`` in the focused
        file's diff (staged when ``reverse``, unstaged otherwise) and
        pipe it to ``git apply --cached``. No-op when the index points
        at a placeholder / context line where there's nothing to
        toggle. Caller resolves the cursor → diff_line mapping; this
        keeps borrow-checker scope minimal."""
        if diff_line_idx < 0:
            return
        if self.sel_file < 0 or self.sel_file >= len(self.files):
            return
        var fe = self.files[self.sel_file]
        var source_diff: String
        if reverse:
            source_diff = fe.staged_diff
        else:
            source_diff = fe.unstaged_diff
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
        self.unstaged.reset()
        self.staged.reset()
        self.info.reset()

    fn _refresh_full(mut self):
        """Reload everything (files + branches + commits) and clear the
        right-pane cache. Used after commit / amend / pull / push since
        any of those can shuffle every list."""
        self._reload_files()
        self.branches = fetch_git_branches(self.root)
        self.commits = fetch_git_commits(self.root, 50)
        if self.sel_file >= len(self.files):
            self.sel_file = len(self.files) - 1
        if self.sel_file < 0:
            self.sel_file = 0
        if self.scroll_files > self.sel_file:
            self.scroll_files = self.sel_file
        if self.sel_branch >= len(self.branches):
            self.sel_branch = len(self.branches) - 1
        if self.sel_branch < 0:
            self.sel_branch = 0
        if self.sel_commit >= len(self.commits):
            self.sel_commit = len(self.commits) - 1
        if self.sel_commit < 0:
            self.sel_commit = 0
        self._right_key = String("")
        self.unstaged.reset()
        self.staged.reset()
        self.info.reset()

    # --- overlay (commit / confirm / status) ------------------------------

    fn _open_commit_prompt(mut self):
        """Pop the commit-message input. Pre-checks that *something* is
        actually staged so we don't pop a prompt that git will refuse."""
        var have_staged = False
        for i in range(len(self.files)):
            if Int(self.files[i].staged) != 0x20 \
                    and Int(self.files[i].staged) != 0x3F:
                have_staged = True
                break
        if not have_staged:
            self._show_status(
                String("Nothing staged — press Space on a file first."),
                False,
            )
            return
        self.overlay = _OVERLAY_COMMIT
        self.overlay_input = String("")
        self.overlay_message = String("")

    fn _open_amend_confirm(mut self):
        self.overlay = _OVERLAY_AMEND_CONFIRM
        self.overlay_input = String("")
        self.overlay_message = \
            String("Amend HEAD with --no-edit? Folds staged changes into the last commit.")

    fn _open_revert_confirm(mut self):
        if self.sel_file < 0 or self.sel_file >= len(self.files):
            self._show_status(String("No file selected."), False)
            return
        var fe = self.files[self.sel_file]
        self.overlay = _OVERLAY_REVERT_CONFIRM
        self.overlay_input = String("")
        var untracked = (Int(fe.staged) == 0x3F and Int(fe.worktree) == 0x3F)
        if untracked:
            self.overlay_message = \
                String("Delete untracked file ") + fe.path + String("?")
        else:
            self.overlay_message = \
                String("Discard ALL local changes for ") + fe.path \
                + String(" (staged + worktree)?")

    fn _show_status(mut self, var msg: String, ok: Bool):
        """Flash a one-shot status line. Dismissed by any keystroke."""
        self.overlay = _OVERLAY_STATUS
        self.overlay_message = msg^
        self.overlay_ok = ok
        self.overlay_input = String("")

    fn _close_overlay(mut self):
        self.overlay = _OVERLAY_NONE
        self.overlay_input = String("")
        self.overlay_message = String("")
        self.overlay_ok = False

    fn _run_pull(mut self):
        var r = git_pull(self.root)
        if r.ok:
            self._refresh_full()
        self._show_status(r.message, r.ok)

    fn _run_push(mut self):
        var r = git_push(self.root)
        if r.ok:
            self._refresh_full()
        self._show_status(r.message, r.ok)

    fn _submit_commit(mut self):
        var msg = self.overlay_input
        if len(msg.as_bytes()) == 0:
            self._show_status(String("Empty commit message."), False)
            return
        var r = git_commit(self.root, msg)
        if r.ok:
            self._refresh_full()
        self._show_status(r.message, r.ok)

    fn _confirm_amend(mut self):
        var r = git_amend_no_edit(self.root)
        if r.ok:
            self._refresh_full()
        self._show_status(r.message, r.ok)

    fn _confirm_revert(mut self):
        if self.sel_file < 0 or self.sel_file >= len(self.files):
            self._close_overlay()
            return
        var fe = self.files[self.sel_file]
        var r = git_revert_file(self.root, fe.path, fe.staged, fe.worktree)
        if r.ok:
            self._refresh_full()
        self._show_status(r.message, r.ok)

    fn _handle_overlay_key(mut self, event: Event) -> Bool:
        """Route key events while an overlay is active. Returns True to
        keep events from leaking to the underlying view."""
        var k = event.key
        if self.overlay == _OVERLAY_STATUS:
            # Any key dismisses the status flash. Pressing ESC again
            # afterwards closes the modal (normal handler runs next
            # frame).
            self._close_overlay()
            return True
        if k == KEY_ESC:
            self._close_overlay()
            return True
        if self.overlay == _OVERLAY_COMMIT:
            if k == KEY_ENTER:
                self._submit_commit()
                return True
            var clip = text_field_clipboard_key(event, self.overlay_input)
            if clip.consumed:
                return True
            if k == KEY_BACKSPACE:
                var bytes = self.overlay_input.as_bytes()
                if len(bytes) > 0:
                    self.overlay_input = String(StringSlice(
                        unsafe_from_utf8=bytes[:len(bytes) - 1]
                    ))
                return True
            if UInt32(0x20) <= k and k < UInt32(0x7F):
                self.overlay_input = self.overlay_input + chr(Int(k))
                return True
            return True
        # Confirmation overlays.
        if k == UInt32(0x79) or k == UInt32(0x59):    # y / Y
            if self.overlay == _OVERLAY_AMEND_CONFIRM:
                self._confirm_amend()
            elif self.overlay == _OVERLAY_REVERT_CONFIRM:
                self._confirm_revert()
            return True
        if k == UInt32(0x6E) or k == UInt32(0x4E):    # n / N
            self._close_overlay()
            return True
        return True

    # --- mouse / drag helpers ---------------------------------------------

    fn _hit_splitter(self, pos: Point, screen: Rect) -> Int:
        """Return ``_DRAG_*`` for the splitter at ``pos`` (1-cell hit
        zone), or ``_DRAG_NONE`` if the position isn't on any splitter.
        Vertical splitter is the ``│`` column at ``sep_x``; horizontal
        splitters are the ``─`` rows between sidebar/right sub-panels."""
        var top = self._list_top(screen)
        var bottom = self._list_bottom(screen)
        if pos.y < top or pos.y >= bottom:
            return _DRAG_NONE
        var sw = self._sidebar_width(screen)
        var sep_x = screen.a.x + sw
        # Vertical sidebar/right splitter.
        if pos.x == sep_x:
            return _DRAG_SIDEBAR
        var rows = self._pane_rows(screen)
        var split1_y = rows[0] + rows[1]
        var split2_y = rows[2] + rows[3]
        # Sidebar horizontal splitters span [screen.a.x, sep_x - 1].
        if pos.x >= screen.a.x and pos.x < sep_x:
            if pos.y == split1_y:
                return _DRAG_SPLIT_FB
            if pos.y == split2_y:
                return _DRAG_SPLIT_BC
        # Right-side horizontal splitter (file mode only).
        if self._driving_pane() == _PANE_FILES \
                and pos.x > sep_x and pos.x <= screen.b.x - 1:
            var rp = self._right_panes(screen)
            var split3_y = rp[0] + rp[1]
            if pos.y == split3_y:
                return _DRAG_SPLIT_US
        return _DRAG_NONE

    fn _apply_drag(mut self, pos: Point, screen: Rect):
        """Continue a drag: update the relevant override based on
        ``pos.y`` (or ``pos.x`` for the vertical splitter). The
        geometry helpers clamp on read, so we just store the raw value."""
        var top = self._list_top(screen)
        var bottom = self._list_bottom(screen)
        if self._drag_kind == _DRAG_SIDEBAR:
            var w = pos.x - screen.a.x
            if w < 16: w = 16
            var max_w = screen.width() // 2
            if max_w > _SIDEBAR_MAX: max_w = _SIDEBAR_MAX
            if w > max_w: w = max_w
            self.sidebar_width_user = w
            return
        if self._drag_kind == _DRAG_SPLIT_FB:
            # New files panel height = pos.y - top.
            var h = pos.y - top
            var min_h = 1 + _PANEL_MIN_BODY
            if h < min_h: h = min_h
            # Ensure at least min_h for branches + commits combined +
            # the second splitter row.
            var max_h = (bottom - top) - (2 * min_h) - 2
            if h > max_h: h = max_h
            if h < min_h: h = min_h
            self.files_height_user = h
            # When dragging files/branches splitter, leave branches in
            # auto unless user has explicitly sized it; geometry will
            # clamp.
            return
        if self._drag_kind == _DRAG_SPLIT_BC:
            # pos.y is the new branches-bottom; subtract files_top + f_h + 1
            # (splitter row) to get branches height.
            var rows = self._pane_rows(screen)
            var b_top = rows[2]
            var h = pos.y - b_top
            var min_h = 1 + _PANEL_MIN_BODY
            if h < min_h: h = min_h
            # Ensure commits keeps min_h: pos.y must leave at least
            # min_h rows below before list_bottom.
            var max_h = bottom - b_top - min_h - 1  # -1 for splitter row
            if h > max_h: h = max_h
            if h < min_h: h = min_h
            self.branches_height_user = h
            return
        if self._drag_kind == _DRAG_SPLIT_US:
            var h = pos.y - top
            var min_h = 1 + _PANEL_MIN_BODY
            if h < min_h: h = min_h
            var max_h = bottom - top - min_h - 1  # -1 for splitter row
            if h > max_h: h = max_h
            if h < min_h: h = min_h
            self.unstaged_height_user = h
            return

    fn _pane_at(self, pos: Point, screen: Rect) -> Int:
        """Return which sidebar pane (or -1 for "right pane / outside /
        on a splitter row") the cursor position falls in."""
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

    fn _right_pane_at(self, pos: Point, screen: Rect) -> Int:
        """Return _PANE_RIGHT_UNSTAGED / _PANE_RIGHT_STAGED /
        _PANE_RIGHT_INFO based on which sub-panel ``pos`` falls in. -1
        when ``pos`` is outside the right side or on the splitter row."""
        var sw = self._sidebar_width(screen)
        var sep_x = screen.a.x + sw
        if pos.x <= sep_x or pos.x > screen.b.x - 1:
            return -1
        var top = self._list_top(screen)
        var bottom = self._list_bottom(screen)
        if pos.y < top or pos.y >= bottom:
            return -1
        if self._driving_pane() != _PANE_FILES:
            return _PANE_RIGHT_INFO
        var rp = self._right_panes(screen)
        if pos.y >= rp[0] and pos.y < rp[0] + rp[1]:
            return _PANE_RIGHT_UNSTAGED
        if pos.y >= rp[2] and pos.y < rp[2] + rp[3]:
            return _PANE_RIGHT_STAGED
        return -1

    fn handle_mouse(mut self, event: Event, screen: Rect) -> Bool:
        if not self.active or event.kind != EVENT_MOUSE:
            return False
        # Modal overlay — swallow all mouse so clicks don't sneak under.
        if self.overlay != _OVERLAY_NONE:
            return True
        var pos = event.pos
        # --- in-progress splitter drag -----------------------------------
        # Resolved before any other handling so a click that *starts* on
        # a splitter never also triggers list-row behaviour even if the
        # cursor crosses into a panel mid-drag.
        if self._drag_kind != _DRAG_NONE:
            if event.button == MOUSE_BUTTON_LEFT and event.pressed \
                    and event.motion:
                self._apply_drag(pos, screen)
                return True
            if not event.pressed:
                self._drag_kind = _DRAG_NONE
                return True
            return True
        var sw = self._sidebar_width(screen)
        var sidebar_right = screen.a.x + sw
        # Wheel: forward to whichever pane the cursor sits over.
        if event.button == MOUSE_WHEEL_UP \
                or event.button == MOUSE_WHEEL_DOWN:
            var dy = -1 if event.button == MOUSE_WHEEL_UP else 1
            if pos.x > sidebar_right:
                # Right side — scroll the sub-panel under the cursor.
                var rpane = self._right_pane_at(pos, screen)
                if rpane < 0:
                    return True
                if self.focus != rpane:
                    if not self._is_right_focus():
                        self.last_sidebar_focus = self.focus
                    self.focus = rpane
                self._scroll_focused_right(3 * dy, screen)
                return True
            var pane = self._pane_at(pos, screen)
            if pane < 0:
                return True
            self.focus = pane
            self.last_sidebar_focus = pane
            self._set_focused_selection(
                self._focused_selection() + dy, screen,
            )
            return True
        # --- left-button press: drag-start, focus or selection ----------
        if event.button == MOUSE_BUTTON_LEFT and event.pressed \
                and not event.motion:
            # Splitter hit?
            var splitter = self._hit_splitter(pos, screen)
            if splitter != _DRAG_NONE:
                self._drag_kind = splitter
                return True
            # Right-side click: focus the sub-panel and jump line cursor.
            if pos.x > sidebar_right:
                var rpane = self._right_pane_at(pos, screen)
                if rpane < 0:
                    return True
                if not self._is_right_focus():
                    self.last_sidebar_focus = self.focus
                self.focus = rpane
                self._ensure_right_panels()
                # Determine which panel + its top to jump cursor.
                if rpane == _PANE_RIGHT_INFO:
                    var top = self._list_top(screen)
                    # Header is one row; clicking on header is a no-op.
                    if pos.y == top:
                        return True
                    var li = self.info.scroll + (pos.y - top - 1)
                    if 0 <= li and li < len(self.info.lines):
                        self.info.cursor = li
                    return True
                var rp = self._right_panes(screen)
                if rpane == _PANE_RIGHT_UNSTAGED:
                    if pos.y == rp[0]:
                        return True
                    var li = self.unstaged.scroll + (pos.y - rp[0] - 1)
                    if 0 <= li and li < len(self.unstaged.lines):
                        self.unstaged.cursor = li
                    return True
                # Staged.
                if pos.y == rp[2]:
                    return True
                var li = self.staged.scroll + (pos.y - rp[2] - 1)
                if 0 <= li and li < len(self.staged.lines):
                    self.staged.cursor = li
                return True
            # Sidebar click.
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
