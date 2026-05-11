"""Modal dialog for editing one ``LanguageServerOverride``.

Used by Settings ▸ Languages to add a new language or edit the server
priority of an existing one. Layout::

    ╔══════════════ Edit language ═══════════════════════════════╗
    ║                                                            ║
    ║ Language id:  [python                ]                     ║
    ║ File types:   [py pyi pyw            ]                     ║
    ║                                                            ║
    ║ Server priority (top = highest):                           ║
    ║ ┌────────────────────────────────────────────────────────┐ ║
    ║ │ pyright-langserver --stdio                             │ ║
    ║ │ pylsp                                                  │ ║
    ║ │ basedpyright-langserver --stdio                        │ ║
    ║ └────────────────────────────────────────────────────────┘ ║
    ║ Argv:  [pyright-langserver --stdio                  ]      ║
    ║ [+ Add] [- Remove] [↑ Up] [↓ Down]                         ║
    ║                                                            ║
    ║                              [ Save ]    [ Cancel ]        ║
    ╚════════════════════════════════════════════════════════════╝

For built-in languages ``is_existing`` is True and the language id /
file types fields are read-only — the user can only adjust the
priority list. For user-added languages everything is editable and
``Save`` writes a fresh ``LanguageServerOverride`` record.
"""

from std.collections.list import List
from std.collections.optional import Optional

from .buttons import (
    BUTTON_FIRED, BUTTON_NONE, ShadowButton, paint_shadow_button,
)
from .canvas import Canvas, paint_drop_shadow
from .painter import Painter
from .colors import Attr, BLACK, BLUE, CYAN, GREEN, LIGHT_GRAY, WHITE
from .config import LanguageServerOverride
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_ENTER, KEY_ESC, KEY_TAB,
    MOD_SHIFT, MOUSE_BUTTON_LEFT,
    MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .geometry import Point, Rect, compute_dialog_rect
from .list_box import ListBox
from .text_field import TextField
from .type_ahead import TypeAhead, is_printable_ascii, type_ahead_pick
from .view import RowCursor
from .window import (
    hit_close_button, paint_close_button, paint_window_title,
)


# --- focus discriminants --------------------------------------------------
comptime _FOCUS_LANG       = UInt8(0)
comptime _FOCUS_FILE_TYPES = UInt8(1)
comptime _FOCUS_LIST       = UInt8(2)
comptime _FOCUS_ARGV       = UInt8(3)
comptime _FOCUS_ADD        = UInt8(4)
comptime _FOCUS_REMOVE     = UInt8(5)
comptime _FOCUS_UP         = UInt8(6)
comptime _FOCUS_DOWN       = UInt8(7)
comptime _FOCUS_SAVE       = UInt8(8)
comptime _FOCUS_CANCEL     = UInt8(9)


# --- layout ---------------------------------------------------------------
comptime _DIALOG_W = 70
comptime _DIALOG_H = 21
"""Dialog height. Controls flow top-down with a blank row between
each via ``RowCursor``; the bottom four rows are pinned to host the
hint line + Save/Cancel + bottom-border padding."""
comptime _LABEL_COL_W = 14
comptime _ARGV_LABEL_W = 6
"""Columns reserved for the inline ``Argv:`` label (5 chars + space)."""
comptime _LIST_HEIGHT = 5

# Button table indices.
comptime _BTN_ADD    = 0
comptime _BTN_REMOVE = 1
comptime _BTN_UP     = 2
comptime _BTN_DOWN   = 3
comptime _BTN_SAVE   = 4
comptime _BTN_CANCEL = 5


