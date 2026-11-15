"""ReferencePick: list-of-locations picker for ``textDocument/references``.

A modal centered dialog, like ``SymbolPick``, but populated from a
references response. Each row is one usage site (path + 1-based line +
0-based column). Enter / click jumps to the selected entry; ESC cancels.

The host opens this only when a references response has two or more
entries — zero is a status-bar message, one is a direct jump. So the
picker doesn't have to model a loading state or a "no results" view.
"""

from std.collections.list import List

from .lsp_dispatch import DefinitionResolved


struct ReferencePick(Movable):
    var active: Bool
    var submitted: Bool
    var entries: List[DefinitionResolved]
    var word: String
    var project_root: String     # for displaying paths relative to the project
    var selected: Int
    # Submission output — read after ``submitted`` flips True.
    var selected_path: String
    var selected_line: Int
    var selected_character: Int

    def __init__(out self):
        self.active = False
        self.submitted = False
        self.entries = List[DefinitionResolved]()
        self.word = String("")
        self.project_root = String("")
        self.selected = 0
        self.selected_path = String("")
        self.selected_line = 0
        self.selected_character = 0

    def open(
        mut self, var entries: List[DefinitionResolved],
        var word: String, var project_root: String,
    ):
        """Open the picker with ``entries``. ``word`` is shown in the
        title bar; ``project_root`` (may be empty) is used to render
        paths relative to the project for readability."""
        self.entries = entries^
        self.word = word^
        self.project_root = project_root^
        self.active = True
        self.submitted = False
        self.selected = 0
        self.selected_path = String("")
        self.selected_line = 0
        self.selected_character = 0

    def close(mut self):
        self.active = False
        self.submitted = False
        self.entries = List[DefinitionResolved]()
        self.word = String("")
        self.project_root = String("")
        self.selected = 0

    def submit(mut self):
        """Jump to the selected entry: sets ``selected_path`` /
        ``selected_line`` / ``selected_character`` and flips
        ``submitted``."""
        if not self.active \
                or self.selected < 0 or self.selected >= len(self.entries):
            return
        var entry = self.entries[self.selected]
        self.selected_path = entry.path
        self.selected_line = entry.line
        self.selected_character = entry.character
        self.submitted = True
