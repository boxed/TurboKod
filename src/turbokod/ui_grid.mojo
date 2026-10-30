"""Grid projector for declarative UI (see ``ui_tree.mojo``).

``GridForm`` lays a ``UINode`` tree out in cells, paints it with the
existing widgets (``TextField``, ``Dropdown``, ``Checkbox``,
``ShadowButton``, ``ListBox``), and turns keys and clicks into
``UIEvent``s — ``set(key, value)`` / ``act(id)`` — for the dialog to apply.
The dialog never sees widgets; the projector never sees the dialog's state.

One set of layout rules replaces per-dialog hand placement, so every grid
dialog lines up the same way:

* a frame with the title on its top border, a margin of two columns and
  one row inside it;
* form labels right-aligned in one column, their controls sharing one left
  edge two columns further;
* one blank row between a stack's children (``ui_vstack`` spacing);
* button rows centered, buttons two columns apart; text fields and tables
  stretch to the width they're given;
* a path field (``ui_path``) gets a Browse button two columns to its right,
  which opens a file dialog over the form.

Widget state that isn't the dialog's business — a field's cursor and
selection, a pop-up being open, a button's press latch, a table's scroll —
lives here, keyed by the node's ``key`` (keys are unique per dialog).
"""

from std.collections.list import List

from .buttons import (
    BUTTON_FIRED, Checkbox, ShadowButton, button_face, paint_checkbox,
    paint_shadow_button,
)
from .canvas import Canvas
from .cell import Cell
from .colors import (
    Attr, BLACK, BLUE, CYAN, DARK_GRAY, EDITOR_BG, EDITOR_FG, GREEN,
    LIGHT_GRAY, RED, SYN_COMMENT, SYN_DECORATOR, SYN_IDENT, SYN_KEYWORD,
    SYN_NUMBER, SYN_OPERATOR, SYN_STRING, WHITE, YELLOW,
)
from .dropdown import DROPDOWN_HIT_BODY, DROPDOWN_HIT_POPUP, Dropdown
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE, KEY_DOWN, KEY_END, KEY_ENTER, KEY_ESC,
    KEY_HOME, KEY_LEFT, KEY_PAGEDOWN, KEY_PAGEUP, KEY_RIGHT, KEY_SPACE,
    KEY_TAB, KEY_UP, MOD_ALT, MOD_CTRL, MOD_META, MOD_SHIFT,
    MOUSE_BUTTON_LEFT,
)
from .file_dialog import FileDialog
from .geometry import Point, Rect, center_in
from .list_box import ListBox
from .painter import Painter
from .string_utils import display_columns, truncate_to_columns
from .text_field import TextField
from .type_ahead import TypeAhead, is_type_ahead_key, type_ahead_pick
from .ui_tree import (
    UI_BROWSE, UI_BUTTON, UI_CANCEL, UI_CENTER, UI_CHECK, UI_CHECKABLE, UI_CHOICE,
    UI_DEFAULT, UI_DESTRUCTIVE, UI_DIALOG, UI_FORM, UI_HEADING, UI_HOTKEY,
    UI_HSTACK, UI_LABEL, UI_ROW, UI_SECONDARY, UI_SEPARATOR, UI_SPACER,
    UI_DISABLED, UI_PREVIEW, UI_TABLE, UI_TABS, UI_TEXT, UI_VSTACK, UINode,
    UI_CODE, UI_LARGE, UI_LIST, UI_MULTI, UI_NAV, UI_RGB, UISpan,
    ui_button, ui_list_anchor, ui_list_row,
)
from .scrollbar import ScrollBarArea
from .window import close_button_clicked, paint_modal_frame, paint_window_title


comptime _MARGIN_X = 2
comptime _MARGIN_Y = 1
comptime _LABEL_GAP = 2
comptime _TEXT_MIN_W = 24
comptime _TABLE_MIN_W = 30
comptime _CHOICE_MIN_W = 10
comptime _COLUMN_MAX_W = 24
"""A table column (but the last) never grows past this; longer cells are
cut with an ellipsis, so one long value can't push the rest off."""
comptime _BROWSE_PREFIX = "browse:"
"""The grid's own action for a path field's Browse button — handled here,
never reported to the dialog."""


@fieldwise_init
struct UIEvent(Copyable, Movable):
    """What the user did: an edit (``is_action`` False: ``key`` gets
    ``value``) or a button / command (``is_action`` True: run ``key``)."""
    var is_action: Bool
    var key: String
    var value: String


def ui_set(var key: String, var value: String) -> UIEvent:
    return UIEvent(False, key^, value^)


def ui_act(var key: String) -> UIEvent:
    return UIEvent(True, key^, String(""))


@fieldwise_init
struct _Placed(Copyable, Movable):
    """A leaf (or a tab header) where the last layout put it."""
    var node: UINode
    var rect: Rect


def _is_focusable(n: UINode) -> Bool:
    if not n.enabled():
        return False
    if n.kind == UI_LIST:
        return not n.has(UI_CODE)
    return n.kind == UI_TEXT or n.kind == UI_CHECK or n.kind == UI_CHOICE \
        or n.kind == UI_TABLE or n.kind == UI_BUTTON or n.kind == UI_TABS


def _button_label(n: UINode) -> String:
    return String(" ") + n.text + String(" ")


def _column_widths(n: UINode) -> List[Int]:
    var widths = List[Int]()
    for c in range(len(n.options)):
        widths.append(display_columns(n.options[c]))
    for r in range(len(n.rows)):
        for c in range(len(n.rows[r])):
            if c >= len(widths):
                widths.append(0)
            var w = display_columns(n.rows[r][c])
            if n.has(UI_CHECKABLE) and c == 0:
                w = 3
            if w > widths[c]:
                widths[c] = w
    for c in range(len(widths) - 1):
        widths[c] = min(widths[c], _COLUMN_MAX_W)
    return widths^


def _fit(text: String, width: Int) -> String:
    """``text`` cut to ``width`` columns, with an ellipsis when it was cut."""
    if display_columns(text) <= width:
        return text
    if width <= 1:
        return truncate_to_columns(text, width)
    return truncate_to_columns(text, width - 1) + String("…")


def _form_label(text: String) -> String:
    """A form row's label as painted: ``Text:`` (an empty one stays empty,
    for a checkbox that labels itself)."""
    if len(text.as_bytes()) == 0:
        return text
    return text + String(":")


