"""LocalChanges: lazygit-style "what's going on with this repo?" view.

The left sidebar stacks three panels:

* **Modified files** — every entry from ``git status``: tracked files
  with staged or unstaged changes plus untracked files. Each row leads
  with the porcelain X (staged) and Y (worktree) columns colored green
  / red respectively, then the path. Enter opens the file; Space
  toggles whole-file staged status (``git add`` if there's anything in
  the worktree column, ``git restore --staged`` otherwise).
* **Branches** — local branches sorted by most recent commit, with the
  currently checked-out branch tagged ``*``. Space checks out the
  selected branch (``git checkout``); ``M`` integrates it into the
  checked-out branch, asking first *how* — ``m`` for a merge commit
  (``git merge --no-ff``) or ``r`` for straight history
  (``git rebase``); ``d`` deletes it, straight away
  when its work is already on ``main`` / ``master`` and behind a y/n
  confirm when it isn't (which is also what an unrecognized main line,
  or the main branch itself, gets). "Already on main" is decided by
  ``git_changes.branch_is_merged``, which compares *content* — a
  rebased or squash-merged branch counts as merged even though its
  commits carry different SHAs and ``git branch -d`` would refuse it.
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
``--reverse`` from Staged). ``http(s)://`` URLs in the info panel's text
— a commit message, a branch-log subject — paint as underlined blue
links and open in the system browser when clicked.

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

**Reporting outcomes.** Every git operation ends in one of three ways,
chosen by whether its output was the one git prints when nothing
interesting happened (``git_output.GitOutputMatcher``, which holds the
per-subcommand regexes for what "boring" looks like):

* *Routine success* — the spinner closes and a one-line summary lands on
  the sub-title row (``flash_message``), ageing out after ``_FLASH_MS``.
  Nothing to dismiss: the panels have already refreshed to show the
  result, so a modal would charge a keystroke for a confirmation.
* *Success with something to say* — a ``pre-push`` hook, or a Dokku-style
  remote streaming a deploy log back over ``remote:``. The output opens
  full screen (``_OVERLAY_OUTPUT``), scrolled to the bottom and
  scrollable, and waits for ESC. While such a child is still *running*,
  ``_promote_if_interesting`` also grows the corner spinner into the same
  full-screen frame, so a two-minute deploy is watchable live rather than
  summarized afterwards.
* *Failure* — same full-screen output view, for the same reason: nothing
  on screen changed to explain it.

``_show_status`` is the modal/non-modal fork; ``tick``'s reap is where the
three-way choice is made.
"""

from collections import Optional

from std.collections.list import List

from .canvas import Canvas, paint_drop_shadow, utf8_byte_to_cell, utf8_codepoint_count
from .cell import Cell
from .clipboard import clipboard_copy
from .colors import (
    Attr, BLACK, BORDER_FOCUS, CYAN, DARK_GRAY, EDITOR_BG, EDITOR_FG,
    GREEN, LIGHT_BLUE, LIGHT_CYAN, LIGHT_GRAY, LIGHT_GREEN, LIGHT_MAGENTA,
    LIGHT_RED, LIGHT_YELLOW, MAGENTA, STYLE_UNDERLINE, WHITE, YELLOW,
)
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_BACKSPACE, KEY_DOWN, KEY_END, KEY_ENTER, KEY_ESC, KEY_HOME, KEY_LEFT,
    KEY_PAGEDOWN, KEY_PAGEUP, KEY_RIGHT, KEY_SPACE, KEY_TAB, KEY_UP,
    MOD_CTRL, MOD_META, MOD_SHIFT,
    MOUSE_BUTTON_LEFT, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .geometry import Point, Rect
from .highlight import (
    GrammarRegistry, Highlight, HighlightCache,
    extension_of, highlight_for_extension_cached,
)
from .output_links import extract_url_links
from .painter import Painter
from .file_io import join_path, read_file
from .window import (
    DockChromeHit, DockedPanelStack,
    paint_window_title, paint_window_title_at,
)
from .git_changes import (
    ChangedFile, GitBranch, GitCommit, GitFileStatus, GitOpResult,
    apply_patch_to_index, apply_patch_to_worktree,
    compute_staged_diff, compute_unstaged_diff, compute_untracked_diff,
    branch_is_merged, create_reworded_commit,
    fetch_blob_text, fetch_branch_log, fetch_commit_message, fetch_commit_show,
    has_merge_between, head_short_sha,
    fetch_git_branches, fetch_git_commits, fetch_git_status,
    fetch_merged_commits,
    format_age,
    main_line_branch,
    git_state_mtimes, GitStateMtimes,
    parse_unified_diff_files,
    stage_file, unstage_file,
)
from .git_output import (
    GIT_OUT_BRANCH_DELETE, GIT_OUT_CHECKOUT, GIT_OUT_COMMIT, GIT_OUT_MERGE,
    GIT_OUT_OTHER, GIT_OUT_PULL, GIT_OUT_PUSH, GIT_OUT_REBASE,
    GIT_OUT_RESTORE,
    GitOutputMatcher, complete_lines,
)
from .posix import monotonic_ms, wall_clock_ms
from .install_runner import InstallRunner
from .string_utils import (
    display_columns,
    split_lines,
    split_lines_no_trailing,
    starts_with,
    tail_to_columns,
)
from .text_field import TextArea, TextField
from .type_ahead import TypeAhead, is_printable_ascii, type_ahead_pick
from .buttons import BUTTON_FIRED, ShadowButton, paint_shadow_button


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
comptime _OVERLAY_DISCARD_LINE_CONFIRM: Int = 5  # y/n: discard one worktree line
comptime _OVERLAY_DELETE_BRANCH_CONFIRM: Int = 6  # y/n: force-delete an unmerged branch
comptime _OVERLAY_OUTPUT: Int = 7   # full-screen scrollback of a git op's output
comptime _OVERLAY_MERGE_CHOICE: Int = 8  # m/r: merge commit or rebase
comptime _OVERLAY_EDIT_MSG: Int = 9  # multi-line edit of a commit message

# Save-button face for the message editor. The chord is spelled out on
# the button because Enter is taken by newlines in a multi-line input, so
# the key the user reaches for first is deliberately *not* the one that
# submits. Both modifiers are listed (and both are accepted) since the
# same label is painted by the native macOS host and the terminal
# frontend, where ⌘ doesn't exist.
comptime _SAVE_BTN_LABEL = " Save  ⌘/Ctrl+↵ "

# How long a success flash stays on the sub-title row before the row
# reverts to the project root. Long enough to read a one-liner, and it
# never stands between the user and their next keystroke.
comptime _FLASH_MS: Int = 4000

# Rows a PgUp / PgDn moves in the full-screen output log. A fixed step
# rather than a viewport-derived one: the key handler has no bounds, and
# paint clamps whatever it produces.
comptime _OUTPUT_PAGE: Int = 15

# Y/N answer keys (upper- and lowercase ASCII) for confirmation overlays.
comptime _KEY_Y_UPPER = UInt32(0x59)
comptime _KEY_Y_LOWER = UInt32(0x79)
comptime _KEY_N_UPPER = UInt32(0x4E)
comptime _KEY_N_LOWER = UInt32(0x6E)
# Answer keys for the merge-style choice: M(erge commit) / R(ebase).
comptime _KEY_M_UPPER = UInt32(0x4D)
comptime _KEY_M_LOWER = UInt32(0x6D)
comptime _KEY_R_UPPER = UInt32(0x52)
comptime _KEY_R_LOWER = UInt32(0x72)

# In-flight async git ops. Tracked so that on completion we know which
# op finished (for the success message + which refresh to run) and so
# the user-facing popup title reads naturally ("Pushing", "Pulling", …).
# Stored on ``LocalChanges._git_op`` while ``git_runner`` is active.
comptime _GITOP_NONE:    Int = 0
comptime _GITOP_COMMIT:  Int = 1
comptime _GITOP_AMEND:   Int = 2
comptime _GITOP_PULL:    Int = 3
comptime _GITOP_PUSH:    Int = 4
comptime _GITOP_REVERT:  Int = 5
comptime _GITOP_CHECKOUT: Int = 6
comptime _GITOP_MERGE:   Int = 7
comptime _GITOP_BRANCH_DELETE: Int = 8
comptime _GITOP_REBASE:  Int = 9
comptime _GITOP_REWORD:  Int = 10  # rewrite an unpushed commit's message

# How often (ms) the open modal re-checks git for state that changed on
# disk behind our back — a save in an editor, a commit/checkout in another
# terminal — so the panels never show a stale worktree. One ``git status``
# + a few ``stat`` calls per tick; cheap enough at ~1 Hz.
comptime _LC_POLL_INTERVAL_MS: Int = 1000

# Hard caps on the inputs we'll feed to the TextMate tokenizer for the
# diff side panels. Above either bound we skip syntax highlighting and
# render the diff with gutter colour only — a 200 KB minified JS file
# can take several seconds to tokenize with the JavaScript grammar
# (every regex walks every char of every long line), and that stalls
# the UI thread because tokenization is synchronous. The user can
# still navigate the diff and double-click to open the file in the
# editor where the highlighter runs incrementally.
comptime _HL_SIZE_CAP:    Int = 64 * 1024
comptime _HL_LONG_LINE:   Int = 2000

# Right-pane line kinds — drives the gutter glyph + colouring strategy
# in ``_paint_panel_body``. ``CTX`` / ``ADD`` / ``REM`` lines have had
# the unified-diff prefix byte stripped; the prefix character lives in
# the gutter column instead.
comptime _LINE_BLANK:     Int = 0
comptime _LINE_FILEHDR:   Int = 1
comptime _LINE_INFO:      Int = 2
comptime _LINE_CTX:       Int = 3
comptime _LINE_ADD:       Int = 4
comptime _LINE_REM:       Int = 5
comptime _LINE_NONEWLINE: Int = 6
comptime _LINE_SEPARATOR: Int = 7


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


@fieldwise_init
struct PanelLink(ImplicitlyCopyable, Movable):
    """One clickable ``http(s)://`` span found in a right-panel info row —
    in practice a URL in a commit message or a branch-log subject.

    ``row`` indexes ``RightPanel.lines``; ``cell_start`` / ``cell_end``
    (exclusive) are codepoint-cell offsets from the start of that line,
    matching how ``Canvas.put_text`` advances columns — so both the paint
    (underline) and the click hit-test convert to screen X the same way,
    by adding the panel's body origin and subtracting the horizontal
    scroll."""
    var row: Int
    var cell_start: Int
    var cell_end: Int
    var url: String


struct RightPanel(Movable):
    """One scrollable subpane on the right side. ``diff_line`` parallels
    ``lines``: the index into the source per-file diff text for body
    rows that can be staged / unstaged, and ``-1`` for synthetic lines
    (placeholder messages, file-name banners, blank separators) that
    aren't part of any patch.

    ``kind`` parallels ``lines`` and tags each row's render style — see
    the ``_LINE_*`` constants above. ``highlights`` is a syntax-colour
    overlay produced from the per-file diff body content; ``row``
    indexes into ``lines`` directly.

    ``file_path`` / ``file_line`` parallel ``lines`` and carry the
    project-relative path + 1-based line number that a body row maps
    to in the *after* file. Empty path / zero line for non-body rows
    (banners, blanks, info text) where there's nothing to jump to.
    Used by the double-click handler to open the file at the clicked
    line.

    ``links`` is a flat list (not parallel to ``lines`` — a row can hold
    several links, most hold none) of URL spans found in the panel's info
    rows; ``PanelLink.row`` indexes back into ``lines``."""
    var lines: List[String]
    var diff_line: List[Int]
    var kind: List[Int]
    var file_path: List[String]
    var file_line: List[Int]
    var highlights: List[Highlight]
    var links: List[PanelLink]
    var scroll: Int
    var scroll_x: Int
    var cursor: Int

    def __init__(out self):
        self.lines = List[String]()
        self.diff_line = List[Int]()
        self.kind = List[Int]()
        self.file_path = List[String]()
        self.file_line = List[Int]()
        self.highlights = List[Highlight]()
        self.links = List[PanelLink]()
        self.scroll = 0
        self.scroll_x = 0
        self.cursor = 0

    def reset(mut self):
        self.lines = List[String]()
        self.diff_line = List[Int]()
        self.kind = List[Int]()
        self.file_path = List[String]()
        self.file_line = List[Int]()
        self.highlights = List[Highlight]()
        self.links = List[PanelLink]()
        self.scroll = 0
        self.scroll_x = 0
        self.cursor = 0

    def link_at(self, row: Int, cell: Int) -> String:
        """URL of the link covering cell column ``cell`` of ``row``, or an
        empty string when the position isn't on a link."""
        for i in range(len(self.links)):
            var l = self.links[i]
            if l.row == row and cell >= l.cell_start and cell < l.cell_end:
                return l.url
        return String("")


def _line_starts_with_at_at(line: String) -> Bool:
    var b = line.as_bytes()
    return len(b) >= 2 and Int(b[0]) == 0x40 and Int(b[1]) == 0x40


def _convert_to_context(line: String) -> String:
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
    return String(StringSpan(unsafe_from_utf8=Span(out)))


def _append_line(mut buf: List[UInt8], line: String):
    var b = line.as_bytes()
    for i in range(len(b)):
        buf.append(b[i])
    buf.append(0x0A)


