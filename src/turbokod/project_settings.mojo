"""Project Settings view — a second-surface container_bounds (native window on the
macOS frontend, in-grid movable/resizable dialog in the terminal), the
same pattern as the global ``Settings`` view.

Three left-rail sections::

    ╔══ Project Settings ═══════════════════════════════════════════════╗
    ║ ┌──────────────┐ On save                                          ║
    ║ │ On save      │ ┌──────────────────────────────────────────┐     ║
    ║ │ Targets      │ │ [x] python  /usr/local/bin/black $File…  │     ║
    ║ │ Grammars     │ │ [ ] rust    /usr/local/bin/rustfmt       │     ║
    ║ └──────────────┘ └──────────────────────────────────────────┘     ║
    ║                  [+ Add] [Edit] [- Remove]            [ Close ]    ║
    ╚═══════════════════════════════════════════════════════════════════╝

* **On save** — the *library* of on-save actions (the global catalog,
  ``config.on_save_actions``) with a per-project enable checkbox. Ticking
  copies the action's definition into the project's ``on_save.json`` as a
  frozen snapshot; only the project's own copies run after a save there.
  Editing a library entry leaves an already-enabled project copy alone —
  the edited version simply surfaces as a fresh (unticked) row.
* **Targets** — the per-project run/debug targets (was *Configure
  targets…*).
* **Grammars** — the per-project syntax-grammar overrides (was *Configure
  project grammars…*).

Like ``Settings``, edits commit immediately to the working state and the
host syncs them to disk on every paint while a section's dirty flag is
set. There is no Save button — closing the window ends the interaction.
"""

from std.collections.list import List
from std.collections.optional import Optional

from .action_editor import ActionEditor
from .buttons import (
    BUTTON_FIRED, BUTTON_NONE, ShadowButton, paint_shadow_button,
)
from .canvas import Canvas, paint_drop_shadow
from .painter import Painter
from .colors import (
    Attr, BLACK, BLUE, BORDER_FOCUS, CYAN, GREEN, LIGHT_GRAY, WHITE,
)
from .config import OnSaveAction
from .dropdown import (
    DROPDOWN_HIT_BODY, DROPDOWN_HIT_NONE, DROPDOWN_HIT_POPUP, Dropdown,
)
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_DOWN, KEY_ENTER, KEY_ESC, KEY_LEFT, KEY_RIGHT, KEY_SPACE,
    KEY_TAB, KEY_UP,
    MOD_SHIFT, MOUSE_BUTTON_LEFT, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .geometry import Point, Rect
from .grammar_install import built_in_downloadable_grammars
from .highlight import bundled_grammar_languages
from .language_config import built_in_servers
from .project_grammars import GrammarOverride
from .project_on_save import on_save_equal
from .project_targets import ProjectTargets, RunTarget
from .text_field import TextField
from .type_ahead import TypeAhead, is_printable_ascii, type_ahead_pick
from .window import paint_window_title


# --- section indices ------------------------------------------------------

comptime _SECTION_ON_SAVE  = 0
comptime _SECTION_TARGETS  = 1
comptime _SECTION_GRAMMARS = 2


# --- focus discriminants --------------------------------------------------

comptime _FOCUS_SECTIONS   = UInt8(0)
comptime _FOCUS_CLOSE      = UInt8(1)
# On-save section.
comptime _FOCUS_OS_LIST    = UInt8(2)
comptime _FOCUS_OS_ADD     = UInt8(3)
comptime _FOCUS_OS_EDIT    = UInt8(4)
comptime _FOCUS_OS_REMOVE  = UInt8(5)
# Targets section.
comptime _FOCUS_TG_LIST    = UInt8(6)
comptime _FOCUS_TG_NAME    = UInt8(7)
comptime _FOCUS_TG_PROGRAM = UInt8(8)
comptime _FOCUS_TG_ARGS    = UInt8(9)
comptime _FOCUS_TG_CWD     = UInt8(10)
comptime _FOCUS_TG_LANG    = UInt8(11)
comptime _FOCUS_TG_ADD     = UInt8(12)
comptime _FOCUS_TG_REMOVE  = UInt8(13)
# Grammars section.
comptime _FOCUS_GR_LIST    = UInt8(14)
comptime _FOCUS_GR_EXT     = UInt8(15)
comptime _FOCUS_GR_LANG    = UInt8(16)
comptime _FOCUS_GR_ADD     = UInt8(17)
comptime _FOCUS_GR_REMOVE  = UInt8(18)


# --- button table indices -------------------------------------------------

comptime _BTN_OS_ADD     = 0
comptime _BTN_OS_EDIT    = 1
comptime _BTN_OS_REMOVE  = 2
comptime _BTN_CLOSE      = 3
comptime _BTN_TG_ADD     = 4
comptime _BTN_TG_REMOVE  = 5
comptime _BTN_GR_ADD     = 6
comptime _BTN_GR_REMOVE  = 7


# --- layout ---------------------------------------------------------------

comptime _SECTION_W = 14
comptime _PS_MIN_W  = 70
comptime _PS_MIN_H  = 18


def _section_labels() -> List[String]:
    var out = List[String]()
    out.append(String("On save"))
    out.append(String("Targets"))
    out.append(String("Grammars"))
    return out^


def _format_action(act: OnSaveAction) -> String:
    """One-line label: ``<lang>  <program> <args>``. Empty language
    renders as ``(any)``."""
    var lang = act.language_id if len(act.language_id.as_bytes()) > 0 \
        else String("(any)")
    var line = lang + String("  ") + act.program
    if len(act.args) > 0:
        line = line + String(" ")
        for i in range(len(act.args)):
            if i > 0:
                line = line + String(" ")
            line = line + act.args[i]
    return line^


def _join_args(args: List[String]) -> String:
    var out = String("")
    for i in range(len(args)):
        if i > 0:
            out = out + String(" ")
        out = out + args[i]
    return out^


def _split_args(text: String) -> List[String]:
    var out = List[String]()
    var b = text.as_bytes()
    var n = len(b)
    var start = 0
    var i = 0
    while i < n:
        if b[i] == 0x20:
            if i > start:
                out.append(String(StringSlice(unsafe_from_utf8=b[start:i])))
            start = i + 1
        i += 1
    if start < n:
        out.append(String(StringSlice(unsafe_from_utf8=b[start:n])))
    return out^


def _build_lang_dropdown(var current: String) -> Dropdown:
    """``(none)`` + every LSP-known language id (targets debug language)."""
    var options = List[String]()
    options.append(String(""))
    var specs = built_in_servers()
    for i in range(len(specs)):
        options.append(specs[i].language_id)
    var dd = Dropdown(options^, 0)
    dd.set_value(current^)
    return dd^


def _build_grammar_dropdown(var current: String) -> Dropdown:
    """``(none)`` + every mappable grammar language (bundled first, then
    downloadable-but-unbundled)."""
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
    var dd = Dropdown(options^, 0)
    dd.set_value(current^)
    return dd^


@fieldwise_init
struct _PlacedButton(ImplicitlyCopyable, Movable):
    var button: ShadowButton
    var focus: UInt8
    var enabled: Bool


# --- ProjectSettings ------------------------------------------------------


