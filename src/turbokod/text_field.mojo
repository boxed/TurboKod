"""Single-line text-field model + handler shared by every dialog with
an editable input strip (``Prompt``, ``QuickOpen``, ``SaveAsDialog``,
``SymbolPick``, ``DocPick``, ``ProjectFind``, ``FindSymbol``,
``TargetsDialog``, ``ActionEditor``, ``LocalChanges`` commit overlay).

``TextField`` owns the text, cursor (byte offset), and selection
anchor for one input strip. It implements editor-style cursor
movement so a dialog field behaves like a tiny one-line editor:

* Left/Right arrow walks one codepoint; Ctrl/Alt+Left/Right walks
  one word (``\\w`` clusters, same class as the editor).
* Home/End jumps to the start/end of the field.
* Shift+<any movement> extends the selection.
* Backspace / Delete remove the selection if any, else one char.
* Cmd+A / Ctrl+A selects all the field's text.
* Ctrl+C copies the selection (or the whole field when nothing is
  selected) to the system clipboard.
* Ctrl+X copies the selection then deletes it; with no selection,
  copies + clears the whole field.
* Ctrl+V pastes (replacing the selection if any). Paste payload is
  filtered to printable bytes — single-line semantics.
* Mouse click positions the cursor at the clicked cell; drag
  extends the selection.

The ``handle_key`` entrypoint returns a ``TextFieldKeyResult`` so
the caller can branch on consumed-vs-changed without re-checking
the keystroke (existing pickers gate their refilter on ``changed``).
"""

from std.collections.list import List

from .canvas import Canvas, utf8_byte_to_cell, utf8_codepoint_count
from .painter import Painter
from .cell import Cell
from .clipboard import (
    CLIP_COPY, CLIP_CUT, CLIP_PASTE, CLIP_SELECT_ALL, clipboard_chord,
    clipboard_copy, clipboard_paste,
)
from .colors import Attr, BLACK, BLUE, CYAN, LIGHT_GRAY, WHITE


# Standard single-line input style, shared by every dialog. Cyan bg
# is the "this is an input field" marker that pops against both the
# light-gray and blue dialog bodies used elsewhere in the codebase.
# Exposed via free fns so callers that need to color an adjacent
# label or rebuild a bordered strip can match the field color
# without re-hardcoding the constants.

def text_field_bg() -> Attr:
    return Attr(BLACK, CYAN)

def text_field_sel_attr() -> Attr:
    return Attr(WHITE, BLUE)
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE, KEY_BACKSPACE, KEY_DELETE, KEY_END,
    KEY_HOME, KEY_LEFT, KEY_RIGHT, MOD_ALT, MOD_CTRL, MOD_META, MOD_SHIFT,
    MOUSE_BUTTON_LEFT,
)
from .posix import monotonic_ms
from .geometry import Point, Rect
from .string_utils import (
    codepoint_at, is_word_codepoint, leading_indent_bytes,
    prev_codepoint_start, word_char_step,
)


# How long a second mouse press can lag the first and still be treated
# as a double-click. 500 ms matches the editor's own threshold (see
# ``editor._DOUBLE_CLICK_MS``) so multi-line and single-line input
# feel the same.
comptime _DOUBLE_CLICK_MS = 500
from .terminal import beep


# How long a typing run can pause before the next keystroke starts a
# fresh undo group. Matches the editor's debounce so single-line input
# undo grouping feels the same as multi-line. Non-typing mutations
# (backspace, paste, cut, delete-forward) always break the run, so this
# only applies to consecutive printable inserts.
comptime _TYPING_DEBOUNCE_MS = 800
# Cap on the per-field undo stack. Single-line inputs don't accumulate
# state the way an editor buffer does, so a small ceiling is plenty.
comptime _UNDO_STACK_LIMIT = 200


@fieldwise_init
struct _Snapshot(ImplicitlyCopyable, Movable):
    """One reversible step of a ``TextField``. Captures the text and the
    caret / anchor so undo restores both content and selection."""
    var text: String
    var cursor: Int
    var anchor: Int


@fieldwise_init
struct TextFieldKeyResult(Copyable, Movable):
    """Outcome of ``TextField.handle_key``.

    ``consumed`` — True if the helper handled the event; the caller
    should ``return True`` from its own ``handle_key`` and skip its
    normal printable / backspace / arrow branches.

    ``changed`` — True if the field's text was mutated. Callers that
    derive state from the field (filter results, dirty markers,
    debouncers) should refresh on True; cursor-only events leave the
    field untouched and report False.
    """
    var consumed: Bool
    var changed: Bool


# --- TextField: the canonical single-line input model --------------------


