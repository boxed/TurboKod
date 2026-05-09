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

The legacy ``text_field_clipboard_key`` helper is preserved for
callers that haven't migrated yet — it delegates to a tiny stub
that operates on a raw ``String`` (no cursor model).
"""

from std.collections.list import List

from .canvas import Canvas, utf8_byte_to_cell, utf8_codepoint_count
from .painter import Painter
from .cell import Cell
from .clipboard import clipboard_copy, clipboard_paste
from .colors import Attr, BLACK, BLUE, CYAN, LIGHT_GRAY, WHITE


# Standard single-line input style, shared by every dialog. Cyan bg
# is the "this is an input field" marker that pops against both the
# light-gray and blue dialog bodies used elsewhere in the codebase.
# Exposed via free fns so callers that need to color an adjacent
# label or rebuild a bordered strip can match the field color
# without re-hardcoding the constants.

fn text_field_bg() -> Attr:
    return Attr(BLACK, CYAN)

fn text_field_sel_attr() -> Attr:
    return Attr(WHITE, BLUE)
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE, KEY_BACKSPACE, KEY_DELETE, KEY_END,
    KEY_HOME, KEY_LEFT, KEY_RIGHT, MOD_ALT, MOD_CTRL, MOD_SHIFT,
    MOUSE_BUTTON_LEFT,
)
from .geometry import Point, Rect
from .string_utils import (
    codepoint_at, is_word_codepoint, prev_codepoint_start, word_char_step,
)


@fieldwise_init
struct TextFieldKeyResult(Copyable, Movable):
    """Outcome of ``TextField.handle_key`` (and the legacy
    ``text_field_clipboard_key`` helper).

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

    fn __init__(out self):
        self.text = String("")
        self.cursor = 0
        self.anchor = 0
        self._drag = False

    fn __copyinit__(out self, copy: Self):
        self.text = copy.text
        self.cursor = copy.cursor
        self.anchor = copy.anchor
        self._drag = copy._drag

    fn copy(self) -> Self:
        var out = Self()
        out.text = self.text
        out.cursor = self.cursor
        out.anchor = self.anchor
        out._drag = self._drag
        return out^

    # --- programmatic mutation -----------------------------------------

    fn set_text(mut self, var t: String):
        """Replace the text; place the cursor at the end and clear
        any selection. The most common pattern when seeding a field
        from a prefill — the user typically wants to keep typing
        from where the existing text leaves off."""
        self.text = t^
        self.cursor = len(self.text.as_bytes())
        self.anchor = self.cursor
        self._drag = False

    fn clear(mut self):
        self.text = String("")
        self.cursor = 0
        self.anchor = 0
        self._drag = False

    # --- selection -----------------------------------------------------

    fn has_selection(self) -> Bool:
        return self.cursor != self.anchor

    fn _sel_range(self) -> Tuple[Int, Int]:
        if self.cursor < self.anchor:
            return (self.cursor, self.anchor)
        return (self.anchor, self.cursor)

    fn selection_text(self) -> String:
        if not self.has_selection():
            return String("")
        var rng = self._sel_range()
        var b = self.text.as_bytes()
        return String(StringSlice(unsafe_from_utf8=b[rng[0]:rng[1]]))

    fn select_all(mut self):
        self.anchor = 0
        self.cursor = len(self.text.as_bytes())

    fn delete_selection(mut self) -> Bool:
        if not self.has_selection():
            return False
        var rng = self._sel_range()
        self.text = _splice(self.text, rng[0], rng[1], String(""))
        self.cursor = rng[0]
        self.anchor = rng[0]
        return True

    # --- cursor movement ----------------------------------------------

    fn _move(mut self, new_cursor: Int, extend: Bool):
        self.cursor = new_cursor
        if not extend:
            self.anchor = new_cursor

    fn _step_left(mut self, extend: Bool):
        if not extend and self.has_selection():
            self._move(self._sel_range()[0], False)
            return
        self._move(_utf8_step_backward(self.text, self.cursor), extend)

    fn _step_right(mut self, extend: Bool):
        if not extend and self.has_selection():
            self._move(self._sel_range()[1], False)
            return
        self._move(_utf8_step_forward(self.text, self.cursor), extend)

    fn _word_left(mut self, extend: Bool):
        self._move(_prev_word_pos(self.text, self.cursor), extend)

    fn _word_right(mut self, extend: Bool):
        self._move(_next_word_pos(self.text, self.cursor), extend)

    fn _home(mut self, extend: Bool):
        self._move(0, extend)

    fn _end(mut self, extend: Bool):
        self._move(len(self.text.as_bytes()), extend)

    # --- mutation ------------------------------------------------------

    fn insert(mut self, s: String) -> Bool:
        """Insert ``s`` at the cursor (replacing the selection if any).
        Returns True if anything actually changed (text grew or a
        selection was deleted)."""
        var had_sel = self.has_selection()
        if had_sel:
            _ = self.delete_selection()
        if len(s.as_bytes()) == 0:
            return had_sel
        self.text = _splice(self.text, self.cursor, self.cursor, s)
        self.cursor = self.cursor + len(s.as_bytes())
        self.anchor = self.cursor
        return True

    fn backspace(mut self) -> Bool:
        if self.has_selection():
            return self.delete_selection()
        if self.cursor == 0:
            return False
        var prev = _utf8_step_backward(self.text, self.cursor)
        self.text = _splice(self.text, prev, self.cursor, String(""))
        self.cursor = prev
        self.anchor = prev
        return True

    fn delete_forward(mut self) -> Bool:
        if self.has_selection():
            return self.delete_selection()
        var n = len(self.text.as_bytes())
        if self.cursor >= n:
            return False
        var nxt = _utf8_step_forward(self.text, self.cursor)
        self.text = _splice(self.text, self.cursor, nxt, String(""))
        return True

    # --- main key entrypoint ------------------------------------------

    fn handle_key(mut self, event: Event) -> TextFieldKeyResult:
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
        # --- cursor / selection movement ---
        if k == KEY_LEFT:
            if word_jump:
                self._word_left(extend)
            else:
                self._step_left(extend)
            return TextFieldKeyResult(True, False)
        if k == KEY_RIGHT:
            if word_jump:
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
        # Ctrl+letter is canonicalized by the parser to
        # ``(lowercase letter, MOD_CTRL)``.
        var is_ctrl = (event.mods & MOD_CTRL) != 0
        if is_ctrl and k == UInt32(ord("a")):    # Ctrl+A — select all
            self.select_all()
            return TextFieldKeyResult(True, False)
        if is_ctrl and k == UInt32(ord("c")):    # Ctrl+C — copy
            if self.has_selection():
                clipboard_copy(self.selection_text())
            else:
                clipboard_copy(self.text)
            return TextFieldKeyResult(True, False)
        if is_ctrl and k == UInt32(ord("x")):    # Ctrl+X — cut
            if self.has_selection():
                clipboard_copy(self.selection_text())
                _ = self.delete_selection()
                return TextFieldKeyResult(True, True)
            clipboard_copy(self.text)
            var had = len(self.text.as_bytes()) > 0
            self.clear()
            return TextFieldKeyResult(True, had)
        if is_ctrl and k == UInt32(ord("v")):    # Ctrl+V — paste
            var pasted = _sanitize_single_line(clipboard_paste())
            if len(pasted.as_bytes()) == 0:
                # Still consume the chord (a paste of pure whitespace
                # / control bytes shouldn't fall through to the
                # caller's printable branch and inject a literal V).
                return TextFieldKeyResult(True, False)
            return TextFieldKeyResult(True, self.insert(pasted))
        # Modified printables are commands (e.g. a hotkey table) —
        # leave them alone for the caller to dispatch.
        if (event.mods & MOD_CTRL) != 0 or (event.mods & MOD_ALT) != 0:
            return TextFieldKeyResult(False, False)
        # Plain printable ASCII: insert at cursor.
        if UInt32(0x20) <= k and k < UInt32(0x7F):
            return TextFieldKeyResult(True, self.insert(chr(Int(k))))
        return TextFieldKeyResult(False, False)

    # --- mouse --------------------------------------------------------

    fn handle_mouse(
        mut self, event: Event, input_rect: Rect,
    ) -> Bool:
        """Position the cursor for a click inside ``input_rect``;
        extend the selection while dragging. Returns True if the
        event was consumed (click landed in the strip, or a drag
        from a previous press is in progress).

        ``input_rect`` is the one-row strip where ``self.text`` is
        drawn, in screen coordinates. The handler maps cells inside
        it to byte offsets — UTF-8 aware so a click on a multi-byte
        glyph lands at the codepoint start, not in the middle of its
        sequence.
        """
        if event.kind != EVENT_MOUSE:
            return False
        if event.button != MOUSE_BUTTON_LEFT:
            # A wheel event etc. on the strip isn't ours to handle —
            # let the caller route it elsewhere.
            return False
        var inside = input_rect.contains(event.pos)
        if event.pressed and not event.motion:
            # Press outside the strip: not our event. Press inside:
            # park the cursor and arm drag-to-extend.
            if not inside:
                return False
            self.cursor = self._byte_at_x(event.pos.x - input_rect.a.x)
            self.anchor = self.cursor
            self._drag = True
            return True
        if event.motion and self._drag:
            # Drag extends the selection; clamp to the field bounds.
            var x = event.pos.x - input_rect.a.x
            if x < 0:
                x = 0
            self.cursor = self._byte_at_x(x)
            return True
        if not event.pressed and self._drag:
            self._drag = False
            return True
        return False

    fn _byte_at_x(self, cell_x: Int) -> Int:
        """Translate a cell offset within the strip to a byte offset
        in ``self.text``. Past-text cells map to ``len(text)`` so a
        click well past the last character parks the cursor at the
        end."""
        var n_cells = utf8_codepoint_count(self.text)
        if cell_x < 0:
            return 0
        if cell_x >= n_cells:
            return len(self.text.as_bytes())
        return _utf8_byte_of_cell(self.text, cell_x)

    # --- rendering helpers --------------------------------------------

    fn cursor_cell(self) -> Int:
        """Cell column of the cursor relative to the start of
        ``self.text``."""
        return _utf8_cell_of_byte(self.text, self.cursor)

    fn paint(
        self, mut canvas: Canvas, rect: Rect, focused: Bool,
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

        Every dialog with an editable input strip routes through this
        method so the cyan-field idiom is consistent across the app.
        """
        var attr = text_field_bg()
        var sel_attr = text_field_sel_attr()
        var painter = Painter(rect)
        painter.fill(canvas, rect, String(" "), attr)
        _ = painter.put_text(
            canvas, Point(rect.a.x, rect.a.y), self.text, attr,
        )
        # Selection overlay: recolor the selected cells without
        # rewriting glyphs (``set_attr`` keeps put_text's UTF-8
        # decoding work).
        if self.has_selection():
            var rng = self._sel_range()
            var start_cell = _utf8_cell_of_byte(self.text, rng[0])
            var end_cell = _utf8_cell_of_byte(self.text, rng[1])
            var x = rect.a.x + start_cell
            var stop = rect.a.x + end_cell
            if stop > rect.b.x:
                stop = rect.b.x
            while x < stop:
                painter.set_attr(canvas, x, rect.a.y, sel_attr)
                x += 1
        if focused:
            var cur_x = rect.a.x + self.cursor_cell()
            if cur_x < rect.b.x and cur_x >= rect.a.x:
                # Reverse-video block over the current cell. Inside
                # a selection we still paint it — the user expects to
                # see *where* their caret sits.
                var glyph: String
                # Use the existing glyph at that cell if we painted one
                # (so a selected char shows under the caret), else " ".
                if cur_x < self.text_end_cell(rect.a.x):
                    glyph = canvas.get(cur_x, rect.a.y).glyph
                else:
                    glyph = String(" ")
                painter.set(
                    canvas, cur_x, rect.a.y,
                    Cell(glyph, Attr(LIGHT_GRAY, BLACK), 1),
                )

    fn text_end_cell(self, base_x: Int) -> Int:
        """Cell column just past the last codepoint of ``self.text``,
        anchored at ``base_x``. Used by ``paint`` to decide whether
        the cursor sits over a glyph (preserve it under the inverted
        cell) or past EOL (paint a space)."""
        return base_x + utf8_codepoint_count(self.text)


# --- Backwards-compat shim -----------------------------------------------


fn text_field_clipboard_key(
    event: Event, mut text: String,
) -> TextFieldKeyResult:
    """Apply Ctrl+C / Ctrl+X / Ctrl+V to a single-line ``text`` field.

    Legacy entrypoint kept for callers that haven't migrated to the
    full ``TextField`` model. Only handles clipboard; cursor moves,
    selection, and mouse all require the full model.

    ``Cmd+A`` (select-all) is also recognised here — without a cursor
    model selecting "all" is a no-op, so the helper just consumes the
    chord so it doesn't fall through to a hotkey table.
    """
    if event.kind != EVENT_KEY:
        return TextFieldKeyResult(False, False)
    var k = event.key
    if (event.mods & MOD_CTRL) == 0:
        return TextFieldKeyResult(False, False)
    if k == UInt32(ord("a")):    # Ctrl+A — no-op without a cursor
        return TextFieldKeyResult(True, False)
    if k == UInt32(ord("c")):    # Ctrl+C — copy whole field
        clipboard_copy(text)
        return TextFieldKeyResult(True, False)
    if k == UInt32(ord("x")):    # Ctrl+X — copy then clear
        clipboard_copy(text)
        var had_text = len(text.as_bytes()) > 0
        text = String("")
        return TextFieldKeyResult(True, had_text)
    if k == UInt32(ord("v")):    # Ctrl+V — append clipboard at end
        var pasted = _sanitize_single_line(clipboard_paste())
        if len(pasted.as_bytes()) == 0:
            return TextFieldKeyResult(True, False)
        text = text + pasted
        return TextFieldKeyResult(True, True)
    return TextFieldKeyResult(False, False)


# --- internals -----------------------------------------------------------


fn _sanitize_single_line(text: String) -> String:
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


fn _splice(text: String, start: Int, end: Int, replacement: String) -> String:
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


fn _utf8_codepoint_size(b: Int) -> Int:
    if b < 0x80:
        return 1
    if (b & 0xE0) == 0xC0:
        return 2
    if (b & 0xF0) == 0xE0:
        return 3
    if (b & 0xF8) == 0xF0:
        return 4
    return 1


fn _utf8_step_forward(text: String, col: Int) -> Int:
    var bytes = text.as_bytes()
    var n = len(bytes)
    if col >= n:
        return n
    var step = _utf8_codepoint_size(Int(bytes[col]))
    var nxt = col + step
    if nxt > n:
        nxt = n
    return nxt


fn _utf8_step_backward(text: String, col: Int) -> Int:
    if col <= 0:
        return 0
    var bytes = text.as_bytes()
    var c = col - 1
    while c > 0 and (Int(bytes[c]) & 0xC0) == 0x80:
        c -= 1
    return c


fn _utf8_cell_of_byte(text: String, byte_col: Int) -> Int:
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


fn _utf8_byte_of_cell(text: String, cell_col: Int) -> Int:
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


fn _next_word_pos(text: String, col: Int) -> Int:
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


fn _prev_word_pos(text: String, col: Int) -> Int:
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
