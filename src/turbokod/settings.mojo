"""Settings — the global preferences, as a tabbed dialog:

* **General** — save behavior, on-save whitespace fixes, line wrapping,
  the open-document cap, keyword-argument compression, caret blink;
* **Appearance** — theme, and on the native macOS frontend the font, its
  size and the look (classic or macOS-style UI), over a live preview;
* **Language Features** — the per-feature language-server gates;
* **Languages** — each language's server priority (``LanguageEditor`` on
  top for Add / Edit);
* **Spelling** — the downloadable dictionaries;
* **Projects** — the folders Quick open project lists.

Plain state plus a declarative UI (``ui`` / ``ui_set`` / ``ui_act``, see
``ui_tree.mojo``). In the terminal it's a dialog over the workspace; on
macOS it gets its own window — the grid projection in a cell window, or a
native window in the macOS-style UI — so the workspace stays visible while
a theme change retints it.

Edits commit immediately to the working copies (``self.auto_save`` etc).
The host syncs them back into ``TurbokodConfig`` while ``self.dirty`` is
set (``Desktop._sync_settings``) and writes the config to disk.
"""

from std.collections.list import List

from .config import (
    DEFAULT_MAX_OPEN_WINDOWS, LanguageServerOverride,
    MAX_FONT_SIZE, MIN_FONT_SIZE, WRAP_NONE,
)
from .dictionary_install import (
    DownloadableDictionary, built_in_downloadable_dictionaries,
    user_dictionary_installed,
)
from .language_config import (
    LanguageSpec, apply_language_overrides, built_in_servers,
    find_language_by_id, find_language_for_extension,
)
from .language_editor import LanguageEditor
from .theme import theme_names
from .ui_tree import (
    UI_DEFAULT, UI_DISABLED, UI_SECONDARY, UINode, ui_bool, ui_button,
    ui_buttons, ui_check, ui_choice, ui_dialog, ui_form, ui_hstack, ui_int,
    ui_label, ui_page, ui_preview, ui_row, ui_table, ui_tabs, ui_text,
    ui_vstack,
)


comptime SECTION_GENERAL    = 0
comptime SECTION_APPEARANCE = 1
comptime SECTION_FEATURES   = 2
comptime SECTION_LANGUAGES  = 3
comptime SECTION_SPELLING   = 4
comptime SECTION_PROJECTS   = 5


def _ls_keys() -> List[String]:
    """The Language Features checkboxes' keys, in display order."""
    return [
        String("ls_format_on_save"), String("ls_signature_help"),
        String("ls_document_highlight"), String("ls_document_links"),
        String("ls_inlay_hints"), String("ls_code_lens"),
        String("ls_document_colors"), String("ls_linked_editing"),
        String("ls_server_progress"),
    ]


def _ls_labels() -> List[String]:
    return [
        String("Format on save"),
        String("Signature help while typing"),
        String("Highlight occurrences of the symbol at the caret"),
        String("Clickable links in documents"),
        String("Inlay hints (inline types and parameter names)"),
        String("Code lens (actionable annotations)"),
        String("Color swatches"),
        String("Linked editing (rename matching tags together)"),
        String("Show language-server progress"),
    ]


def _digits(text: String, max_len: Int) -> String:
    """The leading ``max_len`` digits of ``text`` — what a numeric field
    keeps of a paste or a stray character."""
    var bytes = text.as_bytes()
    var out = String("")
    for i in range(len(bytes)):
        var b = bytes[i]
        if b >= UInt8(0x30) and b <= UInt8(0x39) and len(out.as_bytes()) < max_len:
            out += chr(Int(b))
    return out^


def _parse_digits(text: String, empty: Int) -> Int:
    var bytes = text.as_bytes()
    if len(bytes) == 0:
        return empty
    var v = 0
    for i in range(len(bytes)):
        var d = Int(bytes[i]) - 0x30
        if d < 0 or d > 9:
            return empty
        v = v * 10 + d
    return v


