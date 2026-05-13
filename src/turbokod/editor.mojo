"""Code editor widget — text buffer, cursor, scrolling, and key handling.

Inspired by what magiblot/turbo gets from Scintilla, but written from scratch
in pure Mojo. No syntax highlighting yet (the per-cell render is all in one
attribute); the data model is simple `List[String]`, one entry per line.

Editing operations are O(line-length) for in-line insert/delete (Mojo strings
are immutable so each edit rebuilds the affected line) and O(line-count) for
inserting / removing a line. Fine for source files up to a few thousand lines.
"""

from std.collections.list import List

from .canvas import (
    Canvas, paint_drop_shadow, popup_size_for_text,
    utf8_byte_to_cell, utf8_codepoint_count,
)
from .painter import Painter
from .cell import Cell
from .clipboard import (
    CLIP_COPY, CLIP_CUT, CLIP_PASTE, CLIP_SELECT_ALL, clipboard_chord,
    clipboard_copy, clipboard_paste,
)
from .colors import (
    Attr, BLACK, BLUE, CYAN, DARK_GRAY, LIGHT_BLUE, LIGHT_GRAY, LIGHT_GREEN,
    LIGHT_RED, LIGHT_YELLOW, STYLE_UNDERLINE, STYLE_UNDERLINE_CURLY,
    WHITE, YELLOW,
)
from .diff import MergeResult, diff3_merge, unified_diff
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_BACKSPACE, KEY_DELETE, KEY_DOWN, KEY_END, KEY_ENTER, KEY_ESC, KEY_HOME,
    KEY_LEFT, KEY_PAGEDOWN, KEY_PAGEUP, KEY_RIGHT, KEY_SPACE, KEY_TAB, KEY_UP,
    MOD_ALT, MOD_CTRL, MOD_META, MOD_NONE, MOD_SHIFT,
    MOUSE_BUTTON_LEFT, MOUSE_BUTTON_NONE, MOUSE_BUTTON_RIGHT,
    MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .editorconfig import EditorConfig, load_editorconfig_for_path
from .file_io import FileInfo, read_file, stat_file, write_file
from .git_blame import BlameLine
from .git_changes import (
    GIT_CHANGE_ADDED, GIT_CHANGE_MODIFIED, GIT_CHANGE_NONE,
    GitRevertBlock, GitRevertRequest, compute_revert_block,
)
from .highlight import (
    CompletionRequest, DefinitionRequest, GrammarRegistry, Highlight,
    HighlightCache, extension_of, highlight_comment_attr,
    highlight_for_extension, highlight_incremental, highlight_string_attr,
    line_comment_for_extension, word_at,
)
from .lsp_dispatch import (
    CompletionItem, DIAG_SEVERITY_ERROR, DIAG_SEVERITY_HINT,
    DIAG_SEVERITY_INFO, DIAG_SEVERITY_WARNING, Diagnostic,
)
from .spell import (
    Speller, SpellActionRequest, find_misspelled_runs,
    has_spell_noinspection_directive,
)
from .terminal import terminal_supports_extended_underline
from std.collections.optional import Optional
from .geometry import Point, Rect
from .onig import OnigRegex
from .posix import append_string_bytes, monotonic_ms
from .search_options import (
    SearchOptions, build_search_regex, default_search_options,
)
from .string_utils import (
    codepoint_at, is_word_codepoint, leading_indent_bytes,
    prev_codepoint_start, utf8_codepoint_size, word_char_step,
)
from .text_view import (
    Selection, VisualLine, paint_selection_overlay, paint_text_segments,
    wrap_lines,
)


# --- Helpers ----------------------------------------------------------------


fn _slice(s: String, start: Int, end: Int) -> String:
    """Byte-range substring (ASCII-safe)."""
    var bytes = s.as_bytes()
    var s_start = start
    var s_end = end
    if s_start < 0: s_start = 0
    if s_end > len(bytes): s_end = len(bytes)
    if s_start >= s_end: return String("")
    return String(StringSlice(unsafe_from_utf8=bytes[s_start:s_end]))


fn _completion_kind_name(kind: Int) -> String:
    """Map an LSP ``CompletionItemKind`` integer to its human-readable
    name. Unknown kinds get an empty string so the column stays blank
    rather than rendering noise.
    """
    if kind == 1:   return String("text")
    if kind == 2:   return String("method")
    if kind == 3:   return String("function")
    if kind == 4:   return String("constructor")
    if kind == 5:   return String("field")
    if kind == 6:   return String("variable")
    if kind == 7:   return String("class")
    if kind == 8:   return String("interface")
    if kind == 9:   return String("module")
    if kind == 10:  return String("property")
    if kind == 11:  return String("unit")
    if kind == 12:  return String("value")
    if kind == 13:  return String("enum")
    if kind == 14:  return String("keyword")
    if kind == 15:  return String("snippet")
    if kind == 16:  return String("color")
    if kind == 17:  return String("file")
    if kind == 18:  return String("reference")
    if kind == 19:  return String("folder")
    if kind == 20:  return String("enum member")
    if kind == 21:  return String("constant")
    if kind == 22:  return String("struct")
    if kind == 23:  return String("event")
    if kind == 24:  return String("operator")
    if kind == 25:  return String("type parameter")
    return String("")


fn _is_completion_autotrigger_byte(k: UInt32) -> Bool:
    """True iff typing the ASCII byte ``k`` should kick off an
    as-you-type completion request.

    Word codepoints (letters, digits, underscore) extend the current
    identifier; ``.`` is the canonical member-access trigger across
    every language server we ship. We deliberately don't include
    ``(``, ``,``, ``=`` etc. — those tend to fire signature-help /
    auto-import suggestions that are noisy when invoked on every
    keystroke.
    """
    if UInt32(0x30) <= k and k <= UInt32(0x39):  # 0-9
        return True
    if UInt32(0x41) <= k and k <= UInt32(0x5A):  # A-Z
        return True
    if UInt32(0x61) <= k and k <= UInt32(0x7A):  # a-z
        return True
    if k == UInt32(0x5F):  # underscore
        return True
    if k == UInt32(0x2E):  # .
        return True
    return False


fn _completion_overlap_start(
    line: String, cursor_col: Int, insert_text: String,
) -> Int:
    """Longest column on ``line`` such that ``line[col, cursor_col)``
    is a byte-exact prefix of ``insert_text`` — i.e. how much of what
    the user already typed gets eaten by accepting the completion.

    Fallback anchor for when the server didn't supply a ``textEdit``
    range. Handles the common path-style case: typing ``reviews/re``
    while ``reviews/reviews__tags.html`` is offered — the word-boundary
    anchor stops after the ``/`` and would yield
    ``reviews/reviews/reviews__tags.html``, but the overlap span here
    is the entire typed ``reviews/re`` (it's a prefix of the insert
    text), so accepting replaces all 10 bytes instead.

    Returns ``cursor_col`` (no widening) when nothing matches.
    """
    var lb = line.as_bytes()
    var ib = insert_text.as_bytes()
    var max_overlap = cursor_col
    if max_overlap > len(ib):
        max_overlap = len(ib)
    if cursor_col > len(lb):
        max_overlap = 0
    for try_len in range(max_overlap, 0, -1):
        var ok = True
        for k in range(try_len):
            if lb[cursor_col - try_len + k] != ib[k]:
                ok = False
                break
        if ok:
            return cursor_col - try_len
    return cursor_col


fn _rtrim(s: String) -> String:
    """Drop trailing ASCII spaces and tabs. Used by ``_disk_text`` to honor
    the editorconfig ``trim_trailing_whitespace`` property."""
    var bytes = s.as_bytes()
    var n = len(bytes)
    while n > 0 and (bytes[n - 1] == 0x20 or bytes[n - 1] == 0x09):
        n -= 1
    if n == len(bytes):
        return s
    return _slice(s, 0, n)


fn _diag_intersects_row(diag: Diagnostic, row: Int) -> Bool:
    """True iff ``diag`` covers any byte on ``row``. LSP ranges can
    span multiple rows (e.g. an unclosed bracket marked from open to
    EOF), so the renderer needs to project per row."""
    return diag.start_row <= row and row <= diag.end_row


fn _diag_byte_start_for_row(diag: Diagnostic, row: Int) -> Int:
    """Buffer-byte start column for ``diag`` *on row ``row``*. For the
    first row of a multi-row diagnostic this is ``diag.start_col``; for
    a continuation row the diagnostic starts at column 0 of that row."""
    if row == diag.start_row:
        return diag.start_col
    return 0


fn _diag_byte_end_for_row(diag: Diagnostic, row: Int, line_len: Int) -> Int:
    """Buffer-byte end column for ``diag`` *on row ``row``*. For rows
    strictly between start and end, the diagnostic occupies the whole
    line; ``end_col`` only applies on ``end_row``. ``line_len`` is the
    underlying byte length of the line so a multi-row range can clip to
    the actual line end on continuation rows. We also force a one-cell
    minimum span on a single-row range with start==end so empty
    diagnostics (e.g. "missing semicolon at end-of-line") still paint
    a visible squiggle on at least one column."""
    if row < diag.end_row:
        var n = line_len
        if n < 1:
            n = 1
        return n
    # row == diag.end_row
    var hi = diag.end_col
    if row == diag.start_row and hi <= diag.start_col:
        hi = diag.start_col + 1
    return hi


fn _diag_covers_cell(diag: Diagnostic, row: Int, byte_col: Int) -> Bool:
    """True iff ``(row, byte_col)`` falls inside ``diag``'s range.

    Continuation rows (rows strictly between start and end) are treated
    as fully covered — that mirrors how the underline pass paints them.
    Zero-width single-row diagnostics ("missing semicolon at end of
    line") cover the one cell at ``start_col`` so the user can still
    hover them."""
    if not _diag_intersects_row(diag, row):
        return False
    if row > diag.start_row and row < diag.end_row:
        return byte_col >= 0
    var lo = _diag_byte_start_for_row(diag, row)
    if byte_col < lo:
        return False
    if row < diag.end_row:
        # On the start row of a multi-row range — diagnostic continues
        # to end of line, so any byte at or past ``lo`` qualifies.
        return True
    # row == diag.end_row.
    var hi = diag.end_col
    if row == diag.start_row and hi <= diag.start_col:
        hi = diag.start_col + 1
    return byte_col < hi


fn _diag_severity_to_minimap_kind(severity: Int) -> Int:
    """Map LSP severity → the minimap-hover ``kind`` discriminant the
    tooltip-paint pass already understands. Errors=3, warnings=4,
    info=5, hints=6; unknown severities fall through to info so the
    tooltip still surfaces. Matches ``_minimap_kind_in_slice``'s
    numbering exactly so the rendering branches don't need to know
    where the hit came from."""
    if severity == DIAG_SEVERITY_ERROR:
        return 3
    if severity == DIAG_SEVERITY_WARNING:
        return 4
    if severity == DIAG_SEVERITY_HINT:
        return 6
    return 5


fn _diag_underline_color(severity: Int) -> UInt8:
    """Map LSP severity → squiggle color. Errors = LIGHT_RED, warnings
    = LIGHT_YELLOW, info = LIGHT_BLUE, hints = DARK_GRAY (subtle so
    they don't compete with real problems). Unknown severities default
    to LIGHT_BLUE — the spec says clients can ignore unknowns, but
    "color them as info" is friendlier than dropping them."""
    if severity == DIAG_SEVERITY_ERROR:
        return LIGHT_RED
    if severity == DIAG_SEVERITY_WARNING:
        return LIGHT_YELLOW
    if severity == DIAG_SEVERITY_HINT:
        return DARK_GRAY
    return LIGHT_BLUE


fn _lists_equal(a: List[String], b: List[String]) -> Bool:
    """Element-wise equality for two ``List[String]``. Used after a
    3-way merge to decide whether the merged buffer matches the
    just-read on-disk content (clean = leaves the buffer non-dirty)."""
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


fn _split_buffer_lines(text: String) -> List[String]:
    """Split disk bytes into the buffer's line-list shape.

    Mirrors ``TextBuffer.__init__`` exactly (split on ``\\n``; a trailing
    ``\\n`` produces a trailing empty line). Used by the 3-way merge so
    the merge base, the buffer, and the new on-disk content line up
    cell-for-cell — any difference in how we tokenize lines would make
    the merge spuriously flag whole files as conflicts.
    """
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


# --- UTF-8 boundary helpers -------------------------------------------------
#
# The buffer's column model is byte-indexed (insert/delete need byte access),
# but the cursor must always land on a codepoint boundary so a multi-byte
# character behaves as one indivisible step. These helpers keep that invariant
# and translate between byte offsets and cell columns when vertical movement
# or a mouse click crosses lines whose byte and cell widths disagree.
# ``utf8_codepoint_size`` lives in ``string_utils`` so soft-wrap and cursor
# stepping share one source of truth for UTF-8 lead-byte decoding.


fn _utf8_step_forward(line: String, col: Int) -> Int:
    """Byte offset of the codepoint boundary one step forward from ``col``."""
    var bytes = line.as_bytes()
    var n = len(bytes)
    if col >= n:
        return n
    var step = utf8_codepoint_size(Int(bytes[col]))
    var nxt = col + step
    if nxt > n:
        nxt = n
    return nxt


fn _utf8_step_backward(line: String, col: Int) -> Int:
    """Byte offset of the codepoint boundary one step backward from ``col``.
    Walks back over UTF-8 continuation bytes (10xxxxxx)."""
    if col <= 0:
        return 0
    var bytes = line.as_bytes()
    var c = col - 1
    while c > 0 and (Int(bytes[c]) & 0xC0) == 0x80:
        c -= 1
    return c


fn _utf8_cell_of_byte(line: String, byte_col: Int) -> Int:
    """Cell column for byte offset ``byte_col`` in ``line``. Past-EOL bytes
    consume one virtual cell each so cursors parked to the right of the last
    character stay distinguishable in vertical-movement bookkeeping."""
    if byte_col <= 0:
        return 0
    var bytes = line.as_bytes()
    var n = len(bytes)
    var cell = 0
    var i = 0
    while i < n and i < byte_col:
        i += utf8_codepoint_size(Int(bytes[i]))
        cell += 1
    if byte_col > n:
        cell += byte_col - n
    return cell


fn _utf8_byte_of_cell(line: String, cell_col: Int) -> Int:
    """Byte offset of the codepoint at cell column ``cell_col`` in ``line``,
    clamped to ``len(line)``. Used to translate a remembered cell column from
    one row to another during vertical movement."""
    if cell_col <= 0:
        return 0
    var bytes = line.as_bytes()
    var n = len(bytes)
    var cell = 0
    var i = 0
    while i < n and cell < cell_col:
        i += utf8_codepoint_size(Int(bytes[i]))
        cell += 1
    return i


# --- TextBuffer -------------------------------------------------------------


struct TextBuffer(ImplicitlyCopyable, Movable):
    """Line-oriented buffer. Always has at least one (possibly empty) line."""
    var lines: List[String]

    fn __init__(out self):
        self.lines = List[String]()
        self.lines.append(String(""))

    fn __init__(out self, var text: String):
        self.lines = List[String]()
        var bytes = text.as_bytes()
        var line_start = 0
        var i = 0
        while i < len(bytes):
            if bytes[i] == 0x0A:  # '\n'
                self.lines.append(_slice(text, line_start, i))
                line_start = i + 1
            i += 1
        self.lines.append(_slice(text, line_start, len(bytes)))

    fn __copyinit__(out self, copy: Self):
        self.lines = copy.lines.copy()

    fn line_count(self) -> Int:
        return len(self.lines)

    fn line(self, row: Int) -> String:
        if 0 <= row and row < len(self.lines):
            return self.lines[row]
        return String("")

    fn line_length(self, row: Int) -> Int:
        if 0 <= row and row < len(self.lines):
            return len(self.lines[row].as_bytes())
        return 0

    fn insert(mut self, row: Int, col: Int, text: String):
        if row < 0 or row >= len(self.lines):
            return
        var line = self.lines[row]
        var n = len(line.as_bytes())
        var pos = col
        if pos < 0: pos = 0
        if pos > n: pos = n
        self.lines[row] = _slice(line, 0, pos) + text + _slice(line, pos, n)

    fn delete_at(mut self, row: Int, col: Int):
        """Delete one codepoint at (row, col). If past EOL, joins next line."""
        if row < 0 or row >= len(self.lines):
            return
        var line = self.lines[row]
        var n = len(line.as_bytes())
        if col >= n:
            if row + 1 < len(self.lines):
                self.lines[row] = line + self.lines[row + 1]
                _ = self.lines.pop(row + 1)
            return
        var nxt = _utf8_step_forward(line, col)
        self.lines[row] = _slice(line, 0, col) + _slice(line, nxt, n)

    fn delete_before(mut self, row: Int, col: Int) -> Tuple[Int, Int]:
        """Backspace one codepoint. Returns the new cursor (row, col)."""
        if col > 0:
            var line = self.lines[row]
            var prev_col = _utf8_step_backward(line, col)
            self.lines[row] = _slice(line, 0, prev_col) + _slice(line, col, len(line.as_bytes()))
            return (row, prev_col)
        if row > 0:
            var prev = self.lines[row - 1]
            var prev_len = len(prev.as_bytes())
            self.lines[row - 1] = prev + self.lines[row]
            _ = self.lines.pop(row)
            return (row - 1, prev_len)
        return (row, col)

    fn split(mut self, row: Int, col: Int) -> Tuple[Int, Int]:
        """Split line at col (Enter key). Returns the new cursor (row+1, 0)."""
        if row < 0 or row >= len(self.lines):
            return (row, col)
        var line = self.lines[row]
        var n = len(line.as_bytes())
        var pos = col
        if pos < 0: pos = 0
        if pos > n: pos = n
        var head = _slice(line, 0, pos)
        var tail = _slice(line, pos, n)
        self.lines[row] = head
        # Append-and-shift rather than relying on List.insert which may not
        # exist on all Mojo versions.
        self.lines.append(String(""))
        var i = len(self.lines) - 1
        while i > row + 1:
            self.lines[i] = self.lines[i - 1]
            i -= 1
        self.lines[row + 1] = tail
        return (row + 1, 0)


# --- Undo / redo ------------------------------------------------------------


comptime _UNDO_STACK_LIMIT = 500
"""Cap per-window undo history. Each entry holds a full ``List[String]`` copy
of the buffer plus four ints, so a few hundred steps is comfortably more than
any realistic editing session needs."""


comptime _TYPING_DEBOUNCE_MS = 800
"""How long a typing run can pause before the next keystroke starts a new
undo step. 800 ms feels right in practice — fast enough that "type sentence,
think for a moment, type next sentence" produces two undo steps, slow enough
that a single sentence rarely splits."""


comptime _DOUBLE_CLICK_MS = 500
"""Maximum gap between two left-button presses (at the same cell) for the
second one to be treated as a double-click."""


comptime _COMPLETION_POPUP_ROWS = 8
"""How many completion entries fit in the popup before scrolling."""

comptime _COMPLETION_POPUP_WIDTH_MIN = 18
"""Minimum popup width; the actual width grows to fit the longest
visible label."""

comptime _COMPLETION_POPUP_WIDTH_MAX = 60
"""Maximum popup width; longer labels get truncated with an ellipsis."""


comptime _COMPLETION_DEBOUNCE_MS = 120
"""How long the as-you-type auto-trigger waits for typing to settle
before forwarding a completion request to the LSP server. Without
debounce, fast typing fires one request per keystroke and the popup
visibly lags behind — each response reflects a prefix two or three
chars older than what the user just typed. 120 ms is short enough that
a deliberate pause feels instant, long enough that a steady typist
produces a single request per word fragment. Manual (Ctrl+Space)
requests bypass this — the user is explicitly waiting on results."""


comptime _LSP_DIDCHANGE_DEBOUNCE_MS = 150
"""How long the per-frame didChange sync waits for typing to settle
before flushing the buffer to the LSP server. Without this every
keystroke ships a full-document didChange — slow servers (pyright,
ty/iommi-lsp on a Django settings module) re-type-check the whole
file on every keystroke and the squiggly underline visibly lags
behind the cursor, snapping forward through stale states as old
``publishDiagnostics`` arrive. 150 ms keeps the server quiet through
a typing burst and lets it run once on the settled text. User-driven
requests (completion / definition / symbols) pre-flight their own
``_send_open_or_change``, so this debounce only gates the background
diagnostics sync — there's no added latency on the request paths."""


# --- External-change status codes ------------------------------------------
#
# Returned by ``Editor.check_for_external_change`` so callers (Window /
# Desktop) can react: clean reloads and clean merges are silent;
# conflicts trigger a diff window.

comptime EXT_CHANGE_NONE = 0
"""No on-disk change detected (or the file vanished)."""

comptime EXT_CHANGE_RELOADED = 1
"""Buffer was clean; reloaded the new on-disk content verbatim."""

comptime EXT_CHANGE_MERGED = 2
"""Buffer was dirty; 3-way merge against the previous baseline applied
cleanly (no conflict regions)."""

comptime EXT_CHANGE_CONFLICT = 3
"""Buffer was dirty; merge produced conflicts. The buffer now contains
``<<<<<<< / ======= / >>>>>>>`` markers and the cursor sits on the
first ``<<<<<<<`` line. Caller should surface a diff view."""


@fieldwise_init
struct Caret(ImplicitlyCopyable, Movable):
    """One caret + its anchor + remembered cell column.

    The editor's primary caret lives in ``Editor.cursor_*``/``anchor_*`` /
    ``desired_col``; this struct mirrors the same five fields so any
    operation can be expressed as "set the primary to this caret, run
    the existing single-caret code, capture the result". Additional
    carets sit in ``Editor.extra_carets``; the empty-list case is the
    common one and reduces to the original single-caret model with no
    per-keystroke overhead.
    """
    var row: Int
    var col: Int
    var desired_col: Int
    var anchor_row: Int
    var anchor_col: Int


@fieldwise_init
struct BreakpointMenuRequest(ImplicitlyCopyable, Movable):
    """Set by ``handle_mouse`` when the user right-clicks a breakpoint
    dot in the gutter. ``row`` is the buffer row the BP sits on (so
    Desktop can look up its current condition + enabled state from the
    DAP manager); ``anchor_x``/``anchor_y`` are the clicked screen
    cell so the menu can open under the cursor."""
    var row: Int
    var anchor_x: Int
    var anchor_y: Int


struct EditorSnapshot(ImplicitlyCopyable, Movable):
    """One reversible step. Captures everything ``undo`` needs to restore:
    the buffer contents and the caret/selection. Scroll position is excluded
    on purpose — undoing shouldn't yank the viewport around if the user has
    scrolled since the edit."""
    var lines: List[String]
    var cursor_row: Int
    var cursor_col: Int
    var anchor_row: Int
    var anchor_col: Int
    # Multi-cursor: the extra carets present at the time of the snapshot.
    # Restoring a snapshot rebuilds the full caret set so undo / redo
    # round-trips multi-caret state.
    var extra_carets: List[Caret]

    fn __init__(
        out self,
        var lines: List[String],
        cursor_row: Int,
        cursor_col: Int,
        anchor_row: Int,
        anchor_col: Int,
        var extra_carets: List[Caret],
    ):
        self.lines = lines^
        self.cursor_row = cursor_row
        self.cursor_col = cursor_col
        self.anchor_row = anchor_row
        self.anchor_col = anchor_col
        self.extra_carets = extra_carets^

    fn __copyinit__(out self, copy: Self):
        self.lines = copy.lines.copy()
        self.cursor_row = copy.cursor_row
        self.cursor_col = copy.cursor_col
        self.anchor_row = copy.anchor_row
        self.anchor_col = copy.anchor_col
        self.extra_carets = copy.extra_carets.copy()


# --- Editor widget ----------------------------------------------------------


