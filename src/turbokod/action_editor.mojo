"""Modal dialog for adding or editing one ``OnSaveAction``.

Opened from Project Settings ▸ On save, on top of it: a language, the
program (with Browse), its arguments and a working directory. Plain state
plus a declarative UI (``ui`` / ``ui_set`` / ``ui_act``, see
``ui_tree.mojo``); the grid and native projectors draw it.

The dialog edits a private copy — ``open`` snapshots, and the host commits
``value()`` only once it sees ``submitted``. Arguments stay one free-form
string while editing (spaces and all) and are split on Save.
"""

from std.collections.list import List

from .config import OnSaveAction
from .language_config import built_in_servers
from .string_utils import join_args, split_args
from .ui_tree import (
    UI_CANCEL, UI_DEFAULT, UI_SECONDARY, UINode, ui_button, ui_buttons,
    ui_choice, ui_dialog, ui_form, ui_int, ui_label, ui_path, ui_row, ui_text,
    ui_vstack,
)


struct ActionEditor(Movable):
    var active: Bool
    var submitted: Bool
    """Set on Save. The host reads ``value()`` then calls ``close()``."""
    var edit_index: Int
    """The host-list slot being edited, or -1 for a new action."""
    var language_id: String
    var program: String
    var args: String
    var cwd: String

    def __init__(out self):
        self.active = False
        self.submitted = False
        self.edit_index = -1
        self.language_id = String("")
        self.program = String("")
        self.args = String("")
        self.cwd = String("")

    def open(mut self, entry: OnSaveAction, edit_index: Int):
        """Begin editing ``entry`` (``edit_index`` -1 means a new one)."""
        self = ActionEditor()
        self.active = True
        self.edit_index = edit_index
        self.language_id = entry.language_id
        self.program = entry.program
        self.args = join_args(entry.args)
        self.cwd = entry.cwd

    def close(mut self):
        self = ActionEditor()

    def value(self) -> OnSaveAction:
        return OnSaveAction(
            self.language_id, self.program, split_args(self.args),
            self.cwd,
        )

    def language_options(self) -> List[String]:
        """``""`` (any file) then every LSP-known language id — plus the
        current one when the registry doesn't know it, so opening an
        action never silently changes its language."""
        var out = action_language_options()
        var known = False
        for i in range(len(out)):
            if out[i] == self.language_id:
                known = True
        if not known:
            out.append(self.language_id)
        return out^

    def ui(self) -> UINode:
        var langs = self.language_options()
        var shown = List[String]()
        var sel = 0
        for i in range(len(langs)):
            shown.append(langs[i] if len(langs[i].as_bytes()) > 0 else String("(any)"))
            if langs[i] == self.language_id:
                sel = i
        var rows = List[UINode]()
        rows.append(ui_row(String("Language"), ui_choice(String("language"), shown^, sel)))
        rows.append(ui_row(String("Program"), ui_path(String("program"), self.program)))
        var args = List[UINode]()
        args.append(ui_text(String("args"), self.args))
        args.append(ui_label(
            String("$FilePath$ expands to the saved file's path"), UI_SECONDARY,
        ))
        rows.append(ui_row(String("Arguments"), ui_vstack(args^, 0)))
        rows.append(ui_row(String("Working dir"), ui_text(
            String("cwd"), self.cwd, String("project root"),
        )))
        var buttons = List[UINode]()
        buttons.append(ui_button(String("cancel"), String("Cancel"), UI_CANCEL))
        buttons.append(ui_button(String("save"), String("Save"), UI_DEFAULT))
        var body = List[UINode]()
        body.append(ui_form(rows^))
        body.append(ui_buttons(buttons^))
        var title = String("Add On-Save Action") if self.edit_index < 0 \
            else String("Edit On-Save Action")
        return ui_dialog(title^, String("cancel"), ui_vstack(body^))

    def ui_set(mut self, key: String, value: String):
        if key == String("language"):
            var langs = self.language_options()
            var i = ui_int(value)
            if i >= 0 and i < len(langs):
                self.language_id = langs[i]
        elif key == String("program"):
            self.program = value
        elif key == String("args"):
            self.args = value
        elif key == String("cwd"):
            self.cwd = value

    def ui_act(mut self, id: String):
        if id == String("save"):
            self.submitted = True
        elif id == String("cancel"):
            self.close()


def action_language_options() -> List[String]:
    """``""`` then every language id the LSP registry knows. A registry that
    failed to load (the bundled languages.json not reachable from cwd) falls
    back to a short hand-picked list, so the picker is never just "(any)"."""
    var options = List[String]()
    options.append(String(""))
    var specs = built_in_servers()
    for i in range(len(specs)):
        options.append(specs[i].language_id)
    if len(specs) == 0:
        for name in [
            "python", "rust", "typescript", "javascript", "go", "c", "cpp",
            "ruby", "bash", "html", "css", "json", "yaml", "markdown",
        ]:
            options.append(String(name))
    return options^
