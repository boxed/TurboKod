"""Declarative UI: one description of a dialog, two projections.

A dialog describes itself as a tree of ``UINode``s — stacks, form rows,
labels, text fields, checkboxes, choices, tables, buttons — built fresh
from its state each frame (``ui()``). Two projectors turn the same tree
into a UI:

* the grid projector (``ui_grid.GridForm``) lays it out in cells and runs
  focus, keys and mouse with the existing widgets — the terminal and the
  classic look;
* the native projector (``TurboKod.swift``, ``DeclarativeController``)
  builds AppKit views from ``ui_to_json`` — the macOS-style UI.

Both report what the user did the same way: ``set(key, value)`` for an
edit and ``act(id)`` for a button, which the dialog applies through its
``ui_set`` / ``ui_act`` — the only code that touches its state. Values
cross as strings: a checkbox is ``"1"`` / ``"0"``, a choice or a table
selection its index.

Kept free of widgets and the canvas, so a dialog module can build its tree
without pulling in either projector.
"""

from std.collections.list import List

from .json import (
    JsonValue, json_array, json_int, json_object, json_str,
)


# --- node kinds ---------------------------------------------------------------

comptime UI_DIALOG    = 1
"""Root: ``text`` is the title, ``key`` the action Esc / the close box run;
one child, the body."""
comptime UI_VSTACK    = 2
comptime UI_HSTACK    = 3
comptime UI_FORM      = 4
"""Rows of ``UI_ROW``: labels right-aligned in one column, controls in the
next; ``number`` blank rows between rows (where there's room)."""
comptime UI_ROW       = 5
"""One form row: ``text`` is the label, the one child the control."""
comptime UI_TABS      = 6
"""``key`` binds the selected page index (``number``); each child is a
page whose ``text`` is its tab label."""
comptime UI_LABEL     = 7
comptime UI_TEXT      = 8
"""Single-line text field bound to ``key``; ``value`` is its text;
``number``, when set, the characters it's sized for (it doesn't stretch)."""
comptime UI_CHECK     = 9
comptime UI_CHOICE    = 10
"""Pop-up choice bound to ``key``: ``options``, selected ``number``."""
comptime UI_TABLE     = 11
"""Rows of cells (``rows``) under ``options`` as column titles; ``key``
binds the selected row (``number``); ``value`` is the action a double-click
/ Return runs (may be empty); ``height`` the rows it wants to show."""
comptime UI_BUTTON    = 12
"""``key`` is the action it runs; ``text`` its label."""
comptime UI_SEPARATOR = 13
comptime UI_SPACER    = 14
"""Takes the spare height of a ``UI_VSTACK``."""
comptime UI_PREVIEW   = 15
"""A few lines of sample code in the live theme's editor colors: ``text``
is the font label, ``number`` the font size (0 = its default), ``options``
the built-in font labels, ``value`` a token that changes whenever the
palette does (so a projector knows to repaint)."""
comptime UI_LIST      = 16
"""A list too long to send whole (Quick Open's files, a file's lines):
``count`` rows in all, of which ``rows`` holds the ones from ``first`` on —
the window around what's on screen. Each projector reports where its view
is with ``set("<key>@top", row)``, and the dialog sends the rows around it
next frame (``ListWindow``). Row cells are a primary text and an optional
detail (drawn de-emphasized); ``spans`` color byte ranges of a cell. ``key``
binds the selected row (``number``; ``"<anchor>:<row>"`` for a range with
``UI_MULTI``); ``value`` is the action double-click / Return runs.
With ``UI_CODE`` it's a code view: monospace on the editor colors, no
selection, ``number`` the line to mark and reveal."""


# --- flags --------------------------------------------------------------------