struct TextField(Copyable, Movable):
    """One-line editable text + cursor + selection anchor.

    ``cursor`` and ``anchor`` are byte offsets within ``text``; they
    must always sit on UTF-8 codepoint boundaries. When ``cursor ==
    anchor`` the field has no selection.

    Construct with the default ``__init__`` (empty), then populate
    via ``set_text`` if you have a prefill. ``handle_key`` is the
    main entry; ``handle_mouse`` accepts a single-row ``input_rect``
    and positions the cursor at the clicked cell.
    """

    var text: String
    var cursor: Int       # byte offset of caret in text
    var anchor: Int       # byte offset of selection anchor
    var _drag: Bool       # True between mouse-down and mouse-up
    # Cell offset of the leftmost visible cell within ``text``. Only
    # nonzero when the text is wider than the strip and the cursor has
    # walked past what fits — see ``_ensure_visible``. Mutated by
    # ``paint`` (which knows the strip width) and by ``handle_mouse``
    # before translating a click coordinate, so clicks on the
    # currently-visible portion land on the right codepoint.
    var _scroll: Int
    # Linear undo / redo history. Snapshots are pushed *before* a
    # mutation so ``undo`` rewinds to the pre-edit state; a fresh
    # mutation after an undo clears ``_redo`` (standard linear model).
    # Consecutive printable inserts are coalesced into one snapshot
    # via ``_typing_active`` + ``_typing_last_ms`` so one Cmd+Z
    # rolls back a whole typed word rather than letter-by-letter.
    var _undo: List[_Snapshot]
    var _redo: List[_Snapshot]
    var _typing_active: Bool
    var _typing_last_ms: Int
    # Multi-click tracking for double-click-to-word / triple-click-to-all.
    # ``_last_click_ms`` is the timestamp of the most recent left-button
    # press; ``_last_click_byte`` is the byte offset it landed on.
    # ``_click_count`` counts consecutive presses at the same cell within
    # ``_DOUBLE_CLICK_MS`` (1 = single, 2 = word, 3 = whole field; then
    # resets). During a multi-click drag, ``_dc_active`` /
    # ``_tc_active`` flag which mode the drag-extend is anchored on so
    # the moving end snaps to word / line boundaries.
    var _last_click_ms: Int
    var _last_click_byte: Int
    var _click_count: Int
    var _dc_active: Bool
    var _tc_active: Bool
    # Word range that anchored the most recent double-click. Drag-extend
    # in double-click mode unions the moving end's word with this anchor
    # range so dragging past whole words snaps to whole-word selections.
    var _dc_anchor_start: Int
    var _dc_anchor_end: Int

    def __init__(out self):
        self.text = String("")
        self.cursor = 0
        self.anchor = 0
        self._drag = False
        self._scroll = 0
        self._undo = List[_Snapshot]()
        self._redo = List[_Snapshot]()
        self._typing_active = False
        self._typing_last_ms = 0
        self._last_click_ms = 0
        self._last_click_byte = -1
        self._click_count = 0
        self._dc_active = False
        self._tc_active = False
        self._dc_anchor_start = 0
        self._dc_anchor_end = 0

    def __copyinit__(mut self, copy: Self):
        self.text = copy.text
        self.cursor = copy.cursor
        self.anchor = copy.anchor
        self._drag = copy._drag
        self._scroll = copy._scroll
        self._undo = copy._undo.copy()
        self._redo = copy._redo.copy()
        self._typing_active = copy._typing_active
        self._typing_last_ms = copy._typing_last_ms
        self._last_click_ms = copy._last_click_ms
        self._last_click_byte = copy._last_click_byte
        self._click_count = copy._click_count
        self._dc_active = copy._dc_active
        self._tc_active = copy._tc_active
        self._dc_anchor_start = copy._dc_anchor_start
        self._dc_anchor_end = copy._dc_anchor_end

    def copy(self) -> Self:
        var out = Self()
        out.text = self.text
        out.cursor = self.cursor
        out.anchor = self.anchor
        out._drag = self._drag
        out._scroll = self._scroll
        out._undo = self._undo.copy()
        out._redo = self._redo.copy()
        out._typing_active = self._typing_active
        out._typing_last_ms = self._typing_last_ms
        out._last_click_ms = self._last_click_ms
        out._last_click_byte = self._last_click_byte
        out._click_count = self._click_count
        out._dc_active = self._dc_active
        out._tc_active = self._tc_active
        out._dc_anchor_start = self._dc_anchor_start
        out._dc_anchor_end = self._dc_anchor_end
        return out^

    # --- programmatic mutation -----------------------------------------

    def set_text(mut self, var t: String):
        """Replace the text; place the cursor at the end and clear
        any selection. The most common pattern when seeding a field
        from a prefill — the user typically wants to keep typing
        from where the existing text leaves off.

        Undo history is dropped: a prefill is a fresh starting state,
        not an edit the user should be able to rewind through.
        """
        self.text = t^
        self.cursor = len(self.text.as_bytes())
        self.anchor = self.cursor
        self._drag = False
        # Reset scroll; ``paint`` will adjust on the next call once it
        # knows the strip width. Without the reset, a previous long
        # text's scroll offset could leave the new (possibly short)
        # text drawn off-screen until the cursor moves.
        self._scroll = 0
        self._undo = List[_Snapshot]()
        self._redo = List[_Snapshot]()
        self._typing_active = False
        self._typing_last_ms = 0

    def clear(mut self):
        self.text = String("")
        self.cursor = 0
        self.anchor = 0
        self._drag = False
        self._scroll = 0
        self._undo = List[_Snapshot]()
        self._redo = List[_Snapshot]()
        self._typing_active = False
        self._typing_last_ms = 0

    # --- undo / redo --------------------------------------------------

    def _snapshot(self) -> _Snapshot:
        return _Snapshot(self.text, self.cursor, self.anchor)

    def _push_undo(mut self):
        """Record the current state on the undo stack and clear redo.

        Call this *before* applying a mutation so ``undo`` rewinds to
        the pre-edit state. Any new edit invalidates the redo branch —
        standard linear-history model. Also breaks any typing run
        that was in flight; the printable-insert path explicitly
        re-arms the flag afterwards when it wants the new char to
        anchor a fresh group.
        """
        self._undo.append(self._snapshot())
        if len(self._undo) > _UNDO_STACK_LIMIT:
            var trimmed = List[_Snapshot]()
            for i in range(
                len(self._undo) - _UNDO_STACK_LIMIT, len(self._undo),
            ):
                trimmed.append(self._undo[i])
            self._undo = trimmed^
        self._redo = List[_Snapshot]()
        self._typing_active = False

    def _restore(mut self, snap: _Snapshot):
        self.text = snap.text
        self.cursor = snap.cursor
        self.anchor = snap.anchor
        # Restoring lands on a saved state; the next keystroke should
        # start a fresh undo group rather than extend whatever ran
        # before.
        self._typing_active = False

    def undo(mut self) -> Bool:
        """Roll back the last mutation. Returns False when the stack
        is empty (no edits since ``set_text`` / construction)."""
        if len(self._undo) == 0:
            return False
        var snap = self._undo.pop()
        self._redo.append(self._snapshot())
        self._restore(snap)
        return True

    def redo(mut self) -> Bool:
        """Replay the most recently undone mutation. False when
        nothing to redo."""
        if len(self._redo) == 0:
            return False
        var snap = self._redo.pop()
        self._undo.append(self._snapshot())
        self._restore(snap)
        return True

    # --- selection -----------------------------------------------------

    def has_selection(self) -> Bool:
        return self.cursor != self.anchor

    def _sel_range(self) -> Tuple[Int, Int]:
        if self.cursor < self.anchor:
            return (self.cursor, self.anchor)
        return (self.anchor, self.cursor)

    def selection_text(self) -> String:
        if not self.has_selection():
            return String("")
        var rng = self._sel_range()
        var b = self.text.as_bytes()
        return String(StringSlice(unsafe_from_utf8=b[rng[0]:rng[1]]))

    def select_all(mut self):
        self.anchor = 0
        self.cursor = len(self.text.as_bytes())

    def delete_selection(mut self) -> Bool:
        """Delete the active selection (if any), collapsing the cursor
        to where the selection started. Returns True if anything was
        removed.

        Doesn't push undo by itself — callers wrap this in their own
        ``_push_undo`` so a single user action (Backspace,
        Cut, ``insert`` that replaces a selection, …) ends up as one
        undo step rather than two stacked entries.
        """
        if not self.has_selection():
            return False
        var rng = self._sel_range()
        self.text = _splice(self.text, rng[0], rng[1], String(""))
        self.cursor = rng[0]
        self.anchor = rng[0]
        return True

    # --- cursor movement ----------------------------------------------

    def _move(mut self, new_cursor: Int, extend: Bool):
        self.cursor = new_cursor
        if not extend:
            self.anchor = new_cursor

    def _step_left(mut self, extend: Bool):
        if not extend and self.has_selection():
            self._move(self._sel_range()[0], False)
            return
        self._move(_utf8_step_backward(self.text, self.cursor), extend)

    def _step_right(mut self, extend: Bool):
        if not extend and self.has_selection():
            self._move(self._sel_range()[1], False)
            return
        self._move(_utf8_step_forward(self.text, self.cursor), extend)

    def _word_left(mut self, extend: Bool):
        self._move(_prev_word_pos(self.text, self.cursor), extend)

    def _word_right(mut self, extend: Bool):
        self._move(_next_word_pos(self.text, self.cursor), extend)

    def _home(mut self, extend: Bool):
        self._move(0, extend)

    def _end(mut self, extend: Bool):
        self._move(len(self.text.as_bytes()), extend)

    def _smart_home(mut self, extend: Bool):
        """Mirror the editor's Cmd+Left: jump to the first non-space
        column; if the cursor is already at or before that column,
        fall all the way to byte 0. Two presses from anywhere in the
        body land at the margin — same muscle memory as the editor."""
        var first_ns = leading_indent_bytes(self.text)
        var target = first_ns if self.cursor > first_ns else 0
        self._move(target, extend)

    # --- mutation ------------------------------------------------------

    def insert(mut self, s: String) -> Bool:
        """Insert ``s`` at the cursor (replacing the selection if any).
        Returns True if anything actually changed (text grew or a
        selection was deleted).

        Pushes one undo snapshot for the combined replace + insert so
        undo rolls back the whole operation in one step. The typing
        path is special-cased in ``handle_key`` and bypasses this
        snapshotting to coalesce consecutive keystrokes.
        """
        var had_sel = self.has_selection()
        var will_change = had_sel or len(s.as_bytes()) > 0
        if will_change:
            self._push_undo()
        if had_sel:
            _ = self.delete_selection()
        if len(s.as_bytes()) == 0:
            return had_sel
        self.text = _splice(self.text, self.cursor, self.cursor, s)
        self.cursor = self.cursor + len(s.as_bytes())
        self.anchor = self.cursor
        return True

    def backspace(mut self) -> Bool:
        if self.has_selection():
            self._push_undo()
            return self.delete_selection()
        if self.cursor == 0:
            return False
        self._push_undo()
        var prev = _utf8_step_backward(self.text, self.cursor)
        self.text = _splice(self.text, prev, self.cursor, String(""))
        self.cursor = prev
        self.anchor = prev
        return True

    def delete_forward(mut self) -> Bool:
        if self.has_selection():
            self._push_undo()
            return self.delete_selection()
        var n = len(self.text.as_bytes())
        if self.cursor >= n:
            return False
        self._push_undo()
        var nxt = _utf8_step_forward(self.text, self.cursor)
        self.text = _splice(self.text, self.cursor, nxt, String(""))
        return True

    # --- main key entrypoint ------------------------------------------

    def handle_key(mut self, event: Event) -> TextFieldKeyResult:
        """Apply ``event`` to this field. Returns
        ``(consumed, changed)``; ``consumed`` is True when the event
        was handled (caller should not run its own printable /
        backspace / arrow paths). ``changed`` is True when the
        field's text was mutated (caller should refilter / mark
        dirty)."""
        if event.kind != EVENT_KEY:
            return TextFieldKeyResult(False, False)
        var k = event.key
        var extend = (event.mods & MOD_SHIFT) != 0
        # Word-jump on Ctrl OR Alt — same convention as the editor
        # (``editor.handle_key`` line ~2229). macOS terminals deliver
        # Option+Arrow as KEY_LEFT/RIGHT + MOD_ALT; Linux/Windows
        # terminals deliver Ctrl+Arrow + MOD_CTRL.
        var word_jump = (event.mods & MOD_CTRL) != 0 \
            or (event.mods & MOD_ALT) != 0
        # Cmd+Left / Cmd+Right — line-level horizontal navigation
        # mirroring the editor. Same shared muscle memory: Cmd+Right
        # jumps to end of (single-line) text; Cmd+Left smart-homes
        # to the first non-space, or to byte 0 if already there.
        # Shift extends the selection. Cmd takes precedence over the
        # Ctrl/Alt word-jump fallback so MOD_CTRL+MOD_META (the editor
        # also accepts this combo) still picks the line-level path.
        var line_jump = (event.mods & MOD_META) != 0
        # --- cursor / selection movement ---
        if k == KEY_LEFT:
            if line_jump:
                self._smart_home(extend)
            elif word_jump:
                self._word_left(extend)
            else:
                self._step_left(extend)
            return TextFieldKeyResult(True, False)
        if k == KEY_RIGHT:
            if line_jump:
                self._end(extend)
            elif word_jump:
                self._word_right(extend)
            else:
                self._step_right(extend)
            return TextFieldKeyResult(True, False)
        if k == KEY_HOME:
            self._home(extend)
            return TextFieldKeyResult(True, False)
        if k == KEY_END:
            self._end(extend)
            return TextFieldKeyResult(True, False)
        # --- editing ---
        if k == KEY_BACKSPACE:
            return TextFieldKeyResult(True, self.backspace())
        if k == KEY_DELETE:
            return TextFieldKeyResult(True, self.delete_forward())
        # --- clipboard / select-all ---
        # Chord recognition lives in clipboard.mojo so the editor and
        # this field can't drift on which keystrokes count.
        var chord = clipboard_chord(event)
        if chord == CLIP_SELECT_ALL:
            self.select_all()
            return TextFieldKeyResult(True, False)
        if chord == CLIP_COPY:
            if self.has_selection():
                clipboard_copy(self.selection_text())
            else:
                clipboard_copy(self.text)
            return TextFieldKeyResult(True, False)
        if chord == CLIP_CUT:
            if self.has_selection():
                clipboard_copy(self.selection_text())
                self._push_undo()
                _ = self.delete_selection()
                return TextFieldKeyResult(True, True)
            clipboard_copy(self.text)
            var had = len(self.text.as_bytes()) > 0
            if had:
                # Whole-field cut: snapshot before clearing so undo
                # restores the deleted text.
                self._push_undo()
                self.text = String("")
                self.cursor = 0
                self.anchor = 0
                self._scroll = 0
            return TextFieldKeyResult(True, had)
        if chord == CLIP_PASTE:
            var pasted = _sanitize_single_line(clipboard_paste())
            if len(pasted.as_bytes()) == 0:
                # Still consume the chord (a paste of pure whitespace
                # / control bytes shouldn't fall through to the
                # caller's printable branch and inject a literal V).
                return TextFieldKeyResult(True, False)
            # ``insert`` already snapshots once for the whole
            # replace-and-insert, so undo rolls back the full paste
            # in a single step.
            return TextFieldKeyResult(True, self.insert(pasted))
        # --- undo / redo ---
        # Cmd+Z / Ctrl+Z = undo; Cmd+Shift+Z or Cmd+Y / Ctrl+Y = redo.
        # Both modifier families work so the binding matches whatever
        # the host's editor accepts (the editor binds these on
        # MOD_META; Linux/Windows users typing with MOD_CTRL get the
        # same affordance inside dialog fields).
        var chord_mod = (event.mods & (MOD_CTRL | MOD_META)) != 0
        var is_shift = (event.mods & MOD_SHIFT) != 0
        if chord_mod and k == UInt32(ord("z")):
            if is_shift:
                return TextFieldKeyResult(True, self.redo())
            return TextFieldKeyResult(True, self.undo())
        if chord_mod and not is_shift and k == UInt32(ord("y")):
            return TextFieldKeyResult(True, self.redo())
        # Any chord modifier (Ctrl / Cmd / Alt) reaching this point
        # means the keystroke wasn't a clipboard / select-all / undo
        # chord and isn't editing the field. Modal text fields are
        # leaf input handlers — there's no global hotkey table behind
        # them, so falling through to the printable-insert branch
        # below would smuggle the letter into the buffer (Cmd+B
        # inserting ``b``). Consume the event instead; beep on
        # Ctrl/Cmd so the user knows the chord wasn't bound. Alt is
        # silently swallowed because some terminals deliver
        # ``MOD_ALT`` for Option-as-Meta and Unicode-compose dead
        # keys, where beeping on every press would be obnoxious.
        if (event.mods & (MOD_CTRL | MOD_META)) != 0:
            beep()
            return TextFieldKeyResult(True, False)
        if (event.mods & MOD_ALT) != 0:
            return TextFieldKeyResult(True, False)
        # Plain printable ASCII: insert at cursor. Coalesce consecutive
        # presses into one undo group so Cmd+Z rolls back a whole typed
        # word rather than one character at a time. A selection
        # replacement or a paused-then-resumed run breaks the group:
        # the user expects undo to stop at those natural boundaries.
        if UInt32(0x20) <= k and k < UInt32(0x7F):
            var now = monotonic_ms()
            var in_run = self._typing_active \
                and now - self._typing_last_ms <= _TYPING_DEBOUNCE_MS \
                and not self.has_selection()
            var ch = chr(Int(k))
            var changed: Bool
            if in_run:
                # Bypass ``insert`` entirely so we don't push a per-key
                # snapshot. The first key in the run already snapshotted.
                self.text = _splice(self.text, self.cursor, self.cursor, ch)
                self.cursor = self.cursor + len(ch.as_bytes())
                self.anchor = self.cursor
                changed = True
            else:
                # First key of a (potentially) new run: ``insert``
                # pushes one snapshot covering this key — and the
                # selection-delete if any.
                changed = self.insert(ch)
            self._typing_active = True
            self._typing_last_ms = now
            return TextFieldKeyResult(True, changed)
        return TextFieldKeyResult(False, False)

    # --- mouse --------------------------------------------------------

    def handle_mouse(
        mut self, event: Event, input_rect: Rect,
    ) -> Bool:
        """Position the cursor for a click inside ``input_rect`` and
        run the drag / multi-click gestures on top of it. Returns True
        if the event was consumed (click landed in the strip, or a
        drag from a previous press is in progress).

        ``input_rect`` is the one-row strip where ``self.text`` is
        drawn, in screen coordinates. Cell-to-byte translation is
        UTF-8 aware so a click on a multi-byte glyph lands at the
        codepoint start.

        Multi-click cycle (matches the editor's): single click parks
        the cursor; second press within 500 ms at the same cell
        selects the surrounding word; third selects the whole field.
        Holding the button after a double / triple snaps the moving
        end of the selection to whole-word / whole-field boundaries.
        """
        if event.kind != EVENT_MOUSE:
            return False
        if event.button != MOUSE_BUTTON_LEFT:
            # A wheel event etc. on the strip isn't ours to handle —
            # let the caller route it elsewhere.
            return False
        # Reconcile scroll with the strip width *before* translating a
        # click. If the field has been resized or the text mutated
        # since the last paint, ``_scroll`` may be stale; the
        # translation below adds it to the click cell, so correctness
        # depends on it matching what's actually drawn.
        self._ensure_visible(input_rect.b.x - input_rect.a.x)
        var inside = input_rect.contains(event.pos)
        if event.pressed and not event.motion:
            # Press outside the strip: not our event. Press inside:
            # park the cursor and (if appropriate) bump the click
            # counter for word / line selection.
            if not inside:
                return False
            var byte = self._byte_at_x(event.pos.x - input_rect.a.x)
            var now = monotonic_ms()
            var same_cell = (
                now - self._last_click_ms <= _DOUBLE_CLICK_MS
                and byte == self._last_click_byte
            )
            if same_cell:
                self._click_count += 1
                if self._click_count > 3:
                    self._click_count = 1
            else:
                self._click_count = 1
            self._last_click_ms = now
            self._last_click_byte = byte
            self._drag = True
            self._dc_active = False
            self._tc_active = False
            if self._click_count == 2:
                # Word select: anchor the surrounding word range so a
                # following drag snaps to whole-word boundaries.
                var wrng = _word_range_at(self.text, byte)
                self._dc_active = True
                self._dc_anchor_start = wrng[0]
                self._dc_anchor_end = wrng[1]
                self.anchor = wrng[0]
                self.cursor = wrng[1]
            elif self._click_count == 3:
                # Whole-field select. Cancels the multi-click cycle so
                # a fourth quick press starts fresh as a single click.
                self._tc_active = True
                self.anchor = 0
                self.cursor = len(self.text.as_bytes())
                self._last_click_ms = 0
                self._click_count = 0
            else:
                self.cursor = byte
                self.anchor = byte
            return True
        if event.motion and self._drag:
            # Drag extends the selection; clamp to the field bounds.
            var x = event.pos.x - input_rect.a.x
            if x < 0:
                x = 0
            var byte = self._byte_at_x(x)
            if self._tc_active:
                # Whole-field gesture: nothing to extend, the whole
                # field is already selected.
                pass
            elif self._dc_active:
                # Snap to word boundaries unioned with the anchor word.
                var wrng = _word_range_at(self.text, byte)
                var lo = wrng[0]
                var hi = wrng[1]
                if self._dc_anchor_start < lo:
                    lo = self._dc_anchor_start
                if self._dc_anchor_end > hi:
                    hi = self._dc_anchor_end
                # Direction follows the drag: cursor on the moving end.
                if byte >= self._dc_anchor_end:
                    self.anchor = lo
                    self.cursor = hi
                else:
                    self.anchor = hi
                    self.cursor = lo
            else:
                self.cursor = byte
            return True
        if not event.pressed and self._drag:
            self._drag = False
            return True
        return False

    def _byte_at_x(self, cell_x: Int) -> Int:
        """Translate a cell offset within the strip to a byte offset
        in ``self.text``, accounting for ``_scroll`` (the cell at
        strip column 0 is text cell ``_scroll``). Past-text cells map
        to ``len(text)`` so a click well past the last character
        parks the cursor at the end. Caller must have called
        ``_ensure_visible`` first so ``_scroll`` matches the strip
        width."""
        var local_x = cell_x
        if local_x < 0:
            local_x = 0
        var text_cell = self._scroll + local_x
        var n_cells = utf8_codepoint_count(self.text)
        if text_cell >= n_cells:
            return len(self.text.as_bytes())
        return _utf8_byte_of_cell(self.text, text_cell)

    # --- rendering helpers --------------------------------------------

    def cursor_cell(self) -> Int:
        """Cell column of the cursor relative to the start of
        ``self.text``."""
        return _utf8_cell_of_byte(self.text, self.cursor)

    def _ensure_visible(mut self, width: Int):
        """Adjust ``_scroll`` so that the cursor sits within the
        ``width``-cell visible window. Also pulls scroll back to the
        left when shrinking text would otherwise leave empty cells at
        the right end of the strip — we'd rather show leading text
        than blanks. ``width`` is the cell width of the strip
        (``rect.b.x - rect.a.x``)."""
        if width <= 0:
            self._scroll = 0
            return
        var c = self.cursor_cell()
        if c < self._scroll:
            self._scroll = c
        elif c >= self._scroll + width:
            self._scroll = c - width + 1
        # If text + caret-cell don't fill the window, slide left so we
        # show as much leading text as possible.
        var n_cells = utf8_codepoint_count(self.text)
        var max_useful = n_cells + 1 - width
        if max_useful < 0:
            max_useful = 0
        if self._scroll > max_useful:
            self._scroll = max_useful
        if self._scroll < 0:
            self._scroll = 0

    def paint(
        mut self, mut canvas: Canvas, rect: Rect, focused: Bool,
    ):
        """Render ``self.text`` into ``rect`` (one row) using the
        standard input-field colors: cyan background, white-on-blue
        selection. The cursor cell is painted in reverse-video
        (LIGHT_GRAY on BLACK) when ``focused`` is True.

        ``rect`` is the strip the text occupies — typically one row
        tall. Painting clips at ``rect.b.x`` so the field never
        bleeds past the dialog frame. For a one-line strip
        ``rect.b.y - rect.a.y`` is 1; the helper renders only the
        first row regardless.

        When the text is wider than the strip the field scrolls
        horizontally so the caret stays visible — see
        ``_ensure_visible``. Takes ``mut self`` to update the scroll
        offset.

        Every dialog with an editable input strip routes through this
        method so the cyan-field idiom is consistent across the app.
        """
        var attr = text_field_bg()
        var sel_attr = text_field_sel_attr()
        var painter = Painter(rect)
        painter.fill(canvas, rect, String(" "), attr)
        var width = rect.b.x - rect.a.x
        if width <= 0:
            return
        self._ensure_visible(width)
        # Render only the visible slice of text so a long string
        # doesn't spill UTF-8 past the strip — and so scroll > 0
        # actually shifts the visible characters left.
        var bytes = self.text.as_bytes()
        var start_byte = _utf8_byte_of_cell(self.text, self._scroll)
        if start_byte < len(bytes):
            var visible = String(
                StringSlice(unsafe_from_utf8=bytes[start_byte:])
            )
            _ = painter.put_text(
                canvas, Point(rect.a.x, rect.a.y), visible, attr,
            )
        # Selection overlay: recolor the visible portion of the
        # selection without rewriting glyphs.
        if self.has_selection():
            var rng = self._sel_range()
            var start_cell = _utf8_cell_of_byte(self.text, rng[0])
            var end_cell = _utf8_cell_of_byte(self.text, rng[1])
            var x = rect.a.x + start_cell - self._scroll
            var stop = rect.a.x + end_cell - self._scroll
            if x < rect.a.x:
                x = rect.a.x
            if stop > rect.b.x:
                stop = rect.b.x
            while x < stop:
                painter.set_attr(canvas, x, rect.a.y, sel_attr)
                x += 1
        if focused:
            var cur_x = rect.a.x + self.cursor_cell() - self._scroll
            if cur_x < rect.b.x and cur_x >= rect.a.x:
                # Reverse-video block over the current cell. Inside
                # a selection we still paint it — the user expects to
                # see *where* their caret sits.
                var glyph: String
                # Use the existing glyph at that cell if we painted one
                # (so a selected char shows under the caret), else " ".
                if cur_x < self._text_end_x(rect.a.x):
                    glyph = canvas.get(cur_x, rect.a.y).glyph
                else:
                    glyph = String(" ")
                painter.set(
                    canvas, cur_x, rect.a.y,
                    Cell(glyph, Attr(LIGHT_GRAY, BLACK), 1),
                )

    def _text_end_x(self, base_x: Int) -> Int:
        """Strip column just past the last visible codepoint of
        ``self.text``, anchored at ``base_x``. Used by ``paint`` to
        decide whether the caret sits over a glyph (preserve it under
        the inverted cell) or past EOL (paint a space). Accounts for
        ``_scroll`` so a scrolled field's caret-on-glyph check uses
        the visible position."""
        return base_x + utf8_codepoint_count(self.text) - self._scroll