def build_minimal_patch(
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
    var lines = split_lines_no_trailing(file_diff)
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
    return String(StringSpan(unsafe_from_utf8=Span(out)))


def _first_useful_line(text: String) -> String:
    """Return the *last* non-empty line of ``text``, trimmed of trailing
    whitespace. Git's structured ops (``commit`` / ``push`` / ``pull`` /
    ``checkout``) write their headline result on the last meaningful
    line — ``[main abc1234] subject``, ``abc1234..def5678 main -> main``,
    ``Already up to date.`` — so the bottom line is the most useful
    one-row summary. Falls back to the empty string when ``text`` is
    all blank."""
    var b = text.as_bytes()
    var end = len(b)
    # Trim trailing whitespace (newlines, CR, spaces, tabs).
    while end > 0 and (b[end - 1] == 0x0A or b[end - 1] == 0x0D
            or b[end - 1] == 0x20 or b[end - 1] == 0x09):
        end -= 1
    if end == 0:
        return String("")
    # Walk back to the start of this line.
    var start = end
    while start > 0 and b[start - 1] != 0x0A and b[start - 1] != 0x0D:
        start -= 1
    # Strip leading whitespace inside the line so the message reads
    # cleanly when git indents progress dots (``  remote: ...``).
    while start < end and (b[start] == 0x20 or b[start] == 0x09):
        start += 1
    if start >= end:
        return String("")
    return String(StringSpan(unsafe_from_utf8=b[start:end]))


def _byte_to_string(b: UInt8) -> String:
    """Wrap a single byte as a one-char ``String``. Used for rendering
    porcelain status codes (always ASCII) one column at a time so the
    X column and Y column can take different colors."""
    var buf = List[UInt8]()
    buf.append(b)
    return String(StringSpan(unsafe_from_utf8=Span(buf)))


def _take_first_char(s: String) -> String:
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
    return String(StringSpan(unsafe_from_utf8=b[:n]))


def _take_after_first_char(s: String) -> String:
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
    return String(StringSpan(unsafe_from_utf8=b[n:len(b)]))


def _ascii_upper_str(s: String) -> String:
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
    return String(StringSpan(unsafe_from_utf8=Span(out)))


def _author_abbrev(author: String) -> String:
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
            words.append(String(StringSpan(unsafe_from_utf8=b[s:i])))
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


def _author_color(author: String) -> UInt8:
    """Stable palette index for ``author`` — same name always maps to the
    same color, so a committer's rows are visually grouped down the log.

    The ten candidates are all named ANSI-16 constants (so a theme remaps
    them with the rest of the chrome) and all read with high contrast against
    the default blue editor background — blues are deliberately excluded. The
    set is wider than the two-letter abbreviation can be distinct, so two
    authors who share initials (``AH``) still get told apart by color.

    FNV-1a over the raw bytes (the full name, not the abbreviation, so
    distinct people don't collide on shared initials), folded into the
    palette. UInt32 arithmetic wraps on overflow, which is what FNV relies on.
    """
    var palette = [
        LIGHT_CYAN, LIGHT_GREEN, LIGHT_YELLOW, LIGHT_MAGENTA, LIGHT_RED,
        CYAN, GREEN, YELLOW, MAGENTA, WHITE,
    ]
    var b = author.as_bytes()
    var h = UInt32(2166136261)
    for i in range(len(b)):
        h = (h ^ UInt32(b[i])) * UInt32(16777619)
    return palette[Int(h % UInt32(len(palette)))]


def _scroll_panel(mut panel: RightPanel, delta: Int, h_in: Int):
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


def _move_panel_cursor(mut panel: RightPanel, delta: Int, h_in: Int):
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


def _strip_first_byte_to_string(s: String) -> String:
    """Drop the leading byte of ``s`` (the ``+`` / ``-`` / `` `` diff
    prefix). Returns an empty ``String`` when ``s`` is shorter than one
    byte. The diff prefix is always ASCII so byte-strip is codepoint-
    safe."""
    var b = s.as_bytes()
    if len(b) <= 1:
        return String("")
    return String(StringSpan(unsafe_from_utf8=b[1:]))


def _build_filename_banner(path: String, width: Int) -> String:
    """Make a ``-- path -----------`` banner sized to ``width``.

    Always emits at least eight trailing dashes so the banner reads as
    a divider even when the panel is narrow enough that the path alone
    would fill the row. Width includes the leading two dashes + space
    + path + space; ``width`` is just a hint to extend the trailing
    dashes."""
    var prefix = String("-- ") + path + String(" ")
    var have = len(prefix.as_bytes())
    var pad = width - have
    if pad < 8:
        pad = 8
    var dashes = List[UInt8]()
    for _ in range(pad):
        dashes.append(0x2D)
    return prefix + String(StringSpan(unsafe_from_utf8=Span(dashes)))


def _is_skip_diff_header(line: String) -> Bool:
    """``True`` when ``line`` is one of the unified-diff machine headers
    we hide from the human-facing rendering: ``diff --git``, ``index ``,
    ``--- ``, ``+++ ``, ``@@ ...``, plus the lesser-seen rename / mode
    metadata lines that git emits between ``diff --git`` and ``index``.
    Body content (``+``, ``-``, ``\\``, `` `` prefixes) is preserved."""
    var b = line.as_bytes()
    if len(b) == 0:
        return False
    var c0 = Int(b[0])
    # ``@@``-prefixed hunk header.
    if c0 == 0x40 and len(b) >= 2 and Int(b[1]) == 0x40:
        return True
    if starts_with(line, String("diff --git ")):
        return True
    if starts_with(line, String("index ")):
        return True
    if starts_with(line, String("--- ")):
        return True
    if starts_with(line, String("+++ ")):
        return True
    if starts_with(line, String("new file mode ")):
        return True
    if starts_with(line, String("deleted file mode ")):
        return True
    if starts_with(line, String("old mode ")):
        return True
    if starts_with(line, String("new mode ")):
        return True
    if starts_with(line, String("similarity index ")):
        return True
    if starts_with(line, String("dissimilarity index ")):
        return True
    if starts_with(line, String("rename from ")):
        return True
    if starts_with(line, String("rename to ")):
        return True
    if starts_with(line, String("copy from ")):
        return True
    if starts_with(line, String("copy to ")):
        return True
    return False


def _emit_filename_banner(
    mut panel: RightPanel, path: String, width: Int,
):
    panel.lines.append(_build_filename_banner(path, width))
    panel.kind.append(_LINE_FILEHDR)
    panel.diff_line.append(-1)
    panel.file_path.append(String(""))
    panel.file_line.append(0)


def _emit_blank(mut panel: RightPanel):
    panel.lines.append(String(""))
    panel.kind.append(_LINE_BLANK)
    panel.diff_line.append(-1)
    panel.file_path.append(String(""))
    panel.file_line.append(0)


def _emit_separator(mut panel: RightPanel):
    """A horizontal rule between two hunks of the same file. The text is
    empty — ``_paint_panel_body`` draws the rule across the panel width at
    paint time so it tracks the current panel size."""
    panel.lines.append(String(""))
    panel.kind.append(_LINE_SEPARATOR)
    panel.diff_line.append(-1)
    panel.file_path.append(String(""))
    panel.file_line.append(0)


def _emit_info(mut panel: RightPanel, var text: String):
    """Append a free-form info row. Info rows are the human-facing text of
    a commit (author / date / message) or a branch log line, so they're
    scanned for ``http(s)://`` URLs here — the paint underlines them and a
    click opens them in the browser. Diff body rows deliberately aren't
    scanned: a URL inside changed *code* is a diff line to stage, not a
    link to follow."""
    var hits = extract_url_links(text)
    var row = len(panel.lines)
    for i in range(len(hits)):
        panel.links.append(PanelLink(
            row, hits[i].cell_start, hits[i].cell_end, hits[i].path,
        ))
    panel.lines.append(text^)
    panel.kind.append(_LINE_INFO)
    panel.diff_line.append(-1)
    panel.file_path.append(String(""))
    panel.file_line.append(0)


def _emit_body_row(
    mut panel: RightPanel,
    var text: String, kind: Int, diff_idx: Int,
    path: String, line: Int,
):
    panel.lines.append(text^)
    panel.kind.append(kind)
    panel.diff_line.append(diff_idx)
    panel.file_path.append(path)
    panel.file_line.append(line)


def _cells_skipped(line: String, scroll_x: Int) -> Int:
    """Cell columns of ``line`` hidden off the left edge by the panel's
    ``scroll_x``, which is a *byte* offset (the panels slice raw bytes to
    scroll). Link spans are in cell offsets, so they need this conversion
    before they can be turned into screen columns."""
    if scroll_x <= 0:
        return 0
    var bytes = line.as_bytes()
    if scroll_x >= len(bytes):
        return utf8_codepoint_count(line)
    return utf8_byte_to_cell(line)[scroll_x]


def _underline_row_links(
    mut canvas: Canvas, painter: Painter, panel: RightPanel,
    row: Int, y: Int, body_x: Int, x_max: Int, attr: Attr,
):
    """Stamp ``attr`` over every URL span of ``row``, which is painted at
    screen row ``y`` starting at column ``body_x`` (exclusive right edge
    ``x_max``). Attr-only writes, so the glyphs the row already painted
    stay put and only their colour + underline change."""
    var skipped = _cells_skipped(panel.lines[row], panel.scroll_x)
    for i in range(len(panel.links)):
        var l = panel.links[i]
        if l.row != row:
            continue
        var x0 = body_x + l.cell_start - skipped
        var x1 = body_x + l.cell_end - skipped
        if x0 < body_x:
            x0 = body_x
        if x1 > x_max:
            x1 = x_max
        for x in range(x0, x1):
            painter.set_attr(canvas, x, y, attr)


def _parse_hunk_starts(line: String, mut old_start: Int, mut new_start: Int):
    """Parse ``-a[,b] +c[,d]`` from a ``@@ -a,b +c,d @@`` hunk header.
    Sets ``old_start`` / ``new_start`` to 1-based line numbers, or -1
    when the corresponding side is malformed. Both numbers come from
    the same header so we parse them together rather than running two
    passes over the same bytes."""
    old_start = -1
    new_start = -1
    var b = line.as_bytes()
    var n = len(b)
    if n < 4 or Int(b[0]) != 0x40 or Int(b[1]) != 0x40:
        return
    var i = 2
    while i < n and Int(b[i]) == 0x20:
        i += 1
    # ``-a[,b]``
    if i < n and Int(b[i]) == 0x2D:
        i += 1
        var v = 0
        var have = False
        while i < n:
            var c = Int(b[i])
            if c < 0x30 or c > 0x39:
                break
            v = v * 10 + (c - 0x30)
            have = True
            i += 1
        if have:
            old_start = v
        # Skip the ``,b`` portion if present.
        while i < n and Int(b[i]) != 0x20 and Int(b[i]) != 0x09:
            i += 1
    while i < n and (Int(b[i]) == 0x20 or Int(b[i]) == 0x09):
        i += 1
    # ``+c[,d]``
    if i < n and Int(b[i]) == 0x2B:
        i += 1
        var v = 0
        var have = False
        while i < n:
            var c = Int(b[i])
            if c < 0x30 or c > 0x39:
                break
            v = v * 10 + (c - 0x30)
            have = True
            i += 1
        if have:
            new_start = v


def _first_change_line(diff_text: String) -> Int:
    """1-based line in the *after* file of the first added or removed
    line in ``diff_text`` — where a double-click on a file *name* (the
    panel banner or a Files-pane row) should land the cursor, mirroring
    the per-row jump that ``_populate_diff_panel`` computes for body
    rows. Returns 0 when there's no usable change position (binary diff,
    empty diff, or a change with no corresponding new-file line), which
    the caller treats as "open at the top"."""
    var src_lines = split_lines_no_trailing(diff_text)
    var new_line: Int = -1
    var old_line: Int = -1
    for i in range(len(src_lines)):
        var ln = src_lines[i]
        var b = ln.as_bytes()
        if len(b) >= 2 and Int(b[0]) == 0x40 and Int(b[1]) == 0x40:
            _parse_hunk_starts(ln, old_line, new_line)
            continue
        if _is_skip_diff_header(ln):
            continue
        if len(b) == 0:
            if new_line > 0:
                new_line += 1
            if old_line > 0:
                old_line += 1
            continue
        var c0 = Int(b[0])
        if c0 == 0x2B or c0 == 0x2D:    # first ``+``/``-`` line
            return new_line if new_line > 0 else 0
        if c0 == 0x20:
            if new_line > 0:
                new_line += 1
            if old_line > 0:
                old_line += 1
    return 0


def _emit_panel_highlights(
    mut panel: RightPanel,
    side_text: String,
    file_path: String,
    display_to_side_row: List[Int],
    mut registry: GrammarRegistry,
):
    """Tokenize ``side_text`` (the full file content for one side of
    the diff — before or after) and copy each emitted highlight to
    every display row in ``display_to_side_row`` that maps to it.

    Tokenizing the full file rather than just the diff body lets the
    grammar resolve multi-line scopes that begin or end outside the
    visible hunks. Same call path as ``Editor.flush_highlights``: the
    process-wide ``GrammarRegistry`` caches the loaded grammar across
    panels.

    Skipped on inputs above ``_HL_SIZE_CAP`` bytes or with any line
    longer than ``_HL_LONG_LINE`` codepoints — the JavaScript /
    TypeScript grammars walk every regex across every char of every
    long line, and a 200 KB minified file stalls the UI thread for
    seconds. The diff still renders with gutter colours in that case;
    double-clicking opens the worktree file in the editor where the
    highlighter runs incrementally."""
    if len(side_text.as_bytes()) == 0:
        return
    if len(side_text.as_bytes()) > _HL_SIZE_CAP:
        return
    var side_lines = split_lines_no_trailing(side_text)
    if len(side_lines) == 0:
        return
    for li in range(len(side_lines)):
        if len(side_lines[li].as_bytes()) > _HL_LONG_LINE:
            return
    var ext = extension_of(file_path)
    var cache = HighlightCache()
    var hls = highlight_for_extension_cached(
        ext, side_lines, registry, cache,
    )
    if len(hls) == 0:
        return
    # Inverse map: for each side row, the list of display rows that
    # render that line. Keeps the emit loop O(hits) rather than
    # O(display × hits).
    var inv = List[List[Int]]()
    for _ in range(len(side_lines)):
        inv.append(List[Int]())
    for d in range(len(display_to_side_row)):
        var r = display_to_side_row[d]
        if 0 <= r and r < len(side_lines):
            inv[r].append(d)
    for h in range(len(hls)):
        var hl = hls[h]
        if hl.row < 0 or hl.row >= len(inv):
            continue
        for k in range(len(inv[hl.row])):
            panel.highlights.append(
                Highlight(
                    inv[hl.row][k],
                    hl.col_start, hl.col_end, hl.attr,
                ),
            )


def _populate_diff_panel(
    mut panel: RightPanel,
    diff_text: String,
    file_path: String,
    before_text: String,
    after_text: String,
    banner_width: Int,
    mut registry: GrammarRegistry,
):
    """Transform a per-file unified diff into the human-facing layout
    the panel paints: a ``-- path ---`` banner, a blank, the body lines
    with their diff prefix moved to the gutter, then two trailing
    blanks so the next file (or the bottom of the panel) reads as
    separated.

    ``panel.diff_line[i]`` keeps each rendered body row pointed at its
    original line in ``diff_text`` so the staging path
    (``build_minimal_patch`` → ``git apply --cached``) keeps working
    against the unmodified diff text. Headers / banners / blanks get
    ``-1`` because they aren't part of any patch.

    Syntax-highlight strategy: each side of the diff is tokenized in
    full so multi-line scopes (block comments, triple-quoted strings)
    resolve correctly even when only part of the construct lives in
    the visible hunks. Highlights from the *after* file go onto ``+``
    and context rows; highlights from the *before* file go onto ``-``
    rows. Either side can be empty (untracked file → no before; binary
    file or fetch failure → no after) — those rows just paint without
    a syntax overlay."""
    var src_lines = split_lines_no_trailing(diff_text)
    var banner_idx = len(panel.lines)
    _emit_filename_banner(panel, file_path, banner_width)
    # Make the file-name banner double-clickable: point it at the first
    # change so the editor lands there rather than the top of the file.
    var first_chg = _first_change_line(diff_text)
    if first_chg > 0:
        panel.file_path[banner_idx] = file_path
        panel.file_line[banner_idx] = first_chg
    _emit_blank(panel)
    # Per-display-row mapping into each side's full file. -1 means "no
    # corresponding line on this side" — banners, blanks, and the
    # opposite side's removed/added rows.
    var display_to_after_row = List[Int]()
    var display_to_before_row = List[Int]()
    display_to_after_row.append(-1)    # banner
    display_to_before_row.append(-1)
    display_to_after_row.append(-1)    # blank
    display_to_before_row.append(-1)
    # 1-based current line on each side; -1 = no hunk header seen yet.
    var new_line: Int = -1
    var old_line: Int = -1
    var seen_hunk = False
    for i in range(len(src_lines)):
        var ln = src_lines[i]
        var b = ln.as_bytes()
        # ``@@ -a,b +c,d @@`` resets both line counters.
        if len(b) >= 2 and Int(b[0]) == 0x40 and Int(b[1]) == 0x40:
            # Draw a rule between consecutive hunks; the first hunk in a
            # file already has the banner above it as a separator.
            if seen_hunk:
                _emit_separator(panel)
                display_to_after_row.append(-1)
                display_to_before_row.append(-1)
            seen_hunk = True
            _parse_hunk_starts(ln, old_line, new_line)
            continue
        if _is_skip_diff_header(ln):
            continue
        # ``jump_line`` for body rows: the 1-based line in the *after*
        # file the user lands on when they double-click this row. For
        # ``+`` and context this is the row's own new-file position;
        # for ``-`` it's the upcoming new-file position (the row that
        # took the deletion's place, or the next live line) so a
        # double-click on a removal still lands somewhere meaningful.
        if len(b) == 0:
            # Bare blank inside a hunk: treat as context.
            var jump = new_line if new_line > 0 else 0
            _emit_body_row(
                panel, String(""), _LINE_CTX, i, file_path, jump,
            )
            display_to_after_row.append(
                new_line - 1 if new_line > 0 else -1,
            )
            display_to_before_row.append(
                old_line - 1 if old_line > 0 else -1,
            )
            if new_line > 0:
                new_line += 1
            if old_line > 0:
                old_line += 1
            continue
        var c0 = Int(b[0])
        if c0 == 0x5C:    # ``\ No newline at end of file``
            _emit_body_row(
                panel, ln, _LINE_NONEWLINE, i, String(""), 0,
            )
            display_to_after_row.append(-1)
            display_to_before_row.append(-1)
            continue
        if c0 == 0x2B:
            var jump = new_line if new_line > 0 else 0
            _emit_body_row(
                panel, _strip_first_byte_to_string(ln),
                _LINE_ADD, i, file_path, jump,
            )
            display_to_after_row.append(
                new_line - 1 if new_line > 0 else -1,
            )
            display_to_before_row.append(-1)
            if new_line > 0:
                new_line += 1
            continue
        if c0 == 0x2D:
            var jump = new_line if new_line > 0 else 0
            _emit_body_row(
                panel, _strip_first_byte_to_string(ln),
                _LINE_REM, i, file_path, jump,
            )
            display_to_after_row.append(-1)
            display_to_before_row.append(
                old_line - 1 if old_line > 0 else -1,
            )
            if old_line > 0:
                old_line += 1
            continue
        if c0 == 0x20:
            var jump = new_line if new_line > 0 else 0
            _emit_body_row(
                panel, _strip_first_byte_to_string(ln),
                _LINE_CTX, i, file_path, jump,
            )
            display_to_after_row.append(
                new_line - 1 if new_line > 0 else -1,
            )
            display_to_before_row.append(
                old_line - 1 if old_line > 0 else -1,
            )
            if new_line > 0:
                new_line += 1
            if old_line > 0:
                old_line += 1
            continue
        # Anything else: keep raw, treat as info so it doesn't get a
        # gutter mark.
        _emit_body_row(
            panel, ln, _LINE_INFO, -1, String(""), 0,
        )
        display_to_after_row.append(-1)
        display_to_before_row.append(-1)
    _emit_blank(panel)
    _emit_blank(panel)
    display_to_after_row.append(-1)
    display_to_before_row.append(-1)
    display_to_after_row.append(-1)
    display_to_before_row.append(-1)
    _emit_panel_highlights(
        panel, after_text, file_path, display_to_after_row, registry,
    )
    _emit_panel_highlights(
        panel, before_text, file_path, display_to_before_row, registry,
    )


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
    # URL queued by a click on a link in a commit message / branch log.
    # Non-empty for exactly one frame: the desktop drains it right after
    # dispatching the event and hands it to ``open_url``. Kept as an
    # intent (rather than shelling out from here) so the modal stays free
    # of process-spawning side effects and tests can assert on the click.
    var pending_open_url: String
    # Banner shown at the top when git failed entirely. Empty means
    # "render normally" (per-panel placeholders take over inside each
    # section if its data list is empty).
    var status_message: String
    # Inline modal overlay state. When ``overlay != _OVERLAY_NONE`` the
    # overlay intercepts key events. ``overlay_input`` is the typed
    # commit message; ``overlay_message`` is the static body text shown
    # for confirmations and for the failure flash.
    #
    # Only *failures* reach the modal ``_OVERLAY_STATUS`` flash — a
    # successful op reports through ``flash_message`` below, so it never
    # costs a dismissal keystroke. See ``_show_status``.
    var overlay: Int
    var overlay_input: TextField
    var overlay_message: String
    # ``_OVERLAY_EDIT_MSG`` state: the multi-line editor holding the
    # message being rewritten, plus which commit it belongs to.
    # ``_reword_sha`` is the short SHA as shown in the list;
    # ``_reword_is_head`` picks the apply strategy (a plain ``--amend``
    # for the tip, a replay for anything older — see ``_submit_reword``).
    # The Save button is a field rather than a per-paint temporary because
    # ``ShadowButton`` latches a press across frames.
    var overlay_area: TextArea
    var _reword_sha: String
    var _reword_is_head: Bool
    var _reword_save_btn: ShadowButton
    # Where the text area was last painted, recorded by ``_paint_edit_msg``
    # so click-to-position hit-tests the same rect that was drawn instead
    # of recomputing the box geometry and drifting from it.
    var _reword_area_rect: Rect
    # Transient, non-modal one-liner on the sub-title row: what the last
    # successful git op did. Painted until ``_flash_until_ms``, after
    # which the row goes back to showing the project root. Intercepts no
    # input, so it can't interrupt anything.
    var flash_message: String
    var _flash_until_ms: Int
    # Full-screen scrollback for a git op whose output wasn't the routine
    # one (``_OVERLAY_OUTPUT``): a deploy log streamed back over
    # ``remote:``, a chatty hook, or any failure. ``overlay_output_scroll``
    # is the first visible line; it starts pinned to the bottom, since the
    # part you want is what the command said last.
    var overlay_output: String
    var overlay_output_scroll: Int
    # Compiled "what does boring look like" patterns for the op in flight,
    # plus whether we've already decided this one isn't boring. Sticky:
    # once promoted, we stop re-classifying, so a long deploy log costs
    # one match pass rather than one per frame.
    var _output_matcher: GitOutputMatcher
    var _output_promoted: Bool
    # The three sidebar panels (Modified files / Branches / Commits)
    # share the framework ``DockedPanelStack`` for min/max state, layout
    # and chrome dispatch. Section indices match the ``_PANE_FILES`` /
    # ``_PANE_BRANCHES`` / ``_PANE_COMMITS`` ordering — same identifiers
    # used elsewhere for focus tracking.
    var sidebar_dock: DockedPanelStack
    # Type-to-jump prefix buffer for whichever sidebar pane currently
    # owns focus. The Files pane keeps its bare-letter git shortcuts
    # (c / A / d / p / P), so type-to-jump only fires on Branches /
    # Commits — wiring the Files pane would silently steal those
    # action shortcuts from active git workflows. Branches makes the
    # same trade for two letters: ``M`` (merge) and ``d`` (delete) are
    # actions there and never reach the prefix buffer.
    var _type_ahead: TypeAhead
    # Async runner for the slow git ops (commit / push / pull / amend /
    # revert). The UI used to call ``git_commit`` / ``git_push`` etc.
    # synchronously, which froze the modal — and the whole desktop — for
    # the duration of a push to a slow remote. The runner spawns each
    # op as a child process, drains stdout/stderr per frame, and surfaces
    # a non-modal popup with a spinner + tail of the live output. On
    # exit, ``tick`` reaps the result, refreshes the affected panels,
    # and flashes the usual one-line status overlay.
    var git_runner: InstallRunner
    var _git_op: Int            # one of the _GITOP_* values; _NONE when idle
    var _git_op_label: String   # short label flashed in the success status
    var _git_revert_path: String  # path being reverted (for _GITOP_REVERT)
    var _git_revert_untracked: Bool
    # Branch being switched to (for _GITOP_CHECKOUT) — used for the status
    # flash and to re-select the same branch after the refresh reorders
    # the list (branches sort by most recent commit).
    var _git_checkout_branch: String
    # Branch being brought into the current one (for _GITOP_MERGE and
    # _GITOP_REBASE, whichever the merge-style overlay picked) and the one
    # being deleted (for _GITOP_BRANCH_DELETE). Both feed the status flash,
    # which reads better naming the branch than echoing git's own output;
    # the merge one is also what the choice overlay's wording is built
    # from, so it's set before the answer rather than at spawn time.
    var _git_merge_branch: String
    var _git_delete_branch: String
    # Straight-history integration is three git commands, not one (see
    # ``_confirm_merge_rebase``). ``_rebase_step`` is which one is in
    # flight — 0 none, 1 rebase, 2 checkout back, 3 fast-forward merge —
    # and ``_rebase_onto`` is the branch that was checked out when the
    # user answered, i.e. the one the work is being integrated *into*.
    var _rebase_step: Int
    var _rebase_onto: String
    # Output of the chain's finished steps, and whether any of them said
    # something non-routine. Spawning the next step resets the runner's
    # capture, so a talkative rebase would otherwise scroll away unread
    # before the chain reached the point where it reports.
    var _rebase_log: String
    var _rebase_noisy: Bool
    # Diff-line index queued for line-level discard, captured when the
    # confirmation overlay opens and consumed when the user confirms.
    var _discard_diff_idx: Int
    # Last submitted commit message that hasn't yet succeeded. Saved in
    # ``_submit_commit`` before the overlay closes; cleared in ``tick``
    # when the commit op reaps ok. Used to pre-fill the commit prompt
    # so a hook failure (or other rejection) doesn't force the user to
    # retype the message. Persists across modal close/reopen.
    var _pending_commit_message: String
    # Baseline for the external-change poll (see ``_poll_external_change``).
    # ``_poll_status_fp`` fingerprints the ``git status`` rows (worktree +
    # index), ``_poll_state`` the ``.git`` metadata mtimes (commit / checkout
    # / reset). Both are re-seeded in ``_reload_files`` every time we reload —
    # whether from our own mutation or from a detected external change — so the
    # poll only fires on state we *didn't* cause. ``_last_poll_ms`` rate-limits.
    var _poll_status_fp: String
    var _poll_state: GitStateMtimes
    var _last_poll_ms: Int

    def __init__(out self):
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
        self.pending_open_url = String("")
        self.status_message = String("")
        self.overlay = _OVERLAY_NONE
        self.overlay_input = TextField()
        self.overlay_message = String("")
        self.overlay_area = TextArea()
        self._reword_sha = String("")
        self._reword_is_head = False
        self._reword_save_btn = ShadowButton(String(_SAVE_BTN_LABEL), 0, 0)
        self._reword_area_rect = Rect(0, 0, 0, 0)
        self.flash_message = String("")
        self._flash_until_ms = 0
        self.overlay_output = String("")
        self.overlay_output_scroll = 0
        self._output_matcher = GitOutputMatcher()
        self._output_promoted = False
        self.sidebar_dock = DockedPanelStack()
        # Order must match ``_PANE_FILES`` / ``_PANE_BRANCHES`` /
        # ``_PANE_COMMITS`` (0/1/2).
        _ = self.sidebar_dock.add(String("Modified files"))
        _ = self.sidebar_dock.add(String("Branches"))
        _ = self.sidebar_dock.add(String("Commits"))
        self._type_ahead = TypeAhead()
        self.git_runner = InstallRunner()
        self._git_op = _GITOP_NONE
        self._git_op_label = String("")
        self._git_revert_path = String("")
        self._git_revert_untracked = False
        self._git_checkout_branch = String("")
        self._git_merge_branch = String("")
        self._git_delete_branch = String("")
        self._rebase_step = 0
        self._rebase_onto = String("")
        self._rebase_log = String("")
        self._rebase_noisy = False
        self._discard_diff_idx = -1
        self._pending_commit_message = String("")
        self._poll_status_fp = String("")
        self._poll_state = GitStateMtimes.zero()
        self._last_poll_ms = 0

    def open(mut self, var root: String):
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
        self.pending_open_url = String("")
        self.status_message = String("")
        self.overlay = _OVERLAY_NONE
        self.overlay_input = TextField()
        self.overlay_message = String("")
        self.overlay_area = TextArea()
        self._reword_sha = String("")
        self._reword_is_head = False
        self._reword_save_btn = ShadowButton(String(_SAVE_BTN_LABEL), 0, 0)
        self._reword_area_rect = Rect(0, 0, 0, 0)
        self.flash_message = String("")
        self._flash_until_ms = 0
        self.overlay_output = String("")
        self.overlay_output_scroll = 0
        self._output_matcher = GitOutputMatcher()
        self._output_promoted = False
        self.sidebar_dock.reset()
        self._type_ahead.reset()
        self._git_op = _GITOP_NONE
        self._git_op_label = String("")
        self._git_revert_path = String("")
        self._git_revert_untracked = False
        self._git_checkout_branch = String("")
        self._git_merge_branch = String("")
        self._git_delete_branch = String("")
        self._rebase_step = 0
        self._rebase_onto = String("")
        self._rebase_log = String("")
        self._rebase_noisy = False
        self._reload_files()
        self.branches = fetch_git_branches(self.root)
        self.commits = fetch_git_commits(self.root, 50)
        # If the worktree is clean *and* there are no commits / branches
        # at all the modal isn't really useful — leave the banner up.
        if len(self.files) == 0 \
                and len(self.branches) == 0 and len(self.commits) == 0:
            self.status_message = \
                String("No git data (empty repo or git unavailable).")

    def _reload_files(mut self):
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
        # Re-seed the external-change poll baseline off the same status we
        # just read, so a reload we initiated never re-triggers the poll.
        self._poll_status_fp = LocalChanges._status_fingerprint(statuses)
        self._poll_state = git_state_mtimes(self.root)
        self._last_poll_ms = monotonic_ms()

    @staticmethod
    def _status_fingerprint(statuses: List[GitFileStatus]) -> String:
        """A compact, order-stable digest of ``git status`` rows — staged +
        worktree code and path per entry. Equal fingerprints mean the
        worktree/index state the modal renders is unchanged."""
        var fp = String("")
        for i in range(len(statuses)):
            var s = statuses[i]
            fp += String(Int(s.staged)) + "," + String(Int(s.worktree))
            fp += ":" + s.path + "\n"
        return fp^

    def _poll_external_change(mut self):
        """While the modal is open, watch for git state that changed on disk
        behind our back — an editor saved a file, a commit/checkout/reset
        happened in another terminal — and reload so the panels never show a
        stale worktree. Rate-limited to ~1 Hz.

        Skipped while one of our own git ops is in flight (it refreshes on
        completion via ``tick``) and while an overlay is up (a refresh would
        shuffle the list a confirmation prompt is pinned to). The status
        fingerprint catches worktree + index changes; the ``.git`` mtime
        fingerprint catches commits / checkouts that leave the worktree
        unchanged but reshuffle the Branches / Commits panels."""
        if not self.active:
            return
        if self._git_op != _GITOP_NONE:
            return
        if self.overlay != _OVERLAY_NONE:
            return
        var now = monotonic_ms()
        if now - self._last_poll_ms < _LC_POLL_INTERVAL_MS:
            return
        self._last_poll_ms = now
        var statuses = fetch_git_status(self.root)
        var fp = LocalChanges._status_fingerprint(statuses)
        var state = git_state_mtimes(self.root)
        if fp == self._poll_status_fp and state.equals(self._poll_state):
            return
        # ``_refresh_full`` reloads every panel, clamps the selections, and
        # re-seeds the poll baseline through ``_reload_files``.
        self._refresh_full()

    def close(mut self):
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
        self.pending_open_url = String("")
        self.status_message = String("")
        self.overlay = _OVERLAY_NONE
        self.overlay_input = TextField()
        self.overlay_message = String("")
        self.overlay_area = TextArea()
        self._reword_sha = String("")
        self._reword_is_head = False
        self._reword_save_btn = ShadowButton(String(_SAVE_BTN_LABEL), 0, 0)
        self._reword_area_rect = Rect(0, 0, 0, 0)
        self.flash_message = String("")
        self._flash_until_ms = 0
        self.overlay_output = String("")
        self.overlay_output_scroll = 0
        self._output_matcher = GitOutputMatcher()
        self._output_promoted = False
        self.sidebar_dock.reset()
        self._type_ahead.reset()
        self._git_op = _GITOP_NONE
        self._git_op_label = String("")
        self._git_revert_path = String("")
        self._git_revert_untracked = False
        self._git_checkout_branch = String("")
        self._git_merge_branch = String("")
        self._git_delete_branch = String("")
        self._rebase_step = 0
        self._rebase_onto = String("")
        self._rebase_log = String("")
        self._rebase_noisy = False

    # --- geometry ---------------------------------------------------------

    def _panel_rect(self, container_bounds: Rect) -> Rect:
        """The modal always paints fullscreen — it intercepts every
        input event, so a non-fullscreen "windowed" mode wouldn't gain
        anything visible behind it that the user could interact with."""
        return container_bounds

    def _sidebar_width(self, container_bounds: Rect) -> Int:
        """Sidebar width in cells. The auto-default (no user drag yet)
        targets ~⅓ of the window with the ``_SIDEBAR_MIN``/``MAX``
        comfort range. Once the user drags, only natural bounds apply
        — the splitter must stay one cell inside the box on each side
        so the borders don't get clobbered, but otherwise the user can
        crush the sidebar (or the right side) all the way to 1 cell."""
        var hard_max = container_bounds.width() - 2
        if hard_max < 1:
            hard_max = 1
        var w: Int
        if self.sidebar_width_user >= 0:
            w = self.sidebar_width_user
        else:
            w = container_bounds.width() // 3
            if w < _SIDEBAR_MIN: w = _SIDEBAR_MIN
            if w > _SIDEBAR_MAX: w = _SIDEBAR_MAX
        if w < 1: w = 1
        if w > hard_max: w = hard_max
        return w

    def _list_top(self, container_bounds: Rect) -> Int:
        return container_bounds.a.y + 2

    def _list_bottom(self, container_bounds: Rect) -> Int:
        return container_bounds.b.y - 1

    def _list_height(self, container_bounds: Rect) -> Int:
        var h = self._list_bottom(container_bounds) - self._list_top(container_bounds)
        return 0 if h < 0 else h

    def _diff_left(self, container_bounds: Rect) -> Int:
        return container_bounds.a.x + self._sidebar_width(container_bounds) + 1

    def _diff_right(self, container_bounds: Rect) -> Int:
        return container_bounds.b.x - 1

    def _diff_width(self, container_bounds: Rect) -> Int:
        var w = self._diff_right(container_bounds) - self._diff_left(container_bounds) - 1
        return 0 if w < 0 else w

    def _diff_height(self, container_bounds: Rect) -> Int:
        return self._list_height(container_bounds)

    def _pane_rows(self, container_bounds: Rect) -> List[Int]:
        """Return the y-row layout for the three sidebar panels:
        ``[files_top, files_h, branches_top, branches_h, commits_top,
        commits_h]``. Each panel's first row is a section heading; the
        body fills the rest. Two splitter rows (``─``) sit between the
        three panels and are not counted in any panel's height — caller
        renders them at ``files_top + files_h`` and
        ``branches_top + branches_h``.

        Delegates to ``DockedPanelStack.layout`` when any section is in
        a non-NORMAL state (the state machine drives the heights). When
        all sections are NORMAL we honor ``files_height_user`` /
        ``branches_height_user`` so the user's splitter drags persist
        across frames."""
        var top = self._list_top(container_bounds)
        var bottom = self._list_bottom(container_bounds)
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
        var c_h: Int
        if not self.sidebar_dock.all_normal():
            return self.sidebar_dock.layout(top, bottom)
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
        c_h = content - f_h - b_h
        if c_h < min_h: c_h = min_h
        var out = List[Int]()
        out.append(top)
        out.append(f_h)
        out.append(top + f_h + 1)            # +1 for splitter row
        out.append(b_h)
        out.append(top + f_h + 1 + b_h + 1)  # +1 for second splitter row
        out.append(c_h)
        return out^

    def _right_panes(self, container_bounds: Rect) -> List[Int]:
        """Returns ``[unstaged_top, unstaged_h, staged_top, staged_h]``
        when the right side is split for a file selection. Same min-
        height clamping logic as ``_pane_rows`` so dragging never
        squashes a panel below one body row. Honors
        ``unstaged_height_user`` when set."""
        var top = self._list_top(container_bounds)
        var bottom = self._list_bottom(container_bounds)
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

    def is_input_at(self, pos: Point, container_bounds: Rect) -> Bool:
        return False

    # --- right-pane refresh ----------------------------------------------

    def _focus_key(self) -> String:
        var driving = self._driving_pane()
        if driving == _PANE_FILES:
            return String("f:") + String(self.sel_file)
        if driving == _PANE_BRANCHES:
            return String("b:") + String(self.sel_branch)
        return String("c:") + String(self.sel_commit)

    def _driving_pane(self) -> Int:
        """Which sidebar selection drives what shows on the right side.
        When focus is on a right-pane subpane, ``last_sidebar_focus``
        carries it; otherwise it's the focused pane itself."""
        if self.focus == _PANE_RIGHT_UNSTAGED \
                or self.focus == _PANE_RIGHT_STAGED \
                or self.focus == _PANE_RIGHT_INFO:
            return self.last_sidebar_focus
        return self.focus

    def _is_right_focus(self) -> Bool:
        return self.focus == _PANE_RIGHT_UNSTAGED \
            or self.focus == _PANE_RIGHT_STAGED \
            or self.focus == _PANE_RIGHT_INFO

    def _ensure_right_panels(
        mut self, mut registry: GrammarRegistry,
    ):
        """Recompute the three right-side panel caches when the driving
        sidebar selection changed. Keying by index (not content) means
        re-opening on a fresh tree pulls fresh data; staging mutations
        explicitly reset ``_right_key`` to force a rebuild.

        ``registry`` is the process-wide grammar cache used by
        ``_populate_diff_panel`` to syntax-colour the diff body lines."""
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
                self._build_files_right_panels(registry)
            return
        if driving == _PANE_BRANCHES:
            if 0 <= self.sel_branch and self.sel_branch < len(self.branches):
                var b_name = self.branches[self.sel_branch].name
                var lines = split_lines_no_trailing(
                    fetch_branch_log(self.root, b_name, 30),
                )
                for li in range(len(lines)):
                    _emit_info(self.info, lines[li])
            return
        # commits
        if 0 <= self.sel_commit and self.sel_commit < len(self.commits):
            var co = self.commits[self.sel_commit]
            var show_text = fetch_commit_show(self.root, co.short_sha)
            # Only a merge has commits hiding behind it; for everything
            # else this stays empty and the section isn't painted.
            var merged = String("")
            if co.is_merge():
                merged = fetch_merged_commits(self.root, co.short_sha)
            self._populate_commit_info(show_text, merged, registry)

    def _populate_commit_info(
        mut self, show_text: String, merged_log: String,
        mut registry: GrammarRegistry,
    ):
        """Render ``git show`` output into the info panel: commit
        metadata + message rendered as info rows, then each file's
        diff rendered through ``_populate_diff_panel`` so the same
        gutter + syntax-highlight treatment applies. The split point
        is the first ``diff --git`` line — everything before it is
        free-form metadata that is meant for humans, everything from
        it onward is a multi-file unified diff.

        ``merged_log`` is :func:`fetch_merged_commits` output for a merge
        commit (empty otherwise). It's inserted between the metadata and
        the diff, because "which commits came in with this merge" is the
        first question a merge row raises and the ``Merge:`` header line
        git prints answers it only in raw SHAs."""
        var lines = split_lines_no_trailing(show_text)
        var diff_start = -1
        for i in range(len(lines)):
            if starts_with(lines[i], String("diff --git ")):
                diff_start = i
                break
        var meta_end = diff_start if diff_start >= 0 else len(lines)
        for li in range(meta_end):
            _emit_info(self.info, lines[li])
        self._emit_merged_commits(merged_log)
        if diff_start < 0:
            return
        # Walk per-file diff chunks and feed each one to the same
        # transform the unstaged/staged panels use.
        var diff_part_bytes = List[UInt8]()
        for li in range(diff_start, len(lines)):
            var lb = lines[li].as_bytes()
            for j in range(len(lb)):
                diff_part_bytes.append(lb[j])
            diff_part_bytes.append(0x0A)
        var diff_part = String(StringSpan(
            unsafe_from_utf8=Span(diff_part_bytes),
        ))
        var changed = parse_unified_diff_files(diff_part)
        var banner_w = 200
        # Skip syntax highlighting for commits: a single click in the
        # log can land on a commit that touched dozens of large files,
        # and tokenizing both blobs for each one stalls the UI.
        # Gutter colour + plain text is enough information to read the
        # diff; double-clicking still opens the worktree file at the
        # right line, where the editor's full highlighter takes over.
        for k in range(len(changed)):
            _populate_diff_panel(
                self.info, changed[k].diff, changed[k].path,
                String(""), String(""), banner_w, registry,
            )

    def _emit_merged_commits(mut self, merged_log: String):
        """Emit the "Merged commits" section for a merge commit.

        ``merged_log`` is :func:`fetch_merged_commits` output — two lines
        per commit (``<sha>  <date>  <author>`` then an indented subject)
        plus a blank separator. Continuation lines start with a space, so
        the commit count is the number of non-blank lines that don't."""
        if len(merged_log.as_bytes()) == 0:
            return
        var lines = split_lines_no_trailing(merged_log)
        var count = 0
        for i in range(len(lines)):
            var b = lines[i].as_bytes()
            if len(b) > 0 and b[0] != 0x20:
                count += 1
        if count == 0:
            return
        _emit_info(self.info, String(""))
        var plural = String(" commits:") if count != 1 else String(" commit:")
        _emit_info(
            self.info, String("Merged ") + String(count) + plural,
        )
        for i in range(len(lines)):
            if len(lines[i].as_bytes()) == 0:
                _emit_info(self.info, String(""))
            else:
                _emit_info(self.info, String("  ") + lines[i])

    def _ensure_untracked_diff(mut self):
        """Fill in ``unstaged_diff`` for the focused file when it's
        untracked, so the changes panel shows the whole file as additions
        instead of just a "not tracked yet" note.

        Neither whole-tree fetch in ``_reload_files`` can see an
        untracked file (``git diff`` walks the index), so the diff has to
        come from a per-file ``git diff --no-index`` against
        ``/dev/null``. That's one git spawn, which is why it happens here
        — lazily, for the selected row only — rather than in
        ``_reload_files``, where a tree with hundreds of untracked files
        would pay hundreds of spawns on every staging mutation.

        The result is cached back onto the ``FileEntry`` so the
        line-level staging and discard paths (which read
        ``fe.unstaged_diff``) work on untracked files too, and so a
        repaint doesn't respawn git. ``_reload_files`` rebuilds
        ``self.files`` from scratch, which drops the cache exactly when
        the file's contents may have changed.

        Stays a no-op for a tracked file, for a file whose diff is
        already known, and when git returns nothing (a collapsed ``dir/``
        entry — see ``compute_untracked_diff``). In that last case the
        probe re-runs on the next panel rebuild, which is bounded by the
        hint row ``_build_files_right_panels`` always emits: the panel is
        never empty, so ``_ensure_right_panels`` won't rebuild until the
        selection actually moves."""
        if self.sel_file < 0 or self.sel_file >= len(self.files):
            return
        var fe = self.files[self.sel_file]
        if Int(fe.staged) != 0x3F or Int(fe.worktree) != 0x3F:
            return
        if len(fe.unstaged_diff.as_bytes()) > 0:
            return
        var text = compute_untracked_diff(self.root, fe.path)
        if len(text.as_bytes()) == 0:
            return
        # Normalize through the same splitter the tracked diffs go
        # through, so the stored text is a single-file chunk with the
        # path resolved the same way. We asked about one path, so a
        # lone chunk is ours even when its header path doesn't compare
        # equal — git C-quotes a path containing spaces, and the quoted
        # form is what ``git apply`` wants back anyway.
        var chunks = parse_unified_diff_files(text)
        if len(chunks) == 1:
            self.files[self.sel_file].unstaged_diff = chunks[0].diff
            return
        for i in range(len(chunks)):
            if chunks[i].path == fe.path:
                self.files[self.sel_file].unstaged_diff = chunks[i].diff
                return

    def _build_files_right_panels(
        mut self, mut registry: GrammarRegistry,
    ):
        """Populate the unstaged + staged panels from the focused file's
        diffs. Untracked files (XY == ``"??"``) have no diff in either
        whole-tree fetch, so ``_ensure_untracked_diff`` synthesizes one
        showing the whole file as additions; a hint row above it says
        the file isn't tracked yet.

        For syntax highlighting we hand ``_populate_diff_panel`` the
        full *after* text of each side: the worktree file for the
        unstaged side (read directly from disk — that *is* the after
        version) and the index blob for the staged side. Pulling the
        full file rather than just the diff body lets the tokenizer
        see scope context that ends or starts outside the visible
        hunks (block comments, triple-quoted strings, …)."""
        self._ensure_untracked_diff()
        var fe = self.files[self.sel_file]
        # Banner width is a hint only — the painter clips long banners
        # at the panel edge, so a generous fixed width keeps the dashes
        # filling the row at any panel size we render at.
        var banner_w = 200
        # Unstaged panel. The "after" side is the worktree file (read
        # from disk), the "before" side is the index blob (stage 0).
        # Either fetch may fail (untracked file → no index entry,
        # binary / missing file → no worktree text) — both gracefully
        # degrade to "no full-file highlights for that side".
        var untracked = (Int(fe.staged) == 0x3F and Int(fe.worktree) == 0x3F)
        if untracked:
            _emit_info(
                self.unstaged,
                String(" (untracked — press Space on the file to stage it)"),
            )
        if len(fe.unstaged_diff.as_bytes()) > 0:
            var after: String
            try:
                after = read_file(join_path(self.root, fe.path))
            except:
                after = String("")
            var before = fetch_blob_text(
                self.root, String(""), fe.path,
            )
            _populate_diff_panel(
                self.unstaged, fe.unstaged_diff, fe.path,
                before, after, banner_w, registry,
            )
        elif not untracked:
            _emit_info(self.unstaged, String(" (no unstaged changes)"))
        # Staged panel. "After" is the index blob, "before" is HEAD.
        if len(fe.staged_diff.as_bytes()) > 0:
            var after = fetch_blob_text(
                self.root, String(""), fe.path,
            )
            var before = fetch_blob_text(
                self.root, String("HEAD"), fe.path,
            )
            _populate_diff_panel(
                self.staged, fe.staged_diff, fe.path,
                before, after, banner_w, registry,
            )
        else:
            _emit_info(self.staged, String(" (no staged changes)"))

    # --- paint ------------------------------------------------------------

    def paint(
        mut self, mut canvas: Canvas, container_bounds: Rect,
        mut registry: GrammarRegistry,
    ):
        if not self.active:
            return
        var bg          = Attr(YELLOW, EDITOR_BG)
        var border      = Attr(BORDER_FOCUS, EDITOR_BG)
        var title_attr  = Attr(BORDER_FOCUS, EDITOR_BG)
        var sep_attr    = Attr(BORDER_FOCUS, EDITOR_BG)
        var hint_attr   = Attr(BLACK,  LIGHT_GRAY)
        var list_attr   = Attr(YELLOW, EDITOR_BG)
        var list_dim    = Attr(EDITOR_FG, EDITOR_BG)
        var sel_attr    = Attr(BLACK,  YELLOW)
        var sel_inactive = Attr(BLACK, LIGHT_GRAY)
        var section_attr = Attr(WHITE, DARK_GRAY)
        var splitter_attr = Attr(EDITOR_FG, EDITOR_BG)
        var ctx_attr    = Attr(EDITOR_FG, EDITOR_BG)
        var add_attr    = Attr(LIGHT_GREEN, EDITOR_BG)
        var rem_attr    = Attr(LIGHT_RED, EDITOR_BG)
        var hunk_attr   = Attr(CYAN, EDITOR_BG)
        var header_attr = Attr(BORDER_FOCUS, EDITOR_BG)
        # The modal always covers the full container_bounds — it intercepts every
        # input event, so a windowed mode wouldn't gain any interactive
        # surface area behind it.
        var bounds = self._panel_rect(container_bounds)
        canvas.fill(bounds, String(" "), bg)
        canvas.draw_box(bounds, border, True)
        # Title row — framework helper enforces title bg = body bg.
        paint_window_title(
            canvas, bounds, String(" Local changes "), title_attr, bg,
        )
        # Sub-title: the last successful op's one-liner while its flash is
        # live, else the git-unavailable banner, else the project root.
        var sub_y = bounds.a.y + 1
        var sub: String
        var sub_attr = list_dim
        if len(self.flash_message.as_bytes()) > 0:
            sub = String(" ") + self.flash_message
            sub_attr = Attr(LIGHT_GREEN, EDITOR_BG)
        elif len(self.status_message.as_bytes()) > 0:
            sub = String(" ") + self.status_message
        else:
            sub = String(" ") + self.root
        _ = canvas.put_text(
            Point(bounds.a.x + 1, sub_y), sub, sub_attr, bounds.b.x - 1,
        )
        # Vertical separator (also the sidebar/right splitter target).
        var sw = self._sidebar_width(bounds)
        var sep_x = bounds.a.x + sw
        for y in range(self._list_top(bounds), self._list_bottom(bounds)):
            canvas.set(sep_x, y, Cell(String("│"), sep_attr, 1))
        # Sidebar: three stacked panels with horizontal splitters between.
        # Section bodies paint first (they may not draw the header row
        # at all when collapsed); the framework dock paints titles +
        # chrome buttons on top so headers always win.
        var rows = self._pane_rows(bounds)
        var left = bounds.a.x + 1
        var right = bounds.a.x + sw - 1
        self._paint_section_body(
            canvas, left, right, rows[0], rows[1], _PANE_FILES,
            list_attr, sel_attr, sel_inactive, list_dim,
        )
        self._paint_horizontal_splitter(
            canvas, left, right, rows[0] + rows[1], splitter_attr,
        )
        self._paint_section_body(
            canvas, left, right, rows[2], rows[3], _PANE_BRANCHES,
            list_attr, sel_attr, sel_inactive, list_dim,
        )
        self._paint_horizontal_splitter(
            canvas, left, right, rows[2] + rows[3], splitter_attr,
        )
        self._paint_section_body(
            canvas, left, right, rows[4], rows[5], _PANE_COMMITS,
            list_attr, sel_attr, sel_inactive, list_dim,
        )
        # Headers + chrome buttons. Pass the focused section's index so
        # the marker (``> ``) lights the right title.
        var focused_section: Int
        if self.focus == _PANE_FILES:
            focused_section = 0
        elif self.focus == _PANE_BRANCHES:
            focused_section = 1
        elif self.focus == _PANE_COMMITS:
            focused_section = 2
        else:
            focused_section = -1
        self.sidebar_dock.paint_headers(
            canvas, left, right + 1, rows, section_attr, focused_section,
        )
        # Right side: split (file mode) or single info panel.
        self._ensure_right_panels(registry)
        self._paint_right_side(
            canvas, bounds,
            section_attr, splitter_attr,
            ctx_attr, add_attr, rem_attr, hunk_attr, header_attr,
        )
        # Bottom hint.
        var hint: String
        if self.focus == _PANE_RIGHT_UNSTAGED:
            hint = String(
                " Up/Down: line  Space: stage  d: discard line  ⌘C: copy  Left: back  ESC: close ",
            )
        elif self._is_right_focus():
            hint = String(
                " Up/Down: line  Tab: panel  Space: stage/unstage  ⌘C: copy  Left: back  ESC: close ",
            )
        elif self.focus == _PANE_FILES:
            hint = String(
                " c:commit A:amend d:revert p:pull P:push  Space:stage  ⌘C:copy  Enter:open  ESC:close ",
            )
        elif self.focus == _PANE_BRANCHES:
            hint = String(
                " Space:switch  M:merge  d:delete  Right:log  ⌘C:copy  ESC:close ",
            )
        else:
            hint = String(
                " Tab: pane  Up/Down: select  Right: diff  ⌘C: copy  Enter: open  ESC: close ",
            )
        var hx = bounds.b.x - display_columns(hint) - 1
        if hx < bounds.a.x + 1:
            hx = bounds.a.x + 1
        _ = canvas.put_text(Point(hx, bounds.b.y - 1), hint, hint_attr)
        # Overlay last so it sits on top of everything else.
        if self.overlay != _OVERLAY_NONE:
            self._paint_overlay(canvas, bounds)
        # Async git-op popup (spinner + streaming output tail). Painted
        # after the overlay so the spinner survives a transient status
        # flash sitting on top of the modal — and so the popup is the
        # last thing the user sees while a slow commit/push grinds.
        self.git_runner.paint(canvas, bounds)

    def _paint_overlay(mut self, mut canvas: Canvas, container_bounds: Rect):
        """Render the active overlay (commit prompt / confirmation /
        status flash) as a small drop-shadowed box centered on the
        modal area. Every write is bound to the overlay's clip via a
        Painter so an over-long status message (or a wide commit
        title) can't bleed out onto the underlying modal.

        ``_OVERLAY_OUTPUT`` is the exception — a git log needs room, so it
        gets the whole modal area and its own scrollback rather than a
        centered box."""
        if self.overlay == _OVERLAY_OUTPUT:
            self._paint_output_overlay(canvas, container_bounds)
            return
        var border = Attr(BLACK, LIGHT_GRAY)
        var body   = Attr(BLACK, LIGHT_GRAY)
        # No success colour here: the only status box this paints is a
        # failure (successes flash on the sub-title row instead).
        var err_attr  = Attr(WHITE, LIGHT_RED)
        # Box geometry — 60 cols wide, 5 rows tall by default; clamps
        # to the modal area on tiny terminals.
        var max_w = container_bounds.width() - 4
        var box_w = 64 if max_w >= 64 else max_w
        if box_w < 24:
            box_w = 24
        # The merge-style choice needs room for two labelled options with a
        # consequence line each — a bare ``[m] / [r]`` hint row would put
        # the whole point of asking (what each answer does to the history)
        # off screen. Clamped so a short terminal still gets a box that
        # fits, at which point paint just runs out of rows to fill.
        var box_h = 5
        if self.overlay == _OVERLAY_MERGE_CHOICE:
            box_h = 9
            var max_h = container_bounds.height() - 2
            if box_h > max_h:
                box_h = max_h if max_h >= 5 else 5
        # The message editor needs real room: a commit body is the point,
        # so give it 12 rows (≈8 of text) and shrink only when the
        # terminal can't spare them.
        if self.overlay == _OVERLAY_EDIT_MSG:
            box_h = 14
            var max_h2 = container_bounds.height() - 2
            if box_h > max_h2:
                box_h = max_h2 if max_h2 >= 7 else 7
        var bx = container_bounds.a.x + (container_bounds.width() - box_w) // 2
        var by = container_bounds.a.y + (container_bounds.height() - box_h) // 2
        var rect = Rect(bx, by, bx + box_w, by + box_h)
        paint_drop_shadow(canvas, rect)
        var painter = Painter(rect)
        painter.fill(canvas, rect, String(" "), body)
        painter.draw_box(canvas, rect, border, False)
        var title: String
        var prompt_text: String
        if self.overlay == _OVERLAY_COMMIT:
            title = String(" Commit ")
            prompt_text = String("message: ")
        elif self.overlay == _OVERLAY_EDIT_MSG:
            title = String(" Edit message ") + self._reword_sha + String(" ")
            prompt_text = String("")
        elif self.overlay == _OVERLAY_AMEND_CONFIRM:
            title = String(" Amend ")
            prompt_text = String("")
        elif self.overlay == _OVERLAY_REVERT_CONFIRM:
            title = String(" Revert ")
            prompt_text = String("")
        elif self.overlay == _OVERLAY_DISCARD_LINE_CONFIRM:
            title = String(" Discard ")
            prompt_text = String("")
        elif self.overlay == _OVERLAY_DELETE_BRANCH_CONFIRM:
            title = String(" Delete branch ")
            prompt_text = String("")
        elif self.overlay == _OVERLAY_MERGE_CHOICE:
            title = String(" Merge branch ")
            prompt_text = String("")
        else:
            title = String(" Status ")
            prompt_text = String("")
        _ = painter.put_text(canvas, Point(bx + 2, by), title, border)
        # Body text region — one cell of padding inside the border on
        # all sides. Nested painter so the children can't accidentally
        # write into the box border.
        var body_rect = Rect(bx + 1, by + 1, bx + box_w - 1, by + box_h - 1)
        var body_p = painter.sub(body_rect)
        if self.overlay == _OVERLAY_COMMIT:
            _ = body_p.put_text(
                canvas, Point(bx + 2, by + 2), prompt_text, body,
            )
            var input_x = bx + 2 + display_columns(prompt_text)
            var input_rect = Rect(
                input_x, by + 2, bx + box_w - 1, by + 3,
            )
            self.overlay_input.paint(canvas, input_rect, True)
            var hint = String("Enter: commit   ESC: cancel")
            _ = body_p.put_text(
                canvas, Point(bx + 2, by + box_h - 2), hint, body,
            )
            return
        if self.overlay == _OVERLAY_EDIT_MSG:
            self._paint_edit_msg(canvas, body_p, bx, by, box_w, box_h, body)
            return
        if self.overlay == _OVERLAY_STATUS:
            # Failure-only: successes report through ``flash_message`` on
            # the sub-title row and never open this box.
            body_p.fill(
                canvas, Rect(bx + 1, by + 2, bx + box_w - 1, by + 3),
                String(" "), err_attr,
            )
            _ = body_p.put_text(
                canvas, Point(bx + 2, by + 2), self.overlay_message, err_attr,
            )
            var hint = String("Press any key to dismiss")
            _ = body_p.put_text(
                canvas, Point(bx + 2, by + box_h - 2), hint, body,
            )
            return
        if self.overlay == _OVERLAY_MERGE_CHOICE:
            self._paint_merge_choice(
                canvas, body_p, bx, by, box_w, box_h, body,
            )
            return
        # Confirmation overlays.
        _ = body_p.put_text(
            canvas, Point(bx + 2, by + 1), self.overlay_message, body,
        )
        var hint = String("[y] confirm   [n] / ESC: cancel")
        _ = body_p.put_text(
            canvas, Point(bx + 2, by + box_h - 2), hint, body,
        )

    def _handle_edit_msg_mouse(
        mut self, event: Event, container_bounds: Rect,
    ):
        """Route a click inside the message editor: the Save button first,
        then click-to-position in the text area. The caller swallows the
        event either way, so a click on the box chrome does nothing rather
        than falling through to the list underneath."""
        if self._reword_save_btn.handle_mouse(event) == BUTTON_FIRED:
            self._submit_reword()
            return
        _ = self.overlay_area.handle_mouse(event, self._reword_area_rect)

    def _paint_edit_msg(
        mut self, mut canvas: Canvas, mut body_p: Painter,
        bx: Int, by: Int, box_w: Int, box_h: Int, body: Attr,
    ):
        """Body of the commit-message editor: a multi-row input strip with
        a Save button under it.

        The button carries its own shortcut (``Save  ⌘↵``) because a
        multi-line editor takes Enter for newlines — so the one key the
        user would reach for first isn't the one that submits, and a hint
        row alone is easy to miss. Cancel isn't a button: ESC already
        closes every overlay in this view, and the hint row says so.

        Takes ``mut self`` because the text area tracks its own scroll
        offsets and the button latches presses across paints.
        """
        var last_row = by + box_h - 2      # hint row
        # Text area fills everything between the top padding and the
        # button row, so a taller box just means more visible message.
        var area_top = by + 2
        var area_bottom = last_row - 2
        if area_bottom <= area_top:
            area_bottom = area_top + 1
        var area_rect = Rect(bx + 2, area_top, bx + box_w - 2, area_bottom)
        self._reword_area_rect = area_rect
        self.overlay_area.paint(canvas, area_rect, True)
        # Save button, right-aligned on the row above the hint.
        var btn_y = area_bottom
        var btn_x = bx + box_w - 2 - self._reword_save_btn.total_width()
        self._reword_save_btn.move_to(btn_x, btn_y)
        paint_shadow_button(
            canvas, self._reword_save_btn, Attr(BLACK, LIGHT_GREEN), body.bg,
            bx + box_w - 1,
        )
        # What the edit will actually do — an amend of the tip and a
        # replay of everything above an older commit are different enough
        # that the user should see which one they're about to get.
        var what: String
        if self._reword_is_head:
            what = String("amends ") + self._reword_sha
        else:
            what = String("rewrites ") + self._reword_sha \
                + String(" and replays above it")
        # Shares its row with the button, so it's only drawn when it
        # actually fits beside it — the box clamps to 24 columns on a
        # narrow terminal, where this would otherwise run underneath.
        if bx + 2 + display_columns(what) < btn_x - 1:
            _ = body_p.put_text(canvas, Point(bx + 2, btn_y), what, body)
        # Save's chord lives on the button face, so the hint row only has
        # to cover the way out.
        var hint = String("ESC: cancel")
        _ = body_p.put_text(canvas, Point(bx + 2, by + box_h - 2), hint, body)

    def _paint_merge_choice(
        self, mut canvas: Canvas, mut body_p: Painter,
        bx: Int, by: Int, box_w: Int, box_h: Int, body: Attr,
    ):
        """Body of the merge-style choice box: the question, the two
        answers with what each does to the history, and the escape hatch.

        Rows are emitted top-down and anything that would land on or below
        the hint row is dropped, so a terminal too short for the full box
        loses the explanatory second lines rather than painting over its
        own border. The two hotkey markers are tinted so the answer keys
        are findable without reading the sentence."""
        var key_attr = Attr(LIGHT_RED, body.bg)
        var target = self._git_merge_branch.copy()
        var current = self._current_branch_name()
        var last_row = by + box_h - 2      # the hint row; body stops above it
        var y = by + 1
        _ = body_p.put_text(canvas, Point(bx + 2, y), self.overlay_message, body)
        y += 2
        # ``[m] label`` in two writes so only the bracketed key is tinted.
        if y < last_row:
            _ = body_p.put_text(canvas, Point(bx + 2, y), String("[m]"), key_attr)
            _ = body_p.put_text(
                canvas, Point(bx + 6, y),
                String("merge commit — keep both histories"), body,
            )
            y += 1
        if y < last_row:
            _ = body_p.put_text(
                canvas, Point(bx + 6, y),
                String("and record the merge (git merge --no-ff)"), body,
            )
            y += 1
        if y < last_row:
            _ = body_p.put_text(canvas, Point(bx + 2, y), String("[r]"), key_attr)
            _ = body_p.put_text(
                canvas, Point(bx + 6, y),
                String("straight history — no merge commit;"), body,
            )
            y += 1
        if y < last_row:
            _ = body_p.put_text(
                canvas, Point(bx + 6, y),
                String("replays ") + current + String(" onto ") + target
                + String(" (git rebase)"), body,
            )
        _ = body_p.put_text(
            canvas, Point(bx + 2, last_row),
            String("[m] merge commit   [r] straight   ESC: cancel"), body,
        )

    def _output_overlay_rect(self, container_bounds: Rect) -> Rect:
        """Where the full-screen output log lives: the modal area inset by
        two columns / one row, matching the promoted spinner's frame so the
        log doesn't jump when the child reaps and we take over drawing it."""
        return Rect(
            container_bounds.a.x + 2, container_bounds.a.y + 1,
            container_bounds.b.x - 2, container_bounds.b.y - 1,
        )

    def _output_overlay_lines(self) -> List[String]:
        return split_lines(self.overlay_output)

    def _paint_output_overlay(
        mut self, mut canvas: Canvas, container_bounds: Rect,
    ):
        """Full-screen scrollback of one git op's output.

        Clamps ``overlay_output_scroll`` here rather than in the key
        handler: paint is the only place that knows the viewport height,
        and the overlay opens with the scroll deliberately over-large to
        mean "start at the bottom"."""
        var rect = self._output_overlay_rect(container_bounds)
        if rect.width() < 8 or rect.height() < 4:
            return
        var frame = Attr(BLACK, LIGHT_GRAY)
        var text_attr = Attr(BLACK, LIGHT_GRAY)
        paint_drop_shadow(canvas, rect)
        var painter = Painter(rect)
        painter.fill(canvas, rect, String(" "), frame)
        painter.draw_box(canvas, rect, frame, False)
        var title = String(" ") + self._git_op_label + String(" output ")
        if len(self._git_op_label.as_bytes()) == 0:
            title = String(" git output ")
        paint_window_title_at(
            canvas, Point(rect.a.x + 1, rect.a.y), title, frame, frame,
        )
        var lines = self._output_overlay_lines()
        var view_h = rect.height() - 2
        var max_scroll = len(lines) - view_h
        if max_scroll < 0:
            max_scroll = 0
        if self.overlay_output_scroll > max_scroll:
            self.overlay_output_scroll = max_scroll
        if self.overlay_output_scroll < 0:
            self.overlay_output_scroll = 0
        for i in range(view_h):
            var idx = self.overlay_output_scroll + i
            if idx >= len(lines):
                break
            _ = painter.put_text(
                canvas, Point(rect.a.x + 2, rect.a.y + 1 + i),
                lines[idx], text_attr,
            )
        var hint = String(" Up/Down/PgUp/PgDn: scroll   ESC / Enter: close ")
        var hx = rect.b.x - display_columns(hint) - 1
        if hx < rect.a.x + 1:
            hx = rect.a.x + 1
        _ = painter.put_text(
            canvas, Point(hx, rect.b.y - 1), hint, frame,
        )

    def _scroll_output_overlay(mut self, delta: Int):
        """Move the log viewport. The clamp lives in paint (which knows the
        height); here we only refuse to go negative."""
        self.overlay_output_scroll += delta
        if self.overlay_output_scroll < 0:
            self.overlay_output_scroll = 0

    def _paint_horizontal_splitter(
        self, mut canvas: Canvas, left: Int, right: Int, y: Int,
        attr: Attr,
    ):
        if right < left:
            return
        for x in range(left, right + 1):
            canvas.set(x, y, Cell(String("─"), attr, 1))

    def _paint_section_body(
        self, mut canvas: Canvas,
        left: Int, right: Int, top: Int, height: Int, pane: Int,
        list_attr: Attr, sel_active: Attr,
        sel_inactive: Attr, dim_attr: Attr,
    ):
        """Paint a sidebar section's *body* only — the header row is
        owned by the framework dock (``DockedPanelStack.paint_headers``).
        Skipped entirely when the section is collapsed to header-only
        (height <= 1)."""
        if right <= left or height <= 1:
            return
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

    def _row_attr(
        self, is_sel: Bool, is_focused: Bool,
        list_attr: Attr, sel_active: Attr, sel_inactive: Attr,
    ) -> Attr:
        if not is_sel:
            return list_attr
        return sel_active if is_focused else sel_inactive

    def _paint_truncated(
        self, mut canvas: Canvas, x: Int, y: Int, right_excl: Int,
        text: String, attr: Attr,
    ):
        """Right-truncate ``text`` so it fits in ``[x, right_excl)``,
        marking truncation with a leading ``…`` so the basename / sha
        / subject end stays visible."""
        var avail = right_excl - x
        if avail <= 0:
            return
        if display_columns(text) <= avail:
            _ = canvas.put_text(Point(x, y), text, attr, right_excl)
            return
        canvas.set(x, y, Cell(String("…"), attr, 1))
        # The ellipsis took one column; fit the codepoint-aligned tail of
        # ``text`` into the remaining ``avail - 1`` columns.
        _ = canvas.put_text(
            Point(x + 1, y),
            tail_to_columns(text, avail - 1),
            attr, right_excl,
        )

    def _paint_files(
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
        var staged_attr   = Attr(LIGHT_GREEN, EDITOR_BG)
        var unstaged_attr = Attr(LIGHT_RED, EDITOR_BG)
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

    def _paint_branches(
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
        # One wall-clock reading for the whole pane, so every row's age is
        # measured against the same "now" and the column can't disagree
        # with itself mid-paint.
        var now = wall_clock_ms() // 1000
        # One right-aligned gutter carries *either* the age or the ``*``,
        # never both: the age answers "which branch do I want to switch
        # to", and you're already on the current one. Sizing the gutter
        # from the other branches' ages only is what keeps it narrow —
        # the current row contributes a single ``*``.
        #
        # Width comes from the whole list rather than the visible window,
        # so the name column doesn't shift sideways as the pane scrolls.
        var gutter_w = 1
        if now > 0:
            for i in range(len(self.branches)):
                var b = self.branches[i]
                if b.is_current or b.committer_unix <= 0:
                    continue
                var w = display_columns(format_age(now - b.committer_unix))
                if w > gutter_w:
                    gutter_w = w
        # Gutter spans ``[left + 1, left + 1 + gutter_w)``, then one space,
        # then the name.
        var name_x = left + 2 + gutter_w
        # On a pane too narrow to leave the name real room, drop the gutter
        # entirely and give every column to the name — that's what the row
        # is for. The ``*`` goes back to a bare prefix so the current branch
        # is still identifiable.
        var narrow = name_x + 4 > right
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
            if narrow:
                self._paint_truncated(
                    canvas, left + 1, y, right + 1,
                    (String("* ") if br.is_current else String("  "))
                    + br.name,
                    attr,
                )
                continue
            # ``*`` in the row's own colour (it's identity); the age dim,
            # since it's context — except on the selected row, where it
            # takes the selection bar so the bar reads as one block.
            var gutter = String("*")
            var gutter_attr = attr
            if not br.is_current:
                if br.committer_unix <= 0:
                    gutter = String("")
                else:
                    gutter = format_age(now - br.committer_unix)
                    gutter_attr = attr if is_sel else dim_attr.with_bg(attr.bg)
            if len(gutter.as_bytes()) > 0:
                _ = canvas.put_text(
                    Point(name_x - 1 - display_columns(gutter), y), gutter,
                    gutter_attr, right + 1,
                )
            self._paint_truncated(
                canvas, name_x, y, right + 1, br.name, attr,
            )

    def _paint_commits(
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
        #
        # The SHA tint alone is too easy to miss, and it disappears
        # entirely on the selected row (where ``row_attr`` overrides every
        # segment). So unpushed commits also carry a leading ``↑`` glyph,
        # painted on every row including the selected one: a shape reads
        # against the selection bar where a color can't. ``↑`` matches the
        # status-bar "unpushed" indicator.
        var sha_pushed   = Attr(LIGHT_GREEN, EDITOR_BG)
        var sha_local    = Attr(LIGHT_RED, EDITOR_BG)
        var subject_attr = Attr(EDITOR_FG, EDITOR_BG)
        # Tags get their own colour, sitting between the SHA and the
        # author — yellow, matching git's default tag decoration.
        var tag_attr     = Attr(LIGHT_YELLOW, EDITOR_BG)
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
            # Per-committer color so the same author's rows stand out down
            # the log.
            var seg_author = Attr(_author_color(co.author), EDITOR_BG)
            var seg_tags   = tag_attr
            var seg_subj   = subject_attr
            if is_sel:
                # On the selected row, keep the *foreground* color coding —
                # the sha's pushed/unpushed tint and the per-author color —
                # and only adopt the selection bar's background. Flattening
                # every segment to black would hide exactly the signal the
                # user is acting on. The subject carries no coding, so it
                # takes the selection fg (black) where it reads best.
                var sel_bg = row_attr.bg
                seg_sha = seg_sha.with_bg(sel_bg)
                seg_author = seg_author.with_bg(sel_bg)
                seg_tags = seg_tags.with_bg(sel_bg)
                seg_subj = row_attr
            # Layout: ``<sha> <AB> <subject>`` painted in three
            # passes; each ``put_text`` clips at ``right + 1`` so a
            # segment that runs out of room is hard-cut at the edge
            # and the next segment simply doesn't paint. ``put_text``
            # returns columns advanced, which is what we use to walk
            # the cursor forward — codepoint width, not byte width.
            var x = left + 1
            var stop = right + 1
            # Unpushed marker, always painted (even on the selected row). A
            # space for pushed commits keeps the SHA column aligned. On the
            # selected row it keeps its red tint over the selection bg.
            var mark = String(" ") if co.is_pushed else String("↑")
            var mark_attr = sha_local.with_bg(row_attr.bg) if is_sel else sha_local
            x += canvas.put_text(Point(x, y), mark, mark_attr, stop)
            if x >= stop: continue
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
            # Tags, in their own colour, between the author and the subject.
            if len(co.tags.as_bytes()) > 0:
                x += canvas.put_text(Point(x, y), String(" "), row_attr, stop)
                if x >= stop: continue
                x += canvas.put_text(Point(x, y), co.tags, seg_tags, stop)
                if x >= stop: continue
            x += canvas.put_text(Point(x, y), String(" "), row_attr, stop)
            if x >= stop: continue
            _ = canvas.put_text(
                Point(x, y), co.subject, seg_subj, stop,
            )

    def _paint_right_side(
        mut self, mut canvas: Canvas, container_bounds: Rect,
        section_attr: Attr, splitter_attr: Attr,
        ctx_attr: Attr, add_attr: Attr, rem_attr: Attr,
        hunk_attr: Attr, header_attr: Attr,
    ):
        var top = self._list_top(container_bounds)
        var bottom = self._list_bottom(container_bounds)
        var left = self._diff_left(container_bounds)
        # ``_diff_right`` historically returned the border column itself
        # (``container_bounds.b.x - 1``). The panels and splitters then used ``+1``
        # tricks that ended up writing one cell *past* the content area
        # — straight onto the modal's right border. Treat ``right_excl``
        # as the panel's exclusive right edge instead, anchored one cell
        # short of the border so the Painter clip naturally protects the
        # frame.
        var right_excl = self._diff_right(container_bounds)
        if right_excl <= left:
            return
        var driving = self._driving_pane()
        if driving == _PANE_FILES:
            var rp = self._right_panes(container_bounds)
            self._paint_panel_with_header(
                canvas,
                Rect(left, rp[0], right_excl, rp[0] + rp[1]),
                String("Unstaged"), _PANE_RIGHT_UNSTAGED,
                self.unstaged,
                section_attr,
                ctx_attr, add_attr, rem_attr, hunk_attr, header_attr,
            )
            self._paint_horizontal_splitter(
                canvas, left, right_excl - 1, rp[0] + rp[1], splitter_attr,
            )
            self._paint_panel_with_header(
                canvas,
                Rect(left, rp[2], right_excl, rp[2] + rp[3]),
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
            Rect(left, top, right_excl, bottom),
            info_title, _PANE_RIGHT_INFO,
            self.info,
            section_attr,
            ctx_attr, add_attr, rem_attr, hunk_attr, header_attr,
        )

    def _paint_panel_with_header(
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
        # the splitter row, or off-container_bounds. Children paint without
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

    def _paint_panel_body(
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
        # Base text colour for diff body rows. ``LIGHT_GREEN`` matches
        # the editor's untokenised baseline (``editor.mojo`` paint), so
        # the syntax-highlight overlay ends up colouring exactly the
        # same scopes the editor would — keywords go ``WHITE``, strings
        # ``RED``, comments ``CYAN``, etc. — and idents/variables stay
        # ``LIGHT_GREEN`` which reads as the default text colour rather
        # than a highlight.
        var body_bg = Attr(LIGHT_GREEN, EDITOR_BG)
        # Add/remove gutter cells. Saturated bg + black fg gives a
        # solid coloured block on the left edge that reads as a status
        # band even at a glance — easier to spot than a fg-only glyph
        # against the panel's blue background.
        var add_gutter_attr = Attr(BLACK, LIGHT_GREEN)
        var rem_gutter_attr = Attr(BLACK, LIGHT_RED)
        # Explicit body fill — the outer ``LocalChanges.paint`` sets
        # every container_bounds cell to ``YELLOW`` on ``EDITOR_BG``, but per-cell
        # writes below only touch the gutter glyph (col 0), the body
        # text (col +2 onward), and any highlight overlays. Without an
        # explicit fill the spacer column (col +1) and the trailing
        # cells past the line end carry whatever attr the *previous*
        # panel paint stamped — which leaves visible artifacts when a
        # widget that previously occupied this rect (or a slow
        # repaint) leaks through.
        painter.fill(canvas, area, String(" "), body_bg)
        var pane_focused = (self.focus == pane)
        var height = area.height()
        # Bucket highlights by visible-row offset once, instead of
        # rescanning the whole ``panel.highlights`` list for every body
        # row. ``hl_buckets[i]`` holds the indices into ``panel.highlights``
        # whose ``row`` lands on visible offset ``i`` (absolute line
        # ``panel.scroll + i``); empty buckets let the row loop skip the
        # per-row ``utf8_byte_to_cell`` allocation entirely.
        var hl_buckets = List[List[Int]]()
        for _i in range(height):
            hl_buckets.append(List[Int]())
        for h in range(len(panel.highlights)):
            var bo = panel.highlights[h].row - panel.scroll
            if 0 <= bo and bo < height:
                hl_buckets[bo].append(h)
        # Gutter occupies a single column at the panel's left edge for
        # diff body rows; banners / blanks / info rows render with no
        # gutter and start at the panel edge.
        for i in range(height):
            var idx = panel.scroll + i
            if idx >= len(panel.lines):
                break
            var y = area.a.y + i
            var line = panel.lines[idx]
            var k = panel.kind[idx] if idx < len(panel.kind) else _LINE_INFO
            var is_cursor = (idx == panel.cursor and pane_focused)
            # Per-kind render recipe. Resolved before the cursor row is
            # special-cased so both paths agree on where the text starts —
            # a row must not slide sideways just because it got selected,
            # and the link hit-test in ``_info_link_at`` relies on that.
            var line_attr: Attr
            var gutter_glyph: String
            var gutter_attr: Attr
            var has_gutter: Bool
            if k == _LINE_BLANK:
                line_attr = ctx_attr
                gutter_glyph = String(" ")
                gutter_attr = ctx_attr
                has_gutter = False
            elif k == _LINE_FILEHDR:
                line_attr = header_attr
                gutter_glyph = String(" ")
                gutter_attr = header_attr
                has_gutter = False
            elif k == _LINE_INFO:
                line_attr = ctx_attr
                gutter_glyph = String(" ")
                gutter_attr = ctx_attr
                has_gutter = False
            elif k == _LINE_ADD:
                line_attr = body_bg
                gutter_glyph = String("+")
                gutter_attr = add_gutter_attr
                has_gutter = True
            elif k == _LINE_REM:
                line_attr = body_bg
                gutter_glyph = String("-")
                gutter_attr = rem_gutter_attr
                has_gutter = True
            elif k == _LINE_NONEWLINE:
                line_attr = ctx_attr
                gutter_glyph = String(" ")
                gutter_attr = ctx_attr
                has_gutter = False
            else:    # _LINE_CTX
                line_attr = body_bg
                gutter_glyph = String(" ")
                gutter_attr = body_bg
                has_gutter = True
            var body_x = area.a.x + 2 if has_gutter else area.a.x
            # Cursor row: paint the whole row in cursor_active and write
            # the line content on top — overrides the per-kind colouring
            # below. Skip the syntax overlay for this row so the YELLOW
            # background isn't recoloured back to the editor background.
            if is_cursor:
                painter.fill(
                    canvas,
                    Rect(area.a.x, y, area.b.x, y + 1),
                    String(" "), cursor_active,
                )
                # Show the gutter character even on the cursor row so
                # the user can still tell add from remove from context.
                # The column right of the marker is left as a blank
                # spacer so the marker doesn't crowd the code.
                if has_gutter:
                    _ = painter.put_text(
                        canvas, Point(area.a.x, y),
                        gutter_glyph, cursor_active,
                    )
                var bytes_c = line.as_bytes()
                if panel.scroll_x < len(bytes_c):
                    var visible_c = String(StringSpan(
                        unsafe_from_utf8=bytes_c[
                            panel.scroll_x:len(bytes_c)
                        ],
                    ))
                    _ = painter.put_text(
                        canvas, Point(body_x, y), visible_c, cursor_active,
                    )
                # Keep URLs marked on the cursor row too, but as an
                # underline over the selection colours rather than the
                # blue link attr — recolouring would swallow the cursor.
                if len(panel.links) > 0:
                    _underline_row_links(
                        canvas, painter, panel, idx, y, body_x,
                        area.b.x, cursor_active.add_style(STYLE_UNDERLINE),
                    )
                continue
            # Separator rule between hunks: a dim horizontal line across
            # the whole panel width. No gutter, no syntax overlay.
            if k == _LINE_SEPARATOR:
                var sep_attr = Attr(DARK_GRAY, EDITOR_BG)
                painter.fill(
                    canvas,
                    Rect(area.a.x, y, area.b.x, y + 1),
                    String("─"), sep_attr,
                )
                continue
            # Gutter is two cells: the +/-/space marker, then a blank
            # spacer so the code body doesn't crowd against the marker.
            if has_gutter:
                _ = painter.put_text(
                    canvas, Point(area.a.x, y), gutter_glyph, gutter_attr,
                )
            var bytes = line.as_bytes()
            var start = panel.scroll_x
            if start < len(bytes):
                var visible = String(StringSpan(
                    unsafe_from_utf8=bytes[start:len(bytes)],
                ))
                _ = painter.put_text(
                    canvas, Point(body_x, y), visible, line_attr,
                )
            # Syntax-highlight overlay. Highlights' columns are *byte*
            # offsets in the line text (the same convention the editor
            # uses); we run them through ``utf8_byte_to_cell`` to land
            # on the right visual columns when a line contains
            # multi-byte UTF-8. ``-`` rows pull from the before-file
            # tokenization, ``+`` and context rows pull from the
            # after-file — the populate step already routed them to
            # the right side via ``display_to_*_row``.
            if has_gutter and len(hl_buckets[i]) > 0:
                var byte_to_cell = utf8_byte_to_cell(line)
                var byte_count = len(bytes)
                var cell_count = utf8_codepoint_count(line)
                for bi in range(len(hl_buckets[i])):
                    var hl = panel.highlights[hl_buckets[i][bi]]
                    var hl_byte_lo = hl.col_start - panel.scroll_x
                    var hl_byte_hi = hl.col_end - panel.scroll_x
                    if hl_byte_lo < 0:
                        hl_byte_lo = 0
                    if hl_byte_hi > byte_count:
                        hl_byte_hi = byte_count
                    if hl_byte_lo >= hl_byte_hi:
                        continue
                    var hl_cell_lo = byte_to_cell[hl_byte_lo]
                    var hl_cell_hi: Int
                    if hl_byte_hi < byte_count:
                        hl_cell_hi = byte_to_cell[hl_byte_hi]
                    else:
                        hl_cell_hi = cell_count
                    for c in range(hl_cell_lo, hl_cell_hi):
                        var sx = body_x + c
                        if sx >= area.b.x:
                            break
                        painter.set_attr(canvas, sx, y, hl.attr)
            # URL spans in info rows (commit message / branch log) paint
            # as underlined links last, so they win over the base kind
            # colour. Only info rows ever carry links — see ``_emit_info``.
            if len(panel.links) > 0:
                _underline_row_links(
                    canvas, painter, panel, idx, y, body_x, area.b.x,
                    Attr(LIGHT_BLUE, EDITOR_BG, STYLE_UNDERLINE),
                )
        _ = cursor_inactive
        _ = hunk_attr   # retained for the legacy diff colour palette
        _ = rem_attr
        _ = add_attr

    # --- events -----------------------------------------------------------

    def _focused_count(self) -> Int:
        if self.focus == _PANE_FILES: return len(self.files)
        if self.focus == _PANE_BRANCHES: return len(self.branches)
        if self.focus == _PANE_COMMITS: return len(self.commits)
        return 0

    def _focused_selection(self) -> Int:
        if self.focus == _PANE_FILES: return self.sel_file
        if self.focus == _PANE_BRANCHES: return self.sel_branch
        if self.focus == _PANE_COMMITS: return self.sel_commit
        return 0

    def _focused_panel_height(self, container_bounds: Rect) -> Int:
        var rows = self._pane_rows(container_bounds)
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

    def _set_focused_selection(mut self, new_idx: Int, container_bounds: Rect):
        var n = self._focused_count()
        if n == 0:
            return
        var new = new_idx
        if new < 0: new = 0
        if new >= n: new = n - 1
        var h = self._focused_panel_height(container_bounds)
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

    def _select_branch_by_name(mut self, name: String):
        """Move ``sel_branch`` onto the row named ``name``, if it's still
        in the list. No container bounds here (we're called from ``tick``,
        which doesn't have them), so scroll only gets nudged up when the
        new row sits above the viewport — the paint's own scroll window is
        unchanged otherwise."""
        for i in range(len(self.branches)):
            if self.branches[i].name == name:
                self.sel_branch = i
                if self.scroll_branches > i:
                    self.scroll_branches = i
                return

    def _cycle_focus(mut self, direction: Int):
        """Tab / Shift+Tab. Cycles through every visible pane in a
        single sequence: each sidebar pane is followed by the right-
        side pane(s) it drives, then on to the next sidebar pane.

        Forward order:
            Files → Unstaged → Staged
                  → Branches → Info (branch log)
                  → Commits  → Info (commit details)
                  → wrap to Files

        The Info pane appears twice — once driven by Branches, once
        by Commits — because the right side reconfigures its content
        based on which sidebar pane drove it. ``last_sidebar_focus``
        carries the driving identity through the right-pane stops so
        the next Tab knows whether to jump to Commits or wrap to
        Files."""
        if direction > 0:
            self._tab_forward()
        else:
            self._tab_backward()
        # Each pane has its own row labels — drop any stale type-ahead
        # buffer on a focus change so the next keystroke starts a
        # fresh search against the new pane's items.
        self._type_ahead.reset()

    def _tab_forward(mut self):
        var f = self.focus
        if f == _PANE_FILES:
            self.focus = _PANE_RIGHT_UNSTAGED
            self.last_sidebar_focus = _PANE_FILES
            return
        if f == _PANE_RIGHT_UNSTAGED:
            self.focus = _PANE_RIGHT_STAGED
            return
        if f == _PANE_RIGHT_STAGED:
            self.focus = _PANE_BRANCHES
            self.last_sidebar_focus = _PANE_BRANCHES
            return
        if f == _PANE_BRANCHES:
            self.focus = _PANE_RIGHT_INFO
            self.last_sidebar_focus = _PANE_BRANCHES
            return
        if f == _PANE_COMMITS:
            self.focus = _PANE_RIGHT_INFO
            self.last_sidebar_focus = _PANE_COMMITS
            return
        if f == _PANE_RIGHT_INFO:
            # Two stops in the cycle land here — Branches→Info and
            # Commits→Info. Disambiguate by the driving pane.
            if self.last_sidebar_focus == _PANE_BRANCHES:
                self.focus = _PANE_COMMITS
                self.last_sidebar_focus = _PANE_COMMITS
            else:
                self.focus = _PANE_FILES
                self.last_sidebar_focus = _PANE_FILES
            return

    def _tab_backward(mut self):
        var f = self.focus
        if f == _PANE_FILES:
            # Wrap to last stop in the cycle: Info driven by Commits.
            self.focus = _PANE_RIGHT_INFO
            self.last_sidebar_focus = _PANE_COMMITS
            return
        if f == _PANE_RIGHT_INFO:
            if self.last_sidebar_focus == _PANE_COMMITS:
                self.focus = _PANE_COMMITS
                return
            # branches-driving → step back to Branches
            self.focus = _PANE_BRANCHES
            return
        if f == _PANE_COMMITS:
            self.focus = _PANE_RIGHT_INFO
            self.last_sidebar_focus = _PANE_BRANCHES
            return
        if f == _PANE_BRANCHES:
            self.focus = _PANE_RIGHT_STAGED
            self.last_sidebar_focus = _PANE_FILES
            return
        if f == _PANE_RIGHT_STAGED:
            self.focus = _PANE_RIGHT_UNSTAGED
            return
        if f == _PANE_RIGHT_UNSTAGED:
            self.focus = _PANE_FILES
            self.last_sidebar_focus = _PANE_FILES
            return

    def _focused_right_panel_height(self, container_bounds: Rect) -> Int:
        if self.focus == _PANE_RIGHT_INFO:
            return self._diff_height(container_bounds) - 1
        var rp = self._right_panes(container_bounds)
        if self.focus == _PANE_RIGHT_UNSTAGED:
            return rp[1] - 1
        return rp[3] - 1

    def _scroll_focused_right(mut self, delta: Int, container_bounds: Rect):
        """Scroll the focused right panel and clamp its cursor.

        Dispatches to a free function (rather than a method) because
        Mojo's borrow checker rejects passing ``self.unstaged`` as a
        ``mut`` arg from a method that already holds ``mut self``."""
        var h = self._focused_right_panel_height(container_bounds)
        if self.focus == _PANE_RIGHT_UNSTAGED:
            _scroll_panel(self.unstaged, delta, h)
        elif self.focus == _PANE_RIGHT_STAGED:
            _scroll_panel(self.staged, delta, h)
        elif self.focus == _PANE_RIGHT_INFO:
            _scroll_panel(self.info, delta, h)

    def _move_focused_right_cursor(mut self, delta: Int, container_bounds: Rect):
        var h = self._focused_right_panel_height(container_bounds)
        if self.focus == _PANE_RIGHT_UNSTAGED:
            _move_panel_cursor(self.unstaged, delta, h)
        elif self.focus == _PANE_RIGHT_STAGED:
            _move_panel_cursor(self.staged, delta, h)
        elif self.focus == _PANE_RIGHT_INFO:
            _move_panel_cursor(self.info, delta, h)

    def _enter_right_pane(
        mut self, container_bounds: Rect, mut registry: GrammarRegistry,
    ):
        """Move focus from sidebar → right side. For file selections we
        land on Unstaged and snap the cursor to the first stageable
        add/remove line so a single Space after Right does something
        useful. For branch/commit selections we land on Info."""
        if self._is_right_focus():
            return
        self.last_sidebar_focus = self.focus
        self._ensure_right_panels(registry)
        var driving = self.last_sidebar_focus
        if driving == _PANE_FILES:
            self.focus = _PANE_RIGHT_UNSTAGED
            # Find first stageable add/remove line in unstaged; fall
            # back to 0. Lines now carry their kind explicitly because
            # the prefix character has moved to the gutter.
            var found = -1
            for i in range(len(self.unstaged.lines)):
                if self.unstaged.diff_line[i] < 0:
                    continue
                if i >= len(self.unstaged.kind):
                    continue
                var k = self.unstaged.kind[i]
                if k == _LINE_ADD or k == _LINE_REM:
                    found = i
                    break
            if found < 0:
                self.unstaged.cursor = 0
            else:
                self.unstaged.cursor = found
            var h = self._focused_right_panel_height(container_bounds)
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

    def _leave_right_pane(mut self):
        if not self._is_right_focus():
            return
        self.focus = self.last_sidebar_focus

    def _copy_focused(mut self):
        """Copy whatever the focused pane points at to the system
        clipboard:

        * Files / right diff panes (Unstaged / Staged / Info) — the
          single line under the cursor. Diff body rows store their text
          with the ``+`` / ``-`` / space gutter already stripped, so the
          copy is clean code, not a patch fragment.
        * Commits — ``<short_sha> <subject>``.
        * Branches — the branch name.

        Silent — copying is its own confirmation; an out-of-range
        cursor / empty pane just copies nothing."""
        if self.focus == _PANE_BRANCHES:
            if 0 <= self.sel_branch and self.sel_branch < len(self.branches):
                clipboard_copy(self.branches[self.sel_branch].name.copy())
            return
        if self.focus == _PANE_COMMITS:
            if 0 <= self.sel_commit and self.sel_commit < len(self.commits):
                var c = self.commits[self.sel_commit]
                clipboard_copy(c.short_sha + String(" ") + c.subject)
            return
        # File row, or any of the three right diff/info panes: copy the
        # cursor's line. ``_PANE_FILES`` copies the project-relative path;
        # the right panes copy the diff/log line under the cursor.
        if self.focus == _PANE_FILES:
            if 0 <= self.sel_file and self.sel_file < len(self.files):
                clipboard_copy(self.files[self.sel_file].path.copy())
            return
        if self.focus == _PANE_RIGHT_UNSTAGED:
            if 0 <= self.unstaged.cursor \
                    and self.unstaged.cursor < len(self.unstaged.lines):
                clipboard_copy(self.unstaged.lines[self.unstaged.cursor].copy())
        elif self.focus == _PANE_RIGHT_STAGED:
            if 0 <= self.staged.cursor \
                    and self.staged.cursor < len(self.staged.lines):
                clipboard_copy(self.staged.lines[self.staged.cursor].copy())
        elif self.focus == _PANE_RIGHT_INFO:
            if 0 <= self.info.cursor \
                    and self.info.cursor < len(self.info.lines):
                clipboard_copy(self.info.lines[self.info.cursor].copy())

    def handle_key(
        mut self, event: Event, container_bounds: Rect,
        mut registry: GrammarRegistry,
    ) -> Bool:
        if not self.active or event.kind != EVENT_KEY:
            return False
        if self.overlay != _OVERLAY_NONE:
            return self._handle_overlay_key(event)
        var bounds = self._panel_rect(container_bounds)
        var k = event.key
        if k == KEY_ESC:
            # Refuse to close while a git op is in flight — the spinner
            # popup is the only feedback the user has and dropping the
            # modal would orphan the live child without surfacing its
            # result.
            if self._is_git_busy():
                self._show_status(
                    String("Git operation in progress — please wait."),
                    False,
                )
                return True
            self.close()
            return True
        # Copy (Cmd/⌘+C). Handled before the file-pane bare-letter
        # shortcuts below so the ⌘ chord doesn't fall through to 'c' →
        # commit. The native frontend replays its ⌘C menu equivalent
        # into this handler as a MOD_META key event (see the
        # ``_modal_owns_input`` gate in desktop.dispatch_action), so the
        # same branch serves both frontends. What gets copied depends on
        # the focused pane.
        if k == UInt32(0x63) and (event.mods & MOD_META) != 0:
            self._copy_focused()
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
            self._enter_right_pane(bounds, registry)
            return True
        if k == KEY_LEFT:
            self._leave_right_pane()
            return True
        if k == KEY_SPACE:
            self._handle_space(bounds)
            return True
        # Branch-pane git operations: M / d. Placed before the
        # type-to-jump block below, which means those two letters no
        # longer jump the cursor on this pane — the same trade the Files
        # pane already makes for c / A / d / p / P.
        if self.focus == _PANE_BRANCHES:
            if k == UInt32(0x4D):       # 'M' (shift+m) → merge into HEAD
                self._run_merge()
                return True
            if k == UInt32(0x64):       # 'd' → delete branch
                self._delete_selected_branch()
                return True
        # Commits pane: 'e' → edit the selected commit's message. Same
        # trade as the other panes' bare letters — 'e' no longer
        # type-jumps here, which is why this sits above the type-to-jump
        # block below.
        if self.focus == _PANE_COMMITS:
            if k == UInt32(0x65):       # 'e' → edit commit message
                self._open_reword_prompt()
                return True
        if self._is_right_focus():
            if self.focus == _PANE_RIGHT_UNSTAGED and k == UInt32(0x64):
                # 'd' → discard the worktree change on the cursor's line.
                self._open_discard_line_confirm()
                return True
            if k == KEY_UP:
                self._move_focused_right_cursor(-1, bounds)
                return True
            if k == KEY_DOWN:
                self._move_focused_right_cursor(1, bounds)
                return True
            if k == KEY_HOME:
                self._move_focused_right_cursor(-100000, bounds)
                return True
            if k == KEY_END:
                self._move_focused_right_cursor(100000, bounds)
                return True
            if k == KEY_PAGEUP:
                var h = self._focused_right_panel_height(bounds)
                self._scroll_focused_right(-h, bounds)
                self._move_focused_right_cursor(-h, bounds)
                return True
            if k == KEY_PAGEDOWN:
                var h = self._focused_right_panel_height(bounds)
                self._scroll_focused_right(h, bounds)
                self._move_focused_right_cursor(h, bounds)
                return True
            return False
        if k == KEY_UP:
            self._set_focused_selection(self._focused_selection() - 1, bounds)
            return True
        if k == KEY_DOWN:
            self._set_focused_selection(self._focused_selection() + 1, bounds)
            return True
        if k == KEY_HOME:
            self._set_focused_selection(0, bounds)
            return True
        if k == KEY_END:
            self._set_focused_selection(self._focused_count() - 1, bounds)
            return True
        if k == KEY_PAGEUP:
            self._set_focused_selection(
                self._focused_selection() - self._focused_panel_height(bounds),
                bounds,
            )
            return True
        if k == KEY_PAGEDOWN:
            self._set_focused_selection(
                self._focused_selection() + self._focused_panel_height(bounds),
                bounds,
            )
            return True
        # Framework type-to-jump on the Branches / Commits panes.
        # Files pane is intentionally excluded so its bare-letter git
        # shortcuts (c / A / d / p / P) keep working — see the
        # ``_type_ahead`` field comment for the rationale.
        if is_printable_ascii(k) and (
            self.focus == _PANE_BRANCHES or self.focus == _PANE_COMMITS
        ):
            var labels = List[String]()
            if self.focus == _PANE_BRANCHES:
                for i in range(len(self.branches)):
                    labels.append(self.branches[i].name)
            else:
                for i in range(len(self.commits)):
                    labels.append(self.commits[i].subject)
            var hit = type_ahead_pick(
                self._type_ahead, labels, chr(Int(k)),
            )
            if hit >= 0:
                self._set_focused_selection(hit, bounds)
            return True
        if k == KEY_ENTER:
            # Enter only does something for file rows — open the file.
            # On branches/commits there's no obvious "open" action, and
            # branch checkout lives on Space (see ``_handle_space``), so
            # Enter stays inert there rather than guessing.
            if self.focus == _PANE_FILES \
                    and 0 <= self.sel_file \
                    and self.sel_file < len(self.files):
                self._submit_selected_file()
            return True
        return False

    def _handle_space(mut self, container_bounds: Rect):
        """Stage / unstage the focused thing.

        * On the Files panel: toggle whole-file staged status — stage if
          the worktree column shows any change, unstage if only the
          staged column does. (For an entry with both, prefer staging
          the rest of the worktree changes; the user can press Space
          again to unstage.)
        * On the Branches panel: check out the selected branch. Not
          gated behind a confirmation — git refuses the switch outright
          when it would clobber local changes, and switching back is one
          more keystroke.
        * On Unstaged / Staged right panels: build a minimal patch from
          the cursor's single line and apply it (forward to stage from
          Unstaged, ``--reverse`` to unstage from Staged).

        Anywhere else (commits / info / non-actionable line) it's a
        no-op rather than an error so the keystroke doesn't grab focus
        from a future binding.
        """
        if self.focus == _PANE_FILES:
            if 0 <= self.sel_file and self.sel_file < len(self.files):
                self._toggle_file_at(self.sel_file)
            return
        if self.focus == _PANE_BRANCHES:
            self._run_checkout()
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

    def _toggle_file_at(mut self, idx: Int):
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

    def _toggle_diff_line(
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

    def _refresh_after_mutation(mut self, kept_path: String):
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

    def _refresh_full(mut self):
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

    def _open_commit_prompt(mut self):
        """Pop the commit-message input. Pre-checks that *something* is
        actually staged so we don't pop a prompt that git will refuse."""
        if self._is_git_busy():
            self._show_status(
                String("Git operation in progress — please wait."), False,
            )
            return
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
        self.overlay_input = TextField()
        if len(self._pending_commit_message.as_bytes()) > 0:
            self.overlay_input.set_text(self._pending_commit_message.copy())
        self.overlay_message = String("")

    def _open_reword_prompt(mut self):
        """Pop the multi-line editor for the selected commit's message.

        Refuses up front rather than letting the user type a message we'd
        then have to throw away:

        * **Pushed commits.** Rewriting one would need a force-push and
          would break anyone who already fetched it. ``is_pushed`` is
          conservative (with no remotes configured everything counts as
          unpushed), which errs toward allowing the edit on a purely
          local repo — the case where it's unambiguously safe.
        * **Merge commits**, and any merge between the commit and HEAD.
          The replay path is ``git rebase``, which flattens merges by
          default, so a "message-only" edit would silently restructure
          history.
        """
        if self._is_git_busy():
            self._show_status(
                String("Git operation in progress — please wait."), False,
            )
            return
        if self.sel_commit < 0 or self.sel_commit >= len(self.commits):
            return
        var c = self.commits[self.sel_commit]
        if c.is_pushed:
            self._show_status(
                String("Commit ") + c.short_sha
                + String(" is already pushed — its message can't be edited."),
                False,
            )
            return
        if c.is_merge():
            self._show_status(
                String("Can't edit a merge commit's message."), False,
            )
            return
        if has_merge_between(self.root, c.short_sha):
            self._show_status(
                String("A merge sits between ") + c.short_sha
                + String(" and HEAD — editing would flatten it."),
                False,
            )
            return
        var existing = fetch_commit_message(self.root, c.short_sha)
        self._reword_sha = c.short_sha.copy()
        self._reword_is_head = (head_short_sha(self.root) == c.short_sha)
        self.overlay = _OVERLAY_EDIT_MSG
        self.overlay_area = TextArea()
        self.overlay_area.set_text(existing)
        self.overlay_message = String("")

    def _open_amend_confirm(mut self):
        if self._is_git_busy():
            self._show_status(
                String("Git operation in progress — please wait."), False,
            )
            return
        self.overlay = _OVERLAY_AMEND_CONFIRM
        self.overlay_input = TextField()
        self.overlay_message = \
            String("Amend HEAD with --no-edit? Folds staged changes into the last commit.")

    def _open_revert_confirm(mut self):
        if self._is_git_busy():
            self._show_status(
                String("Git operation in progress — please wait."), False,
            )
            return
        if self.sel_file < 0 or self.sel_file >= len(self.files):
            self._show_status(String("No file selected."), False)
            return
        var fe = self.files[self.sel_file]
        self.overlay = _OVERLAY_REVERT_CONFIRM
        self.overlay_input = TextField()
        var untracked = (Int(fe.staged) == 0x3F and Int(fe.worktree) == 0x3F)
        if untracked:
            self.overlay_message = \
                String("Delete untracked file ") + fe.path + String("?")
        else:
            self.overlay_message = \
                String("Discard ALL local changes for ") + fe.path \
                + String(" (staged + worktree)?")

    def _open_discard_line_confirm(mut self):
        """Pop the y/n confirm for discarding the single worktree line under
        the Unstaged panel's cursor. No-op (with a hint flash) when the
        cursor isn't on a ``+``/``-`` body line — only added/removed lines
        have a change to throw away."""
        if self._is_git_busy():
            self._show_status(
                String("Git operation in progress — please wait."), False,
            )
            return
        if self.sel_file < 0 or self.sel_file >= len(self.files):
            return
        var cursor = self.unstaged.cursor
        if cursor < 0 or cursor >= len(self.unstaged.lines):
            return
        var kind = self.unstaged.kind[cursor]
        if kind != _LINE_ADD and kind != _LINE_REM:
            self._show_status(
                String("Move the cursor onto a changed (+/-) line to discard it."),
                False,
            )
            return
        var diff_idx = self.unstaged.diff_line[cursor]
        if diff_idx < 0:
            return
        self._discard_diff_idx = diff_idx
        self.overlay = _OVERLAY_DISCARD_LINE_CONFIRM
        self.overlay_input = TextField()
        self.overlay_message = \
            String("Discard this line from the working tree?")

    def _confirm_discard_line(mut self):
        """Reverse-apply the cursor line's minimal patch to the working
        tree, undoing just that one unstaged change. Builds the patch with
        ``reverse=True`` so its post-image matches the worktree (other ±
        lines demoted to context / dropped), which is what
        ``git apply --reverse`` needs."""
        var diff_idx = self._discard_diff_idx
        self._discard_diff_idx = -1
        if self.sel_file < 0 or self.sel_file >= len(self.files):
            self._close_overlay()
            return
        var path = self.files[self.sel_file].path
        var patch = build_minimal_patch(
            self.files[self.sel_file].unstaged_diff, diff_idx, True,
        )
        self._close_overlay()
        if len(patch.as_bytes()) == 0:
            return
        if not apply_patch_to_worktree(self.root, patch, True):
            self._show_status(
                String("Discard failed — the line no longer applies."), False,
            )
            return
        self._refresh_after_mutation(path)

    def _show_status(mut self, var msg: String, ok: Bool):
        """Report the outcome of an operation, modally or not depending on
        whether the user needs to act on it.

        **Success** goes to ``flash_message``: a transient one-liner on
        the sub-title row that expires on its own after ``_FLASH_MS`` and
        intercepts nothing. A modal here would put a mandatory keystroke
        between the user and their next action for no reason — the panels
        have already refreshed to show what happened, so the text is a
        confirmation, not information.

        **Failure** keeps the modal ``_OVERLAY_STATUS`` flash. Nothing on
        screen changed, so a banner that quietly ages out is exactly how
        an error gets missed; making it cost a keystroke is the point."""
        if ok:
            self.flash_message = msg^
            self._flash_until_ms = monotonic_ms() + _FLASH_MS
            return
        self.overlay = _OVERLAY_STATUS
        self.overlay_message = msg^
        self.overlay_input = TextField()

    def _open_output_overlay(mut self, var text: String):
        """Show a git op's full output full-screen, scrolled to the bottom.

        Opened for anything that isn't the routine success: a deploy log a
        remote streamed back, a talkative hook, or a failure. The bottom
        is where the answer is, so that's where we start."""
        self.overlay = _OVERLAY_OUTPUT
        self.overlay_input = TextField()
        self.overlay_message = String("")
        self.overlay_output = text^
        # Clamped against the real viewport on the first paint; a large
        # number just means "as far down as it goes".
        self.overlay_output_scroll = 1 << 30

    def _output_kind_for(self, op: Int) -> Int:
        """Map an in-flight ``_GITOP_*`` onto the git subcommand whose
        output shape ``git_output`` knows how to recognize."""
        if op == _GITOP_COMMIT or op == _GITOP_AMEND:
            return GIT_OUT_COMMIT
        if op == _GITOP_PUSH:
            return GIT_OUT_PUSH
        if op == _GITOP_PULL:
            return GIT_OUT_PULL
        if op == _GITOP_CHECKOUT:
            return GIT_OUT_CHECKOUT
        if op == _GITOP_MERGE:
            return GIT_OUT_MERGE
        if op == _GITOP_REBASE:
            return GIT_OUT_REBASE
        if op == _GITOP_REWORD:
            # Amending the tip talks like a commit; replaying onto a
            # rewritten parent talks like a rebase.
            return GIT_OUT_COMMIT if self._reword_is_head else GIT_OUT_REBASE
        if op == _GITOP_BRANCH_DELETE:
            return GIT_OUT_BRANCH_DELETE
        if op == _GITOP_REVERT:
            return GIT_OUT_RESTORE
        return GIT_OUT_OTHER

    def _promote_if_interesting(mut self):
        """While a child runs, watch its output and switch the spinner to
        the full-screen log the moment it says something unexpected.

        This is what makes a ``git push`` to a Dokku-style remote watchable
        without making an ordinary push intrusive: both start as the same
        corner spinner, and only the one streaming a build log grows into
        the whole view. Sticky — once promoted we stop classifying, so the
        remaining megabyte of log costs nothing.

        Only complete lines are classified; a half-read line can fail to
        match a pattern it would match a moment later."""
        if self._output_promoted or self._git_op == _GITOP_NONE:
            return
        var done = complete_lines(self.git_runner.output)
        if len(done.as_bytes()) == 0:
            return
        if self._output_matcher.is_routine(done):
            return
        self._output_promoted = True
        self.git_runner.full_screen = True

    def _expire_flash(mut self):
        """Drop the success banner once its window has passed. Called from
        ``tick``, which the host runs every frame."""
        if len(self.flash_message.as_bytes()) == 0:
            return
        if monotonic_ms() >= self._flash_until_ms:
            self.flash_message = String("")
            self._flash_until_ms = 0

    def _close_overlay(mut self):
        self.overlay = _OVERLAY_NONE
        self.overlay_input = TextField()
        self.overlay_message = String("")
        self.overlay_output = String("")
        self.overlay_output_scroll = 0
        # Queued-but-unconfirmed targets die with the overlay.
        # ``_confirm_delete_branch`` takes its copy before closing.
        if self._git_op != _GITOP_BRANCH_DELETE:
            self._git_delete_branch = String("")
        # Same for the merge-style choice, whose two answers
        # (``_confirm_merge_commit`` / ``_confirm_merge_rebase``) also copy
        # the branch out and restore it after closing.
        if self._git_op != _GITOP_MERGE and self._git_op != _GITOP_REBASE:
            self._git_merge_branch = String("")

    def _is_git_busy(self) -> Bool:
        """True iff an async git op is currently in flight via
        ``git_runner``. Callers should refuse to start a second op while
        this is set — the runner is single-slot and the user-facing
        popup only renders one at a time."""
        return self._git_op != _GITOP_NONE or self.git_runner.is_active()

    def _start_git_op(
        mut self, op: Int, var label: String, var argv: List[String],
        var title_prefix: String,
    ):
        """Spawn an async git child via ``git_runner``. Records the op
        type so ``tick`` knows which refresh to run when the child
        reaps. Flashes a one-line status on spawn failure rather than
        raising — these are user-visible operations and a hung modal is
        worse than an inline error."""
        if self._is_git_busy():
            self._show_status(
                String("Another git operation is still running."), False,
            )
            return
        var spawned: Bool
        try:
            self.git_runner.start_argv(label.copy(), argv^, title_prefix^)
            spawned = True
        except:
            spawned = False
        if spawned:
            self._git_op = op
            self._git_op_label = label^
            # Arm the classifier for this op's expected output before any
            # of it arrives.
            self._output_matcher = GitOutputMatcher(self._output_kind_for(op))
            self._output_promoted = False
        else:
            self._show_status(
                String("Failed to start ") + label, False,
            )

    def _run_pull(mut self):
        var argv = List[String]()
        argv.append(String("git"))
        argv.append(String("-C"))
        argv.append(self.root)
        argv.append(String("pull"))
        self._start_git_op(
            _GITOP_PULL, String("git pull"), argv^, String("Running "),
        )

    def _run_push(mut self):
        var argv = List[String]()
        argv.append(String("git"))
        argv.append(String("-C"))
        argv.append(self.root)
        argv.append(String("push"))
        self._start_git_op(
            _GITOP_PUSH, String("git push"), argv^, String("Running "),
        )

    def _run_checkout(mut self):
        """``git checkout`` the selected branch. Already-current branch is
        a no-op flash rather than a git invocation, so Space on the ``*``
        row doesn't spin the runner for nothing. Open editors pick up the
        new file contents through the desktop's usual external-change
        poll."""
        if self.sel_branch < 0 or self.sel_branch >= len(self.branches):
            self._show_status(String("No branch selected."), False)
            return
        var br = self.branches[self.sel_branch]
        if br.is_current:
            self._show_status(
                String("Already on ") + br.name, True,
            )
            return
        var argv = List[String]()
        argv.append(String("git"))
        argv.append(String("-C"))
        argv.append(self.root)
        argv.append(String("checkout"))
        argv.append(br.name)
        self._git_checkout_branch = br.name.copy()
        self._start_git_op(
            _GITOP_CHECKOUT, String("git checkout"), argv^, String("Running "),
        )

    def _run_merge(mut self):
        """``M`` on the Branches panel: integrate the selected branch into
        the checked-out one — but ask *how* first.

        The two answers are the two shapes a repo's history can take, and
        which one a project wants isn't something we can infer:

        * ``m`` — ``git merge --no-ff``: a merge commit, both histories
          preserved, the integration itself recorded as an event.
        * ``r`` — ``git rebase``: straight history, our commits replayed
          on top of the branch. Nothing new is recorded, and the commits
          being replayed get new SHAs.

        ``--no-ff`` rather than a bare ``git merge`` because the choice
        has to mean what it says: bare merge silently fast-forwards when
        it can, which is the *other* option's outcome. The same reasoning
        makes ``--no-edit`` explicit — git decides whether to open an
        editor partly from whether stdout is a terminal, and a git op
        blocking forever on an editor we never show would be the worst
        possible answer.

        Neither answer gets a second confirmation. git refuses both
        outright when the worktree is dirty, a merge that starts is undone
        with ``git merge --abort`` and a rebase with ``git rebase
        --abort``, and either one stopping on a conflict exits non-zero,
        so it surfaces as git's own diagnostic rather than as success."""
        if self.sel_branch < 0 or self.sel_branch >= len(self.branches):
            self._show_status(String("No branch selected."), False)
            return
        var br = self.branches[self.sel_branch]
        if br.is_current:
            self._show_status(
                String("Can't merge ") + br.name + String(" into itself."),
                False,
            )
            return
        if self._is_git_busy():
            self._show_status(
                String("Git operation in progress — please wait."), False,
            )
            return
        self._git_merge_branch = br.name.copy()
        self.overlay = _OVERLAY_MERGE_CHOICE
        self.overlay_input = TextField()
        self.overlay_message = String("Bring ") + br.name \
            + String(" into ") + self._current_branch_name() + String(":")

    def _current_branch_name(self) -> String:
        """Name of the checked-out branch as the branch list reports it,
        or ``HEAD`` when nothing is tagged current (detached HEAD, or a
        list we haven't fetched yet). Only used for overlay wording."""
        for i in range(len(self.branches)):
            if self.branches[i].is_current:
                return self.branches[i].name.copy()
        return String("HEAD")

    def _confirm_merge_commit(mut self):
        """``m`` in the merge-style overlay — the merge-commit answer."""
        var name = self._git_merge_branch.copy()
        self._close_overlay()
        if len(name.as_bytes()) == 0:
            return
        var argv = List[String]()
        argv.append(String("git"))
        argv.append(String("-C"))
        argv.append(self.root)
        argv.append(String("merge"))
        argv.append(String("--no-ff"))
        argv.append(String("--no-edit"))
        argv.append(name)
        self._git_merge_branch = name^
        self._start_git_op(
            _GITOP_MERGE, String("git merge"), argv^, String("Running "),
        )

    def _confirm_merge_rebase(mut self):
        """``r`` in the merge-style overlay — the straight-history answer.

        Three commands, in this order::

            git rebase <current> <branch>   # replay branch onto current
            git checkout <current>
            git merge --ff-only <branch>

        The one-command version of this is ``git rebase <branch>`` run
        from ``<current>``, and it is **wrong here**: that replays
        *current's* commits onto ``<branch>``, which rewrites the SHAs of
        commits on the branch you're standing on. When those commits were
        already pushed — the normal case for ``main`` — the local branch
        silently diverges from its upstream, and the next pull reports
        "have diverged, N and M different commits each" and manufactures
        a merge that reintroduces the originals.

        Rewriting has to land on the *topic* branch, whose commits are
        the unpublished ones, and the integration branch then only ever
        moves forward — hence the rebase-then-fast-forward pair, which is
        what a forge's "Rebase and merge" button does. ``--ff-only`` is
        load-bearing: after the rebase the fast-forward is guaranteed, so
        if it somehow isn't, that's a bug worth failing on rather than a
        merge commit to paper over it in the answer that exists to avoid
        merge commits.

        The steps are chained in ``tick`` as they reap; a failure at any
        step stops the chain and reports (see ``_advance_rebase_chain``)."""
        var name = self._git_merge_branch.copy()
        var onto = self._current_branch_name()
        self._close_overlay()
        if len(name.as_bytes()) == 0:
            return
        if onto == String("HEAD"):
            # Detached HEAD: there's no branch ref to fast-forward at the
            # end, so the chain has nowhere to land.
            self._show_status(
                String("Not on a branch — check one out first."), False,
            )
            return
        self._git_merge_branch = name.copy()
        self._rebase_onto = onto.copy()
        self._rebase_step = 1
        var argv = List[String]()
        argv.append(String("git"))
        argv.append(String("-C"))
        argv.append(self.root)
        argv.append(String("rebase"))
        argv.append(onto^)
        argv.append(name^)
        self._start_git_op(
            _GITOP_REBASE, String("git rebase"), argv^, String("Running "),
        )
        if self._git_op == _GITOP_NONE:
            # Spawn refused or failed; don't leave the chain armed.
            self._rebase_step = 0
            self._rebase_onto = String("")

    def _advance_rebase_chain(mut self, ok: Bool) -> Bool:
        """Called as each step of the straight-history chain reaps.
        Returns True when another step was started, meaning the caller
        should report nothing yet.

        A failed step ends the chain where it stands. That deliberately
        leaves the repo mid-operation (a conflicted rebase keeps its
        state so it can be resolved and continued); we just stop driving
        it and let the normal failure reporting say so."""
        if self._rebase_step == 0:
            return False
        if not ok:
            self._rebase_step = 0
            return False
        var onto = self._rebase_onto.copy()
        var name = self._git_merge_branch.copy()
        if len(onto.as_bytes()) == 0 or len(name.as_bytes()) == 0:
            self._rebase_step = 0
            return False
        var argv = List[String]()
        argv.append(String("git"))
        argv.append(String("-C"))
        argv.append(self.root)
        var kind: Int
        if self._rebase_step == 1:
            # The rebase left HEAD on the topic branch; go back to the
            # branch we're integrating into.
            self._rebase_step = 2
            argv.append(String("checkout"))
            argv.append(onto^)
            kind = GIT_OUT_CHECKOUT
        elif self._rebase_step == 2:
            self._rebase_step = 3
            argv.append(String("merge"))
            argv.append(String("--ff-only"))
            argv.append(name^)
            kind = GIT_OUT_MERGE
        else:
            # Last step reaped ok — the chain is done. ``_rebase_onto``
            # stays set until ``tick`` has used it to name the branches in
            # the success flash; tick clears it with the other op state.
            self._rebase_step = 0
            return False
        self._start_git_op(
            _GITOP_REBASE, String("git rebase"), argv^, String("Running "),
        )
        if self._git_op == _GITOP_NONE:
            self._rebase_step = 0
            return False
        # ``_start_git_op`` armed the classifier for a rebase; this step is
        # a checkout / merge and prints that shape of output instead.
        self._output_matcher = GitOutputMatcher(kind)
        return True

    def _delete_selected_branch(mut self):
        """``d`` on the Branches panel.

        Deletes the selected branch outright when its work is already on
        the repo's main line, and pops a y/n confirm when it isn't —
        that's the only case where the keystroke would destroy commits.
        ``branch_is_merged`` decides that by content rather than
        ancestry, so a branch that was rebased or squash-merged into main
        deletes without ceremony. It also answers False for the main
        branch itself and for a repo with no ``main`` / ``master``, so
        both of those route through the confirm too.

        The current branch is refused up front: git won't delete the
        branch you're standing on, and saying so is friendlier than
        relaying its error."""
        if self._is_git_busy():
            self._show_status(
                String("Git operation in progress — please wait."), False,
            )
            return
        if self.sel_branch < 0 or self.sel_branch >= len(self.branches):
            self._show_status(String("No branch selected."), False)
            return
        var br = self.branches[self.sel_branch]
        if br.is_current:
            self._show_status(
                String("Can't delete the checked-out branch ") + br.name
                + String("."),
                False,
            )
            return
        if branch_is_merged(self.root, br.name):
            self._start_branch_delete(br.name)
            return
        self._git_delete_branch = br.name.copy()
        self.overlay = _OVERLAY_DELETE_BRANCH_CONFIRM
        self.overlay_input = TextField()
        var main = main_line_branch(self.root)
        if len(main.as_bytes()) == 0:
            self.overlay_message = String("Delete ") + br.name \
                + String("? No main/master to check it against.")
        elif main == br.name:
            self.overlay_message = String("Delete ") + br.name \
                + String(" — this repo's main branch?")
        else:
            self.overlay_message = String("Delete ") + br.name \
                + String("? NOT merged into ") + main \
                + String("; commits will be lost.")

    def _confirm_delete_branch(mut self):
        var name = self._git_delete_branch.copy()
        self._close_overlay()
        if len(name.as_bytes()) == 0:
            return
        self._start_branch_delete(name)

    def _start_branch_delete(mut self, name: String):
        """Spawn ``git branch -D``.

        Always ``-D``, never ``-d``, because by the time we get here the
        safety question is already settled — either ``branch_is_merged``
        proved the work is on the main line, or the user answered the
        confirmation. Letting git re-litigate it with ``-d`` would only
        produce confusing failures, and for two distinct reasons: ``-d``
        judges by ancestry, so it refuses exactly the rebased and
        squash-merged branches this feature exists to delete; and it
        judges against **HEAD**, not the main line, so it would also
        refuse a plainly-merged branch whenever you happen to be standing
        on some other feature branch."""
        var argv = List[String]()
        argv.append(String("git"))
        argv.append(String("-C"))
        argv.append(self.root)
        argv.append(String("branch"))
        argv.append(String("-D"))
        argv.append(name)
        self._git_delete_branch = name.copy()
        self._start_git_op(
            _GITOP_BRANCH_DELETE, String("git branch -D"), argv^,
            String("Running "),
        )

    def _submit_commit(mut self):
        var msg = self.overlay_input.text
        if len(msg.as_bytes()) == 0:
            self._show_status(String("Empty commit message."), False)
            return
        var argv = List[String]()
        argv.append(String("git"))
        argv.append(String("-C"))
        argv.append(self.root)
        argv.append(String("commit"))
        argv.append(String("-m"))
        argv.append(msg)
        # Remember the message so a hook rejection / other failure can
        # repopulate the prompt next time — ``tick`` clears this on a
        # successful reap.
        self._pending_commit_message = msg.copy()
        # Close the commit-message overlay first so the spinner popup
        # isn't drawn behind the modal box. ``_start_git_op`` will flash
        # an inline status overlay on failure.
        self._close_overlay()
        self._start_git_op(
            _GITOP_COMMIT, String("git commit"), argv^, String("Running "),
        )

    def _submit_reword(mut self):
        """Apply the edited message to ``_reword_sha``.

        Two strategies, because only one of them is cheap:

        * **The tip** — ``git commit --amend -m <msg>``. Touches nothing
          but HEAD's message, and leaves the index and worktree alone.
        * **An older commit** — write a copy of it carrying the new
          message (``create_reworded_commit``, a pure object-store write),
          then ``git rebase --onto <new> <old> HEAD`` to replay its
          children onto the copy. Those children keep their trees, so the
          replay is content-identical and can't raise a conflict; only the
          message differs. ``--autostash`` covers a dirty worktree, which
          rebase would otherwise refuse outright.

        Both are guarded by ``_open_reword_prompt``: unpushed only, and no
        merges in the replayed range.
        """
        if self.overlay_area.is_empty():
            self._show_status(String("Empty commit message."), False)
            return
        var msg = self.overlay_area.text()
        var sha = self._reword_sha.copy()
        if len(sha.as_bytes()) == 0:
            self._close_overlay()
            return
        var argv = List[String]()
        argv.append(String("git"))
        argv.append(String("-C"))
        argv.append(self.root)
        if self._reword_is_head:
            argv.append(String("commit"))
            argv.append(String("--amend"))
            argv.append(String("-m"))
            argv.append(msg)
        else:
            # Build the replacement object first: if this fails there's
            # nothing to undo, and the editor is still open with the
            # user's text intact.
            var new_sha = create_reworded_commit(self.root, sha, msg)
            if len(new_sha.as_bytes()) == 0:
                self._show_status(
                    String("Could not rewrite ") + sha + String("."), False,
                )
                return
            argv.append(String("rebase"))
            argv.append(String("--autostash"))
            argv.append(String("--onto"))
            argv.append(new_sha)
            argv.append(sha)
            argv.append(String("HEAD"))
        self._close_overlay()
        self._start_git_op(
            _GITOP_REWORD, String("git reword"), argv^, String("Running "),
        )

    def _confirm_amend(mut self):
        var argv = List[String]()
        argv.append(String("git"))
        argv.append(String("-C"))
        argv.append(self.root)
        argv.append(String("commit"))
        argv.append(String("--amend"))
        argv.append(String("--no-edit"))
        self._close_overlay()
        self._start_git_op(
            _GITOP_AMEND, String("git amend"), argv^, String("Running "),
        )

    def _confirm_revert(mut self):
        if self.sel_file < 0 or self.sel_file >= len(self.files):
            self._close_overlay()
            return
        var fe = self.files[self.sel_file]
        var untracked = (Int(fe.staged) == 0x3F and Int(fe.worktree) == 0x3F)
        var argv = List[String]()
        argv.append(String("git"))
        argv.append(String("-C"))
        argv.append(self.root)
        if untracked:
            argv.append(String("clean"))
            argv.append(String("-f"))
            argv.append(String("--"))
            argv.append(fe.path)
        else:
            argv.append(String("checkout"))
            argv.append(String("HEAD"))
            argv.append(String("--"))
            argv.append(fe.path)
        self._git_revert_path = fe.path
        self._git_revert_untracked = untracked
        self._close_overlay()
        self._start_git_op(
            _GITOP_REVERT, String("git revert"), argv^, String("Running "),
        )

    def tick(mut self):
        """Drain the in-flight git child (if any). When it reaps, refresh
        the affected panels and report the summary — as a self-expiring
        sub-title flash on success, as a modal on failure (see
        ``_show_status``).

        Safe to call every frame regardless of whether anything's in
        flight; returns immediately when idle. We deliberately *don't*
        gate on ``self.active`` — if the modal got closed while a child
        was still running (e.g. the user Enter'd a file to open it), we
        still need to drain the pipes and reap the pid here so the
        child doesn't get orphaned with a full kernel pipe buffer."""
        # Age out the previous success flash. Ahead of the early returns
        # below: the flash outlives the op that set it, so its expiry
        # can't be gated on one being in flight.
        self._expire_flash()
        # Notice on-disk git changes we didn't cause and reload (no-op while
        # one of our ops is in flight — it gates on ``_git_op``).
        self._poll_external_change()
        if self._git_op == _GITOP_NONE:
            return
        var maybe = self.git_runner.tick()
        # Classify what's arrived so far — a child that turns out to be
        # streaming a build log gets the whole view while it still has
        # something to show, not a summary after the fact.
        self._promote_if_interesting()
        if not maybe:
            return
        var r = maybe.value()
        var op = self._git_op
        self._git_op = _GITOP_NONE
        # Modal closed mid-op: reap and drop. Nothing to flash and
        # ``_refresh_full`` would re-fetch state we no longer display.
        if not self.active:
            self._git_op_label = String("")
            self._git_revert_path = String("")
            self._git_revert_untracked = False
            self._git_checkout_branch = String("")
            self._git_merge_branch = String("")
            self._git_delete_branch = String("")
            # Whatever step was in flight is the last one we drive — the
            # view that would report the rest is gone.
            self._rebase_step = 0
            self._rebase_onto = String("")
            self._rebase_log = String("")
            self._rebase_noisy = False
            return
        var ok = r.ok()
        # Three fates, decided here: a routine success reports through the
        # non-modal flash, anything else opens the full-screen log. See
        # ``git_output`` for what "routine" means and why the test is
        # "every line was expected" rather than "nothing looked wrong".
        var routine = ok and not self._output_promoted \
            and self._output_matcher.is_routine(r.output)
        # Push/pull report progress + the final summary on stderr; the
        # rest report success on stdout and the error on stderr. We
        # collapse the captured output to a single trimmed line for the
        # status flash and prefer stdout on success / stderr on failure.
        var summary = _first_useful_line(r.output)
        # Straight-history integration is a chain of git commands; keep
        # this step's output, start the next one, and report nothing until
        # the chain either finishes or stops on a failure.
        if self._rebase_step > 0:
            self._rebase_log += r.output
            if not routine:
                self._rebase_noisy = True
            if self._advance_rebase_chain(ok):
                return
            r.output = self._rebase_log.copy()
            self._rebase_log = String("")
            routine = ok and not self._rebase_noisy
            self._rebase_noisy = False
            # A clean chain reports through its own one-liner below —
            # git's per-step chatter names the topic branch it rewrote,
            # which reads like the wrong thing happened.
            summary = String("") if routine else _first_useful_line(r.output)
        var fallback: String
        if op == _GITOP_COMMIT:
            fallback = String("commit ok") if ok else String("commit failed")
        elif op == _GITOP_AMEND:
            fallback = String("amend ok") if ok else String("amend failed")
        elif op == _GITOP_PULL:
            fallback = String("pull ok") if ok else String("pull failed")
        elif op == _GITOP_PUSH:
            fallback = String("push ok") if ok else String("push failed")
        elif op == _GITOP_REVERT:
            if ok and self._git_revert_untracked:
                fallback = String("removed untracked file")
            elif ok:
                fallback = String("reverted ") + self._git_revert_path
            else:
                fallback = String("revert failed")
        elif op == _GITOP_CHECKOUT:
            if ok:
                fallback = String("switched to ") + self._git_checkout_branch
            else:
                fallback = String("checkout failed")
        elif op == _GITOP_MERGE:
            if ok:
                fallback = String("merged ") + self._git_merge_branch
            else:
                fallback = String("merge failed")
        elif op == _GITOP_REBASE:
            if ok:
                fallback = String("rebased ") + self._git_merge_branch \
                    + String(" into ") + self._rebase_onto
            else:
                fallback = String("rebase failed")
        elif op == _GITOP_REWORD:
            if ok:
                fallback = String("reworded ") + self._reword_sha
            else:
                fallback = String("reword failed")
        elif op == _GITOP_BRANCH_DELETE:
            if ok:
                fallback = String("deleted ") + self._git_delete_branch
            else:
                fallback = String("delete failed")
        else:
            fallback = String("done") if ok else String("failed")
        var had_output = len(summary.as_bytes()) > 0
        var msg: String
        if had_output:
            msg = summary^
        else:
            msg = fallback^
        if ok:
            self._refresh_full()
        if op == _GITOP_COMMIT and ok:
            self._pending_commit_message = String("")
        if op == _GITOP_CHECKOUT and ok:
            # Branches sort by most recent commit, so the refreshed list
            # can have moved the row we just checked out — follow it by
            # name rather than leaving the cursor on whatever slid in.
            var switched = self._git_checkout_branch.copy()
            self._select_branch_by_name(switched)
        if routine:
            self._show_status(msg^, True)
        elif had_output:
            # Everything git said, not just the last line — the reason the
            # output was worth stopping for is usually several lines up.
            self._open_output_overlay(r.output.copy())
        else:
            # Silent failure (a spawn that died, a command with no
            # diagnostic): our own one-liner is all there is to show.
            self._show_status(msg^, False)
        self._git_op_label = String("")
        if op == _GITOP_REVERT:
            self._git_revert_path = String("")
            self._git_revert_untracked = False
        if op == _GITOP_CHECKOUT:
            self._git_checkout_branch = String("")
        if op == _GITOP_MERGE or op == _GITOP_REBASE:
            self._git_merge_branch = String("")
            self._rebase_onto = String("")
        if op == _GITOP_BRANCH_DELETE:
            self._git_delete_branch = String("")
        if op == _GITOP_REWORD:
            self._reword_sha = String("")
            self._reword_is_head = False

    def _handle_overlay_key(mut self, event: Event) -> Bool:
        """Route key events while an overlay is active. Returns True to
        keep events from leaking to the underlying view."""
        var k = event.key
        if self.overlay == _OVERLAY_STATUS:
            # Any key dismisses the status flash. Pressing ESC again
            # afterwards closes the modal (normal handler runs next
            # frame).
            self._close_overlay()
            return True
        if self.overlay == _OVERLAY_OUTPUT:
            # A log is for reading, so arrows scroll it and only an
            # explicit ESC / Enter closes — "any key dismisses" would make
            # it impossible to page through.
            if k == KEY_ESC or k == KEY_ENTER:
                self._close_overlay()
                return True
            if k == KEY_UP:
                self._scroll_output_overlay(-1)
                return True
            if k == KEY_DOWN:
                self._scroll_output_overlay(1)
                return True
            if k == KEY_PAGEUP:
                self._scroll_output_overlay(-_OUTPUT_PAGE)
                return True
            if k == KEY_PAGEDOWN:
                self._scroll_output_overlay(_OUTPUT_PAGE)
                return True
            if k == KEY_HOME:
                self.overlay_output_scroll = 0
                return True
            if k == KEY_END:
                self.overlay_output_scroll = 1 << 30
                return True
            return True
        if k == KEY_ESC:
            self._close_overlay()
            return True
        if self.overlay == _OVERLAY_EDIT_MSG:
            # Cmd/Ctrl+Enter saves; plain Enter is a newline (the text
            # area handles it and deliberately leaves the chord alone).
            #
            # Both modifiers are accepted so one binding covers the native
            # host (⌘) and the terminal (Ctrl). The terminal only sees the
            # modifier on Enter when its emulator honours the
            # modifyOtherKeys=2 / kitty request ``Terminal.start`` sends —
            # true for xterm, kitty, iTerm2, WezTerm, Alacritty, but *not*
            # macOS Terminal.app, which delivers Ctrl+Enter as a bare CR.
            # That's why Save is also a real button: clicking it is the
            # keyboard-independent path, and it carries the chord on its
            # face so the shortcut is discoverable where it does work.
            if k == KEY_ENTER and (event.mods & (MOD_CTRL | MOD_META)) != 0:
                self._submit_reword()
                return True
            var ra = self.overlay_area.handle_key(event)
            if ra.consumed:
                return True
            # Swallow anything else so a stray key can't reach the list
            # underneath while a modal editor is open.
            return True
        if self.overlay == _OVERLAY_COMMIT:
            if k == KEY_ENTER:
                self._submit_commit()
                return True
            var r = self.overlay_input.handle_key(event)
            if r.consumed:
                return True
            return True
        if self.overlay == _OVERLAY_MERGE_CHOICE:
            # Its own answer keys, and deliberately no default on Enter:
            # the two outcomes are different enough that guessing which one
            # a stray Return meant would be worse than doing nothing.
            if k == _KEY_M_LOWER or k == _KEY_M_UPPER:
                self._confirm_merge_commit()
            elif k == _KEY_R_LOWER or k == _KEY_R_UPPER:
                self._confirm_merge_rebase()
            return True
        # Confirmation overlays.
        if k == _KEY_Y_LOWER or k == _KEY_Y_UPPER:
            if self.overlay == _OVERLAY_AMEND_CONFIRM:
                self._confirm_amend()
            elif self.overlay == _OVERLAY_REVERT_CONFIRM:
                self._confirm_revert()
            elif self.overlay == _OVERLAY_DISCARD_LINE_CONFIRM:
                self._confirm_discard_line()
            elif self.overlay == _OVERLAY_DELETE_BRANCH_CONFIRM:
                self._confirm_delete_branch()
            return True
        if k == _KEY_N_LOWER or k == _KEY_N_UPPER:
            self._close_overlay()
            return True
        return True

    # --- mouse / drag helpers ---------------------------------------------

    def _hit_splitter(self, pos: Point, container_bounds: Rect) -> Int:
        """Return ``_DRAG_*`` for the splitter at ``pos``, or
        ``_DRAG_NONE`` if the position isn't on any splitter. The
        vertical sidebar/right splitter takes a 2-cell hit zone (the
        ``│`` column plus the last sidebar column, which is padding)
        so the drag is discoverable; widening the hit zone over the
        right side would steal clicks from diff body rows. Horizontal
        splitters are the ``─`` rows between sidebar/right sub-panels."""
        var top = self._list_top(container_bounds)
        var bottom = self._list_bottom(container_bounds)
        if pos.y < top or pos.y >= bottom:
            return _DRAG_NONE
        var sw = self._sidebar_width(container_bounds)
        var sep_x = container_bounds.a.x + sw
        # Vertical sidebar/right splitter.
        if pos.x >= sep_x - 1 and pos.x <= sep_x:
            return _DRAG_SIDEBAR
        var rows = self._pane_rows(container_bounds)
        var split1_y = rows[0] + rows[1]
        var split2_y = rows[2] + rows[3]
        # Sidebar horizontal splitters span [container_bounds.a.x, sep_x - 1]. Only
        # draggable when all three sidebar panels are in NORMAL state —
        # min/max collapse the layout to state-driven sizing where
        # ``files_height_user`` / ``branches_height_user`` aren't read.
        if self.sidebar_dock.all_normal() \
                and pos.x >= container_bounds.a.x and pos.x < sep_x:
            if pos.y == split1_y:
                return _DRAG_SPLIT_FB
            if pos.y == split2_y:
                return _DRAG_SPLIT_BC
        # Right-side horizontal splitter (file mode only).
        if self._driving_pane() == _PANE_FILES \
                and pos.x > sep_x and pos.x <= container_bounds.b.x - 1:
            var rp = self._right_panes(container_bounds)
            var split3_y = rp[0] + rp[1]
            if pos.y == split3_y:
                return _DRAG_SPLIT_US
        return _DRAG_NONE

    def _apply_drag(mut self, pos: Point, container_bounds: Rect):
        """Continue a drag: update the relevant override based on
        ``pos.y`` (or ``pos.x`` for the vertical splitter). The
        geometry helpers clamp on read, so we just store the raw value."""
        var top = self._list_top(container_bounds)
        var bottom = self._list_bottom(container_bounds)
        if self._drag_kind == _DRAG_SIDEBAR:
            # Only natural bounds: the splitter must stay one cell
            # inside the box on either side so the borders survive.
            # The user can drag the sidebar all the way down to 1 or
            # all the way up to ``container_bounds.width() - 2``.
            var w = pos.x - container_bounds.a.x
            if w < 1: w = 1
            var max_w = container_bounds.width() - 2
            if max_w < 1: max_w = 1
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
            var rows = self._pane_rows(container_bounds)
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

    def _pane_at(self, pos: Point, container_bounds: Rect) -> Int:
        """Return which sidebar pane (or -1 for "right pane / outside /
        on a splitter row") the cursor position falls in."""
        var sw = self._sidebar_width(container_bounds)
        var sidebar_right = container_bounds.a.x + sw
        if pos.x >= sidebar_right or pos.x < container_bounds.a.x:
            return -1
        var rows = self._pane_rows(container_bounds)
        if pos.y >= rows[0] and pos.y < rows[0] + rows[1]:
            return _PANE_FILES
        if pos.y >= rows[2] and pos.y < rows[2] + rows[3]:
            return _PANE_BRANCHES
        if pos.y >= rows[4] and pos.y < rows[4] + rows[5]:
            return _PANE_COMMITS
        return -1

    def _right_pane_at(self, pos: Point, container_bounds: Rect) -> Int:
        """Return _PANE_RIGHT_UNSTAGED / _PANE_RIGHT_STAGED /
        _PANE_RIGHT_INFO based on which sub-panel ``pos`` falls in. -1
        when ``pos`` is outside the right side or on the splitter row."""
        var sw = self._sidebar_width(container_bounds)
        var sep_x = container_bounds.a.x + sw
        if pos.x <= sep_x or pos.x > container_bounds.b.x - 1:
            return -1
        var top = self._list_top(container_bounds)
        var bottom = self._list_bottom(container_bounds)
        if pos.y < top or pos.y >= bottom:
            return -1
        if self._driving_pane() != _PANE_FILES:
            return _PANE_RIGHT_INFO
        var rp = self._right_panes(container_bounds)
        if pos.y >= rp[0] and pos.y < rp[0] + rp[1]:
            return _PANE_RIGHT_UNSTAGED
        if pos.y >= rp[2] and pos.y < rp[2] + rp[3]:
            return _PANE_RIGHT_STAGED
        return -1

    def _info_link_at(self, pos: Point, row: Int, container_bounds: Rect) -> String:
        """URL of the link under ``pos`` in the info panel's row ``row``,
        or empty when the click missed every link.

        Links only ever land on info rows (``_emit_info``), which carry no
        gutter — selected or not, their text starts at the panel's left
        edge, which is where ``_paint_right_side`` puts the info panel."""
        if row < 0 or row >= len(self.info.lines):
            return String("")
        var body_x = self._diff_left(container_bounds)
        var cell = pos.x - body_x \
            + _cells_skipped(self.info.lines[row], self.info.scroll_x)
        return self.info.link_at(row, cell)

    def consume_open_url(mut self) -> String:
        """Take the URL queued by a click on a commit-message link (empty
        when there is none). The desktop calls this after dispatching an
        event and passes any result to ``open_url``."""
        var u = self.pending_open_url
        self.pending_open_url = String("")
        return u^

    def _try_submit_jump(
        mut self, var path: String, line: Int,
    ) -> Bool:
        """Set the submission contract for ``selected_path`` /
        ``selected_line`` and flag ``submitted``. Caller has already
        decided this should fire (e.g. a double-click landed on a
        body row with a valid file mapping)."""
        if len(path.as_bytes()) == 0 or line <= 0:
            return False
        self.selected_path = path^
        self.selected_line = line
        self.submitted = True
        return True

    def _submit_selected_file(mut self):
        """Open the currently-selected Files-pane row, landing on its
        first change rather than the top of the file. Shared by the
        Enter key and the double-click handler. Prefers the worktree
        diff, falling back to the staged diff when a file is only
        staged."""
        if not (0 <= self.sel_file and self.sel_file < len(self.files)):
            return
        self.selected_path = self.files[self.sel_file].path
        var diff = self.files[self.sel_file].unstaged_diff
        if len(diff.as_bytes()) == 0:
            diff = self.files[self.sel_file].staged_diff
        self.selected_line = _first_change_line(diff)
        self.submitted = True

    def handle_mouse(
        mut self, event: Event, container_bounds: Rect,
        mut registry: GrammarRegistry,
    ) -> Bool:
        if not self.active or event.kind != EVENT_MOUSE:
            return False
        # Modal overlay — swallow all mouse so clicks don't sneak under.
        # The message editor is the one overlay with clickable parts (the
        # Save button, and click-to-position in the text area), so it gets
        # a look first; everything it doesn't claim is still swallowed.
        if self.overlay == _OVERLAY_EDIT_MSG:
            self._handle_edit_msg_mouse(event, container_bounds)
            return True
        if self.overlay != _OVERLAY_NONE:
            return True
        var pos = event.pos
        var bounds = self._panel_rect(container_bounds)
        # --- in-progress splitter drag -----------------------------------
        # Resolved before any other handling so a click that *starts* on
        # a splitter never also triggers list-row behaviour even if the
        # cursor crosses into a panel mid-drag.
        if self._drag_kind != _DRAG_NONE:
            if event.button == MOUSE_BUTTON_LEFT and event.pressed \
                    and event.motion:
                self._apply_drag(pos, bounds)
                return True
            if not event.pressed:
                self._drag_kind = _DRAG_NONE
                return True
            return True
        # Sidebar panel min/max chrome buttons. Take priority over
        # splitter drag-start so a header click never accidentally
        # initiates a sidebar resize.
        if event.button == MOUSE_BUTTON_LEFT and event.pressed \
                and not event.motion:
            var dock_hit = self.sidebar_dock.hit_chrome(pos)
            if dock_hit.hit():
                if dock_hit.is_max:
                    self.sidebar_dock.toggle_max(dock_hit.section_idx)
                else:
                    self.sidebar_dock.toggle_min(dock_hit.section_idx)
                return True
        var sw = self._sidebar_width(bounds)
        var sidebar_right = bounds.a.x + sw
        # Wheel: forward to whichever pane the cursor sits over.
        if event.button == MOUSE_WHEEL_UP \
                or event.button == MOUSE_WHEEL_DOWN:
            var dy = -1 if event.button == MOUSE_WHEEL_UP else 1
            if pos.x > sidebar_right:
                # Right side — scroll the sub-panel under the cursor.
                var rpane = self._right_pane_at(pos, bounds)
                if rpane < 0:
                    return True
                if self.focus != rpane:
                    if not self._is_right_focus():
                        self.last_sidebar_focus = self.focus
                    self.focus = rpane
                self._scroll_focused_right(3 * dy, bounds)
                return True
            var pane = self._pane_at(pos, bounds)
            if pane < 0:
                return True
            self.focus = pane
            self.last_sidebar_focus = pane
            self._set_focused_selection(
                self._focused_selection() + dy, bounds,
            )
            return True
        # --- left-button press: drag-start, focus or selection ----------
        if event.button == MOUSE_BUTTON_LEFT and event.pressed \
                and not event.motion:
            # Splitter hit?
            var splitter = self._hit_splitter(pos, bounds)
            if splitter != _DRAG_NONE:
                self._drag_kind = splitter
                return True
            # Right-side click: focus the sub-panel and jump line cursor.
            if pos.x > sidebar_right:
                var rpane = self._right_pane_at(pos, bounds)
                if rpane < 0:
                    return True
                if not self._is_right_focus():
                    self.last_sidebar_focus = self.focus
                self.focus = rpane
                self._ensure_right_panels(registry)
                # Determine which panel + its top to jump cursor.
                if rpane == _PANE_RIGHT_INFO:
                    var top = self._list_top(bounds)
                    # Header is one row; clicking on header is a no-op.
                    if pos.y == top:
                        return True
                    var li = self.info.scroll + (pos.y - top - 1)
                    if 0 <= li and li < len(self.info.lines):
                        # A URL in the commit message / branch log opens in
                        # the browser instead of moving the line cursor.
                        # Guarded to the first press of a click so a
                        # double-click can't launch two browser tabs.
                        if Int(event.click_count) < 2:
                            var url = self._info_link_at(pos, li, bounds)
                            if len(url.as_bytes()) > 0:
                                self.pending_open_url = url^
                                return True
                        self.info.cursor = li
                        if Int(event.click_count) >= 2 \
                                and li < len(self.info.file_line) \
                                and li < len(self.info.file_path):
                            var path = self.info.file_path[li].copy()
                            var line = self.info.file_line[li]
                            if self._try_submit_jump(path^, line):
                                return True
                    return True
                var rp = self._right_panes(bounds)
                if rpane == _PANE_RIGHT_UNSTAGED:
                    if pos.y == rp[0]:
                        return True
                    var li = self.unstaged.scroll + (pos.y - rp[0] - 1)
                    if 0 <= li and li < len(self.unstaged.lines):
                        self.unstaged.cursor = li
                        if Int(event.click_count) >= 2 \
                                and li < len(self.unstaged.file_line) \
                                and li < len(self.unstaged.file_path):
                            var path = self.unstaged.file_path[li].copy()
                            var line = self.unstaged.file_line[li]
                            if self._try_submit_jump(path^, line):
                                return True
                    return True
                # Staged.
                if pos.y == rp[2]:
                    return True
                var li = self.staged.scroll + (pos.y - rp[2] - 1)
                if 0 <= li and li < len(self.staged.lines):
                    self.staged.cursor = li
                    if Int(event.click_count) >= 2 \
                            and li < len(self.staged.file_line) \
                            and li < len(self.staged.file_path):
                        var path = self.staged.file_path[li].copy()
                        var line = self.staged.file_line[li]
                        if self._try_submit_jump(path^, line):
                            return True
                return True
            # Sidebar click.
            var pane = self._pane_at(pos, bounds)
            if pane < 0:
                return True
            var rows = self._pane_rows(bounds)
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
            self._set_focused_selection(scroll + body_offset, bounds)
            if pane == _PANE_FILES \
                    and Int(event.click_count) >= 2 \
                    and 0 <= self.sel_file \
                    and self.sel_file < len(self.files):
                self._submit_selected_file()
            return True
        return False