struct Editor(ImplicitlyCopyable, Movable):
    """Pure-Mojo text editor widget.

    Cursor model: a *primary* cursor at ``(cursor_row, cursor_col)`` plus an
    ``anchor`` at the same coordinates when there is no selection. Any movement
    can be performed *with* or *without* the Shift modifier; with Shift we keep
    the anchor fixed (extending the selection), without Shift we collapse the
    anchor to the new cursor position. Word movement (Ctrl) and selection
    (Shift) are independent dimensions that compose cleanly.

    Multiple cursors live in ``extra_carets``. Most edit / movement ops
    iterate every caret (primary + extras) and run the single-caret code
    once per caret — so the empty-extras path is identical to the
    pre-multi-cursor code. Bindings: Ctrl+click adds a caret, Ctrl+Alt+
    Up/Down stamps a caret one row above the topmost / below the
    bottommost existing caret, plain click drops back to a single caret.
    Edits that don't generalise cleanly across rows (Enter, paste, cut,
    comment toggle, replace-all, …) collapse the extras first.
    """
    var buffer: TextBuffer
    var cursor_row: Int
    var cursor_col: Int
    # ``desired_col`` is the column the user wants to be in when moving
    # vertically. It only diverges from ``cursor_col`` when the cursor is
    # parked on a line shorter than the desired column — the next vertical
    # move that lands on a wider line snaps back to ``desired_col``. Any
    # horizontal motion (typing, arrows, click, etc.) resets it.
    var desired_col: Int
    var anchor_row: Int
    var anchor_col: Int
    # Additional carets beyond the primary. Empty in the common case.
    # Order is not significant for correctness — every iteration helper
    # sorts the union of {primary, *extras} on demand. The list omits
    # the primary so callers can keep using the existing fields without
    # round-tripping through a list lookup.
    var extra_carets: List[Caret]
    var scroll_y: Int
    var scroll_x: Int
    # File-backing (empty file_path means buffer is not file-backed):
    var file_path: String
    var file_size: Int64
    var file_mtime: Int64
    var dirty: Bool
    # Last on-disk byte-content we observed for this file, used as the
    # merge base when ``check_for_external_change`` detects a stat
    # change while ``dirty`` is True. Updated on initial load
    # (``from_file``), every successful ``save`` / ``save_as``, and the
    # clean-reload branch of ``check_for_external_change``. Empty when
    # the buffer has no backing file.
    var disk_baseline: String
    # Resolved editorconfig settings (default-constructed when no
    # ``.editorconfig`` is found; in that case the editor falls back to
    # its pre-editorconfig behavior — 4-space tabs, ``\n`` line endings,
    # no trim/final-newline enforcement).
    var editorconfig: EditorConfig
    # Syntax highlighting overlay. ``_highlights_dirty`` triggers
    # ``_refresh_highlights`` after edits / file loads;
    # ``_hl_dirty_row`` says where to start re-tokenizing — every
    # row below it potentially has stale state (block comment
    # opened, scope changed, etc.). 0 means "the whole buffer"
    # (the conservative default for operations that may have
    # touched any row, e.g. undo / redo / file load).
    var highlights: List[Highlight]
    var _highlights_dirty: Bool
    var _hl_dirty_row: Int
    # Spell-check overlay. ``spell_highlights`` holds underline-only
    # ``Highlight`` entries painted *after* the syntax pass so a
    # misspelled word inside a comment stays cyan but gets a squiggle.
    # ``spell_lines[i]`` is True iff buffer row ``i`` contains at least
    # one misspelling — the right-side minimap projects this list so
    # the user can scan the file at a glance.
    var spell_highlights: List[Highlight]
    var spell_lines: List[Bool]
    # LSP diagnostics overlay. ``diagnostics`` is the most recent set
    # routed in by ``Desktop.lsp_tick`` from
    # ``LspManager.take_diagnostics_for(file_path)``; the editor itself
    # never speaks LSP. Painted on top of syntax + spell as a third
    # underline pass — color keyed on severity (red curly = error,
    # yellow curly = warning, blue = info, dim gray = hint).
    # ``diagnostic_lines[i]`` is the highest severity present on
    # buffer row ``i`` (1=Error wins, 2=Warning, 3=Info, 4=Hint, 0=clean)
    # so the right-side minimap can color-code the marker.
    var diagnostics: List[Diagnostic]
    var diagnostic_lines: List[Int]
    # ``pending_spell_action`` is set when the user hits Alt+Enter on
    # a misspelled word — the host polls
    # ``consume_spell_action_request`` and forwards to whichever popup
    # menu it wants to surface (currently the "Add to user/project
    # dictionary" menu in ``Desktop``). Lives next to
    # ``pending_definition`` so multi-pending state is uniformly
    # consumed by the host on every paint.
    var pending_spell_action: Optional[SpellActionRequest]
    # ``pending_definition`` is set when the user Cmd+left-clicks an
    # identifier (delivered as Left+Alt by iTerm2) — the host polls
    # ``consume_definition_request`` and forwards to whichever LSP client
    # is active.
    var pending_definition: Optional[DefinitionRequest]
    # Debugger gutter state. ``gutter_width`` is 0 when no debug session
    # is associated with this file; when > 0 the leftmost columns are
    # reserved for breakpoint dots / current-execution arrow. The Desktop
    # repopulates ``breakpoint_lines`` and ``exec_line`` each frame from
    # the active ``DapManager`` — the editor itself owns no DAP state.
    var gutter_width: Int
    var breakpoint_lines: List[Int]
    # Parallel to ``breakpoint_lines``. Drives gutter colour:
    # disabled → gray, conditional → yellow, otherwise red. Both lists
    # populated together by Desktop's ``dap_tick`` so the entries
    # always line up; a length mismatch is treated as "render plain
    # red dots" by the paint code below.
    var breakpoint_enabled: List[Bool]
    var breakpoint_conditional: List[Bool]
    var exec_line: Int
    # Set by ``handle_mouse`` when the user left-clicks anywhere in the
    # gutter (debugger / line-number / change / blame strip). The host
    # polls ``consume_breakpoint_toggle`` and forwards the row to its
    # ``DapManager.toggle_breakpoint``; the editor itself owns no DAP
    # state, so the toggle has to round-trip through Desktop.
    var pending_breakpoint_toggle: Optional[Int]
    # Right-click on a breakpoint dot in the gutter sets this — the
    # host opens the breakpoint-context dialog. ``anchor_*`` is the
    # clicked cell so the dialog opens near the click; ``row`` is the
    # buffer row the BP sits on.
    var pending_breakpoint_menu: Optional[BreakpointMenuRequest]
    # Set by ``handle_mouse`` when the user left-clicks the per-line
    # change-bar in the git-changes gutter. The host polls
    # ``consume_git_revert_request``, opens its revert popup anchored at
    # the click, and on confirmation calls ``apply_revert_block`` with a
    # block computed from the cached HEAD baseline.
    var pending_git_revert: Optional[GitRevertRequest]
    # Set by ``check_for_external_change`` when a 3-way merge against a
    # changed-on-disk file produces conflicts. Holds a pre-rendered
    # unified diff (previous on-disk content vs. current on-disk
    # content) so the host can open a side-by-side diff view without
    # the Editor needing to know about windows. ``consume_conflict_diff``
    # returns and clears the slot.
    var pending_conflict_diff: Optional[String]
    # View options. ``line_numbers`` paints a right-aligned line-number
    # gutter to the right of the debugger gutter; its width is derived
    # from ``buffer.line_count()`` at paint time. ``soft_wrap`` forces
    # ``scroll_x = 0`` and breaks long lines across multiple screen rows
    # at the text-area's right edge. Both default off and are toggled
    # via the View menu.
    var line_numbers: Bool
    var soft_wrap: Bool
    # ``read_only`` makes every mutating operation a no-op: typing,
    # backspace/delete, paste, cut, undo/redo, replace_all,
    # toggle_comment, toggle_case. Cursor movement, selection, copy,
    # search, and scrolling stay enabled. Used by the docs viewer so
    # the user can browse rendered HTML without accidentally typing
    # into it.
    var read_only: Bool
    # Git blame overlay. ``blame_lines[i]`` carries the short SHA and
    # author for buffer row ``i`` when the gutter is on; the list is
    # populated by the host (Desktop's ``EDITOR_TOGGLE_BLAME`` action
    # runs ``git blame --porcelain`` and feeds the result through
    # ``set_blame``). Off by default — adds a wide left gutter that
    # would be noise for casual editing.
    var blame_lines: List[BlameLine]
    var blame_visible: Bool
    # Git-changes gutter. ``git_change_lines[i]`` is one of
    # ``GIT_CHANGE_NONE/ADDED/MODIFIED`` for buffer row ``i``; the host
    # populates it by diffing the in-memory buffer against the file at
    # ``HEAD``. ``git_changes_visible`` mirrors the global config flag
    # (the column only renders when *visible* AND the lines list is
    # non-empty, so non-git files silently produce no column even when
    # the toggle is on).
    var git_changes_visible: Bool
    var git_change_lines: List[Int]
    # Right-side minimap gutter. When True, the right-edge column paints
    # a whole-file projection of uncommitted-change markers (independent
    # of ``scroll_y``). The gutter is zero-width whenever there's no
    # source data to project — currently the git_change_lines list — so
    # turning this on outside a git repo is a silent no-op.
    var minimap_visible: Bool
    # ``_git_head_text`` caches the file's content at HEAD so the
    # gutter can re-diff against the in-memory buffer on every edit
    # without re-spawning git. ``_git_head_loaded`` distinguishes "not
    # fetched yet" from "fetched and confirmed absent" (untracked
    # file) — only the former triggers a fetch on the next paint.
    # ``_git_head_present`` is True when the fetch produced a real
    # baseline; ``_git_changes_dirty`` is set on every buffer edit
    # (piggy-backing on ``_mark_hl_dirty``) so the desktop paint pass
    # re-runs the line-diff.
    var _git_head_text: String
    var _git_head_loaded: Bool
    var _git_head_present: Bool
    var _git_changes_dirty: Bool
    # ``_lsp_dirty`` is True when the buffer has mutated since the last
    # didChange we sent to the LSP server. Set in ``_mark_hl_dirty``
    # (every edit path) and consumed by ``Desktop.lsp_tick`` which sends
    # a didChange and clears it. Without this the server's view of the
    # file freezes at didOpen time, so its published diagnostics
    # describe stale text — old issues stick to lines the user has
    # since edited and new issues never appear.
    var _lsp_dirty: Bool
    # Wallclock (``monotonic_ms``) at which ``_lsp_dirty`` was last
    # raised. Read by ``consume_lsp_dirty`` so the per-frame didChange
    # sync can wait ``_LSP_DIDCHANGE_DEBOUNCE_MS`` past the last edit
    # before flushing — see the constant's docstring for the rationale.
    var _lsp_dirty_stamp_ms: Int
    # Per-window undo history. ``_undo_stack`` grows on every mutating
    # command; ``_redo_stack`` is filled by ``undo`` and emptied by any
    # subsequent edit (the standard "branching breaks redo" model).
    var _undo_stack: List[EditorSnapshot]
    var _redo_stack: List[EditorSnapshot]
    # Typing-group debounce. While ``_typing_active`` is True and the gap
    # since ``_typing_last_ms`` is short, the next printable insert extends
    # the current undo step instead of pushing a new one. Any non-typing
    # operation (cursor move, backspace, mouse click, paste, …) clears
    # the flag so the next character starts a fresh group.
    var _typing_active: Bool
    var _typing_last_ms: Int
    # Multi-click tracking. ``_last_click_ms`` is the timestamp of the
    # most recent left-button press; ``_last_click_row`` /
    # ``_last_click_col`` were the (row, col) it landed on.
    # ``_click_count`` counts consecutive presses at the same cell within
    # ``_DOUBLE_CLICK_MS`` (1=single, 2=double, 3=triple, then resets).
    # Double-click selects the word under the pointer; triple-click
    # selects the whole line. ``_dc_active`` / ``_tc_active`` stay True
    # until release or a press elsewhere; while set, drag-motion extends
    # in whole-word / whole-line units anchored to the originally clicked
    # word (``_dc_anchor_*``) or row (``_tc_anchor_row``).
    var _last_click_ms: Int
    var _last_click_row: Int
    var _last_click_col: Int
    var _click_count: Int
    var _dc_active: Bool
    var _dc_anchor_row: Int
    var _dc_anchor_start: Int
    var _dc_anchor_end: Int
    var _tc_active: Bool
    var _tc_anchor_row: Int
    # TextMate grammar cache. Refreshing highlights re-loads the grammar
    # via this slot; a cold load is ~100 ms for the bundled rust grammar
    # so we *really* want hits here on every keystroke. Reset on copy
    # because the cached ``Grammar`` isn't ``ImplicitlyCopyable`` (its
    # ``OnigRegex`` list aliases libonig handles); the next refresh will
    # rebuild it from the file path.
    var _hl_cache: HighlightCache
    # Smart-select expansion stack. Each Cmd+Up snapshots the current
    # caret + selection here before growing; Cmd+Down pops to walk back.
    # Cleared by any other key, click, or edit so the stack only ever
    # describes a contiguous Cmd+Up run.
    var _smart_select_stack: List[Caret]
    # Hover-tooltip state. Originally minimap-only (hence the field
    # prefix), now also drives in-text hover popups for spell flags and
    # LSP diagnostic underlines: hovering over a misspelled word or a
    # warning/error squiggle in the editor surface produces the same
    # tooltip box as the minimap-mark hover.
    # ``_minimap_hover_kind`` is 0 when nothing is hovered,
    # 1=git-change mark, 2=spell flag, 3..6=LSP diagnostic
    # (error/warning/info/hint).
    # ``_minimap_hover_buf_row`` is the buffer row the tooltip describes;
    # ``_minimap_hover_word`` is the label payload (misspelled word for
    # kind=2, full diagnostic message for kind=3..6, empty for kind=1);
    # ``_minimap_hover_x/y`` are the screen coords used to anchor the
    # tooltip box — for minimap-source hovers that's the cursor pos
    # (tooltip floats above-left); for text-area-source hovers that's
    # the leftmost cell of the underlined span and the row immediately
    # below it (tooltip floats below the underline, left-aligned).
    # ``_minimap_hover_below`` selects which fallback the paint code
    # uses if the preferred placement doesn't fit. Updated by hover
    # events flowing through ``handle_mouse``; consumed by
    # ``paint_minimap_tooltip`` after the main editor paint pass.
    var _minimap_hover_kind: Int
    var _minimap_hover_buf_row: Int
    var _minimap_hover_word: String
    var _minimap_hover_x: Int
    var _minimap_hover_y: Int
    var _minimap_hover_below: Bool
    # LSP completion popup. ``pending_completion_request`` is set when
    # the user invokes completion (Ctrl+Space) — the host polls
    # ``consume_completion_request`` and dispatches to its LSP
    # manager. When a response lands, ``set_completions`` populates
    # the list and flips ``completion_popup_visible`` on; key events
    # then route through the popup (Up/Down/Enter/Tab/Esc/typing) so
    # the user can pick an entry without taking their hands off the
    # keyboard.
    #
    # ``completion_anchor_row`` / ``completion_anchor_col`` is the
    # cursor position when the popup was opened *minus the length of
    # the in-progress identifier*: accepting an entry replaces
    # ``[anchor_col, cursor_col)`` with the chosen ``insert_text``,
    # so a user who typed "fo" before invoking and then picks ``foo``
    # ends up with just ``foo`` rather than ``fofoo``. The host also
    # uses these to position the popup below the start of the word.
    var pending_completion_request: Optional[CompletionRequest]
    var completion_popup_visible: Bool
    var completion_items: List[CompletionItem]
    var completion_highlight: Int
    var completion_scroll: Int
    var completion_anchor_row: Int
    var completion_anchor_col: Int
    # True when the popup is showing a synthetic message (currently only
    # ``<no completion found>`` from a manual Ctrl+Space that returned
    # empty). The single ``completion_items`` entry is non-acceptable —
    # Enter/Tab dismiss the popup rather than insert.
    var completion_is_message: Bool
    # ``monotonic_ms()`` reading from the last time
    # ``_stamp_completion_request`` (or Ctrl+Space) fired. The host's
    # ``consume_completion_request`` reads this to debounce as-you-type
    # requests — see ``_COMPLETION_DEBOUNCE_MS``.
    var _completion_request_stamp_ms: Int
    # Latched True when ``close_completion_popup`` runs: tells the host
    # to send ``$/cancelRequest`` for any LSP-side completion that is
    # still in flight so a late response doesn't pop the popup back open
    # after the user dismissed it (Esc / cursor-out-of-word / accept).
    var _completion_cancel_pending: Bool

    fn __init__(out self):
        self.buffer = TextBuffer()
        self.cursor_row = 0
        self.cursor_col = 0
        self.desired_col = 0
        self.anchor_row = 0
        self.anchor_col = 0
        self.extra_carets = List[Caret]()
        self.scroll_y = 0
        self.scroll_x = 0
        self.file_path = String("")
        self.file_size = Int64(0)
        self.file_mtime = Int64(0)
        self.dirty = False
        self.disk_baseline = String("")
        self.editorconfig = EditorConfig()
        self.highlights = List[Highlight]()
        self._highlights_dirty = True
        self._hl_dirty_row = 0
        self.spell_highlights = List[Highlight]()
        self.spell_lines = List[Bool]()
        self.diagnostics = List[Diagnostic]()
        self.diagnostic_lines = List[Int]()
        self.pending_spell_action = Optional[SpellActionRequest]()
        self.pending_definition = Optional[DefinitionRequest]()
        self.gutter_width = 0
        self.breakpoint_lines = List[Int]()
        self.breakpoint_enabled = List[Bool]()
        self.breakpoint_conditional = List[Bool]()
        self.exec_line = -1
        self.pending_breakpoint_toggle = Optional[Int]()
        self.pending_breakpoint_menu = Optional[BreakpointMenuRequest]()
        self.pending_git_revert = Optional[GitRevertRequest]()
        self.pending_conflict_diff = Optional[String]()
        self.line_numbers = False
        self.soft_wrap = False
        self.read_only = False
        self.blame_lines = List[BlameLine]()
        self.blame_visible = False
        self.git_changes_visible = False
        self.git_change_lines = List[Int]()
        self.minimap_visible = True
        self._git_head_text = String("")
        self._git_head_loaded = False
        self._git_head_present = False
        self._git_changes_dirty = True
        self._lsp_dirty = False
        self._lsp_dirty_stamp_ms = 0
        self._undo_stack = List[EditorSnapshot]()
        self._redo_stack = List[EditorSnapshot]()
        self._typing_active = False
        self._typing_last_ms = 0
        self._last_click_ms = 0
        self._last_click_row = -1
        self._last_click_col = -1
        self._click_count = 0
        self._dc_active = False
        self._dc_anchor_row = 0
        self._dc_anchor_start = 0
        self._dc_anchor_end = 0
        self._tc_active = False
        self._tc_anchor_row = 0
        self._hl_cache = HighlightCache()
        self._smart_select_stack = List[Caret]()
        self._minimap_hover_kind = 0
        self._minimap_hover_buf_row = -1
        self._minimap_hover_word = String("")
        self._minimap_hover_x = 0
        self._minimap_hover_y = 0
        self._minimap_hover_below = False
        self.pending_completion_request = Optional[CompletionRequest]()
        self.completion_popup_visible = False
        self.completion_items = List[CompletionItem]()
        self.completion_highlight = 0
        self.completion_scroll = 0
        self.completion_anchor_row = 0
        self.completion_anchor_col = 0
        self.completion_is_message = False
        self._completion_request_stamp_ms = 0
        self._completion_cancel_pending = False

    fn __init__(out self, var text: String):
        self.buffer = TextBuffer(text^)
        self.cursor_row = 0
        self.cursor_col = 0
        self.desired_col = 0
        self.anchor_row = 0
        self.anchor_col = 0
        self.extra_carets = List[Caret]()
        self.scroll_y = 0
        self.scroll_x = 0
        self.file_path = String("")
        self.file_size = Int64(0)
        self.file_mtime = Int64(0)
        self.dirty = False
        self.disk_baseline = String("")
        self.editorconfig = EditorConfig()
        self.highlights = List[Highlight]()
        self._highlights_dirty = True
        self._hl_dirty_row = 0
        self.spell_highlights = List[Highlight]()
        self.spell_lines = List[Bool]()
        self.diagnostics = List[Diagnostic]()
        self.diagnostic_lines = List[Int]()
        self.pending_spell_action = Optional[SpellActionRequest]()
        self.pending_definition = Optional[DefinitionRequest]()
        self.gutter_width = 0
        self.breakpoint_lines = List[Int]()
        self.breakpoint_enabled = List[Bool]()
        self.breakpoint_conditional = List[Bool]()
        self.exec_line = -1
        self.pending_breakpoint_toggle = Optional[Int]()
        self.pending_breakpoint_menu = Optional[BreakpointMenuRequest]()
        self.pending_git_revert = Optional[GitRevertRequest]()
        self.pending_conflict_diff = Optional[String]()
        self.line_numbers = False
        self.soft_wrap = False
        self.read_only = False
        self.blame_lines = List[BlameLine]()
        self.blame_visible = False
        self.git_changes_visible = False
        self.git_change_lines = List[Int]()
        self.minimap_visible = True
        self._git_head_text = String("")
        self._git_head_loaded = False
        self._git_head_present = False
        self._git_changes_dirty = True
        self._lsp_dirty = False
        self._lsp_dirty_stamp_ms = 0
        self._undo_stack = List[EditorSnapshot]()
        self._redo_stack = List[EditorSnapshot]()
        self._typing_active = False
        self._typing_last_ms = 0
        self._last_click_ms = 0
        self._last_click_row = -1
        self._last_click_col = -1
        self._click_count = 0
        self._dc_active = False
        self._dc_anchor_row = 0
        self._dc_anchor_start = 0
        self._dc_anchor_end = 0
        self._tc_active = False
        self._tc_anchor_row = 0
        self._hl_cache = HighlightCache()
        self._smart_select_stack = List[Caret]()
        self._minimap_hover_kind = 0
        self._minimap_hover_buf_row = -1
        self._minimap_hover_word = String("")
        self._minimap_hover_x = 0
        self._minimap_hover_y = 0
        self._minimap_hover_below = False
        self.pending_completion_request = Optional[CompletionRequest]()
        self.completion_popup_visible = False
        self.completion_items = List[CompletionItem]()
        self.completion_highlight = 0
        self.completion_scroll = 0
        self.completion_anchor_row = 0
        self.completion_anchor_col = 0
        self.completion_is_message = False
        self._completion_request_stamp_ms = 0
        self._completion_cancel_pending = False

    @staticmethod
    fn from_file(var path: String) raises -> Self:
        var text = read_file(path)
        var info = stat_file(path)
        # Keep a copy of the on-disk bytes as the merge base for any
        # later 3-way merge against an external write.
        var baseline = text
        var ed = Editor(text^)
        ed.editorconfig = load_editorconfig_for_path(path)
        ed.file_path = path^
        ed.file_size = info.size
        ed.file_mtime = info.mtime_sec
        ed.dirty = False
        ed.disk_baseline = baseline^
        # No inline tokenization: ``_highlights_dirty`` is True
        # from ``__init__``, so the next ``flush_highlights`` call
        # from the render path will populate ``ed.highlights``.
        # Tests that need synchronous highlights call
        # ``ed.flush_highlights(local_registry)`` directly.
        return ed^

    fn __copyinit__(out self, copy: Self):
        self.buffer = copy.buffer
        self.cursor_row = copy.cursor_row
        self.cursor_col = copy.cursor_col
        self.desired_col = copy.desired_col
        self.anchor_row = copy.anchor_row
        self.anchor_col = copy.anchor_col
        self.extra_carets = copy.extra_carets.copy()
        self.scroll_y = copy.scroll_y
        self.scroll_x = copy.scroll_x
        self.file_path = copy.file_path
        self.file_size = copy.file_size
        self.file_mtime = copy.file_mtime
        self.dirty = copy.dirty
        self.disk_baseline = copy.disk_baseline
        self.editorconfig = copy.editorconfig
        self.highlights = copy.highlights.copy()
        self._highlights_dirty = copy._highlights_dirty
        self._hl_dirty_row = copy._hl_dirty_row
        self.spell_highlights = copy.spell_highlights.copy()
        self.spell_lines = copy.spell_lines.copy()
        self.diagnostics = copy.diagnostics.copy()
        self.diagnostic_lines = copy.diagnostic_lines.copy()
        self.pending_spell_action = copy.pending_spell_action
        self.pending_definition = copy.pending_definition
        self.gutter_width = copy.gutter_width
        self.breakpoint_lines = copy.breakpoint_lines.copy()
        self.breakpoint_enabled = copy.breakpoint_enabled.copy()
        self.breakpoint_conditional = copy.breakpoint_conditional.copy()
        self.exec_line = copy.exec_line
        self.pending_breakpoint_toggle = copy.pending_breakpoint_toggle
        self.pending_breakpoint_menu = copy.pending_breakpoint_menu
        self.pending_git_revert = copy.pending_git_revert
        self.pending_conflict_diff = copy.pending_conflict_diff
        self.line_numbers = copy.line_numbers
        self.soft_wrap = copy.soft_wrap
        self.read_only = copy.read_only
        self.blame_lines = copy.blame_lines.copy()
        self.blame_visible = copy.blame_visible
        self.git_changes_visible = copy.git_changes_visible
        self.git_change_lines = copy.git_change_lines.copy()
        self.minimap_visible = copy.minimap_visible
        self._git_head_text = copy._git_head_text
        self._git_head_loaded = copy._git_head_loaded
        self._git_head_present = copy._git_head_present
        self._git_changes_dirty = copy._git_changes_dirty
        self._lsp_dirty = copy._lsp_dirty
        self._lsp_dirty_stamp_ms = copy._lsp_dirty_stamp_ms
        self._undo_stack = copy._undo_stack.copy()
        self._redo_stack = copy._redo_stack.copy()
        self._typing_active = copy._typing_active
        self._typing_last_ms = copy._typing_last_ms
        self._last_click_ms = copy._last_click_ms
        self._last_click_row = copy._last_click_row
        self._last_click_col = copy._last_click_col
        self._click_count = copy._click_count
        self._dc_active = copy._dc_active
        self._dc_anchor_row = copy._dc_anchor_row
        self._dc_anchor_start = copy._dc_anchor_start
        self._dc_anchor_end = copy._dc_anchor_end
        self._tc_active = copy._tc_active
        self._tc_anchor_row = copy._tc_anchor_row
        # Don't carry the cached grammar across a copy. ``Grammar`` owns
        # ``OnigRegex`` instances whose libonig handles we share via a
        # bitwise-aliasing copy; once we add proper ``__del__`` support
        # the aliasing could double-free. Letting the copy rebuild on
        # first refresh costs one cold load but is always correct.
        self._hl_cache = HighlightCache()
        self._smart_select_stack = copy._smart_select_stack.copy()
        self._minimap_hover_kind = copy._minimap_hover_kind
        self._minimap_hover_buf_row = copy._minimap_hover_buf_row
        self._minimap_hover_word = copy._minimap_hover_word
        self._minimap_hover_x = copy._minimap_hover_x
        self._minimap_hover_y = copy._minimap_hover_y
        self._minimap_hover_below = copy._minimap_hover_below
        self.pending_completion_request = copy.pending_completion_request
        self.completion_popup_visible = copy.completion_popup_visible
        self.completion_items = copy.completion_items.copy()
        self.completion_highlight = copy.completion_highlight
        self.completion_scroll = copy.completion_scroll
        self.completion_anchor_row = copy.completion_anchor_row
        self.completion_anchor_col = copy.completion_anchor_col
        self.completion_is_message = copy.completion_is_message
        self._completion_request_stamp_ms = copy._completion_request_stamp_ms
        self._completion_cancel_pending = copy._completion_cancel_pending

    fn flush_highlights(
        mut self, mut registry: GrammarRegistry, mut speller: Speller,
    ):
        """Bring ``self.highlights`` up to date by tokenizing against
        the shared ``GrammarRegistry``. No-op if not ``_highlights_dirty``.

        Also recomputes ``spell_highlights`` and ``spell_lines`` from
        the fresh syntax pass, so the spell overlay always reflects
        the current buffer state. ``speller`` is the process-shared
        wordlist; if it isn't loaded yet we trigger a lazy load on the
        first call.

        Called from the render path (``Desktop.paint`` walks all
        editors before drawing). Edit methods on ``Editor`` no
        longer tokenize inline — they just set the dirty flag and
        the dirty-row marker via ``_mark_hl_dirty``, so highlights
        stay slightly stale between an edit and the next paint.
        Tests that need synchronous highlights call this directly.
        """
        if not self._highlights_dirty:
            return
        var ext = extension_of(self.file_path)
        self.highlights = highlight_incremental(
            ext, self.buffer.lines, self._hl_dirty_row,
            registry, self._hl_cache,
        )
        self._highlights_dirty = False
        # Mark the cache as fully clean by parking the dirty row
        # past the end of the buffer. Any subsequent edit will
        # bring it back to a real row via ``_mark_hl_dirty``.
        self._hl_dirty_row = self.buffer.line_count()
        speller.load_default()
        self._refresh_spell(speller)

    fn _refresh_spell(mut self, speller: Speller):
        """Rebuild ``spell_highlights`` and ``spell_lines`` from the
        current ``self.highlights``. Walks every comment / string
        highlight, runs the words through the speller, and emits an
        underline-only highlight for each misspelling.

        On terminals that support the colon-separated SGR extensions
        (iTerm2, kitty, vte, Windows Terminal, …) the misspelled word
        keeps its host fg/bg and gets a *red curly underline* —
        ``SGR 4:3`` + ``SGR 58:5:1`` — the classic VS Code squiggle.
        On terminals that don't (Apple Terminal.app, basic xterm) we
        fall back to ``LIGHT_RED`` foreground + plain ``SGR 4`` so the
        flag is at least visible; the underline alone would be
        invisible because cyan-on-cyan blends.

        ``spell_lines[i]`` is set True for any row that gained a
        highlight so the right-side minimap can project a marker."""
        self.spell_highlights = List[Highlight]()
        self.spell_lines = List[Bool]()
        for _ in range(self.buffer.line_count()):
            self.spell_lines.append(False)
        if not speller.loaded:
            return
        var comment_attr = highlight_comment_attr()
        var string_attr = highlight_string_attr()
        var extended = terminal_supports_extended_underline()
        # First pass: honor IntelliJ-style ``noinspection`` directives
        # in comments. A directive on row N suppresses spell flags on
        # row N (so ``noinspection`` itself isn't flagged) and on row
        # N+1, mirroring IntelliJ's "applies to next code element"
        # behavior.
        var n_lines = self.buffer.line_count()
        var suppressed = List[Bool]()
        var row_has_comment = List[Bool]()
        for _ in range(n_lines):
            suppressed.append(False)
            row_has_comment.append(False)
        for h in range(len(self.highlights)):
            var hl = self.highlights[h]
            if hl.attr != comment_attr:
                continue
            if hl.row < 0 or hl.row >= n_lines:
                continue
            row_has_comment[hl.row] = True
        for r in range(n_lines):
            if not row_has_comment[r]:
                continue
            if has_spell_noinspection_directive(self.buffer.line(r)):
                suppressed[r] = True
                if r + 1 < n_lines:
                    suppressed[r + 1] = True
        for h in range(len(self.highlights)):
            var hl = self.highlights[h]
            var is_comment = hl.attr == comment_attr
            var is_string = hl.attr == string_attr
            if not (is_comment or is_string):
                continue
            if hl.row < 0 or hl.row >= n_lines:
                continue
            if suppressed[hl.row]:
                continue
            var line = self.buffer.line(hl.row)
            var line_bytes = line.as_bytes()
            var lo = hl.col_start
            var hi = hl.col_end
            if lo < 0:
                lo = 0
            if hi > len(line_bytes):
                hi = len(line_bytes)
            if lo >= hi:
                continue
            var slice_text = String(
                StringSlice(unsafe_from_utf8=line_bytes[lo:hi])
            )
            var runs = find_misspelled_runs(speller, slice_text)
            if len(runs) == 0:
                continue
            var underline_attr: Attr
            if extended:
                # Keep the host comment/string color, add curly red
                # underline as a separate channel.
                underline_attr = hl.attr.add_style(
                    STYLE_UNDERLINE | STYLE_UNDERLINE_CURLY,
                ).with_underline_color(Int16(LIGHT_RED))
            else:
                # Plain underline: paint the word red so the flag
                # itself is visible (the line would otherwise blend
                # into the cyan comment text).
                underline_attr = hl.attr.with_fg(LIGHT_RED).add_style(
                    STYLE_UNDERLINE,
                )
            for r in range(len(runs)):
                var rs = runs[r][0] + lo
                var re = runs[r][1] + lo
                self.spell_highlights.append(
                    Highlight(hl.row, rs, re, underline_attr)
                )
            self.spell_lines[hl.row] = True

    fn invalidate_spell(mut self):
        """Force ``flush_highlights`` to rerun ``_refresh_spell`` on
        the next paint. Used after the speller's word list changes
        (e.g. user added a word to the user/project dictionary) so the
        underline goes away on this same frame.

        Sets ``_highlights_dirty`` rather than only touching spell state
        because ``_refresh_spell`` reads from the cached
        ``self.highlights`` and we don't have a separate
        spell-only entry point. The grammar pass hits the incremental
        cache so the extra cost is microseconds."""
        self._highlights_dirty = True
        self._hl_dirty_row = 0

    fn set_diagnostics(mut self, var diags: List[Diagnostic]):
        """Replace the diagnostic set with ``diags`` and rebuild the
        per-row severity index used by the minimap.

        The host owns when this fires — typically once per frame from
        ``Desktop.lsp_tick`` after draining ``LspManager.take_diagnostics_for``.
        Severity priority on a single row: error > warning > info >
        hint; ``diagnostic_lines[i]`` carries the winning severity
        (or 0 for "clean") so the right-side minimap can color a row
        without re-scanning the whole list."""
        var n_lines = self.buffer.line_count()
        var per_row = List[Int]()
        for _ in range(n_lines):
            per_row.append(0)
        for i in range(len(diags)):
            var d = diags[i]
            if d.start_row < 0 or d.start_row >= n_lines:
                continue
            var sev = d.severity
            if sev <= 0:
                continue
            # Lower numeric value wins (1=Error beats 2=Warning).
            var prev = per_row[d.start_row]
            if prev == 0 or sev < prev:
                per_row[d.start_row] = sev
        self.diagnostics = diags^
        self.diagnostic_lines = per_row^

    fn clear_diagnostics(mut self):
        """Drop all diagnostics and the per-row severity index. Used
        when an LSP server fails / restarts and the prior diagnostics
        no longer reflect reality."""
        self.diagnostics = List[Diagnostic]()
        self.diagnostic_lines = List[Int]()

    fn consume_lsp_dirty(mut self, now_ms: Int = 0) -> Bool:
        """Return whether the buffer has been edited since the last
        time this was called, and clear the flag. The host drives this
        from ``Desktop.lsp_tick`` to send a didChange and keep the
        server's text in sync with what's on screen.

        ``now_ms`` enables the debounce gate: when non-zero, the dirty
        flag is only consumed (and reported) once
        ``_LSP_DIDCHANGE_DEBOUNCE_MS`` has elapsed since the last edit.
        Within that window the flag stays raised so the next tick will
        check again. ``now_ms == 0`` is the unconditional / test-path
        flavor used by callers that are about to flush the buffer
        themselves (``_dispatch_completion_request`` pre-flights its
        own didChange and just needs the flag cleared)."""
        if not self._lsp_dirty:
            return False
        if now_ms != 0 \
                and now_ms - self._lsp_dirty_stamp_ms \
                    < _LSP_DIDCHANGE_DEBOUNCE_MS:
            return False
        self._lsp_dirty = False
        return True

    fn invalidate_highlight_cache(mut self):
        """Drop the per-buffer tokenizer state and force a full
        retokenize on the next ``flush_highlights``. Used after a
        grammar download lands so the editor immediately picks up the
        newly-installed ``.tmLanguage.json`` instead of continuing to
        paint stale (or empty) highlights from before the download."""
        self._hl_cache = HighlightCache()
        self._highlights_dirty = True
        self._hl_dirty_row = 0

    fn _mark_hl_dirty(mut self, row: Int):
        """Note that ``row`` (and possibly later rows) need
        re-tokenizing. The dirty pointer only ever moves *up*
        toward the top of the buffer — once row 5 is dirty,
        subsequent edits at row 12 don't lift it back to 12.

        ``row < 0`` is the conservative "I don't know which row
        was touched" signal; it sets the dirty pointer to 0,
        forcing a full retokenize."""
        var r = row
        if r < 0:
            r = 0
        if r < self._hl_dirty_row:
            self._hl_dirty_row = r
        self._highlights_dirty = True
        # Every code path that mutates the buffer eventually flows
        # through here — same hook drives the change-bar gutter so
        # we don't need to thread a separate "buffer changed" signal
        # to every edit handler.
        self._git_changes_dirty = True
        self._lsp_dirty = True
        self._lsp_dirty_stamp_ms = monotonic_ms()

    fn refresh_highlights(mut self):
        """Mark highlights dirty so the next ``flush_highlights``
        call (driven by the render path) re-tokenizes. Use this
        when the host changes the buffer through a path that
        bypassed the normal edit-handlers — setting ``file_path``
        directly is the canonical example.

        We *don't* tokenize inline here: the actual work needs the
        shared ``GrammarRegistry`` which lives at the layer above.
        Callers that need a synchronous refresh in test code can
        call ``flush_highlights(local_registry)`` instead.
        """
        self._mark_hl_dirty(0)

    # --- undo / redo ------------------------------------------------------

    fn _snapshot(self) -> EditorSnapshot:
        return EditorSnapshot(
            self.buffer.lines.copy(),
            self.cursor_row, self.cursor_col,
            self.anchor_row, self.anchor_col,
            self.extra_carets.copy(),
        )

    fn _push_undo(mut self):
        """Record the current state on the undo stack and clear redo.

        Call this *before* applying a mutation so ``undo`` rewinds to the
        pre-edit state. Any new edit invalidates the redo branch — that's
        the standard linear-history model and matches what users expect
        from a Turbo-Vision-era editor.
        """
        self._undo_stack.append(self._snapshot())
        # Drop the oldest entries when the cap is exceeded. ``List`` has no
        # pop_front, so we rebuild a tail slice — only happens at most once
        # per push, after the stack has filled up.
        if len(self._undo_stack) > _UNDO_STACK_LIMIT:
            var trimmed = List[EditorSnapshot]()
            for i in range(
                len(self._undo_stack) - _UNDO_STACK_LIMIT,
                len(self._undo_stack),
            ):
                trimmed.append(self._undo_stack[i])
            self._undo_stack = trimmed^
        self._redo_stack = List[EditorSnapshot]()
        # Pushing a snapshot ends any typing run that was in flight. The
        # printable-insert path explicitly re-sets the flag after this
        # call when it wants the new char to anchor a fresh group.
        self._typing_active = False

    fn _restore(mut self, snap: EditorSnapshot):
        self.buffer.lines = snap.lines.copy()
        self.cursor_row = snap.cursor_row
        self.cursor_col = snap.cursor_col
        self.desired_col = _utf8_cell_of_byte(
            self.buffer.line(snap.cursor_row), snap.cursor_col,
        )
        self.anchor_row = snap.anchor_row
        self.anchor_col = snap.anchor_col
        self.extra_carets = snap.extra_carets.copy()
        self.dirty = True
        # Undo/redo restores the entire buffer; we don't know which
        # rows differ from the post-state we last tokenized, so we
        # force a full retokenize. Could narrow this by diffing
        # ``snap.lines`` against ``self.buffer.lines`` pre-restore,
        # but the marginal cost of a full retokenize on undo is
        # acceptable for now.
        self._mark_hl_dirty(0)
        # Undo/redo lands on a saved state; the next typing should start a
        # new group rather than extend whatever was running before.
        self._typing_active = False
        # _refresh_highlights() removed: render path flushes via Editor.flush_highlights

    # --- multi-cursor helpers --------------------------------------------
    #
    # The primary caret stays in ``cursor_*``/``anchor_*``/``desired_col``;
    # ``extra_carets`` carries any additional carets. ``has_extra_carets``
    # is the cheap "is multi-cursor in flight?" check. ``primary_caret`` /
    # ``_apply_caret`` round-trip primary state to/from a ``Caret`` value
    # so iteration helpers can run the existing single-caret code once
    # per caret (set primary, run op, capture result).

    fn has_extra_carets(self) -> Bool:
        return len(self.extra_carets) > 0

    fn caret_count(self) -> Int:
        return 1 + len(self.extra_carets)

    fn primary_caret(self) -> Caret:
        return Caret(
            self.cursor_row, self.cursor_col, self.desired_col,
            self.anchor_row, self.anchor_col,
        )

    fn _apply_caret(mut self, c: Caret):
        self.cursor_row = c.row
        self.cursor_col = c.col
        self.desired_col = c.desired_col
        self.anchor_row = c.anchor_row
        self.anchor_col = c.anchor_col

    fn clear_extra_carets(mut self):
        """Drop every extra caret. The primary caret keeps its position
        and selection. Called on plain mouse click, on collapsing
        operations (Enter, paste, comment toggle, …), and from the host
        when the user presses Esc with no modal open."""
        self.extra_carets = List[Caret]()

    fn _collapse_extras_with_undo(mut self):
        """When extras are present, push an undo snapshot capturing
        them and then drop them — so undo restores the multi-caret
        state. Used by ops that don't generalise to multi-caret
        (Enter, paste, cut, comment toggle, …): each falls through
        to the original single-caret code paths after this call,
        and those may push their own further undo steps. The user
        then walks back through both via repeated undo."""
        if self.has_extra_carets():
            self._push_undo()
            self.extra_carets = List[Caret]()

    fn _all_carets_asc(self) -> List[Caret]:
        """Return primary + extras sorted ascending by ``(row, col)``.
        Used by every multi-caret iteration; sort is stable, ties on
        identical positions are dropped by the dedupe in
        ``_install_carets``."""
        var out = List[Caret]()
        out.append(self.primary_caret())
        for i in range(len(self.extra_carets)):
            out.append(self.extra_carets[i])
        # Insertion sort — typical caret count is 2..10, plenty fast.
        var n = len(out)
        for i in range(1, n):
            var j = i
            while j > 0 and _caret_less(out[j], out[j - 1]):
                var tmp = out[j]
                out[j] = out[j - 1]
                out[j - 1] = tmp
                j -= 1
        return out^

    fn _install_carets(mut self, var carets: List[Caret]):
        """Promote ``carets[0]`` to primary, the rest to ``extra_carets``,
        after deduping carets that landed on the same ``(row, col)`` —
        merging is what the user expects when two carets walk into each
        other (e.g. ten carets all running ``Home``).

        Ties on the caret position keep the entry whose anchor is
        farther from the cursor — that's the one carrying a real
        selection if any of them did."""
        if len(carets) == 0:
            return
        # Sort ascending by (row, col).
        var n = len(carets)
        for i in range(1, n):
            var j = i
            while j > 0 and _caret_less(carets[j], carets[j - 1]):
                var tmp = carets[j]
                carets[j] = carets[j - 1]
                carets[j - 1] = tmp
                j -= 1
        # Dedupe: collapse runs of carets at the same (row, col).
        var deduped = List[Caret]()
        for i in range(len(carets)):
            var c = carets[i]
            if len(deduped) > 0:
                var prev = deduped[len(deduped) - 1]
                if prev.row == c.row and prev.col == c.col:
                    # Keep whichever has the larger selection span;
                    # equal-span ties break in favor of the existing
                    # entry (insertion order = ``carets`` order).
                    var prev_span = _caret_anchor_span(prev)
                    var cur_span = _caret_anchor_span(c)
                    if cur_span > prev_span:
                        deduped[len(deduped) - 1] = c
                    continue
            deduped.append(c)
        self._apply_caret(deduped[0])
        var extras = List[Caret]()
        for i in range(1, len(deduped)):
            extras.append(deduped[i])
        self.extra_carets = extras^

    fn _add_caret(mut self, c: Caret):
        """Append a caret and renormalise. Public-facing convenience for
        the host (Ctrl+click, Ctrl+Alt+Up/Down, …)."""
        var all_c = self._all_carets_asc()
        all_c.append(c)
        self._install_carets(all_c^)

    fn add_caret_above(mut self):
        """Stamp a new caret one row above the topmost existing caret,
        column-cell-aligned to the primary caret's ``desired_col``. Bound
        to Ctrl+Alt+Up. No-op when the topmost caret is already on row 0
        — there's nowhere above to stamp."""
        var all_c = self._all_carets_asc()
        var top = all_c[0]
        if top.row <= 0:
            return
        var nr = top.row - 1
        var line = self.buffer.line(nr)
        var nc = _utf8_byte_of_cell(line, self.desired_col)
        self._add_caret(Caret(nr, nc, self.desired_col, nr, nc))

    fn add_caret_below(mut self):
        """Stamp a new caret one row below the bottommost existing caret.
        Bound to Ctrl+Alt+Down. No-op when there's no row below."""
        var all_c = self._all_carets_asc()
        var bot = all_c[len(all_c) - 1]
        if bot.row + 1 >= self.buffer.line_count():
            return
        var nr = bot.row + 1
        var line = self.buffer.line(nr)
        var nc = _utf8_byte_of_cell(line, self.desired_col)
        self._add_caret(Caret(nr, nc, self.desired_col, nr, nc))

    fn _any_caret_has_selection(self) -> Bool:
        if self.has_selection():
            return True
        for i in range(len(self.extra_carets)):
            var c = self.extra_carets[i]
            if c.row != c.anchor_row or c.col != c.anchor_col:
                return True
        return False

    fn _all_carets_inline_safe(
        self, op: Int,
    ) -> Bool:
        """``op``: 0 = inline insert, 1 = backspace, 2 = delete.
        Returns True iff every caret can perform the op without crossing
        a row boundary. Used by the keystroke handler to decide whether
        to take the multi-caret fast path or to collapse to primary
        first. ``has_selection`` on any caret also collapses (multi-
        caret + selection edits aren't supported in the MVP)."""
        if self._any_caret_has_selection():
            return False
        if op == 0:
            return True
        var carets = self._all_carets_asc()
        for i in range(len(carets)):
            var c = carets[i]
            if op == 1:
                if c.col == 0:
                    return False
            elif op == 2:
                var n = self.buffer.line_length(c.row)
                if c.col >= n:
                    return False
        return True

    fn undo(mut self) -> Bool:
        """Roll back the last mutation. Returns False when the stack is empty.

        The caller is responsible for re-scrolling — pass the editor's view
        rect to ``reveal_cursor`` afterwards if you want the cursor on screen.
        """
        if self.read_only:
            return False
        if len(self._undo_stack) == 0:
            return False
        var snap = self._undo_stack.pop()
        self._redo_stack.append(self._snapshot())
        self._restore(snap)
        return True

    fn redo(mut self) -> Bool:
        """Replay the most recently undone mutation. False when nothing to redo."""
        if self.read_only:
            return False
        if len(self._redo_stack) == 0:
            return False
        var snap = self._redo_stack.pop()
        self._undo_stack.append(self._snapshot())
        self._restore(snap)
        return True

    fn consume_definition_request(mut self) -> Optional[DefinitionRequest]:
        """Return any pending ``DefinitionRequest`` and clear the slot."""
        var req = self.pending_definition
        self.pending_definition = Optional[DefinitionRequest]()
        return req

    fn consume_completion_request(
        mut self, now_ms: Int = 0,
    ) -> Optional[CompletionRequest]:
        """Return any pending ``CompletionRequest`` and clear the slot.

        Set by ``handle_key`` when the user invokes completion (Ctrl+Space
        or the as-you-type auto-trigger). The host forwards to its LSP
        manager and routes the response back via ``set_completions``.

        ``now_ms`` (``monotonic_ms()`` from the host) gates as-you-type
        requests behind ``_COMPLETION_DEBOUNCE_MS``: a request keeps
        getting refreshed in the slot while the user types, and only
        becomes consumable after typing settles. Manual requests
        (Ctrl+Space) bypass the gate. ``now_ms == 0`` (the default) is
        the test escape hatch — tests don't carry monotonic time and
        the debounce check is unrelated to what they verify.
        """
        if not self.pending_completion_request:
            return Optional[CompletionRequest]()
        var req = self.pending_completion_request.value()
        if now_ms != 0 and not req.manual:
            if now_ms - self._completion_request_stamp_ms \
                    < _COMPLETION_DEBOUNCE_MS:
                return Optional[CompletionRequest]()
        self.pending_completion_request = Optional[CompletionRequest]()
        return Optional[CompletionRequest](req)

    fn consume_completion_cancel(mut self) -> Bool:
        """Return and clear the cancel-pending latch.

        Set by ``close_completion_popup`` whenever the popup is
        dismissed. The host translates a True return into
        ``LspManager.cancel_completion()`` so a late response on a
        previously-issued request doesn't reopen the popup after the
        user has explicitly dismissed it."""
        var pending = self._completion_cancel_pending
        self._completion_cancel_pending = False
        return pending

    fn close_completion_popup(mut self):
        """Hide and clear the completion popup. Idempotent.

        Also clears any queued ``pending_completion_request`` and
        latches ``_completion_cancel_pending`` so the host sends
        ``$/cancelRequest`` for any LSP-side request still in flight.
        Without the cancel a late response would call back into
        ``set_completions`` and pop the popup right back open — the
        user dismisses via Esc, sees the popup go away, then it
        reappears 100 ms later. Cheap when nothing is in flight (the
        host's ``cancel_completion`` is a no-op in that case)."""
        self.completion_popup_visible = False
        self.completion_items = List[CompletionItem]()
        self.completion_highlight = 0
        self.completion_scroll = 0
        self.completion_is_message = False
        self.pending_completion_request = Optional[CompletionRequest]()
        self._completion_cancel_pending = True

    fn set_completions(
        mut self, var items: List[CompletionItem],
        anchor_row: Int, anchor_col: Int,
    ):
        """Park ``items`` on the popup and make it visible.

        ``anchor_row`` / ``anchor_col`` is the start of the identifier
        the completion will replace — usually a few cells left of the
        cursor when the user invoked completion partway through a
        word. Accepting an entry replaces ``[anchor_col, cursor_col)``
        on ``anchor_row`` with the chosen ``insert_text``. Empty
        ``items`` closes the popup (a server response with no matches
        is identical, UX-wise, to dismissing the popup). Hosts that
        want to surface "no matches" to the user (e.g. when the user
        explicitly invoked completion) should call
        ``show_no_completion_message`` instead.
        """
        if len(items) == 0:
            self.close_completion_popup()
            return
        self.completion_items = items^
        self.completion_popup_visible = True
        self.completion_highlight = 0
        self.completion_scroll = 0
        self.completion_anchor_row = anchor_row
        self.completion_anchor_col = anchor_col
        self.completion_is_message = False

    fn show_no_completion_message(
        mut self, anchor_row: Int, anchor_col: Int,
    ):
        """Surface a ``<no completion found>`` popup at the anchor.

        Used by hosts when a user-invoked (Ctrl+Space) completion
        request returned no results — silently doing nothing leaves
        the user wondering whether anything happened. The popup
        renders a single non-acceptable entry; Enter / Tab dismiss
        rather than insert, arrow keys are no-ops."""
        var items = List[CompletionItem]()
        items.append(
            CompletionItem(
                String("<no completion found>"),
                String(""), 0, String(""), String(""),
                False, 0, 0, 0, 0,
            )
        )
        self.completion_items = items^
        self.completion_popup_visible = True
        self.completion_highlight = 0
        self.completion_scroll = 0
        self.completion_anchor_row = anchor_row
        self.completion_anchor_col = anchor_col
        self.completion_is_message = True

    fn completion_prefix_start(self) -> Int:
        """Cursor's identifier start col on the current line. Walks
        backward through word codepoints until hitting a non-word char
        or the start of the line. Used to anchor the completion popup
        so accepting an entry replaces what the user already typed."""
        var line = self.buffer.line(self.cursor_row)
        var col = self.cursor_col
        while col > 0:
            var prev = prev_codepoint_start(line, col)
            var info = codepoint_at(line, prev)
            if not is_word_codepoint(info[0]):
                break
            col = prev
        return col

    fn _cursor_after_word_codepoint(self) -> Bool:
        """True iff the codepoint immediately to the left of the cursor
        is a word codepoint (letter, digit, or underscore). Used by the
        as-you-type completion auto-trigger to decide whether the
        cursor is still inside an identifier after a backspace."""
        if self.cursor_col == 0:
            return False
        var line = self.buffer.line(self.cursor_row)
        if len(line.as_bytes()) == 0:
            return False
        var prev = prev_codepoint_start(line, self.cursor_col)
        var info = codepoint_at(line, prev)
        return is_word_codepoint(info[0])

    fn _stamp_completion_request(mut self):
        """Stamp ``pending_completion_request`` at the current cursor.
        Helper for the as-you-type auto-trigger paths so they don't
        each duplicate the prefix-start lookup. ``manual=False`` —
        an empty response on this path silently dismisses the popup
        rather than showing ``<no completion found>``.

        Also refreshes ``_completion_request_stamp_ms``: while the user
        is typing this keeps resetting and the host's debounced
        ``consume_completion_request`` leaves the slot alone — only
        once typing pauses for ``_COMPLETION_DEBOUNCE_MS`` does the
        host actually forward the request."""
        var start_col = self.completion_prefix_start()
        self.pending_completion_request = Optional[CompletionRequest](
            CompletionRequest(
                self.cursor_row, self.cursor_col, start_col, False,
            ),
        )
        self._completion_request_stamp_ms = monotonic_ms()

    fn accept_completion(mut self) -> Bool:
        """Apply the currently highlighted completion to the buffer.

        Replaces ``[anchor_col, cursor_col)`` on ``anchor_row`` with the
        selected item's ``insert_text`` and parks the cursor at the end
        of the replacement. Closes the popup. Returns False (no-op)
        when the popup isn't visible, the highlight is out of range,
        or the anchor row no longer matches the cursor row (the user
        clicked away to another row while the popup was up).

        For the ``<no completion found>`` message popup, Enter / Tab
        just dismiss — there is nothing to insert."""
        if not self.completion_popup_visible:
            return False
        if self.completion_is_message:
            self.close_completion_popup()
            return True
        if self.read_only:
            self.close_completion_popup()
            return False
        if self.completion_highlight < 0 \
                or self.completion_highlight >= len(self.completion_items):
            self.close_completion_popup()
            return False
        if self.completion_anchor_row != self.cursor_row:
            self.close_completion_popup()
            return False
        var item = self.completion_items[self.completion_highlight]
        var pre = self.cursor_row
        var line = self.buffer.line(self.cursor_row)
        var ln = len(line.as_bytes())
        var start = self.completion_anchor_col
        var end = self.cursor_col
        if end > ln:
            end = ln
        # Pick the widest sensible replacement span. Priority:
        # 1. LSP ``textEdit`` range — the server's authoritative answer.
        # 2. Longest typed-prefix overlap with ``insert_text`` — catches
        #    path completions (``reviews/re`` → ``reviews/reviews__tags
        #    .html``) where the word-boundary anchor stops at the ``/``
        #    and would leave a duplicated prefix on the line.
        # 3. Word-boundary anchor (already in ``start``) — the
        #    conservative default.
        # End stays at the cursor so chars typed between request and
        # accept get folded into the replacement rather than left
        # dangling past the inserted text.
        if item.has_range \
                and item.range_start_line == self.cursor_row \
                and item.range_end_line == self.cursor_row:
            start = item.range_start_char
        else:
            var overlap = _completion_overlap_start(
                line, end, item.insert_text,
            )
            if overlap < start:
                start = overlap
        if start < 0:
            start = 0
        if end < start:
            end = start
        if start > ln:
            start = ln
        self._push_undo()
        self._typing_active = False
        # Delete the existing prefix span, then insert.
        if end > start:
            self.move_to(self.cursor_row, end, False)
            for _ in range(end - start):
                var p = self.buffer.delete_before(
                    self.cursor_row, self.cursor_col,
                )
                self.move_to(p[0], p[1], False)
        self.buffer.insert(
            self.cursor_row, self.cursor_col, item.insert_text,
        )
        self.move_to(
            self.cursor_row,
            self.cursor_col + len(item.insert_text.as_bytes()),
            False,
        )
        self.dirty = True
        self._mark_hl_dirty(pre)
        self.close_completion_popup()
        return True

    fn _completion_step(mut self, delta: Int):
        """Move the popup highlight by ``delta`` (clamped). No-op when
        the popup isn't visible or when showing a message popup (the
        sole entry isn't selectable, so arrow keys have nothing to do).
        """
        if not self.completion_popup_visible:
            return
        if self.completion_is_message:
            return
        var n = len(self.completion_items)
        if n == 0:
            return
        var i = self.completion_highlight + delta
        if i < 0:
            i = 0
        elif i >= n:
            i = n - 1
        self.completion_highlight = i
        # Keep the highlight in view. Popup renders _COMPLETION_POPUP_ROWS
        # rows at a time; scroll the window when the highlight steps
        # outside it.
        if self.completion_highlight < self.completion_scroll:
            self.completion_scroll = self.completion_highlight
        elif self.completion_highlight \
                >= self.completion_scroll + _COMPLETION_POPUP_ROWS:
            self.completion_scroll = (
                self.completion_highlight - _COMPLETION_POPUP_ROWS + 1
            )

    fn consume_spell_action_request(
        mut self,
    ) -> Optional[SpellActionRequest]:
        """Return any pending ``SpellActionRequest`` and clear the slot.

        Set by ``handle_key`` when the user hits Alt+Enter while the
        cursor sits inside a misspelled-word range. The host opens its
        spell-action popup against the returned row/col span."""
        var req = self.pending_spell_action
        self.pending_spell_action = Optional[SpellActionRequest]()
        return req

    fn spell_run_at_cursor(self) -> Optional[SpellActionRequest]:
        """Return the misspelled-word range at the current cursor, or
        ``None`` if the cursor isn't inside one. Treats the trailing
        boundary as inclusive (``col_start <= cursor_col <= col_end``)
        so a cursor parked just past the last letter still finds the
        word — typing usually leaves the cursor there."""
        for h in range(len(self.spell_highlights)):
            var hl = self.spell_highlights[h]
            if hl.row != self.cursor_row:
                continue
            if hl.col_start <= self.cursor_col \
                    and self.cursor_col <= hl.col_end:
                var line = self.buffer.line(hl.row)
                var lb = line.as_bytes()
                var lo = hl.col_start
                var hi = hl.col_end
                if lo < 0:
                    lo = 0
                if hi > len(lb):
                    hi = len(lb)
                if lo >= hi:
                    return Optional[SpellActionRequest]()
                var word = String(
                    StringSlice(unsafe_from_utf8=lb[lo:hi])
                )
                return Optional[SpellActionRequest](
                    SpellActionRequest(hl.row, lo, hi, word)
                )
        return Optional[SpellActionRequest]()

    fn consume_breakpoint_toggle(mut self) -> Optional[Int]:
        """Return any pending gutter-click row and clear the slot."""
        var row = self.pending_breakpoint_toggle
        self.pending_breakpoint_toggle = Optional[Int]()
        return row

    fn consume_breakpoint_menu(
        mut self,
    ) -> Optional[BreakpointMenuRequest]:
        """Return any pending right-click on a BP dot and clear the
        slot. The host opens the breakpoint-context dialog anchored at
        the request's screen cell."""
        var req = self.pending_breakpoint_menu
        self.pending_breakpoint_menu = Optional[BreakpointMenuRequest]()
        return req

    fn consume_git_revert_request(mut self) -> Optional[GitRevertRequest]:
        """Return any pending git revert request and clear the slot.
        Set by ``handle_mouse`` when the user clicks the per-line bar
        in the git-changes column over a row that's actually changed
        from HEAD."""
        var req = self.pending_git_revert
        self.pending_git_revert = Optional[GitRevertRequest]()
        return req

    fn apply_revert_block(mut self, var block: GitRevertBlock):
        """Replace ``buffer.lines[buf_start:buf_end_excl]`` with
        ``block.head_lines``. Used by the git-gutter revert popup;
        leaves the cursor at the start of the reverted block."""
        if self.read_only:
            return
        var bs = block.buf_start
        var be = block.buf_end_excl
        if bs < 0 or bs > self.buffer.line_count():
            return
        if be < bs:
            return
        if be > self.buffer.line_count():
            be = self.buffer.line_count()
        self._push_undo()
        # Build a new line list with the slice replaced. Doing this as
        # one rebuild keeps the operation atomic for undo and avoids
        # repeated mid-list pops/inserts.
        var new_lines = List[String]()
        for i in range(bs):
            new_lines.append(self.buffer.lines[i])
        for i in range(len(block.head_lines)):
            new_lines.append(block.head_lines[i])
        for i in range(be, self.buffer.line_count()):
            new_lines.append(self.buffer.lines[i])
        # An empty buffer still needs to hold one (empty) line so the
        # rest of the editor can index lines[0] safely.
        if len(new_lines) == 0:
            new_lines.append(String(""))
        self.buffer.lines = new_lines^
        var max_row = self.buffer.line_count() - 1
        var nr = bs
        if nr > max_row:
            nr = max_row
        if nr < 0:
            nr = 0
        self.move_to(nr, 0, False)
        self.dirty = True
        self._mark_hl_dirty(bs)

    fn consume_conflict_diff(mut self) -> Optional[String]:
        """Return any pending merge-conflict diff text and clear the
        slot. Populated by ``check_for_external_change`` whenever it
        returns ``EXT_CHANGE_CONFLICT``; the host wraps the text in a
        read-only diff window so the user can see what changed
        externally while resolving the conflict markers in the buffer.
        """
        var d = self.pending_conflict_diff
        self.pending_conflict_diff = Optional[String]()
        return d

    fn check_for_external_change(mut self) raises -> Int:
        """Re-stat the backing file and react to any out-of-band write.

        Returns one of the ``EXT_CHANGE_*`` codes:

        * ``EXT_CHANGE_NONE`` — no change detected.
        * ``EXT_CHANGE_RELOADED`` — buffer was clean; loaded the new
          on-disk content verbatim.
        * ``EXT_CHANGE_MERGED`` — buffer was dirty; 3-way merge against
          ``disk_baseline`` produced a clean result and was applied.
        * ``EXT_CHANGE_CONFLICT`` — buffer was dirty; merge produced
          conflicts. The buffer now has standard ``<<<<<<< / ======= /
          >>>>>>>`` markers, the cursor sits on the first marker line,
          and the caller should surface a diff view.

        After any non-``NONE`` return the stat info and ``disk_baseline``
        are updated so the next tick won't re-trigger on the same
        external write.
        """
        if len(self.file_path.as_bytes()) == 0:
            return EXT_CHANGE_NONE
        var info = stat_file(self.file_path)
        if not info.ok:
            return EXT_CHANGE_NONE
        if info.size == self.file_size and info.mtime_sec == self.file_mtime:
            return EXT_CHANGE_NONE
        var text = read_file(self.file_path)
        if not self.dirty:
            # Clean reload: buffer matches the previous baseline, just
            # adopt the new bytes.
            var baseline = text
            self.buffer = TextBuffer(text^)
            self.disk_baseline = baseline^
            self.file_size = info.size
            self.file_mtime = info.mtime_sec
            self.refresh_highlights()
            self._clamp_cursor_after_reload()
            self.anchor_row = self.cursor_row
            self.anchor_col = self.cursor_col
            return EXT_CHANGE_RELOADED
        # Dirty: 3-way merge against the previous on-disk content.
        var base_lines = _split_buffer_lines(self.disk_baseline)
        var ours_lines = self.buffer.lines.copy()
        var theirs_lines = _split_buffer_lines(text)
        var merge = diff3_merge(
            base_lines, ours_lines, theirs_lines,
            String("local edits"), String("on disk"),
        )
        # Snapshot for undo before mutating — gives the user a single
        # Ctrl+Z to back out of the merge if they don't like it.
        self._push_undo()
        self.buffer.lines = merge.lines.copy()
        # Pre-render the previous-on-disk vs. current-on-disk diff
        # *before* we overwrite ``disk_baseline`` so the host can open
        # a diff view that shows what changed externally.
        if merge.conflicts > 0:
            self.pending_conflict_diff = Optional[String](unified_diff(
                self.disk_baseline,
                text,
                String("on disk (previous)"),
                String("on disk (current)"),
            ))
        self.disk_baseline = text^
        self.file_size = info.size
        self.file_mtime = info.mtime_sec
        if merge.conflicts > 0:
            self.cursor_row = merge.first_conflict_row
            self.cursor_col = 0
            self.anchor_row = self.cursor_row
            self.anchor_col = self.cursor_col
            self.desired_col = 0
            self.dirty = True
            self.refresh_highlights()
            return EXT_CHANGE_CONFLICT
        # Clean merge: dirty iff the merged buffer differs from what's
        # currently on disk. (Equal happens when ``theirs`` already
        # contained all of our local edits.)
        var dirty_after = not _lists_equal(self.buffer.lines, theirs_lines)
        self.dirty = dirty_after
        self._clamp_cursor_after_reload()
        self.anchor_row = self.cursor_row
        self.anchor_col = self.cursor_col
        self.refresh_highlights()
        return EXT_CHANGE_MERGED

    fn _clamp_cursor_after_reload(mut self):
        """Pull the primary cursor back inside the new buffer bounds and
        recompute ``desired_col``. Used after a reload or merge replaces
        ``buffer.lines`` so a cursor that was past the previous EOL
        doesn't end up dangling."""
        var max_row = self.buffer.line_count() - 1
        if max_row < 0:
            max_row = 0
        if self.cursor_row > max_row:
            self.cursor_row = max_row
        if self.cursor_row < 0:
            self.cursor_row = 0
        var n = self.buffer.line_length(self.cursor_row)
        if self.cursor_col > n:
            self.cursor_col = n
        if self.cursor_col < 0:
            self.cursor_col = 0
        self.desired_col = _utf8_cell_of_byte(
            self.buffer.line(self.cursor_row), self.cursor_col,
        )

    # --- saving ------------------------------------------------------------

    fn text_snapshot(self) -> String:
        """Concatenate buffer lines with ``\\n`` separators (no trailing
        newline appended — a file that originally ended in ``\\n`` produces
        a trailing empty line in the buffer, which round-trips correctly).
        Used by the LSP layer for didOpen/didChange payloads. Saving uses
        ``_disk_text`` instead so editorconfig transforms (line endings,
        trailing-whitespace trim, final newline) are only applied on disk
        — the LSP server should see the buffer as-is.

        Accumulates into a byte buffer to keep this O(N): ``String +
        String`` allocates a fresh String each call, so the obvious
        loop is O(N²) and a single snapshot of a 10k-line file is
        multi-GB of churn — felt as a perceptible hang on the UI
        thread because the LSP completion path calls this on every
        keystroke.
        """
        var n = self.buffer.line_count()
        if n == 0:
            return String("")
        var buf = List[UInt8]()
        for i in range(n):
            if i > 0:
                buf.append(UInt8(0x0A))
            append_string_bytes(buf, self.buffer.line(i))
        return String(StringSlice(
            ptr=buf.unsafe_ptr(), length=len(buf),
        ))

    fn _disk_text(self) -> String:
        """Build the byte sequence to write to disk for the current buffer,
        applying any active editorconfig transforms.

        Three editorconfig properties feed in here:

        * ``trim_trailing_whitespace`` — strip trailing spaces/tabs from
          every line.
        * ``insert_final_newline`` — ensure (or forbid) a trailing newline.
          The buffer convention encodes a trailing newline as a final
          empty line, so we add or drop that empty line accordingly.
        * ``end_of_line`` — replaces the line separator (``\\n`` by
          default) with the configured byte sequence.

        When no ``.editorconfig`` was found, ``editorconfig`` is
        default-constructed and this reduces to the same join-with-``\\n``
        behavior that ``text_snapshot`` produces.
        """
        var trim = self.editorconfig.trim_trailing_whitespace == 1
        var ifn = self.editorconfig.insert_final_newline
        var sep = self.editorconfig.line_separator()
        var n = self.buffer.line_count()
        # ``has_trailing_newline``: by buffer convention, a file that ends
        # in ``\n`` produces a final empty line. Use that as the test.
        var has_trailing_newline = n > 0 \
            and len(self.buffer.line(n - 1).as_bytes()) == 0
        var emit_count = n
        if ifn == 1 and not has_trailing_newline:
            # Pretend there's an extra empty line at the end.
            emit_count = n + 1
        elif ifn == 0 and has_trailing_newline:
            # Drop the trailing empty line.
            emit_count = n - 1
        var out = String("")
        for i in range(emit_count):
            var line: String
            if i < n:
                line = self.buffer.line(i)
            else:
                line = String("")
            if trim:
                line = _rtrim(line)
            if i > 0:
                out = out + sep
            out = out + line
        return out

    fn save(mut self) raises -> Bool:
        """Write the buffer back to ``file_path``. Returns False if the
        editor has no backing path (caller should trigger Save As) or the
        write fails.
        """
        if len(self.file_path.as_bytes()) == 0:
            return False
        var disk = self._disk_text()
        if not write_file(self.file_path, disk):
            return False
        # Refresh stat info so check_for_external_change doesn't pick up our
        # own write as an external change. Adopt the just-written bytes as
        # the new merge base.
        var info = stat_file(self.file_path)
        if info.ok:
            self.file_size = info.size
            self.file_mtime = info.mtime_sec
        self.disk_baseline = disk^
        self.dirty = False
        return True

    fn save_as(mut self, var path: String) raises -> Bool:
        """Write the buffer to ``path`` and adopt it as the new backing file.

        Resolves editorconfig for the destination *before* writing so disk
        transforms (line endings, trailing-whitespace trim, final newline)
        reflect the new path. If the write fails the previous backing path
        and editorconfig are restored — observable state matches the
        original "noop on failure" contract.
        """
        var prev_path = self.file_path
        var prev_config = self.editorconfig
        self.editorconfig = load_editorconfig_for_path(path)
        self.file_path = path^
        var disk = self._disk_text()
        if not write_file(self.file_path, disk):
            self.file_path = prev_path^
            self.editorconfig = prev_config^
            return False
        var info = stat_file(self.file_path)
        if info.ok:
            self.file_size = info.size
            self.file_mtime = info.mtime_sec
        self.disk_baseline = disk^
        self.dirty = False
        # Extension may have changed (e.g., ``.txt`` → ``.mojo``); re-tokenize.
        # _refresh_highlights() removed: render path flushes via Editor.flush_highlights
        return True

    fn replace_all(
        mut self, find: String, replacement: String,
        opts: SearchOptions = default_search_options(),
    ) -> Int:
        """Replace every occurrence of ``find`` with ``replacement`` in the
        buffer. Returns the number of replacements; sets ``dirty`` if > 0.
        Does not move the cursor (caller may want to clamp it).

        An undo step is pushed eagerly and rolled back when no replacements
        actually fired, so a bulk replace that finds nothing won't blow
        away redo history. No-op when the editor is read-only.

        ``opts`` honors the Cc / W / .* search-mode flags. The fast
        byte-replace loop runs unchanged when no flag is set; once any
        flag is on we route through libonig per line. Replacement is
        always literal (no ``$1`` backrefs) — that's a deliberate
        scope limit, not a bug."""
        if self.read_only:
            return 0
        var fb = find.as_bytes()
        var rb_len = len(replacement.as_bytes())
        var n = len(fb)
        if n == 0:
            return 0
        var rx_opt = build_search_regex(find, opts)
        if rx_opt:
            return self._replace_all_regex(rx_opt.value(), replacement)
        self._push_undo()
        var count = 0
        for row in range(self.buffer.line_count()):
            var line = self.buffer.line(row)
            var lb = line.as_bytes()
            var h = len(lb)
            if h < n:
                continue
            var rebuilt = String("")
            var i = 0
            var seg_start = 0
            var line_changed = False
            while i + n <= h:
                var hit = True
                for k in range(n):
                    if lb[i + k] != fb[k]:
                        hit = False
                        break
                if hit:
                    if i > seg_start:
                        rebuilt = rebuilt + String(StringSlice(
                            unsafe_from_utf8=lb[seg_start:i]
                        ))
                    rebuilt = rebuilt + replacement
                    i += n
                    seg_start = i
                    count += 1
                    line_changed = True
                else:
                    i += 1
            if line_changed:
                if seg_start < h:
                    rebuilt = rebuilt + String(StringSlice(
                        unsafe_from_utf8=lb[seg_start:h]
                    ))
                self.buffer.lines[row] = rebuilt
        if count > 0:
            self.dirty = True
            # ``replace_all`` may have touched any number of lines;
            # we don't track the lowest, so force a full retokenize.
            self._mark_hl_dirty(0)
            # Clamp the cursor (line lengths may have changed under it).
            var max_row = self.buffer.line_count() - 1
            if self.cursor_row > max_row: self.cursor_row = max_row
            var nlen = self.buffer.line_length(self.cursor_row)
            if self.cursor_col > nlen: self.cursor_col = nlen
            self.anchor_row = self.cursor_row
            self.anchor_col = self.cursor_col
            _ = rb_len   # silence unused warning if compiler reports it
            # _refresh_highlights() removed: render path flushes via Editor.flush_highlights
        else:
            # Nothing changed — roll back the speculative snapshot so the
            # undo stack stays in sync and redo isn't clobbered.
            _ = self._undo_stack.pop()
        return count

    fn _replace_all_regex(
        mut self, rx: OnigRegex, replacement: String,
    ) -> Int:
        """Regex-mode ``replace_all``: rebuild each line by walking
        forward through libonig matches. Same speculative-undo
        protocol as the byte path so a no-op replace doesn't clobber
        redo history."""
        self._push_undo()
        var count = 0
        for row in range(self.buffer.line_count()):
            var line = self.buffer.line(row)
            var lb = line.as_bytes()
            var h = len(lb)
            var rebuilt = String("")
            var pos = 0
            var seg_start = 0
            var line_changed = False
            while pos <= h:
                var m = rx.search_at(line, pos)
                if not m:
                    break
                var mv = m.value()
                if mv.start < 0 or mv.end < mv.start:
                    break
                if mv.start > seg_start:
                    rebuilt = rebuilt + String(StringSlice(
                        unsafe_from_utf8=lb[seg_start:mv.start]
                    ))
                rebuilt = rebuilt + replacement
                count += 1
                line_changed = True
                if mv.end == mv.start:
                    # Zero-width match: advance one byte to avoid an
                    # infinite loop while still consuming the position.
                    seg_start = mv.start
                    pos = mv.start + 1
                else:
                    seg_start = mv.end
                    pos = mv.end
            if line_changed:
                if seg_start < h:
                    rebuilt = rebuilt + String(StringSlice(
                        unsafe_from_utf8=lb[seg_start:h]
                    ))
                self.buffer.lines[row] = rebuilt
        if count > 0:
            self.dirty = True
            self._mark_hl_dirty(0)
            var max_row = self.buffer.line_count() - 1
            if self.cursor_row > max_row: self.cursor_row = max_row
            var nlen = self.buffer.line_length(self.cursor_row)
            if self.cursor_col > nlen: self.cursor_col = nlen
            self.anchor_row = self.cursor_row
            self.anchor_col = self.cursor_col
        else:
            _ = self._undo_stack.pop()
        return count

    # --- selection state ---------------------------------------------------

    fn has_selection(self) -> Bool:
        return (self.cursor_row != self.anchor_row) \
            or (self.cursor_col != self.anchor_col)

    fn selection(self) -> Tuple[Int, Int, Int, Int]:
        """Normalized ``(start_row, start_col, end_row, end_col)`` (start <= end)."""
        var sr = self.anchor_row
        var sc = self.anchor_col
        var er = self.cursor_row
        var ec = self.cursor_col
        if (sr > er) or (sr == er and sc > ec):
            var tr = sr; var tc = sc
            sr = er; sc = ec
            er = tr; ec = tc
        return (sr, sc, er, ec)

    fn _line_op_range(self) -> Tuple[Int, Int]:
        """Inclusive ``(start_row, end_row)`` for line-level commands like
        Tab/Shift+Tab indent. With no selection both bounds are the cursor's
        row. With a selection that ends at column 0 of a row, that row is
        excluded — matching the visual intuition that the trailing line
        wasn't actually part of the selection."""
        if not self.has_selection():
            return (self.cursor_row, self.cursor_row)
        var sel = self.selection()
        var sr = sel[0]
        var er = sel[2]
        var ec = sel[3]
        if er > sr and ec == 0:
            er -= 1
        return (sr, er)

    fn _indent_rows(mut self, sr: Int, er: Int, pre_dirty_row: Int):
        """Prepend one indent unit (per editorconfig) to every row in
        ``[sr, er]``. Cursor and anchor cols on affected rows shift right
        by the inserted byte count so the selection stays anchored to the
        same characters."""
        if er < sr:
            return
        var indent = self.editorconfig.indent_string()
        var indent_n = len(indent.as_bytes())
        if indent_n == 0:
            return
        self._push_undo()
        for r in range(sr, er + 1):
            self.buffer.lines[r] = indent + self.buffer.lines[r]
        if self.cursor_row >= sr and self.cursor_row <= er:
            self.cursor_col += indent_n
        if self.anchor_row >= sr and self.anchor_row <= er:
            self.anchor_col += indent_n
        self.desired_col = _utf8_cell_of_byte(
            self.buffer.line(self.cursor_row), self.cursor_col,
        )
        self.dirty = True
        self._mark_hl_dirty(pre_dirty_row)

    fn _dedent_rows(mut self, sr: Int, er: Int, pre_dirty_row: Int):
        """Remove up to one indent unit of leading whitespace from every
        row in ``[sr, er]``. A leading tab counts as one unit; otherwise
        up to ``effective_indent_size`` leading spaces are removed. Lines
        with no leading whitespace are left alone — and if no row would
        change, the call is a no-op (no undo entry burned)."""
        if er < sr:
            return
        var width = self.editorconfig.effective_indent_size()
        if width < 1:
            width = 4
        var removed = List[Int]()
        var any_change = False
        for r in range(sr, er + 1):
            var line = self.buffer.line(r)
            var lb = line.as_bytes()
            var n = len(lb)
            var rm = 0
            if n > 0 and lb[0] == 0x09:  # leading tab
                rm = 1
            else:
                while rm < width and rm < n and lb[rm] == 0x20:  # leading space
                    rm += 1
            removed.append(rm)
            if rm > 0:
                any_change = True
        if not any_change:
            return
        self._push_undo()
        for r in range(sr, er + 1):
            var rm = removed[r - sr]
            if rm > 0:
                var line = self.buffer.line(r)
                self.buffer.lines[r] = _slice(line, rm, len(line.as_bytes()))
        if self.cursor_row >= sr and self.cursor_row <= er:
            var rm_c = removed[self.cursor_row - sr]
            var nc = self.cursor_col - rm_c
            if nc < 0: nc = 0
            self.cursor_col = nc
        if self.anchor_row >= sr and self.anchor_row <= er:
            var rm_a = removed[self.anchor_row - sr]
            var nca = self.anchor_col - rm_a
            if nca < 0: nca = 0
            self.anchor_col = nca
        self.desired_col = _utf8_cell_of_byte(
            self.buffer.line(self.cursor_row), self.cursor_col,
        )
        self.dirty = True
        self._mark_hl_dirty(pre_dirty_row)

    fn move_to(mut self, row: Int, col: Int, extend: Bool = False, sticky_col: Bool = True):
        """Place the cursor at ``(row, col)`` (``col`` is a byte offset, must
        sit on a codepoint boundary).

        ``sticky_col=True`` (the default) updates ``desired_col`` to the cell
        column of ``col`` — any movement that the user perceives as horizontal
        (click, type, arrow-left/right, Home/End, ...) should use this.
        Vertical-only moves (up/down/PgUp/PgDn) pass ``sticky_col=False`` so
        the remembered column survives a hop through a short line. The
        cell-column representation is what makes this survive lines whose
        byte and visual widths disagree (multi-byte UTF-8 characters).
        """
        self.cursor_row = row
        self.cursor_col = col
        if sticky_col:
            self.desired_col = _utf8_cell_of_byte(self.buffer.line(row), col)
        if not extend:
            self.anchor_row = row
            self.anchor_col = col

    # --- view options ------------------------------------------------------

    fn toggle_line_numbers(mut self):
        self.line_numbers = not self.line_numbers

    fn set_blame(mut self, var lines: List[BlameLine]):
        """Replace the blame attribution list and turn the blame
        gutter on. Pass an empty list to clear the cache (the gutter
        also auto-hides when there's nothing to show)."""
        self.blame_lines = lines^
        self.blame_visible = True

    fn toggle_blame(mut self):
        """Show / hide the blame gutter. The host loads ``blame_lines``
        on the same tick the user enables it; toggling off doesn't
        discard the cache, so the next toggle-on is instant."""
        self.blame_visible = not self.blame_visible

    fn _blame_gutter(self) -> Int:
        """Width of the blame gutter in cells: 8-char short SHA + space
        + author truncated to 14 cells + one trailing separator. Zero
        when blame is hidden or no data has been loaded yet."""
        if not self.blame_visible or len(self.blame_lines) == 0:
            return 0
        return 8 + 1 + 14 + 1

    fn set_git_head_text(mut self, var text: String, present: Bool):
        """Cache the file's content at ``HEAD`` for the change-bar
        gutter. ``present=False`` records "no baseline" (file is
        untracked, brand new, or git couldn't resolve the path) — the
        column then renders nothing for this editor.

        Setting the baseline arms ``_git_changes_dirty`` so the next
        paint re-diffs the buffer against it.
        """
        self._git_head_text = text^
        self._git_head_loaded = True
        self._git_head_present = present
        self._git_changes_dirty = True

    fn set_git_changes(mut self, var lines: List[Int]):
        """Replace the per-line change-status cache. The desktop paint
        pass calls this after running the buffer-vs-HEAD diff."""
        self.git_change_lines = lines^
        self._git_changes_dirty = False

    fn git_head_text(self) -> Optional[String]:
        """Return the cached HEAD content for this file, or empty
        Optional when no baseline has been fetched (file is untracked,
        new, or git isn't reachable). Used by the gutter revert popup
        so it doesn't re-spawn git on every confirmation."""
        if not self._git_head_present:
            return Optional[String]()
        return Optional[String](self._git_head_text)

    fn invalidate_git_changes(mut self):
        """Drop the cached HEAD baseline and per-line change status.
        The next paint with the toggle on re-fetches HEAD via
        ``git show`` and re-runs the diff. Call this on save / file
        reload so the column reflects the freshly written state — the
        on-disk HEAD blob may itself have changed (commit, checkout)
        between when we cached it and now."""
        self.git_change_lines = List[Int]()
        self._git_head_text = String("")
        self._git_head_loaded = False
        self._git_head_present = False
        self._git_changes_dirty = True

    fn has_uncommitted_changes(self) -> Bool:
        """True if the buffer has unsaved edits or any cached
        line-vs-HEAD diff entry. Used by the tab bar to tint the
        filename. ``git_change_lines`` may be empty (non-git file or
        baseline not yet fetched) — that's not "uncommitted", just
        "unknown", so we report False."""
        if self.dirty:
            return True
        for i in range(len(self.git_change_lines)):
            if self.git_change_lines[i] != GIT_CHANGE_NONE:
                return True
        return False

    fn toggle_soft_wrap(mut self):
        self.soft_wrap = not self.soft_wrap
        if self.soft_wrap:
            # Soft wrap forces a left-aligned visible area: keep the
            # invariant that scroll_x == 0 by snapping it back here.
            self.scroll_x = 0

    fn _line_number_gutter(self) -> Int:
        """Width of the line-number gutter in cells, including a trailing
        space. Zero when line numbers are off."""
        if not self.line_numbers:
            return 0
        var n = self.buffer.line_count()
        var digits = 1
        var v = n
        while v >= 10:
            v //= 10
            digits += 1
        return digits + 1

    fn _git_changes_gutter(self) -> Int:
        """Width of the git-changes gutter in cells (one column for the
        bar, no trailing separator — line-number gutter already gives a
        space, and the blame / text columns abut directly). Zero when
        the toggle is off or no change data has been loaded — non-git
        files produce no column."""
        if not self.git_changes_visible:
            return 0
        if len(self.git_change_lines) == 0:
            return 0
        return 1

    fn _right_gutter(self) -> Int:
        """Width of the right-side gutter in cells. A single column
        reserved on the right edge of the editor for at-a-glance row
        annotations: gray squares for uncommitted-change lines, yellow
        squares for spell issues, plus red/yellow/blue/dim squares for
        LSP diagnostics. Zero when no annotation source is active so
        editors with nothing to show give the full width back to text."""
        if not self.minimap_visible:
            return 0
        if len(self.git_change_lines) > 0:
            return 1
        if self._has_spell_issues():
            return 1
        if self._has_diagnostic_lines():
            return 1
        return 0

    fn _has_spell_issues(self) -> Bool:
        for i in range(len(self.spell_lines)):
            if self.spell_lines[i]:
                return True
        return False

    fn _has_diagnostic_lines(self) -> Bool:
        for i in range(len(self.diagnostic_lines)):
            if self.diagnostic_lines[i] != 0:
                return True
        return False

    fn _minimap_total_lines(self) -> Int:
        """Largest source length — sets the file-row span the minimap
        projects onto its content_h screen rows. Sources may differ in
        length (e.g. ``git_change_lines`` is empty for non-git files
        even when ``spell_lines`` has entries) so we take the max
        rather than locking to ``buffer.line_count()``."""
        var n = len(self.git_change_lines)
        if len(self.spell_lines) > n:
            n = len(self.spell_lines)
        if len(self.diagnostic_lines) > n:
            n = len(self.diagnostic_lines)
        return n

    fn _minimap_buf_range_for_screen_row(
        self, sy: Int, content_h: Int,
    ) -> Tuple[Int, Int]:
        """Map screen row ``sy`` (relative to the editor's view) onto the
        slice of buffer rows the minimap projects onto it. Returns
        ``(start, end)`` with ``start == end`` when the row is past the
        end of the projection. Single source of truth for both painting
        (``_paint_right_gutter``) and hit-testing (hover/click)."""
        var n_lines = self._minimap_total_lines()
        if n_lines == 0:
            return (0, 0)
        var rows = content_h
        if rows < 1:
            rows = 1
        var start: Int
        var end: Int
        if n_lines <= rows:
            start = sy
            end = sy + 1
        else:
            start = (sy * n_lines) // rows
            end = ((sy + 1) * n_lines) // rows
            if end <= start:
                end = start + 1
        if start > n_lines:
            start = n_lines
        if end > n_lines:
            end = n_lines
        return (start, end)

    fn _minimap_kind_in_slice(self, start: Int, end: Int) -> Int:
        """Return the priority-winning source kind for the slice.

        Kinds: ``0`` (clean), ``1`` (git change), ``2`` (spell),
        ``3`` (LSP error), ``4`` (LSP warning), ``5`` (LSP info),
        ``6`` (LSP hint). Priority order, highest first:
        error → warning → git → spell → info → hint. Errors and
        warnings outrank git/spell so a real problem isn't hidden
        behind a 1-character whitespace edit; info / hint sit below
        spell so a 'consider renaming' hint doesn't overpower a
        real misspelling."""
        var n_diag = len(self.diagnostic_lines)
        var ds = start if start < n_diag else n_diag
        var de = end if end < n_diag else n_diag
        # Walk once for severity 1 (error), then 2 (warning).
        for li in range(ds, de):
            if self.diagnostic_lines[li] == DIAG_SEVERITY_ERROR:
                return 3
        for li in range(ds, de):
            if self.diagnostic_lines[li] == DIAG_SEVERITY_WARNING:
                return 4
        var n_git = len(self.git_change_lines)
        var s = start if start < n_git else n_git
        var e = end if end < n_git else n_git
        for li in range(s, e):
            if self.git_change_lines[li] != GIT_CHANGE_NONE:
                return 1
        var n_sp = len(self.spell_lines)
        s = start if start < n_sp else n_sp
        e = end if end < n_sp else n_sp
        for li in range(s, e):
            if self.spell_lines[li]:
                return 2
        for li in range(ds, de):
            if self.diagnostic_lines[li] == DIAG_SEVERITY_INFO:
                return 5
        for li in range(ds, de):
            if self.diagnostic_lines[li] == DIAG_SEVERITY_HINT:
                return 6
        return 0

    fn _minimap_first_marked_buf_row(self, start: Int, end: Int) -> Int:
        """First buffer row in ``[start, end)`` that carries a mark,
        in the same priority order as ``_minimap_kind_in_slice``.
        Returns ``-1`` when the slice has no marks."""
        var n_diag = len(self.diagnostic_lines)
        var ds = start if start < n_diag else n_diag
        var de = end if end < n_diag else n_diag
        for li in range(ds, de):
            if self.diagnostic_lines[li] == DIAG_SEVERITY_ERROR:
                return li
        for li in range(ds, de):
            if self.diagnostic_lines[li] == DIAG_SEVERITY_WARNING:
                return li
        var n_git = len(self.git_change_lines)
        var s = start if start < n_git else n_git
        var e = end if end < n_git else n_git
        for li in range(s, e):
            if self.git_change_lines[li] != GIT_CHANGE_NONE:
                return li
        var n_sp = len(self.spell_lines)
        s = start if start < n_sp else n_sp
        e = end if end < n_sp else n_sp
        for li in range(s, e):
            if self.spell_lines[li]:
                return li
        for li in range(ds, de):
            if self.diagnostic_lines[li] == DIAG_SEVERITY_INFO:
                return li
        for li in range(ds, de):
            if self.diagnostic_lines[li] == DIAG_SEVERITY_HINT:
                return li
        return -1

    fn _minimap_attr_for_slice(self, start: Int, end: Int) -> Optional[Attr]:
        """Source registry for the right-side projection — same priority
        order as ``_minimap_kind_in_slice``, returning the Attr to paint."""
        var kind = self._minimap_kind_in_slice(start, end)
        if kind == 1:
            return Optional[Attr](Attr(LIGHT_GRAY, BLUE))
        if kind == 2:
            return Optional[Attr](Attr(CYAN, BLUE))
        if kind == 3:
            return Optional[Attr](Attr(LIGHT_RED, BLUE))
        if kind == 4:
            return Optional[Attr](Attr(LIGHT_YELLOW, BLUE))
        if kind == 5:
            return Optional[Attr](Attr(LIGHT_BLUE, BLUE))
        if kind == 6:
            return Optional[Attr](Attr(DARK_GRAY, BLUE))
        return Optional[Attr]()

    fn _minimap_first_misspelled_word(self, row: Int) -> String:
        """The first misspelled word on ``row``, sliced from the buffer
        line using ``spell_highlights``. Empty string if none — callers
        fall back to a generic 'spelling issue' label."""
        for h in range(len(self.spell_highlights)):
            var hl = self.spell_highlights[h]
            if hl.row == row:
                var line = self.buffer.line(row)
                return _slice(line, hl.col_start, hl.col_end)
        return String("")

    fn _minimap_first_diagnostic_message(self, row: Int) -> String:
        """The first diagnostic message that intersects ``row``, with
        the source name prepended in brackets when present (so the user
        can distinguish "[pyright] …" from "[ruff] …" when both
        servers contribute). Empty string if no diagnostic covers that
        row."""
        for d in range(len(self.diagnostics)):
            var diag = self.diagnostics[d]
            if not _diag_intersects_row(diag, row):
                continue
            var msg = diag.message
            if len(diag.source.as_bytes()) > 0:
                msg = String("[") + diag.source + String("] ") + msg
            return msg^
        return String("")

    fn _is_minimap_hit(self, pos: Point, view: Rect) -> Bool:
        """True when ``pos`` lands on the minimap column for ``view``."""
        if not self.minimap_visible:
            return False
        if self._right_gutter() == 0:
            return False
        if pos.x != view.b.x - 1:
            return False
        var sy = pos.y - view.a.y
        if sy < 0 or sy >= view.height():
            return False
        return True

    fn clear_minimap_hover(mut self):
        self._minimap_hover_kind = 0
        self._minimap_hover_buf_row = -1
        self._minimap_hover_word = String("")
        self._minimap_hover_below = False

    fn _update_minimap_hover(mut self, pos: Point, view: Rect):
        """Refresh hover-tooltip state from a mouse position.

        Two hit surfaces, in order:
        1. The right-edge minimap column — kind/buf_row/label come from
           the projection (existing behavior).
        2. The text area itself — if the cursor sits on a cell covered
           by a diagnostic span or a spell-highlight underline, surface
           the same tooltip we'd show for a minimap mark of that kind,
           anchored at the cursor's screen position.

        Anything else (gutters, blank space past EOL, plain text) clears
        the hover state. The tooltip-paint code reads these fields in
        both cases, so the user gets one consistent visual."""
        self.clear_minimap_hover()
        if self._is_minimap_hit(pos, view):
            self._update_minimap_hover_from_minimap(pos, view)
            return
        self._update_minimap_hover_from_text_area(pos, view)

    fn _update_minimap_hover_from_minimap(
        mut self, pos: Point, view: Rect,
    ):
        """Minimap-column branch of ``_update_minimap_hover``."""
        var sy = pos.y - view.a.y
        var rng = self._minimap_buf_range_for_screen_row(sy, view.height())
        var kind = self._minimap_kind_in_slice(rng[0], rng[1])
        if kind == 0:
            return
        var buf_row = self._minimap_first_marked_buf_row(rng[0], rng[1])
        if buf_row < 0:
            buf_row = rng[0]
        self._minimap_hover_kind = kind
        self._minimap_hover_buf_row = buf_row
        self._minimap_hover_x = pos.x
        self._minimap_hover_y = pos.y
        if kind == 2:
            self._minimap_hover_word = self._minimap_first_misspelled_word(
                buf_row
            )
        elif kind == 3 or kind == 4 or kind == 5 or kind == 6:
            self._minimap_hover_word = self._minimap_first_diagnostic_message(
                buf_row,
            )

    fn _update_minimap_hover_from_text_area(
        mut self, pos: Point, view: Rect,
    ):
        """Text-area branch of ``_update_minimap_hover``: hit-test the
        cursor against per-cell diagnostic ranges and spell highlights,
        and (when something hits) anchor the tooltip immediately below
        the underlined span with the box's left edge aligned to the
        leftmost cell of the underline.

        Diagnostic ranges win over spell when both cover the same cell —
        a real warning is more important to surface than a misspelling
        in a comment. Within diagnostics, lower numeric severity wins
        (error > warning > info > hint) so the most actionable popup
        gets shown when ranges overlap.
        """
        var resolved = self._resolve_text_area_buf_pos(pos, view)
        if not resolved:
            return
        var rc = resolved.value()
        var row = rc[0]
        var byte_col = rc[1]
        var seg_byte_start = rc[2]
        var seg_byte_end = rc[3]
        var seg_x0 = rc[4]
        # Diagnostic hit test. Pick the lowest-severity-numbered (most
        # severe) match on this cell so an error squiggle isn't masked
        # by an info hint that happens to overlap it.
        var best_diag_idx = -1
        var best_diag_sev = 0
        for d in range(len(self.diagnostics)):
            var diag = self.diagnostics[d]
            if not _diag_covers_cell(diag, row, byte_col):
                continue
            if best_diag_idx < 0 or diag.severity < best_diag_sev:
                best_diag_idx = d
                best_diag_sev = diag.severity
        if best_diag_idx >= 0:
            var diag = self.diagnostics[best_diag_idx]
            var kind = _diag_severity_to_minimap_kind(diag.severity)
            var span_start = _diag_byte_start_for_row(diag, row)
            self._set_text_hover_anchor(
                row, span_start, seg_byte_start, seg_byte_end, seg_x0,
                pos.y,
            )
            self._minimap_hover_kind = kind
            self._minimap_hover_buf_row = row
            var label = diag.message
            if len(diag.source.as_bytes()) > 0:
                label = String("[") + diag.source + String("] ") + label
            self._minimap_hover_word = label^
            return
        # Spell hit test. Spell highlights are stored as
        # ``Highlight(row, col_start, col_end, attr)`` so the same
        # byte-range cover check works.
        for h in range(len(self.spell_highlights)):
            var sh = self.spell_highlights[h]
            if sh.row != row:
                continue
            if byte_col < sh.col_start or byte_col >= sh.col_end:
                continue
            self._set_text_hover_anchor(
                row, sh.col_start, seg_byte_start, seg_byte_end, seg_x0,
                pos.y,
            )
            self._minimap_hover_kind = 2
            self._minimap_hover_buf_row = row
            self._minimap_hover_word = _slice(
                self.buffer.line(row), sh.col_start, sh.col_end,
            )
            return

    fn _set_text_hover_anchor(
        mut self, row: Int, span_start: Int,
        seg_byte_start: Int, seg_byte_end: Int, seg_x0: Int,
        screen_y: Int,
    ):
        """Compute and store the tooltip anchor for an in-text hover.

        The tooltip's top-left should land at the leftmost cell of the
        underlined span on this visual segment, one row below the
        underline. ``span_start`` is the diagnostic / spell highlight's
        leftmost byte on this buffer row; if it sits before the visible
        segment (e.g. the underline starts on a previous wrapped line),
        clamp to ``seg_byte_start`` so the tooltip still aligns to
        whatever is on screen rather than scrolling out of view."""
        var line = self.buffer.line(row)
        var line_n = len(line.as_bytes())
        var byte_in_seg: Int
        if span_start < seg_byte_start:
            byte_in_seg = 0
        else:
            byte_in_seg = span_start - seg_byte_start
        var visible: String
        if seg_byte_start >= line_n:
            visible = String("")
        else:
            var clip_end = seg_byte_end
            if clip_end > line_n:
                clip_end = line_n
            visible = _slice(line, seg_byte_start, clip_end)
        var cell_off = _utf8_cell_of_byte(visible, byte_in_seg)
        self._minimap_hover_x = seg_x0 + cell_off
        self._minimap_hover_y = screen_y + 1
        self._minimap_hover_below = True

    fn _resolve_text_area_buf_pos(
        self, pos: Point, view: Rect,
    ) -> Optional[Tuple[Int, Int, Int, Int, Int]]:
        """Map a screen position onto buffer + segment info if it lands
        inside the editor's text area. Returns
        ``(buf_row, byte_col, seg_byte_start, seg_byte_end, seg_x0)``
        — enough to convert any other byte position on the same visual
        segment back to its screen x via ``_utf8_cell_of_byte``, which
        is what the hover path needs to anchor its tooltip to the
        leftmost cell of an underlined span.

        Returns ``None`` for the gutters, the right-side minimap
        column, positions outside the view, and positions past the end
        of the visible content row. Past-EOL hovers are reported as
        ``None`` rather than clamping so a tooltip doesn't fire on
        blank space whose 'nearest' diagnostic might be far away."""
        var miss = Optional[Tuple[Int, Int, Int, Int, Int]]()
        if not view.contains(pos):
            return miss
        var total_gutter = self._total_gutter()
        var right_gutter = self._right_gutter()
        var rel_x = pos.x - view.a.x
        if total_gutter > 0 and rel_x < total_gutter:
            return miss
        if right_gutter > 0 and pos.x >= view.b.x - right_gutter:
            return miss
        var content_h = view.height()
        var content_w = view.width() - total_gutter - right_gutter
        if content_w < 1:
            return miss
        var layout = self._layout_lines(content_h, content_w)
        var screen_row = pos.y - view.a.y
        if screen_row < 0 or screen_row >= len(layout):
            return miss
        var row = layout[screen_row].line_idx
        var seg_start = layout[screen_row].byte_start
        var seg_end = layout[screen_row].byte_end
        var seg_indent = layout[screen_row].indent_cells
        var seg_x0 = view.a.x + total_gutter + seg_indent
        var cell_x = rel_x - total_gutter - seg_indent
        if cell_x < 0:
            return miss
        var line = self.buffer.line(row)
        var line_n = len(line.as_bytes())
        var visible: String
        if seg_start >= line_n:
            visible = String("")
        else:
            visible = _slice(line, seg_start, seg_end)
        var visible_cells = utf8_codepoint_count(visible)
        if cell_x >= visible_cells:
            return miss
        var col = seg_start + _utf8_byte_of_cell(visible, cell_x)
        if col > line_n:
            col = line_n
        return Optional[Tuple[Int, Int, Int, Int, Int]](
            (row, col, seg_start, seg_end, seg_x0)
        )

    fn _try_minimap_click(mut self, pos: Point, view: Rect) -> Bool:
        """Handle a left-click on the minimap column: scroll the editor
        so the corresponding buffer row is centered, and place the cursor
        on that row. For rows flagged by the speller, the cursor lands
        on the first misspelled word so spell-fix actions (Alt+Enter)
        work immediately; otherwise it lands at column 0. Returns True
        if the click was on the minimap (and was therefore consumed)."""
        if not self._is_minimap_hit(pos, view):
            return False
        var sy = pos.y - view.a.y
        var content_h = view.height()
        var rng = self._minimap_buf_range_for_screen_row(sy, content_h)
        if rng[0] >= rng[1]:
            return False
        var kind = self._minimap_kind_in_slice(rng[0], rng[1])
        var buf_row = self._minimap_first_marked_buf_row(rng[0], rng[1])
        if buf_row < 0:
            buf_row = rng[0]
        var n_lines = self.buffer.line_count()
        if buf_row >= n_lines:
            buf_row = n_lines - 1
        if buf_row < 0:
            buf_row = 0
        var col = 0
        if kind == 2:
            for h in range(len(self.spell_highlights)):
                var hl = self.spell_highlights[h]
                if hl.row == buf_row:
                    col = hl.col_end
                    break
        elif kind == 3 or kind == 4 or kind == 5 or kind == 6:
            for d in range(len(self.diagnostics)):
                var diag = self.diagnostics[d]
                if not _diag_intersects_row(diag, buf_row):
                    continue
                col = _diag_byte_start_for_row(diag, buf_row)
                break
        self.move_to(buf_row, col, False)
        var target = buf_row - content_h // 2
        var max_y = n_lines - content_h
        if max_y < 0:
            max_y = 0
        if target < 0:
            target = 0
        if target > max_y:
            target = max_y
        self.scroll_y = target
        return True

    fn _paint_completion_popup_at(
        self, mut canvas: Canvas, view: Rect, anchor_x: Int, anchor_y: Int,
    ):
        """Render the completion popup anchored at the start of the
        identifier being completed (``anchor_x`` / ``anchor_y`` are
        screen cells). Floats one row below the anchor when there's
        room, flips above when not. The width fits the longest visible
        label plus a right-aligned kind column that's sized for the
        longest visible kind name, clamped to
        ``[_COMPLETION_POPUP_WIDTH_MIN, _COMPLETION_POPUP_WIDTH_MAX]``.
        """
        var n_items = len(self.completion_items)
        if n_items == 0:
            return
        var visible_rows = n_items
        if visible_rows > _COMPLETION_POPUP_ROWS:
            visible_rows = _COMPLETION_POPUP_ROWS
        var height = visible_rows
        # Scan visible items to size both columns. Label column grows
        # to the longest *visible* label so a single huge entry far
        # offscreen doesn't bloat the popup; the kind column grows to
        # the longest visible kind name and stays empty (width 0) if
        # nothing has a known kind.
        var longest_label = 0
        var longest_kind = 0
        var first = self.completion_scroll
        var last = first + visible_rows
        if last > n_items:
            last = n_items
        for i in range(first, last):
            var lw = len(self.completion_items[i].label.as_bytes())
            if lw > longest_label:
                longest_label = lw
            var kw = len(_completion_kind_name(
                self.completion_items[i].kind
            ).as_bytes())
            if kw > longest_kind:
                longest_kind = kw
        # Kind column = [1 dark-gray pad][name][1 dark-gray pad]. The
        # internal padding shares the kind stripe's background so the
        # stripe reads as a self-contained chip. The cell of popup-bg
        # padding sitting between the label and the kind stripe is
        # *outside* this column and gets overpainted by the selection
        # bg on the highlighted row.
        var kind_col_w = longest_kind + 2 if longest_kind > 0 else 0
        # Natural width before clamps:
        #   [1 left pad][label][1 pad before kind][kind column]  with kind
        #   [1 left pad][label][1 right pad]                     no kind
        var width: Int
        if kind_col_w > 0:
            width = longest_label + kind_col_w + 2
        else:
            width = longest_label + 2
        if width < _COMPLETION_POPUP_WIDTH_MIN:
            width = _COMPLETION_POPUP_WIDTH_MIN
        if width > _COMPLETION_POPUP_WIDTH_MAX:
            width = _COMPLETION_POPUP_WIDTH_MAX
        var x = anchor_x
        if x + width > view.b.x:
            x = view.b.x - width
            if x < view.a.x:
                x = view.a.x
        # Prefer below the cursor row; flip above when it'd run off
        # the bottom of the editor's view.
        var y = anchor_y + 1
        if y + height > view.b.y:
            y = anchor_y - height
            if y < view.a.y:
                y = view.a.y
        # Final clamp horizontally + vertically — popup can't be
        # bigger than the view.
        if width > view.width():
            width = view.width()
        if height > view.height():
            height = view.height()
        if x + width > view.b.x:
            x = view.b.x - width
        if x < view.a.x:
            x = view.a.x
        if y + height > view.b.y:
            y = view.b.y - height
        if y < view.a.y:
            y = view.a.y
        var rect = Rect(x, y, x + width, y + height)
        var attr = Attr(BLACK, LIGHT_GRAY)
        var sel_attr = Attr(BLACK, LIGHT_GREEN)
        # The right-edge kind column gets its own background so the
        # kind name doesn't visually merge with the label text. It
        # stays the same colour across all rows (including the
        # selected one), forming a continuous stripe down the popup.
        var kind_attr = Attr(WHITE, DARK_GRAY)
        var pop_painter = Painter(rect)
        pop_painter.fill(canvas, rect, String(" "), attr)
        # Kind column hugs the right edge — no padding after it.
        # ``kind_col_left`` is the first cell of the dark-gray kind
        # stripe; the cell just left of it (``kind_col_left - 1``) is
        # the single-cell pad between label and kind, painted in the
        # popup bg by default and overpainted by the selection bg when
        # the row is highlighted.
        var kind_col_left: Int
        if kind_col_w > 0:
            kind_col_left = rect.b.x - kind_col_w
        else:
            kind_col_left = rect.b.x
        var label_left = rect.a.x + 1
        var label_right: Int
        if kind_col_w > 0:
            label_right = kind_col_left - 1
        else:
            label_right = rect.b.x - 1
        if label_right < label_left:
            label_right = label_left
        var label_w = label_right - label_left
        for r in range(visible_rows):
            var idx = self.completion_scroll + r
            if idx >= n_items:
                break
            var ty = rect.a.y + r
            var item = self.completion_items[idx]
            var is_hl = (idx == self.completion_highlight)
            var row_attr = sel_attr if is_hl else attr
            if is_hl:
                # Selection spans the left pad, label area, and the
                # pad-before-kind cell. When there's no kind column we
                # extend to the right pad so the whole row is green.
                var sel_right = kind_col_left if kind_col_w > 0 else rect.b.x
                pop_painter.fill(
                    canvas, Rect(rect.a.x, ty, sel_right, ty + 1),
                    String(" "), row_attr,
                )
            if kind_col_w > 0:
                pop_painter.fill(
                    canvas, Rect(kind_col_left, ty, rect.b.x, ty + 1),
                    String(" "), kind_attr,
                )
            var label = item.label
            var max_label = label_w
            if max_label < 1:
                max_label = 1
            var lb = label.as_bytes()
            if len(lb) > max_label:
                if max_label >= 1:
                    label = String(StringSlice(
                        unsafe_from_utf8=lb[0:max_label - 1],
                    )) + String("…")
                else:
                    label = String("…")
            _ = pop_painter.put_text(
                canvas, Point(label_left, ty),
                label, row_attr,
            )
            if kind_col_w > 0:
                _ = pop_painter.put_text(
                    canvas, Point(kind_col_left + 1, ty),
                    _completion_kind_name(item.kind), kind_attr,
                )

    fn paint_minimap_tooltip(
        self, mut canvas: Canvas, view: Rect,
    ):
        """Render the hover tooltip for the right-side minimap. Called
        after the editor's main paint pass so it overlays the text.

        Built on the framework's standard popup chrome — drop shadow,
        boxed border, light-gray background, soft-wrapped body text —
        so a long diagnostic message wraps inside the box instead of
        bleeding past its right edge."""
        if self._minimap_hover_kind == 0:
            return
        var label: String
        if self._minimap_hover_kind == 1:
            label = String("Modified line ") \
                + String(self._minimap_hover_buf_row + 1)
        elif self._minimap_hover_kind == 2:
            if len(self._minimap_hover_word.as_bytes()) > 0:
                label = String("Suspected spelling error: ") \
                    + self._minimap_hover_word
            else:
                label = String("Suspected spelling error on line ") \
                    + String(self._minimap_hover_buf_row + 1)
        elif self._minimap_hover_kind == 3 \
                or self._minimap_hover_kind == 4 \
                or self._minimap_hover_kind == 5 \
                or self._minimap_hover_kind == 6:
            var prefix: String
            if self._minimap_hover_kind == 3:
                prefix = String("Error: ")
            elif self._minimap_hover_kind == 4:
                prefix = String("Warning: ")
            elif self._minimap_hover_kind == 5:
                prefix = String("Info: ")
            else:
                prefix = String("Hint: ")
            if len(self._minimap_hover_word.as_bytes()) > 0:
                label = prefix + self._minimap_hover_word
            else:
                label = prefix + String("line ") \
                    + String(self._minimap_hover_buf_row + 1)
        else:
            return
        # Reserve 2 cells on the right of ``view`` for the drop-shadow
        # strip so the shadow doesn't bleed past the editor area when
        # the popup is anchored near the right edge.
        var max_box_w = view.width() - 2
        if max_box_w < 5:
            max_box_w = view.width()
        var size = popup_size_for_text(label, max_box_w, view.height())
        var w = size[0]
        var h = size[1]
        if w == 0 or h == 0:
            return
        # Two anchor modes, selected by ``_minimap_hover_below``:
        #
        # * Text-area hover (below=True): tooltip top-left is the
        #   anchor — the leftmost cell of the underlined span on the
        #   row immediately below the underline. Falls back upward
        #   (above the underline) when there's no room below; clamps
        #   horizontally so the box always fits within ``view``.
        # * Minimap hover (below=False): tooltip is anchored *above
        #   and to the left of* the cursor — preserves the original
        #   right-edge minimap behavior so the popup floats away from
        #   the cursor toward the text body.
        var bx: Int
        var by: Int
        if self._minimap_hover_below:
            bx = self._minimap_hover_x
            by = self._minimap_hover_y
            # No room below? Flip above the underline. The underline
            # itself sits at hover_y - 1, so the tooltip's bottom must
            # land at hover_y - 2 (one row of padding above the line).
            if by + h > view.b.y:
                by = self._minimap_hover_y - 1 - h
            if by < view.a.y:
                by = view.a.y
            if bx + w > view.b.x:
                bx = view.b.x - w
            if bx < view.a.x:
                bx = view.a.x
        else:
            bx = self._minimap_hover_x - w
            if bx < view.a.x:
                bx = view.a.x
            if bx + w > view.b.x:
                bx = view.b.x - w
            by = self._minimap_hover_y - 1
            if by < view.a.y:
                by = view.a.y
            if by + h > view.b.y:
                by = view.b.y - h
        var r = Rect(bx, by, bx + w, by + h)
        var attr = Attr(BLACK, LIGHT_GRAY)
        # Drop shadow first (compositing under ``r``), then the box
        # itself: fill bg, draw border, soft-wrap body text inside the
        # 1-cell padding ring. ``put_wrapped_text`` wraps to the
        # interior width and clips to its rect, so the message can't
        # overflow the popup.
        paint_drop_shadow(canvas, r)
        var tt_painter = Painter(r)
        tt_painter.fill(canvas, r, String(" "), attr)
        tt_painter.draw_box(canvas, r, attr, False)
        var msg_rect = Rect(
            r.a.x + 2, r.a.y + 1,
            r.b.x - 2, r.b.y - 1,
        )
        if msg_rect.width() > 0 and msg_rect.height() > 0:
            _ = canvas.put_wrapped_text(msg_rect, label, attr)

    fn _paint_right_gutter(
        self, mut canvas: Canvas, painter: Painter,
        view: Rect, content_h: Int,
    ):
        """Paint the right-edge minimap column. Each screen row owns an
        evenly-sized slice of buffer rows; for that slice we ask
        ``_minimap_attr_for_slice`` which (if any) source has a hit and
        paint a square in that color. When the file fits in
        ``content_h`` rows the slices collapse to one buffer row each,
        so the projection lines up cell-for-cell with the text."""
        var n_lines = self._minimap_total_lines()
        if n_lines == 0:
            return
        var rows = content_h
        if rows < 1:
            rows = 1
        for sy in range(rows):
            var rng = self._minimap_buf_range_for_screen_row(sy, content_h)
            if rng[0] >= n_lines:
                break
            if rng[0] >= rng[1]:
                continue
            var attr_opt = self._minimap_attr_for_slice(rng[0], rng[1])
            if attr_opt:
                painter.set(
                    canvas, view.b.x - 1, view.a.y + sy,
                    Cell(String("■"), attr_opt.value(), 1),
                )

    fn _total_gutter(self) -> Int:
        return self.gutter_width + self._line_number_gutter() \
            + self._git_changes_gutter() + self._blame_gutter()

    fn _layout_lines(
        self, content_h: Int, text_width: Int,
    ) -> List[VisualLine]:
        """Per-screen-row visual layout for the painted window.

        Soft-wrap on: delegates to ``text_view.wrap_lines`` with the
        editor's word-aware / hanging-indent options enabled. The same
        primitive the DebugPane uses with indent_size=0.

        Soft-wrap off: synthesizes one ``VisualLine`` per visible
        buffer row covering ``[scroll_x, line_length)`` — preserves
        the editor's horizontal-scroll semantics (``scroll_x``) which
        the shared wrap primitive doesn't model.
        """
        # Clamp ``content_h`` to non-negative. ``wrap_lines`` reads
        # negative values as "unbounded" (the DebugPane idiom) and
        # would otherwise wrap the entire buffer when callers pass
        # ``view.height()`` of an empty / collapsed view.
        var max_rows = content_h
        if max_rows < 0:
            max_rows = 0
        var n_lines = self.buffer.line_count()
        var br = self.scroll_y
        if not self.soft_wrap:
            var out = List[VisualLine]()
            while br < n_lines and len(out) < max_rows:
                var n = self.buffer.line_length(br)
                out.append(VisualLine(br, self.scroll_x, n, 0, 0, 0))
                br += 1
            return out^
        var w = text_width
        if w < 1:
            w = 1
        var tab = self.editorconfig.effective_indent_size()
        if tab < 1:
            tab = 4
        return wrap_lines(
            self.buffer.lines, w,
            indent_size=tab, word_aware=True,
            start_line=self.scroll_y, max_rows=max_rows,
        )

    fn _cursor_screen_row(
        self, layout: List[VisualLine],
    ) -> Int:
        """Convenience wrapper around ``_screen_row_for`` that uses the
        primary caret. Kept as a separate symbol because it's also
        called from ``_scroll_to_cursor`` and ``reveal_cursor``."""
        return self._screen_row_for(layout, self.cursor_row, self.cursor_col)

    fn _paint_one_caret(
        self, mut canvas: Canvas, painter: Painter, view: Rect,
        layout: List[VisualLine],
        text_x0: Int, content_right: Int, content_bottom: Int,
        row: Int, col: Int,
    ):
        """Paint a single caret block at buffer position ``(row, col)``.
        Identical visual to the original primary-caret block; called
        once per caret from ``paint``. Out-of-view carets are skipped."""
        var sr = self._screen_row_for(layout, row, col)
        if sr < 0:
            return
        var seg_start = layout[sr].byte_start
        var seg_end = layout[sr].byte_end
        var indent = layout[sr].indent_cells
        var seg_x0 = text_x0 + indent
        var line = self.buffer.line(row)
        var line_byte_count = len(line.as_bytes())
        var visible_str: String
        if seg_start >= line_byte_count:
            visible_str = String("")
        else:
            visible_str = _slice(line, seg_start, seg_end)
        var cursor_cell_map = utf8_byte_to_cell(visible_str)
        var cursor_cell_count = utf8_codepoint_count(visible_str)
        var visible_byte_count = len(visible_str.as_bytes())
        var cursor_byte = col - seg_start
        var cell_offset: Int
        if cursor_byte < 0:
            cell_offset = 0
        elif cursor_byte < visible_byte_count:
            cell_offset = cursor_cell_map[cursor_byte]
        else:
            cell_offset = cursor_cell_count + (cursor_byte - visible_byte_count)
        var sx = seg_x0 + cell_offset
        var sy = view.a.y + sr
        if not (seg_x0 <= sx and sx < content_right
                and view.a.y <= sy and sy < content_bottom):
            return
        if col < line_byte_count:
            painter.set_attr(canvas, sx, sy, Attr(BLUE, YELLOW))
        else:
            painter.set(canvas, sx, sy, Cell(String(" "), Attr(BLUE, YELLOW), 1))

    fn _screen_row_for(
        self, layout: List[VisualLine],
        row: Int, col: Int,
    ) -> Int:
        """Index into ``layout`` of the screen row that hosts the caret
        at ``(row, col)``, or -1 if it lies outside the painted layout.
        The caret sits on a buffer-row segment when its byte column
        falls in the segment's range; ties at the segment boundary go
        to the *next* segment (so a caret parked at a wrap point shows
        up at the start of the next visual line, matching most
        editors)."""
        for sr in range(len(layout)):
            var br = layout[sr].line_idx
            if br != row:
                continue
            var sb = layout[sr].byte_start
            var eb = layout[sr].byte_end
            var is_last = (sr + 1 >= len(layout)) or (
                layout[sr + 1].line_idx != row
            )
            if col < sb:
                continue
            if col < eb:
                return sr
            if is_last:
                return sr
        return -1

    # --- painting ----------------------------------------------------------

    fn paint(self, mut canvas: Canvas, view: Rect, focused: Bool):
        # Nothing to draw when the host workspace has collapsed (e.g.
        # the debug pane is maximized and the editor area shrinks to
        # zero or negative height). Without this early return,
        # ``content_h = view.height()`` becomes negative, and the
        # negative value sails past ``wrap_lines``'s ``max_rows >= 0``
        # gate to walk the entire buffer every frame — ~200 ms on a
        # large file, enough to peg the main loop at 100 % CPU.
        if view.is_empty():
            return
        # Default text: LIGHT_GREEN on BLUE — identifiers / variables
        # are the bulk of "unhighlighted" tokens in code, so this is
        # what every scope-less span lands as. Keywords / strings /
        # comments / numbers / operators paint over this via the
        # highlight overlay; ``YELLOW`` stays reserved for tokens
        # that *want* to stand out against the green baseline (e.g.
        # the exec-line marker in the gutter, dirty-buffer asterisk,
        # selection inversion below).
        var attr = Attr(LIGHT_GREEN, BLUE)
        var sel_attr = Attr(LIGHT_GREEN, CYAN)
        # Single Painter for the entire editor view. Every gutter,
        # text, caret, and overlay write below routes through it so an
        # over-long highlight or a stray cell write at the right edge
        # can't bleed into the neighbouring window's chrome.
        var painter = Painter(view)
        painter.fill(canvas, view, String(" "), attr)
        # Stacked left gutters: line-number gutter sits at the very
        # left (right-aligned, one trailing space), then the debugger
        # gutter (breakpoint dot and exec arrow, owned by Desktop),
        # then the git-changes column, then the optional blame gutter
        # ("<sha> <author>"). Any of them can be zero-width.
        var dap_gutter = self.gutter_width
        var ln_gutter = self._line_number_gutter()
        var gc_gutter = self._git_changes_gutter()
        var bl_gutter = self._blame_gutter()
        var right_gutter = self._right_gutter()
        var total_gutter = dap_gutter + ln_gutter + gc_gutter + bl_gutter
        var text_x0 = view.a.x + total_gutter
        var content_right = view.b.x - right_gutter
        var content_bottom = view.b.y
        var content_h = view.height()
        var content_w = view.width() - total_gutter - right_gutter
        if content_w < 1:
            content_w = 1
        # Layout drives every per-screen-row decision below: with soft-
        # wrap off it's a 1:1 mapping (one tuple per buffer row from
        # ``scroll_y``); with soft-wrap on each buffer row produces one
        # tuple per visual segment.
        var layout = self._layout_lines(content_h, content_w)
        # Gutter pass — debugger markers + line numbers, both painted
        # before the text overlay so they aren't clobbered downstream.
        # Markers / line numbers are only stamped on the *first* visual
        # segment of each buffer row (start_byte == 0 in the segment, AND
        # this segment isn't a continuation row produced by soft-wrap).
        if total_gutter > 0:
            var gutter_attr = Attr(LIGHT_GRAY, BLUE)
            var bp_attr = Attr(LIGHT_RED, BLUE)
            var exec_attr = Attr(LIGHT_YELLOW, BLUE)
            var ln_attr = Attr(DARK_GRAY, BLUE)
            for screen_row in range(len(layout)):
                var buf_row = layout[screen_row].line_idx
                var seg_start = layout[screen_row].byte_start
                var sy_g = view.a.y + screen_row
                for gx in range(total_gutter):
                    painter.set(
                        canvas, view.a.x + gx, sy_g,
                        Cell(String(" "), gutter_attr, 1),
                    )
                # Each layout entry is the *first* visual segment of its
                # buffer row when either soft-wrap is off (one segment per
                # row) or this segment starts at byte 0 of the row.
                var is_first_seg = (not self.soft_wrap) or (seg_start == 0)
                if ln_gutter > 0 and is_first_seg:
                    var num_str = String(buf_row + 1)
                    var num_w = len(num_str.as_bytes())
                    # Right-align inside the line-number gutter, leaving
                    # the trailing column as a one-cell separator.
                    var sx = view.a.x + (ln_gutter - 1) - num_w
                    if sx < view.a.x:
                        sx = view.a.x
                    _ = painter.put_text(
                        canvas, Point(sx, sy_g), num_str, ln_attr,
                    )
                if dap_gutter > 0 and is_first_seg:
                    for k in range(len(self.breakpoint_lines)):
                        if self.breakpoint_lines[k] == buf_row:
                            # Per-row colour:
                            #   * disabled BP   → DARK_GRAY (parked)
                            #   * conditional   → LIGHT_YELLOW (gates on expression)
                            #   * otherwise     → LIGHT_RED (default firing BP)
                            # The two metadata lists are populated in
                            # lockstep with ``breakpoint_lines`` by the
                            # Desktop's ``dap_tick``; a length mismatch
                            # falls back to the plain red default.
                            var dot_attr = bp_attr
                            if k < len(self.breakpoint_enabled) \
                                    and not self.breakpoint_enabled[k]:
                                dot_attr = Attr(DARK_GRAY, BLUE)
                            elif k < len(self.breakpoint_conditional) \
                                    and self.breakpoint_conditional[k]:
                                dot_attr = Attr(LIGHT_YELLOW, BLUE)
                            painter.set(
                                canvas, view.a.x + ln_gutter, sy_g,
                                Cell(String("●"), dot_attr, 1),
                            )
                            break
                    if buf_row == self.exec_line:
                        var ax = view.a.x + ln_gutter \
                            + (1 if dap_gutter >= 2 else 0)
                        painter.set(canvas, ax, sy_g, Cell(String("▶"), exec_attr, 1))
                if gc_gutter > 0 and is_first_seg \
                        and buf_row < len(self.git_change_lines):
                    var status = self.git_change_lines[buf_row]
                    if status != GIT_CHANGE_NONE:
                        var bar_attr = Attr(LIGHT_GRAY, BLUE)
                        var gx = view.a.x + ln_gutter + dap_gutter
                        painter.set(canvas, gx, sy_g, Cell(String("│"), bar_attr, 1))
                if bl_gutter > 0 and is_first_seg \
                        and buf_row < len(self.blame_lines):
                    var bl = self.blame_lines[buf_row]
                    var bx = view.a.x + ln_gutter + dap_gutter + gc_gutter
                    # Blame columns: clip to ``[bx, bx + bl_gutter)``
                    # via a sub-painter so a long author/commit can't
                    # bleed into the source text column.
                    var bl_p = painter.sub(
                        Rect(bx, sy_g, bx + bl_gutter, sy_g + 1),
                    )
                    _ = bl_p.put_text(
                        canvas, Point(bx, sy_g), bl.commit, ln_attr,
                    )
                    var ax = bx + 8 + 1
                    _ = bl_p.put_text(
                        canvas, Point(ax, sy_g), bl.author, ln_attr,
                    )
        # Right-side gutter: a fixed-height projection of the whole
        # file, independent of ``scroll_y``. ``_paint_right_gutter``
        # handles slicing + per-source priority — see
        # ``_minimap_attr_for_slice`` for the source registry.
        if right_gutter > 0:
            self._paint_right_gutter(canvas, painter, view, content_h)
        # Text pass — single-source via ``paint_text_segments`` (used
        # by ``TextLog`` too). ``layout`` already accounts for
        # ``indent_cells``; the helper offsets each row's segment
        # accordingly.
        var text_view = Rect(text_x0, view.a.y, content_right, content_bottom)
        paint_text_segments(
            canvas, text_view, self.buffer.lines, layout,
            0, len(layout), List[Attr](), attr,
        )
        # Per-row overlay loop. Highlights and spell-check sit
        # between text and selection, so the visual order is text →
        # syntax → spell → selection → cursor. ``visible_cell_map``
        # is per-row state these overlays need; selection moved out
        # to a separate pass below.
        var all_carets_paint = self._all_carets_asc()
        for screen_row in range(len(layout)):
            var buf_row = layout[screen_row].line_idx
            var start_byte = layout[screen_row].byte_start
            var end_byte = layout[screen_row].byte_end
            var indent_cells = layout[screen_row].indent_cells
            var seg_x0 = text_x0 + indent_cells
            var line = self.buffer.line(buf_row)
            var n = len(line.as_bytes())
            var visible: String
            if start_byte >= n:
                visible = String("")
            else:
                visible = _slice(line, start_byte, end_byte)
            var visible_cell_map = utf8_byte_to_cell(visible)
            var visible_byte_count = len(visible.as_bytes())
            var visible_cell_count = utf8_codepoint_count(visible)
            var sy_hl = view.a.y + screen_row
            # Syntax-highlight overlay: change the attr on cells covered by
            # any highlight that targets this buffer row. Glyphs come from
            # ``paint_text_segments`` above; we only adjust attributes here.
            for h in range(len(self.highlights)):
                var hl = self.highlights[h]
                if hl.row != buf_row:
                    continue
                var hl_byte_start = hl.col_start - start_byte
                var hl_byte_end = hl.col_end - start_byte
                if hl_byte_start < 0:
                    hl_byte_start = 0
                if hl_byte_end > visible_byte_count:
                    hl_byte_end = visible_byte_count
                if hl_byte_start >= hl_byte_end:
                    continue
                # Walk by codepoint via the cell map: each new cell column
                # we hit gets recoloured exactly once even though several
                # bytes feed into it.
                var hl_cell_start = visible_cell_map[hl_byte_start]
                var hl_cell_end: Int
                if hl_byte_end < visible_byte_count:
                    hl_cell_end = visible_cell_map[hl_byte_end]
                else:
                    hl_cell_end = visible_cell_count
                for cell_off in range(hl_cell_start, hl_cell_end):
                    var sx_hl = seg_x0 + cell_off
                    if sx_hl >= content_right:
                        break
                    painter.set_attr(canvas, sx_hl, sy_hl, hl.attr)
            # Spell-check overlay: same byte-to-cell mapping as the
            # syntax pass above, but reapplies the *same* fg/bg with
            # ``STYLE_UNDERLINE`` ORed in. Painted after the syntax
            # pass so the underline lands on the comment/string color
            # rather than getting flattened back to plain text.
            for h in range(len(self.spell_highlights)):
                var sh = self.spell_highlights[h]
                if sh.row != buf_row:
                    continue
                var sh_byte_start = sh.col_start - start_byte
                var sh_byte_end = sh.col_end - start_byte
                if sh_byte_start < 0:
                    sh_byte_start = 0
                if sh_byte_end > visible_byte_count:
                    sh_byte_end = visible_byte_count
                if sh_byte_start >= sh_byte_end:
                    continue
                var sh_cell_start = visible_cell_map[sh_byte_start]
                var sh_cell_end: Int
                if sh_byte_end < visible_byte_count:
                    sh_cell_end = visible_cell_map[sh_byte_end]
                else:
                    sh_cell_end = visible_cell_count
                for cell_off in range(sh_cell_start, sh_cell_end):
                    var sx_sh = seg_x0 + cell_off
                    if sx_sh >= content_right:
                        break
                    painter.set_attr(canvas, sx_sh, sy_hl, sh.attr)
            # Diagnostic overlay: third underline pass. Unlike spell —
            # which already knows the host attr from the syntax
            # highlight it sits on — diagnostics can land anywhere
            # (operators, identifiers, even whitespace), so we read
            # the existing cell attr, OR in the underline + set the
            # underline_color, and write back. That preserves the
            # syntax color underneath while making severity readable
            # via the squiggle color.
            var diag_extended = terminal_supports_extended_underline()
            for d in range(len(self.diagnostics)):
                var diag = self.diagnostics[d]
                if not _diag_intersects_row(diag, buf_row):
                    continue
                var d_lo = _diag_byte_start_for_row(diag, buf_row)
                var d_hi = _diag_byte_end_for_row(
                    diag, buf_row, len(line.as_bytes()),
                )
                var d_byte_start = d_lo - start_byte
                var d_byte_end = d_hi - start_byte
                if d_byte_start < 0:
                    d_byte_start = 0
                if d_byte_end > visible_byte_count:
                    d_byte_end = visible_byte_count
                if d_byte_start >= d_byte_end:
                    continue
                var d_cell_start = visible_cell_map[d_byte_start]
                var d_cell_end: Int
                if d_byte_end < visible_byte_count:
                    d_cell_end = visible_cell_map[d_byte_end]
                else:
                    d_cell_end = visible_cell_count
                var underline_color = _diag_underline_color(diag.severity)
                var add_style: UInt8
                if diag_extended:
                    add_style = STYLE_UNDERLINE | STYLE_UNDERLINE_CURLY
                else:
                    add_style = STYLE_UNDERLINE
                for cell_off in range(d_cell_start, d_cell_end):
                    var sx_d = seg_x0 + cell_off
                    if sx_d >= content_right:
                        break
                    var existing = canvas.get(sx_d, sy_hl).attr
                    var new_attr = existing.add_style(add_style) \
                        .with_underline_color(Int16(underline_color))
                    if not diag_extended:
                        # Legacy underline picks up the foreground
                        # color, so override fg to make the severity
                        # visible on its own.
                        new_attr = new_attr.with_fg(underline_color)
                    painter.set_attr(canvas, sx_d, sy_hl, new_attr)
        # Selection pass — one ``paint_selection_overlay`` call per
        # caret with a non-empty selection. ``extend_past_eol`` opts
        # into the editor's "show the trailing newline" UX, so empty
        # rows in the middle of a multi-line selection still paint a
        # one-cell marker.
        for ci in range(len(all_carets_paint)):
            var c = all_carets_paint[ci]
            if c.row == c.anchor_row and c.col == c.anchor_col:
                continue
            var caret_sel = Selection(
                True, False,
                c.anchor_row, c.anchor_col, c.row, c.col,
            )
            paint_selection_overlay(
                canvas, text_view, self.buffer.lines, layout,
                0, len(layout), caret_sel, sel_attr,
                extend_past_eol=True,
            )
        # Cursor block: a reverse-video cell on every caret position
        # when the editor is focused. The primary and any extras paint
        # identically — the user reads "this line is the focus" from
        # the cursor's color, not from any difference between primary
        # and secondary carets.
        if focused:
            for ci in range(len(all_carets_paint)):
                var c = all_carets_paint[ci]
                self._paint_one_caret(
                    canvas, painter, view, layout, text_x0,
                    content_right, content_bottom,
                    c.row, c.col,
                )
        # Paint the right-side minimap tooltip last so it overlays
        # everything else in the editor's view. The hover state is set
        # by ``_update_minimap_hover`` on bare-hover events; when no
        # mark is hovered this is a no-op.
        self.paint_minimap_tooltip(canvas, view)
        # Completion popup: floats just below (or above) the column
        # where the in-progress identifier starts. Painted last so it
        # overlays both the text and the minimap tooltip. ``focused``
        # gates it — when the user clicked away the popup gets
        # painted by whichever editor is focused now (none, in this
        # case) rather than the stale frame.
        if focused and self.completion_popup_visible \
                and len(self.completion_items) > 0:
            var sr = self._screen_row_for(
                layout, self.completion_anchor_row,
                self.completion_anchor_col,
            )
            if sr >= 0:
                var seg_start = layout[sr].byte_start
                var indent = layout[sr].indent_cells
                var seg_x0 = text_x0 + indent
                var line = self.buffer.line(self.completion_anchor_row)
                var line_n = len(line.as_bytes())
                var vis: String
                if seg_start >= line_n:
                    vis = String("")
                else:
                    vis = _slice(line, seg_start, layout[sr].byte_end)
                var cm = utf8_byte_to_cell(vis)
                var cc = utf8_codepoint_count(vis)
                var vbc = len(vis.as_bytes())
                var anchor_byte = self.completion_anchor_col - seg_start
                var cell_off: Int
                if anchor_byte < 0:
                    cell_off = 0
                elif anchor_byte < vbc:
                    cell_off = cm[anchor_byte]
                else:
                    cell_off = cc + (anchor_byte - vbc)
                var sx = seg_x0 + cell_off
                var sy = view.a.y + sr
                self._paint_completion_popup_at(canvas, view, sx, sy)

    # --- multi-caret movement / inline-edit dispatchers -------------------

    fn _dispatch_move_one(
        mut self, kind: Int, extend: Bool, page_height: Int,
    ):
        """Single-caret movement step. ``kind`` selects the operation;
        the existing ``_move_*`` / ``move_to`` helpers each operate on
        the primary caret, so the multi-caret iterator can call this
        once per caret with the primary already swapped in."""
        if kind == 0:
            self._move_left(extend)
        elif kind == 1:
            self._move_right(extend)
        elif kind == 2:
            self._move_word_left(extend)
        elif kind == 3:
            self._move_word_right(extend)
        elif kind == 4:
            self._move_up(extend)
        elif kind == 5:
            self._move_down(extend)
        elif kind == 6:
            self.move_to(self.cursor_row, 0, extend)
        elif kind == 7:
            self.move_to(
                self.cursor_row,
                self.buffer.line_length(self.cursor_row),
                extend,
            )
        elif kind == 8:
            var nr = self.cursor_row - page_height
            if nr < 0:
                nr = 0
            var nc = _utf8_byte_of_cell(self.buffer.line(nr), self.desired_col)
            self.move_to(nr, nc, extend, False)
        elif kind == 9:
            var nr = self.cursor_row + page_height
            var max_row = self.buffer.line_count() - 1
            if nr > max_row:
                nr = max_row
            var nc = _utf8_byte_of_cell(self.buffer.line(nr), self.desired_col)
            self.move_to(nr, nc, extend, False)

    fn _multi_move(
        mut self, kind: Int, extend: Bool, page_height: Int,
    ):
        """Apply a movement to every caret. With no extras the primary
        is moved in place (no list churn). The two-pass design — collect
        carets, run the op once per caret, install the merged result —
        keeps the existing single-caret movement code as the only
        source of truth for what each direction does."""
        if not self.has_extra_carets():
            self._dispatch_move_one(kind, extend, page_height)
            return
        var carets = self._all_carets_asc()
        var new_carets = List[Caret]()
        for i in range(len(carets)):
            self._apply_caret(carets[i])
            self._dispatch_move_one(kind, extend, page_height)
            new_carets.append(self.primary_caret())
        self._install_carets(new_carets^)

    fn _multi_insert_inline(mut self, ch: String):
        """Insert ``ch`` at every caret. Pre-condition checked by the
        caller: no caret has a selection, every caret position is
        valid for an inline insert.

        The cumulative shift on the same row is the only subtlety —
        carets are processed left-to-right, and each insert pushes
        every later same-row caret right by ``len(ch)`` bytes. Cross-
        row carets are independent."""
        var n = len(ch.as_bytes())
        if n == 0:
            return
        var carets = self._all_carets_asc()
        var new_carets = List[Caret]()
        var prev_row = -1
        var row_shift = 0
        for i in range(len(carets)):
            var c = carets[i]
            if c.row != prev_row:
                row_shift = 0
                prev_row = c.row
            var actual_col = c.col + row_shift
            self.buffer.insert(c.row, actual_col, ch)
            var new_col = actual_col + n
            var new_desired = _utf8_cell_of_byte(
                self.buffer.line(c.row), new_col,
            )
            new_carets.append(
                Caret(c.row, new_col, new_desired, c.row, new_col),
            )
            row_shift += n
        self._install_carets(new_carets^)

    fn _multi_backspace_inline(mut self):
        """Same-row backspace at every caret. Caller guarantees every
        caret has ``col > 0`` (so no row joins) and no selection."""
        var carets = self._all_carets_asc()
        var new_carets = List[Caret]()
        var prev_row = -1
        var row_shift = 0
        for i in range(len(carets)):
            var c = carets[i]
            if c.row != prev_row:
                row_shift = 0
                prev_row = c.row
            var actual_col = c.col + row_shift
            var line = self.buffer.line(c.row)
            var prev_col = _utf8_step_backward(line, actual_col)
            var byte_removed = actual_col - prev_col
            var n_line = len(line.as_bytes())
            self.buffer.lines[c.row] = _slice(line, 0, prev_col) \
                + _slice(line, actual_col, n_line)
            var new_col = prev_col
            var new_desired = _utf8_cell_of_byte(
                self.buffer.line(c.row), new_col,
            )
            new_carets.append(
                Caret(c.row, new_col, new_desired, c.row, new_col),
            )
            row_shift -= byte_removed
        self._install_carets(new_carets^)

    fn _multi_delete_inline(mut self):
        """Same-row Delete at every caret. Caller guarantees every
        caret has ``col < line_length`` (so no row joins) and no
        selection."""
        var carets = self._all_carets_asc()
        var new_carets = List[Caret]()
        var prev_row = -1
        var row_shift = 0
        for i in range(len(carets)):
            var c = carets[i]
            if c.row != prev_row:
                row_shift = 0
                prev_row = c.row
            var actual_col = c.col + row_shift
            var line = self.buffer.line(c.row)
            var nxt = _utf8_step_forward(line, actual_col)
            var byte_removed = nxt - actual_col
            var n_line = len(line.as_bytes())
            self.buffer.lines[c.row] = _slice(line, 0, actual_col) \
                + _slice(line, nxt, n_line)
            # Caret stays at actual_col; col doesn't change for Delete.
            var new_desired = _utf8_cell_of_byte(
                self.buffer.line(c.row), actual_col,
            )
            new_carets.append(
                Caret(
                    c.row, actual_col, new_desired,
                    c.row, actual_col,
                ),
            )
            row_shift -= byte_removed
        self._install_carets(new_carets^)

    # --- smart-select (Cmd+Up / Cmd+Down) ---------------------------------
    #
    # Cmd+Up grows the selection to the next-larger syntactic scope and
    # pushes the previous caret state onto a stack so Cmd+Down can rewind
    # through every step. The stack is cleared by any other interaction
    # (handle_key default branch, handle_mouse), so the rewind is always
    # contiguous with the run of Cmd+Up presses that produced it.
    #
    # Levels (smallest → largest):
    #   1. word at cursor
    #   2. dotted symbol (``foo.bar.baz``)
    #   3. interior of enclosing string literal (without quotes)
    #   4. enclosing string literal with its quotes
    #   5. interior of enclosing bracket pair ``( ) / [ ] / { }``
    #   6. enclosing bracket pair including the brackets
    #   7. line content (leading / trailing whitespace stripped)
    #   8. whole line (start-of-line .. end-of-line)
    #   9. enclosing indent block (rows at >= current indent)
    #   N. whole file
    #
    # Each level is *attempted in order*; the first one that strictly
    # grows the current selection wins, so steps 3 / 5 / 9 silently skip
    # when the cursor isn't inside the relevant scope. Selections drop
    # any extra carets — multi-caret + smart-select isn't a meaningful
    # combination and would just complicate the snapshot model.

    fn _smart_select_set(
        mut self, sr: Int, sc: Int, er: Int, ec: Int,
    ):
        """Install ``[sr, sc) .. [er, ec)`` as the primary caret's
        anchor / cursor and refresh ``desired_col``. The anchor sits at
        the start so the cursor lands at the end — this matches what
        Shift-arrow selections produce, and keeps subsequent right /
        down arrows extending in the same direction the user expects."""
        self.anchor_row = sr
        self.anchor_col = sc
        self.cursor_row = er
        self.cursor_col = ec
        self.desired_col = _utf8_cell_of_byte(self.buffer.line(er), ec)

    fn _smart_select_grow(mut self):
        """Expand the primary caret's selection to the next-larger
        smart-select level and push the previous state onto the stack.
        No-op once the selection covers the whole file."""
        # Smart-select operates on the primary caret only — drop extras.
        # No undo snapshot: smart-select doesn't change the buffer, and
        # the user can always re-add carets after rewinding via Cmd+Down.
        self.extra_carets = List[Caret]()
        var before = self.primary_caret()
        var sr = self.anchor_row
        var sc = self.anchor_col
        var er = self.cursor_row
        var ec = self.cursor_col
        if (sr > er) or (sr == er and sc > ec):
            var tr = sr; var tc = sc
            sr = er; sc = ec
            er = tr; ec = tc
        var nxt = self._smart_compute_expansion(sr, sc, er, ec)
        if nxt[0] == sr and nxt[1] == sc and nxt[2] == er and nxt[3] == ec:
            return
        self._smart_select_stack.append(before)
        self._smart_select_set(nxt[0], nxt[1], nxt[2], nxt[3])

    fn _smart_select_shrink(mut self):
        """Pop the most-recently captured snapshot and restore it.
        No-op when the stack is empty — Cmd+Down outside a smart-select
        run does nothing rather than guessing what to shrink."""
        if len(self._smart_select_stack) == 0:
            return
        self.extra_carets = List[Caret]()
        var c = self._smart_select_stack[len(self._smart_select_stack) - 1]
        self._smart_select_stack.resize(
            len(self._smart_select_stack) - 1, Caret(0, 0, 0, 0, 0),
        )
        self._apply_caret(c)

    fn _smart_compute_expansion(
        self, sr: Int, sc: Int, er: Int, ec: Int,
    ) -> Tuple[Int, Int, Int, Int]:
        """Return the next-larger range strictly containing
        ``[sr, sc) .. [er, ec)``, or the same range if no expansion
        applies (selection already covers the whole file)."""
        # 1) Empty selection → word at cursor.
        if sr == er and sc == ec:
            var line = self.buffer.line(sr)
            var w = _word_run_at_or_left(line, sc)
            if w[0] != w[1]:
                return (sr, w[0], sr, w[1])
            # No word at or before cursor: try line content; failing
            # that, fall through to the whole-line / file ladder below.
            var lc = _smart_line_content_range(line)
            if lc[0] != lc[1]:
                return (sr, lc[0], sr, lc[1])
        # 2) Dotted symbol — only meaningful when the selection sits on
        #    a single line and is contained within one identifier run.
        if sr == er:
            var line = self.buffer.line(sr)
            var dotted = _smart_dotted_extend(line, sc, ec)
            if _smart_strictly_contains(
                sr, sc, er, ec, sr, dotted[0], sr, dotted[1],
            ):
                return (sr, dotted[0], sr, dotted[1])
        # 3) Interior of an enclosing same-line string literal.
        if sr == er:
            var line = self.buffer.line(sr)
            var s = _smart_string_around(line, sc, ec)
            if s:
                var pair = s.value()
                var inner_s = pair[0] + 1
                var inner_e = pair[1]
                if _smart_strictly_contains(
                    sr, sc, er, ec, sr, inner_s, sr, inner_e,
                ):
                    return (sr, inner_s, sr, inner_e)
                # Already at the interior — try with quotes.
                if sc == inner_s and ec == inner_e:
                    return (sr, pair[0], sr, pair[1] + 1)
        # 4) String with quotes (when the selection didn't reach interior
        #    above but still sits inside a string).
        if sr == er:
            var line = self.buffer.line(sr)
            var s = _smart_string_around(line, sc, ec)
            if s:
                var pair = s.value()
                var with_s = pair[0]
                var with_e = pair[1] + 1
                if _smart_strictly_contains(
                    sr, sc, er, ec, sr, with_s, sr, with_e,
                ):
                    return (sr, with_s, sr, with_e)
        # 5) Interior of enclosing bracket pair (cross-line).
        var b = self._smart_find_enclosing_bracket(sr, sc, er, ec)
        if b:
            var p = b.value()
            var open_r = p[0]
            var open_c = p[1]
            var close_r = p[2]
            var close_c = p[3]
            var inner_sr = open_r
            var inner_sc = open_c + 1
            var inner_er = close_r
            var inner_ec = close_c
            if _smart_strictly_contains(
                sr, sc, er, ec, inner_sr, inner_sc, inner_er, inner_ec,
            ):
                return (inner_sr, inner_sc, inner_er, inner_ec)
            # 6) With brackets.
            if sr == inner_sr and sc == inner_sc \
                    and er == inner_er and ec == inner_ec:
                return (open_r, open_c, close_r, close_c + 1)
            var with_sr = open_r
            var with_sc = open_c
            var with_er = close_r
            var with_ec = close_c + 1
            if _smart_strictly_contains(
                sr, sc, er, ec, with_sr, with_sc, with_er, with_ec,
            ):
                return (with_sr, with_sc, with_er, with_ec)
        # 7) Line content (single-line selection only).
        if sr == er:
            var line = self.buffer.line(sr)
            var lc = _smart_line_content_range(line)
            if _smart_strictly_contains(
                sr, sc, er, ec, sr, lc[0], sr, lc[1],
            ):
                return (sr, lc[0], sr, lc[1])
        # 8) Whole line(s).
        var line_end = self.buffer.line_length(er)
        if _smart_strictly_contains(
            sr, sc, er, ec, sr, 0, er, line_end,
        ):
            return (sr, 0, er, line_end)
        # 9) Indent block.
        var ib = self._smart_indent_block(sr, er)
        if ib:
            var p = ib.value()
            var b_sr = p[0]
            var b_er = p[1]
            var b_ec = self.buffer.line_length(b_er)
            if _smart_strictly_contains(
                sr, sc, er, ec, b_sr, 0, b_er, b_ec,
            ):
                return (b_sr, 0, b_er, b_ec)
        # 10) Whole file.
        var n = self.buffer.line_count()
        if n > 0:
            var last = n - 1
            var last_len = self.buffer.line_length(last)
            if _smart_strictly_contains(
                sr, sc, er, ec, 0, 0, last, last_len,
            ):
                return (0, 0, last, last_len)
        return (sr, sc, er, ec)

    fn _smart_find_enclosing_bracket(
        self, sr: Int, sc: Int, er: Int, ec: Int,
    ) -> Optional[Tuple[Int, Int, Int, Int]]:
        """Find the smallest bracket pair ``( ) / [ ] / { }`` that
        strictly encloses ``[sr, sc) .. [er, ec)``. Returns
        ``(open_row, open_col, close_row, close_col)`` of the bracket
        bytes themselves, or ``None`` when no enclosing pair exists.

        Backward scan tracks one skip-counter per bracket type — when we
        encounter a closer we owe a same-type opener; when we encounter
        an opener we either pay the debt or, if no debt outstanding, we
        found the enclosing opener. Mismatched brackets (``f(x]``) keep
        the counters from steering us into a wrong pair as long as the
        actual nesting balances. Once the opener is known, a forward
        scan finds the matching closer with a single same-type depth
        counter; brackets of other types pass through untouched.
        """
        var paren_skip = 0
        var bracket_skip = 0
        var brace_skip = 0
        var r = sr
        var c = sc - 1
        var opener_r = -1
        var opener_c = -1
        var opener_b = 0
        # Walk back; the loop only enters a row's byte-scan when ``c >= 0``.
        # When ``sc == 0`` the initial ``c == -1`` falls straight through
        # the row-skip block and lands us on the previous row's last byte,
        # rather than wrapping forward into the start row's tail.
        while r >= 0:
            if c < 0:
                r -= 1
                if r < 0: break
                c = self.buffer.line_length(r) - 1
                continue
            var line = self.buffer.line(r)
            var bytes = line.as_bytes()
            if c >= len(bytes):
                c = len(bytes) - 1
            while c >= 0:
                var b = Int(bytes[c])
                if b == 0x29:
                    paren_skip += 1
                elif b == 0x5D:
                    bracket_skip += 1
                elif b == 0x7D:
                    brace_skip += 1
                elif b == 0x28:
                    if paren_skip > 0:
                        paren_skip -= 1
                    else:
                        opener_r = r; opener_c = c; opener_b = b
                        break
                elif b == 0x5B:
                    if bracket_skip > 0:
                        bracket_skip -= 1
                    else:
                        opener_r = r; opener_c = c; opener_b = b
                        break
                elif b == 0x7B:
                    if brace_skip > 0:
                        brace_skip -= 1
                    else:
                        opener_r = r; opener_c = c; opener_b = b
                        break
                c -= 1
            if opener_r >= 0:
                break
            r -= 1
            if r < 0: break
            c = self.buffer.line_length(r) - 1
        if opener_r < 0:
            return Optional[Tuple[Int, Int, Int, Int]]()
        var closer_b = _matching_closer(opener_b)
        var depth = 1
        var fr = opener_r
        var fc = opener_c + 1
        var n = self.buffer.line_count()
        while fr < n:
            var line = self.buffer.line(fr)
            var bytes = line.as_bytes()
            while fc < len(bytes):
                var b = Int(bytes[fc])
                if b == opener_b:
                    depth += 1
                elif b == closer_b:
                    depth -= 1
                    if depth == 0:
                        # The found pair must strictly enclose the
                        # cursor's *end* — otherwise the user's caret
                        # sits outside this pair (e.g. starts in the
                        # middle of a closer scan after a partial
                        # selection past the bracket) and we should
                        # report nothing.
                        if (fr > er) or (fr == er and fc >= ec):
                            return Optional[
                                Tuple[Int, Int, Int, Int]
                            ](
                                (opener_r, opener_c, fr, fc),
                            )
                        return Optional[Tuple[Int, Int, Int, Int]]()
                fc += 1
            fr += 1
            fc = 0
        return Optional[Tuple[Int, Int, Int, Int]]()

    fn _smart_indent_block(
        self, sr: Int, er: Int,
    ) -> Optional[Tuple[Int, Int]]:
        """Expand ``[sr, er]`` outward to consecutive rows whose leading
        indent is ``>=`` the minimum non-blank indent of the selection.
        Trailing blank lines are excluded — they're rejoined to the
        sibling block above unless that block ends *at* a blank.

        Returns the new ``(start_row, end_row)`` if expansion succeeded,
        otherwise widens the selection by dropping one indent level (the
        introducer line above the current block enters the selection).
        Returns ``None`` only when nothing larger remains.
        """
        var n = self.buffer.line_count()
        if n == 0:
            return Optional[Tuple[Int, Int]]()
        var min_indent = -1
        for r in range(sr, er + 1):
            var line = self.buffer.line(r)
            if _is_blank_line(line):
                continue
            var lead = leading_indent_bytes(line)
            if min_indent < 0 or lead < min_indent:
                min_indent = lead
        if min_indent < 0:
            min_indent = 0
        # Phase A: include neighbors at the same-or-greater indent.
        var new_sr = sr
        var r = sr - 1
        var blank_run_top = -1
        while r >= 0:
            var line = self.buffer.line(r)
            if _is_blank_line(line):
                if blank_run_top < 0:
                    blank_run_top = r
                r -= 1
                continue
            var lead = leading_indent_bytes(line)
            if lead >= min_indent:
                new_sr = r
                blank_run_top = -1
                r -= 1
                continue
            break
        # Phase A: walk down.
        var new_er = er
        r = er + 1
        var blank_run_bot = -1
        while r < n:
            var line = self.buffer.line(r)
            if _is_blank_line(line):
                if blank_run_bot < 0:
                    blank_run_bot = r
                r += 1
                continue
            var lead = leading_indent_bytes(line)
            if lead >= min_indent:
                new_er = r
                blank_run_bot = -1
                r += 1
                continue
            break
        if new_sr < sr or new_er > er:
            return Optional[Tuple[Int, Int]]((new_sr, new_er))
        # Phase B: drop one indent level — the introducer above the
        # current block (e.g. the ``def foo():`` line above an indented
        # body) joins the selection. We stop right after attaching the
        # introducer; the next Cmd+Up press will run Phase A again at
        # the parent's indent level and grow to its siblings, so the
        # user sees one scope per keypress instead of jumping straight
        # to top-level.
        if min_indent <= 0:
            return Optional[Tuple[Int, Int]]()
        var intro_r = sr - 1
        while intro_r >= 0 and _is_blank_line(self.buffer.line(intro_r)):
            intro_r -= 1
        if intro_r < 0:
            return Optional[Tuple[Int, Int]]()
        var intro_indent = leading_indent_bytes(self.buffer.line(intro_r))
        if intro_indent >= min_indent:
            return Optional[Tuple[Int, Int]]()
        return Optional[Tuple[Int, Int]]((intro_r, er))

    # --- event handling ----------------------------------------------------

    fn handle_key(mut self, event: Event, view: Rect) -> Bool:
        if event.kind != EVENT_KEY:
            return False
        # LSP completion-popup intercept. While the popup is visible
        # the navigation keys steer it rather than the cursor;
        # Enter/Tab accept; Esc dismisses. Typing / backspace / arrow
        # keys fall through to the normal handler — the as-you-type
        # auto-trigger at the bottom of ``handle_key`` decides
        # whether to re-stamp a request (keeping the popup alive) or
        # close it.
        if self.completion_popup_visible:
            var ck = event.key
            var no_mods = event.mods == MOD_NONE
            if no_mods and ck == KEY_ESC:
                self.close_completion_popup()
                return True
            if no_mods and ck == KEY_UP:
                self._completion_step(-1)
                return True
            if no_mods and ck == KEY_DOWN:
                self._completion_step(1)
                return True
            if no_mods and ck == KEY_PAGEUP:
                self._completion_step(-_COMPLETION_POPUP_ROWS)
                return True
            if no_mods and ck == KEY_PAGEDOWN:
                self._completion_step(_COMPLETION_POPUP_ROWS)
                return True
            if no_mods and (ck == KEY_ENTER or ck == KEY_TAB):
                if self.accept_completion():
                    self._scroll_to_cursor(view)
                    return True
                return True
        # Ctrl+Space — request completions from the LSP server. The
        # actual round-trip is the host's job; we just emit the
        # request payload. Terminals canonicalize to
        # ``(KEY_SPACE, MOD_CTRL)``; the bare NUL byte some terminals
        # send for Ctrl+Space arrives as ``KEY_NONE`` with no mods,
        # so accept that too.
        if (event.mods == MOD_CTRL and event.key == KEY_SPACE) \
                or (event.mods == MOD_NONE and event.key == UInt32(0)):
            var start_col = self.completion_prefix_start()
            self.pending_completion_request = Optional[CompletionRequest](
                CompletionRequest(
                    self.cursor_row, self.cursor_col, start_col, True,
                ),
            )
            self._completion_request_stamp_ms = monotonic_ms()
            return True
        # Capture the typing-group flag before any branch touches it, then
        # default to "broken" — every non-typing path (cursor moves, edits,
        # clipboard ops, …) leaves the flag false so the next keystroke
        # starts a fresh undo group. The printable-insert branch reads
        # ``was_typing`` to decide whether to extend, then explicitly
        # re-arms the flag at the end of its work.
        var was_typing = self._typing_active
        var prev_typing_ms = self._typing_last_ms
        self._typing_active = False
        # As-you-type completion: set to True by the typing / backspace
        # branches when they stamp a fresh ``pending_completion_request``.
        # At the bottom of this method, ``False`` + a still-visible
        # popup means the user did something that should dismiss the
        # popup (moved the cursor, typed a non-word char, etc.).
        var did_auto_trigger = False
        # Capture the lowest pre-edit row that any selection or
        # cursor-line edit could touch. The dirty-row marker the
        # tokenizer reads must be ``<=`` the actual lowest changed
        # row, so we take the min of cursor + anchor *before* any
        # mutation moves them, and use that for ``_mark_hl_dirty``
        # below. Subsequent moves of the cursor don't matter — we
        # already captured the floor.
        var pre_dirty_row = self.cursor_row
        if self.anchor_row < pre_dirty_row:
            pre_dirty_row = self.anchor_row
        var k = event.key
        # Single source of truth for the clipboard chords (Ctrl+A / C /
        # X / V). The four branches further down read this instead of
        # re-checking ``mods & MOD_CTRL && key == ord(...)`` each time.
        var chord = clipboard_chord(event)
        var extend = (event.mods & MOD_SHIFT) != 0
        # Either Ctrl or Alt triggers word jumps. Ctrl is the Linux/Windows
        # convention; Alt is the macOS convention (and what iTerm2/Terminal.app
        # send by default for Option+Arrow via the readline ``ESC f``/``ESC b``
        # sequences, which the terminal parser translates to KEY_RIGHT/LEFT +
        # MOD_ALT).
        var word = (event.mods & MOD_CTRL) != 0 or (event.mods & MOD_ALT) != 0
        # Multi-cursor stamp bindings — Ctrl+Alt+Up/Down adds a caret one
        # row above the topmost / below the bottommost existing caret.
        # Both modifiers required so this doesn't collide with the
        # word-jump bindings above (which fire on Ctrl OR Alt, not both).
        var has_ctrl = (event.mods & MOD_CTRL) != 0
        var has_alt = (event.mods & MOD_ALT) != 0
        # Smart-select bindings — plain Cmd+Up grows, plain Cmd+Down
        # rewinds. Only the Meta bit may be set: Cmd+Shift+Up doesn't
        # trigger smart-select (host bindings can use it for something
        # else), and any other modifier combination falls through to
        # the existing handlers. Checked before the smart-select stack
        # gets cleared below so the run survives.
        if event.mods == MOD_META and k == KEY_UP:
            self._smart_select_grow()
            self._scroll_to_cursor(view)
            return True
        if event.mods == MOD_META and k == KEY_DOWN:
            self._smart_select_shrink()
            self._scroll_to_cursor(view)
            return True
        # Anything else breaks the smart-select run — the user has
        # moved the cursor, edited, or otherwise shifted intent, so
        # subsequent Cmd+Down should not undo their action.
        self._smart_select_stack = List[Caret]()
        # Cmd+Right / Cmd+Left — line-level horizontal navigation.
        # Cmd+Right jumps to end of line; Cmd+Left jumps to the first
        # non-space, or to col 0 if the cursor is already at or before
        # the first non-space (so a second press from the indent column
        # falls all the way to the margin). Shift extends the selection.
        if (event.mods == MOD_META or event.mods == (MOD_META | MOD_SHIFT)):
            var extend_line = (event.mods & MOD_SHIFT) != 0
            if k == KEY_RIGHT:
                self.clear_extra_carets()
                self.move_to(
                    self.cursor_row,
                    self.buffer.line_length(self.cursor_row),
                    extend_line,
                )
                self._scroll_to_cursor(view)
                return True
            if k == KEY_LEFT:
                self.clear_extra_carets()
                var line_str = self.buffer.line(self.cursor_row)
                var first_ns = leading_indent_bytes(line_str)
                var target = first_ns if self.cursor_col > first_ns else 0
                self.move_to(self.cursor_row, target, extend_line)
                self._scroll_to_cursor(view)
                return True
        if has_ctrl and has_alt and k == KEY_UP:
            self.add_caret_above()
            self._scroll_to_cursor(view)
            return True
        if has_ctrl and has_alt and k == KEY_DOWN:
            self.add_caret_below()
            self._scroll_to_cursor(view)
            return True
        # Pre-edit floor for the highlight dirty-row marker — has to be
        # the lowest row any caret could affect, so look across the
        # primary's cursor + anchor *and* every extra caret.
        var pre_dirty_row_multi = self.cursor_row
        if self.anchor_row < pre_dirty_row_multi:
            pre_dirty_row_multi = self.anchor_row
        for i in range(len(self.extra_carets)):
            var c = self.extra_carets[i]
            if c.row < pre_dirty_row_multi:
                pre_dirty_row_multi = c.row
            if c.anchor_row < pre_dirty_row_multi:
                pre_dirty_row_multi = c.anchor_row
        if k == KEY_LEFT:
            if word:
                self._multi_move(2, extend, view.height())
            else:
                self._multi_move(0, extend, view.height())
        elif k == KEY_RIGHT:
            if word:
                self._multi_move(3, extend, view.height())
            else:
                self._multi_move(1, extend, view.height())
        elif k == KEY_UP:
            self._multi_move(4, extend, view.height())
        elif k == KEY_DOWN:
            self._multi_move(5, extend, view.height())
        elif k == KEY_HOME:
            self._multi_move(6, extend, view.height())
        elif k == KEY_END:
            self._multi_move(7, extend, view.height())
        elif k == KEY_PAGEUP:
            self._multi_move(8, extend, view.height())
        elif k == KEY_PAGEDOWN:
            self._multi_move(9, extend, view.height())
        elif k == KEY_BACKSPACE:
            if self.read_only:
                return True
            # Multi-caret fast path: every caret is mid-line with no
            # selection → process them all bottom-up with cumulative
            # row shift. Anything else (selection, col == 0) collapses
            # to the primary and runs the original single-caret path.
            if self.has_extra_carets() \
                    and self._all_carets_inline_safe(1):
                self._push_undo()
                self._multi_backspace_inline()
                self.dirty = True
                self._mark_hl_dirty(pre_dirty_row_multi)
            else:
                # Single-caret fallback. Push once, capturing extras
                # if any, so a single undo restores the multi-caret
                # state. The original "no-op when nothing to delete"
                # guard becomes "no-op when nothing to delete AND no
                # extras" — collapsing extras is itself state worth
                # rolling back.
                if self.has_extra_carets() or self.has_selection() \
                        or self.cursor_col > 0 or self.cursor_row > 0:
                    self._push_undo()
                self.clear_extra_carets()
                if self.has_selection():
                    self._delete_selection()
                else:
                    var p = self.buffer.delete_before(
                        self.cursor_row, self.cursor_col,
                    )
                    self.move_to(p[0], p[1], False)
                self.dirty = True
                self._mark_hl_dirty(pre_dirty_row)
            # As-you-type completion: when the popup is visible and
            # the cursor is still inside an identifier after the
            # backspace, re-stamp a request so the filtered list
            # refreshes. Stepping out of the word lets the
            # end-of-handler check close the popup naturally.
            if self.completion_popup_visible \
                    and self._cursor_after_word_codepoint():
                self._stamp_completion_request()
                did_auto_trigger = True
        elif k == KEY_DELETE:
            if self.read_only:
                return True
            if self.has_extra_carets() \
                    and self._all_carets_inline_safe(2):
                self._push_undo()
                self._multi_delete_inline()
                self.dirty = True
                self._mark_hl_dirty(pre_dirty_row_multi)
            else:
                # Single-caret fallback. As with backspace, push once
                # capturing extras so a single undo walks back to the
                # multi-caret state.
                var at_end = self.cursor_col \
                        >= self.buffer.line_length(self.cursor_row) \
                    and self.cursor_row + 1 >= self.buffer.line_count()
                if self.has_extra_carets() or self.has_selection() \
                        or not at_end:
                    self._push_undo()
                self.clear_extra_carets()
                if self.has_selection():
                    self._delete_selection()
                else:
                    self.buffer.delete_at(self.cursor_row, self.cursor_col)
                self.dirty = True
                self._mark_hl_dirty(pre_dirty_row)
        elif k == KEY_ENTER:
            # Alt+Enter on a misspelled word stamps a pending
            # ``SpellActionRequest`` for the host to surface its
            # spell-action popup. The naked ``KEY_ENTER`` path below
            # would split the line, so this *must* check the modifier
            # before falling through. We don't move the cursor, edit
            # the buffer, or touch undo — the pending request is the
            # only side effect.
            if has_alt:
                var sa = self.spell_run_at_cursor()
                if sa:
                    self.pending_spell_action = sa
                    return True
                # Alt+Enter outside any misspelling: leave the event
                # for the caller to bind to a hotkey of their own.
                return False
            if self.read_only:
                return True
            # Enter splits a row, which would shift every caret below;
            # multi-caret Enter isn't supported in this MVP. Push once
            # before clearing extras so a single undo restores the
            # multi-caret state.
            self._push_undo()
            self.clear_extra_carets()
            if self.has_selection():
                self._delete_selection()
            # Compute the new line's indent before splitting so we can
            # mirror the source line's leading whitespace (and add one
            # extra step when the cursor sits after a brace, bracket,
            # paren, or Python ``:``).
            var prev_line = self.buffer.line(self.cursor_row)
            var indent = _smart_indent_for_enter(
                prev_line, self.cursor_col, self.editorconfig,
            )
            var p = self.buffer.split(self.cursor_row, self.cursor_col)
            self.move_to(p[0], p[1], False)
            if len(indent.as_bytes()) > 0:
                self.buffer.insert(self.cursor_row, self.cursor_col, indent)
                self.move_to(
                    self.cursor_row,
                    self.cursor_col + len(indent.as_bytes()),
                    False,
                )
            self.dirty = True
            self._mark_hl_dirty(pre_dirty_row)
        elif k == KEY_TAB:
            if self.read_only:
                return True
            var shift_tab = (event.mods & MOD_SHIFT) != 0
            if shift_tab:
                self._collapse_extras_with_undo()
                # Shift+Tab dedents the cursor's line, or every line in
                # the selection when one is active.
                var rng = self._line_op_range()
                self._dedent_rows(rng[0], rng[1], pre_dirty_row)
            elif self.has_selection():
                self._collapse_extras_with_undo()
                # Tab on a selection indents every line in the selection.
                var rng = self._line_op_range()
                self._indent_rows(rng[0], rng[1], pre_dirty_row)
            else:
                # No selection: Tab is an inline insert of the indent
                # string, which the multi-caret path handles cleanly.
                self._push_undo()
                var indent = self.editorconfig.indent_string()
                if self.has_extra_carets():
                    self._multi_insert_inline(indent)
                else:
                    var indent_n = len(indent.as_bytes())
                    self.buffer.insert(
                        self.cursor_row, self.cursor_col, indent,
                    )
                    self.move_to(
                        self.cursor_row, self.cursor_col + indent_n, False,
                    )
                self.dirty = True
                self._mark_hl_dirty(pre_dirty_row_multi)
        elif chord == CLIP_SELECT_ALL:
            # Ctrl+A — select whole buffer.
            # Pure selection move: no buffer mutation, no undo, no
            # extras (a select-all on top of multi-cursor would
            # collapse to one selection anyway). Anchor at (0, 0),
            # cursor at end of last line — same direction as a
            # Shift-Down/End drive so subsequent shift-arrows extend
            # in the natural direction.
            self.clear_extra_carets()
            var n_rows = self.buffer.line_count()
            if n_rows > 0:
                var last = n_rows - 1
                self.move_to(0, 0, False)
                self.move_to(last, self.buffer.line_length(last), True)
        elif chord == CLIP_COPY:
            # Ctrl+C — non-mutating copy. No undo snapshot needed.
            self.clear_extra_carets()
            self.copy_to_clipboard()
        elif chord == CLIP_CUT:
            if self.read_only:
                return True
            self._collapse_extras_with_undo()
            self.cut_to_clipboard()
            self._mark_hl_dirty(pre_dirty_row)
        elif chord == CLIP_PASTE:
            if self.read_only:
                return True
            self._collapse_extras_with_undo()
            self.paste_from_clipboard()
            self._mark_hl_dirty(pre_dirty_row)
        elif UInt32(0x20) <= k and k < UInt32(0x7F):
            # Modified letters are commands, not text — defer to whatever
            # the caller wants to do with them (e.g., a hotkey table).
            # MOD_SHIFT is fine: capitals already arrive with a different
            # codepoint, so a leftover SHIFT bit just means a shifted
            # printable that the terminal pre-folded. ``MOD_META`` has
            # to be in the check too — without it, Cmd+B (which isn't
            # bound to any hotkey or editor command) used to fall
            # through and insert ``b`` into the buffer.
            if (event.mods & (MOD_CTRL | MOD_ALT | MOD_META)) != 0:
                return False
            if self.read_only:
                return True
            var now = monotonic_ms()
            # Multi-caret typing: collapse to a fresh undo step (the
            # debounce-extension logic would interact awkwardly with
            # carets coming and going) and broadcast via the inline
            # helper. Selections-into-typing on multi-caret aren't
            # supported in this MVP — the caller-visible behavior is
            # "carets typed at their cursor positions, selections kept".
            if self.has_extra_carets() and not self._any_caret_has_selection():
                self._push_undo()
                self._multi_insert_inline(chr(Int(k)))
                self._typing_active = True
                self._typing_last_ms = now
                self.dirty = True
                self._mark_hl_dirty(pre_dirty_row_multi)
            else:
                # Selections + multi-caret typing isn't supported;
                # snapshot the multi-state so undo can restore it,
                # then collapse so the destructive replace below
                # only runs on the primary.
                self._collapse_extras_with_undo()
                # Group consecutive printable inserts into a single undo
                # step. Boundaries: a typing pause longer than
                # ``_TYPING_DEBOUNCE_MS``, an active selection (typing-
                # into-selection is a destructive replace, not a
                # continuation), or anything that already cleared
                # ``was_typing`` (cursor move, edit, paste, mouse, …).
                var extend_group = was_typing and not self.has_selection() \
                    and now - prev_typing_ms <= _TYPING_DEBOUNCE_MS
                if not extend_group:
                    self._push_undo()
                if self.has_selection():
                    self._delete_selection()
                self.buffer.insert(
                    self.cursor_row, self.cursor_col, chr(Int(k)),
                )
                self.move_to(
                    self.cursor_row, self.cursor_col + 1, False,
                )
                self._typing_active = True
                self._typing_last_ms = now
                self.dirty = True
                self._mark_hl_dirty(pre_dirty_row)
            # As-you-type completion. Stamp a fresh request whenever
            # the typed byte extends an identifier (ASCII letter,
            # digit, or underscore) or is a member-access trigger
            # (``.``). Non-word punctuation falls through to the
            # bottom-of-handler logic, which closes any visible popup.
            if _is_completion_autotrigger_byte(k):
                self._stamp_completion_request()
                did_auto_trigger = True
        else:
            return False
        self._scroll_to_cursor(view)
        # As-you-type popup management. ``did_auto_trigger`` is True
        # iff this keystroke explicitly re-stamped a completion
        # request (typing an identifier char or backspacing inside
        # one). For other paths (cursor moves, etc.), keep the popup
        # alive as long as the cursor is still inside the *same*
        # identifier we anchored on — left/right arrow inside the
        # prefix re-filters the popup rather than dismissing it,
        # which matches every modern IDE. Leaving the identifier
        # (jumping rows, moving past the anchor, landing on a non-
        # word char) closes the popup.
        if self.completion_popup_visible and not did_auto_trigger:
            if self.cursor_row == self.completion_anchor_row \
                    and self.cursor_col >= self.completion_anchor_col \
                    and self.completion_prefix_start() \
                        == self.completion_anchor_col:
                self._stamp_completion_request()
            else:
                self.close_completion_popup()
        # Re-tokenize only when this keystroke actually mutated the
        # buffer. Mutating branches set ``_highlights_dirty`` via
        # ``_mark_hl_dirty`` next to their existing ``self.dirty =
        # True`` write; the actual tokenization is deferred to the
        # render path's ``Editor.flush_highlights`` call so we don't
        # need a ``GrammarRegistry`` parameter on every edit method.
        return True

    # --- clipboard / programmatic edit API --------------------------------

    fn selection_text(self) -> String:
        """Return the currently-selected text (empty when no selection).
        Delegates to ``Selection.extracted_text`` — same byte-slice
        iteration the DebugPane output panel uses for its Cmd+C copy."""
        return self._selection_view().extracted_text(self.buffer.lines)

    fn _selection_view(self) -> Selection:
        """Wrap ``anchor_*`` / ``cursor_*`` into a ``Selection`` value
        for shared text-extraction logic. The Editor still owns the
        anchor/cursor fields directly (mutated all over the place by
        movement / typing); this is just a one-line view."""
        return Selection(
            self.has_selection(), False,
            self.anchor_row, self.anchor_col,
            self.cursor_row, self.cursor_col,
        )

    fn cut_selection(mut self) -> String:
        """Remove and return the selected text. Pushes an undo step iff a
        selection actually existed (so calling cut with no selection is a
        true no-op). No-op (returns empty string) when the editor is
        read-only."""
        if self.read_only:
            return String("")
        var text = self.selection_text()
        if self.has_selection():
            var pre = self.cursor_row
            if self.anchor_row < pre:
                pre = self.anchor_row
            self._push_undo()
            self._delete_selection()
            self.dirty = True
            self._mark_hl_dirty(pre)
        return text

    fn paste_text(mut self, text: String):
        """Replace any selection then insert ``text`` (newlines split lines).
        Pushes an undo step when there's something to do — a paste with
        empty clipboard and no selection is a no-op and won't disturb the
        undo history. No-op when the editor is read-only."""
        if self.read_only:
            return
        if len(text.as_bytes()) == 0 and not self.has_selection():
            return
        self._push_undo()
        if self.has_selection():
            self._delete_selection()
        self._insert_text(text)
        self.dirty = True

    fn copy_to_clipboard(self):
        """Copy the current selection to the system clipboard. With no
        selection, copy the whole current line including its trailing
        newline — matches the behavior in VS Code/Sublime/JetBrains
        where Ctrl+C with an empty selection grabs the cursor's line."""
        if self.has_selection():
            clipboard_copy(self.selection_text())
        else:
            clipboard_copy(self.buffer.line(self.cursor_row) + String("\n"))

    fn cut_to_clipboard(mut self):
        """Copy the selection to the clipboard, then remove it from the
        buffer. With no selection, cut the whole current line (including
        its trailing newline). Read-only editors fall through to a copy
        without mutating the buffer."""
        if self.has_selection():
            if self.read_only:
                clipboard_copy(self.selection_text())
                return
            var pre = self.cursor_row
            if self.anchor_row < pre:
                pre = self.anchor_row
            var text = self.selection_text()
            clipboard_copy(text)
            self._push_undo()
            self._delete_selection()
            self.dirty = True
            self._mark_hl_dirty(pre)
            return
        # Whole-line mode.
        var r = self.cursor_row
        var text = self.buffer.line(r) + String("\n")
        if self.read_only:
            clipboard_copy(text)
            return
        clipboard_copy(text)
        self._push_undo()
        if self.buffer.line_count() == 1:
            # Only line in the buffer — keep one (now empty) line.
            self.buffer.lines[0] = String("")
            self.move_to(0, 0, False)
        else:
            _ = self.buffer.lines.pop(r)
            var max_row = self.buffer.line_count() - 1
            var nr = r
            if nr > max_row:
                nr = max_row
            self.move_to(nr, 0, False)
        self.dirty = True
        self._mark_hl_dirty(r)

    fn paste_from_clipboard(mut self):
        """Replace any selection with the system clipboard's contents.
        With no selection, a clipboard whose text ends in ``\\n`` is
        treated as a line-clipboard and inserted as new lines above the
        current line (cursor stays on its original line, now displaced
        down)."""
        var text = clipboard_paste()
        var bytes = text.as_bytes()
        var n = len(bytes)
        var line_mode = (
            not self.has_selection()
            and n > 0
            and bytes[n - 1] == 0x0A
        )
        if line_mode:
            self._paste_as_line(text)
        else:
            self.paste_text(text)

    fn _paste_as_line(mut self, text: String):
        """Insert ``text`` (which ends in ``\\n``) above the cursor's
        current line, leaving the cursor on its original line at the
        same column."""
        if self.read_only:
            return
        if len(text.as_bytes()) == 0:
            return
        self._push_undo()
        var orig_col = self.cursor_col
        self.move_to(self.cursor_row, 0, False)
        self._insert_text(text)
        # ``_insert_text`` parks the cursor at column 0 of the line that
        # *was* the original current line. Restore the column (clamped).
        var line_n = self.buffer.line_length(self.cursor_row)
        var col = orig_col
        if col > line_n:
            col = line_n
        self.move_to(self.cursor_row, col, False)
        self.dirty = True

    # --- turbo-style editor commands --------------------------------------

    fn goto_line(mut self, one_based_line: Int):
        """Move the cursor to the start of ``one_based_line`` (clamped)."""
        var r = one_based_line - 1
        if r < 0: r = 0
        var max_r = self.buffer.line_count() - 1
        if r > max_r: r = max_r
        self.move_to(r, 0, False)

    fn find_next(
        mut self, needle: String,
        opts: SearchOptions = default_search_options(),
    ) -> Bool:
        """Search forward from the cursor for ``needle``; select on hit.

        ``opts`` carries the Cc / W / .* toggles from the Find prompt;
        when every flag is off the function takes the byte-match fast
        path (the original implementation). With any flag set we
        compile ``needle`` to a libonig regex and scan one line at a
        time so word boundaries, case folding, and user-supplied
        regex syntax all share one code path."""
        if len(needle.as_bytes()) == 0:
            return False
        var rx_opt = build_search_regex(needle, opts)
        if rx_opt:
            return self._find_next_regex(rx_opt.value())
        var n = len(needle.as_bytes())
        var nb = needle.as_bytes()
        # Search the rest of the current line, then subsequent lines, then wrap.
        var start_row = self.cursor_row
        var start_col = self.cursor_col + 1   # skip past current match
        for pass_idx in range(2):
            var r0 = start_row if pass_idx == 0 else 0
            var r1 = self.buffer.line_count() if pass_idx == 0 else start_row + 1
            for r in range(r0, r1):
                var line = self.buffer.line(r)
                var lb = line.as_bytes()
                var first_col = start_col if (pass_idx == 0 and r == start_row) else 0
                if first_col + n > len(lb):
                    continue
                for c in range(first_col, len(lb) - n + 1):
                    var matches = True
                    for k in range(n):
                        if lb[c + k] != nb[k]:
                            matches = False
                            break
                    if matches:
                        self.move_to(r, c, False)
                        self.move_to(r, c + n, True)
                        return True
        return False

    fn _find_next_regex(mut self, rx: OnigRegex) -> Bool:
        """Regex-mode implementation of ``find_next``. Scans each
        line independently from the cursor's row, then wraps. We
        skip the current selection by starting one byte past
        ``cursor_col`` on the cursor's row — same idiom as the byte
        path so a repeated press steps to the next match."""
        var start_row = self.cursor_row
        var start_col = self.cursor_col + 1
        for pass_idx in range(2):
            var r0 = start_row if pass_idx == 0 else 0
            var r1 = self.buffer.line_count() if pass_idx == 0 else start_row + 1
            for r in range(r0, r1):
                var line = self.buffer.line(r)
                var lb = line.as_bytes()
                var first_col = start_col if (pass_idx == 0 and r == start_row) else 0
                if first_col > len(lb):
                    continue
                var m = rx.search_at(line, first_col)
                if m:
                    var mv = m.value()
                    if mv.start < 0 or mv.end <= mv.start:
                        continue
                    self.move_to(r, mv.start, False)
                    self.move_to(r, mv.end, True)
                    return True
        return False

    fn find_prev(
        mut self, needle: String,
        opts: SearchOptions = default_search_options(),
    ) -> Bool:
        """Search backward from the cursor for ``needle``; select on hit.
        Wraps around to the file end when nothing earlier matches.

        Mirrors ``find_next`` for the opts-aware path: any flag set
        triggers the regex implementation; otherwise the byte scan
        runs unchanged."""
        if len(needle.as_bytes()) == 0:
            return False
        var rx_opt = build_search_regex(needle, opts)
        if rx_opt:
            return self._find_prev_regex(rx_opt.value())
        var n = len(needle.as_bytes())
        var nb = needle.as_bytes()
        # Anchor: the leftmost end of the current selection / cursor. We
        # subtract one byte so a repeated press steps to the *previous*
        # match instead of re-finding the one already selected.
        var sel = self.selection()
        var anchor_row = sel[0]
        var anchor_col = sel[1] - 1
        # First pass walks rows from anchor_row down to 0 inclusive;
        # second pass wraps and walks from the last row back up to
        # anchor_row + 1 (so the anchor row's earlier columns get a
        # chance on the first pass, never twice).
        for pass_idx in range(2):
            var r_top: Int
            var r_bot: Int
            if pass_idx == 0:
                r_top = 0
                r_bot = anchor_row
            else:
                r_top = anchor_row + 1
                r_bot = self.buffer.line_count() - 1
            var r = r_bot
            while r >= r_top:
                var line = self.buffer.line(r)
                var lb = line.as_bytes()
                if len(lb) >= n:
                    var last_col: Int
                    if pass_idx == 0 and r == anchor_row:
                        last_col = anchor_col
                        if last_col > len(lb) - n:
                            last_col = len(lb) - n
                    else:
                        last_col = len(lb) - n
                    var c = last_col
                    while c >= 0:
                        var matches = True
                        for k in range(n):
                            if lb[c + k] != nb[k]:
                                matches = False
                                break
                        if matches:
                            self.move_to(r, c, False)
                            self.move_to(r, c + n, True)
                            return True
                        c -= 1
                r -= 1
        return False

    fn _find_prev_regex(mut self, rx: OnigRegex) -> Bool:
        """Regex-mode ``find_prev``: walk lines from the selection
        anchor backward, and within each line collect every match
        forward until past the upper bound, then return the
        right-most one. libonig has no built-in reverse search, but
        per-line forward scans are still cheap because line lengths
        are bounded in practice."""
        var sel = self.selection()
        var anchor_row = sel[0]
        var anchor_col = sel[1] - 1
        for pass_idx in range(2):
            var r_top: Int
            var r_bot: Int
            if pass_idx == 0:
                r_top = 0
                r_bot = anchor_row
            else:
                r_top = anchor_row + 1
                r_bot = self.buffer.line_count() - 1
            var r = r_bot
            while r >= r_top:
                var line = self.buffer.line(r)
                var lb = line.as_bytes()
                var upper: Int
                if pass_idx == 0 and r == anchor_row:
                    upper = anchor_col + 1
                    if upper < 0:
                        upper = 0
                    if upper > len(lb):
                        upper = len(lb)
                else:
                    upper = len(lb)
                # Walk forward collecting hits whose start is < upper;
                # remember the last such match.
                var best_start = -1
                var best_end = -1
                var pos = 0
                while pos <= len(lb):
                    var m = rx.search_at(line, pos)
                    if not m:
                        break
                    var mv = m.value()
                    if mv.start < 0 or mv.end < mv.start:
                        break
                    if mv.start >= upper:
                        break
                    best_start = mv.start
                    best_end = mv.end
                    if mv.end == mv.start:
                        pos = mv.end + 1
                    else:
                        pos = mv.end
                if best_start >= 0:
                    self.move_to(r, best_start, False)
                    self.move_to(r, best_end, True)
                    return True
                r -= 1
        return False

    fn toggle_comment(mut self, prefix: String = String("")):
        """Toggle a line-comment prefix on every line touched by the selection
        (or the current line if no selection). No-op when the editor is
        read-only.

        The prefix is inserted at the start of the non-whitespace content
        on each line. When multiple lines are selected the column is the
        shared leading whitespace across all non-blank lines, so a block
        like ``    foo()`` / ``        bar()`` keeps the inner indentation
        intact: the outer four spaces are preserved and the prefix lands
        at column 4 on both rows. Blank / whitespace-only lines are
        skipped — there is no non-whitespace position to mark.

        When ``prefix`` is empty (the default), the prefix is derived from
        the buffer's file extension via ``line_comment_for_extension`` —
        ``# `` for Python/Mojo/YAML/shell, ``-- `` for SQL/Lua, etc. Falls
        back to ``// `` for unknown / file-less buffers."""
        if self.read_only:
            return
        var effective_prefix = prefix
        if len(effective_prefix.as_bytes()) == 0:
            effective_prefix = line_comment_for_extension(
                extension_of(self.file_path)
            )
            if len(effective_prefix.as_bytes()) == 0:
                effective_prefix = String("// ")
        self._push_undo()
        var sel = self.selection()
        var sr = sel[0]
        var er = sel[2]
        if not self.has_selection():
            sr = self.cursor_row
            er = self.cursor_row
        var pn = len(effective_prefix.as_bytes())
        var pb = effective_prefix.as_bytes()

        # Common leading-whitespace bytes across all non-blank lines in
        # the range. Tracked as (reference byte vector, current shared
        # length) so we can shrink to the longest matching prefix as new
        # lines are encountered. Mixed tabs/spaces collapse the shared
        # prefix at the first byte that diverges.
        var common_bytes = List[UInt8]()
        var common_len = 0
        var saw_nonblank = False
        for r in range(sr, er + 1):
            var line = self.buffer.line(r)
            var lb = line.as_bytes()
            var lws = leading_indent_bytes(line)
            if lws == len(lb):
                continue  # blank / whitespace-only
            if not saw_nonblank:
                for k in range(lws):
                    common_bytes.append(lb[k])
                common_len = lws
                saw_nonblank = True
            else:
                var maxk = common_len if common_len < lws else lws
                var k = 0
                while k < maxk and common_bytes[k] == lb[k]:
                    k += 1
                common_len = k

        # If every non-blank line already carries the prefix at the
        # shared-indent column, the toggle strips; otherwise it adds.
        var all_commented = saw_nonblank
        for r in range(sr, er + 1):
            if not all_commented:
                break
            var line = self.buffer.line(r)
            var lb = line.as_bytes()
            if leading_indent_bytes(line) == len(lb):
                continue  # blank: doesn't participate in the vote
            if len(lb) < common_len + pn:
                all_commented = False
                break
            for k in range(pn):
                if lb[common_len + k] != pb[k]:
                    all_commented = False
                    break

        for r in range(sr, er + 1):
            var line = self.buffer.line(r)
            var lb_len = len(line.as_bytes())
            if leading_indent_bytes(line) == lb_len:
                continue  # leave blank lines alone
            if all_commented:
                var before = _slice(line, 0, common_len)
                var after = _slice(line, common_len + pn, lb_len)
                self.buffer.lines[r] = before + after
            else:
                var before = _slice(line, 0, common_len)
                var after = _slice(line, common_len, lb_len)
                self.buffer.lines[r] = before + effective_prefix + after
        self.dirty = True
        # Toggle-comment touches rows ``sr..er``; mark dirty from
        # the lowest one. The early-exit logic in
        # ``highlight_incremental`` will still skip below ``er``
        # once tokenizer state stabilizes.
        self._mark_hl_dirty(sr)
        # _refresh_highlights() removed: render path flushes via Editor.flush_highlights

    fn toggle_case(mut self):
        """Invert ASCII case across the current selection (no-op if empty
        or when the editor is read-only)."""
        if self.read_only:
            return
        if not self.has_selection():
            return
        self._push_undo()
        var sel = self.selection()
        var sr = sel[0]; var sc = sel[1]
        var er = sel[2]; var ec = sel[3]
        for r in range(sr, er + 1):
            var line = self.buffer.line(r)
            var lb = line.as_bytes()
            var col_start = sc if r == sr else 0
            var col_end = ec if r == er else len(lb)
            var new_bytes = List[UInt8]()
            for i in range(len(lb)):
                if col_start <= i and i < col_end:
                    var b = Int(lb[i])
                    if 0x41 <= b and b <= 0x5A:
                        new_bytes.append(UInt8(b + 32))
                    elif 0x61 <= b and b <= 0x7A:
                        new_bytes.append(UInt8(b - 32))
                    else:
                        new_bytes.append(lb[i])
                else:
                    new_bytes.append(lb[i])
            self.buffer.lines[r] = String(StringSlice(
                ptr=new_bytes.unsafe_ptr(), length=len(new_bytes),
            ))
        self.dirty = True
        # ``toggle_case`` walks ``sr..er``; lowest changed is ``sr``.
        self._mark_hl_dirty(sr)
        # _refresh_highlights() removed: render path flushes via Editor.flush_highlights

    fn _insert_text(mut self, text: String):
        var bytes = text.as_bytes()
        var line_start = 0
        var i = 0
        while i < len(bytes):
            if bytes[i] == 0x0A:  # '\n'
                if i > line_start:
                    self.buffer.insert(
                        self.cursor_row, self.cursor_col,
                        _slice(text, line_start, i),
                    )
                    self.cursor_col += i - line_start
                var p = self.buffer.split(self.cursor_row, self.cursor_col)
                self.move_to(p[0], p[1], False)
                line_start = i + 1
            i += 1
        if line_start < len(bytes):
            var rest = _slice(text, line_start, len(bytes))
            self.buffer.insert(self.cursor_row, self.cursor_col, rest)
            self.move_to(
                self.cursor_row,
                self.cursor_col + (len(bytes) - line_start),
                False,
            )

    fn longest_line_width(self) -> Int:
        """Used by the surrounding window to size its horizontal scroll bar."""
        var m = 0
        for i in range(self.buffer.line_count()):
            var n = len(self.buffer.line(i).as_bytes())
            if n > m: m = n
        return m

    fn handle_mouse(mut self, event: Event, view: Rect) -> Bool:
        if event.kind != EVENT_MOUSE:
            return False
        # Bare hover (no button held, motion=True under xterm 1003): the
        # only thing it currently drives is the right-side minimap
        # tooltip. Don't touch typing state or selection — the user
        # hasn't actually clicked.
        if event.button == MOUSE_BUTTON_NONE:
            self._update_minimap_hover(event.pos, view)
            return True
        # Any actual mouse interaction breaks an active typing run —
        # clicking, dragging or scrolling means the user has shifted
        # attention and the next keystroke should anchor a new undo
        # step. Same idea for the smart-select stack: clicking elsewhere
        # is a fresh caret intent, so abandon the rewind history.
        self._typing_active = False
        self._smart_select_stack = List[Caret]()
        # A click on the minimap column is a "scroll-to-here" gesture,
        # not a text-area interaction — short-circuit before the gutter /
        # text-area branches below try to interpret it as a caret move.
        if event.button == MOUSE_BUTTON_LEFT \
                and event.pressed and not event.motion:
            if self._try_minimap_click(event.pos, view):
                self.clear_minimap_hover()
                return True
        # Wheel events scroll the view without moving the cursor.
        if event.button == MOUSE_WHEEL_UP:
            if event.pressed:
                self.scroll_y -= 3
                if self.scroll_y < 0: self.scroll_y = 0
            return True
        if event.button == MOUSE_WHEEL_DOWN:
            if event.pressed:
                var max_y = self.buffer.line_count() - view.height()
                if max_y < 0: max_y = 0
                self.scroll_y += 3
                if self.scroll_y > max_y: self.scroll_y = max_y
            return True
        # Right-click in the debugger gutter on a row that has a
        # breakpoint opens the BP context dialog. We resolve which row
        # the click landed on by replaying the same layout the paint
        # path uses, then check ``breakpoint_lines`` for that row. Any
        # other right-click is ignored (no generic editor context menu
        # yet).
        if event.button == MOUSE_BUTTON_RIGHT:
            if event.pressed and not event.motion:
                var total_g = self._total_gutter()
                var right_g = self._right_gutter()
                var rel = event.pos.x - view.a.x
                if total_g > 0 and rel >= 0 and rel < total_g:
                    var content_h = view.height()
                    var content_w = view.width() - total_g - right_g
                    if content_w < 1:
                        content_w = 1
                    var layout = self._layout_lines(content_h, content_w)
                    var screen_row = event.pos.y - view.a.y
                    if screen_row >= 0 and screen_row < len(layout):
                        var buf_row = layout[screen_row].line_idx
                        for k in range(len(self.breakpoint_lines)):
                            if self.breakpoint_lines[k] == buf_row:
                                self.pending_breakpoint_menu = \
                                    Optional[BreakpointMenuRequest](
                                        BreakpointMenuRequest(
                                            buf_row,
                                            event.pos.x, event.pos.y,
                                        ),
                                    )
                                break
            return True
        if event.button != MOUSE_BUTTON_LEFT:
            return False
        if not event.pressed:
            # Left-button release ends any in-flight multi-click drag.
            # We still leave ``_last_click_*`` populated so the next
            # press within ``_DOUBLE_CLICK_MS`` can promote to a
            # double- or triple-click.
            if not event.motion:
                self._dc_active = False
                self._tc_active = False
            return False
        # The gutter (debugger + line numbers + change bar + blame)
        # occupies the leftmost columns. A click there is a breakpoint
        # toggle on the corresponding buffer row — same effect as F9 on
        # that line. We stash the row and let Desktop forward to the
        # active DapManager (the editor itself owns no DAP state).
        var total_gutter = self._total_gutter()
        var right_gutter = self._right_gutter()
        var rel_x = event.pos.x - view.a.x
        var in_gutter = total_gutter > 0 and rel_x >= 0 and rel_x < total_gutter
        var cell_x = rel_x - total_gutter
        if cell_x < 0: cell_x = 0
        # Map the click's screen row through the same layout used by
        # paint, so soft-wrapped buffer rows resolve to their wrapped
        # segment instead of advancing buffer rows 1:1.
        var content_h = view.height()
        var content_w = view.width() - total_gutter - right_gutter
        if content_w < 1:
            content_w = 1
        var layout = self._layout_lines(content_h, content_w)
        var screen_row = event.pos.y - view.a.y
        if screen_row < 0:
            screen_row = 0
        var row: Int
        var seg_start: Int
        var seg_end: Int
        var seg_indent: Int
        var on_real_row = False
        if len(layout) == 0:
            row = 0
            seg_start = 0
            seg_end = 0
            seg_indent = 0
        elif screen_row >= len(layout):
            var last = layout[len(layout) - 1]
            row = last.line_idx
            seg_start = last.byte_start
            seg_end = last.byte_end
            seg_indent = last.indent_cells
        else:
            row = layout[screen_row].line_idx
            seg_start = layout[screen_row].byte_start
            seg_end = layout[screen_row].byte_end
            seg_indent = layout[screen_row].indent_cells
            on_real_row = True
        if in_gutter:
            # Drag-motion that started in the gutter is ignored — no
            # selection extend, no toggle. Initial-press only, on a row
            # that actually maps to buffer content.
            if not event.motion and on_real_row:
                # Hit-test: is the click on the git-changes column
                # specifically, over a row that has a change marker?
                # That's an "open the revert popup" gesture; everything
                # else in the gutter remains a breakpoint toggle.
                var gc_w = self._git_changes_gutter()
                var gc_x0 = self.gutter_width + self._line_number_gutter()
                var on_gc = (
                    gc_w > 0
                    and rel_x >= gc_x0
                    and rel_x < gc_x0 + gc_w
                )
                var has_change = (
                    row >= 0 and row < len(self.git_change_lines)
                    and self.git_change_lines[row] != GIT_CHANGE_NONE
                )
                if on_gc and has_change:
                    self.pending_git_revert = Optional[GitRevertRequest](
                        GitRevertRequest(row, event.pos.x, event.pos.y)
                    )
                else:
                    self.pending_breakpoint_toggle = Optional[Int](row)
            return True
        # Continuation segments paint their text shifted right by the
        # hanging indent; subtract that here so a click on the indent
        # area lands at the segment start.
        cell_x -= seg_indent
        if cell_x < 0:
            cell_x = 0
        # Translate cell offset within the visible segment to a byte
        # offset, so a click on a multi-byte glyph lands at the start of
        # that codepoint instead of in the middle of its UTF-8 sequence.
        var line = self.buffer.line(row)
        var line_n = len(line.as_bytes())
        var visible: String
        if seg_start >= line_n:
            visible = String("")
        else:
            visible = _slice(line, seg_start, seg_end)
        var col = seg_start + _utf8_byte_of_cell(visible, cell_x)
        if col > line_n: col = line_n
        # Cmd+click (native app folds super onto the alt bit; iTerm2
        # delivers Option+click on the same bit): capture a go-to-
        # definition request without moving the cursor. The host polls
        # ``consume_definition_request`` and forwards to whichever LSP
        # client is wired up. (No effect during drag-extend — that's still
        # a selection gesture.)
        if (event.mods & MOD_ALT) != 0 and not event.motion:
            var word = word_at(self.buffer.line(row), col)
            if len(word.as_bytes()) > 0:
                self.pending_definition = Optional[DefinitionRequest](
                    DefinitionRequest(row, col, word),
                )
            return True
        # Ctrl+click: stamp an extra caret at the click point without
        # disturbing the primary or any existing extras. Drag-motion
        # carries no MOD_CTRL bit (the mods are sampled on press), so
        # this fires only on the initial press. Skip the multi-click
        # cycle bookkeeping — Ctrl+click is a separate gesture and
        # shouldn't promote into double-click word selection.
        if (event.mods & MOD_CTRL) != 0 and not event.motion:
            self._add_caret(Caret(row, col, _utf8_cell_of_byte(line, col),
                                   row, col))
            return True
        if event.motion:
            # Drag-motion: extend the selection. While a multi-click
            # gesture is in progress, snap the moving end to whole-word
            # (double-click) or whole-line (triple-click) boundaries
            # anchored on the originally clicked region.
            if self._tc_active:
                self._extend_line_drag(row)
            elif self._dc_active:
                self._extend_word_drag(row, col)
            else:
                self.move_to(row, col, True)
            self._scroll_to_cursor(view)
            return True
        # Initial plain press. Drop any extra carets that an earlier
        # Ctrl+click / Ctrl+Alt+Up/Down had stamped — the user has
        # picked a single position and that becomes the new primary.
        self.clear_extra_carets()
        # Consecutive presses at the same cell within the double-click
        # window cycle through single → double → triple before
        # resetting; the count drives word vs. line selection.
        var now = monotonic_ms()
        var same_cell = (
            now - self._last_click_ms <= _DOUBLE_CLICK_MS
            and row == self._last_click_row
            and col == self._last_click_col
        )
        if same_cell:
            self._click_count += 1
            if self._click_count > 3:
                self._click_count = 1
        else:
            self._click_count = 1
        self._last_click_ms = now
        self._last_click_row = row
        self._last_click_col = col
        if self._click_count == 2:
            var wrng = _word_range_at(line, col)
            self._dc_active = True
            self._tc_active = False
            self._dc_anchor_row = row
            self._dc_anchor_start = wrng[0]
            self._dc_anchor_end = wrng[1]
            self.move_to(row, wrng[0], False)
            self.move_to(row, wrng[1], True)
        elif self._click_count == 3:
            self._tc_active = True
            self._dc_active = False
            self._tc_anchor_row = row
            var lrng = self._line_select_range(row)
            self.move_to(lrng[0], lrng[1], False)
            self.move_to(lrng[2], lrng[3], True)
            # Reset so a 4th quick press starts a fresh single click
            # instead of chaining into the cycle.
            self._last_click_ms = 0
            self._click_count = 0
        else:
            self._dc_active = False
            self._tc_active = False
            self.move_to(row, col, False)
        self._scroll_to_cursor(view)
        return True

    fn _extend_word_drag(mut self, row: Int, col: Int):
        """Word-snapped selection extend used while the user is
        double-click-dragging. The originally double-clicked word stays
        anchored; the moving end snaps to the start or end of whichever
        word the pointer is currently over."""
        var line = self.buffer.line(row)
        var rng = _word_range_at(line, col)
        var word_start = rng[0]
        var word_end = rng[1]
        var ar = self._dc_anchor_row
        var a_start = self._dc_anchor_start
        var a_end = self._dc_anchor_end
        var backward = (row < ar) or (row == ar and word_end <= a_start)
        if backward:
            self.move_to(ar, a_end, False)
            self.move_to(row, word_start, True)
        else:
            self.move_to(ar, a_start, False)
            self.move_to(row, word_end, True)

    fn _line_select_range(self, row: Int) -> Tuple[Int, Int, Int, Int]:
        """Return ``(start_row, start_col, end_row, end_col)`` for
        selecting the entire line at ``row``. Includes the trailing
        newline by extending to col 0 of the next line; on the last line
        we extend to end-of-line instead since there's no newline to
        grab."""
        var lc = self.buffer.line_count()
        if row + 1 < lc:
            return (row, 0, row + 1, 0)
        return (row, 0, row, self.buffer.line_length(row))

    fn _extend_line_drag(mut self, row: Int):
        """Line-snapped selection extend used while the user is
        triple-click-dragging. The originally triple-clicked row stays
        anchored; the selection grows to cover whole lines from the
        anchor row to the row under the pointer."""
        var ar = self._tc_anchor_row
        var lc = self.buffer.line_count()
        if row >= ar:
            self.move_to(ar, 0, False)
            if row + 1 < lc:
                self.move_to(row + 1, 0, True)
            else:
                self.move_to(row, self.buffer.line_length(row), True)
        else:
            if ar + 1 < lc:
                self.move_to(ar + 1, 0, False)
            else:
                self.move_to(ar, self.buffer.line_length(ar), False)
            self.move_to(row, 0, True)

    # --- buffer-level helpers ---------------------------------------------

    fn _delete_selection(mut self):
        var sel = self.selection()
        var sr = sel[0]; var sc = sel[1]
        var er = sel[2]; var ec = sel[3]
        if sr == er:
            var line = self.buffer.line(sr)
            self.buffer.lines[sr] = _slice(line, 0, sc) + _slice(line, ec, len(line.as_bytes()))
        else:
            var first = self.buffer.line(sr)
            var last = self.buffer.line(er)
            var head = _slice(first, 0, sc)
            var tail = _slice(last, ec, len(last.as_bytes()))
            self.buffer.lines[sr] = head + tail
            for _ in range(er - sr):
                _ = self.buffer.lines.pop(sr + 1)
        self.move_to(sr, sc, False)

    # --- cursor movement primitives ---------------------------------------

    fn _move_left(mut self, extend: Bool):
        if self.cursor_col > 0:
            var line = self.buffer.line(self.cursor_row)
            var nc = _utf8_step_backward(line, self.cursor_col)
            self.move_to(self.cursor_row, nc, extend)
        elif self.cursor_row > 0:
            var prev = self.buffer.line_length(self.cursor_row - 1)
            self.move_to(self.cursor_row - 1, prev, extend)

    fn _move_right(mut self, extend: Bool):
        var n = self.buffer.line_length(self.cursor_row)
        if self.cursor_col < n:
            var line = self.buffer.line(self.cursor_row)
            var nc = _utf8_step_forward(line, self.cursor_col)
            self.move_to(self.cursor_row, nc, extend)
        elif self.cursor_row + 1 < self.buffer.line_count():
            self.move_to(self.cursor_row + 1, 0, extend)

    fn _move_up(mut self, extend: Bool):
        if self.cursor_row > 0:
            var nr = self.cursor_row - 1
            var nc = _utf8_byte_of_cell(self.buffer.line(nr), self.desired_col)
            self.move_to(nr, nc, extend, False)

    fn _move_down(mut self, extend: Bool):
        if self.cursor_row + 1 < self.buffer.line_count():
            var nr = self.cursor_row + 1
            var nc = _utf8_byte_of_cell(self.buffer.line(nr), self.desired_col)
            self.move_to(nr, nc, extend, False)

    fn _move_word_right(mut self, extend: Bool):
        var p = self._next_word_pos(self.cursor_row, self.cursor_col)
        self.move_to(p[0], p[1], extend)

    fn _move_word_left(mut self, extend: Bool):
        var p = self._prev_word_pos(self.cursor_row, self.cursor_col)
        self.move_to(p[0], p[1], extend)

    fn _next_word_pos(self, row: Int, col: Int) -> Tuple[Int, Int]:
        """Move to end-of-word + skip following non-word chars on this line.

        At end of line, jumps to the start of the next line. One press = one
        meaningful jump, like every editor since vi. Walks by UTF-8
        codepoint so word boundaries land on character edges in
        non-ASCII text (``Godkänn`` is one word, not three).
        """
        var line = self.buffer.line(row)
        var bytes = line.as_bytes()
        var n = len(bytes)
        if col >= n:
            if row + 1 < self.buffer.line_count():
                return (row + 1, 0)
            return (row, n)
        var c = col
        while c < n:
            var step = word_char_step(line, c)
            if not step[0]:
                break
            c += step[1]
        while c < n:
            var step = word_char_step(line, c)
            if step[0]:
                break
            c += step[1]
        return (row, c)

    fn _prev_word_pos(self, row: Int, col: Int) -> Tuple[Int, Int]:
        if col == 0:
            if row > 0:
                return (row - 1, self.buffer.line_length(row - 1))
            return (0, 0)
        var line = self.buffer.line(row)
        var c = col
        while c > 0:
            var prev = prev_codepoint_start(line, c)
            var info = codepoint_at(line, prev)
            if is_word_codepoint(info[0]):
                break
            c = prev
        while c > 0:
            var prev = prev_codepoint_start(line, c)
            var info = codepoint_at(line, prev)
            if not is_word_codepoint(info[0]):
                break
            c = prev
        return (row, c)

    fn _scroll_to_cursor(mut self, view: Rect):
        var h = view.height()
        var total_gutter = self._total_gutter()
        var right_gutter = self._right_gutter()
        var w = view.width() - total_gutter - right_gutter
        if w < 1:
            w = 1
        if self.cursor_row < self.scroll_y:
            self.scroll_y = self.cursor_row
        elif self.cursor_row >= self.scroll_y + h:
            self.scroll_y = self.cursor_row - h + 1
        if self.soft_wrap:
            # No horizontal scroll on the wrap path: text reflows
            # vertically instead. Walk wrapped segments to make sure the
            # cursor's screen row fits inside the view; if the buffer
            # row's wraps push the cursor past the bottom, anchor
            # ``scroll_y`` to the cursor row so the cursor is on the
            # first visible line.
            self.scroll_x = 0
            var layout = self._layout_lines(h, w)
            if self._cursor_screen_row(layout) < 0:
                self.scroll_y = self.cursor_row
            return
        # Horizontal scroll math is done in cell columns and converted back
        # to a byte offset so ``scroll_x`` always lands on a codepoint
        # boundary — the slicing in ``paint`` would corrupt UTF-8 otherwise.
        var line = self.buffer.line(self.cursor_row)
        var cur_cell = _utf8_cell_of_byte(line, self.cursor_col)
        var scroll_cell = _utf8_cell_of_byte(line, self.scroll_x)
        if cur_cell < scroll_cell:
            scroll_cell = cur_cell
        elif cur_cell >= scroll_cell + w:
            scroll_cell = cur_cell - w + 1
        self.scroll_x = _utf8_byte_of_cell(line, scroll_cell)

    fn clamp_scroll(mut self, view: Rect):
        """Pull ``scroll_x`` / ``scroll_y`` back inside their valid ranges.

        Called every frame from ``WindowManager.fit_into``. The interesting
        case is a grow-resize: the user scrolled right while the window
        was narrow, then widened the window so the horizontal scroll bar
        disappears entirely — without this clamp, ``scroll_x`` would
        stay positive and hide leading characters that the user can no
        longer scroll back to. Vertical axis is clamped symmetrically.
        """
        var total_gutter = self._total_gutter()
        var right_gutter = self._right_gutter()
        var content_w = view.width() - total_gutter - right_gutter
        if content_w < 1:
            content_w = 1
        var content_h = view.height()
        if content_h < 1:
            content_h = 1
        if self.soft_wrap:
            self.scroll_x = 0
        else:
            var max_x = self.longest_line_width() - content_w
            if max_x < 0: max_x = 0
            if self.scroll_x > max_x:
                self.scroll_x = max_x
            if self.scroll_x < 0:
                self.scroll_x = 0
            # Re-snap to a codepoint boundary on the cursor row so a
            # multi-byte glyph isn't sliced by paint's substring.
            var line = self.buffer.line(self.cursor_row)
            var cell = _utf8_cell_of_byte(line, self.scroll_x)
            self.scroll_x = _utf8_byte_of_cell(line, cell)
        var max_y = self.buffer.line_count() - content_h
        if max_y < 0: max_y = 0
        if self.scroll_y > max_y:
            self.scroll_y = max_y
        if self.scroll_y < 0:
            self.scroll_y = 0

    fn reveal_cursor(
        mut self, view: Rect,
        margin_below: Int = 5, margin_above: Int = 0,
    ):
        """Scroll so the cursor is visible with up to ``margin_above``
        rows of context above it and ``margin_below`` below (each
        clamped to the file boundaries).

        Used after non-incremental jumps (e.g. goto-definition,
        find-next / find-prev): plain ``_scroll_to_cursor`` brings the
        cursor *just* into view, which leaves it stuck at the edge
        with no surrounding code visible — fine for typing, jarring
        for landings.
        """
        var h = view.height()
        var total_gutter = self._total_gutter()
        var right_gutter = self._right_gutter()
        var w = view.width() - total_gutter - right_gutter
        if w < 1:
            w = 1
        var max_row = self.buffer.line_count() - 1
        var top = self.cursor_row - margin_above
        if top < 0:
            top = 0
        var bottom = self.cursor_row + margin_below
        if bottom > max_row:
            bottom = max_row
        if top < self.scroll_y:
            self.scroll_y = top
        elif bottom >= self.scroll_y + h:
            self.scroll_y = bottom - h + 1
        if self.scroll_y < 0:
            self.scroll_y = 0
        if self.soft_wrap:
            self.scroll_x = 0
            var layout = self._layout_lines(h, w)
            if self._cursor_screen_row(layout) < 0:
                self.scroll_y = self.cursor_row
            return
        var line = self.buffer.line(self.cursor_row)
        var cur_cell = _utf8_cell_of_byte(line, self.cursor_col)
        var scroll_cell = _utf8_cell_of_byte(line, self.scroll_x)
        if cur_cell < scroll_cell:
            scroll_cell = cur_cell
        elif cur_cell >= scroll_cell + w:
            scroll_cell = cur_cell - w + 1
        self.scroll_x = _utf8_byte_of_cell(line, scroll_cell)