def _measure(n: UINode) -> Tuple[Int, Int]:
    var k = n.kind
    if k == UI_LABEL:
        return (display_columns(n.text), 1)
    if k == UI_TEXT:
        var w = n.number + 2 if n.number > 0 \
            else max(_TEXT_MIN_W, display_columns(n.value) + 2)
        if n.has(UI_BROWSE):
            return (w + _LABEL_GAP + _measure(_browse_button(n))[0], 2)
        return (w, 1)
    if k == UI_CHECK:
        return (display_columns(n.text) + 6, 1)
    if k == UI_CHOICE:
        var w = _CHOICE_MIN_W
        for i in range(len(n.options)):
            w = max(w, display_columns(n.options[i]) + 4)
        return (w, 1)
    if k == UI_BUTTON:
        return (ShadowButton(_button_label(n), 0, 0).total_width(), 2)
    if k == UI_SEPARATOR:
        return (1, 1)
    if k == UI_SPACER:
        return (0, 0)
    if k == UI_PREVIEW:
        return (40, len(_preview_lines()))
    if k == UI_LIST:
        return (60, max(n.height, 3))
    if k == UI_TABLE:
        var widths = _column_widths(n)
        var w = 2
        for i in range(len(widths)):
            w += widths[i] + (2 if i > 0 else 0)
        return (max(_TABLE_MIN_W, min(w, 90)), max(n.height, 3) + 1)
    if k == UI_ROW:
        var c = _measure(n.children[0])
        return (display_columns(_form_label(n.text)) + _LABEL_GAP + c[0], c[1])
    if k == UI_FORM:
        var label_w = 0
        var control_w = 0
        var h = 0
        for i in range(len(n.children)):
            label_w = max(label_w, display_columns(_form_label(n.children[i].text)))
            var c = _measure(n.children[i].children[0])
            control_w = max(control_w, c[0])
            h += c[1] + _form_gap(n, i)
        return (label_w + _LABEL_GAP + control_w, h)
    if k == UI_VSTACK:
        var w = 0
        var h = 0
        var shown = 0
        for i in range(len(n.children)):
            var c = _measure(n.children[i])
            w = max(w, c[0])
            if n.children[i].kind == UI_SPACER:
                continue
            if shown > 0:
                h += n.number
            h += c[1]
            shown += 1
        return (w, h)
    if k == UI_HSTACK:
        var w = 0
        var h = 0
        for i in range(len(n.children)):
            var c = _measure(n.children[i])
            if i > 0:
                w += n.number
            w += c[0]
            h = max(h, c[1])
        return (w, h)
    if k == UI_TABS:
        var header = 0
        var w = 0
        var h = 0
        for i in range(len(n.children)):
            header += display_columns(n.children[i].text) + 3
            var c = _measure(n.children[i])
            w = max(w, c[0])
            h = max(h, c[1])
        return (max(header, w), h + 2)
    if k == UI_DIALOG:
        var c = _measure(n.children[0])
        var w = max(c[0], display_columns(n.text) + 8)
        return (w + 2 * (_MARGIN_X + 1), c[1] + 2 + _MARGIN_Y + _bottom_margin(n))
    return (0, 0)


def _ends_with_buttons(n: UINode) -> Bool:
    """True when the bottom row of ``n`` is a row of buttons."""
    if n.kind == UI_BUTTON:
        return True
    if n.kind == UI_HSTACK:
        for i in range(len(n.children)):
            if _ends_with_buttons(n.children[i]):
                return True
        return False
    if n.kind == UI_VSTACK or n.kind == UI_DIALOG:
        for i in range(len(n.children) - 1, -1, -1):
            if n.children[i].kind != UI_SPACER:
                return _ends_with_buttons(n.children[i])
    return False


def _bottom_margin(dialog: UINode) -> Int:
    """Rows between the content and the bottom border. A closing button
    row's shadow is margin enough — Turbo Vision puts the shadow right on
    the row above the frame."""
    if _ends_with_buttons(dialog):
        return max(_MARGIN_Y - 1, 0)
    return _MARGIN_Y


def _browse_button(n: UINode) -> UINode:
    """The Browse button a path field (``UI_BROWSE``) is drawn with."""
    var b = ui_button(String(_BROWSE_PREFIX) + n.key, String("Browse"))
    if not n.enabled():
        b.flags |= UI_DISABLED
    return b^


def _browse_seed(path: String) -> String:
    """Where Browse starts: the directory of the path already typed, else
    the root."""
    var b = path.as_bytes()
    var i = len(b) - 1
    while i >= 0 and b[i] != 0x2F:
        i -= 1
    if i <= 0:
        return String("/")
    return String(StringSpan(unsafe_from_utf8=b[:i]))


def _form_gap(n: UINode, i: Int) -> Int:
    """Blank rows above form row ``i``: the form's spacing, except inside a
    cluster of checkboxes that label themselves (no form label), which stay
    together like a Turbo Vision check-box group."""
    if i == 0:
        return 0
    ref a = n.children[i - 1]
    ref b = n.children[i]
    if len(a.text.as_bytes()) == 0 and len(b.text.as_bytes()) == 0 \
            and a.children[0].kind == UI_CHECK and b.children[0].kind == UI_CHECK:
        return 0
    # A Browse button's shadow row already separates it from the next row.
    if a.children[0].kind == UI_TEXT and a.children[0].has(UI_BROWSE):
        return max(0, n.number - 1)
    return n.number


def _stretches(n: UINode) -> Bool:
    """Takes spare width in a row (fields and tables), versus keeping its
    natural width (labels, checkboxes, choices, buttons)."""
    return (n.kind == UI_TEXT and n.number == 0) or n.kind == UI_TABLE \
        or n.kind == UI_LIST \
        or n.kind == UI_SEPARATOR \
        or n.kind == UI_FORM or n.kind == UI_VSTACK or n.kind == UI_TABS \
        or n.kind == UI_PREVIEW


