"""NamesReview: the new names of changeset after changeset (Git ▸ Review
new names…).

One dialog, three panes top to bottom: the changesets (unstaged, staged,
recent commits, then branches against the main line — ``ReviewMode``'s
picker entries), the selected changeset's distinct new names
(``new_names.mojo``) — name, what it is (function, variable, parameter,
constant, class, struct, …) and where — and the selected name's file in a
code view, the definition line marked and the name highlighted. Moving
through the changesets reloads the names, so many commits review in a
row. Open (or a double-click) jumps to the definition in a normal editor;
reopening the dialog comes back to the same changeset.

A declarative dialog (``ui`` / ``ui_set`` / ``ui_act``), so the grid,
native and Platinum projectors all draw it from the same tree.
"""

from std.collections.optional import Optional

from .colors import BLACK, FG_TRUECOLOR, YELLOW
from .highlight import (
    GrammarRegistry, Highlight, HighlightCache, extension_of,
    highlight_for_extension_cached,
)
from .new_names import NewName
from .review_mode import ReviewMode
from .string_utils import byte_slice, split_lines_no_trailing
from .ui_tree import (
    ListWindow, UI_CANCEL, UI_CODE, UI_DEFAULT, UI_DISABLED, UI_LARGE,
    UI_RGB, UI_SECONDARY, UINode, UISpan, ui_button, ui_buttons, ui_dialog,
    ui_int, ui_label, ui_list, ui_table, ui_vstack,
)


# Files longer than this aren't tokenized for the code view (shown plain).
comptime _HIGHLIGHT_LINE_CAP: Int = 20000


@fieldwise_init
struct _Loaded(Copyable, Movable):
    """A changeset already loaded this session of the dialog."""
    var key: String
    var title: String
    var paths: List[String]
    var afters: List[String]
    var names: List[NewName]