comptime UI_DISABLED    = 1 << 0
comptime UI_DEFAULT     = 1 << 1
"""Button: what Return runs when focus is on a text field (and it's drawn
as the default)."""
comptime UI_CANCEL      = 1 << 2
"""Button: answers Esc (the dialog's cancel action is the same id)."""
comptime UI_DESTRUCTIVE = 1 << 3
comptime UI_CENTER      = 1 << 4
"""Stack: center its children (a button row)."""
comptime UI_SECONDARY   = 1 << 5
"""Label: de-emphasized (hints, notes)."""
comptime UI_HEADING     = 1 << 6
"""Label: a section heading."""
comptime UI_HOTKEY      = 1 << 7
"""Button: its label's first letter presses it while focus isn't in a text
field (the confirm dialogs' one-key answers)."""
comptime UI_CHECKABLE   = 1 << 8
"""Table: the first cell of each row is "1" / "0" and shows as a checkbox;
Space or a click on it runs ``toggle:<row>``."""
comptime UI_BROWSE      = 1 << 9
"""Text: a file path, with a Browse button beside it that picks one (the
grid's file dialog, natively an open panel) and sets the field."""
comptime UI_NAV         = 1 << 10
"""Text: the search field of the dialog's list — Up / Down / Page Up /
Page Down move the list's selection and Return runs its action, while the
typing stays in the field (a picker)."""
comptime UI_MULTI       = 1 << 11
"""List: Shift extends the selection into a range."""
comptime UI_CODE        = 1 << 12
"""List: a code view (see ``UI_LIST``)."""
comptime UI_LARGE       = 1 << 13
"""Dialog: takes most of the window instead of its natural size (a
picker, whose list should show as many rows as fit)."""


@fieldwise_init
struct UISpan(ImplicitlyCopyable, Movable):
    """A colored byte range ``[start, end)`` of cell ``col`` of list row
    ``row`` (absolute). ``fg`` / ``bg``: -1 for none, a palette index
    (0..255, so it follows the theme), or ``UI_RGB | 0xRRGGBB``."""
    var row: Int
    var col: Int
    var start: Int
    var end: Int
    var fg: Int
    var bg: Int


comptime UI_RGB = 1 << 24
"""``UISpan`` color tag: the low 24 bits are an RGB value."""


struct UINode(Copyable, Movable, Deinitable):
    var kind: Int
    var key: String
    var text: String
    var value: String
    var placeholder: String
    var options: List[String]
    var rows: List[List[String]]
    var number: Int
    var height: Int
    var flags: Int
    var children: List[UINode]
    var count: Int
    var first: Int
    var spans: List[UISpan]

    def __init__(out self, kind: Int):
        self.kind = kind
        self.key = String("")
        self.text = String("")
        self.value = String("")
        self.placeholder = String("")
        self.options = List[String]()
        self.rows = List[List[String]]()
        self.number = 0
        self.height = 0
        self.flags = 0
        self.children = List[UINode]()
        self.count = 0
        self.first = 0
        self.spans = List[UISpan]()

    def __deinit__(deinit self):
        # Deliberately empty — the recursive ``List[UINode]`` field needs an
        # explicit ``__deinit__`` to break the conformance cycle (see the same
        # note on ``JsonValue``). Fields are still destroyed afterwards.
        pass

    def __copyinit__(mut self, copy: Self):
        self.kind = copy.kind
        self.key = copy.key
        self.text = copy.text
        self.value = copy.value
        self.placeholder = copy.placeholder
        self.options = copy.options.copy()
        self.rows = copy.rows.copy()
        self.number = copy.number
        self.height = copy.height
        self.flags = copy.flags
        self.children = copy.children.copy()
        self.count = copy.count
        self.first = copy.first
        self.spans = copy.spans.copy()

    def has(self, flag: Int) -> Bool:
        return (self.flags & flag) != 0

    def enabled(self) -> Bool:
        return not self.has(UI_DISABLED)


# --- builders -----------------------------------------------------------------


def ui_dialog(var title: String, var cancel: String, var body: UINode) -> UINode:
    var n = UINode(UI_DIALOG)
    n.text = title^
    n.key = cancel^
    n.children.append(body^)
    return n^


def ui_vstack(var children: List[UINode], spacing: Int = 1) -> UINode:
    var n = UINode(UI_VSTACK)
    n.children = children^
    n.number = spacing
    return n^


def ui_hstack(
    var children: List[UINode], spacing: Int = 2, center: Bool = False,
) -> UINode:
    var n = UINode(UI_HSTACK)
    n.children = children^
    n.number = spacing
    if center:
        n.flags |= UI_CENTER
    return n^


def ui_buttons(var children: List[UINode]) -> UINode:
    """The dialog's button row: centered, the usual gap."""
    return ui_hstack(children^, 2, True)


def ui_form(var rows: List[UINode], spacing: Int = 1) -> UINode:
    var n = UINode(UI_FORM)
    n.children = rows^
    n.number = spacing
    return n^


