"""Find / Replace as a declarative dialog, for the looks that give dialogs
windows of their own (the Turbo Vision look in the native app).

It stays open while the user steps through the matches, like the Mac OS 9
look's Find window: Next (the default, so Return), Previous, Mark All /
Unmark All, and with Replace, Replace and Replace All. The dialog only
holds the fields; each button leaves its operation in ``op`` for the host,
which runs it through ``Desktop.native_find`` — the same code the macOS
find bar and the Mac OS 9 Find window drive. Done (Esc) closes it.

The terminal frontends keep the in-grid prompt: a modal dialog over the
workspace would cover the matches it steps to.
"""

from std.collections.list import List

from .search_options import SearchOptions
from .ui_tree import (
    UI_CANCEL, UI_DEFAULT, UINode, ui_bool, ui_button, ui_buttons, ui_check,
    ui_dialog, ui_form, ui_hstack, ui_row, ui_text, ui_vstack,
)


struct FindDialog(Movable):
    var active: Bool
    var replacing: Bool
    var find: String
    var replacement: String
    var opts: SearchOptions
    var op: String
    """The button just pressed (``next`` / ``prev`` / ``mark`` /
    ``unmark`` / ``replace`` / ``replace_all``), for the host to run and
    clear; "" when none."""

    def __init__(out self):
        self.active = False
        self.replacing = False
        self.find = String("")
        self.replacement = String("")
        self.opts = SearchOptions()
        self.op = String("")

    def open(mut self, replacing: Bool, var seed: String, opts: SearchOptions):
        """Show it, seeded like the prompt: the selection or the previous
        needle, and the previous options."""
        self.active = True
        self.replacing = replacing
        self.find = seed^
        self.opts = opts
        self.op = String("")

    def close(mut self):
        self.active = False
        self.op = String("")

    def ui(self) -> UINode:
        var rows = List[UINode]()
        rows.append(ui_row(String("Find"), ui_text(String("find"), self.find)))
        if self.replacing:
            rows.append(ui_row(
                String("Replace"), ui_text(String("replace"), self.replacement),
            ))
        var checks = List[UINode]()
        checks.append(ui_check(
            String("case"), String("Match case"), self.opts.case_sensitive,
        ))
        checks.append(ui_check(
            String("word"), String("Whole word"), self.opts.whole_word,
        ))
        checks.append(ui_check(
            String("regex"), String("Regular expression"), self.opts.regex,
        ))
        var buttons = List[UINode]()
        buttons.append(ui_button(String("done"), String("Done"), UI_CANCEL))
        buttons.append(ui_button(String("mark"), String("Mark All")))
        buttons.append(ui_button(String("unmark"), String("Unmark All")))
        buttons.append(ui_button(String("prev"), String("Previous")))
        if self.replacing:
            buttons.append(ui_button(String("replace"), String("Replace")))
            buttons.append(ui_button(String("replace_all"), String("Replace All")))
        buttons.append(ui_button(String("next"), String("Next"), UI_DEFAULT))
        var body = List[UINode]()
        body.append(ui_form(rows^))
        body.append(ui_hstack(checks^))
        body.append(ui_buttons(buttons^))
        return ui_dialog(
            String("Replace") if self.replacing else String("Find"),
            String("done"), ui_vstack(body^),
        )

    def ui_set(mut self, key: String, value: String):
        if key == String("find"):
            self.find = value
        elif key == String("replace"):
            self.replacement = value
        elif key == String("case"):
            self.opts.case_sensitive = ui_bool(value)
        elif key == String("word"):
            self.opts.whole_word = ui_bool(value)
        elif key == String("regex"):
            self.opts.regex = ui_bool(value)

    def ui_act(mut self, id: String):
        if id == String("done"):
            self.close()
            return
        self.op = id