# --- Form: a group of TextFields keyed by focus IDs ----------------------


struct Form(Movable):
    """A grouped collection of ``TextField``s, keyed by caller-chosen
    focus IDs. Owns the fields and routes every mouse / keyboard event
    through them, so a dialog with N inputs doesn't need to enumerate
    each one in its event handler — it instantiates a ``Form``, fills
    it via ``add``, and forwards events with a single call.

    The contract is:

    * ``handle_mouse(event, rects)`` — ``rects`` is parallel to the
      field list, indexed by registration order. Returns the focus
      ID of whichever field claimed the event (a press inside its
      rect, or a motion / release while mid-drag), or ``None``. The
      dialog sets ``self.focus`` from the returned ID.
    * ``handle_key(event, focus)`` — forwards the key to the field
      whose focus ID matches; non-matching focus is a no-op.
    * ``paint_field`` / ``text`` / ``set_text`` — by focus ID lookup
      for the painting and read-back paths.

    Drag tracking, click counting, undo, Cmd+arrow, double-click word
    selection, and all the other input-field niceties live inside
    ``TextField`` itself — the dialog never sees any of it.
    """
    var _fields: List[TextField]
    var _keys: List[UInt8]

    def __init__(out self):
        self._fields = List[TextField]()
        self._keys = List[UInt8]()

    def __copyinit__(mut self, copy: Self):
        self._fields = copy._fields.copy()
        self._keys = copy._keys.copy()

    def copy(self) -> Self:
        var out = Self()
        out._fields = self._fields.copy()
        out._keys = self._keys.copy()
        return out^

    def add(mut self, focus_key: UInt8):
        """Register a fresh empty field bound to ``focus_key``. The
        field's index in ``rects`` (passed to ``handle_mouse`` /
        ``paint_each``) is the order of ``add`` calls."""
        self._fields.append(TextField())
        self._keys.append(focus_key)

    def _index_of(self, focus_key: UInt8) -> Int:
        for i in range(len(self._keys)):
            if self._keys[i] == focus_key:
                return i
        return -1

    def handle_mouse(
        mut self, event: Event, rects: List[Rect],
    ) -> Optional[UInt8]:
        """Forward ``event`` to every registered field paired with its
        rect from ``rects`` (parallel list). The first field that
        consumes wins — press-inside arms its drag, motion / release
        while mid-drag continue or end it. Returns the consumer's
        focus key so the dialog can update ``self.focus``."""
        var n = len(self._fields)
        if len(rects) < n:
            n = len(rects)
        for i in range(n):
            if self._fields[i].handle_mouse(event, rects[i]):
                return Optional[UInt8](self._keys[i])
        return Optional[UInt8]()

    def handle_key(
        mut self, event: Event, focus_key: UInt8,
    ) -> TextFieldKeyResult:
        """Route ``event`` to the field whose registered key is
        ``focus_key``. Returns ``TextFieldKeyResult(False, False)``
        when ``focus_key`` isn't in the form — useful when the
        dialog's overall focus is on a non-field widget (button,
        dropdown) and the form has nothing to do."""
        var idx = self._index_of(focus_key)
        if idx < 0:
            return TextFieldKeyResult(False, False)
        return self._fields[idx].handle_key(event)

    def text(self, focus_key: UInt8) -> String:
        var idx = self._index_of(focus_key)
        if idx < 0:
            return String("")
        return self._fields[idx].text

    def set_text(mut self, focus_key: UInt8, var text: String):
        var idx = self._index_of(focus_key)
        if idx < 0:
            return
        self._fields[idx].set_text(text^)

    def paint_field(
        mut self, mut canvas: Canvas, focus_key: UInt8,
        rect: Rect, focused: Bool,
    ):
        """Paint the field bound to ``focus_key`` at ``rect``. Per-
        field painting (rather than a single ``paint_each``) lets
        dialogs interleave labels, hints, and chrome between the
        rows however their layout requires."""
        var idx = self._index_of(focus_key)
        if idx < 0:
            return
        self._fields[idx].paint(canvas, rect, focused)