struct Settings(Movable):
    var active: Bool
    var dirty: Bool
    """Set when a setting has been mutated. The host applies and writes
    ``TurbokodConfig``; ``ack_dirty`` clears it."""
    var close_requested: Bool
    """Close was pressed; the host syncs the last edits, then closes."""
    var section: Int

    # General.
    var auto_save: Bool
    var wrap_mode: Int
    """``WRAP_NONE`` / ``WRAP_SOFT`` / ``WRAP_SMART``."""
    var trim_trailing_whitespace: Bool
    var ensure_final_newline: Bool
    var compress_kwargs: Bool
    var cursor_blink: Bool
    var comma_text: String
    """Smart wrap's comma trigger as typed: digits, empty = off."""
    var max_windows_text: String
    """The open-document cap as typed: digits, empty = no limit."""

    # Language Features.
    var ls_format_on_save: Bool
    var ls_signature_help: Bool
    var ls_document_highlight: Bool
    var ls_document_links: Bool
    var ls_inlay_hints: Bool
    var ls_code_lens: Bool
    var ls_document_colors: Bool
    var ls_linked_editing: Bool
    var ls_server_progress: Bool

    # Appearance.
    var theme_choice: String
    var _theme_names: List[String]
    var font_choice: String
    var _font_names: List[String]
    """Host-provided font labels (the two built-in fonts first, then the
    system's monospace families). Empty on the terminal frontend, where
    the terminal owns the font."""
    var font_size_choice: Int
    """0 means the font's default size."""
    var _font_effective_size: Int
    """The size actually rendering (resolves 0); reported by the host."""
    var _font_ideal_size: Int
    """The active font's design size, 0 when unknown; reported by the host."""
    var offer_native_ui: Bool
    """The host can show the macOS-style UI (the native macOS frontend)."""
    var native_ui: Bool
    var palette_version: Int
    """Bumped by the host when the palette changes, so the preview repaints."""

    # Languages.
    var language_overrides: List[LanguageServerOverride]
    """Working copy of ``TurbokodConfig.language_servers``."""
    var languages_view: List[LanguageSpec]
    """Built-in languages with the overrides applied — what the list shows."""
    var selected_language: Int
    var language_editor: LanguageEditor

    # Spelling.
    var dict_specs: List[DownloadableDictionary]
    var selected_dict: Int
    var pending_dict_install_lang: String
    """When non-empty, the host starts installing this dictionary (and
    clears it with ``ack_dict_install``)."""
    var pending_dict_remove_lang: String

    # Projects.
    var project_dirs: List[String]
    var selected_project_dir: Int
    var project_input: String

    def __init__(out self):
        self.active = False
        self.dirty = False
        self.close_requested = False
        self.section = SECTION_GENERAL
        self.auto_save = False
        self.wrap_mode = WRAP_NONE
        self.trim_trailing_whitespace = False
        self.ensure_final_newline = False
        self.compress_kwargs = False
        self.cursor_blink = False
        self.comma_text = String("")
        self.max_windows_text = String("")
        self.ls_format_on_save = False
        self.ls_signature_help = False
        self.ls_document_highlight = False
        self.ls_document_links = False
        self.ls_inlay_hints = False
        self.ls_code_lens = False
        self.ls_document_colors = False
        self.ls_linked_editing = False
        self.ls_server_progress = False
        self.theme_choice = String("Turbo C++ 3.0")
        self._theme_names = theme_names()
        self.font_choice = String("")
        self._font_names = List[String]()
        self.font_size_choice = 0
        self._font_effective_size = 0
        self._font_ideal_size = 0
        self.offer_native_ui = False
        self.native_ui = False
        self.palette_version = 0
        self.language_overrides = List[LanguageServerOverride]()
        self.languages_view = List[LanguageSpec]()
        self.selected_language = -1
        self.language_editor = LanguageEditor()
        self.dict_specs = List[DownloadableDictionary]()
        self.selected_dict = -1
        self.pending_dict_install_lang = String("")
        self.pending_dict_remove_lang = String("")
        self.project_dirs = List[String]()
        self.selected_project_dir = -1
        self.project_input = String("")

    def open(
        mut self, auto_save: Bool,
        var language_overrides: List[LanguageServerOverride] = List[LanguageServerOverride](),
        current_language_ext: String = String(""),
        trim_trailing_whitespace: Bool = True,
        ensure_final_newline: Bool = True,
        compress_kwargs: Bool = False,
        theme: String = String("Turbo C++ 3.0"),
        font: String = String(""),
        var font_names: List[String] = List[String](),
        font_size: Int = 0,
        font_effective_size: Int = 0,
        font_ideal_size: Int = 0,
        wrap_mode: Int = WRAP_NONE,
        comma_threshold: Int = -1,
        max_open_windows: Int = DEFAULT_MAX_OPEN_WINDOWS,
        cursor_blink: Bool = True,
        ls_format_on_save: Bool = False,
        ls_signature_help: Bool = True,
        ls_document_highlight: Bool = True,
        ls_document_links: Bool = False,
        ls_inlay_hints: Bool = False,
        ls_code_lens: Bool = False,
        ls_document_colors: Bool = False,
        ls_linked_editing: Bool = False,
        ls_server_progress: Bool = True,
        var project_dirs: List[String] = List[String](),
    ):
        self = Settings()
        self.active = True
        self.auto_save = auto_save
        self.trim_trailing_whitespace = trim_trailing_whitespace
        self.ensure_final_newline = ensure_final_newline
        self.compress_kwargs = compress_kwargs
        self.cursor_blink = cursor_blink
        self.wrap_mode = wrap_mode
        self.comma_text = String("") if comma_threshold < 0 else String(comma_threshold)
        self.max_windows_text = String("") if max_open_windows <= 0 \
            else String(max_open_windows)
        self.ls_format_on_save = ls_format_on_save
        self.ls_signature_help = ls_signature_help
        self.ls_document_highlight = ls_document_highlight
        self.ls_document_links = ls_document_links
        self.ls_inlay_hints = ls_inlay_hints
        self.ls_code_lens = ls_code_lens
        self.ls_document_colors = ls_document_colors
        self.ls_linked_editing = ls_linked_editing
        self.ls_server_progress = ls_server_progress
        self.theme_choice = theme
        self.font_choice = font
        self._font_names = font_names^
        self.font_size_choice = font_size
        self._font_effective_size = font_effective_size
        self._font_ideal_size = font_ideal_size
        self.language_overrides = language_overrides^
        self._rebuild_languages_view()
        # Open Languages on the focused editor's language: the row the
        # user most likely came to change.
        var lang_idx = -1
        if len(current_language_ext.as_bytes()) > 0:
            lang_idx = find_language_for_extension(
                self.languages_view, current_language_ext,
            )
        if lang_idx < 0 and len(self.languages_view) > 0:
            lang_idx = 0
        self.selected_language = lang_idx
        self.dict_specs = built_in_downloadable_dictionaries()
        self.selected_dict = 0 if len(self.dict_specs) > 0 else -1
        self.project_dirs = project_dirs^
        self.selected_project_dir = 0 if len(self.project_dirs) > 0 else -1

    def close(mut self):
        self = Settings()

    def update_font_info(mut self, effective: Int, ideal: Int):
        """The host reports the live effective / ideal sizes every frame (a
        family change moves both, a frame after it's applied). Display
        only; never dirties."""
        self._font_effective_size = effective
        self._font_ideal_size = ideal

    def ack_dirty(mut self):
        self.dirty = False

    def ack_dict_install(mut self):
        self.pending_dict_install_lang = String("")

    def ack_dict_remove(mut self):
        self.pending_dict_remove_lang = String("")

    def font_names(self) -> List[String]:
        return self._font_names.copy()

    def comma_threshold_value(self) -> Int:
        """Smart wrap's comma trigger: -1 when the field is empty (off)."""
        return _parse_digits(self.comma_text, -1)

    def max_open_windows_value(self) -> Int:
        """The open-document cap: 0 when the field is empty (no limit)."""
        return _parse_digits(self.max_windows_text, 0)

    # --- declarative UI -------------------------------------------------

    def ui(self) -> UINode:
        var pages = List[UINode]()
        pages.append(ui_page(String("General"), self._general_ui()))
        pages.append(ui_page(String("Appearance"), self._appearance_ui()))
        pages.append(ui_page(String("LSP Features"), self._features_ui()))
        pages.append(ui_page(String("Languages"), self._languages_ui()))
        pages.append(ui_page(String("Spelling"), self._spelling_ui()))
        pages.append(ui_page(String("Projects"), self._projects_ui()))
        var buttons = List[UINode]()
        buttons.append(ui_button(String("close"), String("Close"), UI_DEFAULT))
        var body = List[UINode]()
        body.append(ui_tabs(String("section"), self.section, pages^))
        body.append(ui_buttons(buttons^))
        return ui_dialog(String("Settings"), String("close"), ui_vstack(body^))

    def _general_ui(self) -> UINode:
        var rows = List[UINode]()
        rows.append(ui_row(String("Saving"), ui_choice(
            String("auto_save"), [String("Manual"), String("Automatic")],
            1 if self.auto_save else 0,
        )))
        rows.append(ui_row(String(""), ui_check(
            String("trim_trailing_whitespace"),
            String("Trim trailing whitespace on save"),
            self.trim_trailing_whitespace,
        )))
        rows.append(ui_row(String(""), ui_check(
            String("ensure_final_newline"),
            String("Ensure a final newline on save"), self.ensure_final_newline,
        )))
        rows.append(ui_row(String("Line wrapping"), ui_choice(
            String("wrap_mode"),
            [String("None"), String("Soft"), String("Smart")], self.wrap_mode,
        )))
        rows.append(ui_row(String("Smart wrap at commas"), ui_text(
            String("comma_threshold"), self.comma_text, String("Off"), width=8,
        )))
        rows.append(ui_row(String("Open documents"), ui_text(
            String("max_open_windows"), self.max_windows_text, String("No limit"),
            width=8,
        )))
        rows.append(ui_row(String(""), ui_check(
            String("compress_kwargs"), String("Compress keyword arguments"),
            self.compress_kwargs,
        )))
        rows.append(ui_row(String(""), ui_check(
            String("cursor_blink"), String("Blinking caret"), self.cursor_blink,
        )))
        return ui_form(rows^)

    def _font_size_shown(self) -> Int:
        if self.font_size_choice > 0:
            return self.font_size_choice
        if self._font_effective_size > 0:
            return self._font_effective_size
        return 16

    def _appearance_ui(self) -> UINode:
        var rows = List[UINode]()
        if self.offer_native_ui:
            rows.append(ui_row(String(""), ui_check(
                String("native_ui"),
                String("macOS-style UI (native tabs, sheets and pickers)"),
                self.native_ui,
            )))
        var theme = 0
        for i in range(len(self._theme_names)):
            if self._theme_names[i] == self.theme_choice:
                theme = i
        rows.append(ui_row(String("Theme"), ui_choice(
            String("theme"), self._theme_names.copy(), theme,
        )))
        var builtins = List[String]()
        if len(self._font_names) > 0:
            var font = 0
            for i in range(len(self._font_names)):
                if self._font_names[i] == self.font_choice:
                    font = i
            rows.append(ui_row(String("Font"), ui_choice(
                String("font"), self._font_names.copy(), font,
            )))
            var size = self._font_size_shown()
            var ideal = self._font_ideal_size
            var steps = List[UINode]()
            steps.append(ui_label(String(size) + String(" pt")))
            steps.append(ui_button(
                String("font_smaller"), String("Smaller"),
                0 if size > MIN_FONT_SIZE else UI_DISABLED,
            ))
            steps.append(ui_button(
                String("font_larger"), String("Larger"),
                0 if size < MAX_FONT_SIZE else UI_DISABLED,
            ))
            steps.append(ui_button(
                String("font_ideal"), String("Ideal Size"),
                0 if ideal > 0 and ideal != size else UI_DISABLED,
            ))
            rows.append(ui_row(String("Size"), ui_hstack(steps^)))
            for i in range(min(2, len(self._font_names))):
                builtins.append(self._font_names[i])
        rows.append(ui_row(String(""), ui_preview(
            self.font_choice, self.font_size_choice, builtins^,
            String(self.palette_version),
        )))
        return ui_form(rows^)

    def _features_ui(self) -> UINode:
        var keys = _ls_keys()
        var labels = _ls_labels()
        var rows = List[UINode]()
        for i in range(len(keys)):
            rows.append(ui_check(keys[i], labels[i], self._ls_get(keys[i])))
        return ui_vstack(rows^)

    def _languages_ui(self) -> UINode:
        var rows = List[List[String]]()
        for i in range(len(self.languages_view)):
            ref spec = self.languages_view[i]
            var servers = String("")
            for j in range(len(spec.candidates)):
                if j > 0:
                    servers += String(", ")
                servers += _join_argv(spec.candidates[j].argv)
            rows.append([
                spec.language_id
                    + (String(" *") if _has_override(self.language_overrides, spec.language_id)
                       else String("")),
                String(" ").join(spec.file_types),
                servers,
            ])
        var has = self.selected_language >= 0 \
            and self.selected_language < len(self.languages_view)
        var custom = has and _has_override(
            self.language_overrides, self.languages_view[self.selected_language].language_id,
        )
        var buttons = List[UINode]()
        buttons.append(ui_button(String("lang_add"), String("Add…")))
        buttons.append(ui_button(String("lang_edit"), String("Edit…"), 0 if has else UI_DISABLED))
        buttons.append(ui_button(
            String("lang_remove"), String("Restore Default"), 0 if custom else UI_DISABLED,
        ))
        var body = List[UINode]()
        body.append(ui_label(
            String("Language servers per language, highest priority first. * marks your changes."),
            UI_SECONDARY,
        ))
        body.append(ui_table(
            String("languages"),
            [String("Language"), String("File types"), String("Servers")],
            rows^, self.selected_language, String("lang_edit"), 8,
        ))
        body.append(ui_hstack(buttons^))
        return ui_vstack(body^)

    def _spelling_ui(self) -> UINode:
        var rows = List[List[String]]()
        var sel_installed = False
        for i in range(len(self.dict_specs)):
            var installed = user_dictionary_installed(self.dict_specs[i].language_id)
            if i == self.selected_dict:
                sel_installed = installed
            rows.append([
                self.dict_specs[i].display, self.dict_specs[i].language_id,
                String("Installed") if installed else String(""),
            ])
        var has = self.selected_dict >= 0 and self.selected_dict < len(self.dict_specs)
        var buttons = List[UINode]()
        buttons.append(ui_button(
            String("dict_install"), String("Install"),
            0 if has and not sel_installed else UI_DISABLED,
        ))
        buttons.append(ui_button(
            String("dict_remove"), String("Remove"),
            0 if has and sel_installed else UI_DISABLED,
        ))
        var body = List[UINode]()
        body.append(ui_label(
            String("English is built in. Install a dictionary to spell-check another language."),
            UI_SECONDARY,
        ))
        body.append(ui_table(
            String("dictionaries"),
            [String("Language"), String("Code"), String("Status")],
            rows^, self.selected_dict, String(""), 8,
        ))
        body.append(ui_hstack(buttons^))
        return ui_vstack(body^)

    def _projects_ui(self) -> UINode:
        var rows = List[List[String]]()
        for i in range(len(self.project_dirs)):
            rows.append([self.project_dirs[i]])
        var has = self.selected_project_dir >= 0 \
            and self.selected_project_dir < len(self.project_dirs)
        var add = List[UINode]()
        add.append(ui_row(String("Folder"), ui_text(
            String("project_input"), self.project_input, String("~/Projects"),
        )))
        var add_row = List[UINode]()
        add_row.append(ui_form(add^))
        add_row.append(ui_button(
            String("proj_add"), String("Add"),
            0 if len(String(self.project_input.strip()).as_bytes()) > 0 else UI_DISABLED,
        ))
        var buttons = List[UINode]()
        buttons.append(ui_button(String("proj_remove"), String("Remove"), 0 if has else UI_DISABLED))
        var body = List[UINode]()
        body.append(ui_label(
            String("Folders whose subfolders Quick open project lists."),
            UI_SECONDARY,
        ))
        body.append(ui_table(
            String("projects"), [String("Folder")], rows^,
            self.selected_project_dir, String(""), 8,
        ))
        body.append(ui_hstack(buttons^))
        body.append(ui_hstack(add_row^))
        return ui_vstack(body^)

    def ui_set(mut self, key: String, value: String):
        if key == String("section"):
            var s = ui_int(value, self.section)
            if s >= 0 and s <= SECTION_PROJECTS:
                self.section = s
            return
        if key == String("languages"):
            var s = ui_int(value, self.selected_language)
            if s >= 0 and s < len(self.languages_view):
                self.selected_language = s
            return
        if key == String("dictionaries"):
            var s = ui_int(value, self.selected_dict)
            if s >= 0 and s < len(self.dict_specs):
                self.selected_dict = s
            return
        if key == String("projects"):
            var s = ui_int(value, self.selected_project_dir)
            if s >= 0 and s < len(self.project_dirs):
                self.selected_project_dir = s
            return
        if key == String("project_input"):
            self.project_input = value
            return
        # Everything below is a setting.
        if key == String("auto_save"):
            self.auto_save = ui_int(value) == 1
        elif key == String("wrap_mode"):
            var w = ui_int(value, self.wrap_mode)
            if w >= 0 and w <= 2:
                self.wrap_mode = w
        elif key == String("comma_threshold"):
            self.comma_text = _digits(value, 3)
        elif key == String("max_open_windows"):
            self.max_windows_text = _digits(value, 4)
        elif key == String("trim_trailing_whitespace"):
            self.trim_trailing_whitespace = ui_bool(value)
        elif key == String("ensure_final_newline"):
            self.ensure_final_newline = ui_bool(value)
        elif key == String("compress_kwargs"):
            self.compress_kwargs = ui_bool(value)
        elif key == String("cursor_blink"):
            self.cursor_blink = ui_bool(value)
        elif key == String("native_ui"):
            self.native_ui = ui_bool(value)
        elif key == String("theme"):
            var i = ui_int(value)
            if i < 0 or i >= len(self._theme_names):
                return
            self.theme_choice = self._theme_names[i]
        elif key == String("font"):
            var i = ui_int(value)
            if i < 0 or i >= len(self._font_names):
                return
            self.font_choice = self._font_names[i]
        elif not self._ls_set(key, ui_bool(value)):
            return
        self.dirty = True

    def ui_act(mut self, id: String):
        if id == String("close"):
            self.close_requested = True
        elif id == String("font_smaller"):
            self._set_font_size(self._font_size_shown() - 1)
        elif id == String("font_larger"):
            self._set_font_size(self._font_size_shown() + 1)
        elif id == String("font_ideal"):
            if self._font_ideal_size > 0:
                self._set_font_size(self._font_ideal_size)
        elif id == String("lang_add"):
            self.language_editor.open(String(""), List[String](), List[String](), False)
        elif id == String("lang_edit"):
            self._edit_language()
        elif id == String("lang_remove"):
            self._remove_language_override()
        elif id == String("dict_install"):
            self._request_dict(True)
        elif id == String("dict_remove"):
            self._request_dict(False)
        elif id == String("proj_add"):
            self._add_project_dir()
        elif id == String("proj_remove"):
            self._remove_project_dir()

    def _ls_get(self, key: String) -> Bool:
        if key == String("ls_format_on_save"): return self.ls_format_on_save
        if key == String("ls_signature_help"): return self.ls_signature_help
        if key == String("ls_document_highlight"): return self.ls_document_highlight
        if key == String("ls_document_links"): return self.ls_document_links
        if key == String("ls_inlay_hints"): return self.ls_inlay_hints
        if key == String("ls_code_lens"): return self.ls_code_lens
        if key == String("ls_document_colors"): return self.ls_document_colors
        if key == String("ls_linked_editing"): return self.ls_linked_editing
        return self.ls_server_progress

    def _ls_set(mut self, key: String, on: Bool) -> Bool:
        """Set language-feature gate ``key``; False when it isn't one."""
        if key == String("ls_format_on_save"): self.ls_format_on_save = on
        elif key == String("ls_signature_help"): self.ls_signature_help = on
        elif key == String("ls_document_highlight"): self.ls_document_highlight = on
        elif key == String("ls_document_links"): self.ls_document_links = on
        elif key == String("ls_inlay_hints"): self.ls_inlay_hints = on
        elif key == String("ls_code_lens"): self.ls_code_lens = on
        elif key == String("ls_document_colors"): self.ls_document_colors = on
        elif key == String("ls_linked_editing"): self.ls_linked_editing = on
        elif key == String("ls_server_progress"): self.ls_server_progress = on
        else:
            return False
        return True

    def _set_font_size(mut self, size: Int):
        var s = max(MIN_FONT_SIZE, min(size, MAX_FONT_SIZE))
        if s != self.font_size_choice:
            self.font_size_choice = s
            self.dirty = True

    # --- languages -------------------------------------------------------

    def _rebuild_languages_view(mut self):
        self.languages_view = apply_language_overrides(
            built_in_servers(), self.language_overrides,
        )

    def _edit_language(mut self):
        if self.selected_language < 0 \
                or self.selected_language >= len(self.languages_view):
            return
        ref spec = self.languages_view[self.selected_language]
        var argvs = List[String]()
        for i in range(len(spec.candidates)):
            argvs.append(_join_argv(spec.candidates[i].argv))
        var is_existing = find_language_by_id(
            built_in_servers(), spec.language_id,
        ) >= 0
        self.language_editor.open(
            spec.language_id, spec.file_types, argvs^, is_existing,
        )

    def _remove_language_override(mut self):
        """Drop the user's override for the selected language: back to the
        built-in servers, or gone if the user added it."""
        if self.selected_language < 0 \
                or self.selected_language >= len(self.languages_view):
            return
        var id = self.languages_view[self.selected_language].language_id
        var rebuilt = List[LanguageServerOverride]()
        for i in range(len(self.language_overrides)):
            if self.language_overrides[i].language_id != id:
                rebuilt.append(self.language_overrides[i].copy())
        self.language_overrides = rebuilt^
        self.dirty = True
        self._rebuild_languages_view()
        if self.selected_language >= len(self.languages_view):
            self.selected_language = len(self.languages_view) - 1

    def consume_language_editor(mut self):
        """Store the language editor's result once it was saved."""
        if not self.language_editor.submitted:
            return
        var entry = self.language_editor.value()
        self.language_editor.close()
        if len(entry.language_id.as_bytes()) == 0:
            return
        var rebuilt = List[LanguageServerOverride]()
        var replaced = False
        for i in range(len(self.language_overrides)):
            if self.language_overrides[i].language_id == entry.language_id:
                rebuilt.append(entry.copy())
                replaced = True
            else:
                rebuilt.append(self.language_overrides[i].copy())
        if not replaced:
            rebuilt.append(entry.copy())
        self.language_overrides = rebuilt^
        self.dirty = True
        self._rebuild_languages_view()
        for i in range(len(self.languages_view)):
            if self.languages_view[i].language_id == entry.language_id:
                self.selected_language = i
                break

    # --- spelling --------------------------------------------------------

    def _request_dict(mut self, install: Bool):
        """Queue an install / remove of the selected dictionary for the
        host — only when it would change something."""
        if self.selected_dict < 0 or self.selected_dict >= len(self.dict_specs):
            return
        var lang = self.dict_specs[self.selected_dict].language_id
        var installed = user_dictionary_installed(lang)
        if install and not installed:
            self.pending_dict_install_lang = lang
        elif not install and installed:
            self.pending_dict_remove_lang = lang

    # --- projects --------------------------------------------------------

    def _add_project_dir(mut self):
        """Append the typed folder (trailing slashes dropped, duplicates
        ignored) and clear the field."""
        var t = String(self.project_input.strip())
        var b = t.as_bytes()
        var n = len(b)
        while n > 1 and b[n - 1] == 0x2F:
            n -= 1
        if n == 0:
            return
        var path = String(StringSpan(unsafe_from_utf8=b[:n]))
        self.project_input = String("")
        for i in range(len(self.project_dirs)):
            if self.project_dirs[i] == path:
                self.selected_project_dir = i
                return
        self.project_dirs.append(path^)
        self.selected_project_dir = len(self.project_dirs) - 1
        self.dirty = True

    def _remove_project_dir(mut self):
        if self.selected_project_dir < 0 \
                or self.selected_project_dir >= len(self.project_dirs):
            return
        _ = self.project_dirs.pop(self.selected_project_dir)
        if self.selected_project_dir >= len(self.project_dirs):
            self.selected_project_dir = len(self.project_dirs) - 1
        self.dirty = True


