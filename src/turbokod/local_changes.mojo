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

from .canvas import Canvas, utf8_byte_to_cell, utf8_codepoint_count
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
from .highlight import (
    GrammarRegistry, Highlight, HighlightCache,
    extension_of, highlight_for_extension_cached,
)
from .painter import Painter
from .file_io import join_path, read_file
from .window import (
    DockChromeHit, DockedPanelStack,
    paint_drop_shadow, paint_window_title,
)
from .git_changes import (
    ChangedFile, GitBranch, GitCommit, GitFileStatus, GitOpResult,
    apply_patch_to_index,
    compute_staged_diff, compute_unstaged_diff,
    fetch_blob_text, fetch_branch_log, fetch_commit_show,
    fetch_git_branches, fetch_git_commits, fetch_git_status,
    parse_unified_diff_files,
    git_amend_no_edit, git_commit, git_pull, git_push, git_revert_file,
    stage_file, unstage_file,
)
from .string_utils import split_lines_no_trailing, starts_with
from .text_field import TextField


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
    line."""
    var lines: List[String]
    var diff_line: List[Int]
    var kind: List[Int]
    var file_path: List[String]
    var file_line: List[Int]
    var highlights: List[Highlight]
    var scroll: Int
    var scroll_x: Int
    var cursor: Int

    fn __init__(out self):
        self.lines = List[String]()
        self.diff_line = List[Int]()
        self.kind = List[Int]()
        self.file_path = List[String]()
        self.file_line = List[Int]()
        self.highlights = List[Highlight]()
        self.scroll = 0
        self.scroll_x = 0
        self.cursor = 0

    fn reset(mut self):
        self.lines = List[String]()
        self.diff_line = List[Int]()
        self.kind = List[Int]()
        self.file_path = List[String]()
        self.file_line = List[Int]()
        self.highlights = List[Highlight]()
        self.scroll = 0
        self.scroll_x = 0
        self.cursor = 0


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


fn _strip_first_byte_to_string(s: String) -> String:
    """Drop the leading byte of ``s`` (the ``+`` / ``-`` / `` `` diff
    prefix). Returns an empty ``String`` when ``s`` is shorter than one
    byte. The diff prefix is always ASCII so byte-strip is codepoint-
    safe."""
    var b = s.as_bytes()
    if len(b) <= 1:
        return String("")
    return String(StringSlice(unsafe_from_utf8=b[1:]))


fn _build_filename_banner(path: String, width: Int) -> String:
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
    return prefix + String(StringSlice(unsafe_from_utf8=Span(dashes)))


fn _is_skip_diff_header(line: String) -> Bool:
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


fn _emit_filename_banner(
    mut panel: RightPanel, path: String, width: Int,
):
    panel.lines.append(_build_filename_banner(path, width))
    panel.kind.append(_LINE_FILEHDR)
    panel.diff_line.append(-1)
    panel.file_path.append(String(""))
    panel.file_line.append(0)


fn _emit_blank(mut panel: RightPanel):
    panel.lines.append(String(""))
    panel.kind.append(_LINE_BLANK)
    panel.diff_line.append(-1)
    panel.file_path.append(String(""))
    panel.file_line.append(0)


fn _emit_info(mut panel: RightPanel, var text: String):
    panel.lines.append(text^)
    panel.kind.append(_LINE_INFO)
    panel.diff_line.append(-1)
    panel.file_path.append(String(""))
    panel.file_line.append(0)


fn _emit_body_row(
    mut panel: RightPanel,
    var text: String, kind: Int, diff_idx: Int,
    path: String, line: Int,
):
    panel.lines.append(text^)
    panel.kind.append(kind)
    panel.diff_line.append(diff_idx)
    panel.file_path.append(path)
    panel.file_line.append(line)


fn _parse_hunk_starts(line: String, mut old_start: Int, mut new_start: Int):
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


fn _emit_panel_highlights(
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


fn _populate_diff_panel(
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
    _emit_filename_banner(panel, file_path, banner_width)
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
    for i in range(len(src_lines)):
        var ln = src_lines[i]
        var b = ln.as_bytes()
        # ``@@ -a,b +c,d @@`` resets both line counters.
        if len(b) >= 2 and Int(b[0]) == 0x40 and Int(b[1]) == 0x40:
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
    var overlay_input: TextField
    var overlay_message: String
    var overlay_ok: Bool
    # The three sidebar panels (Modified files / Branches / Commits)
    # share the framework ``DockedPanelStack`` for min/max state, layout
    # and chrome dispatch. Section indices match the ``_PANE_FILES`` /
    # ``_PANE_BRANCHES`` / ``_PANE_COMMITS`` ordering — same identifiers
    # used elsewhere for focus tracking.
    var sidebar_dock: DockedPanelStack

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
        self.overlay_input = TextField()
        self.overlay_message = String("")
        self.overlay_ok = False
        self.sidebar_dock = DockedPanelStack()
        # Order must match ``_PANE_FILES`` / ``_PANE_BRANCHES`` /
        # ``_PANE_COMMITS`` (0/1/2).
        _ = self.sidebar_dock.add(String("Modified files"))
        _ = self.sidebar_dock.add(String("Branches"))
        _ = self.sidebar_dock.add(String("Commits"))

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
        self.overlay_input = TextField()
        self.overlay_message = String("")
        self.overlay_ok = False
        self.sidebar_dock.reset()
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
        self.overlay_input = TextField()
        self.overlay_message = String("")
        self.overlay_ok = False
        self.sidebar_dock.reset()

    # --- geometry ---------------------------------------------------------

    fn _panel_rect(self, screen: Rect) -> Rect:
        """The modal always paints fullscreen — it intercepts every
        input event, so a non-fullscreen "windowed" mode wouldn't gain
        anything visible behind it that the user could interact with."""
        return screen

    fn _sidebar_width(self, screen: Rect) -> Int:
        """Sidebar width in cells. The auto-default (no user drag yet)
        targets ~⅓ of the window with the ``_SIDEBAR_MIN``/``MAX``
        comfort range. Once the user drags, only natural bounds apply
        — the splitter must stay one cell inside the box on each side
        so the borders don't get clobbered, but otherwise the user can
        crush the sidebar (or the right side) all the way to 1 cell."""
        var hard_max = screen.width() - 2
        if hard_max < 1:
            hard_max = 1
        var w: Int
        if self.sidebar_width_user >= 0:
            w = self.sidebar_width_user
        else:
            w = screen.width() // 3
            if w < _SIDEBAR_MIN: w = _SIDEBAR_MIN
            if w > _SIDEBAR_MAX: w = _SIDEBAR_MAX
        if w < 1: w = 1
        if w > hard_max: w = hard_max
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

        Delegates to ``DockedPanelStack.layout`` when any section is in
        a non-NORMAL state (the state machine drives the heights). When
        all sections are NORMAL we honor ``files_height_user`` /
        ``branches_height_user`` so the user's splitter drags persist
        across frames."""
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

    fn _ensure_right_panels(
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
            var sha = self.commits[self.sel_commit].short_sha
            var show_text = fetch_commit_show(self.root, sha)
            self._populate_commit_info(show_text, registry)

    fn _populate_commit_info(
        mut self, show_text: String, mut registry: GrammarRegistry,
    ):
        """Render ``git show`` output into the info panel: commit
        metadata + message rendered as info rows, then each file's
        diff rendered through ``_populate_diff_panel`` so the same
        gutter + syntax-highlight treatment applies. The split point
        is the first ``diff --git`` line — everything before it is
        free-form metadata that is meant for humans, everything from
        it onward is a multi-file unified diff."""
        var lines = split_lines_no_trailing(show_text)
        var diff_start = -1
        for i in range(len(lines)):
            if starts_with(lines[i], String("diff --git ")):
                diff_start = i
                break
        var meta_end = diff_start if diff_start >= 0 else len(lines)
        for li in range(meta_end):
            _emit_info(self.info, lines[li])
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
        var diff_part = String(StringSlice(
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

    fn _build_files_right_panels(
        mut self, mut registry: GrammarRegistry,
    ):
        """Populate the unstaged + staged panels from the focused file's
        diffs. Untracked files (XY == ``"??"``) get a hint in the
        unstaged panel so the user knows to press Space on the file row
        to start tracking them.

        For syntax highlighting we hand ``_populate_diff_panel`` the
        full *after* text of each side: the worktree file for the
        unstaged side (read directly from disk — that *is* the after
        version) and the index blob for the staged side. Pulling the
        full file rather than just the diff body lets the tokenizer
        see scope context that ends or starts outside the visible
        hunks (block comments, triple-quoted strings, …)."""
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
        else:
            if Int(fe.staged) == 0x3F and Int(fe.worktree) == 0x3F:
                _emit_info(
                    self.unstaged,
                    String(" (untracked — press Space on the file to stage it)"),
                )
            else:
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

    fn paint(
        mut self, mut canvas: Canvas, screen: Rect,
        mut registry: GrammarRegistry,
    ):
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
        # The modal always covers the full screen — it intercepts every
        # input event, so a windowed mode wouldn't gain any interactive
        # surface area behind it.
        var bounds = self._panel_rect(screen)
        canvas.fill(bounds, String(" "), bg)
        canvas.draw_box(bounds, border, True)
        # Title row — framework helper enforces title bg = body bg.
        paint_window_title(
            canvas, bounds, String(" Local changes "), title_attr, bg,
        )
        # Sub-title: project root (or status banner).
        var sub_y = bounds.a.y + 1
        var sub: String
        if len(self.status_message.as_bytes()) > 0:
            sub = String(" ") + self.status_message
        else:
            sub = String(" ") + self.root
        _ = canvas.put_text(
            Point(bounds.a.x + 1, sub_y), sub, list_dim, bounds.b.x - 1,
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
        var hx = bounds.b.x - len(hint.as_bytes()) - 1
        if hx < bounds.a.x + 1:
            hx = bounds.a.x + 1
        _ = canvas.put_text(Point(hx, bounds.b.y - 1), hint, hint_attr)
        # Overlay last so it sits on top of everything else.
        if self.overlay != _OVERLAY_NONE:
            self._paint_overlay(canvas, bounds)

    fn _paint_overlay(mut self, mut canvas: Canvas, screen: Rect):
        """Render the active overlay (commit prompt / confirmation /
        status flash) as a small drop-shadowed box centered on the
        modal area. Every write is bound to the overlay's clip via a
        Painter so an over-long status message (or a wide commit
        title) can't bleed out onto the underlying modal."""
        var border = Attr(BLACK, LIGHT_GRAY)
        var body   = Attr(BLACK, LIGHT_GRAY)
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
        var painter = Painter(rect)
        painter.fill(canvas, rect, String(" "), body)
        painter.draw_box(canvas, rect, border, False)
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
            var input_x = bx + 2 + len(prompt_text.as_bytes())
            var input_rect = Rect(
                input_x, by + 2, bx + box_w - 1, by + 3,
            )
            self.overlay_input.paint(canvas, input_rect, True)
            var hint = String("Enter: commit   ESC: cancel")
            _ = body_p.put_text(
                canvas, Point(bx + 2, by + box_h - 2), hint, body,
            )
            return
        if self.overlay == _OVERLAY_STATUS:
            var attr = ok_attr if self.overlay_ok else err_attr
            body_p.fill(
                canvas, Rect(bx + 1, by + 2, bx + box_w - 1, by + 3),
                String(" "), attr,
            )
            _ = body_p.put_text(
                canvas, Point(bx + 2, by + 2), self.overlay_message, attr,
            )
            var hint = String("Press any key to dismiss")
            _ = body_p.put_text(
                canvas, Point(bx + 2, by + box_h - 2), hint, body,
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

    fn _paint_horizontal_splitter(
        self, mut canvas: Canvas, left: Int, right: Int, y: Int,
        attr: Attr,
    ):
        if right < left:
            return
        for x in range(left, right + 1):
            canvas.set(x, y, Cell(String("─"), attr, 1))

    fn _paint_section_body(
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
        # ``_diff_right`` historically returned the border column itself
        # (``screen.b.x - 1``). The panels and splitters then used ``+1``
        # tricks that ended up writing one cell *past* the content area
        # — straight onto the modal's right border. Treat ``right_excl``
        # as the panel's exclusive right edge instead, anchored one cell
        # short of the border so the Painter clip naturally protects the
        # frame.
        var right_excl = self._diff_right(screen)
        if right_excl <= left:
            return
        var driving = self._driving_pane()
        if driving == _PANE_FILES:
            var rp = self._right_panes(screen)
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
        # Base text colour for diff body rows. ``LIGHT_GREEN`` matches
        # the editor's untokenised baseline (``editor.mojo`` paint), so
        # the syntax-highlight overlay ends up colouring exactly the
        # same scopes the editor would — keywords go ``WHITE``, strings
        # ``RED``, comments ``CYAN``, etc. — and idents/variables stay
        # ``LIGHT_GREEN`` which reads as the default text colour rather
        # than a highlight.
        var body_bg = Attr(LIGHT_GREEN, BLUE)
        # Add/remove gutter cells. Saturated bg + black fg gives a
        # solid coloured block on the left edge that reads as a status
        # band even at a glance — easier to spot than a fg-only glyph
        # against the panel's blue background.
        var add_gutter_attr = Attr(BLACK, LIGHT_GREEN)
        var rem_gutter_attr = Attr(BLACK, LIGHT_RED)
        # Explicit body fill — the outer ``LocalChanges.paint`` sets
        # every screen cell to ``YELLOW`` on ``BLUE``, but per-cell
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
            # Cursor row: paint the whole row in cursor_active and write
            # the line content on top — overrides the per-kind colouring
            # below. Skip the syntax overlay for this row so the YELLOW
            # background isn't recoloured back to BLUE.
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
                var gutter_glyph: String
                if k == _LINE_ADD:
                    gutter_glyph = String("+")
                elif k == _LINE_REM:
                    gutter_glyph = String("-")
                else:
                    gutter_glyph = String(" ")
                _ = painter.put_text(
                    canvas, Point(area.a.x, y), gutter_glyph, cursor_active,
                )
                var bytes_c = line.as_bytes()
                if panel.scroll_x < len(bytes_c):
                    var visible_c = String(StringSlice(
                        unsafe_from_utf8=bytes_c[
                            panel.scroll_x:len(bytes_c)
                        ],
                    ))
                    _ = painter.put_text(
                        canvas, Point(area.a.x + 2, y),
                        visible_c, cursor_active,
                    )
                continue
            # Non-cursor row: pick the base colour by line kind.
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
            # Gutter is two cells: the +/-/space marker, then a blank
            # spacer so the code body doesn't crowd against the marker.
            if has_gutter:
                _ = painter.put_text(
                    canvas, Point(area.a.x, y), gutter_glyph, gutter_attr,
                )
            var body_x = area.a.x + 2 if has_gutter else area.a.x
            var bytes = line.as_bytes()
            var start = panel.scroll_x
            if start < len(bytes):
                var visible = String(StringSlice(
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
            if has_gutter:
                var byte_to_cell = utf8_byte_to_cell(line)
                var byte_count = len(bytes)
                var cell_count = utf8_codepoint_count(line)
                for h in range(len(panel.highlights)):
                    var hl = panel.highlights[h]
                    if hl.row != idx:
                        continue
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
        _ = cursor_inactive
        _ = hunk_attr   # retained for the legacy diff colour palette
        _ = rem_attr
        _ = add_attr

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

    fn _tab_forward(mut self):
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

    fn _tab_backward(mut self):
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

    fn _enter_right_pane(
        mut self, screen: Rect, mut registry: GrammarRegistry,
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

    fn handle_key(
        mut self, event: Event, screen: Rect,
        mut registry: GrammarRegistry,
    ) -> Bool:
        if not self.active or event.kind != EVENT_KEY:
            return False
        if self.overlay != _OVERLAY_NONE:
            return self._handle_overlay_key(event)
        var bounds = self._panel_rect(screen)
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
            self._enter_right_pane(bounds, registry)
            return True
        if k == KEY_LEFT:
            self._leave_right_pane()
            return True
        if k == KEY_SPACE:
            self._handle_space(bounds)
            return True
        if self._is_right_focus():
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
        self.overlay_input = TextField()
        self.overlay_message = String("")

    fn _open_amend_confirm(mut self):
        self.overlay = _OVERLAY_AMEND_CONFIRM
        self.overlay_input = TextField()
        self.overlay_message = \
            String("Amend HEAD with --no-edit? Folds staged changes into the last commit.")

    fn _open_revert_confirm(mut self):
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

    fn _show_status(mut self, var msg: String, ok: Bool):
        """Flash a one-shot status line. Dismissed by any keystroke."""
        self.overlay = _OVERLAY_STATUS
        self.overlay_message = msg^
        self.overlay_ok = ok
        self.overlay_input = TextField()

    fn _close_overlay(mut self):
        self.overlay = _OVERLAY_NONE
        self.overlay_input = TextField()
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
        var msg = self.overlay_input.text
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
            var r = self.overlay_input.handle_key(event)
            if r.consumed:
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
        """Return ``_DRAG_*`` for the splitter at ``pos``, or
        ``_DRAG_NONE`` if the position isn't on any splitter. The
        vertical sidebar/right splitter takes a 2-cell hit zone (the
        ``│`` column plus the last sidebar column, which is padding)
        so the drag is discoverable; widening the hit zone over the
        right side would steal clicks from diff body rows. Horizontal
        splitters are the ``─`` rows between sidebar/right sub-panels."""
        var top = self._list_top(screen)
        var bottom = self._list_bottom(screen)
        if pos.y < top or pos.y >= bottom:
            return _DRAG_NONE
        var sw = self._sidebar_width(screen)
        var sep_x = screen.a.x + sw
        # Vertical sidebar/right splitter.
        if pos.x >= sep_x - 1 and pos.x <= sep_x:
            return _DRAG_SIDEBAR
        var rows = self._pane_rows(screen)
        var split1_y = rows[0] + rows[1]
        var split2_y = rows[2] + rows[3]
        # Sidebar horizontal splitters span [screen.a.x, sep_x - 1]. Only
        # draggable when all three sidebar panels are in NORMAL state —
        # min/max collapse the layout to state-driven sizing where
        # ``files_height_user`` / ``branches_height_user`` aren't read.
        if self.sidebar_dock.all_normal() \
                and pos.x >= screen.a.x and pos.x < sep_x:
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
            # Only natural bounds: the splitter must stay one cell
            # inside the box on either side so the borders survive.
            # The user can drag the sidebar all the way down to 1 or
            # all the way up to ``screen.width() - 2``.
            var w = pos.x - screen.a.x
            if w < 1: w = 1
            var max_w = screen.width() - 2
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

    fn _try_submit_jump(
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

    fn handle_mouse(
        mut self, event: Event, screen: Rect,
        mut registry: GrammarRegistry,
    ) -> Bool:
        if not self.active or event.kind != EVENT_MOUSE:
            return False
        # Modal overlay — swallow all mouse so clicks don't sneak under.
        if self.overlay != _OVERLAY_NONE:
            return True
        var pos = event.pos
        var bounds = self._panel_rect(screen)
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
                self.selected_path = self.files[self.sel_file].path
                self.selected_line = 0
                self.submitted = True
            return True
        return False
