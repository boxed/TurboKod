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
next."""
comptime UI_ROW       = 5
"""One form row: ``text`` is the label, the one child the control."""
comptime UI_TABS      = 6
"""``key`` binds the selected page index (``number``); each child is a
page whose ``text`` is its tab label."""
comptime UI_LABEL     = 7
comptime UI_TEXT      = 8
"""Single-line text field bound to ``key``; ``value`` is its text."""
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


def ui_form(var rows: List[UINode]) -> UINode:
    var n = UINode(UI_FORM)
    n.children = rows^
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
) -> UINode:
    var n = UINode(UI_TEXT)
    n.key = key^
    n.value = value^
    n.placeholder = placeholder^
    if not enabled:
        n.flags |= UI_DISABLED
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
    return String("spacer")


def ui_to_json(node: UINode) -> JsonValue:
    """``{k, key, text, value, ph, opts, rows, n, h, f, kids}`` — empty
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
    if len(node.children) > 0:
        var kids = json_array()
        for i in range(len(node.children)):
            kids.append(ui_to_json(node.children[i]))
        o.put(String("kids"), kids)
    return o^