# --- helpers --------------------------------------------------------------


def _has_override(
    overrides: List[LanguageServerOverride], language_id: String,
) -> Bool:
    for i in range(len(overrides)):
        if overrides[i].language_id == language_id:
            return True
    return False


def _join_argv(argv: List[String]) -> String:
    """Round-trip-safe join: wrap tokens with shell-significant
    characters (spaces, tabs, or pre-existing quotes) in double quotes
    so the re-parser in ``language_editor._split_space`` reconstructs
    the same argv. Without the re-quoting, editing a saved
    ``--ty-command "/path/to/ty server"`` would silently lose the
    grouping the next time the dialog opened.
    """
    var out = String("")
    for i in range(len(argv)):
        if i > 0:
            out = out + String(" ")
        out = out + _shell_quote(argv[i])
    return out^


def _shell_quote(s: String) -> String:
    """Return ``s`` unchanged when it contains no shell-significant
    bytes; otherwise wrap it in double quotes with embedded ``"`` and
    ``\\`` escaped. Single quotes are passed through inside ``"…"``
    so they don't need their own handling. Empty input is rendered as
    ``""`` so it survives a re-split as a real (empty) token rather
    than getting dropped."""
    var b = s.as_bytes()
    if len(b) == 0:
        return String("\"\"")
    var needs_quote = False
    for i in range(len(b)):
        var c = b[i]
        if c == 0x20 or c == 0x09 or c == 0x22 or c == 0x27 \
                or c == 0x5C:
            needs_quote = True
            break
    if not needs_quote:
        return s
    var buf = List[UInt8]()
    buf.append(0x22)  # opening "
    for i in range(len(b)):
        var c = b[i]
        if c == 0x22 or c == 0x5C:
            buf.append(0x5C)
        buf.append(c)
    buf.append(0x22)  # closing "
    return String(StringSpan(unsafe_from_utf8=Span(unsafe_ptr=buf.unsafe_ptr(), length=len(buf))))