fn _caret_less(a: Caret, b: Caret) -> Bool:
    """Strict ``<`` ordering on (row, col). Used by the caret-iteration
    helpers; ties on position are broken by the dedupe step that
    follows."""
    if a.row != b.row:
        return a.row < b.row
    return a.col < b.col


fn _caret_anchor_span(c: Caret) -> Int:
    """Cheap "is this caret carrying a selection?" measure used when
    deduping two carets that landed on the same ``(row, col)``. The
    caret with the longer selection span wins so a real selection
    isn't silently dropped on top of an empty one."""
    if c.row == c.anchor_row:
        var d = c.col - c.anchor_col
        return d if d >= 0 else -d
    var d = c.row - c.anchor_row
    return d if d >= 0 else -d


fn _char_class(cp: Int) -> Int:
    """Three-way character class used by ``_word_range_at``. Word chars
    cluster, whitespace clusters, everything else clusters as
    "punctuation" — so a double-click on punctuation selects the run of
    punctuation, not just the single byte. Operates on a codepoint (not
    a byte) so non-ASCII letters cluster correctly with their ASCII
    neighbors (``ä`` and ``n`` end up in the same word)."""
    if is_word_codepoint(cp):
        return 1
    if cp == 0x20 or cp == 0x09:
        return 2
    return 3