def _arrange(n: UINode, r: Rect, mut out: List[_Placed]):
    var k = n.kind
    if k == UI_VSTACK:
        var heights = List[Int]()
        var used = 0
        var spacers = 0
        var shown = 0
        for i in range(len(n.children)):
            var c = _measure(n.children[i])
            heights.append(c[1])
            if n.children[i].kind == UI_SPACER:
                spacers += 1
                continue
            if shown > 0:
                used += n.number
            used += c[1]
            shown += 1
        var spare = r.height() - used
        # Spare height goes to spacers, else to the last table (a list
        # that can show more rows) — which is also what gives rows back
        # when the screen is too short for the whole dialog.
        if spacers == 0 or spare < 0:
            for i in range(len(n.children) - 1, -1, -1):
                if n.children[i].kind == UI_TABLE or (
                    n.children[i].kind == UI_TABS
                ) or n.children[i].kind == UI_LIST:
                    var h = max(heights[i] + spare, 2)
                    spare -= h - heights[i]
                    heights[i] = h
                    break
        # Still too short: close up the gaps between children.
        var gap = n.number
        if spare < 0 and shown > 1:
            spare += (shown - 1) * gap
            gap = 0
        spare = max(spare, 0)
        var y = r.a.y
        shown = 0
        for i in range(len(n.children)):
            var h = heights[i]
            if n.children[i].kind == UI_SPACER:
                h = spare // spacers if spacers > 0 else 0
            elif shown > 0:
                y += gap
            if n.children[i].kind != UI_SPACER:
                shown += 1
            _arrange(n.children[i], Rect(r.a.x, y, r.b.x, min(y + h, r.b.y)), out)
            y += h
        return
    if k == UI_HSTACK:
        var widths = List[Int]()
        var used = 0
        var stretchers = 0
        for i in range(len(n.children)):
            var c = _measure(n.children[i])
            widths.append(c[0])
            used += c[0] + (n.number if i > 0 else 0)
            if _stretches(n.children[i]):
                stretchers += 1
        var spare = max(0, r.width() - used)
        var x = r.a.x
        if stretchers > 0:
            var share = spare // stretchers
            for i in range(len(n.children)):
                if _stretches(n.children[i]):
                    widths[i] += share
        elif n.has(UI_CENTER):
            x += spare // 2
        for i in range(len(n.children)):
            if i > 0:
                x += n.number
            var c = _measure(n.children[i])
            _arrange(
                n.children[i], Rect(x, r.a.y, min(x + widths[i], r.b.x), r.a.y + c[1]),
                out,
            )
            x += widths[i]
        return
    if k == UI_FORM:
        var label_w = 0
        for i in range(len(n.children)):
            label_w = max(label_w, display_columns(_form_label(n.children[i].text)))
        # The gaps between rows go first when the screen is short.
        var spaced = _measure(n)[1] <= r.height()
        var y = r.a.y
        for i in range(len(n.children)):
            if spaced:
                y += _form_gap(n, i)
            ref row = n.children[i]
            var c = _measure(row.children[0])
            # Right-aligned label, controls sharing one left edge.
            var lab = UINode(UI_LABEL)
            lab.text = _form_label(row.text)
            var lw = display_columns(lab.text)
            if not row.children[0].enabled():
                lab.flags = UI_SECONDARY
            out.append(_Placed(lab^, Rect(r.a.x + label_w - lw, y, r.a.x + label_w, y + 1)))
            var cx = r.a.x + label_w + _LABEL_GAP
            var cw = r.b.x - cx if _stretches(row.children[0]) else c[0]
            _arrange(row.children[0], Rect(cx, y, min(cx + cw, r.b.x), y + c[1]), out)
            y += c[1]
        return
    if k == UI_ROW:
        var f = UINode(UI_FORM)
        f.children.append(n.copy())
        _arrange(f, r, out)
        return
    if k == UI_TABS:
        out.append(_Placed(n.copy(), Rect(r.a.x, r.a.y, r.b.x, r.a.y + 1)))
        var sel = n.number
        if sel >= 0 and sel < len(n.children):
            _arrange(n.children[sel], Rect(r.a.x, r.a.y + 2, r.b.x, r.b.y), out)
        return
    if k == UI_DIALOG:
        _arrange(n.children[0], r, out)
        return
    if k == UI_SPACER:
        return
    if k == UI_TEXT and n.has(UI_BROWSE):
        var b = _browse_button(n)
        var bw = _measure(b)[0]
        var fw = max(1, r.width() - bw - _LABEL_GAP)
        out.append(_Placed(n.copy(), Rect(r.a.x, r.a.y, r.a.x + fw, r.a.y + 1)))
        var bx = r.a.x + fw + _LABEL_GAP
        out.append(_Placed(b^, Rect(bx, r.a.y, bx + bw, r.a.y + 2)))
        return
    # Leaves keep their natural size unless they stretch.
    var m = _measure(n)
    var w = r.width() if _stretches(n) else min(m[0], r.width())
    var h = r.height() if n.kind == UI_TABLE or n.kind == UI_LIST \
        else min(m[1], r.height())
    out.append(_Placed(n.copy(), Rect(r.a.x, r.a.y, r.a.x + w, r.a.y + h)))