@fieldwise_init
struct _Layout(ImplicitlyCopyable, Movable):
    """Pre-computed Y rows and rects for the language editor dialog.

    Computed once from the dialog rect and shared by ``paint`` and
    ``handle_mouse`` so painted geometry and hit-test geometry can't
    drift out of sync as the layout evolves.
    """
    var lang_y: Int
    """Row for the language-id label + text field."""
    var ft_y: Int
    """Row for the file-types label + text field."""
    var priority_label_y: Int
    """Row for the ``Server priority`` block label."""
    var list_rect: Rect
    """Multi-row rect of the candidate list, sitting directly under
    the priority label (no gap — label and list are one logical
    control)."""
    var argv_y: Int
    """Row for the ``Argv:`` label + text field."""
    var actions_y: Int
    """Row for the Add / Remove / Up / Down button strip."""
    var hint_y: Int
    """Row for the built-in-language hint line, pinned to the bottom
    region above the commit buttons."""
    var commit_y: Int
    """Row for the Save / Cancel buttons, pinned to ``rect.b.y - 3``."""
    var lang_rect: Rect
    var ft_rect: Rect
    var argv_rect: Rect


fn _build_layout(rect: Rect) -> _Layout:
    """Lay the dialog out top-down with automatic gaps between
    controls, plus the bottom-anchored commit/hint rows."""
    var cursor = RowCursor(rect.a.y + 1)
    var lang_y = cursor.place()
    var ft_y = cursor.place()
    var priority_y = cursor.place()
    # The priority label is conceptually part of the list — sit them
    # flush (no gap) so the label visibly heads the rows it labels.
    var list_y = cursor.place_tight(_LIST_HEIGHT)
    var argv_y = cursor.place()
    var actions_y = cursor.place()
    var left = rect.a.x + 2
    var right = rect.b.x - 2
    return _Layout(
        lang_y, ft_y, priority_y,
        Rect(left, list_y, right, list_y + _LIST_HEIGHT),
        argv_y, actions_y,
        rect.b.y - 5, rect.b.y - 3,
        Rect(left + _LABEL_COL_W, lang_y, right, lang_y + 1),
        Rect(left + _LABEL_COL_W, ft_y, right, ft_y + 1),
        Rect(left + _ARGV_LABEL_W, argv_y, right, argv_y + 1),
    )


fn _dialog_rect(screen: Rect, pos: Optional[Point]) -> Rect:
    return compute_dialog_rect(screen, pos, _DIALOG_W, _DIALOG_H)


@fieldwise_init
struct _PlacedButton(ImplicitlyCopyable, Movable):
    var button: ShadowButton
    var focus: UInt8
    var enabled: Bool