struct ProjectSettings(Movable):
    var active: Bool
    var detached: Bool
    """True when the host renders this in its own native window (macOS)."""
    var bounds: Rect
    var section: Int
    var focus: UInt8
    var project_root: String

    # Dirty flags — one per backend, so each section persists only when
    # its own data changed.
    var on_save_dirty: Bool
    var targets_dirty: Bool
    var grammars_dirty: Bool

    # On-save section.
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

    # Targets section.
    var targets: ProjectTargets
    var targets_active_name: String
    var selected_tg: Int
    var name_tf: TextField
    var program_tf: TextField
    var args_tf: TextField
    var cwd_tf: TextField
    var tg_lang_dropdown: Dropdown
    var _tg_lang_anchor: Rect

    # Grammars section.
    var grammars: List[GrammarOverride]
    var selected_gr: Int
    var ext_tf: TextField
    var gr_lang_dropdown: Dropdown
    var _gr_lang_anchor: Rect
    var grammars_install_check: List[String]
    """Extensions whose grammar was just picked from the dropdown — the
    host drains these and offers to download any uninstalled grammar."""

    # Shared list/scroll + chrome state.
    var _list_scroll: Int
    var _last_scroll_os: Int
    var _last_scroll_tg: Int
    var _last_scroll_gr: Int
    var _buttons: List[_PlacedButton]
    var _type_ahead: TypeAhead
    var _moving: Bool
    var _move_dx: Int
    var _move_dy: Int
    var _resizing: Bool
    var _rs_left: Bool
    var _rs_right: Bool
    var _rs_bottom: Bool

    def __init__(out self):
        self.active = False
        self.detached = False
        self.bounds = Rect(0, 0, 0, 0)
        self.section = 0
        self.focus = _FOCUS_SECTIONS
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
        self.name_tf = TextField()
        self.program_tf = TextField()
        self.args_tf = TextField()
        self.cwd_tf = TextField()
        self.tg_lang_dropdown = _build_lang_dropdown(String(""))
        self._tg_lang_anchor = Rect(0, 0, 0, 0)
        self.grammars = List[GrammarOverride]()
        self.selected_gr = -1
        self.ext_tf = TextField()
        self.gr_lang_dropdown = _build_grammar_dropdown(String(""))
        self._gr_lang_anchor = Rect(0, 0, 0, 0)
        self.grammars_install_check = List[String]()
        self._list_scroll = 0
        self._last_scroll_os = -2
        self._last_scroll_tg = -2
        self._last_scroll_gr = -2
        self._buttons = List[_PlacedButton]()
        self._buttons.append(_PlacedButton(
            ShadowButton(String(" + Add "), 0, 0), _FOCUS_OS_ADD, True,
        ))
        self._buttons.append(_PlacedButton(
            ShadowButton(String(" Edit "), 0, 0), _FOCUS_OS_EDIT, True,
        ))
        self._buttons.append(_PlacedButton(
            ShadowButton(String(" - Remove "), 0, 0), _FOCUS_OS_REMOVE, True,
        ))
        self._buttons.append(_PlacedButton(
            ShadowButton(String(" Close "), 0, 0), _FOCUS_CLOSE, True,
        ))
        self._buttons.append(_PlacedButton(
            ShadowButton(String(" + Add "), 0, 0), _FOCUS_TG_ADD, True,
        ))
        self._buttons.append(_PlacedButton(
            ShadowButton(String(" - Remove "), 0, 0), _FOCUS_TG_REMOVE, True,
        ))
        self._buttons.append(_PlacedButton(
            ShadowButton(String(" + Add "), 0, 0), _FOCUS_GR_ADD, True,
        ))
        self._buttons.append(_PlacedButton(
            ShadowButton(String(" - Remove "), 0, 0), _FOCUS_GR_REMOVE, True,
        ))
        self._type_ahead = TypeAhead()
        self._moving = False
        self._move_dx = 0
        self._move_dy = 0
        self._resizing = False
        self._rs_left = False
        self._rs_right = False
        self._rs_bottom = False

    def open(
        mut self,
        var project_root: String,
        var targets: ProjectTargets,
        var grammars: List[GrammarOverride],
        var library: List[OnSaveAction],
        var project_actions: List[OnSaveAction],
        current_language_ext: String = String(""),
    ):
        self.project_root = project_root^
        self.targets = targets^
        self.targets_active_name = String("")
        if self.targets.has_active():
            self.targets_active_name = (
                self.targets.targets[self.targets.active].name
            )
        self.grammars = grammars^
        self.library = library^
        self.project_actions = project_actions^
        self.active = True
        self.section = _SECTION_ON_SAVE
        self.focus = _FOCUS_SECTIONS
        self.on_save_dirty = False
        self.targets_dirty = False
        self.grammars_dirty = False
        self.selected_os = 0 if len(self._os_union()) > 0 else -1
        self.selected_tg = (
            self.targets.active if self.targets.has_active() else -1
        )
        if self.selected_tg < 0 and len(self.targets.targets) > 0:
            self.selected_tg = 0
        self.selected_gr = 0 if len(self.grammars) > 0 else -1
        self._list_scroll = 0
        self._last_scroll_os = -2
        self._last_scroll_tg = -2
        self._last_scroll_gr = -2
        self.grammars_install_check = List[String]()
        self._tg_load_fields()
        self._gr_load_fields()

    def close(mut self):
        self.active = False
        self._moving = False
        self._resizing = False
        self.section = _SECTION_ON_SAVE
        self.focus = _FOCUS_SECTIONS
        self.library = List[OnSaveAction]()
        self.project_actions = List[OnSaveAction]()
        self.selected_os = -1
        self.editor.close()
        self.targets = ProjectTargets()
        self.selected_tg = -1
        self.grammars = List[GrammarOverride]()
        self.selected_gr = -1
        self.tg_lang_dropdown.close()
        self.gr_lang_dropdown.close()
        self._type_ahead.reset()
        for i in range(len(self._buttons)):
            self._buttons[i].button.pressed = False
            self._buttons[i].button.pressed_inside = False

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

    # --- on-save model ----------------------------------------------

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
        self.editor.open(rows[self.selected_os].copy(), self.selected_os)

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
        self._clamp_os_selection()

    def _clamp_os_selection(mut self):
        var n = len(self._os_union())
        if n == 0:
            self.selected_os = -1
            self.focus = _FOCUS_OS_ADD
        elif self.selected_os >= n:
            self.selected_os = n - 1

    def _maybe_consume_editor(mut self):
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
        self.focus = _FOCUS_OS_LIST

    # --- targets model ----------------------------------------------

    def _tg_load_fields(mut self):
        if self.selected_tg < 0 or self.selected_tg >= len(self.targets.targets):
            self.name_tf = TextField()
            self.program_tf = TextField()
            self.args_tf = TextField()
            self.cwd_tf = TextField()
            self.tg_lang_dropdown = _build_lang_dropdown(String(""))
            return
        var t = self.targets.targets[self.selected_tg].copy()
        self.name_tf = TextField()
        self.name_tf.set_text(t.name)
        self.program_tf = TextField()
        self.program_tf.set_text(t.program)
        self.args_tf = TextField()
        self.args_tf.set_text(_join_args(t.args))
        self.cwd_tf = TextField()
        self.cwd_tf.set_text(t.cwd)
        self.tg_lang_dropdown = _build_lang_dropdown(t.debug_language)

    def _tg_commit_fields(mut self):
        if self.selected_tg < 0 or self.selected_tg >= len(self.targets.targets):
            return
        var t = self.targets.targets[self.selected_tg].copy()
        t.name = self.name_tf.text
        t.program = self.program_tf.text
        t.args = _split_args(self.args_tf.text)
        t.cwd = self.cwd_tf.text
        self.targets.targets[self.selected_tg] = t^
        self.targets_dirty = True

    def _tg_commit_lang(mut self):
        if self.selected_tg < 0 or self.selected_tg >= len(self.targets.targets):
            return
        var t = self.targets.targets[self.selected_tg].copy()
        t.debug_language = self.tg_lang_dropdown.value()
        self.targets.targets[self.selected_tg] = t^
        self.targets_dirty = True

    def _tg_unique_name(self, base: String) -> String:
        var taken = False
        for i in range(len(self.targets.targets)):
            if self.targets.targets[i].name == base:
                taken = True
                break
        if not taken:
            return base
        var n = 2
        var max_iters = len(self.targets.targets) + 2
        for _ in range(max_iters):
            var candidate = base + String(" ") + String(n)
            var hit = False
            for i in range(len(self.targets.targets)):
                if self.targets.targets[i].name == candidate:
                    hit = True
                    break
            if not hit:
                return candidate^
            n += 1
        return base + String(" ") + String(n)

    def _tg_add(mut self):
        self._tg_commit_fields()
        var t = RunTarget()
        t.name = self._tg_unique_name(String("new"))
        self.targets.targets.append(t^)
        self.selected_tg = len(self.targets.targets) - 1
        self.targets_dirty = True
        self.focus = _FOCUS_TG_NAME
        self._tg_load_fields()

    def _tg_remove(mut self):
        if self.selected_tg < 0 or self.selected_tg >= len(self.targets.targets):
            return
        var rebuilt = List[RunTarget]()
        for i in range(len(self.targets.targets)):
            if i == self.selected_tg:
                continue
            rebuilt.append(self.targets.targets[i].copy())
        self.targets.targets = rebuilt^
        self.targets_dirty = True
        if len(self.targets.targets) == 0:
            self.selected_tg = -1
            self.focus = _FOCUS_TG_ADD
        else:
            if self.selected_tg >= len(self.targets.targets):
                self.selected_tg = len(self.targets.targets) - 1
            self.focus = _FOCUS_TG_LIST
        self._tg_load_fields()

    def _step_tg(mut self, delta: Int):
        if len(self.targets.targets) == 0:
            return
        var s = self.selected_tg + delta
        if s < 0:
            s = 0
        if s >= len(self.targets.targets):
            s = len(self.targets.targets) - 1
        if s == self.selected_tg:
            return
        self._tg_commit_fields()
        self.selected_tg = s
        self._tg_load_fields()

    # --- grammars model ---------------------------------------------

    def _gr_load_fields(mut self):
        if self.selected_gr < 0 or self.selected_gr >= len(self.grammars):
            self.ext_tf = TextField()
            self.gr_lang_dropdown = _build_grammar_dropdown(String(""))
            return
        var e = self.grammars[self.selected_gr].copy()
        self.ext_tf = TextField()
        self.ext_tf.set_text(e.ext)
        self.gr_lang_dropdown = _build_grammar_dropdown(e.language_id)

    def _gr_commit_fields(mut self):
        if self.selected_gr < 0 or self.selected_gr >= len(self.grammars):
            return
        self.grammars[self.selected_gr] = GrammarOverride(
            self.ext_tf.text, self.gr_lang_dropdown.value(),
        )
        self.grammars_dirty = True

    def _gr_commit_lang(mut self):
        if self.selected_gr < 0 or self.selected_gr >= len(self.grammars):
            return
        var lang = self.gr_lang_dropdown.value()
        self.grammars[self.selected_gr] = GrammarOverride(
            self.ext_tf.text, lang,
        )
        self.grammars_dirty = True
        # Queue an install-check for the mapped extension — only fired
        # when the grammar is actually picked, not on every ext keystroke.
        var ext = self.ext_tf.text
        if len(ext.as_bytes()) > 0 and len(lang.as_bytes()) > 0:
            self.grammars_install_check.append(ext)

    def _gr_add(mut self):
        self._gr_commit_fields()
        self.grammars.append(GrammarOverride(String(""), String("")))
        self.selected_gr = len(self.grammars) - 1
        self.grammars_dirty = True
        self.focus = _FOCUS_GR_EXT
        self._gr_load_fields()

    def _gr_remove(mut self):
        if self.selected_gr < 0 or self.selected_gr >= len(self.grammars):
            return
        var rebuilt = List[GrammarOverride]()
        for i in range(len(self.grammars)):
            if i == self.selected_gr:
                continue
            rebuilt.append(self.grammars[i].copy())
        self.grammars = rebuilt^
        self.grammars_dirty = True
        if len(self.grammars) == 0:
            self.selected_gr = -1
            self.focus = _FOCUS_GR_ADD
        else:
            if self.selected_gr >= len(self.grammars):
                self.selected_gr = len(self.grammars) - 1
            self.focus = _FOCUS_GR_LIST
        self._gr_load_fields()

    def _step_gr(mut self, delta: Int):
        if len(self.grammars) == 0:
            return
        var s = self.selected_gr + delta
        if s < 0:
            s = 0
        if s >= len(self.grammars):
            s = len(self.grammars) - 1
        if s == self.selected_gr:
            return
        self._gr_commit_fields()
        self.selected_gr = s
        self._gr_load_fields()

    def _step_os(mut self, delta: Int):
        var n = len(self._os_union())
        if n == 0:
            return
        var s = self.selected_os + delta
        if s < 0:
            s = 0
        if s >= n:
            s = n - 1
        self.selected_os = s

    # --- chrome -----------------------------------------------------

    def _workspace_rect(self, container_bounds: Rect) -> Rect:
        if self.detached:
            return container_bounds
        return self.bounds

    def _host_workspace(self, container_bounds: Rect) -> Rect:
        var top = 1 if container_bounds.b.y > 2 else 0
        var bottom = container_bounds.b.y - 1 if container_bounds.b.y > 2 else container_bounds.b.y
        return Rect(container_bounds.a.x, top, container_bounds.b.x, bottom)

    def _ensure_bounds(mut self, container_bounds: Rect):
        if self.detached:
            return
        var ws = self._host_workspace(container_bounds)
        var w = self.bounds.width()
        var h = self.bounds.height()
        if w < _PS_MIN_W or h < _PS_MIN_H:
            w = ws.width() - 8
            if w > 104:
                w = 104
            h = ws.height() - 4
            if h > 30:
                h = 30
            var x = ws.a.x + (ws.width() - w) // 2
            var y = ws.a.y + (ws.height() - h) // 2
            self.bounds = Rect(x, y, x + w, y + h)
        var b = self.bounds
        if b.width() > ws.width():
            b = Rect(b.a.x, b.a.y, b.a.x + ws.width(), b.b.y)
        if b.height() > ws.height():
            b = Rect(b.a.x, b.a.y, b.b.x, b.a.y + ws.height())
        var dx = 0
        var dy = 0
        if b.a.x < ws.a.x:
            dx = ws.a.x - b.a.x
        if b.b.x > ws.b.x:
            dx = ws.b.x - b.b.x
        if b.a.y < ws.a.y:
            dy = ws.a.y - b.a.y
        if b.b.y > ws.b.y:
            dy = ws.b.y - b.b.y
        self.bounds = Rect(b.a.x + dx, b.a.y + dy, b.b.x + dx, b.b.y + dy)

    def _handle_window_chrome(
        mut self, event: Event, rect: Rect, container_bounds: Rect,
    ) -> Bool:
        if self.detached:
            return False
        var ws = self._host_workspace(container_bounds)
        if self._moving:
            if event.button == MOUSE_BUTTON_LEFT and not event.pressed:
                self._moving = False
                return True
            var w = self.bounds.width()
            var h = self.bounds.height()
            var nx = event.pos.x - self._move_dx
            var ny = event.pos.y - self._move_dy
            if nx < ws.a.x:
                nx = ws.a.x
            if ny < ws.a.y:
                ny = ws.a.y
            if nx + w > ws.b.x:
                nx = ws.b.x - w
            if ny + h > ws.b.y:
                ny = ws.b.y - h
            self.bounds = Rect(nx, ny, nx + w, ny + h)
            return True
        if self._resizing:
            if event.button == MOUSE_BUTTON_LEFT and not event.pressed:
                self._resizing = False
                return True
            var ax = self.bounds.a.x
            var ay = self.bounds.a.y
            var bx = self.bounds.b.x
            var by = self.bounds.b.y
            if self._rs_left:
                ax = event.pos.x
                if ax < ws.a.x:
                    ax = ws.a.x
                if bx - ax < _PS_MIN_W:
                    ax = bx - _PS_MIN_W
            if self._rs_right:
                bx = event.pos.x + 1
                if bx > ws.b.x:
                    bx = ws.b.x
                if bx - ax < _PS_MIN_W:
                    bx = ax + _PS_MIN_W
            if self._rs_bottom:
                by = event.pos.y + 1
                if by > ws.b.y:
                    by = ws.b.y
                if by - ay < _PS_MIN_H:
                    by = ay + _PS_MIN_H
            self.bounds = Rect(ax, ay, bx, by)
            return True
        if event.button != MOUSE_BUTTON_LEFT or not event.pressed \
                or event.motion:
            return False
        var inside_x = event.pos.x >= rect.a.x and event.pos.x < rect.b.x
        var inside_y = event.pos.y >= rect.a.y and event.pos.y < rect.b.y
        if not (inside_x and inside_y):
            return False
        if event.pos.y == rect.a.y:
            self._moving = True
            self._move_dx = event.pos.x - rect.a.x
            self._move_dy = event.pos.y - rect.a.y
            return True
        var on_left = event.pos.x == rect.a.x
        var on_right = event.pos.x == rect.b.x - 1
        var on_bottom = event.pos.y == rect.b.y - 1
        if on_left or on_right or on_bottom:
            self._resizing = True
            self._rs_left = on_left
            self._rs_right = on_right
            self._rs_bottom = on_bottom
            return True
        return False

    def _sections_rect(self, rect: Rect) -> Rect:
        return Rect(
            rect.a.x + 2, rect.a.y + 2,
            rect.a.x + 2 + _SECTION_W, rect.b.y - 2,
        )

    def _right_rect(self, rect: Rect) -> Rect:
        return Rect(
            rect.a.x + 2 + _SECTION_W + 2, rect.a.y + 2,
            rect.b.x - 2, rect.b.y - 2,
        )

    # --- painting ---------------------------------------------------

    def paint(mut self, mut canvas: Canvas, container_bounds: Rect):
        if not self.active:
            return
        self._ensure_bounds(container_bounds)
        var rect = self._workspace_rect(container_bounds)
        if not self.detached:
            paint_drop_shadow(canvas, rect)
        var bg = Attr(BLACK, LIGHT_GRAY)
        var painter = Painter(rect)
        painter.fill(canvas, rect, String(" "), bg)
        if not self.detached:
            var border = Attr(BORDER_FOCUS, LIGHT_GRAY)
            painter.draw_box(canvas, rect, border, True)
            paint_window_title(
                canvas, rect, String(" Project Settings "), bg, bg,
            )
        self._paint_sections(canvas, painter, rect)
        self._paint_right_pane(canvas, painter, rect)
        self._paint_close_button(canvas, rect)
        # Dropdown popups float above the body.
        if self.section == _SECTION_TARGETS and self.tg_lang_dropdown.is_open:
            self.tg_lang_dropdown.paint_popup(
                canvas, self._tg_lang_anchor, container_bounds,
            )
        if self.section == _SECTION_GRAMMARS and self.gr_lang_dropdown.is_open:
            self.gr_lang_dropdown.paint_popup(
                canvas, self._gr_lang_anchor, container_bounds,
            )
        if self.editor.active:
            self.editor.paint(canvas, container_bounds)

    def _paint_sections(
        self, mut canvas: Canvas, painter: Painter, rect: Rect,
    ):
        var inner = self._sections_rect(rect)
        var sub = painter.sub(inner)
        var body_attr = Attr(BLACK, CYAN)
        sub.fill(canvas, inner, String(" "), body_attr)
        var labels = _section_labels()
        for i in range(len(labels)):
            var y = inner.a.y + i
            if y >= inner.b.y:
                break
            var attr = body_attr
            if i == self.section:
                attr = (
                    Attr(WHITE, BLUE) if self.focus == _FOCUS_SECTIONS
                    else Attr(BLACK, GREEN)
                )
                sub.fill(
                    canvas, Rect(inner.a.x, y, inner.b.x, y + 1),
                    String(" "), attr,
                )
            _ = sub.put_text(
                canvas, Point(inner.a.x + 1, y), labels[i], attr,
            )

    def _paint_right_pane(
        mut self, mut canvas: Canvas, painter: Painter, rect: Rect,
    ):
        var inner = self._right_rect(rect)
        var sub = painter.sub(inner)
        var bg = Attr(BLACK, LIGHT_GRAY)
        var labels = _section_labels()
        if 0 <= self.section and self.section < len(labels):
            _ = sub.put_text(
                canvas, Point(inner.a.x, inner.a.y), labels[self.section], bg,
            )
        if self.section == _SECTION_ON_SAVE:
            self._paint_on_save_section(canvas, sub, inner)
        elif self.section == _SECTION_TARGETS:
            self._paint_targets_section(canvas, sub, inner)
        elif self.section == _SECTION_GRAMMARS:
            self._paint_grammars_section(canvas, sub, inner)

    def _paint_on_save_section(
        mut self, mut canvas: Canvas, painter: Painter, inner: Rect,
    ):
        var hint = Attr(BLUE, LIGHT_GRAY)
        var list_top = inner.a.y + 2
        var list_bottom = inner.b.y - 5
        if list_bottom <= list_top:
            return
        var list_rect = Rect(inner.a.x, list_top, inner.b.x, list_bottom)
        var body_attr = Attr(BLACK, CYAN)
        painter.fill(canvas, list_rect, String(" "), body_attr)
        var rows = self._os_union()
        if len(rows) == 0:
            _ = painter.put_text(
                canvas, Point(list_rect.a.x + 1, list_rect.a.y),
                String("(no actions in library — press [+ Add])"), hint,
            )
        else:
            self._paint_on_save_list(canvas, painter, list_rect, rows)
        _ = painter.put_text(
            canvas, Point(inner.a.x, list_bottom),
            String("Tick to copy the action into this project (runs on save)."),
            hint,
        )
        var btn_y = list_bottom + 2
        var add_x = inner.a.x
        self._buttons[_BTN_OS_ADD].button.move_to(add_x, btn_y)
        var edit_x = add_x + self._buttons[_BTN_OS_ADD].button.total_width() + 1
        self._buttons[_BTN_OS_EDIT].button.move_to(edit_x, btn_y)
        var rm_x = edit_x + self._buttons[_BTN_OS_EDIT].button.total_width() + 1
        self._buttons[_BTN_OS_REMOVE].button.move_to(rm_x, btn_y)
        var has_sel = 0 <= self.selected_os and self.selected_os < len(rows)
        self._buttons[_BTN_OS_EDIT].enabled = has_sel
        self._buttons[_BTN_OS_REMOVE].enabled = has_sel
        self._paint_button(canvas, _BTN_OS_ADD)
        self._paint_button(canvas, _BTN_OS_EDIT)
        self._paint_button(canvas, _BTN_OS_REMOVE)

    def _paint_on_save_list(
        mut self, mut canvas: Canvas, painter: Painter, list_rect: Rect,
        rows: List[OnSaveAction],
    ):
        var visible = list_rect.height()
        if self.selected_os >= 0 \
                and self.selected_os != self._last_scroll_os:
            if self.selected_os < self._list_scroll:
                self._list_scroll = self.selected_os
            elif self.selected_os >= self._list_scroll + visible:
                self._list_scroll = self.selected_os - visible + 1
        self._last_scroll_os = self.selected_os
        if self._list_scroll < 0:
            self._list_scroll = 0
        var max_scroll = len(rows) - visible
        if max_scroll < 0:
            max_scroll = 0
        if self._list_scroll > max_scroll:
            self._list_scroll = max_scroll
        var body_attr = Attr(BLACK, CYAN)
        for r in range(visible):
            var idx = self._list_scroll + r
            if idx >= len(rows):
                break
            var act = rows[idx].copy()
            var attr = body_attr
            if idx == self.selected_os:
                attr = (
                    Attr(WHITE, BLUE) if self.focus == _FOCUS_OS_LIST
                    else Attr(BLACK, GREEN)
                )
                painter.fill(
                    canvas, Rect(list_rect.a.x, list_rect.a.y + r,
                         list_rect.b.x, list_rect.a.y + r + 1),
                    String(" "), attr,
                )
            var mark = String("[x] ") if self._os_is_enabled(act) \
                else String("[ ] ")
            _ = painter.put_text(
                canvas, Point(list_rect.a.x + 1, list_rect.a.y + r),
                mark + _format_action(act), attr,
            )

    def _paint_targets_section(
        mut self, mut canvas: Canvas, painter: Painter, inner: Rect,
    ):
        var bg = Attr(BLACK, LIGHT_GRAY)
        var hint = Attr(BLUE, LIGHT_GRAY)
        var list_w = 18
        var list_rect = Rect(
            inner.a.x, inner.a.y + 2, inner.a.x + list_w, inner.b.y - 3,
        )
        var label_x = inner.a.x + list_w + 2
        var field_x = label_x + 14
        var right_max = inner.b.x
        var y0 = inner.a.y + 2
        var name_y = y0
        var program_y = y0 + 2
        var args_y = y0 + 4
        var cwd_y = y0 + 6
        var lang_y = y0 + 9
        var name_rect = Rect(field_x, name_y, right_max, name_y + 1)
        var program_rect = Rect(field_x, program_y, right_max, program_y + 1)
        var args_rect = Rect(field_x, args_y, right_max, args_y + 1)
        var cwd_rect = Rect(field_x, cwd_y, right_max, cwd_y + 1)
        var lang_rect = Rect(field_x, lang_y, right_max, lang_y + 1)
        self._tg_lang_anchor = lang_rect
        # Left list.
        _ = painter.put_text(
            canvas, Point(inner.a.x, inner.a.y + 1), String("Targets:"), bg,
        )
        self._paint_targets_list(canvas, painter, list_rect)
        # Right form.
        if self.selected_tg < 0:
            _ = painter.put_text(
                canvas, Point(label_x, args_y),
                String("(no target — press [+ Add])"), hint,
            )
        else:
            _ = painter.put_text(canvas, Point(label_x, name_y), String("Name:"), bg)
            _ = painter.put_text(canvas, Point(label_x, program_y), String("Program:"), bg)
            _ = painter.put_text(canvas, Point(label_x, args_y), String("Args:"), bg)
            _ = painter.put_text(canvas, Point(label_x, cwd_y), String("Working dir:"), bg)
            _ = painter.put_text(
                canvas, Point(field_x, cwd_y + 1),
                String("(empty = project root)"), hint,
            )
            _ = painter.put_text(canvas, Point(label_x, lang_y), String("Debug language:"), bg)
            self.name_tf.paint(canvas, name_rect, self.focus == _FOCUS_TG_NAME)
            self.program_tf.paint(canvas, program_rect, self.focus == _FOCUS_TG_PROGRAM)
            self.args_tf.paint(canvas, args_rect, self.focus == _FOCUS_TG_ARGS)
            self.cwd_tf.paint(canvas, cwd_rect, self.focus == _FOCUS_TG_CWD)
            self.tg_lang_dropdown.paint(
                canvas, lang_rect, self.focus == _FOCUS_TG_LANG,
                Attr(WHITE, BLUE), Attr(BLACK, CYAN),
            )
        # Buttons.
        var btn_y = inner.b.y - 2
        self._buttons[_BTN_TG_ADD].button.move_to(inner.a.x, btn_y)
        var rm_x = inner.a.x + self._buttons[_BTN_TG_ADD].button.total_width() + 1
        self._buttons[_BTN_TG_REMOVE].button.move_to(rm_x, btn_y)
        self._buttons[_BTN_TG_REMOVE].enabled = self.selected_tg >= 0
        self._paint_button(canvas, _BTN_TG_ADD)
        self._paint_button(canvas, _BTN_TG_REMOVE)

    def _paint_targets_list(
        mut self, mut canvas: Canvas, painter: Painter, list_rect: Rect,
    ):
        var body_attr = Attr(BLACK, CYAN)
        painter.fill(canvas, list_rect, String(" "), body_attr)
        var visible = list_rect.height()
        if self.selected_tg >= 0 and self.selected_tg != self._last_scroll_tg:
            if self.selected_tg < self._list_scroll:
                self._list_scroll = self.selected_tg
            elif self.selected_tg >= self._list_scroll + visible:
                self._list_scroll = self.selected_tg - visible + 1
        self._last_scroll_tg = self.selected_tg
        if self._list_scroll < 0:
            self._list_scroll = 0
        var max_scroll = len(self.targets.targets) - visible
        if max_scroll < 0:
            max_scroll = 0
        if self._list_scroll > max_scroll:
            self._list_scroll = max_scroll
        for r in range(visible):
            var idx = self._list_scroll + r
            if idx >= len(self.targets.targets):
                break
            var name = self.targets.targets[idx].name
            var marker = String("● ") if name == self.targets_active_name \
                else String("  ")
            var attr = body_attr
            if idx == self.selected_tg:
                attr = (
                    Attr(WHITE, BLUE) if self.focus == _FOCUS_TG_LIST
                    else Attr(BLACK, GREEN)
                )
                painter.fill(
                    canvas, Rect(list_rect.a.x, list_rect.a.y + r,
                         list_rect.b.x, list_rect.a.y + r + 1),
                    String(" "), attr,
                )
            _ = painter.put_text(
                canvas, Point(list_rect.a.x, list_rect.a.y + r),
                marker + name, attr,
            )

    def _paint_grammars_section(
        mut self, mut canvas: Canvas, painter: Painter, inner: Rect,
    ):
        var bg = Attr(BLACK, LIGHT_GRAY)
        var hint = Attr(BLUE, LIGHT_GRAY)
        var list_w = 22
        var list_rect = Rect(
            inner.a.x, inner.a.y + 2, inner.a.x + list_w, inner.b.y - 3,
        )
        var label_x = inner.a.x + list_w + 2
        var field_x = label_x + 11
        var right_max = inner.b.x
        var ext_y = inner.a.y + 2
        var lang_y = inner.a.y + 4
        var ext_rect = Rect(field_x, ext_y, right_max, ext_y + 1)
        var lang_rect = Rect(field_x, lang_y, right_max, lang_y + 1)
        self._gr_lang_anchor = lang_rect
        _ = painter.put_text(
            canvas, Point(inner.a.x, inner.a.y + 1), String("Extensions:"), bg,
        )
        self._paint_grammars_list(canvas, painter, list_rect)
        if self.selected_gr < 0:
            _ = painter.put_text(
                canvas, Point(label_x, ext_y),
                String("(no mapping — press [+ Add])"), hint,
            )
        else:
            _ = painter.put_text(canvas, Point(label_x, ext_y), String("Extension:"), bg)
            _ = painter.put_text(canvas, Point(label_x, lang_y), String("Language:"), bg)
            _ = painter.put_text(
                canvas, Point(label_x, lang_y + 2),
                String("(uninstalled grammars prompt to download)"), hint,
            )
            self.ext_tf.paint(canvas, ext_rect, self.focus == _FOCUS_GR_EXT)
            self.gr_lang_dropdown.paint(
                canvas, lang_rect, self.focus == _FOCUS_GR_LANG,
                Attr(WHITE, BLUE), Attr(BLACK, CYAN),
            )
        var btn_y = inner.b.y - 2
        self._buttons[_BTN_GR_ADD].button.move_to(inner.a.x, btn_y)
        var rm_x = inner.a.x + self._buttons[_BTN_GR_ADD].button.total_width() + 1
        self._buttons[_BTN_GR_REMOVE].button.move_to(rm_x, btn_y)
        self._buttons[_BTN_GR_REMOVE].enabled = self.selected_gr >= 0
        self._paint_button(canvas, _BTN_GR_ADD)
        self._paint_button(canvas, _BTN_GR_REMOVE)

    def _paint_grammars_list(
        mut self, mut canvas: Canvas, painter: Painter, list_rect: Rect,
    ):
        var body_attr = Attr(BLACK, CYAN)
        painter.fill(canvas, list_rect, String(" "), body_attr)
        var visible = list_rect.height()
        if self.selected_gr >= 0 and self.selected_gr != self._last_scroll_gr:
            if self.selected_gr < self._list_scroll:
                self._list_scroll = self.selected_gr
            elif self.selected_gr >= self._list_scroll + visible:
                self._list_scroll = self.selected_gr - visible + 1
        self._last_scroll_gr = self.selected_gr
        if self._list_scroll < 0:
            self._list_scroll = 0
        var max_scroll = len(self.grammars) - visible
        if max_scroll < 0:
            max_scroll = 0
        if self._list_scroll > max_scroll:
            self._list_scroll = max_scroll
        for r in range(visible):
            var idx = self._list_scroll + r
            if idx >= len(self.grammars):
                break
            var e = self.grammars[idx].copy()
            var ext_label = e.ext if len(e.ext.as_bytes()) > 0 \
                else String("(ext?)")
            var lang_label = e.language_id if len(e.language_id.as_bytes()) > 0 \
                else String("(language?)")
            var attr = body_attr
            if idx == self.selected_gr:
                attr = (
                    Attr(WHITE, BLUE) if self.focus == _FOCUS_GR_LIST
                    else Attr(BLACK, GREEN)
                )
                painter.fill(
                    canvas, Rect(list_rect.a.x, list_rect.a.y + r,
                         list_rect.b.x, list_rect.a.y + r + 1),
                    String(" "), attr,
                )
            _ = painter.put_text(
                canvas, Point(list_rect.a.x, list_rect.a.y + r),
                ext_label + String(" → ") + lang_label, attr,
            )

    def _paint_close_button(mut self, mut canvas: Canvas, rect: Rect):
        var close = self._buttons[_BTN_CLOSE]
        var btn_w = close.button.face_width()
        var btn_x = rect.b.x - 2 - (btn_w + 1)
        var btn_y = rect.b.y - 3
        self._buttons[_BTN_CLOSE].button.move_to(btn_x, btn_y)
        self._paint_button(canvas, _BTN_CLOSE)

    def _paint_button(mut self, mut canvas: Canvas, idx: Int):
        var pb = self._buttons[idx]
        var face: Attr
        if not pb.enabled:
            face = Attr(WHITE, GREEN)
        elif self.focus == pb.focus:
            face = Attr(WHITE, BLUE)
        else:
            face = Attr(BLACK, GREEN)
        paint_shadow_button(canvas, pb.button, face, LIGHT_GRAY)

    # --- key handling -----------------------------------------------

    def handle_key(mut self, event: Event) -> Bool:
        if not self.active:
            return False
        if self.editor.active:
            _ = self.editor.handle_key(event)
            self._maybe_consume_editor()
            return True
        if event.kind != EVENT_KEY:
            return True
        var k = event.key
        # Open dropdown popup eats navigation keys first.
        if self.section == _SECTION_TARGETS \
                and self.focus == _FOCUS_TG_LANG \
                and self.tg_lang_dropdown.is_open:
            if k == KEY_ESC:
                self.tg_lang_dropdown.close()
                return True
            if self.tg_lang_dropdown.handle_key(event):
                self._tg_commit_lang()
                return True
        if self.section == _SECTION_GRAMMARS \
                and self.focus == _FOCUS_GR_LANG \
                and self.gr_lang_dropdown.is_open:
            if k == KEY_ESC:
                self.gr_lang_dropdown.close()
                return True
            if self.gr_lang_dropdown.handle_key(event):
                self._gr_commit_lang()
                return True
        if k == KEY_ESC:
            self.close()
            return True
        if k == KEY_TAB:
            var backward = (event.mods & MOD_SHIFT) != 0
            self.focus = self._next_focus(self.focus, backward)
            return True
        if k == KEY_ENTER:
            return self._activate_focus()
        if k == KEY_UP:
            if self.focus == _FOCUS_SECTIONS:
                self._step_section(-1)
            elif self.focus == _FOCUS_OS_LIST:
                self._step_os(-1)
            elif self.focus == _FOCUS_TG_LIST:
                self._step_tg(-1)
            elif self.focus == _FOCUS_GR_LIST:
                self._step_gr(-1)
            return True
        if k == KEY_DOWN:
            if self.focus == _FOCUS_SECTIONS:
                self._step_section(1)
            elif self.focus == _FOCUS_OS_LIST:
                self._step_os(1)
            elif self.focus == _FOCUS_TG_LIST:
                self._step_tg(1)
            elif self.focus == _FOCUS_GR_LIST:
                self._step_gr(1)
            elif self.focus == _FOCUS_TG_LANG:
                self.tg_lang_dropdown.open()
            elif self.focus == _FOCUS_GR_LANG:
                self.gr_lang_dropdown.open()
            return True
        if (k == KEY_LEFT or k == KEY_RIGHT):
            if self.focus == _FOCUS_TG_LANG:
                if self.tg_lang_dropdown.handle_key(event):
                    self._tg_commit_lang()
                return True
            if self.focus == _FOCUS_GR_LANG:
                if self.gr_lang_dropdown.handle_key(event):
                    self._gr_commit_lang()
                return True
        if k == KEY_SPACE and self.focus == _FOCUS_OS_LIST:
            self._os_toggle(self.selected_os)
            return True
        # Route to a focused editable strip.
        if self.focus == _FOCUS_TG_NAME:
            if self.name_tf.handle_key(event).consumed:
                self._tg_commit_fields()
                return True
        elif self.focus == _FOCUS_TG_PROGRAM:
            if self.program_tf.handle_key(event).consumed:
                self._tg_commit_fields()
                return True
        elif self.focus == _FOCUS_TG_ARGS:
            if self.args_tf.handle_key(event).consumed:
                self._tg_commit_fields()
                return True
        elif self.focus == _FOCUS_TG_CWD:
            if self.cwd_tf.handle_key(event).consumed:
                self._tg_commit_fields()
                return True
        elif self.focus == _FOCUS_GR_EXT:
            if self.ext_tf.handle_key(event).consumed:
                self._gr_commit_fields()
                return True
        # Type-to-jump on whichever list owns focus.
        if is_printable_ascii(k):
            self._handle_type_to_jump(chr(Int(k)))
            return True
        return True

    def _handle_type_to_jump(mut self, ch: String):
        if self.focus == _FOCUS_OS_LIST:
            var rows = self._os_union()
            var labels = List[String]()
            for i in range(len(rows)):
                labels.append(_format_action(rows[i]))
            var hit = type_ahead_pick(self._type_ahead, labels, ch)
            if hit >= 0:
                self.selected_os = hit
        elif self.focus == _FOCUS_TG_LIST:
            var labels = List[String]()
            for i in range(len(self.targets.targets)):
                labels.append(self.targets.targets[i].name)
            var hit = type_ahead_pick(self._type_ahead, labels, ch)
            if hit >= 0 and hit != self.selected_tg:
                self._tg_commit_fields()
                self.selected_tg = hit
                self._tg_load_fields()
        elif self.focus == _FOCUS_GR_LIST:
            var labels = List[String]()
            for i in range(len(self.grammars)):
                labels.append(self.grammars[i].ext)
            var hit = type_ahead_pick(self._type_ahead, labels, ch)
            if hit >= 0 and hit != self.selected_gr:
                self._gr_commit_fields()
                self.selected_gr = hit
                self._gr_load_fields()

    def _step_section(mut self, delta: Int):
        var s = self.section + delta
        if s < 0:
            s = 0
        if s >= 3:
            s = 2
        if s != self.section:
            self.tg_lang_dropdown.close()
            self.gr_lang_dropdown.close()
            self._type_ahead.reset()
        self.section = s

    def _next_focus(self, current: UInt8, backward: Bool) -> UInt8:
        var ordered = List[UInt8]()
        ordered.append(_FOCUS_SECTIONS)
        if self.section == _SECTION_ON_SAVE:
            if len(self._os_union()) > 0:
                ordered.append(_FOCUS_OS_LIST)
            ordered.append(_FOCUS_OS_ADD)
            if self.selected_os >= 0:
                ordered.append(_FOCUS_OS_EDIT)
                ordered.append(_FOCUS_OS_REMOVE)
        elif self.section == _SECTION_TARGETS:
            if len(self.targets.targets) > 0:
                ordered.append(_FOCUS_TG_LIST)
            if self.selected_tg >= 0:
                ordered.append(_FOCUS_TG_NAME)
                ordered.append(_FOCUS_TG_PROGRAM)
                ordered.append(_FOCUS_TG_ARGS)
                ordered.append(_FOCUS_TG_CWD)
                ordered.append(_FOCUS_TG_LANG)
            ordered.append(_FOCUS_TG_ADD)
            if self.selected_tg >= 0:
                ordered.append(_FOCUS_TG_REMOVE)
        elif self.section == _SECTION_GRAMMARS:
            if len(self.grammars) > 0:
                ordered.append(_FOCUS_GR_LIST)
            if self.selected_gr >= 0:
                ordered.append(_FOCUS_GR_EXT)
                ordered.append(_FOCUS_GR_LANG)
            ordered.append(_FOCUS_GR_ADD)
            if self.selected_gr >= 0:
                ordered.append(_FOCUS_GR_REMOVE)
        ordered.append(_FOCUS_CLOSE)
        var pos = -1
        for i in range(len(ordered)):
            if ordered[i] == current:
                pos = i
                break
        if pos < 0:
            return ordered[0]
        var n = len(ordered)
        if backward:
            return ordered[(pos - 1 + n) % n]
        return ordered[(pos + 1) % n]

    def _activate_focus(mut self) -> Bool:
        if self.focus == _FOCUS_CLOSE:
            self.close()
            return True
        if self.focus == _FOCUS_OS_ADD:
            self._os_add()
            return True
        if self.focus == _FOCUS_OS_EDIT:
            self._os_edit()
            return True
        if self.focus == _FOCUS_OS_REMOVE:
            self._os_remove()
            return True
        if self.focus == _FOCUS_OS_LIST:
            self._os_edit()
            return True
        if self.focus == _FOCUS_TG_ADD:
            self._tg_add()
            return True
        if self.focus == _FOCUS_TG_REMOVE:
            self._tg_remove()
            return True
        if self.focus == _FOCUS_TG_LANG:
            self.tg_lang_dropdown.open()
            return True
        if self.focus == _FOCUS_GR_ADD:
            self._gr_add()
            return True
        if self.focus == _FOCUS_GR_REMOVE:
            self._gr_remove()
            return True
        if self.focus == _FOCUS_GR_LANG:
            self.gr_lang_dropdown.open()
            return True
        # Enter on a list / field advances focus.
        self.focus = self._next_focus(self.focus, False)
        return True

    # --- mouse ------------------------------------------------------

    def is_input_at(self, pos: Point, container_bounds: Rect) -> Bool:
        if not self.active:
            return False
        var rect = self._workspace_rect(container_bounds)
        var inner = self._right_rect(rect)
        if self.section == _SECTION_TARGETS and self.selected_tg >= 0:
            var list_w = 18
            var field_x = inner.a.x + list_w + 2 + 14
            var y0 = inner.a.y + 2
            if pos.x >= field_x and pos.x < inner.b.x:
                if pos.y == y0 or pos.y == y0 + 2 or pos.y == y0 + 4 \
                        or pos.y == y0 + 6:
                    return True
        if self.section == _SECTION_GRAMMARS and self.selected_gr >= 0:
            var field_x = inner.a.x + 22 + 2 + 11
            if pos.x >= field_x and pos.x < inner.b.x \
                    and pos.y == inner.a.y + 2:
                return True
        return False

    def handle_mouse(mut self, event: Event, container_bounds: Rect) -> Bool:
        if not self.active:
            return False
        if self.editor.active:
            _ = self.editor.handle_mouse(event, container_bounds)
            self._maybe_consume_editor()
            return True
        if event.kind != EVENT_MOUSE:
            return True
        self._ensure_bounds(container_bounds)
        var rect = self._workspace_rect(container_bounds)
        if self._handle_window_chrome(event, rect, container_bounds):
            return True
        # Section-specific dropdown first-crack (body + popup clicks).
        if self.section == _SECTION_TARGETS and self.selected_tg >= 0:
            var hit = self.tg_lang_dropdown.handle_mouse(
                self._tg_lang_anchor, container_bounds, event,
            )
            if hit == DROPDOWN_HIT_BODY:
                self.focus = _FOCUS_TG_LANG
                return True
            if hit == DROPDOWN_HIT_POPUP:
                self._tg_commit_lang()
                self.focus = _FOCUS_TG_LANG
                return True
        if self.section == _SECTION_GRAMMARS and self.selected_gr >= 0:
            var hit = self.gr_lang_dropdown.handle_mouse(
                self._gr_lang_anchor, container_bounds, event,
            )
            if hit == DROPDOWN_HIT_BODY:
                self.focus = _FOCUS_GR_LANG
                return True
            if hit == DROPDOWN_HIT_POPUP:
                self._gr_commit_lang()
                self.focus = _FOCUS_GR_LANG
                return True
        if self._dispatch_buttons(event):
            return True
        if event.button == MOUSE_WHEEL_UP:
            if self._right_rect(rect).contains(event.pos):
                self._list_scroll -= 1
                if self._list_scroll < 0:
                    self._list_scroll = 0
                return True
        if event.button == MOUSE_WHEEL_DOWN:
            if self._right_rect(rect).contains(event.pos):
                self._list_scroll += 1
                return True
        if event.button != MOUSE_BUTTON_LEFT or not event.pressed \
                or event.motion:
            return True
        # Left rail.
        var sec = self._sections_rect(rect)
        if sec.contains(event.pos):
            var idx = event.pos.y - sec.a.y
            if 0 <= idx and idx < 3:
                if idx != self.section:
                    self.tg_lang_dropdown.close()
                    self.gr_lang_dropdown.close()
                self.section = idx
                self.focus = _FOCUS_SECTIONS
            return True
        var inner = self._right_rect(rect)
        if self.section == _SECTION_ON_SAVE:
            return self._mouse_on_save(event, inner)
        if self.section == _SECTION_TARGETS:
            return self._mouse_targets(event, inner, container_bounds)
        if self.section == _SECTION_GRAMMARS:
            return self._mouse_grammars(event, inner, container_bounds)
        return True

    def _mouse_on_save(mut self, event: Event, inner: Rect) -> Bool:
        var list_top = inner.a.y + 2
        var list_bottom = inner.b.y - 5
        var list_rect = Rect(inner.a.x, list_top, inner.b.x, list_bottom)
        if list_rect.contains(event.pos):
            var idx = self._list_scroll + (event.pos.y - list_rect.a.y)
            var rows = self._os_union()
            if 0 <= idx and idx < len(rows):
                self.selected_os = idx
                # A click on the checkbox glyph toggles enablement.
                if event.pos.x <= list_rect.a.x + 3:
                    self._os_toggle(idx)
            self.focus = _FOCUS_OS_LIST
            return True
        return True

    def _mouse_targets(mut self, event: Event, inner: Rect, container_bounds: Rect) -> Bool:
        var list_w = 18
        var list_rect = Rect(
            inner.a.x, inner.a.y + 2, inner.a.x + list_w, inner.b.y - 3,
        )
        var field_x = inner.a.x + list_w + 2 + 14
        var right_max = inner.b.x
        var y0 = inner.a.y + 2
        var name_rect = Rect(field_x, y0, right_max, y0 + 1)
        var program_rect = Rect(field_x, y0 + 2, right_max, y0 + 3)
        var args_rect = Rect(field_x, y0 + 4, right_max, y0 + 5)
        var cwd_rect = Rect(field_x, y0 + 6, right_max, y0 + 7)
        if self.selected_tg >= 0:
            if self.name_tf.handle_mouse(event, name_rect):
                self.focus = _FOCUS_TG_NAME
                return True
            if self.program_tf.handle_mouse(event, program_rect):
                self.focus = _FOCUS_TG_PROGRAM
                return True
            if self.args_tf.handle_mouse(event, args_rect):
                self.focus = _FOCUS_TG_ARGS
                return True
            if self.cwd_tf.handle_mouse(event, cwd_rect):
                self.focus = _FOCUS_TG_CWD
                return True
        if list_rect.contains(event.pos):
            var idx = self._list_scroll + (event.pos.y - list_rect.a.y)
            if 0 <= idx and idx < len(self.targets.targets) \
                    and idx != self.selected_tg:
                self._tg_commit_fields()
                self.selected_tg = idx
                self._tg_load_fields()
            elif 0 <= idx and idx < len(self.targets.targets):
                self.selected_tg = idx
            self.focus = _FOCUS_TG_LIST
            return True
        if self.selected_tg >= 0 and self._tg_lang_anchor.contains(event.pos):
            self.focus = _FOCUS_TG_LANG
            var hit = self.tg_lang_dropdown.handle_mouse(
                self._tg_lang_anchor, container_bounds, event,
            )
            if hit != DROPDOWN_HIT_NONE:
                self._tg_commit_lang()
            return True
        return True

    def _mouse_grammars(mut self, event: Event, inner: Rect, container_bounds: Rect) -> Bool:
        var list_w = 22
        var list_rect = Rect(
            inner.a.x, inner.a.y + 2, inner.a.x + list_w, inner.b.y - 3,
        )
        var field_x = inner.a.x + list_w + 2 + 11
        var right_max = inner.b.x
        var ext_rect = Rect(field_x, inner.a.y + 2, right_max, inner.a.y + 3)
        if self.selected_gr >= 0:
            if self.ext_tf.handle_mouse(event, ext_rect):
                self.focus = _FOCUS_GR_EXT
                return True
        if list_rect.contains(event.pos):
            var idx = self._list_scroll + (event.pos.y - list_rect.a.y)
            if 0 <= idx and idx < len(self.grammars) \
                    and idx != self.selected_gr:
                self._gr_commit_fields()
                self.selected_gr = idx
                self._gr_load_fields()
            elif 0 <= idx and idx < len(self.grammars):
                self.selected_gr = idx
            self.focus = _FOCUS_GR_LIST
            return True
        if self.selected_gr >= 0 and self._gr_lang_anchor.contains(event.pos):
            self.focus = _FOCUS_GR_LANG
            var hit = self.gr_lang_dropdown.handle_mouse(
                self._gr_lang_anchor, container_bounds, event,
            )
            if hit != DROPDOWN_HIT_NONE:
                self._gr_commit_lang()
            return True
        return True

    def _dispatch_buttons(mut self, event: Event) -> Bool:
        for i in range(len(self._buttons)):
            if not self._button_active_for_section(i):
                continue
            var status = self._buttons[i].button.handle_mouse(event)
            if status == BUTTON_NONE:
                continue
            if status == BUTTON_FIRED and self._buttons[i].enabled:
                self.focus = self._buttons[i].focus
                _ = self._activate_focus()
            return True
        return False

    def _button_active_for_section(self, idx: Int) -> Bool:
        if idx == _BTN_CLOSE:
            return True
        if self.section == _SECTION_ON_SAVE:
            return idx == _BTN_OS_ADD or idx == _BTN_OS_EDIT \
                or idx == _BTN_OS_REMOVE
        if self.section == _SECTION_TARGETS:
            return idx == _BTN_TG_ADD or idx == _BTN_TG_REMOVE
        if self.section == _SECTION_GRAMMARS:
            return idx == _BTN_GR_ADD or idx == _BTN_GR_REMOVE
        return False
