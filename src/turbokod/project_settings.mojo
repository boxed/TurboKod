"""Project Settings — a modal dialog with three tabs:

* **On save** — the *library* of on-save actions (the global catalog,
  ``config.on_save_actions``) with a per-project enable checkbox. Ticking
  copies the action's definition into the project's ``on_save.json`` as a
  frozen snapshot; only the project's own copies run after a save there.
  Editing a library entry leaves an already-enabled project copy alone —
  the edited version simply surfaces as a fresh (unticked) row. Add and
  Edit open an ``ActionEditor`` on top.
* **Targets** — the per-project run/debug targets: a list, and a form for
  the selected one.
* **Grammars** — the per-project syntax-grammar overrides: extension →
  grammar.

Plain state plus a declarative UI (``ui`` / ``ui_set`` / ``ui_act``, see
``ui_tree.mojo``); the grid and native projectors draw it. Edits commit
immediately to the working state, and the host syncs each section to disk
while its dirty flag is set (``Desktop._sync_project_settings``). There is
no Save button — Close ends the interaction.
"""

from std.collections.list import List

from .action_editor import ActionEditor, action_language_options
from .config import OnSaveAction
from .grammar_install import built_in_downloadable_grammars
from .highlight import bundled_grammar_languages
from .project_grammars import GrammarOverride
from .project_on_save import on_save_equal
from .project_targets import (
    ProjectTargets, RunTarget, join_env_field, split_env_field,
)
from .string_utils import split_whitespace
from .ui_tree import (
    UI_DEFAULT, UI_DISABLED, UI_SECONDARY, UINode, ui_button, ui_buttons, ui_choice,
    ui_dialog, ui_form, ui_hstack, ui_int, ui_label, ui_page, ui_path, ui_row,
    ui_table, ui_tabs, ui_text, ui_vstack,
)


comptime _SECTION_ON_SAVE  = 0
comptime _SECTION_TARGETS  = 1
comptime _SECTION_GRAMMARS = 2


def _format_command(act: OnSaveAction) -> String:
    """``<program> <args>`` on one line."""
    var line = act.program
    for i in range(len(act.args)):
        line += String(" ") + act.args[i]
    return line^


def grammar_options() -> List[String]:
    """``""`` then every mappable grammar language: bundled first, then
    downloadable-but-unbundled."""
    var options = List[String]()
    options.append(String(""))
    var bundled = bundled_grammar_languages()
    for i in range(len(bundled)):
        options.append(bundled[i])
    var dls = built_in_downloadable_grammars()
    for i in range(len(dls)):
        var lang = dls[i].language_id
        var dup = False
        for j in range(len(bundled)):
            if bundled[j] == lang:
                dup = True
                break
        if not dup:
            options.append(lang)
    return options^


def _choice_of(var options: List[String], value: String) -> Tuple[List[String], Int]:
    """``options`` as a choice shows them — ``""`` as ``(none)``, plus
    ``value`` when it isn't one of them — and ``value``'s index."""
    var sel = -1
    for i in range(len(options)):
        if options[i] == value:
            sel = i
    if sel < 0:
        options.append(value)
        sel = len(options) - 1
    var shown = List[String]()
    for i in range(len(options)):
        shown.append(options[i] if len(options[i].as_bytes()) > 0 else String("(none)"))
    return (shown^, sel)


def _pick(var options: List[String], current: String, value: String) -> String:
    """The option a choice's ``set`` index names (``options`` extended the
    way ``_choice_of`` extended them)."""
    var known = False
    for i in range(len(options)):
        if options[i] == current:
            known = True
    if not known:
        options.append(current)
    var i = ui_int(value)
    if i < 0 or i >= len(options):
        return current
    return options[i]