# --- internals -----------------------------------------------------------


def _sanitize_single_line(text: String) -> String:
    """Strip CR / LF / TAB and other control bytes from a paste payload.

    A clipboard chunk with embedded newlines would otherwise smuggle
    real ``\\n`` bytes into a single-row input strip — ``put_text``
    doesn't render them and the dialog's submit logic wouldn't expect
    them either. Tabs are dropped for the same reason. Printable
    bytes >= 0x20 and UTF-8 continuation bytes (>= 0x80) are
    preserved so a paste of e.g. ``café`` survives.
    """
    var b = text.as_bytes()
    var out = List[UInt8]()
    for i in range(len(b)):
        var byte = b[i]
        if byte < 0x20 or byte == 0x7F:
            continue
        out.append(byte)
    if len(out) == 0:
        return String("")
    return String(StringSlice(ptr=out.unsafe_ptr(), length=len(out)))


def _splice(text: String, start: Int, end: Int, replacement: String) -> String:
    """Return ``text`` with bytes ``[start, end)`` replaced by
    ``replacement``. Boundary-clamped so callers don't have to
    pre-validate."""
    var b = text.as_bytes()
    var n = len(b)
    var s = start
    var e = end
    if s < 0:
        s = 0
    if e > n:
        e = n
    if s > e:
        s = e
    var rb = replacement.as_bytes()
    var out = List[UInt8]()
    for i in range(s):
        out.append(b[i])
    for i in range(len(rb)):
        out.append(rb[i])
    for i in range(e, n):
        out.append(b[i])
    if len(out) == 0:
        return String("")
    return String(StringSlice(ptr=out.unsafe_ptr(), length=len(out)))


