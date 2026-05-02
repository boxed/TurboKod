"""Code editor widget — text buffer, cursor, scrolling, and key handling.

Inspired by what magiblot/turbo gets from Scintilla, but written from scratch
in pure Mojo. No syntax highlighting yet (the per-cell render is all in one
attribute); the data model is simple `List[String]`, one entry per line.

Editing operations are O(line-length) for in-line insert/delete (Mojo strings
are immutable so each edit rebuilds the affected line) and O(line-count) for
inserting / removing a line. Fine for source files up to a few thousand lines.
"""

from std.collections.list import List

from .canvas import Canvas, utf8_byte_to_cell, utf8_codepoint_count
from .cell import Cell
from .clipboard import clipboard_copy, clipboard_paste
from .colors import (
    Attr, BLUE, CYAN, DARK_GRAY, LIGHT_GRAY, LIGHT_GREEN, LIGHT_RED,
    LIGHT_YELLOW, WHITE, YELLOW,
)
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_BACKSPACE, KEY_DELETE, KEY_DOWN, KEY_END, KEY_ENTER, KEY_HOME,
    KEY_LEFT, KEY_PAGEDOWN, KEY_PAGEUP, KEY_RIGHT, KEY_TAB, KEY_UP,
    MOD_ALT, MOD_CTRL, MOD_SHIFT,
    MOUSE_BUTTON_LEFT, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .editorconfig import EditorConfig, load_editorconfig_for_path
from .file_io import FileInfo, read_file, stat_file, write_file
from .git_blame import BlameLine
from .highlight import (
    DefinitionRequest, GrammarRegistry, Highlight, HighlightCache,
    extension_of, highlight_for_extension, highlight_incremental,
    word_at,
)
from std.collections.optional import Optional
from .geometry import Point, Rect
from .posix import monotonic_ms


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


# --- UTF-8 boundary helpers -------------------------------------------------
#
# The buffer's column model is byte-indexed (insert/delete need byte access),
# but the cursor must always land on a codepoint boundary so a multi-byte
# character behaves as one indivisible step. These helpers keep that invariant
# and translate between byte offsets and cell columns when vertical movement
# or a mouse click crosses lines whose byte and cell widths disagree.


fn _utf8_codepoint_size(b: Int) -> Int:
    """Byte length of the UTF-8 codepoint that begins with lead byte ``b``.
    Returns 1 for invalid leads so a stray continuation byte never traps the
    cursor in an infinite no-op loop."""
    if b < 0x80:
        return 1
    if (b & 0xE0) == 0xC0:
        return 2
    if (b & 0xF0) == 0xE0:
        return 3
    if (b & 0xF8) == 0xF0:
        return 4
    return 1


fn _utf8_step_forward(line: String, col: Int) -> Int:
    """Byte offset of the codepoint boundary one step forward from ``col``."""
    var bytes = line.as_bytes()
    var n = len(bytes)
    if col >= n:
        return n
    var step = _utf8_codepoint_size(Int(bytes[col]))
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
        i += _utf8_codepoint_size(Int(bytes[i]))
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
        i += _utf8_codepoint_size(Int(bytes[i]))
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

    fn __init__(
        out self,
        var lines: List[String],
        cursor_row: Int,
        cursor_col: Int,
        anchor_row: Int,
        anchor_col: Int,
    ):
        self.lines = lines^
        self.cursor_row = cursor_row
        self.cursor_col = cursor_col
        self.anchor_row = anchor_row
        self.anchor_col = anchor_col

    fn __copyinit__(out self, copy: Self):
        self.lines = copy.lines.copy()
        self.cursor_row = copy.cursor_row
        self.cursor_col = copy.cursor_col
        self.anchor_row = copy.anchor_row
        self.anchor_col = copy.anchor_col


# --- Editor widget ----------------------------------------------------------