struct GridForm(Movable):
    """The grid projection of one open dialog: layout, paint and input,
    plus the widget state the dialog doesn't own. ``reset`` it when the
    dialog opens so stale cursors / scrolls / focus don't leak in."""
    var focus_key: String
    var _placed: List[_Placed]
    var _frame: Rect
    var _cancel: String
    var _field_keys: List[String]
    var _fields: List[TextField]
    var _drop_keys: List[String]
    var _drops: List[Dropdown]
    var _list_keys: List[String]
    var _lists: List[ListBox]
    var _list_marks: List[Int]
    """A code view's marked line as last revealed, parallel to ``_lists``."""
    var _button_keys: List[String]
    var _buttons: List[ShadowButton]
    var _open_drop: String
    var _screen: Rect
    var _file_dialog: FileDialog
    var _browse_key: String
    """The path field the open file dialog will fill."""
    var _type_ahead: TypeAhead
    var fill: Bool
    """Lay the dialog out over the whole screen rather than centered at its
    natural size — for a host window that is the dialog (classic macOS
    Settings)."""

    def __init__(out self):
        self.focus_key = String("")
        self._placed = List[_Placed]()
        self._frame = Rect(0, 0, 0, 0)
        self._cancel = String("")
        self._field_keys = List[String]()
        self._fields = List[TextField]()
        self._drop_keys = List[String]()
        self._drops = List[Dropdown]()
        self._list_keys = List[String]()
        self._lists = List[ListBox]()
        self._list_marks = List[Int]()
        self._button_keys = List[String]()
        self._buttons = List[ShadowButton]()
        self._open_drop = String("")
        self._screen = Rect(0, 0, 0, 0)
        self._file_dialog = FileDialog()
        self._browse_key = String("")
        self._type_ahead = TypeAhead()
        self.fill = False

    def reset(mut self):
        self.focus_key = String("")
        self._placed = List[_Placed]()
        self._field_keys = List[String]()
        self._fields = List[TextField]()
        self._drop_keys = List[String]()
        self._drops = List[Dropdown]()
        self._list_keys = List[String]()
        self._lists = List[ListBox]()
        self._list_marks = List[Int]()
        self._button_keys = List[String]()
        self._buttons = List[ShadowButton]()
        self._open_drop = String("")
        self._file_dialog.close()
        self._browse_key = String("")
        self._type_ahead.reset()

    # --- widget state, keyed by node key ------------------------------

    def _field(mut self, n: UINode) -> Int:
        for i in range(len(self._field_keys)):
            if self._field_keys[i] == n.key:
                # The dialog's value wins unless the user is editing it
                # here (then this field *is* the source of the edits).
                if self._fields[i].text != n.value and n.key != self.focus_key:
                    self._fields[i].set_text(n.value)
                return i
        var f = TextField()
        f.set_text(n.value)
        self._field_keys.append(n.key)
        self._fields.append(f^)
        return len(self._fields) - 1

    def _drop(mut self, n: UINode) -> Int:
        for i in range(len(self._drop_keys)):
            if self._drop_keys[i] == n.key:
                if self._drops[i].options != n.options:
                    self._drops[i] = Dropdown(n.options.copy(), n.number)
                elif not self._drops[i].is_open:
                    self._drops[i].index = n.number
                return i
        self._drop_keys.append(n.key)
        self._drops.append(Dropdown(n.options.copy(), n.number))
        return len(self._drops) - 1

    def _list(mut self, n: UINode) -> Int:
        for i in range(len(self._list_keys)):
            if self._list_keys[i] == n.key:
                if self._lists[i].selected != n.number:
                    self._lists[i].set_selected(n.number)
                return i
        var lb = ListBox(False)
        lb.set_selected(n.number)
        self._list_keys.append(n.key)
        self._lists.append(lb^)
        return len(self._lists) - 1

    def _vlist(mut self, n: UINode) -> Int:
        """A ``UI_LIST``'s ``ListBox``: its scroll and its selection,
        synced from the dialog's (a code view has none)."""
        var row = -1 if n.has(UI_CODE) else n.number
        var anchor = -1 if n.has(UI_CODE) else ui_list_anchor(n.text)
        for i in range(len(self._list_keys)):
            if self._list_keys[i] == n.key:
                if self._lists[i].selected != row or (
                    n.has(UI_MULTI) and self._lists[i].anchor() != anchor
                ):
                    self._select(i, row, anchor, n.count)
                return i
        var lb = ListBox(n.has(UI_MULTI))
        self._list_keys.append(n.key)
        self._lists.append(lb^)
        self._list_marks.append(-1)
        var i = len(self._lists) - 1
        self._select(i, row, anchor, n.count)
        return i

    def _select(mut self, i: Int, row: Int, anchor: Int, count: Int):
        if not self._lists[i].multi or anchor < 0 or anchor == row:
            self._lists[i].set_selected(row)
            return
        var rows = List[Int]()
        for r in range(min(anchor, row), max(anchor, row) + 1):
            rows.append(r)
        self._lists[i].set_selection(rows, row, anchor, count)

    def _button(mut self, n: UINode, r: Rect) -> Int:
        for i in range(len(self._button_keys)):
            if self._button_keys[i] == n.key:
                if self._buttons[i].label != _button_label(n):
                    self._buttons[i] = ShadowButton(_button_label(n), 0, 0)
                self._buttons[i].move_to(r.a.x, r.a.y)
                return i
        var b = ShadowButton(_button_label(n), 0, 0)
        b.move_to(r.a.x, r.a.y)
        self._button_keys.append(n.key)
        self._buttons.append(b^)
        return len(self._buttons) - 1

    # --- layout --------------------------------------------------------

    def _layout(mut self, root: UINode, screen: Rect):
        self._screen = screen
        self._cancel = root.key
        var m = _measure(root)
        var w = min(m[0], screen.width() - 2)
        var h = min(m[1], screen.height() - 2)
        if root.has(UI_LARGE):
            w = max(w, min(screen.width() - 4, screen.width() * 4 // 5))
            h = max(h, screen.height() - 4)
        self._frame = screen if self.fill else center_in(screen, max(w, 10), max(h, 5))
        var body = Rect(
            self._frame.a.x + 1 + _MARGIN_X, self._frame.a.y + 1 + _MARGIN_Y,
            self._frame.b.x - 1 - _MARGIN_X, self._frame.b.y - 1 - _bottom_margin(root),
        )
        self._placed = List[_Placed]()
        _arrange(root, body, self._placed)
        # Widgets follow the tree; buttons learn where they are.
        for i in range(len(self._placed)):
            var p = self._placed[i].copy()
            if p.node.kind == UI_TEXT:
                _ = self._field(p.node)
            elif p.node.kind == UI_CHOICE:
                _ = self._drop(p.node)
            elif p.node.kind == UI_TABLE:
                _ = self._list(p.node)
            elif p.node.kind == UI_LIST:
                _ = self._vlist(p.node)
            elif p.node.kind == UI_BUTTON:
                _ = self._button(p.node, p.rect)
        # Keep focus on something focusable that still exists.
        var keep = False
        var first = String("")
        for i in range(len(self._placed)):
            if _is_focusable(self._placed[i].node):
                if len(first.as_bytes()) == 0:
                    first = self._placed[i].node.key
                if self._placed[i].node.key == self.focus_key:
                    keep = True
        if not keep:
            self.focus_key = first

    def frame(self) -> Rect:
        return self._frame

    # --- paint ---------------------------------------------------------

    def paint(
        mut self, root: UINode, mut canvas: Canvas, screen: Rect,
        active: Bool = True,
    ):
        """Draw the dialog. ``active`` False draws it without focus — a
        dialog stacked under another one."""
        self._layout(root, screen)
        var bg = Attr(BLACK, LIGHT_GRAY)
        _ = paint_modal_frame(canvas, self._frame, bg)
        # Filling a host window, the window's own title bar has the title.
        if len(root.text.as_bytes()) > 0 and not self.fill:
            paint_window_title(
                canvas, self._frame, String(" ") + root.text + String(" "), bg, bg,
            )
        var painter = Painter(self._frame)
        var popup = -1
        var popup_rect = Rect(0, 0, 0, 0)
        for i in range(len(self._placed)):
            var p = self._placed[i].copy()
            var focused = active and p.node.key == self.focus_key \
                and _is_focusable(p.node)
            var k = p.node.kind
            if k == UI_LABEL:
                var attr = bg
                if p.node.has(UI_SECONDARY):
                    attr = Attr(DARK_GRAY, LIGHT_GRAY)
                elif p.node.has(UI_HEADING):
                    attr = Attr(BLUE, LIGHT_GRAY)
                _ = painter.put_text(
                    canvas, p.rect.a, _fit(p.node.text, p.rect.width()), attr,
                )
            elif k == UI_TEXT:
                var fi = self._field(p.node)
                if p.node.enabled():
                    self._fields[fi].paint(canvas, p.rect, focused)
                    if not focused and len(self._fields[fi].text.as_bytes()) == 0:
                        _ = painter.put_text(
                            canvas, Point(p.rect.a.x + 1, p.rect.a.y),
                            _fit(p.node.placeholder, p.rect.width() - 1),
                            Attr(DARK_GRAY, CYAN),
                        )
                else:
                    painter.fill(canvas, p.rect, String(" "), Attr(DARK_GRAY, LIGHT_GRAY))
                    _ = painter.put_text(
                        canvas, p.rect.a, p.node.value, Attr(DARK_GRAY, LIGHT_GRAY),
                    )
            elif k == UI_CHECK:
                if p.node.enabled():
                    var cb = Checkbox(p.node.text, p.rect.a.x, p.rect.a.y, p.node.number != 0)
                    paint_checkbox(
                        canvas, cb, Attr(BLACK, CYAN), Attr(BLACK, GREEN), focused,
                        p.rect.b.x,
                    )
                else:
                    _ = painter.put_text(
                        canvas, p.rect.a,
                        String(" [") + (String("x") if p.node.number != 0 else String(" "))
                        + String("] ") + p.node.text,
                        Attr(DARK_GRAY, LIGHT_GRAY),
                    )
            elif k == UI_CHOICE:
                var di = self._drop(p.node)
                if p.node.enabled():
                    self._drops[di].paint(
                        canvas, p.rect, focused, Attr(WHITE, BLUE), Attr(BLACK, CYAN),
                    )
                    if self._drops[di].is_open:
                        popup = di
                        popup_rect = p.rect
                else:
                    painter.fill(canvas, p.rect, String(" "), Attr(DARK_GRAY, LIGHT_GRAY))
                    if p.node.number >= 0 and p.node.number < len(p.node.options):
                        _ = painter.put_text(
                            canvas, p.rect.a, String(" ") + p.node.options[p.node.number],
                            Attr(DARK_GRAY, LIGHT_GRAY),
                        )
            elif k == UI_BUTTON:
                var bi = self._button(p.node, p.rect)
                var face = button_face(focused, p.node.enabled())
                if p.node.has(UI_DESTRUCTIVE) and p.node.enabled():
                    face = Attr(YELLOW if focused else WHITE, RED)
                paint_shadow_button(canvas, self._buttons[bi], face, LIGHT_GRAY)
            elif k == UI_SEPARATOR:
                for x in range(p.rect.a.x, p.rect.b.x):
                    painter.set(canvas, x, p.rect.a.y, _sep_cell())
            elif k == UI_TABLE:
                self._paint_table(canvas, p.node, p.rect, focused)
            elif k == UI_LIST:
                self._paint_list(canvas, p.node, p.rect, focused)
            elif k == UI_PREVIEW:
                _paint_preview(canvas, painter, p.rect)
            elif k == UI_TABS:
                self._paint_tabs(canvas, p.node, p.rect, focused)
        # Open pop-ups overlay the rest.
        if popup >= 0:
            self._drops[popup].paint_popup(canvas, popup_rect, screen)
        if self._file_dialog.active:
            self._file_dialog.paint(canvas, screen)

    def _paint_table(mut self, mut canvas: Canvas, n: UINode, r: Rect, focused: Bool):
        var widths = _column_widths(n)
        var painter = Painter(r)
        # Header row.
        var x = r.a.x + 1
        for c in range(len(n.options)):
            var w = widths[c] if c < len(widths) else 0
            _ = painter.put_text(
                canvas, Point(x, r.a.y),
                _fit(n.options[c], w) if c + 1 < len(n.options) else n.options[c],
                Attr(DARK_GRAY, LIGHT_GRAY),
            )
            x += (widths[c] if c < len(widths) else 0) + 2
        var body = Rect(r.a.x, r.a.y + 1, r.b.x, r.b.y)
        var li = self._list(n)
        # Labels for the visible rows only, from the scroll offset.
        var first = self._lists[li].prepare(body, len(n.rows))
        var labels = List[String]()
        for i in range(first, min(first + body.height(), len(n.rows))):
            var line = String("")
            for c in range(len(n.rows[i])):
                var cell = n.rows[i][c]
                if n.has(UI_CHECKABLE) and c == 0:
                    cell = String("[x]") if cell == String("1") else String("[ ]")
                var w = widths[c] if c < len(widths) else 0
                if c + 1 < len(n.rows[i]):
                    cell = _fit(cell, w)
                line += cell
                if c + 1 < len(n.rows[i]):
                    line += String(" ") * (max(0, w - display_columns(cell)) + 2)
            labels.append(line^)
        self._lists[li].paint_rows(canvas, body, labels, focused, Attr(BLACK, CYAN))

    def _paint_list(mut self, mut canvas: Canvas, n: UINode, r: Rect, focused: Bool):
        var li = self._vlist(n)
        var code = n.has(UI_CODE)
        var body_attr = Attr(SYN_IDENT, EDITOR_BG) if code else Attr(BLACK, CYAN)
        if code and n.number != self._list_marks[li]:
            # A new line to show: put it at the golden-ratio line.
            self._list_marks[li] = n.number
            self._lists[li].scroll_to(n.number - r.height() * 38 // 100)
        var first = self._lists[li].prepare(r, n.count)
        # The primary text's column: as wide as the widest in the window,
        # but leaving room for the detail.
        var w0 = 0
        if not code:
            for i in range(len(n.rows)):
                if len(n.rows[i]) > 0:
                    w0 = max(w0, display_columns(n.rows[i][0]))
            w0 = min(w0, max(r.width() // 2, 20))
        var labels = List[String]()
        var end = min(first + r.height(), n.count)
        for i in range(first, end):
            var j = i - n.first
            if j < 0 or j >= len(n.rows):
                labels.append(String(""))
                continue
            labels.append(_list_label(n.rows[j], w0, code))
        self._lists[li].paint_rows(canvas, r, labels, focused, body_attr)
        # Recolor on top: the marked line, the details, the spans.
        var clip = r
        if ScrollBarArea.overflows(r, n.count):
            clip = Rect(r.a.x, r.a.y, r.b.x - 1, r.b.y)
        var painter = Painter(clip)
        for i in range(first, end):
            var j = i - n.first
            if j < 0 or j >= len(n.rows):
                continue
            var y = r.a.y + (i - first)
            var sel = not code and self._lists[li].is_selected(i)
            var row_attr = body_attr
            if sel:
                row_attr = Attr(WHITE, BLUE) if focused else Attr(BLACK, GREEN)
            elif code and i == n.number:
                row_attr = Attr(BLACK, CYAN)
                painter.fill(canvas, Rect(r.a.x, y, r.b.x, y + 1), String(" "), row_attr)
                _ = painter.put_text(canvas, Point(r.a.x + 1, y), labels[i - first], row_attr)
            ref cells = n.rows[j]
            if not code and len(cells) > 1 and not sel:
                _ = painter.put_text(
                    canvas, Point(r.a.x + 1 + w0 + 2, y), cells[1],
                    Attr(DARK_GRAY, CYAN),
                )
            for s in range(len(n.spans)):
                ref sp = n.spans[s]
                if sp.row != i or sp.col >= len(cells) or sp.col > 1:
                    continue
                var text = cells[sp.col]
                var b = text.as_bytes()
                var a = max(0, min(sp.start, len(b)))
                var e = max(a, min(sp.end, len(b)))
                if e <= a:
                    continue
                var cell_x = r.a.x + 1 + (0 if sp.col == 0 else w0 + 2)
                var x = cell_x + _code_columns(String(StringSpan(unsafe_from_utf8=b[:a])))
                if sp.col == 0 and not code and x >= cell_x + w0:
                    continue
                var attr = row_attr
                if sp.fg >= UI_RGB:
                    attr = attr.with_fg_rgb(UInt32(sp.fg & 0xFFFFFF))
                elif sp.fg >= 0 and not sel:
                    attr = attr.with_fg(UInt8(sp.fg))
                if sp.bg >= UI_RGB:
                    attr = attr.with_bg_rgb(UInt32(sp.bg & 0xFFFFFF))
                elif sp.bg >= 0:
                    attr = attr.with_bg(UInt8(sp.bg))
                var piece = String(StringSpan(unsafe_from_utf8=b[a:e])).replace(
                    String("\t"), String("    "),
                )
                if sp.col == 0 and not code:
                    piece = truncate_to_columns(piece, max(0, cell_x + w0 - x))
                _ = painter.put_text(canvas, Point(x, y), piece, attr)

    def _list_nav(mut self, n: UINode, event: Event, page: Int, mut out: List[UIEvent]):
        """Up / Down / Page / Home / End on list ``n``: report the new
        selection (with Shift on a ``UI_MULTI`` list, the range)."""
        var li = self._vlist(n)
        var before_sel = self._lists[li].selected
        var before_anchor = self._lists[li].anchor()
        var ev = event
        if not n.has(UI_MULTI):
            ev.mods = ev.mods & ~MOD_SHIFT
        _ = self._lists[li].handle_nav_key(ev, n.count, page)
        self._report_selection(n, li, before_sel, before_anchor, out)

    def _report_selection(
        self, n: UINode, li: Int, before_sel: Int, before_anchor: Int,
        mut out: List[UIEvent],
    ):
        var sel = self._lists[li].selected
        var anchor = self._lists[li].anchor()
        if sel == before_sel and (not n.has(UI_MULTI) or anchor == before_anchor):
            return
        if n.has(UI_MULTI) and anchor >= 0 and anchor != sel:
            out.append(ui_set(n.key, String(anchor) + String(":") + String(sel)))
        else:
            out.append(ui_set(n.key, String(sel)))

    def _nav_list(self) -> Int:
        """The placed list a ``UI_NAV`` field drives: the first one that
        isn't a code view."""
        for i in range(len(self._placed)):
            ref n = self._placed[i].node
            if n.kind == UI_LIST and not n.has(UI_CODE):
                return i
        return -1

    def _tab_spans(self, n: UINode, r: Rect) -> List[Tuple[Int, Int]]:
        var out = List[Tuple[Int, Int]]()
        var x = r.a.x
        for i in range(len(n.children)):
            var w = display_columns(n.children[i].text) + 2
            out.append((x, x + w))
            x += w + 1
        return out^

    def _paint_tabs(self, mut canvas: Canvas, n: UINode, r: Rect, focused: Bool):
        var painter = Painter(r)
        var spans = self._tab_spans(n, r)
        for i in range(len(n.children)):
            var attr = Attr(BLACK, LIGHT_GRAY)
            if i == n.number:
                attr = Attr(BLACK, GREEN) if focused else Attr(WHITE, BLUE)
            _ = painter.put_text(
                canvas, Point(spans[i][0], r.a.y),
                String(" ") + n.children[i].text + String(" "), attr,
            )

    # --- input ---------------------------------------------------------

    def _focusables(self) -> List[String]:
        var out = List[String]()
        for i in range(len(self._placed)):
            if _is_focusable(self._placed[i].node):
                out.append(self._placed[i].node.key)
        return out^

    def _focused(self) -> Int:
        for i in range(len(self._placed)):
            if self._placed[i].node.key == self.focus_key \
                    and _is_focusable(self._placed[i].node):
                return i
        return -1

    def _cycle(mut self, backward: Bool):
        self._close_drop()
        var keys = self._focusables()
        if len(keys) == 0:
            return
        var at = 0
        for i in range(len(keys)):
            if keys[i] == self.focus_key:
                at = i
        at = (at + len(keys) - 1) % len(keys) if backward else (at + 1) % len(keys)
        self.focus_key = keys[at]

    def _close_drop(mut self):
        for i in range(len(self._drops)):
            self._drops[i].close()

    def _default_action(self) -> String:
        for i in range(len(self._placed)):
            ref n = self._placed[i].node
            if n.kind == UI_BUTTON and n.has(UI_DEFAULT) and n.enabled():
                return n.key
        return String("")

    def handle_event(
        mut self, root: UINode, event: Event, screen: Rect,
    ) -> List[UIEvent]:
        """Route ``event`` and report what it did. Every event is the
        dialog's while it's open (modal)."""
        self._layout(root, screen)
        var out = List[UIEvent]()
        if self._file_dialog.active:
            # Browse's file dialog is modal over the form.
            if event.kind == EVENT_KEY:
                _ = self._file_dialog.handle_key(event)
            elif event.kind == EVENT_MOUSE:
                _ = self._file_dialog.handle_mouse(event, screen)
            if self._file_dialog.submitted:
                out.append(ui_set(self._browse_key, self._file_dialog.selected_path))
                self.focus_key = self._browse_key
                self._file_dialog.close()
            return out^
        # Where each list's view starts, to report the ones that move.
        var tops = List[Int]()
        for i in range(len(self._lists)):
            tops.append(self._lists[i].scroll())
        if event.kind == EVENT_KEY:
            self._key(event, out)
        elif event.kind == EVENT_MOUSE:
            self._mouse(event, out)
        for i in range(min(len(tops), len(self._lists))):
            if self._lists[i].scroll() != tops[i]:
                out.append(ui_set(
                    self._list_keys[i] + String("@top"), String(self._lists[i].scroll()),
                ))
        # A Browse button is the grid's own business: open the file dialog
        # at the field's directory.
        var kept = List[UIEvent]()
        for i in range(len(out)):
            if out[i].is_action and out[i].key.startswith(_BROWSE_PREFIX):
                var key = String(StringSpan(
                    unsafe_from_utf8=out[i].key.as_bytes()[len(String(_BROWSE_PREFIX).as_bytes()):]
                ))
                var seed = String("")
                for j in range(len(self._placed)):
                    if self._placed[j].node.key == key:
                        seed = self._placed[j].node.value
                self._browse_key = key
                self._file_dialog.open(_browse_seed(seed))
            else:
                kept.append(out[i].copy())
        return kept^

    def _key(mut self, event: Event, mut out: List[UIEvent]):
        var k = event.key
        var fi = self._focused()
        # An open pop-up takes the keys first.
        for i in range(len(self._drops)):
            if self._drops[i].is_open:
                if k == KEY_ESC:
                    self._drops[i].close()
                    return
                var before = self._drops[i].index
                _ = self._drops[i].handle_key(event)
                if self._drops[i].index != before or not self._drops[i].is_open:
                    out.append(ui_set(self._drop_keys[i], String(self._drops[i].index)))
                return
        if k == KEY_ESC:
            out.append(ui_act(self._cancel))
            return
        if k == KEY_TAB:
            self._cycle((event.mods & MOD_SHIFT) != 0)
            return
        if fi < 0:
            if k == KEY_ENTER:
                var d = self._default_action()
                if len(d.as_bytes()) > 0:
                    out.append(ui_act(d))
            return
        var n = self._placed[fi].node.copy()
        var kind = n.kind
        # One-key answers (Cancel / Delete / Save) outside text fields.
        if kind != UI_TEXT and (event.mods & (MOD_CTRL | MOD_META | MOD_ALT)) == 0 \
                and k >= 0x21 and k < 0x7F:
            var ch = k | 0x20 if k >= 0x41 and k <= 0x5A else k
            for i in range(len(self._placed)):
                ref b = self._placed[i].node
                if b.kind == UI_BUTTON and b.has(UI_HOTKEY) and b.enabled():
                    var bb = b.text.as_bytes()
                    if len(bb) > 0:
                        var first = UInt32(bb[0])
                        if first >= 0x41 and first <= 0x5A:
                            first |= 0x20
                        if first == ch:
                            out.append(ui_act(b.key))
                            return
        if kind == UI_TEXT and n.has(UI_NAV):
            var target = self._nav_list()
            if target >= 0:
                var ln = self._placed[target].node.copy()
                if k == KEY_UP or k == KEY_DOWN or k == KEY_PAGEUP \
                        or k == KEY_PAGEDOWN:
                    var page = max(self._placed[target].rect.height() - 1, 1)
                    self._list_nav(ln, event, page, out)
                    return
                if k == KEY_ENTER and len(ln.value.as_bytes()) > 0:
                    out.append(ui_act(ln.value))
                    return
        if kind == UI_TEXT:
            if k == KEY_ENTER:
                var d = self._default_action()
                if len(d.as_bytes()) > 0:
                    out.append(ui_act(d))
                return
            var i = self._field(n)
            var before = self._fields[i].text
            _ = self._fields[i].handle_key(event)
            if self._fields[i].text != before:
                out.append(ui_set(n.key, self._fields[i].text))
            return
        if kind == UI_CHECK:
            if k == KEY_SPACE or k == KEY_ENTER:
                out.append(ui_set(n.key, String("0") if n.number != 0 else String("1")))
            return
        if kind == UI_CHOICE:
            var i = self._drop(n)
            if k == KEY_ENTER or k == KEY_SPACE:
                self._drops[i].toggle()
                return
            var before = self._drops[i].index
            _ = self._drops[i].handle_key(event)
            if self._drops[i].index != before:
                out.append(ui_set(n.key, String(self._drops[i].index)))
            return
        if kind == UI_BUTTON:
            if k == KEY_ENTER or k == KEY_SPACE:
                out.append(ui_act(n.key))
            elif k == KEY_LEFT or k == KEY_RIGHT:
                self._cycle(k == KEY_LEFT)
            return
        if kind == UI_TABS:
            if k == KEY_LEFT and n.number > 0:
                out.append(ui_set(n.key, String(n.number - 1)))
            elif k == KEY_RIGHT and n.number + 1 < len(n.children):
                out.append(ui_set(n.key, String(n.number + 1)))
            return
        if kind == UI_LIST:
            if k == KEY_ENTER:
                if len(n.value.as_bytes()) > 0:
                    out.append(ui_act(n.value))
                return
            var page = max(self._placed[fi].rect.height() - 1, 1)
            self._list_nav(n, event, page, out)
            return
        if kind == UI_TABLE:
            if k == KEY_ENTER:
                if len(n.value.as_bytes()) > 0:
                    out.append(ui_act(n.value))
                else:
                    var d = self._default_action()
                    if len(d.as_bytes()) > 0:
                        out.append(ui_act(d))
                return
            if k == KEY_SPACE and n.has(UI_CHECKABLE):
                if n.number >= 0:
                    out.append(ui_act(String("toggle:") + String(n.number)))
                return
            if is_type_ahead_key(event) and k != KEY_SPACE:
                # Type-to-jump on the row's first text column.
                var labels = List[String]()
                var col = 1 if n.has(UI_CHECKABLE) else 0
                for r in range(len(n.rows)):
                    labels.append(n.rows[r][col] if col < len(n.rows[r]) else String(""))
                var hit = type_ahead_pick(
                    self._type_ahead, labels, String(chr(Int(k))),
                )
                if hit >= 0 and hit != n.number:
                    out.append(ui_set(n.key, String(hit)))
                return
            var i = self._list(n)
            var page = max(self._placed[fi].rect.height() - 2, 1)
            _ = self._lists[i].handle_nav_key(event, len(n.rows), page)
            if self._lists[i].selected != n.number:
                out.append(ui_set(n.key, String(self._lists[i].selected)))
            return

    def _mouse(mut self, event: Event, mut out: List[UIEvent]):
        if close_button_clicked(self._frame, event):
            out.append(ui_act(self._cancel))
            return
        # Buttons track their own press → release.
        for i in range(len(self._placed)):
            var p = self._placed[i].copy()
            if p.node.kind != UI_BUTTON or not p.node.enabled():
                continue
            var bi = self._button(p.node, p.rect)
            if self._buttons[bi].handle_mouse(event) == BUTTON_FIRED:
                self.focus_key = p.node.key
                out.append(ui_act(p.node.key))
                return
        # An open pop-up overlays everything.
        for i in range(len(self._placed)):
            var p = self._placed[i].copy()
            if p.node.kind != UI_CHOICE:
                continue
            var di = self._drop(p.node)
            if not self._drops[di].is_open:
                continue
            var before = self._drops[di].index
            var hit = self._drops[di].handle_mouse(p.rect, self._screen, event)
            if self._drops[di].index != before:
                out.append(ui_set(p.node.key, String(self._drops[di].index)))
            if hit == DROPDOWN_HIT_POPUP or hit == DROPDOWN_HIT_BODY:
                return
        # A scroll-bar drag takes every event up to the release.
        for i in range(len(self._placed)):
            var p = self._placed[i].copy()
            if p.node.kind != UI_LIST:
                continue
            var li = self._vlist(p.node)
            if self._lists[li].scrolling():
                _ = self._lists[li].handle_mouse_drag(event, p.rect, p.node.count)
                return
        # A drag continues in the field it started in.
        var fi = self._focused()
        if event.motion and fi >= 0 and self._placed[fi].node.kind == UI_TEXT:
            var fp = self._placed[fi].copy()
            var i = self._field(fp.node)
            _ = self._fields[i].handle_mouse(event, fp.rect)
            return
        var press = event.button == MOUSE_BUTTON_LEFT and event.pressed and not event.motion
        for i in range(len(self._placed) - 1, -1, -1):
            var p = self._placed[i].copy()
            if not p.rect.contains(event.pos) or not p.node.enabled():
                continue
            var kind = p.node.kind
            if kind == UI_LIST:
                var li = self._vlist(p.node)
                var code = p.node.has(UI_CODE)
                if press and not code:
                    self.focus_key = p.node.key
                var before_sel = self._lists[li].selected
                var before_anchor = self._lists[li].anchor()
                if self._lists[li].handle_mouse_press(event, p.rect, p.node.count):
                    if code:
                        # A code view only scrolls.
                        self._lists[li].set_selected(-1)
                        return
                    self._report_selection(p.node, li, before_sel, before_anchor, out)
                    if press and event.click_count >= 2 \
                            and len(p.node.value.as_bytes()) > 0:
                        out.append(ui_act(p.node.value))
                return
            if kind == UI_TABLE:
                # Wheel or click: the list scrolls / selects itself.
                var body = Rect(p.rect.a.x, p.rect.a.y + 1, p.rect.b.x, p.rect.b.y)
                var li = self._list(p.node)
                if press:
                    self.focus_key = p.node.key
                if self._lists[li].handle_mouse_press(event, body, len(p.node.rows)):
                    var sel = self._lists[li].selected
                    if sel != p.node.number:
                        out.append(ui_set(p.node.key, String(sel)))
                    if press and p.node.has(UI_CHECKABLE) and sel >= 0 \
                            and event.pos.x < body.a.x + 5:
                        out.append(ui_act(String("toggle:") + String(sel)))
                    elif press and event.click_count >= 2 \
                            and len(p.node.value.as_bytes()) > 0:
                        out.append(ui_act(p.node.value))
                return
            if not press:
                continue
            if kind == UI_TEXT:
                self.focus_key = p.node.key
                var fx = self._field(p.node)
                _ = self._fields[fx].handle_mouse(event, p.rect)
                return
            if kind == UI_CHECK:
                self.focus_key = p.node.key
                out.append(ui_set(p.node.key, String("0") if p.node.number != 0 else String("1")))
                return
            if kind == UI_CHOICE:
                self.focus_key = p.node.key
                var di = self._drop(p.node)
                _ = self._drops[di].handle_mouse(p.rect, self._screen, event)
                return
            if kind == UI_TABS:
                self.focus_key = p.node.key
                var spans = self._tab_spans(p.node, p.rect)
                for t in range(len(spans)):
                    if event.pos.x >= spans[t][0] and event.pos.x < spans[t][1]:
                        if t != p.node.number:
                            out.append(ui_set(p.node.key, String(t)))
                return
            return


def _code_columns(text: String) -> Int:
    """Cells ``text`` takes in a list row, tabs drawn as four spaces."""
    return display_columns(text.replace(String("\t"), String("    ")))


def _list_label(cells: List[String], w0: Int, code: Bool) -> String:
    """A list row as plain text: the primary cell (cut to ``w0`` columns)
    and the detail two columns after it; a code line as is."""
    if len(cells) == 0:
        return String("")
    var primary = cells[0].replace(String("\t"), String("    "))
    if code or len(cells) < 2:
        return primary^
    var p = _fit(primary, w0)
    return p + String(" ") * (max(0, w0 - display_columns(p)) + 2) + cells[1]


def _preview_lines() -> List[List[Tuple[String, UInt8]]]:
    """The sample code a preview shows — the same lines as the native one
    (``CodePreview`` in TurboKod.swift), as (text, palette slot) runs."""
    var fg = EDITOR_FG
    return [
        [(String("# A taste of your editor"), SYN_COMMENT)],
        [(String("@"), SYN_DECORATOR), (String("dataclass"), SYN_DECORATOR)],
        [(String("class"), SYN_KEYWORD), (String(" "), fg), (String("Point"), SYN_IDENT),
         (String(":"), SYN_OPERATOR)],
        [(String("    x"), fg), (String(":"), SYN_OPERATOR), (String(" "), fg),
         (String("int"), SYN_KEYWORD), (String(" = "), SYN_OPERATOR), (String("0"), SYN_NUMBER)],
        [(String(""), fg)],
        [(String("def"), SYN_KEYWORD), (String(" "), fg), (String("greet"), SYN_IDENT),
         (String("("), SYN_OPERATOR), (String("name"), fg), (String(")"), SYN_OPERATOR),
         (String(":"), SYN_OPERATOR)],
        [(String("    count"), fg), (String(" = "), SYN_OPERATOR), (String("42"), SYN_NUMBER)],
        [(String("    return"), SYN_KEYWORD), (String(" "), fg),
         (String('f"Hello, {name}!"'), SYN_STRING)],
    ]


def _paint_preview(mut canvas: Canvas, painter: Painter, r: Rect):
    """Sample code in palette slots, so it retints with the live theme."""
    painter.fill(canvas, r, String(" "), Attr(EDITOR_FG, EDITOR_BG))
    var lines = _preview_lines()
    for y in range(min(len(lines), r.height())):
        var x = r.a.x + 1
        for i in range(len(lines[y])):
            x += painter.put_text(
                canvas, Point(x, r.a.y + y), lines[y][i][0],
                Attr(lines[y][i][1], EDITOR_BG),
            )


def _sep_cell() -> Cell:
    return Cell(String("─"), Attr(DARK_GRAY, LIGHT_GRAY), 1)