# --- UTF-8 boundary helpers (mirrors editor.mojo) -----------------------


def _utf8_codepoint_size(b: Int) -> Int:
    if b < 0x80:
        return 1
    if (b & 0xE0) == 0xC0:
        return 2
    if (b & 0xF0) == 0xE0:
        return 3
    if (b & 0xF8) == 0xF0:
        return 4
    return 1


def _utf8_step_forward(text: String, col: Int) -> Int:
    var bytes = text.as_bytes()
    var n = len(bytes)
    if col >= n:
        return n
    var step = _utf8_codepoint_size(Int(bytes[col]))
    var nxt = col + step
    if nxt > n:
        nxt = n
    return nxt


def _utf8_step_backward(text: String, col: Int) -> Int:
    if col <= 0:
        return 0
    var bytes = text.as_bytes()
    var c = col - 1
    while c > 0 and (Int(bytes[c]) & 0xC0) == 0x80:
        c -= 1
    return c


def _utf8_cell_of_byte(text: String, byte_col: Int) -> Int:
    if byte_col <= 0:
        return 0
    var bytes = text.as_bytes()
    var n = len(bytes)
    var cell = 0
    var i = 0
    while i < n and i < byte_col:
        i += _utf8_codepoint_size(Int(bytes[i]))
        cell += 1
    if byte_col > n:
        cell += byte_col - n
    return cell