struct LanguageEditor(Movable):
    var active: Bool
    var submitted: Bool
    var is_existing: Bool
    """When True, ``language_id`` and ``file_types`` are display-only
    (the language matches a built-in spec). Only the candidate list
    is editable. Set by the host on ``open``."""
    var lang_tf: TextField
    var file_types_tf: TextField
    var candidates: List[String]
    """Joined argv strings (space-separated). Edited via the bottom
    ``argv_tf`` strip — selecting a row copies it into the strip;
    typing into the strip writes back to the selected row."""
    var _list: ListBox
    """Standard scrollable list widget. Owns the selection index and
    scroll state for the candidates list; ``selected`` flows through
    its ``selected`` field. Painting is clipped to the list rect by
    the widget itself."""
    var argv_tf: TextField
    var focus: UInt8
    var pos: Optional[Point]
    var _drag: Optional[Point]
    var _buttons: List[_PlacedButton]
    var _type_ahead: TypeAhead
    """Type-to-jump prefix buffer for the candidates list. Reset on
    open / close and on focus changes away from the list so the next
    list-focused keystroke starts a fresh search."""

    fn __init__(out self):
        self.active = False
        self.submitted = False
        self.is_existing = False
        self.lang_tf = TextField()
        self.file_types_tf = TextField()
        self.candidates = List[String]()
        self._list = ListBox()
        self.argv_tf = TextField()
        self.focus = _FOCUS_LANG
        self.pos = Optional[Point]()
        self._drag = Optional[Point]()
        self._type_ahead = TypeAhead()
        self._buttons = List[_PlacedButton]()
        self._buttons.append(_PlacedButton(
            ShadowButton(String(" + Add "), 0, 0), _FOCUS_ADD, True,
        ))
        self._buttons.append(_PlacedButton(
            ShadowButton(String(" - Remove "), 0, 0), _FOCUS_REMOVE, True,
        ))
        self._buttons.append(_PlacedButton(
            ShadowButton(String(" Up "), 0, 0), _FOCUS_UP, True,
        ))
        self._buttons.append(_PlacedButton(
            ShadowButton(String(" Down "), 0, 0), _FOCUS_DOWN, True,
        ))
        self._buttons.append(_PlacedButton(
            ShadowButton(String(" Save "), 0, 0), _FOCUS_SAVE, True,
        ))
        self._buttons.append(_PlacedButton(
            ShadowButton(String(" Cancel "), 0, 0), _FOCUS_CANCEL, True,
        ))

    fn open(
        mut self, var language_id: String, var file_types: List[String],
        var candidates: List[String], is_existing: Bool,
    ):
        """Begin editing. ``candidates`` is the seed list of joined
        argv strings (one per server, space-separated). For Add-new
        pass an empty list; for Edit pass the effective candidates of
        the language (built-in or override-merged).
        """
        var ft_text = _join_space(file_types)
        self.lang_tf = TextField()
        self.lang_tf.set_text(language_id^)
        self.file_types_tf = TextField()
        self.file_types_tf.set_text(ft_text^)
        self.candidates = candidates^
        _ = file_types  # consumed via _join_space copy
        self._list.reset()
        self._list.set_selected(0 if len(self.candidates) > 0 else -1)
        self.argv_tf = TextField()
        if self._list.selected >= 0:
            self.argv_tf.set_text(self.candidates[self._list.selected])
        self.is_existing = is_existing
        self.active = True
        self.submitted = False
        self.focus = (
            _FOCUS_LIST if is_existing else _FOCUS_LANG
        )
        self.pos = Optional[Point]()
        self._drag = Optional[Point]()
        self._type_ahead.reset()

    fn close(mut self):
        self.active = False
        self.submitted = False
        self.is_existing = False
        self.lang_tf = TextField()
        self.file_types_tf = TextField()
        self.candidates = List[String]()
        self._list.reset()
        self.argv_tf = TextField()
        self.focus = _FOCUS_LANG
        self.pos = Optional[Point]()
        self._drag = Optional[Point]()
        self._type_ahead.reset()
        for i in range(len(self._buttons)):
            self._buttons[i].button.pressed = False
            self._buttons[i].button.pressed_inside = False

    fn value(self) -> LanguageServerOverride:
        """Snapshot the editor state into a ``LanguageServerOverride``.
        Empty argv lines (after trim) are skipped — they're the
        leftover from a + Add the user never filled in.
        """
        var ov = LanguageServerOverride()
        ov.language_id = self.lang_tf.text
        ov.file_types = _split_space(self.file_types_tf.text)
        for i in range(len(self.candidates)):
            var argv = _split_space(self.candidates[i])
            if len(argv) > 0:
                ov.argvs.append(argv^)
        return ov^

    # --- painting ---------------------------------------------------

    fn paint(mut self, mut canvas: Canvas, screen: Rect):
        if not self.active:
            return
        var bg = Attr(BLACK, LIGHT_GRAY)
        var border = Attr(WHITE, LIGHT_GRAY)
        var hint = Attr(BLUE, LIGHT_GRAY)
        var rect = _dialog_rect(screen, self.pos)
        var layout = _build_layout(rect)
        paint_drop_shadow(canvas, rect)
        var painter = Painter(rect)
        painter.fill(canvas, rect, String(" "), bg)
        painter.draw_box(canvas, rect, border, True)
        paint_window_title(canvas, rect, String(" Edit language "), bg, bg)
        paint_close_button(canvas, Point(rect.a.x, rect.a.y), border)
        # Labels.
        _ = painter.put_text(
            canvas, Point(rect.a.x + 2, layout.lang_y),
            String("Language id:"), bg,
        )
        _ = painter.put_text(
            canvas, Point(rect.a.x + 2, layout.ft_y),
            String("File types:"), bg,
        )
        _ = painter.put_text(
            canvas, Point(rect.a.x + 2, layout.priority_label_y),
            String("Server priority (top = highest):"), bg,
        )
        if self.is_existing:
            # Render the read-only fields as plain text, no input frame
            # or focus indicator — clarifies that the user can't change
            # them on a built-in language.
            _ = painter.put_text(
                canvas, Point(layout.lang_rect.a.x, layout.lang_rect.a.y),
                self.lang_tf.text, bg,
            )
            _ = painter.put_text(
                canvas, Point(layout.ft_rect.a.x, layout.ft_rect.a.y),
                self.file_types_tf.text, bg,
            )
        else:
            self.lang_tf.paint(
                canvas, layout.lang_rect, self.focus == _FOCUS_LANG,
            )
            self.file_types_tf.paint(
                canvas, layout.ft_rect, self.focus == _FOCUS_FILE_TYPES,
            )
        # Candidate list.
        self._paint_list(canvas, layout.list_rect)
        # Argv strip.
        _ = painter.put_text(
            canvas, Point(rect.a.x + 2, layout.argv_y),
            String("Argv:"), bg,
        )
        self.argv_tf.paint(
            canvas, layout.argv_rect, self.focus == _FOCUS_ARGV,
        )
        # Buttons row under the argv strip.
        self._layout_action_buttons(rect, layout.actions_y)
        for i in range(_BTN_ADD, _BTN_DOWN + 1):
            self._paint_button(canvas, i)
        # Save / Cancel pinned to the bottom-right.
        self._layout_commit_buttons(rect, layout)
        self._paint_button(canvas, _BTN_SAVE)
        self._paint_button(canvas, _BTN_CANCEL)
        # Hint line for the read-only built-in case so the UI explains
        # itself — otherwise users wonder why they can't edit the id.
        if self.is_existing:
            _ = painter.put_text(
                canvas, Point(rect.a.x + 2, layout.hint_y),
                String(
                    "Built-in language; only server priority is editable."
                ),
                hint,
            )

    fn _paint_list(
        mut self, mut canvas: Canvas, list_rect: Rect,
    ):
        var bg = Attr(BLACK, CYAN)
        if len(self.candidates) == 0:
            # The empty hint sits on the dialog-body background, but
            # paint through the list-rect-clipped helper so even a
            # too-narrow dialog can't push the hint past the list's
            # right edge.
            var painter = Painter(list_rect)
            painter.fill(canvas, list_rect, String(" "), bg)
            self._list.paint_empty_hint(
                canvas, list_rect,
                String("(no servers — press [+ Add])"),
                Attr(BLUE, LIGHT_GRAY),
            )
            return
        self._list.paint(
            canvas, list_rect, self.candidates,
            self.focus == _FOCUS_LIST, bg,
        )

    fn _layout_action_buttons(mut self, rect: Rect, y: Int):
        var x = rect.a.x + 2
        for i in range(_BTN_ADD, _BTN_DOWN + 1):
            self._buttons[i].button.move_to(x, y)
            x = x + self._buttons[i].button.total_width() + 1

    fn _layout_commit_buttons(mut self, rect: Rect, layout: _Layout):
        var bottom_y = layout.commit_y
        var cancel_w = self._buttons[_BTN_CANCEL].button.face_width()
        var cancel_x = rect.b.x - 2 - (cancel_w + 1)
        var save_w = self._buttons[_BTN_SAVE].button.face_width()
        var save_x = cancel_x - 1 - (save_w + 1)
        self._buttons[_BTN_SAVE].button.move_to(save_x, bottom_y)
        self._buttons[_BTN_CANCEL].button.move_to(cancel_x, bottom_y)

    fn _paint_button(mut self, mut canvas: Canvas, idx: Int):
        var pb = self._buttons[idx]
        var face: Attr
        if not pb.enabled:
            face = Attr(LIGHT_GRAY, GREEN)
        elif self.focus == pb.focus:
            face = Attr(WHITE, BLUE)
        else:
            face = Attr(BLACK, GREEN)
        paint_shadow_button(canvas, pb.button, face, LIGHT_GRAY)

    # --- key handling -----------------------------------------------

    fn handle_key(mut self, event: Event) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_KEY:
            return True
        var k = event.key
        if k == KEY_ESC:
            self.close()
            return True
        if k == KEY_TAB:
            var backward = (event.mods & MOD_SHIFT) != 0
            var prev = self.focus
            self.focus = self._next_focus(self.focus, backward)
            if prev == _FOCUS_LIST and self.focus != _FOCUS_LIST:
                self._type_ahead.reset()
            return True
        if k == KEY_ENTER:
            return self._activate_focus()
        if self.focus == _FOCUS_LIST:
            var prev = self._list.selected
            if self._list.handle_nav_key(event, len(self.candidates)):
                if self._list.selected != prev and self._list.selected >= 0:
                    self.argv_tf = TextField()
                    self.argv_tf.set_text(
                        self.candidates[self._list.selected]
                    )
                return True
        # Type-to-jump on the candidates list. Gated on focus so the
        # argv text field below it still consumes letters as text
        # input rather than as a search prefix.
        if self.focus == _FOCUS_LIST and is_printable_ascii(k):
            var labels = List[String]()
            for i in range(len(self.candidates)):
                labels.append(self.candidates[i])
            var hit = type_ahead_pick(
                self._type_ahead, labels, chr(Int(k)),
            )
            if hit >= 0:
                self._list.selected = hit
                self.argv_tf = TextField()
                self.argv_tf.set_text(self.candidates[self._list.selected])
            return True
        # Route to the focused field.
        if self.focus == _FOCUS_LANG and not self.is_existing:
            var r = self.lang_tf.handle_key(event)
            if r.consumed:
                return True
        elif self.focus == _FOCUS_FILE_TYPES and not self.is_existing:
            var r = self.file_types_tf.handle_key(event)
            if r.consumed:
                return True
        elif self.focus == _FOCUS_ARGV:
            var r = self.argv_tf.handle_key(event)
            if r.consumed:
                # Mirror the strip text into the selected list row so
                # the list updates live as the user types.
                if self._list.selected >= 0 \
                        and self._list.selected < len(self.candidates):
                    self.candidates[self._list.selected] = self.argv_tf.text
                return True
        return True

    fn _next_focus(self, current: UInt8, backward: Bool) -> UInt8:
        var ordered = List[UInt8]()
        if not self.is_existing:
            ordered.append(_FOCUS_LANG)
            ordered.append(_FOCUS_FILE_TYPES)
        ordered.append(_FOCUS_LIST)
        ordered.append(_FOCUS_ARGV)
        ordered.append(_FOCUS_ADD)
        if self._list.selected >= 0:
            ordered.append(_FOCUS_REMOVE)
            ordered.append(_FOCUS_UP)
            ordered.append(_FOCUS_DOWN)
        ordered.append(_FOCUS_SAVE)
        ordered.append(_FOCUS_CANCEL)
        var pos = -1
        for i in range(len(ordered)):
            if ordered[i] == current:
                pos = i
                break
        if pos < 0:
            return ordered[0]
        var n = len(ordered)
        if backward:
            return ordered[(pos - 1 + n) % n]
        return ordered[(pos + 1) % n]

    fn _activate_focus(mut self) -> Bool:
        if self.focus == _FOCUS_ADD:
            self._add_candidate()
            return True
        if self.focus == _FOCUS_REMOVE:
            self._remove_candidate()
            return True
        if self.focus == _FOCUS_UP:
            self._move_candidate(-1)
            return True
        if self.focus == _FOCUS_DOWN:
            self._move_candidate(1)
            return True
        if self.focus == _FOCUS_SAVE:
            self.submitted = True
            return True
        if self.focus == _FOCUS_CANCEL:
            self.close()
            return True
        # Enter on a non-button control walks forward.
        self.focus = self._next_focus(self.focus, False)
        return True

    fn _add_candidate(mut self):
        self.candidates.append(String(""))
        self._list.selected = len(self.candidates) - 1
        self.argv_tf = TextField()
        self.focus = _FOCUS_ARGV

    fn _remove_candidate(mut self):
        if self._list.selected < 0 or self._list.selected >= len(self.candidates):
            return
        var rebuilt = List[String]()
        for i in range(len(self.candidates)):
            if i == self._list.selected:
                continue
            rebuilt.append(self.candidates[i])
        self.candidates = rebuilt^
        if len(self.candidates) == 0:
            self._list.selected = -1
            self.argv_tf = TextField()
            self.focus = _FOCUS_ADD
        elif self._list.selected >= len(self.candidates):
            self._list.selected = len(self.candidates) - 1
        if self._list.selected >= 0:
            self.argv_tf = TextField()
            self.argv_tf.set_text(self.candidates[self._list.selected])

    fn _move_candidate(mut self, delta: Int):
        if self._list.selected < 0:
            return
        var target = self._list.selected + delta
        if target < 0 or target >= len(self.candidates):
            return
        var tmp = self.candidates[self._list.selected]
        self.candidates[self._list.selected] = self.candidates[target]
        self.candidates[target] = tmp
        self._list.selected = target

    # --- mouse ------------------------------------------------------

    fn handle_mouse(mut self, event: Event, screen: Rect) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_MOUSE:
            return True
        var rect = _dialog_rect(screen, self.pos)
        var layout = _build_layout(rect)
        # Buttons first.
        if self._dispatch_buttons(event):
            return True
        # Drag.
        if self._drag:
            if event.button == MOUSE_BUTTON_LEFT and event.pressed \
                    and event.motion:
                var off = self._drag.value()
                self.pos = Optional[Point](Point(
                    event.pos.x - off.x, event.pos.y - off.y,
                ))
                return True
            if not event.pressed:
                self._drag = Optional[Point]()
            return True
        if event.button == MOUSE_BUTTON_LEFT and event.pressed \
                and not event.motion \
                and hit_close_button(Point(rect.a.x, rect.a.y), event.pos):
            self.close()
            return True
        if event.button == MOUSE_BUTTON_LEFT and event.pressed \
                and not event.motion and event.pos.y == rect.a.y \
                and rect.a.x <= event.pos.x and event.pos.x < rect.b.x:
            self._drag = Optional[Point](Point(
                event.pos.x - rect.a.x, event.pos.y - rect.a.y,
            ))
            return True
        # Wheel scrolls the candidate list when the cursor is over it.
        # ``handle_mouse_press`` clamps scroll to the item count so the
        # viewport can't run past the end of the list.
        if event.button == MOUSE_WHEEL_UP or event.button == MOUSE_WHEEL_DOWN:
            if self._list.handle_mouse_press(
                event, layout.list_rect, len(self.candidates),
            ):
                return True
        # Every mouse event goes through every text field. Each
        # field consumes only when a press lands inside its strip or
        # when it's currently mid-drag — at most one claims any given
        # event. The TextField framework owns drag tracking, click
        # counting, focus-on-press, and motion / release dispatch.
        # The argv-edit mirror runs after the call: the field's text
        # may have changed via drag-select-then-delete-paste, and
        # the per-candidate copy needs to stay in sync.
        if not self.is_existing \
                and self.lang_tf.handle_mouse(event, layout.lang_rect):
            self.focus = _FOCUS_LANG
            return True
        if not self.is_existing \
                and self.file_types_tf.handle_mouse(event, layout.ft_rect):
            self.focus = _FOCUS_FILE_TYPES
            return True
        if self.argv_tf.handle_mouse(event, layout.argv_rect):
            self.focus = _FOCUS_ARGV
            if self._list.selected >= 0 \
                    and self._list.selected < len(self.candidates):
                self.candidates[self._list.selected] = self.argv_tf.text
            return True
        # Remaining widgets are press-only (the candidate list).
        if event.button != MOUSE_BUTTON_LEFT or not event.pressed \
                or event.motion:
            return True
        if layout.list_rect.contains(event.pos):
            var prev = self._list.selected
            _ = self._list.handle_mouse_press(
                event, layout.list_rect, len(self.candidates),
            )
            if self._list.selected != prev and self._list.selected >= 0:
                self.argv_tf = TextField()
                self.argv_tf.set_text(self.candidates[self._list.selected])
            self.focus = _FOCUS_LIST
            return True
        return True

    fn _dispatch_buttons(mut self, event: Event) -> Bool:
        for i in range(len(self._buttons)):
            var status = self._buttons[i].button.handle_mouse(event)
            if status == BUTTON_NONE:
                continue
            if status == BUTTON_FIRED and self._buttons[i].enabled:
                self.focus = self._buttons[i].focus
                _ = self._activate_focus()
            return True
        return False