def ui_row(var label: String, var control: UINode) -> UINode:
    var n = UINode(UI_ROW)
    n.text = label^
    n.children.append(control^)
    return n^


def ui_tabs(var key: String, selected: Int, var pages: List[UINode]) -> UINode:
    var n = UINode(UI_TABS)
    n.key = key^
    n.number = selected
    n.children = pages^
    return n^


def ui_page(var label: String, var body: UINode) -> UINode:
    var n = UINode(UI_VSTACK)
    n.text = label^
    n.children.append(body^)
    n.number = 0
    return n^


def ui_label(var text: String, flags: Int = 0) -> UINode:
    var n = UINode(UI_LABEL)
    n.text = text^
    n.flags = flags
    return n^


def ui_text(
    var key: String, var value: String,
    var placeholder: String = String(""), enabled: Bool = True,
    width: Int = 0,
) -> UINode:
    var n = UINode(UI_TEXT)
    n.key = key^
    n.value = value^
    n.placeholder = placeholder^
    n.number = width
    if not enabled:
        n.flags |= UI_DISABLED
    return n^


def ui_path(
    var key: String, var value: String,
    var placeholder: String = String(""), enabled: Bool = True,
) -> UINode:
    """A text field for a file path, with a Browse button."""
    var n = ui_text(key^, value^, placeholder^, enabled)
    n.flags |= UI_BROWSE
    return n^


def ui_check(
    var key: String, var label: String, on: Bool, enabled: Bool = True,
) -> UINode:
    var n = UINode(UI_CHECK)
    n.key = key^
    n.text = label^
    n.number = 1 if on else 0
    if not enabled:
        n.flags |= UI_DISABLED
    return n^


def ui_choice(
    var key: String, var options: List[String], selected: Int,
    enabled: Bool = True,
) -> UINode:
    var n = UINode(UI_CHOICE)
    n.key = key^
    n.options = options^
    n.number = selected
    if not enabled:
        n.flags |= UI_DISABLED
    return n^


def ui_table(
    var key: String, var columns: List[String], var rows: List[List[String]],
    selected: Int, var activate: String = String(""), height: Int = 8,
    checkable: Bool = False,
) -> UINode:
    var n = UINode(UI_TABLE)
    n.key = key^
    n.options = columns^
    n.rows = rows^
    n.number = selected
    n.value = activate^
    n.height = height
    if checkable:
        n.flags |= UI_CHECKABLE
    return n^


def ui_list(
    var key: String, count: Int, first: Int, var rows: List[List[String]],
    var selected: String, var activate: String = String(""), height: Int = 8,
    flags: Int = 0, var spans: List[UISpan] = List[UISpan](),
) -> UINode:
    """See ``UI_LIST``. ``selected`` is the row index as text, or
    ``"<anchor>:<row>"`` for a ``UI_MULTI`` range."""
    var n = UINode(UI_LIST)
    n.key = key^
    n.count = count
    n.first = first
    n.rows = rows^
    n.text = selected^
    n.number = ui_list_row(n.text)
    n.value = activate^
    n.height = height
    n.flags = flags
    n.spans = spans^
    return n^


def ui_list_row(selected: String) -> Int:
    """The row a list's selection value names (its moving end)."""
    var b = selected.as_bytes()
    for i in range(len(b)):
        if b[i] == 0x3A:
            return ui_int(String(StringSpan(unsafe_from_utf8=b[i + 1:])))
    return ui_int(selected)


def ui_list_anchor(selected: String) -> Int:
    """The fixed end of a list's selection range (its row when single)."""
    var b = selected.as_bytes()
    for i in range(len(b)):
        if b[i] == 0x3A:
            return ui_int(String(StringSpan(unsafe_from_utf8=b[:i])))
    return ui_int(selected)