fn _smart_indent_for_enter(
    line: String, split_col: Int, ec: EditorConfig,
) -> String:
    """Indent the new line produced by Enter inside ``line`` at byte
    ``split_col``: copy the source line's leading whitespace, and add
    one indent step when the prefix (right-trimmed) ends with a block
    opener (``{``, ``(``, ``[``, ``:``).

    The block-opener heuristic is intentionally simple — covers
    C-family / JS / Rust / Go (`{`, `(`, `[`) and Python (`:`). A real
    LSP-driven ``onTypeFormatting`` exchange would do better but isn't
    cheap to plumb through synchronously; this captures the 80% case.
    """
    var bytes = line.as_bytes()
    var n = len(bytes)
    var i = 0
    while i < n and (bytes[i] == 0x20 or bytes[i] == 0x09):
        i += 1
    var base = _slice(line, 0, i)
    var p = split_col
    if p > n:
        p = n
    while p > 0 and (bytes[p - 1] == 0x20 or bytes[p - 1] == 0x09):
        p -= 1
    if p > 0:
        var last = bytes[p - 1]
        if last == 0x7B or last == 0x28 or last == 0x5B or last == 0x3A:
            return base + ec.indent_string()
    return base


fn _word_range_at(line: String, col: Int) -> Tuple[Int, Int]:
    """Return the (start, end) byte range of the contiguous run of the
    same character class around ``col``. Empty range when ``col`` is at
    or past end of line. Walks by UTF-8 codepoint so a multibyte letter
    (``ä``) groups with its ASCII neighbors instead of breaking the
    selection in the middle of the codepoint."""
    var bytes = line.as_bytes()
    var n = len(bytes)
    if col < 0 or col >= n:
        return (col, col)
    var here = codepoint_at(line, col)
    var cls = _char_class(here[0])
    var start = col
    while start > 0:
        var prev = prev_codepoint_start(line, start)
        var info = codepoint_at(line, prev)
        if _char_class(info[0]) != cls:
            break
        start = prev
    var end = col + here[1]
    while end < n:
        var info = codepoint_at(line, end)
        if _char_class(info[0]) != cls:
            break
        end += info[1]
    return (start, end)