# --- helpers --------------------------------------------------------------


fn _join_space(items: List[String]) -> String:
    var out = String("")
    for i in range(len(items)):
        if i > 0:
            out = out + String(" ")
        out = out + items[i]
    return out^


fn _split_space(text: String) -> List[String]:
    """Shell-style argv tokenizer: split on whitespace, but treat
    ``"..."`` and ``'...'`` as a single token whose interior whitespace
    is preserved (the quote characters themselves are stripped). Adjacent
    quoted/unquoted runs concatenate, mirroring POSIX shell — so
    ``foo"a b"`` becomes one token ``fooa b``. Crucial for LSP commands
    like ``iommi-lsp --ty-command "/path/to/ty server"`` where the
    second flag's value must reach the child as one argv entry.
    """
    var out = List[String]()
    var b = text.as_bytes()
    var n = len(b)
    var i = 0
    while i < n:
        # Skip leading whitespace between tokens.
        while i < n and (b[i] == 0x20 or b[i] == 0x09):
            i += 1
        if i >= n:
            break
        # Accumulate one token, honoring quotes.
        var token = List[UInt8]()
        var has_content = False
        while i < n:
            var c = b[i]
            if c == 0x20 or c == 0x09:
                break
            if c == 0x22:  # double quote
                i += 1
                has_content = True
                while i < n and b[i] != 0x22:
                    # Inside ``"…"`` only ``\"`` and ``\\`` are escapes;
                    # leave other backslashes literal so a Windows path
                    # like ``"C:\\Users\\…"`` isn't mangled.
                    if b[i] == 0x5C and i + 1 < n \
                            and (b[i + 1] == 0x22 or b[i + 1] == 0x5C):
                        token.append(b[i + 1])
                        i += 2
                        continue
                    token.append(b[i])
                    i += 1
                if i < n:  # consume closing quote
                    i += 1
                continue
            if c == 0x27:  # single quote
                i += 1
                has_content = True
                while i < n and b[i] != 0x27:
                    token.append(b[i])
                    i += 1
                if i < n:
                    i += 1
                continue
            token.append(c)
            has_content = True
            i += 1
        if has_content:
            out.append(String(StringSlice(
                ptr=token.unsafe_ptr(), length=len(token),
            )))
    return out^
