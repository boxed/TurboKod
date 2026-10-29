"""Modal dialog for editing one ``LanguageServerOverride``.

Opened from Settings ▸ Languages, on top of it, to add a language or to
change the server priority of an existing one: the language id, its file
types, and the server command lines in priority order (top first). For a
built-in language (``is_existing``) the id and file types are read-only.

Plain state plus a declarative UI (``ui`` / ``ui_set`` / ``ui_act``, see
``ui_tree.mojo``); the grid and native projectors draw it.
"""

from std.collections.list import List

from .config import LanguageServerOverride
from .string_utils import split_args
from .ui_tree import (
    UI_CANCEL, UI_DEFAULT, UI_DISABLED, UI_SECONDARY, UINode, ui_button,
    ui_buttons, ui_dialog, ui_form, ui_hstack, ui_int, ui_label, ui_row,
    ui_table, ui_text, ui_vstack,
)


struct LanguageEditor(Movable):
    var active: Bool
    var submitted: Bool
    var is_existing: Bool
    """A built-in language: only the server priority is editable."""
    var language_id: String
    var file_types: String
    """Space-separated, as typed."""
    var candidates: List[String]
    """Server command lines, highest priority first."""
    var selected: Int
    var command: String
    """The selected server's command line, as typed."""
    var adding: Bool

    def __init__(out self):
        self.active = False
        self.submitted = False
        self.is_existing = False
        self.language_id = String("")
        self.file_types = String("")
        self.candidates = List[String]()
        self.selected = -1
        self.command = String("")
        self.adding = False

    def open(
        mut self, var language_id: String, file_types: List[String],
        var candidates: List[String], is_existing: Bool,
    ):
        self = LanguageEditor()
        self.active = True
        self.is_existing = is_existing
        self.adding = len(language_id.as_bytes()) == 0
        self.language_id = language_id^
        self.file_types = String(" ").join(file_types)
        self.candidates = candidates^
        self._select(0)

    def close(mut self):
        self = LanguageEditor()

    def value(self) -> LanguageServerOverride:
        """The edited record. Each command line splits the way a shell
        would (quotes keep a token together)."""
        var ov = LanguageServerOverride()
        ov.language_id = String(self.language_id.strip())
        ov.file_types = split_args(self.file_types)
        for i in range(len(self.candidates)):
            var argv = split_args(self.candidates[i])
            if len(argv) > 0:
                ov.argvs.append(argv^)
        return ov^

    def ui(self) -> UINode:
        var head = List[UINode]()
        head.append(ui_row(String("Language id"), ui_text(
            String("language_id"), self.language_id, String("python"),
            not self.is_existing,
        )))
        head.append(ui_row(String("File types"), ui_text(
            String("file_types"), self.file_types, String("py pyi"),
            not self.is_existing,
        )))
        var rows = List[List[String]]()
        for i in range(len(self.candidates)):
            rows.append([self.candidates[i]])
        var has = self.selected >= 0 and self.selected < len(self.candidates)
        var edit = List[UINode]()
        edit.append(ui_button(String("add"), String("Add")))
        edit.append(ui_button(String("remove"), String("Remove"), 0 if has else UI_DISABLED))
        edit.append(ui_button(
            String("up"), String("Move Up"), 0 if has and self.selected > 0 else UI_DISABLED,
        ))
        edit.append(ui_button(
            String("down"), String("Move Down"),
            0 if has and self.selected + 1 < len(self.candidates) else UI_DISABLED,
        ))
        var edit_row = List[UINode]()
        edit_row.append(ui_row(String("Command"), ui_text(
            String("command"), self.command, String("pyright-langserver --stdio"),
            has,
        )))
        var buttons = List[UINode]()
        buttons.append(ui_button(String("cancel"), String("Cancel"), UI_CANCEL))
        buttons.append(ui_button(String("save"), String("Save"), UI_DEFAULT))
        var body = List[UINode]()
        body.append(ui_form(head^))
        body.append(ui_label(
            String("Language servers, highest priority first:"), UI_SECONDARY,
        ))
        body.append(ui_table(
            String("servers"), [String("Command")], rows^, self.selected,
            String(""), 5,
        ))
        body.append(ui_hstack(edit^))
        body.append(ui_form(edit_row^))
        body.append(ui_buttons(buttons^))
        var title = String("Add Language") if self.adding else String("Edit Language")
        return ui_dialog(title^, String("cancel"), ui_vstack(body^))

    def ui_set(mut self, key: String, value: String):
        if key == String("language_id") and not self.is_existing:
            self.language_id = value
        elif key == String("file_types") and not self.is_existing:
            self.file_types = value
        elif key == String("command"):
            self.command = value
            if self.selected >= 0 and self.selected < len(self.candidates):
                self.candidates[self.selected] = value
        elif key == String("servers"):
            self._select(ui_int(value, self.selected))

    def ui_act(mut self, id: String):
        if id == String("save"):
            self.submitted = True
        elif id == String("cancel"):
            self.close()
        elif id == String("add"):
            # A blank row to type the new server's command into.
            self.candidates.append(String(""))
            self._select(len(self.candidates) - 1)
        elif id == String("remove"):
            if self.selected >= 0 and self.selected < len(self.candidates):
                _ = self.candidates.pop(self.selected)
                self._select(min(self.selected, len(self.candidates) - 1))
        elif id == String("up"):
            self._move(-1)
        elif id == String("down"):
            self._move(1)

    def _select(mut self, row: Int):
        """Select server ``row`` (or none) and show its command."""
        if row < 0 or row >= len(self.candidates):
            self.selected = -1
            self.command = String("")
            return
        self.selected = row
        self.command = self.candidates[row]

    def _move(mut self, delta: Int):
        var to = self.selected + delta
        if self.selected < 0 or to < 0 or to >= len(self.candidates):
            return
        self.candidates.swap_elements(self.selected, to)
        self.selected = to