# --- Smart-select helpers ---------------------------------------------------
#
# These power Cmd+Up / Cmd+Down: each press of Cmd+Up grows the selection
# to the next syntactic scope (word → dotted symbol → string → enclosing
# brackets → line → block → file); Cmd+Down rewinds through the snapshots
# captured on the stack. Helpers operate on raw byte ranges and don't
# touch the editor — keeping them pure makes the levels easy to test.


fn _word_run_at_or_left(line: String, col: Int) -> Tuple[Int, Int]:
    """Word range covering ``col``. If ``col`` sits on whitespace or
    punctuation, try ``col - 1`` so a click just past the end of an
    identifier still selects it. Empty result when neither side is a
    word character. Walks by UTF-8 codepoint so non-ASCII identifiers
    select cleanly."""
    var bytes = line.as_bytes()
    var n = len(bytes)
    var c = col
    if c >= n:
        c = prev_codepoint_start(line, n)
    if c < 0:
        return (0, 0)
    var here = codepoint_at(line, c)
    if is_word_codepoint(here[0]):
        var start = c
        while start > 0:
            var prev = prev_codepoint_start(line, start)
            var info = codepoint_at(line, prev)
            if not is_word_codepoint(info[0]):
                break
            start = prev
        var end = c + here[1]
        while end < n:
            var info = codepoint_at(line, end)
            if not is_word_codepoint(info[0]):
                break
            end += info[1]
        return (start, end)
    # ``c`` not on a word char — try the codepoint immediately before it,
    # so a click just past the end of an identifier still selects the
    # whole word.
    if c > 0:
        var prev = prev_codepoint_start(line, c)
        var info = codepoint_at(line, prev)
        if is_word_codepoint(info[0]):
            var end = c
            var start = prev
            while start > 0:
                var p = prev_codepoint_start(line, start)
                var pinfo = codepoint_at(line, p)
                if not is_word_codepoint(pinfo[0]):
                    break
                start = p
            return (start, end)
    return (col, col)