struct ProjectSettings(Movable):
    var active: Bool
    var close_requested: Bool
    """Close was pressed; the host syncs the last edits, then closes."""
    var section: Int
    var project_root: String

    # Dirty flags — one per backend, so each section persists only when
    # its own data changed.
    var on_save_dirty: Bool
    var targets_dirty: Bool
    var grammars_dirty: Bool

    # On save.
    var library: List[OnSaveAction]
    """Working copy of the global catalog (``config.on_save_actions``)."""
    var project_actions: List[OnSaveAction]
    """Working copy of the project's frozen enabled set (on_save.json)."""
    var selected_os: Int
    """Row in the union(library, project_actions) display list."""
    var editor: ActionEditor
    var _os_edit_is_add: Bool
    var _os_edit_orig: OnSaveAction
    """The row being edited, so an Edit replaces the matching library
    entry while leaving any frozen project copy untouched."""

    # Targets. The selected target's fields are edited as text here (an
    # argument line keeps its trailing space while you type) and committed
    # to ``targets`` on every change.
    var targets: ProjectTargets
    var targets_active_name: String
    var selected_tg: Int
    var tg_name: String
    var tg_program: String
    var tg_args: String
    var tg_cwd: String
    var tg_env: String

    # Grammars.
    var grammars: List[GrammarOverride]
    var selected_gr: Int
    var grammars_install_check: List[String]
    """Extensions whose grammar was just picked — the host drains these and
    offers to download any uninstalled grammar."""

    def __init__(out self):
        self.active = False
        self.close_requested = False
        self.section = _SECTION_ON_SAVE
        self.project_root = String("")
        self.on_save_dirty = False
        self.targets_dirty = False
        self.grammars_dirty = False
        self.library = List[OnSaveAction]()
        self.project_actions = List[OnSaveAction]()
        self.selected_os = -1
        self.editor = ActionEditor()
        self._os_edit_is_add = False
        self._os_edit_orig = OnSaveAction()
        self.targets = ProjectTargets()
        self.targets_active_name = String("")
        self.selected_tg = -1
        self.tg_name = String("")
        self.tg_program = String("")
        self.tg_args = String("")
        self.tg_cwd = String("")
        self.tg_env = String("")
        self.grammars = List[GrammarOverride]()
        self.selected_gr = -1
        self.grammars_install_check = List[String]()

    def open(
        mut self,
        var project_root: String,
        var targets: ProjectTargets,
        var grammars: List[GrammarOverride],
        var library: List[OnSaveAction],
        var project_actions: List[OnSaveAction],
    ):
        self = ProjectSettings()
        self.active = True
        self.project_root = project_root^
        self.targets = targets^
        if self.targets.has_active():
            self.targets_active_name = (
                self.targets.targets[self.targets.active].name
            )
        self.grammars = grammars^
        self.library = library^
        self.project_actions = project_actions^
        self.selected_os = 0 if len(self._os_union()) > 0 else -1
        self.selected_tg = (
            self.targets.active if self.targets.has_active() else -1
        )
        if self.selected_tg < 0 and len(self.targets.targets) > 0:
            self.selected_tg = 0
        self.selected_gr = 0 if len(self.grammars) > 0 else -1
        self._tg_load_fields()

    def close(mut self):
        self = ProjectSettings()

    def ack_on_save_dirty(mut self):
        self.on_save_dirty = False

    def ack_targets_dirty(mut self):
        self.targets_dirty = False

    def ack_grammars_dirty(mut self):
        self.grammars_dirty = False

    def targets_value(self) -> ProjectTargets:
        """Build a ProjectTargets for the host. Active follows the
        preserved name when it still resolves, else the highlighted row."""
        var out = ProjectTargets()
        out.targets = self.targets.targets.copy()
        out.active = -1
        if len(out.targets) == 0:
            return out^
        if len(self.targets_active_name.as_bytes()) > 0:
            for i in range(len(out.targets)):
                if out.targets[i].name == self.targets_active_name:
                    out.active = i
                    break
        if out.active < 0:
            out.active = self.selected_tg if self.selected_tg >= 0 else 0
            if out.active >= len(out.targets):
                out.active = 0
        return out^

    def grammars_value(self) -> List[GrammarOverride]:
        """Override list for the host. Half-filled rows dropped."""
        var out = List[GrammarOverride]()
        for i in range(len(self.grammars)):
            var e = self.grammars[i].copy()
            if len(e.ext.as_bytes()) == 0 \
                    or len(e.language_id.as_bytes()) == 0:
                continue
            out.append(GrammarOverride(e.ext, e.language_id))
        return out^

    # --- declarative UI -------------------------------------------------

    def ui(self) -> UINode:
        var pages = List[UINode]()
        pages.append(ui_page(String("On save"), self._on_save_ui()))
        pages.append(ui_page(String("Targets"), self._targets_ui()))
        pages.append(ui_page(String("Grammars"), self._grammars_ui()))
        var buttons = List[UINode]()
        buttons.append(ui_button(String("close"), String("Close"), UI_DEFAULT))
        var body = List[UINode]()
        body.append(ui_tabs(String("section"), self.section, pages^))
        body.append(ui_buttons(buttons^))
        return ui_dialog(String("Project Settings"), String("close"), ui_vstack(body^))

    def _on_save_ui(self) -> UINode:
        var union = self._os_union()
        var rows = List[List[String]]()
        for i in range(len(union)):
            var lang = union[i].language_id
            rows.append([
                String("1") if self._os_is_enabled(union[i]) else String("0"),
                lang if len(lang.as_bytes()) > 0 else String("(any)"),
                _format_command(union[i]),
            ])
        var has_row = self.selected_os >= 0 and self.selected_os < len(union)
        var buttons = List[UINode]()
        buttons.append(ui_button(String("os_add"), String("Add…")))
        buttons.append(ui_button(String("os_edit"), String("Edit…"), 0 if has_row else UI_DISABLED))
        buttons.append(ui_button(String("os_remove"), String("Remove"), 0 if has_row else UI_DISABLED))
        var body = List[UINode]()
        body.append(ui_label(
            String("Ticked actions run after every save in this project."),
            UI_SECONDARY,
        ))
        body.append(ui_table(
            String("os"), [String(""), String("Language"), String("Command")],
            rows^, self.selected_os, String("os_edit"), 7, True,
        ))
        body.append(ui_hstack(buttons^))
        return ui_vstack(body^)

    def _targets_ui(self) -> UINode:
        var rows = List[List[String]]()
        for i in range(len(self.targets.targets)):
            ref t = self.targets.targets[i]
            rows.append([t.name, t.program])
        var on = self.selected_tg >= 0 and self.selected_tg < len(self.targets.targets)
        var buttons = List[UINode]()
        buttons.append(ui_button(String("tg_add"), String("Add")))
        buttons.append(ui_button(String("tg_remove"), String("Remove"), 0 if on else UI_DISABLED))
        var lang = String("")
        if on:
            lang = self.targets.targets[self.selected_tg].debug_language
        var choice = _choice_of(action_language_options(), lang)
        var form = List[UINode]()
        form.append(ui_row(String("Name"), ui_text(String("tg_name"), self.tg_name, String(""), on)))
        form.append(ui_row(String("Program"), ui_path(
            String("tg_program"), self.tg_program, String(""), on,
        )))
        form.append(ui_row(String("Arguments"), ui_text(
            String("tg_args"), self.tg_args, String(""), on,
        )))
        form.append(ui_row(String("Working dir"), ui_text(
            String("tg_cwd"), self.tg_cwd, String("project root"), on,
        )))
        form.append(ui_row(String("Environment"), ui_text(
            String("tg_env"), self.tg_env, String("KEY=value; KEY2=value"), on,
        )))
        form.append(ui_row(String("Debug language"), ui_choice(
            String("tg_lang"), choice[0].copy(), choice[1], on,
        )))
        var body = List[UINode]()
        body.append(ui_table(
            String("tg"), [String("Name"), String("Program")], rows^,
            self.selected_tg, String(""), 4,
        ))
        body.append(ui_hstack(buttons^))
        body.append(ui_form(form^))
        return ui_vstack(body^)

    def _grammars_ui(self) -> UINode:
        var rows = List[List[String]]()
        for i in range(len(self.grammars)):
            rows.append([self.grammars[i].ext, self.grammars[i].language_id])
        var on = self.selected_gr >= 0 and self.selected_gr < len(self.grammars)
        var buttons = List[UINode]()
        buttons.append(ui_button(String("gr_add"), String("Add")))
        buttons.append(ui_button(String("gr_remove"), String("Remove"), 0 if on else UI_DISABLED))
        var ext = String("")
        var lang = String("")
        if on:
            ext = self.grammars[self.selected_gr].ext
            lang = self.grammars[self.selected_gr].language_id
        var choice = _choice_of(grammar_options(), lang)
        var form = List[UINode]()
        form.append(ui_row(String("Extension"), ui_text(
            String("gr_ext"), ext, String("html"), on,
        )))
        form.append(ui_row(String("Grammar"), ui_choice(
            String("gr_lang"), choice[0].copy(), choice[1], on,
        )))
        var body = List[UINode]()
        body.append(ui_label(
            String("Highlight files with these extensions using another grammar."),
            UI_SECONDARY,
        ))
        body.append(ui_table(
            String("gr"), [String("Extension"), String("Grammar")], rows^,
            self.selected_gr, String(""), 4,
        ))
        body.append(ui_hstack(buttons^))
        body.append(ui_form(form^))
        return ui_vstack(body^)

    def ui_set(mut self, key: String, value: String):
        if key == String("section"):
            var s = ui_int(value, self.section)
            if s >= 0 and s <= _SECTION_GRAMMARS:
                self.section = s
        elif key == String("os"):
            var n = len(self._os_union())
            var s = ui_int(value, self.selected_os)
            if s >= 0 and s < n:
                self.selected_os = s
        elif key == String("tg"):
            var s = ui_int(value, self.selected_tg)
            if s >= 0 and s < len(self.targets.targets):
                self.selected_tg = s
                self._tg_load_fields()
        elif key == String("tg_name"):
            self.tg_name = value
            self._tg_commit_fields()
        elif key == String("tg_program"):
            self.tg_program = value
            self._tg_commit_fields()
        elif key == String("tg_args"):
            self.tg_args = value
            self._tg_commit_fields()
        elif key == String("tg_cwd"):
            self.tg_cwd = value
            self._tg_commit_fields()
        elif key == String("tg_env"):
            self.tg_env = value
            self._tg_commit_fields()
        elif key == String("tg_lang"):
            if self.selected_tg >= 0 and self.selected_tg < len(self.targets.targets):
                var cur = self.targets.targets[self.selected_tg].debug_language
                self.targets.targets[self.selected_tg].debug_language = _pick(
                    action_language_options(), cur, value,
                )
                self.targets_dirty = True
        elif key == String("gr"):
            var s = ui_int(value, self.selected_gr)
            if s >= 0 and s < len(self.grammars):
                self.selected_gr = s
        elif key == String("gr_ext"):
            if self.selected_gr >= 0 and self.selected_gr < len(self.grammars):
                self.grammars[self.selected_gr].ext = value
                self.grammars_dirty = True
        elif key == String("gr_lang"):
            if self.selected_gr >= 0 and self.selected_gr < len(self.grammars):
                ref e = self.grammars[self.selected_gr]
                e.language_id = _pick(grammar_options(), e.language_id, value)
                self.grammars_dirty = True
                # Offer the download only when a grammar is actually
                # picked, not on every extension keystroke.
                if len(e.ext.as_bytes()) > 0 and len(e.language_id.as_bytes()) > 0:
                    self.grammars_install_check.append(e.ext)

    def ui_act(mut self, id: String):
        if id == String("close"):
            self.close_requested = True
        elif id == String("os_add"):
            self._os_add()
        elif id == String("os_edit"):
            self._os_edit()
        elif id == String("os_remove"):
            self._os_remove()
        elif id.startswith(String("toggle:")):
            var row = ui_int(String(StringSpan(unsafe_from_utf8=id.as_bytes()[7:])))
            self.selected_os = row
            self._os_toggle(row)
        elif id == String("tg_add"):
            self._tg_add()
        elif id == String("tg_remove"):
            self._tg_remove()
        elif id == String("gr_add"):
            self._gr_add()
        elif id == String("gr_remove"):
            self._gr_remove()

    # --- on save ---------------------------------------------------------

    def _os_union(self) -> List[OnSaveAction]:
        """Display list: every library entry, then any project copy that
        no longer matches a library entry (a frozen copy whose library
        original was edited away — the 'new suggestion' case)."""
        var out = self.library.copy()
        for i in range(len(self.project_actions)):
            var pa = self.project_actions[i].copy()
            var found = False
            for j in range(len(self.library)):
                if on_save_equal(pa, self.library[j]):
                    found = True
                    break
            if not found:
                out.append(pa^)
        return out^

    def _os_is_enabled(self, act: OnSaveAction) -> Bool:
        for i in range(len(self.project_actions)):
            if on_save_equal(act, self.project_actions[i]):
                return True
        return False

    def _os_toggle(mut self, row: Int):
        var rows = self._os_union()
        if row < 0 or row >= len(rows):
            return
        var act = rows[row].copy()
        if self._os_is_enabled(act):
            var rebuilt = List[OnSaveAction]()
            for i in range(len(self.project_actions)):
                if on_save_equal(act, self.project_actions[i]):
                    continue
                rebuilt.append(self.project_actions[i].copy())
            self.project_actions = rebuilt^
        else:
            self.project_actions.append(act^)
        self.on_save_dirty = True

    def _os_add(mut self):
        self._os_edit_is_add = True
        self._os_edit_orig = OnSaveAction()
        self.editor.open(OnSaveAction(), -1)

    def _os_edit(mut self):
        var rows = self._os_union()
        if self.selected_os < 0 or self.selected_os >= len(rows):
            return
        self._os_edit_is_add = False
        self._os_edit_orig = rows[self.selected_os].copy()
        self.editor.open(rows[self.selected_os], self.selected_os)

    def _os_remove(mut self):
        var rows = self._os_union()
        if self.selected_os < 0 or self.selected_os >= len(rows):
            return
        var act = rows[self.selected_os].copy()
        var lib = List[OnSaveAction]()
        for i in range(len(self.library)):
            if on_save_equal(act, self.library[i]):
                continue
            lib.append(self.library[i].copy())
        self.library = lib^
        var pa = List[OnSaveAction]()
        for i in range(len(self.project_actions)):
            if on_save_equal(act, self.project_actions[i]):
                continue
            pa.append(self.project_actions[i].copy())
        self.project_actions = pa^
        self.on_save_dirty = True
        var n = len(self._os_union())
        if n == 0:
            self.selected_os = -1
        elif self.selected_os >= n:
            self.selected_os = n - 1

    def consume_editor(mut self):
        """Store the action editor's result once it was saved."""
        if not self.editor.submitted:
            return
        var entry = self.editor.value()
        self.editor.close()
        if self._os_edit_is_add:
            self.library.append(entry.copy())
            self.project_actions.append(entry.copy())
        else:
            var replaced = False
            var lib = List[OnSaveAction]()
            for i in range(len(self.library)):
                if not replaced \
                        and on_save_equal(self._os_edit_orig, self.library[i]):
                    lib.append(entry.copy())
                    replaced = True
                else:
                    lib.append(self.library[i].copy())
            if not replaced:
                lib.append(entry.copy())
            self.library = lib^
        self.on_save_dirty = True
        # Land the selection on the row we just touched.
        var rows = self._os_union()
        for i in range(len(rows)):
            if on_save_equal(rows[i], entry):
                self.selected_os = i
                break

    # --- targets ---------------------------------------------------------

    def _tg_load_fields(mut self):
        if self.selected_tg < 0 or self.selected_tg >= len(self.targets.targets):
            self.tg_name = String("")
            self.tg_program = String("")
            self.tg_args = String("")
            self.tg_cwd = String("")
            self.tg_env = String("")
            return
        ref t = self.targets.targets[self.selected_tg]
        self.tg_name = t.name
        self.tg_program = t.program
        self.tg_args = String(" ").join(t.args)
        self.tg_cwd = t.cwd
        self.tg_env = join_env_field(t.env)

    def _tg_commit_fields(mut self):
        if self.selected_tg < 0 or self.selected_tg >= len(self.targets.targets):
            return
        ref t = self.targets.targets[self.selected_tg]
        t.name = self.tg_name
        t.program = self.tg_program
        t.args = split_whitespace(self.tg_args)
        t.cwd = self.tg_cwd
        t.env = split_env_field(self.tg_env)
        self.targets_dirty = True

    def _tg_unique_name(self, base: String) -> String:
        var n = 1
        while True:
            var candidate = base if n == 1 else base + String(" ") + String(n)
            var hit = False
            for i in range(len(self.targets.targets)):
                if self.targets.targets[i].name == candidate:
                    hit = True
                    break
            if not hit:
                return candidate^
            n += 1

    def _tg_add(mut self):
        var t = RunTarget()
        t.name = self._tg_unique_name(String("new"))
        self.targets.targets.append(t^)
        self.selected_tg = len(self.targets.targets) - 1
        self.targets_dirty = True
        self._tg_load_fields()

    def _tg_remove(mut self):
        if self.selected_tg < 0 or self.selected_tg >= len(self.targets.targets):
            return
        _ = self.targets.targets.pop(self.selected_tg)
        self.targets_dirty = True
        if self.selected_tg >= len(self.targets.targets):
            self.selected_tg = len(self.targets.targets) - 1
        self._tg_load_fields()

    # --- grammars --------------------------------------------------------

    def _gr_add(mut self):
        self.grammars.append(GrammarOverride(String(""), String("")))
        self.selected_gr = len(self.grammars) - 1
        self.grammars_dirty = True

    def _gr_remove(mut self):
        if self.selected_gr < 0 or self.selected_gr >= len(self.grammars):
            return
        _ = self.grammars.pop(self.selected_gr)
        self.grammars_dirty = True
        if self.selected_gr >= len(self.grammars):
            self.selected_gr = len(self.grammars) - 1