struct NamesReview(Movable):
    var active: Bool
    var title: String
    var root: String
    # The changeset model, and its picker entries flattened into one list:
    # ``change_tab`` / ``change_idx`` per row.
    var model: ReviewMode
    var change_tab: List[Int]
    var change_idx: List[Int]
    var change: Int
    var _loaded: List[_Loaded]
    var paths: List[String]     # repo-relative, per changeset file
    var afters: List[String]    # each file's after text
    var names: List[NewName]
    var selected: Int
    # Set by Open: the host opens ``open_request``'s name and closes.
    var open_requested: Bool
    var close_requested: Bool
    var code_window: ListWindow
    # The code view's file, split and highlighted once per file.
    var _code_file: Int
    var _code_lines: List[String]
    var _code_hl: List[Highlight]

    def __init__(out self):
        self.active = False
        self.title = String("")
        self.root = String("")
        self.model = ReviewMode()
        self.change_tab = List[Int]()
        self.change_idx = List[Int]()
        self.change = -1
        self._loaded = List[_Loaded]()
        self.paths = List[String]()
        self.afters = List[String]()
        self.names = List[NewName]()
        self.selected = 0
        self.open_requested = False
        self.close_requested = False
        self.code_window = ListWindow()
        self._code_file = -1
        self._code_lines = List[String]()
        self._code_hl = List[Highlight]()

    def open(mut self, var root: String):
        """List ``root``'s changesets and show the one reviewed last (when
        it's still listed), else the first. A reopen keeps the selected name
        too, so Open and back resumes where the review was."""
        var same = root == self.root
        var last = self.model.last_key
        var keep_name = self.selected if same else 0
        self.root = root^
        self.model.open(self.root)
        self.change_tab = List[Int]()
        self.change_idx = List[Int]()
        var start = 0
        for t in range(2):
            for i in range(self.model.changeset_count(t)):
                if self.model.changeset_key(t, i) == last:
                    start = len(self.change_tab)
                self.change_tab.append(t)
                self.change_idx.append(i)
        self._loaded = List[_Loaded]()
        self.change = -1
        self.open_requested = False
        self.close_requested = False
        self.active = True
        self._select_change(start)
        if same and start < len(self.change_tab) \
                and self.model.changeset_key(
                    self.change_tab[start], self.change_idx[start]
                ) == last \
                and keep_name < len(self.names):
            self.selected = keep_name

    def close(mut self):
        self.active = False
        self.model.close()
        self._loaded = List[_Loaded]()
        self.paths = List[String]()
        self.afters = List[String]()
        self.names = List[NewName]()
        self._code_file = -1
        self._code_lines = List[String]()
        self._code_hl = List[Highlight]()

    def _select_change(mut self, c: Int):
        """Show changeset row ``c``'s names (loaded once per dialog)."""
        if c < 0 or c >= len(self.change_tab) or c == self.change:
            return
        self.change = c
        var tab = self.change_tab[c]
        var idx = self.change_idx[c]
        var key = self.model.changeset_key(tab, idx)
        var hit = -1
        for i in range(len(self._loaded)):
            if self._loaded[i].key == key:
                hit = i
        if hit < 0:
            self.model.load_changeset(tab, idx)
            self._loaded.append(_Loaded(
                key, self.model.title, self.model.file_paths.copy(),
                self.model.file_after.copy(), self.model.new_names(),
            ))
            hit = len(self._loaded) - 1
        else:
            # Remembered for the next open, as a fresh load would.
            self.model.last_key = key
        ref l = self._loaded[hit]
        self.title = l.title
        self.paths = l.paths.copy()
        self.afters = l.afters.copy()
        self.names = l.names.copy()
        self.selected = 0
        self.code_window.reset()
        self._code_file = -1

    def selected_name(self) -> Optional[NewName]:
        if 0 <= self.selected and self.selected < len(self.names):
            return Optional[NewName](self.names[self.selected])
        return Optional[NewName]()

    def selected_path(self) -> String:
        """Repo-relative path of the selected name's file (empty if none)."""
        var n = self.selected_name()
        if not n:
            return String("")
        return self.paths[n.value().file]

    # --- declarative UI ---------------------------------------------------

    def ui(mut self, mut registry: GrammarRegistry) -> UINode:
        var change_cols = List[String]()
        change_cols.append(String("Changeset"))
        change_cols.append(String("Subject"))
        var change_rows = List[List[String]]()
        for c in range(len(self.change_tab)):
            var label = self.model.changeset_label(
                self.change_tab[c], self.change_idx[c],
            )
            # "<sha or branch>  <subject>"; unstaged / staged have no subject.
            var head = label
            var rest = String("")
            var cut = label.find("  ")
            if cut >= 0:
                head = byte_slice(label, 0, cut)
                rest = byte_slice(label, cut + 2, len(label.as_bytes()))
            if self.change_tab[c] == 1:
                head = String("branch ") + head
            var r = List[String]()
            r.append(head^)
            r.append(rest^)
            change_rows.append(r^)
        var columns = List[String]()
        columns.append(String("Name"))
        columns.append(String("Kind"))
        columns.append(String("File"))
        var rows = List[List[String]]()
        for i in range(len(self.names)):
            ref n = self.names[i]
            var r = List[String]()
            r.append(n.name)
            r.append(n.what)
            r.append(self.paths[n.file] + String(":") + String(n.row + 1))
            rows.append(r^)
        var body = List[UINode]()
        body.append(ui_table(
            String("changes"), change_cols^, change_rows^, self.change,
            String(""), 8,
        ))
        body.append(ui_table(
            String("names"), columns^, rows^, self.selected, String("open"), 10,
        ))
        body.append(self._code_view(registry))
        var status: String
        if len(self.change_tab) == 0:
            status = String("No changesets to review")
        elif len(self.names) == 0:
            status = String("No new names in ") + self.title
        else:
            status = String(len(self.names)) + String(
                " new name in " if len(self.names) == 1 else " new names in "
            ) + self.title
        body.append(ui_label(status^, UI_SECONDARY))
        var buttons = List[UINode]()
        buttons.append(ui_button(String("cancel"), String("Close"), UI_CANCEL))
        buttons.append(ui_button(
            String("open"), String("Open"),
            UI_DEFAULT if len(self.names) > 0 else UI_DISABLED,
        ))
        body.append(ui_buttons(buttons^))
        var d = ui_dialog(
            String("Review new names"), String("cancel"),
            ui_vstack(body^),
        )
        d.flags |= UI_LARGE
        return d^

    def _load_code(mut self, mut registry: GrammarRegistry):
        """Split + highlight the selected name's file, once per file."""
        var n = self.selected_name()
        var f = n.value().file if n else -1
        if f == self._code_file:
            return
        self._code_file = f
        self._code_lines = List[String]()
        self._code_hl = List[Highlight]()
        self.code_window.reset()
        if f < 0:
            return
        self._code_lines = split_lines_no_trailing(self.afters[f])
        for i in range(len(self._code_lines)):
            if len(self._code_lines[i].as_bytes()) > _HIGHLIGHT_LINE_CAP:
                return
        var cache = HighlightCache()
        self._code_hl = highlight_for_extension_cached(
            extension_of(self.paths[f]), self._code_lines, registry, cache,
        )

    def _code_view(mut self, mut registry: GrammarRegistry) -> UINode:
        """The selected name's file around its definition: the line marked
        (and revealed at the golden ratio), the name itself highlighted."""
        self._load_code(registry)
        var mark = -1
        var n = self.selected_name()
        if n:
            mark = n.value().row
        var count = len(self._code_lines)
        var span = self.code_window.range(count, mark)
        var rows = List[List[String]]()
        for i in range(span[0], span[1]):
            rows.append([self._code_lines[i]])
        var spans = List[UISpan]()
        for i in range(len(self._code_hl)):
            ref h = self._code_hl[i]
            if h.row < span[0] or h.row >= span[1]:
                continue
            var fg = Int(h.attr.fg)
            if (h.attr.color_mode & FG_TRUECOLOR) != 0:
                fg = UI_RGB | Int(h.attr.fg_rgb)
            spans.append(UISpan(h.row, 0, h.col_start, h.col_end, fg, -1))
        if n and span[0] <= mark and mark < span[1]:
            var nm = n.value()
            spans.append(UISpan(
                mark, 0, nm.col, nm.col + len(nm.name.as_bytes()),
                Int(BLACK), Int(YELLOW),
            ))
        return ui_list(
            String("context"), count, span[0], rows^, String(mark), String(""),
            12, UI_CODE, spans^,
        )

    def ui_set(mut self, key: String, value: String):
        if key == String("changes"):
            self._select_change(ui_int(value, self.change))
        elif key == String("names"):
            var i = ui_int(value, self.selected)
            if 0 <= i and i < len(self.names):
                self.selected = i
        elif key == String("context@top"):
            self.code_window.view_at(ui_int(value, 0))

    def ui_act(mut self, id: String):
        if id == String("cancel"):
            self.close_requested = True
        elif id == String("open") and len(self.names) > 0:
            self.open_requested = True