fn _smart_dotted_extend(
    line: String, sc: Int, ec: Int,
) -> Tuple[Int, Int]:
    """Extend ``[sc, ec)`` over surrounding ``.``-joined word runs. So
    ``bar`` inside ``foo.bar.baz`` grows to the whole dotted path. No-op
    when nothing on either side qualifies."""
    var bytes = line.as_bytes()
    var n = len(bytes)
    var s = sc
    var e = ec
    while s >= 2 and Int(bytes[s - 1]) == 0x2E:
        var before_dot = prev_codepoint_start(line, s - 1)
        var info = codepoint_at(line, before_dot)
        if not is_word_codepoint(info[0]):
            break
        s = before_dot
        while s > 0:
            var prev = prev_codepoint_start(line, s)
            var pinfo = codepoint_at(line, prev)
            if not is_word_codepoint(pinfo[0]):
                break
            s = prev
    while e + 1 < n and Int(bytes[e]) == 0x2E:
        var after_dot = e + 1
        var info = codepoint_at(line, after_dot)
        if not is_word_codepoint(info[0]):
            break
        e = after_dot + info[1]
        while e < n:
            var einfo = codepoint_at(line, e)
            if not is_word_codepoint(einfo[0]):
                break
            e += einfo[1]
    return (s, e)