def _utf8_byte_of_cell(text: String, cell_col: Int) -> Int:
    if cell_col <= 0:
        return 0
    var bytes = text.as_bytes()
    var n = len(bytes)
    var cell = 0
    var i = 0
    while i < n and cell < cell_col:
        i += _utf8_codepoint_size(Int(bytes[i]))
        cell += 1
    return i


def _char_class(cp: Int) -> Int:
    """Three-way character class used by ``_word_range_at``. Word
    chars cluster, whitespace clusters, everything else clusters as
    "punctuation". Mirrors the editor's grouping so double-click in
    a dialog field picks the same span as double-click in a
    full-buffer line."""
    if is_word_codepoint(cp):
        return 1
    if cp == 0x20 or cp == 0x09:
        return 2
    return 3


def _word_range_at(text: String, byte_col: Int) -> Tuple[Int, Int]:
    """Return the (start, end) byte range of the contiguous run of
    same-class codepoints around ``byte_col``. Empty range when
    ``byte_col`` is at end of text. Walks by UTF-8 codepoint so
    multibyte letters cluster with their ASCII neighbours."""
    var bytes = text.as_bytes()
    var n = len(bytes)
    if byte_col < 0 or byte_col >= n:
        return (byte_col, byte_col)
    var here = codepoint_at(text, byte_col)
    var cls = _char_class(here[0])
    var start = byte_col
    while start > 0:
        var prev = prev_codepoint_start(text, start)
        var info = codepoint_at(text, prev)
        if _char_class(info[0]) != cls:
            break
        start = prev
    var end = byte_col + here[1]
    while end < n:
        var info = codepoint_at(text, end)
        if _char_class(info[0]) != cls:
            break
        end += info[1]
    return (start, end)


def _next_word_pos(text: String, col: Int) -> Int:
    """Skip the current word run, then any non-word run. Mirrors
    ``Editor._next_word_pos`` for a single-line buffer (no row
    wrapping). One press = one meaningful jump. Walks by UTF-8
    codepoint so non-ASCII letters (``ä``, Cyrillic, CJK) cluster
    with their ASCII neighbors."""
    var bytes = text.as_bytes()
    var n = len(bytes)
    if col >= n:
        return n
    var c = col
    while c < n:
        var step = word_char_step(text, c)
        if not step[0]:
            break
        c += step[1]
    while c < n:
        var step = word_char_step(text, c)
        if step[0]:
            break
        c += step[1]
    return c


def _prev_word_pos(text: String, col: Int) -> Int:
    if col <= 0:
        return 0
    var c = col
    while c > 0:
        var prev = prev_codepoint_start(text, c)
        var info = codepoint_at(text, prev)
        if is_word_codepoint(info[0]):
            break
        c = prev
    while c > 0:
        var prev = prev_codepoint_start(text, c)
        var info = codepoint_at(text, prev)
        if not is_word_codepoint(info[0]):
            break
        c = prev
    return c