struct ListWindow(Copyable, Movable):
    """The dialog's half of a ``UI_LIST``: which rows to send. It follows
    the projector's view (``<key>@top``) and the selection, keeping
    ``size`` rows around them so a scroll within that needs no round
    trip."""
    var top: Int
    var size: Int

    def __init__(out self, size: Int = 200):
        self.top = 0
        self.size = size

    def reset(mut self):
        self.top = 0

    def view_at(mut self, row: Int):
        """The projector's view now starts at ``row``."""
        self.top = max(row, 0)

    def range(self, count: Int, selected: Int) -> Tuple[Int, Int]:
        """``[first, end)`` to send: centered on the view, moved to cover
        the selection when it's out of it (the view is about to follow)."""
        var at = self.top
        if selected >= 0 and (selected < at or selected >= at + self.size // 2):
            at = selected
        var first = max(0, min(at - self.size // 4, count - self.size))
        return (first, min(count, first + self.size))


def ui_button(var key: String, var label: String, flags: Int = 0) -> UINode:
    var n = UINode(UI_BUTTON)
    n.key = key^
    n.text = label^
    n.flags = flags
    return n^


def ui_separator() -> UINode:
    return UINode(UI_SEPARATOR)


def ui_spacer() -> UINode:
    return UINode(UI_SPACER)


def ui_preview(
    var font: String, size: Int, var builtins: List[String], var version: String,
) -> UINode:
    var n = UINode(UI_PREVIEW)
    n.text = font^
    n.number = size
    n.options = builtins^
    n.value = version^
    return n^


def ui_bool(value: String) -> Bool:
    """A checkbox's ``set`` value."""
    return value == String("1")


def ui_int(value: String, default: Int = -1) -> Int:
    """A choice / table / tabs ``set`` value."""
    try:
        return Int(value)
    except:
        return default


# --- JSON (the native projector's input) ---------------------------------------


def _kind_name(kind: Int) -> String:
    if kind == UI_DIALOG: return String("dialog")
    if kind == UI_VSTACK: return String("vstack")
    if kind == UI_HSTACK: return String("hstack")
    if kind == UI_FORM: return String("form")
    if kind == UI_ROW: return String("row")
    if kind == UI_TABS: return String("tabs")
    if kind == UI_LABEL: return String("label")
    if kind == UI_TEXT: return String("text")
    if kind == UI_CHECK: return String("check")
    if kind == UI_CHOICE: return String("choice")
    if kind == UI_TABLE: return String("table")
    if kind == UI_BUTTON: return String("button")
    if kind == UI_SEPARATOR: return String("separator")
    if kind == UI_PREVIEW: return String("preview")
    if kind == UI_LIST: return String("list")
    return String("spacer")


def ui_to_json(node: UINode) -> JsonValue:
    """``{k, key, text, value, ph, opts, rows, n, h, f, kids}`` (a list
    adds ``count``, ``first`` and ``spans``) — empty
    fields are left out to keep the per-frame payload small."""
    var o = json_object()
    o.put(String("k"), json_str(_kind_name(node.kind)))
    if len(node.key.as_bytes()) > 0:
        o.put(String("key"), json_str(node.key))
    if len(node.text.as_bytes()) > 0:
        o.put(String("text"), json_str(node.text))
    if len(node.value.as_bytes()) > 0:
        o.put(String("value"), json_str(node.value))
    if len(node.placeholder.as_bytes()) > 0:
        o.put(String("ph"), json_str(node.placeholder))
    if len(node.options) > 0:
        var a = json_array()
        for i in range(len(node.options)):
            a.append(json_str(node.options[i]))
        o.put(String("opts"), a)
    if len(node.rows) > 0:
        var rs = json_array()
        for i in range(len(node.rows)):
            var r = json_array()
            for j in range(len(node.rows[i])):
                r.append(json_str(node.rows[i][j]))
            rs.append(r)
        o.put(String("rows"), rs)
    if node.number != 0:
        o.put(String("n"), json_int(node.number))
    if node.height != 0:
        o.put(String("h"), json_int(node.height))
    if node.flags != 0:
        o.put(String("f"), json_int(node.flags))
    if node.kind == UI_LIST:
        o.put(String("count"), json_int(node.count))
        o.put(String("first"), json_int(node.first))
        if len(node.spans) > 0:
            var sp = json_array()
            for i in range(len(node.spans)):
                ref s = node.spans[i]
                var a = json_array()
                a.append(json_int(s.row))
                a.append(json_int(s.col))
                a.append(json_int(s.start))
                a.append(json_int(s.end))
                a.append(json_int(s.fg))
                a.append(json_int(s.bg))
                sp.append(a)
            o.put(String("spans"), sp)
    if len(node.children) > 0:
        var kids = json_array()
        for i in range(len(node.children)):
            kids.append(ui_to_json(node.children[i]))
        o.put(String("kids"), kids)
    return o^