fn _is_string_quote(b: Int) -> Bool:
    """ASCII single, double, and back-tick quotes — the three string
    delimiters we recognize for smart-select."""
    return b == 0x22 or b == 0x27 or b == 0x60


fn _smart_string_around(
    line: String, sc: Int, ec: Int,
) -> Optional[Tuple[Int, Int]]:
    """Find the nearest matching pair of ASCII quote characters on
    ``line`` whose interior contains ``[sc, ec)``. Returns
    ``(open_index, close_index)`` of the quote bytes themselves.

    Same-line only: multi-line strings would need grammar awareness to
    handle correctly, so we sidestep them. Pairs are found by scanning
    left and right from the selection to the *next* same-quote char,
    which works for the common one-quote-per-side case but doesn't try
    to skip escapes — a backslash-escaped quote can mis-pair. Acceptable
    for an interactive grow-selection: the worst case is one extra
    Cmd+Up to land on the right scope.
    """
    var bytes = line.as_bytes()
    var n = len(bytes)
    var i = sc - 1
    while i >= 0:
        if _is_string_quote(Int(bytes[i])):
            var qb = Int(bytes[i])
            var j = ec
            while j < n:
                if Int(bytes[j]) == qb:
                    return Optional[Tuple[Int, Int]]((i, j))
                j += 1
            return Optional[Tuple[Int, Int]]()
        i -= 1
    return Optional[Tuple[Int, Int]]()