struct Editor(ImplicitlyCopyable, Movable):
    """Pure-Mojo text editor widget.

    Cursor model: a single cursor at ``(cursor_row, cursor_col)`` plus an
    ``anchor`` at the same coordinates when there is no selection. Any movement
    can be performed *with* or *without* the Shift modifier; with Shift we keep
    the anchor fixed (extending the selection), without Shift we collapse the
    anchor to the new cursor position. Word movement (Ctrl) and selection
    (Shift) are independent dimensions that compose cleanly.
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
    var scroll_y: Int
    var scroll_x: Int
    # File-backing (empty file_path means buffer is not file-backed):
    var file_path: String
    var file_size: Int64
    var file_mtime: Int64
    var dirty: Bool
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
    var exec_line: Int
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
    # TextMate grammar cache. Refreshing highlights re-loads the grammar
    # via this slot; a cold load is ~100 ms for the bundled rust grammar
    # so we *really* want hits here on every keystroke. Reset on copy
    # because the cached ``Grammar`` isn't ``ImplicitlyCopyable`` (its
    # ``OnigRegex`` list aliases libonig handles); the next refresh will
    # rebuild it from the file path.
    var _hl_cache: HighlightCache

    fn __init__(out self):
        self.buffer = TextBuffer()
        self.cursor_row = 0
        self.cursor_col = 0
        self.desired_col = 0
        self.anchor_row = 0
        self.anchor_col = 0
        self.scroll_y = 0
        self.scroll_x = 0
        self.file_path = String("")
        self.file_size = Int64(0)
        self.file_mtime = Int64(0)
        self.dirty = False
        self.editorconfig = EditorConfig()
        self.highlights = List[Highlight]()
        self._highlights_dirty = True
        self._hl_dirty_row = 0
        self.pending_definition = Optional[DefinitionRequest]()
        self.gutter_width = 0
        self.breakpoint_lines = List[Int]()
        self.exec_line = -1
        self.line_numbers = False
        self.soft_wrap = False
        self.read_only = False
        self.blame_lines = List[BlameLine]()
        self.blame_visible = False
        self._undo_stack = List[EditorSnapshot]()
        self._redo_stack = List[EditorSnapshot]()
        self._typing_active = False
        self._typing_last_ms = 0
        self._hl_cache = HighlightCache()

    fn __init__(out self, var text: String):
        self.buffer = TextBuffer(text^)
        self.cursor_row = 0
        self.cursor_col = 0
        self.desired_col = 0
        self.anchor_row = 0
        self.anchor_col = 0
        self.scroll_y = 0
        self.scroll_x = 0
        self.file_path = String("")
        self.file_size = Int64(0)
        self.file_mtime = Int64(0)
        self.dirty = False
        self.editorconfig = EditorConfig()
        self.highlights = List[Highlight]()
        self._highlights_dirty = True
        self._hl_dirty_row = 0
        self.pending_definition = Optional[DefinitionRequest]()
        self.gutter_width = 0
        self.breakpoint_lines = List[Int]()
        self.exec_line = -1
        self.line_numbers = False
        self.soft_wrap = False
        self.read_only = False
        self.blame_lines = List[BlameLine]()
        self.blame_visible = False
        self._undo_stack = List[EditorSnapshot]()
        self._redo_stack = List[EditorSnapshot]()
        self._typing_active = False
        self._typing_last_ms = 0
        self._hl_cache = HighlightCache()

    @staticmethod
    fn from_file(var path: String) raises -> Self:
        var text = read_file(path)
        var info = stat_file(path)
        var ed = Editor(text^)
        ed.editorconfig = load_editorconfig_for_path(path)
        ed.file_path = path^
        ed.file_size = info.size
        ed.file_mtime = info.mtime_sec
        ed.dirty = False
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
        self.scroll_y = copy.scroll_y
        self.scroll_x = copy.scroll_x
        self.file_path = copy.file_path
        self.file_size = copy.file_size
        self.file_mtime = copy.file_mtime
        self.dirty = copy.dirty
        self.editorconfig = copy.editorconfig
        self.highlights = copy.highlights.copy()
        self._highlights_dirty = copy._highlights_dirty
        self._hl_dirty_row = copy._hl_dirty_row
        self.pending_definition = copy.pending_definition
        self.gutter_width = copy.gutter_width
        self.breakpoint_lines = copy.breakpoint_lines.copy()
        self.exec_line = copy.exec_line
        self.line_numbers = copy.line_numbers
        self.soft_wrap = copy.soft_wrap
        self.read_only = copy.read_only
        self.blame_lines = copy.blame_lines.copy()
        self.blame_visible = copy.blame_visible
        self._undo_stack = copy._undo_stack.copy()
        self._redo_stack = copy._redo_stack.copy()
        self._typing_active = copy._typing_active
        self._typing_last_ms = copy._typing_last_ms
        # Don't carry the cached grammar across a copy. ``Grammar`` owns
        # ``OnigRegex`` instances whose libonig handles we share via a
        # bitwise-aliasing copy; once we add proper ``__del__`` support
        # the aliasing could double-free. Letting the copy rebuild on
        # first refresh costs one cold load but is always correct.
        self._hl_cache = HighlightCache()

    fn flush_highlights(mut self, mut registry: GrammarRegistry):
        """Bring ``self.highlights`` up to date by tokenizing against
        the shared ``GrammarRegistry``. No-op if not ``_highlights_dirty``.

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

    fn check_for_external_change(mut self) raises -> Bool:
        """Re-stat the backing file; if it changed and we have no unsaved
        edits, reload the buffer. Returns True if a reload happened.

        If the file changed *and* the buffer is dirty, leaves both alone — the
        caller can detect the conflict by comparing ``file_mtime`` to the new
        ``stat_file`` result.
        """
        if len(self.file_path.as_bytes()) == 0:
            return False
        var info = stat_file(self.file_path)
        if not info.ok:
            return False
        if info.size == self.file_size and info.mtime_sec == self.file_mtime:
            return False
        if self.dirty:
            return False
        var text = read_file(self.file_path)
        self.buffer = TextBuffer(text)
        self.file_size = info.size
        self.file_mtime = info.mtime_sec
        # _refresh_highlights() removed: render path flushes via Editor.flush_highlights
        # Clamp cursor to the new buffer.
        var max_row = self.buffer.line_count() - 1
        if self.cursor_row > max_row: self.cursor_row = max_row
        var n = self.buffer.line_length(self.cursor_row)
        if self.cursor_col > n: self.cursor_col = n
        self.desired_col = _utf8_cell_of_byte(
            self.buffer.line(self.cursor_row), self.cursor_col,
        )
        self.anchor_row = self.cursor_row
        self.anchor_col = self.cursor_col
        return True

    # --- saving ------------------------------------------------------------

    fn text_snapshot(self) -> String:
        """Concatenate buffer lines with ``\\n`` separators (no trailing
        newline appended — a file that originally ended in ``\\n`` produces
        a trailing empty line in the buffer, which round-trips correctly).
        Used by the LSP layer for didOpen/didChange payloads. Saving uses
        ``_disk_text`` instead so editorconfig transforms (line endings,
        trailing-whitespace trim, final newline) are only applied on disk
        — the LSP server should see the buffer as-is.
        """
        var out = String("")
        var n = self.buffer.line_count()
        for i in range(n):
            if i > 0:
                out = out + String("\n")
            out = out + self.buffer.line(i)
        return out

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
        if not write_file(self.file_path, self._disk_text()):
            return False
        # Refresh stat info so check_for_external_change doesn't pick up our
        # own write as an external change.
        var info = stat_file(self.file_path)
        if info.ok:
            self.file_size = info.size
            self.file_mtime = info.mtime_sec
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
        if not write_file(self.file_path, self._disk_text()):
            self.file_path = prev_path^
            self.editorconfig = prev_config^
            return False
        var info = stat_file(self.file_path)
        if info.ok:
            self.file_size = info.size
            self.file_mtime = info.mtime_sec
        self.dirty = False
        # Extension may have changed (e.g., ``.txt`` → ``.mojo``); re-tokenize.
        # _refresh_highlights() removed: render path flushes via Editor.flush_highlights
        return True

    fn replace_all(mut self, find: String, replacement: String) -> Int:
        """Replace every occurrence of ``find`` with ``replacement`` in the
        buffer. Returns the number of replacements; sets ``dirty`` if > 0.
        Does not move the cursor (caller may want to clamp it).

        An undo step is pushed eagerly and rolled back when no replacements
        actually fired, so a bulk replace that finds nothing won't blow
        away redo history. No-op when the editor is read-only."""
        if self.read_only:
            return 0
        var fb = find.as_bytes()
        var rb_len = len(replacement.as_bytes())
        var n = len(fb)
        if n == 0:
            return 0
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

    fn _total_gutter(self) -> Int:
        return self.gutter_width + self._line_number_gutter() \
            + self._blame_gutter()

    fn _layout_lines(
        self, content_h: Int, text_width: Int,
    ) -> List[Tuple[Int, Int, Int, Int]]:
        """Per-screen-row ``(buffer_row, start_byte, end_byte, indent_cells)``.

        ``indent_cells`` is the cell offset to apply *before* painting the
        segment's text — zero on the first visual segment of a buffer
        row, and the buffer line's leading-whitespace width plus one
        indent unit on continuation segments. The hanging-indent matches
        the original line's indent so wrapped code stays visually
        aligned with its parent.

        Without soft-wrap, returns one tuple per visible buffer row from
        ``scroll_y`` onward, with ``start_byte = scroll_x``, ``end_byte``
        at the line length, and ``indent_cells = 0``. With soft-wrap on,
        every buffer row is broken into successive segments that fit
        within ``text_width`` cells (minus the hanging indent on
        continuations); codepoint boundaries are honored so a multi-byte
        glyph is never split. ``scroll_x`` is ignored on the wrap path
        (callers force it to 0 in ``toggle_soft_wrap`` and on every
        cursor move via ``_scroll_to_cursor``).
        """
        var out = List[Tuple[Int, Int, Int, Int]]()
        var n_lines = self.buffer.line_count()
        var br = self.scroll_y
        if not self.soft_wrap:
            while br < n_lines and len(out) < content_h:
                var n = self.buffer.line_length(br)
                out.append((br, self.scroll_x, n, 0))
                br += 1
            return out^
        var w = text_width
        if w < 1:
            w = 1
        var tab = self.editorconfig.effective_indent_size()
        if tab < 1:
            tab = 4
        while br < n_lines and len(out) < content_h:
            var line = self.buffer.line(br)
            var bytes = line.as_bytes()
            var line_n = len(bytes)
            if line_n == 0:
                out.append((br, 0, 0, 0))
                br += 1
                continue
            # Hanging indent applied to every wrap continuation: original
            # line's leading-whitespace width plus one indent unit. Capped
            # to ``w - 1`` so there's always at least one cell of text
            # room even on absurdly narrow viewports.
            var prefix = _leading_indent_cells(line)
            var cont_indent = prefix + tab
            if cont_indent > w - 1:
                cont_indent = w - 1
            if cont_indent < 0:
                cont_indent = 0
            var c = 0
            var first = True
            while c < line_n and len(out) < content_h:
                var indent_cells = 0 if first else cont_indent
                var seg_w = w - indent_cells
                if seg_w < 1:
                    seg_w = 1
                # Hard upper bound: at most ``seg_w`` cells from ``c``,
                # walking codepoints so a multi-byte glyph is never split.
                var cells = 0
                var e_hard = c
                while e_hard < line_n and cells < seg_w:
                    e_hard += _utf8_codepoint_size(Int(bytes[e_hard]))
                    cells += 1
                if e_hard > line_n:
                    e_hard = line_n
                # Walk back to the last symbol boundary inside ``[c, e_hard)``
                # so wrap points land between identifiers / words instead of
                # mid-symbol. Only ASCII non-word bytes count — multi-byte
                # bytes would land mid-codepoint, and a single very long
                # word with no boundary falls through to the hard break.
                var e = e_hard
                if e_hard < line_n:
                    var p = e_hard
                    while p > c + 1:
                        var b = Int(bytes[p - 1])
                        if b < 0x80 and not _is_word_char(b):
                            e = p
                            break
                        p -= 1
                out.append((br, c, e, indent_cells))
                c = e
                first = False
            br += 1
        return out^

    fn _cursor_screen_row(
        self, layout: List[Tuple[Int, Int, Int, Int]],
    ) -> Int:
        """Index into ``layout`` of the screen row that hosts the cursor,
        or -1 if the cursor lies outside the painted layout. The cursor
        sits on a buffer-row segment when its byte column falls in the
        segment's range; ties at the segment boundary go to the *next*
        segment (so a cursor parked at a wrap point shows up at the
        start of the next visual line, matching most editors)."""
        for sr in range(len(layout)):
            var br = layout[sr][0]
            if br != self.cursor_row:
                continue
            var sb = layout[sr][1]
            var eb = layout[sr][2]
            # Last segment of this buffer row in the layout?
            var is_last = (sr + 1 >= len(layout)) or (
                layout[sr + 1][0] != self.cursor_row
            )
            if self.cursor_col < sb:
                continue
            if self.cursor_col < eb:
                return sr
            if is_last:
                return sr
            # Cursor sits exactly at the wrap point — let the next
            # segment claim it.
        return -1

    # --- painting ----------------------------------------------------------

    fn paint(self, mut canvas: Canvas, view: Rect, focused: Bool):
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
        canvas.fill(view, String(" "), attr)
        # Three stacked left gutters: the debugger gutter (breakpoint
        # dot and exec arrow, owned by Desktop) sits at the very left,
        # then the line-number gutter (right-aligned, one trailing
        # space), then the optional blame gutter ("<sha> <author>").
        # Any of them can be zero-width.
        var dap_gutter = self.gutter_width
        var ln_gutter = self._line_number_gutter()
        var bl_gutter = self._blame_gutter()
        var total_gutter = dap_gutter + ln_gutter + bl_gutter
        var text_x0 = view.a.x + total_gutter
        var content_right = view.b.x
        var content_bottom = view.b.y
        var content_h = view.height()
        var content_w = view.width() - total_gutter
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
                var buf_row = layout[screen_row][0]
                var seg_start = layout[screen_row][1]
                var sy_g = view.a.y + screen_row
                for gx in range(total_gutter):
                    canvas.set(
                        view.a.x + gx, sy_g,
                        Cell(String(" "), gutter_attr, 1),
                    )
                # Each layout entry is the *first* visual segment of its
                # buffer row when either soft-wrap is off (one segment per
                # row) or this segment starts at byte 0 of the row.
                var is_first_seg = (not self.soft_wrap) or (seg_start == 0)
                if dap_gutter > 0 and is_first_seg:
                    for k in range(len(self.breakpoint_lines)):
                        if self.breakpoint_lines[k] == buf_row:
                            canvas.set(
                                view.a.x, sy_g,
                                Cell(String("●"), bp_attr, 1),
                            )
                            break
                    if buf_row == self.exec_line:
                        var ax = view.a.x + (1 if dap_gutter >= 2 else 0)
                        canvas.set(ax, sy_g, Cell(String("▶"), exec_attr, 1))
                if ln_gutter > 0 and is_first_seg:
                    var num_str = String(buf_row + 1)
                    var num_w = len(num_str.as_bytes())
                    # Right-align inside the line-number gutter, leaving
                    # the trailing column as a one-cell separator.
                    var sx = view.a.x + dap_gutter + (ln_gutter - 1) - num_w
                    if sx < view.a.x + dap_gutter:
                        sx = view.a.x + dap_gutter
                    _ = canvas.put_text(
                        Point(sx, sy_g), num_str, ln_attr,
                        view.a.x + total_gutter,
                    )
                if bl_gutter > 0 and is_first_seg \
                        and buf_row < len(self.blame_lines):
                    var bl = self.blame_lines[buf_row]
                    var bx = view.a.x + dap_gutter + ln_gutter
                    var bl_right = bx + bl_gutter - 1
                    _ = canvas.put_text(
                        Point(bx, sy_g), bl.commit, ln_attr, bl_right,
                    )
                    # Author is truncated by ``put_text``'s ``max_x`` clamp
                    # so a long name doesn't bleed into the source text.
                    var ax = bx + 8 + 1
                    _ = canvas.put_text(
                        Point(ax, sy_g), bl.author, ln_attr, bl_right,
                    )
        var sel = self.selection()
        var sel_active = self.has_selection()
        var sel_sr = sel[0]; var sel_sc = sel[1]
        var sel_er = sel[2]; var sel_ec = sel[3]
        for screen_row in range(len(layout)):
            var buf_row = layout[screen_row][0]
            var start_byte = layout[screen_row][1]
            var end_byte = layout[screen_row][2]
            var indent_cells = layout[screen_row][3]
            var seg_x0 = text_x0 + indent_cells
            var line = self.buffer.line(buf_row)
            var n = len(line.as_bytes())
            # Last segment of this buffer row in the painted layout?
            # Past-EOL selection / cursor extensions are only meaningful
            # at the trailing visual line of a wrapped buffer row.
            var is_last_seg = (screen_row + 1 >= len(layout)) or (
                layout[screen_row + 1][0] != buf_row
            )
            var visible: String
            if start_byte >= n:
                visible = String("")
            else:
                visible = _slice(line, start_byte, end_byte)
            _ = canvas.put_text(
                Point(seg_x0, view.a.y + screen_row),
                visible,
                attr,
                content_right,
            )
            # Translate overlay byte offsets into cell columns so
            # multi-byte codepoints (which paint into a single cell)
            # don't get aliased against several adjacent columns.
            var visible_cell_map = utf8_byte_to_cell(visible)
            var visible_byte_count = len(visible.as_bytes())
            var visible_cell_count = utf8_codepoint_count(visible)
            var sy_hl = view.a.y + screen_row
            # Syntax-highlight overlay: change the attr on cells covered by
            # any highlight that targets this buffer row. Glyphs come from
            # ``put_text`` above; we only adjust attributes here.
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
                    canvas.set_attr(sx_hl, sy_hl, hl.attr)
            # Overlay selection highlight on this row, if any.
            if sel_active and sel_sr <= buf_row and buf_row <= sel_er:
                var row_start = 0 if buf_row > sel_sr else sel_sc
                var row_end = n if buf_row < sel_er else sel_ec
                # Selection past EOL: highlight one trailing cell so empty-
                # line selections are still visible. Only meaningful on the
                # last visual segment of the wrapped buffer row.
                if buf_row < sel_er and row_end == row_start and is_last_seg:
                    row_end = row_start + 1
                # Clip to the visible segment.
                var seg_lo = row_start if row_start > start_byte else start_byte
                var seg_hi = row_end
                if not is_last_seg and seg_hi > end_byte:
                    seg_hi = end_byte
                if seg_lo >= seg_hi:
                    continue
                var sel_byte_start = seg_lo - start_byte
                var sel_byte_end = seg_hi - start_byte
                if sel_byte_start < 0: sel_byte_start = 0
                # Map each end of the byte range to a cell. Past-EOL
                # extensions get one cell per virtual byte so empty-line
                # and trailing-space selections stay visible.
                var sel_cell_start: Int
                if sel_byte_start < visible_byte_count:
                    sel_cell_start = visible_cell_map[sel_byte_start]
                else:
                    sel_cell_start = visible_cell_count + (sel_byte_start - visible_byte_count)
                var sel_cell_end: Int
                if sel_byte_end < visible_byte_count:
                    sel_cell_end = visible_cell_map[sel_byte_end]
                elif sel_byte_end == visible_byte_count:
                    sel_cell_end = visible_cell_count
                else:
                    sel_cell_end = visible_cell_count + (sel_byte_end - visible_byte_count)
                var sx0 = seg_x0 + sel_cell_start
                var sx1 = seg_x0 + sel_cell_end
                if sx1 > content_right: sx1 = content_right
                var sy = view.a.y + screen_row
                for x in range(sx0, sx1):
                    var cell_off = x - seg_x0
                    if cell_off < visible_cell_count:
                        canvas.set_attr(x, sy, sel_attr)
                    else:
                        # Past EOL — paint an explicit space so the
                        # selection extends visibly past the line's
                        # final character.
                        canvas.set(x, sy, Cell(String(" "), sel_attr, 1))
        # Cursor: a reverse-video cell when focused (only inside content area).
        if focused:
            var sr = self._cursor_screen_row(layout)
            if sr >= 0:
                var seg_start = layout[sr][1]
                var seg_end = layout[sr][2]
                var indent = layout[sr][3]
                var seg_x0 = text_x0 + indent
                var line = self.buffer.line(self.cursor_row)
                var line_byte_count = len(line.as_bytes())
                var visible_str: String
                if seg_start >= line_byte_count:
                    visible_str = String("")
                else:
                    visible_str = _slice(line, seg_start, seg_end)
                var cursor_cell_map = utf8_byte_to_cell(visible_str)
                var cursor_cell_count = utf8_codepoint_count(visible_str)
                var visible_byte_count = len(visible_str.as_bytes())
                var cursor_byte = self.cursor_col - seg_start
                var cell_offset: Int
                if cursor_byte < 0:
                    cell_offset = 0
                elif cursor_byte < visible_byte_count:
                    cell_offset = cursor_cell_map[cursor_byte]
                else:
                    cell_offset = cursor_cell_count + (cursor_byte - visible_byte_count)
                var sx = seg_x0 + cell_offset
                var sy = view.a.y + sr
                if seg_x0 <= sx and sx < content_right \
                   and view.a.y <= sy and sy < content_bottom:
                    if self.cursor_col < line_byte_count:
                        canvas.set_attr(sx, sy, Attr(BLUE, YELLOW))
                    else:
                        # Cursor is past EOL — paint a visible block so the
                        # caret is still visible.
                        canvas.set(sx, sy, Cell(String(" "), Attr(BLUE, YELLOW), 1))

    # --- event handling ----------------------------------------------------

    fn handle_key(mut self, event: Event, view: Rect) -> Bool:
        if event.kind != EVENT_KEY:
            return False
        # Capture the typing-group flag before any branch touches it, then
        # default to "broken" — every non-typing path (cursor moves, edits,
        # clipboard ops, …) leaves the flag false so the next keystroke
        # starts a fresh undo group. The printable-insert branch reads
        # ``was_typing`` to decide whether to extend, then explicitly
        # re-arms the flag at the end of its work.
        var was_typing = self._typing_active
        var prev_typing_ms = self._typing_last_ms
        self._typing_active = False
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
        var extend = (event.mods & MOD_SHIFT) != 0
        # Either Ctrl or Alt triggers word jumps. Ctrl is the Linux/Windows
        # convention; Alt is the macOS convention (and what iTerm2/Terminal.app
        # send by default for Option+Arrow via the readline ``ESC f``/``ESC b``
        # sequences, which the terminal parser translates to KEY_RIGHT/LEFT +
        # MOD_ALT).
        var word = (event.mods & MOD_CTRL) != 0 or (event.mods & MOD_ALT) != 0
        if k == KEY_LEFT:
            if word:
                self._move_word_left(extend)
            else:
                self._move_left(extend)
        elif k == KEY_RIGHT:
            if word:
                self._move_word_right(extend)
            else:
                self._move_right(extend)
        elif k == KEY_UP:
            self._move_up(extend)
        elif k == KEY_DOWN:
            self._move_down(extend)
        elif k == KEY_HOME:
            self.move_to(self.cursor_row, 0, extend)
        elif k == KEY_END:
            self.move_to(self.cursor_row, self.buffer.line_length(self.cursor_row), extend)
        elif k == KEY_PAGEUP:
            var step = view.height()
            var nr = self.cursor_row - step
            if nr < 0: nr = 0
            var nc = _utf8_byte_of_cell(self.buffer.line(nr), self.desired_col)
            self.move_to(nr, nc, extend, False)
        elif k == KEY_PAGEDOWN:
            var step = view.height()
            var nr = self.cursor_row + step
            var max_row = self.buffer.line_count() - 1
            if nr > max_row: nr = max_row
            var nc = _utf8_byte_of_cell(self.buffer.line(nr), self.desired_col)
            self.move_to(nr, nc, extend, False)
        elif k == KEY_BACKSPACE:
            if self.read_only:
                return True
            # Skip the snapshot when the keystroke can't actually change
            # anything (cursor at (0, 0) with no selection) — otherwise
            # repeated backspaces at the buffer head would clobber redo.
            if self.has_selection() \
                    or self.cursor_col > 0 or self.cursor_row > 0:
                self._push_undo()
            if self.has_selection():
                self._delete_selection()
            else:
                var p = self.buffer.delete_before(self.cursor_row, self.cursor_col)
                self.move_to(p[0], p[1], False)
            self.dirty = True
            self._mark_hl_dirty(pre_dirty_row)
        elif k == KEY_DELETE:
            if self.read_only:
                return True
            # Same no-op guard: at end-of-buffer with no selection, Delete
            # is a no-op and shouldn't burn an undo entry.
            var at_end = self.cursor_col \
                    >= self.buffer.line_length(self.cursor_row) \
                and self.cursor_row + 1 >= self.buffer.line_count()
            if self.has_selection() or not at_end:
                self._push_undo()
            if self.has_selection():
                self._delete_selection()
            else:
                self.buffer.delete_at(self.cursor_row, self.cursor_col)
            self.dirty = True
            self._mark_hl_dirty(pre_dirty_row)
        elif k == KEY_ENTER:
            if self.read_only:
                return True
            self._push_undo()
            if self.has_selection():
                self._delete_selection()
            var p = self.buffer.split(self.cursor_row, self.cursor_col)
            self.move_to(p[0], p[1], False)
            self.dirty = True
            self._mark_hl_dirty(pre_dirty_row)
        elif k == KEY_TAB:
            if self.read_only:
                return True
            self._push_undo()
            if self.has_selection():
                self._delete_selection()
            # editorconfig drives indent width / style. Default produces
            # the original 4-space tab when no ``.editorconfig`` was found.
            var indent = self.editorconfig.indent_string()
            var indent_n = len(indent.as_bytes())
            self.buffer.insert(self.cursor_row, self.cursor_col, indent)
            self.move_to(self.cursor_row, self.cursor_col + indent_n, False)
            self.dirty = True
            self._mark_hl_dirty(pre_dirty_row)
        elif k == UInt32(0x03):    # Ctrl+C — non-mutating
            self.copy_to_clipboard()
        elif k == UInt32(0x18):    # Ctrl+X
            if self.read_only:
                return True
            self.cut_to_clipboard()
            self._mark_hl_dirty(pre_dirty_row)
        elif k == UInt32(0x16):    # Ctrl+V
            if self.read_only:
                return True
            self.paste_from_clipboard()
            self._mark_hl_dirty(pre_dirty_row)
        elif UInt32(0x20) <= k and k < UInt32(0x7F):
            # Modified letters are commands, not text — defer to whatever
            # the caller wants to do with them (e.g., a hotkey table).
            # MOD_SHIFT is fine: capitals already arrive with a different
            # codepoint, so a leftover SHIFT bit just means a shifted
            # printable that the terminal pre-folded.
            if (event.mods & MOD_CTRL) != 0 or (event.mods & MOD_ALT) != 0:
                return False
            if self.read_only:
                return True
            # Group consecutive printable inserts into a single undo step.
            # Boundaries: a typing pause longer than ``_TYPING_DEBOUNCE_MS``,
            # an active selection (typing-into-selection is a destructive
            # replace, not a continuation), or anything that already cleared
            # ``was_typing`` (cursor move, edit, paste, mouse, …). Spaces
            # don't break the run on their own — that's what the debounce
            # is for, and pausing between sentences naturally yields a
            # boundary while a fast-typed line stays one step.
            var now = monotonic_ms()
            var extend_group = was_typing and not self.has_selection() \
                and now - prev_typing_ms <= _TYPING_DEBOUNCE_MS
            if not extend_group:
                self._push_undo()
            if self.has_selection():
                self._delete_selection()
            self.buffer.insert(self.cursor_row, self.cursor_col, chr(Int(k)))
            self.move_to(self.cursor_row, self.cursor_col + 1, False)
            self._typing_active = True
            self._typing_last_ms = now
            self.dirty = True
            self._mark_hl_dirty(pre_dirty_row)
        else:
            return False
        self._scroll_to_cursor(view)
        # Re-tokenize only when this keystroke actually mutated the
        # buffer. Mutating branches set ``_highlights_dirty`` via
        # ``_mark_hl_dirty`` next to their existing ``self.dirty =
        # True`` write; the actual tokenization is deferred to the
        # render path's ``Editor.flush_highlights`` call so we don't
        # need a ``GrammarRegistry`` parameter on every edit method.
        return True

    # --- clipboard / programmatic edit API --------------------------------

    fn selection_text(self) -> String:
        """Return the currently-selected text (empty when no selection)."""
        if not self.has_selection():
            return String("")
        var sel = self.selection()
        var sr = sel[0]; var sc = sel[1]
        var er = sel[2]; var ec = sel[3]
        if sr == er:
            return _slice(self.buffer.line(sr), sc, ec)
        var first = self.buffer.line(sr)
        var result = _slice(first, sc, len(first.as_bytes()))
        for r in range(sr + 1, er):
            result = result + String("\n") + self.buffer.line(r)
        result = result + String("\n") + _slice(self.buffer.line(er), 0, ec)
        return result

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
        """Copy the current selection to the system clipboard. No-op when
        nothing is selected."""
        if self.has_selection():
            clipboard_copy(self.selection_text())

    fn cut_to_clipboard(mut self):
        """Copy the selection to the clipboard, then remove it from the
        buffer. No-op when nothing is selected — the undo stack is left
        untouched in that case. Read-only editors fall through to a copy
        (so Ctrl+X still grabs the selection) without mutating the buffer."""
        if not self.has_selection():
            return
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

    fn paste_from_clipboard(mut self):
        """Replace any selection with the system clipboard's contents."""
        var text = clipboard_paste()
        self.paste_text(text)

    # --- turbo-style editor commands --------------------------------------

    fn goto_line(mut self, one_based_line: Int):
        """Move the cursor to the start of ``one_based_line`` (clamped)."""
        var r = one_based_line - 1
        if r < 0: r = 0
        var max_r = self.buffer.line_count() - 1
        if r > max_r: r = max_r
        self.move_to(r, 0, False)

    fn find_next(mut self, needle: String) -> Bool:
        """Search forward from the cursor for ``needle``; select on hit."""
        if len(needle.as_bytes()) == 0:
            return False
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

    fn find_prev(mut self, needle: String) -> Bool:
        """Search backward from the cursor for ``needle``; select on hit.
        Wraps around to the file end when nothing earlier matches."""
        if len(needle.as_bytes()) == 0:
            return False
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

    fn toggle_comment(mut self, prefix: String = String("// ")):
        """Toggle a line-comment prefix on every line touched by the selection
        (or the current line if no selection). No-op when the editor is
        read-only."""
        if self.read_only:
            return
        self._push_undo()
        var sel = self.selection()
        var sr = sel[0]
        var er = sel[2]
        if not self.has_selection():
            sr = self.cursor_row
            er = self.cursor_row
        var pn = len(prefix.as_bytes())
        # If every line begins with the prefix, strip; else add.
        var all_commented = True
        for r in range(sr, er + 1):
            var line = self.buffer.line(r)
            var lb = line.as_bytes()
            if len(lb) < pn:
                all_commented = False
                break
            var pb = prefix.as_bytes()
            for k in range(pn):
                if lb[k] != pb[k]:
                    all_commented = False
                    break
            if not all_commented:
                break
        for r in range(sr, er + 1):
            var line = self.buffer.line(r)
            if all_commented:
                self.buffer.lines[r] = _slice(line, pn, len(line.as_bytes()))
            else:
                self.buffer.lines[r] = prefix + line
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
        # Any mouse interaction breaks an active typing run — clicking,
        # dragging or scrolling means the user has shifted attention and
        # the next keystroke should anchor a new undo step.
        self._typing_active = False
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
        if event.button != MOUSE_BUTTON_LEFT:
            return False
        if not event.pressed:
            return False
        # The gutter (debugger + line numbers) occupies the leftmost
        # columns; clicks there land on column 0 (so a gutter click
        # still picks the corresponding line, just like clicking the
        # line number in most editors). The actual breakpoint toggle is
        # on F9 — handled by Desktop, since only it knows the active
        # DapManager.
        var total_gutter = self._total_gutter()
        var cell_x = event.pos.x - view.a.x - total_gutter
        if cell_x < 0: cell_x = 0
        # Map the click's screen row through the same layout used by
        # paint, so soft-wrapped buffer rows resolve to their wrapped
        # segment instead of advancing buffer rows 1:1.
        var content_h = view.height()
        var content_w = view.width() - total_gutter
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
        if len(layout) == 0:
            row = 0
            seg_start = 0
            seg_end = 0
            seg_indent = 0
        elif screen_row >= len(layout):
            var last = layout[len(layout) - 1]
            row = last[0]
            seg_start = last[1]
            seg_end = last[2]
            seg_indent = last[3]
        else:
            row = layout[screen_row][0]
            seg_start = layout[screen_row][1]
            seg_end = layout[screen_row][2]
            seg_indent = layout[screen_row][3]
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
        # Press collapses; drag-motion extends.
        self.move_to(row, col, event.motion)
        self._scroll_to_cursor(view)
        return True

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
        meaningful jump, like every editor since vi.
        """
        var line = self.buffer.line(row)
        var bytes = line.as_bytes()
        var n = len(bytes)
        if col >= n:
            if row + 1 < self.buffer.line_count():
                return (row + 1, 0)
            return (row, n)
        var c = col
        while c < n and _is_word_char(Int(bytes[c])):
            c += 1
        while c < n and not _is_word_char(Int(bytes[c])):
            c += 1
        return (row, c)

    fn _prev_word_pos(self, row: Int, col: Int) -> Tuple[Int, Int]:
        if col == 0:
            if row > 0:
                return (row - 1, self.buffer.line_length(row - 1))
            return (0, 0)
        var line = self.buffer.line(row)
        var bytes = line.as_bytes()
        var c = col
        while c > 0 and not _is_word_char(Int(bytes[c - 1])):
            c -= 1
        while c > 0 and _is_word_char(Int(bytes[c - 1])):
            c -= 1
        return (row, c)

    fn _scroll_to_cursor(mut self, view: Rect):
        var h = view.height()
        var total_gutter = self._total_gutter()
        var w = view.width() - total_gutter
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
        var content_w = view.width() - total_gutter
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
        var w = view.width() - total_gutter
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


fn _leading_indent_cells(line: String) -> Int:
    """Cell width of the leading whitespace on ``line``.

    Each leading space or tab byte counts as one cell — matching the
    rest of the editor's byte-as-cell column model. Used by soft-wrap to
    align continuation lines under their parent's indent.
    """
    var bytes = line.as_bytes()
    var i = 0
    while i < len(bytes) and (bytes[i] == 0x20 or bytes[i] == 0x09):
        i += 1
    return i


fn _is_word_char(b: Int) -> Bool:
    """ASCII alphanumeric or underscore — the standard ``\\w`` regex class."""
    if b == 0x5F:
        return True
    if 0x30 <= b and b <= 0x39:
        return True
    if 0x41 <= b and b <= 0x5A:
        return True
    if 0x61 <= b and b <= 0x7A:
        return True
    return False
