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
    Attr, BLUE, CYAN, DARK_GRAY, LIGHT_GRAY, LIGHT_RED, LIGHT_YELLOW,
    WHITE, YELLOW,
)
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_BACKSPACE, KEY_DELETE, KEY_DOWN, KEY_END, KEY_ENTER, KEY_HOME,
    KEY_LEFT, KEY_PAGEDOWN, KEY_PAGEUP, KEY_RIGHT, KEY_TAB, KEY_UP,
    MOD_ALT, MOD_CTRL, MOD_SHIFT,
    MOUSE_BUTTON_LEFT, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .file_io import FileInfo, read_file, stat_file, write_file
from .highlight import (
    DefinitionRequest, Highlight, extension_of, highlight_for_extension,
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
    # Syntax highlighting overlay. ``_highlights_dirty`` triggers
    # ``_refresh_highlights`` after edits / file loads.
    var highlights: List[Highlight]
    var _highlights_dirty: Bool
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
        self.highlights = List[Highlight]()
        self._highlights_dirty = True
        self.pending_definition = Optional[DefinitionRequest]()
        self.gutter_width = 0
        self.breakpoint_lines = List[Int]()
        self.exec_line = -1
        self._undo_stack = List[EditorSnapshot]()
        self._redo_stack = List[EditorSnapshot]()
        self._typing_active = False
        self._typing_last_ms = 0

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
        self.highlights = List[Highlight]()
        self._highlights_dirty = True
        self.pending_definition = Optional[DefinitionRequest]()
        self.gutter_width = 0
        self.breakpoint_lines = List[Int]()
        self.exec_line = -1
        self._undo_stack = List[EditorSnapshot]()
        self._redo_stack = List[EditorSnapshot]()
        self._typing_active = False
        self._typing_last_ms = 0

    @staticmethod
    fn from_file(var path: String) raises -> Self:
        var text = read_file(path)
        var info = stat_file(path)
        var ed = Editor(text^)
        ed.file_path = path^
        ed.file_size = info.size
        ed.file_mtime = info.mtime_sec
        ed.dirty = False
        ed._refresh_highlights()
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
        self.highlights = copy.highlights.copy()
        self._highlights_dirty = copy._highlights_dirty
        self.pending_definition = copy.pending_definition
        self.gutter_width = copy.gutter_width
        self.breakpoint_lines = copy.breakpoint_lines.copy()
        self.exec_line = copy.exec_line
        self._undo_stack = copy._undo_stack.copy()
        self._redo_stack = copy._redo_stack.copy()
        self._typing_active = copy._typing_active
        self._typing_last_ms = copy._typing_last_ms

    fn _refresh_highlights(mut self):
        var ext = extension_of(self.file_path)
        self.highlights = highlight_for_extension(ext, self.buffer.lines)
        self._highlights_dirty = False

    fn refresh_highlights(mut self):
        """Re-tokenize and replace ``highlights`` immediately. Call this when
        the host knows the buffer changed in a way that bypassed
        ``handle_key`` (e.g., setting ``file_path`` directly)."""
        self._refresh_highlights()

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
        self._highlights_dirty = True
        # Undo/redo lands on a saved state; the next typing should start a
        # new group rather than extend whatever was running before.
        self._typing_active = False
        self._refresh_highlights()

    fn undo(mut self) -> Bool:
        """Roll back the last mutation. Returns False when the stack is empty.

        The caller is responsible for re-scrolling — pass the editor's view
        rect to ``reveal_cursor`` afterwards if you want the cursor on screen.
        """
        if len(self._undo_stack) == 0:
            return False
        var snap = self._undo_stack.pop()
        self._redo_stack.append(self._snapshot())
        self._restore(snap)
        return True

    fn redo(mut self) -> Bool:
        """Replay the most recently undone mutation. False when nothing to redo."""
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
        self._refresh_highlights()
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
        Used by ``save`` and by the LSP layer for didOpen/didChange payloads.
        """
        var out = String("")
        var n = self.buffer.line_count()
        for i in range(n):
            if i > 0:
                out = out + String("\n")
            out = out + self.buffer.line(i)
        return out

    fn save(mut self) raises -> Bool:
        """Write the buffer back to ``file_path``. Returns False if the
        editor has no backing path (caller should trigger Save As) or the
        write fails.
        """
        if len(self.file_path.as_bytes()) == 0:
            return False
        if not write_file(self.file_path, self.text_snapshot()):
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
        """Write the buffer to ``path`` and adopt it as the new backing file."""
        if not write_file(path, self.text_snapshot()):
            return False
        self.file_path = path^
        var info = stat_file(self.file_path)
        if info.ok:
            self.file_size = info.size
            self.file_mtime = info.mtime_sec
        self.dirty = False
        # Extension may have changed (e.g., ``.txt`` → ``.mojo``); re-tokenize.
        self._refresh_highlights()
        return True

    fn replace_all(mut self, find: String, replacement: String) -> Int:
        """Replace every occurrence of ``find`` with ``replacement`` in the
        buffer. Returns the number of replacements; sets ``dirty`` if > 0.
        Does not move the cursor (caller may want to clamp it).

        An undo step is pushed eagerly and rolled back when no replacements
        actually fired, so a bulk replace that finds nothing won't blow
        away redo history."""
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
            self._highlights_dirty = True
            # Clamp the cursor (line lengths may have changed under it).
            var max_row = self.buffer.line_count() - 1
            if self.cursor_row > max_row: self.cursor_row = max_row
            var nlen = self.buffer.line_length(self.cursor_row)
            if self.cursor_col > nlen: self.cursor_col = nlen
            self.anchor_row = self.cursor_row
            self.anchor_col = self.cursor_col
            _ = rb_len   # silence unused warning if compiler reports it
            self._refresh_highlights()
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

    # --- painting ----------------------------------------------------------

    fn paint(self, mut canvas: Canvas, view: Rect, focused: Bool):
        var attr = Attr(YELLOW, BLUE)
        var sel_attr = Attr(YELLOW, CYAN)
        canvas.fill(view, String(" "), attr)
        # Reserve ``gutter`` columns at the left for the debugger gutter.
        # Everything in this method's text/cursor/selection passes uses
        # ``text_x0`` as its origin x — the original code used
        # ``view.a.x`` directly, and adding the gutter is just a shift.
        # When ``gutter_width == 0`` this is a no-op and behaves
        # identically to the pre-DAP editor.
        var gutter = self.gutter_width
        var text_x0 = view.a.x + gutter
        var content_right = view.b.x
        var content_bottom = view.b.y
        var content_h = view.height()
        # Gutter pass — render breakpoint / exec markers per visible row.
        # Done before text/highlight overlay so the markers aren't
        # clobbered by anything downstream.
        if gutter > 0:
            var gutter_attr = Attr(LIGHT_GRAY, BLUE)
            var bp_attr = Attr(LIGHT_RED, BLUE)
            var exec_attr = Attr(LIGHT_YELLOW, BLUE)
            for screen_row in range(content_h):
                var buf_row = self.scroll_y + screen_row
                if buf_row >= self.buffer.line_count():
                    break
                var sy_g = view.a.y + screen_row
                for gx in range(gutter):
                    canvas.set(
                        view.a.x + gx, sy_g,
                        Cell(String(" "), gutter_attr, 1),
                    )
                # Breakpoint dot in column 0 of the gutter.
                for k in range(len(self.breakpoint_lines)):
                    if self.breakpoint_lines[k] == buf_row:
                        canvas.set(
                            view.a.x, sy_g,
                            Cell(String("●"), bp_attr, 1),
                        )
                        break
                if buf_row == self.exec_line:
                    var ax = view.a.x + (1 if gutter >= 2 else 0)
                    canvas.set(ax, sy_g, Cell(String("▶"), exec_attr, 1))
        var sel = self.selection()
        var sel_active = self.has_selection()
        var sel_sr = sel[0]; var sel_sc = sel[1]
        var sel_er = sel[2]; var sel_ec = sel[3]
        for screen_row in range(content_h):
            var buf_row = self.scroll_y + screen_row
            if buf_row >= self.buffer.line_count():
                break
            var line = self.buffer.line(buf_row)
            var n = len(line.as_bytes())
            var visible: String
            if self.scroll_x >= n:
                visible = String("")
            elif self.scroll_x > 0:
                visible = _slice(line, self.scroll_x, n)
            else:
                visible = line
            _ = canvas.put_text(
                Point(text_x0, view.a.y + screen_row),
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
                var hl_byte_start = hl.col_start - self.scroll_x
                var hl_byte_end = hl.col_end - self.scroll_x
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
                    var sx_hl = text_x0 + cell_off
                    if sx_hl >= content_right:
                        break
                    canvas.set_attr(sx_hl, sy_hl, hl.attr)
            # Overlay selection highlight on this row, if any.
            if sel_active and sel_sr <= buf_row and buf_row <= sel_er:
                var row_start = 0 if buf_row > sel_sr else sel_sc
                var row_end = n if buf_row < sel_er else sel_ec
                # Selection past EOL: highlight one trailing cell so empty-line
                # selections are still visible.
                if buf_row < sel_er and row_end == row_start:
                    row_end = row_start + 1
                var sel_byte_start = row_start - self.scroll_x
                var sel_byte_end = row_end - self.scroll_x
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
                var sx0 = text_x0 + sel_cell_start
                var sx1 = text_x0 + sel_cell_end
                if sx1 > content_right: sx1 = content_right
                var sy = view.a.y + screen_row
                for x in range(sx0, sx1):
                    var cell_off = x - text_x0
                    if cell_off < visible_cell_count:
                        canvas.set_attr(x, sy, sel_attr)
                    else:
                        # Past EOL — paint an explicit space so the
                        # selection extends visibly past the line's
                        # final character.
                        canvas.set(x, sy, Cell(String(" "), sel_attr, 1))
        # Cursor: a reverse-video cell when focused (only inside content area).
        if focused:
            var line = self.buffer.line(self.cursor_row)
            var line_byte_count = len(line.as_bytes())
            var cursor_byte = self.cursor_col - self.scroll_x
            # Visible portion of *this* line for cell-mapping. We can't
            # reuse the loop's variable since the cursor row may not be
            # the row currently being painted on a given iteration.
            var visible_str: String
            if self.scroll_x >= line_byte_count:
                visible_str = String("")
            elif self.scroll_x > 0:
                visible_str = _slice(line, self.scroll_x, line_byte_count)
            else:
                visible_str = line
            var cursor_cell_map = utf8_byte_to_cell(visible_str)
            var cursor_cell_count = utf8_codepoint_count(visible_str)
            var visible_byte_count = len(visible_str.as_bytes())
            var cell_offset: Int
            if cursor_byte < 0:
                cell_offset = 0
            elif cursor_byte < visible_byte_count:
                cell_offset = cursor_cell_map[cursor_byte]
            else:
                # At or past EOL: each byte beyond the end claims its
                # own cell so successive ``Right`` presses past EOL
                # keep advancing visibly.
                cell_offset = cursor_cell_count + (cursor_byte - visible_byte_count)
            var sx = text_x0 + cell_offset
            var sy = view.a.y + (self.cursor_row - self.scroll_y)
            if text_x0 <= sx and sx < content_right \
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
            self._highlights_dirty = True
        elif k == KEY_DELETE:
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
            self._highlights_dirty = True
        elif k == KEY_ENTER:
            self._push_undo()
            if self.has_selection():
                self._delete_selection()
            var p = self.buffer.split(self.cursor_row, self.cursor_col)
            self.move_to(p[0], p[1], False)
            self.dirty = True
            self._highlights_dirty = True
        elif k == KEY_TAB:
            self._push_undo()
            if self.has_selection():
                self._delete_selection()
            self.buffer.insert(self.cursor_row, self.cursor_col, String("    "))
            self.move_to(self.cursor_row, self.cursor_col + 4, False)
            self.dirty = True
            self._highlights_dirty = True
        elif k == UInt32(0x03):    # Ctrl+C — non-mutating
            self.copy_to_clipboard()
        elif k == UInt32(0x18):    # Ctrl+X
            self.cut_to_clipboard()
            self._highlights_dirty = True
        elif k == UInt32(0x16):    # Ctrl+V
            self.paste_from_clipboard()
            self._highlights_dirty = True
        elif UInt32(0x20) <= k and k < UInt32(0x7F):
            # Modified letters are commands, not text — defer to whatever
            # the caller wants to do with them (e.g., a hotkey table).
            # MOD_SHIFT is fine: capitals already arrive with a different
            # codepoint, so a leftover SHIFT bit just means a shifted
            # printable that the terminal pre-folded.
            if (event.mods & MOD_CTRL) != 0 or (event.mods & MOD_ALT) != 0:
                return False
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
            self._highlights_dirty = True
        else:
            return False
        self._scroll_to_cursor(view)
        # Re-tokenize only when this keystroke actually mutated the buffer.
        # Mutating branches set ``_highlights_dirty`` next to their existing
        # ``self.dirty = True`` write, so cursor moves don't trigger a
        # rebuild every press.
        if self._highlights_dirty:
            self._refresh_highlights()
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
        true no-op)."""
        var text = self.selection_text()
        if self.has_selection():
            self._push_undo()
            self._delete_selection()
            self.dirty = True
            self._highlights_dirty = True
        return text

    fn paste_text(mut self, text: String):
        """Replace any selection then insert ``text`` (newlines split lines).
        Pushes an undo step when there's something to do — a paste with
        empty clipboard and no selection is a no-op and won't disturb the
        undo history."""
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
        untouched in that case."""
        if not self.has_selection():
            return
        var text = self.selection_text()
        clipboard_copy(text)
        self._push_undo()
        self._delete_selection()
        self.dirty = True
        self._highlights_dirty = True

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

    fn toggle_comment(mut self, prefix: String = String("// ")):
        """Toggle a line-comment prefix on every line touched by the selection
        (or the current line if no selection)."""
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
        self._highlights_dirty = True
        self._refresh_highlights()

    fn toggle_case(mut self):
        """Invert ASCII case across the current selection (no-op if empty)."""
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
        self._highlights_dirty = True
        self._refresh_highlights()

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
        # The gutter occupies the leftmost ``gutter_width`` columns;
        # clicks there land on column 0 (so a gutter click still picks
        # the corresponding line, just like clicking the line number in
        # most editors). The actual breakpoint toggle is on F9 — handled
        # by Desktop, since only it knows the active DapManager.
        var cell_x = event.pos.x - view.a.x - self.gutter_width
        if cell_x < 0: cell_x = 0
        var row = event.pos.y - view.a.y + self.scroll_y
        if row < 0: row = 0
        var max_row = self.buffer.line_count() - 1
        if row > max_row: row = max_row
        # Translate cell offset within the visible portion of the row to a
        # byte offset, so a click on a multi-byte glyph lands at the start
        # of that codepoint instead of in the middle of its UTF-8 sequence.
        var line = self.buffer.line(row)
        var line_n = len(line.as_bytes())
        var visible: String
        if self.scroll_x >= line_n:
            visible = String("")
        elif self.scroll_x > 0:
            visible = _slice(line, self.scroll_x, line_n)
        else:
            visible = line
        var col = self.scroll_x + _utf8_byte_of_cell(visible, cell_x)
        if col > line_n: col = line_n
        # Cmd+click (delivered by iTerm2 as Left+Alt): capture a go-to-
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
        var w = view.width() - self.gutter_width
        if w < 1:
            w = 1
        if self.cursor_row < self.scroll_y:
            self.scroll_y = self.cursor_row
        elif self.cursor_row >= self.scroll_y + h:
            self.scroll_y = self.cursor_row - h + 1
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

    fn reveal_cursor(mut self, view: Rect, margin_below: Int = 5):
        """Scroll so the cursor is visible with at least ``margin_below``
        rows of context underneath it (clamped to file end).

        Used after non-incremental jumps (e.g. goto-definition): plain
        ``_scroll_to_cursor`` brings the cursor *just* into view, which
        leaves it stuck at the bottom edge with no surrounding code
        visible — fine for typing, jarring for landings.
        """
        var h = view.height()
        var w = view.width() - self.gutter_width
        if w < 1:
            w = 1
        var max_row = self.buffer.line_count() - 1
        var bottom = self.cursor_row + margin_below
        if bottom > max_row:
            bottom = max_row
        if self.cursor_row < self.scroll_y:
            self.scroll_y = self.cursor_row
        elif bottom >= self.scroll_y + h:
            self.scroll_y = bottom - h + 1
        if self.scroll_y < 0:
            self.scroll_y = 0
        var line = self.buffer.line(self.cursor_row)
        var cur_cell = _utf8_cell_of_byte(line, self.cursor_col)
        var scroll_cell = _utf8_cell_of_byte(line, self.scroll_x)
        if cur_cell < scroll_cell:
            scroll_cell = cur_cell
        elif cur_cell >= scroll_cell + w:
            scroll_cell = cur_cell - w + 1
        self.scroll_x = _utf8_byte_of_cell(line, scroll_cell)


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
