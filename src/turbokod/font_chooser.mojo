"""Settings ▸ Choose… for a font: every font on the system, searched by
typing.

Plain state plus a declarative UI (``ui`` / ``ui_set`` / ``ui_act``, see
``ui_tree.mojo``) that the grid and native projectors draw, opened over
Settings like its language editor. Settings reads ``choice`` back when
``submitted``.
"""

from std.collections.list import List

from .case_fold import contains_ci
from .ui_tree import (
    UI_CANCEL, UI_DEFAULT, UI_DISABLED, UINode, ui_button, ui_buttons,
    ui_dialog, ui_int, ui_table, ui_text, ui_vstack,
)


struct FontChooser(Movable):
    var active: Bool
    var submitted: Bool
    var target: String
    """Which setting it chooses for (Settings' key for it)."""
    var title: String
    var names: List[String]
    var query: String
    var matched: List[Int]
    """Indices into ``names`` that contain ``query``."""
    var selected: Int
    """Index into ``matched``; -1 when nothing matches."""
    var choice: String

    def __init__(out self):
        self.active = False
        self.submitted = False
        self.target = String("")
        self.title = String("")
        self.names = List[String]()
        self.query = String("")
        self.matched = List[Int]()
        self.selected = -1
        self.choice = String("")

    def open(
        mut self, var target: String, var title: String,
        var names: List[String], current: String,
    ):
        """Show ``names`` with ``current`` selected and the search empty."""
        self.active = True
        self.submitted = False
        self.target = target^
        self.title = title^
        self.names = names^
        self.query = String("")
        self.choice = current
        self._refilter()
        for i in range(len(self.matched)):
            if self.names[self.matched[i]] == current:
                self.selected = i

    def close(mut self):
        self.active = False
        self.names = List[String]()
        self.matched = List[Int]()

    def _refilter(mut self):
        self.matched = List[Int]()
        for i in range(len(self.names)):
            if contains_ci(self.names[i], self.query):
                self.matched.append(i)
        self.selected = 0 if len(self.matched) > 0 else -1

    def ui(self) -> UINode:
        var rows = List[List[String]]()
        for i in range(len(self.matched)):
            rows.append([self.names[self.matched[i]]])
        var body = List[UINode]()
        body.append(ui_text(
            String("query"), self.query, String("Search fonts"),
        ))
        body.append(ui_table(
            String("fonts"), [String("Font")], rows^, self.selected,
            String("choose"), 14,
        ))
        var buttons = List[UINode]()
        buttons.append(ui_button(String("cancel"), String("Cancel"), UI_CANCEL))
        buttons.append(ui_button(
            String("choose"), String("Choose"),
            UI_DEFAULT if self.selected >= 0 else UI_DEFAULT | UI_DISABLED,
        ))
        body.append(ui_buttons(buttons^))
        return ui_dialog(self.title, String("cancel"), ui_vstack(body^))

    def ui_set(mut self, key: String, value: String):
        if key == String("query"):
            self.query = value
            self._refilter()
        elif key == String("fonts"):
            var row = ui_int(value, self.selected)
            if row >= 0 and row < len(self.matched):
                self.selected = row

    def ui_act(mut self, id: String):
        if id == String("choose"):
            if self.selected >= 0 and self.selected < len(self.matched):
                self.choice = self.names[self.matched[self.selected]]
                self.submitted = True
        elif id == String("cancel"):
            self.close()