fn _is_blank_line(line: String) -> Bool:
    """A line of zero or more spaces / tabs is blank for the purpose of
    smart-select indent block detection."""
    var bytes = line.as_bytes()
    for i in range(len(bytes)):
        var b = Int(bytes[i])
        if b != 0x20 and b != 0x09:
            return False
    return True


fn _smart_line_content_range(line: String) -> Tuple[Int, Int]:
    """Byte range of the non-whitespace content on ``line`` — leading
    whitespace and trailing whitespace stripped. Empty range for blank
    lines."""
    var bytes = line.as_bytes()
    var n = len(bytes)
    var s = 0
    while s < n and (bytes[s] == 0x20 or bytes[s] == 0x09):
        s += 1
    var e = n
    while e > s and (bytes[e - 1] == 0x20 or bytes[e - 1] == 0x09):
        e -= 1
    return (s, e)


fn _smart_strictly_contains(
    sr1: Int, sc1: Int, er1: Int, ec1: Int,
    sr2: Int, sc2: Int, er2: Int, ec2: Int,
) -> Bool:
    """``True`` if range 2 is a *strictly* larger range than range 1 —
    i.e. range 2 contains range 1 and they aren't equal. Used to decide
    whether a candidate expansion actually grows the current selection."""
    var start_le = (sr2 < sr1) or (sr2 == sr1 and sc2 <= sc1)
    var end_ge = (er2 > er1) or (er2 == er1 and ec2 >= ec1)
    if not (start_le and end_ge):
        return False
    var start_lt = (sr2 < sr1) or (sr2 == sr1 and sc2 < sc1)
    var end_gt = (er2 > er1) or (er2 == er1 and ec2 > ec1)
    return start_lt or end_gt


fn _matching_closer(opener: Int) -> Int:
    """Closing-bracket byte for an opener byte. Returns ``0`` for
    non-bracket inputs so callers can guard with a nonzero check."""
    if opener == 0x28: return 0x29  # ( )
    if opener == 0x5B: return 0x5D  # [ ]
    if opener == 0x7B: return 0x7D  # { }
    return 0


fn _is_open_bracket(b: Int) -> Bool:
    return b == 0x28 or b == 0x5B or b == 0x7B


fn _is_close_bracket(b: Int) -> Bool:
    return b == 0x29 or b == 0x5D or b == 0x7D
