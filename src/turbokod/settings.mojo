"""Fullscreen Settings view.

Activated from the hamburger menu. Layout::

    ╔══ Settings ══════════════════════════════════════════════════════╗
    ║ ┌────────────────┐ Actions on save                               ║
    ║ │ Actions on save│ ┌─────────────────────────────────────────┐   ║
    ║ │ Editor         │ │ python  /usr/local/bin/black --quiet $F │   ║
    ║ │                │ │ rust    /usr/local/bin/rustfmt          │   ║
    ║ │                │ └─────────────────────────────────────────┘   ║
    ║ │                │ [+ Add] [✎ Edit] [- Remove]                   ║
    ║ │                │                                               ║
    ║ └────────────────┘                                               ║
    ║                                                                  ║
    ║                                              [ Close ]           ║
    ╚══════════════════════════════════════════════════════════════════╝

Sections live in a left-rail list. The right pane changes per
section. Adding a new section is two entries (a string label in
``_section_labels`` and a ``_paint_section_*`` arm).

Edits commit immediately to ``self.actions`` / ``self.auto_save``.
The host syncs them back into ``TurbokodConfig`` on every paint when
``self.dirty`` is True and writes the updated config to disk.

The view *takes over the workspace* but doesn't repaint the menu bar
or status bar — the host keeps painting those above and below so the
user can still see context. Esc closes (same as the [Close] button).
"""

from std.collections.list import List
from std.collections.optional import Optional

from .action_editor import ActionEditor
from .buttons import (
    BUTTON_FIRED, BUTTON_NONE, Checkbox, ShadowButton,
    paint_checkbox, paint_shadow_button,
)
from .canvas import Canvas, paint_drop_shadow
from .painter import Painter
from .cell import Cell
from .colors import (
    Attr, BLACK, BLUE, BORDER_FOCUS, CYAN, DARK_GRAY, GREEN, LIGHT_GRAY, RED,
    WHITE, EDITOR_BG, EDITOR_FG, SYN_KEYWORD, SYN_STRING, SYN_COMMENT,
    SYN_NUMBER, SYN_IDENT,
)
from .theme import theme_names
from .config import (
    LanguageServerOverride, MAX_FONT_SIZE, MIN_FONT_SIZE, OnSaveAction,
    WRAP_NONE,
)
from .dictionary_install import (
    DownloadableDictionary, built_in_downloadable_dictionaries,
    user_dictionary_installed,
)
from .language_config import (
    LanguageSpec, ServerCandidate, apply_language_overrides,
    built_in_servers, find_language_by_id, find_language_for_extension,
)
from .language_editor import LanguageEditor
from .dropdown import (
    DROPDOWN_HIT_BODY, DROPDOWN_HIT_NONE, DROPDOWN_HIT_OUTSIDE,
    DROPDOWN_HIT_POPUP, Dropdown,
)
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_BACKSPACE, KEY_DOWN, KEY_ENTER, KEY_ESC, KEY_SPACE, KEY_TAB, KEY_UP,
    MOD_NONE, MOD_SHIFT, MOUSE_BUTTON_LEFT,
    MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .geometry import Point, Rect
from .string_utils import display_columns
from .type_ahead import TypeAhead, is_printable_ascii, type_ahead_pick
from .window import paint_window_title


# --- focus discriminants --------------------------------------------------

comptime _FOCUS_SECTIONS      = UInt8(0)
comptime _FOCUS_LIST          = UInt8(1)
comptime _FOCUS_ADD           = UInt8(2)
comptime _FOCUS_EDIT          = UInt8(3)
comptime _FOCUS_REMOVE        = UInt8(4)
comptime _FOCUS_CLOSE         = UInt8(5)
comptime _FOCUS_SAVE_BEHAVIOR = UInt8(6)
comptime _FOCUS_TRIM_WS       = UInt8(14)
comptime _FOCUS_FINAL_NL      = UInt8(15)
comptime _FOCUS_DICT_LIST     = UInt8(7)
comptime _FOCUS_DICT_INSTALL  = UInt8(8)
comptime _FOCUS_DICT_REMOVE   = UInt8(9)
comptime _FOCUS_LANG_LIST     = UInt8(10)
comptime _FOCUS_LANG_ADD      = UInt8(11)
comptime _FOCUS_LANG_EDIT     = UInt8(12)
comptime _FOCUS_LANG_REMOVE   = UInt8(13)
comptime _FOCUS_THEME_LIST    = UInt8(16)
comptime _FOCUS_FONT_LIST     = UInt8(17)
comptime _FOCUS_FONT_SMALLER  = UInt8(18)
comptime _FOCUS_FONT_LARGER   = UInt8(19)
comptime _FOCUS_FONT_IDEAL    = UInt8(20)
comptime _FOCUS_WRAP_MODE     = UInt8(21)
comptime _FOCUS_COMPRESS_KW   = UInt8(22)
comptime _FOCUS_COMMA_WRAP    = UInt8(23)
comptime _FOCUS_BLINK_CURSOR  = UInt8(24)


# --- section indices ------------------------------------------------------

comptime _SECTION_ACTIONS   = 0
comptime _SECTION_EDITOR    = 1
comptime _SECTION_SPELL     = 2
comptime _SECTION_LANGUAGES = 3
comptime _SECTION_THEME     = 4
comptime _SECTION_FONT      = 5


# --- layout ---------------------------------------------------------------

comptime _SECTION_W = 22

# Minimum in-grid dialog size (terminal frontend). Wide enough for the left
# rail plus a usable right pane; tall enough for the section lists.
comptime _SETTINGS_MIN_W = 64
comptime _SETTINGS_MIN_H = 16


# --- button table indices -------------------------------------------------
# ``Settings._buttons`` is a flat list rather than per-section sublists so
# the press latches survive across paints and section switches. The names
# below are the canonical mapping; callers should not hand-write the ints.

comptime _BTN_ADD          = 0
comptime _BTN_EDIT         = 1
comptime _BTN_REMOVE       = 2
comptime _BTN_CLOSE        = 3
comptime _BTN_DICT_INSTALL = 4
comptime _BTN_DICT_REMOVE  = 5
comptime _BTN_LANG_ADD     = 6
comptime _BTN_LANG_EDIT    = 7
comptime _BTN_LANG_REMOVE  = 8
comptime _BTN_FONT_SMALLER = 9
comptime _BTN_FONT_LARGER  = 10
comptime _BTN_FONT_IDEAL   = 11

# Width of the inline dropdown strip in the Editor section. Wide enough
# for "Automatic" plus the right-edge ``▼`` indicator.
comptime _SAVE_DD_W = 16


def _section_labels(include_font: Bool) -> List[String]:
    """Section names rendered in the left rail. Add new section names
    here and a matching ``_paint_section_*`` / ``_handle_*`` branch
    below; nothing else needs to change. ``Font`` only exists when the
    host registered font options (the native macOS frontend) — the
    terminal emulator owns the font on the terminal frontend."""
    var out = List[String]()
    out.append(String("Actions on save"))
    out.append(String("Editor"))
    out.append(String("Spell check"))
    out.append(String("Languages"))
    out.append(String("Theme"))
    if include_font:
        out.append(String("Font"))
    return out^


def _save_behavior_options() -> List[String]:
    """Dropdown options for the Editor ▸ Save behavior picker. Order
    here is the order rendered in the popup; index 0 is the default
    when no value is committed."""
    var out = List[String]()
    out.append(String("Manual"))
    out.append(String("Automatic"))
    return out^


def _wrap_mode_options() -> List[String]:
    """Dropdown options for the Editor ▸ Wrap picker. Index order is in
    lock-step with the ``WRAP_NONE`` / ``WRAP_SOFT`` / ``WRAP_SMART``
    constants (0 / 1 / 2)."""
    var out = List[String]()
    out.append(String("No wrap"))
    out.append(String("Soft wrap"))
    out.append(String("Smart wrap"))
    return out^


@fieldwise_init
struct _PlacedButton(ImplicitlyCopyable, Movable):
    var button: ShadowButton
    var focus: UInt8
    var enabled: Bool


# --- Settings -------------------------------------------------------------


struct Settings(Movable):
    var active: Bool
    var dirty: Bool
    """Set when ``actions`` or ``auto_save`` has been mutated. Host
    watches this flag and writes ``TurbokodConfig`` to disk;
    ``ack_dirty`` clears it after a successful write."""
    var actions: List[OnSaveAction]
    """Working copy of the on-save actions. Host snapshots into this
    on ``open``; mutations are immediate (no per-edit commit step).
    """
    var auto_save: Bool
    """Working copy of ``TurbokodConfig.auto_save`` — Editor ▸ Save
    behavior. ``False`` means Manual (Ctrl+S only), ``True`` means
    Automatic. Driven by ``_save_dropdown``."""
    var wrap_mode: Int
    """Working copy of ``TurbokodConfig.wrap_mode`` — Editor ▸ Wrap
    (``WRAP_NONE`` / ``WRAP_SOFT`` / ``WRAP_SMART``). Driven by
    ``_wrap_dropdown``; the host applies + persists it on the next config
    sync when it differs from ``config.wrap_mode``."""
    var trim_trailing_whitespace: Bool
    """Working copy of ``TurbokodConfig.trim_trailing_whitespace`` —
    Editor ▸ "Trim trailing whitespace". Driven by ``_trim_cb``."""
    var ensure_final_newline: Bool
    """Working copy of ``TurbokodConfig.ensure_final_newline`` — Editor
    ▸ "Ensure newline at end of files". Driven by ``_final_nl_cb``."""
    var compress_kwargs: Bool
    """Working copy of ``TurbokodConfig.compress_kwargs`` — Editor ▸
    "Compress keyword arguments". Driven by ``_compress_cb``."""
    var cursor_blink: Bool
    """Working copy of ``TurbokodConfig.cursor_blink`` — Editor ▸
    "Blinking cursor". Driven by ``_blink_cb``."""
    var section: Int
    """Index into ``_section_labels`` for the active section."""
    var selected_action: Int
    """Row in ``actions`` that's highlighted in the right pane."""
    var focus: UInt8
    var editor: ActionEditor
    var _list_scroll: Int
    var _last_scroll_action: Int
    """Last ``selected_action`` value snapped into view by paint. The
    actions-list paint only scrolls to the selection when this differs
    from ``selected_action`` — so wheel-scrolling moves the viewport
    independently and isn't snapped back on the next frame."""
    var _last_scroll_dict: Int
    """Counterpart for ``selected_dict``."""
    var _last_scroll_language: Int
    """Counterpart for ``selected_language``."""
    var _buttons: List[_PlacedButton]
    """Persistent button table — Add / Edit / Remove / Close, in order."""
    var _save_dropdown: Dropdown
    """Stateful Save-behavior picker. Index is in lock-step with
    ``auto_save`` (0 = Manual, 1 = Automatic) and the popup state
    persists across paints so a click on the strip can show the
    popup on the next refresh."""
    var _save_dd_anchor: Rect
    """Last-painted bounds of the dropdown strip. Cached so mouse
    events arriving between paints can hit-test against the same
    rectangle the user just clicked."""
    var _wrap_dropdown: Dropdown
    """Stateful Wrap-mode picker. Index is in lock-step with
    ``wrap_mode`` (0 = No wrap, 1 = Soft wrap, 2 = Smart wrap)."""
    var _wrap_dd_anchor: Rect
    """Last-painted bounds of the Wrap dropdown strip (mouse hit-test
    cache, mirrors ``_save_dd_anchor``)."""
    var smart_wrap_comma_text: String
    """Working copy of ``TurbokodConfig.smart_wrap_comma_threshold`` as an
    editable digit string — Editor ▸ "Smart wrap: break at commas". Empty
    means "no comma trigger, only window width" (the ``-1`` sentinel). The
    host reads the parsed value via ``comma_threshold_value`` on the next
    config sync."""
    var _comma_input_anchor: Rect
    """Last-painted bounds of the comma-threshold input box (mouse hit-test
    cache, mirrors ``_wrap_dd_anchor``)."""
    var _trim_cb: Checkbox
    """Editor ▸ "Trim trailing whitespace" toggle. ``on`` tracks
    ``trim_trailing_whitespace``; position is set each paint so the
    press/release state machine hit-tests against the live row."""
    var _final_nl_cb: Checkbox
    """Editor ▸ "Ensure newline at end of files" toggle. Mirrors
    ``ensure_final_newline``."""
    var _compress_cb: Checkbox
    """Editor ▸ "Compress keyword arguments" toggle. Mirrors
    ``compress_kwargs``."""
    var _blink_cb: Checkbox
    """Editor ▸ "Blinking cursor" toggle. Mirrors ``cursor_blink``."""
    var dict_specs: List[DownloadableDictionary]
    """Catalog of downloadable spell-check dictionaries shown in the
    Spell-check pane. Snapshotted on ``open`` so the list and the
    install/remove buttons agree across paints."""
    var selected_dict: Int
    """Row in ``dict_specs`` that's highlighted in the Spell-check pane."""
    var pending_dict_install_lang: String
    """When non-empty, host should kick off an install for this language
    on the next ``paint``. The host clears it after picking up the
    request — Settings emits one request at a time."""
    var pending_dict_remove_lang: String
    """When non-empty, host should remove the on-disk wordlist for this
    language on the next ``paint`` and reload the speller. Host clears
    after picking up."""
    var language_overrides: List[LanguageServerOverride]
    """Working copy of ``TurbokodConfig.language_servers`` — the
    Languages section's authoritative state. Edits commit immediately
    on Save in the language editor; the host writes back to config on
    every paint when ``self.dirty`` is True."""
    var languages_view: List[LanguageSpec]
    """Effective per-paint snapshot of all languages: built-in plus
    user overrides applied. Rebuilt on ``open`` and after every
    language editor commit so the right pane reflects the user's
    latest priority list."""
    var selected_language: Int
    """Row in ``languages_view`` that's highlighted in the right pane."""
    var language_editor: LanguageEditor
    var theme_choice: String
    """Working copy of ``TurbokodConfig.theme`` — the Theme section's
    authoritative value. Changing the selection in the theme list commits
    here and raises ``dirty``; the host applies it live via
    ``Desktop.set_theme`` and persists on the next config sync."""
    var selected_theme: Int
    """Row in ``_theme_names`` that's highlighted in the Theme pane."""
    var _theme_names: List[String]
    """Snapshot of the available theme names (``theme.theme_names()``)."""
    var font_choice: String
    """Working copy of the active font label — the Font section's
    authoritative value. Index 0 of ``_font_names`` is the built-in
    bitmap font's label; changing the selection commits here and raises
    ``dirty``, and the host applies it live via ``Desktop.set_font``."""
    var selected_font: Int
    """Row in ``_font_names`` that's highlighted in the Font pane."""
    var _font_names: List[String]
    """Host-provided font labels (built-in default first, then the
    system's monospace families). Empty on the terminal frontend, which
    hides the Font section entirely."""
    var _last_scroll_font: Int
    """Counterpart of ``_last_scroll_action`` for ``selected_font``."""
    var font_size_choice: Int
    """Working copy of ``TurbokodConfig.font_size`` — 0 means "the
    font's default size", anything else is an explicit point size. The
    size stepper writes here and raises ``dirty``; the host applies it
    live via ``Desktop.set_font_size``."""
    var _font_effective_size: Int
    """Host-reported point size actually rendering right now (resolves
    the 0-means-default case for display). Refreshed every paint via
    ``update_font_info`` so it tracks live font-family changes."""
    var _font_ideal_size: Int
    """Host-reported design size of the active font — 16 for the
    built-in bitmap font, the embedded bitmap-strike ppem for true
    bitmap fonts, 0 when unknown (ordinary vector fonts). Gates the
    "Restore ideal" button."""
    var detached: Bool
    """True when the host renders Settings in its own native window (the
    macOS frontend; see ``Desktop.set_settings_detached``). The dialog then
    fills the whole surface and the in-grid move/resize chrome is disabled —
    the native window provides both."""
    var bounds: Rect
    """In-grid dialog rect (terminal frontend). Centered by default, then
    movable by dragging the title row and resizable by dragging the left /
    right / bottom border — so the workspace behind stays visible while a
    theme change retints it live. Session-persistent across open/close;
    ``_ensure_bounds`` re-clamps it against the current screen."""
    var _moving: Bool
    var _move_dx: Int
    var _move_dy: Int
    var _resizing: Bool
    var _rs_left: Bool
    var _rs_right: Bool
    var _rs_bottom: Bool
    var _type_ahead: TypeAhead
    """Shared type-to-jump prefix buffer for whichever section list
    currently owns focus. Reset on focus / section changes so a
    stale buffer doesn't misroute the first keystroke after the
    user moves between panes."""

    def __init__(out self):
        self.active = False
        self.dirty = False
        self.actions = List[OnSaveAction]()
        self.auto_save = False
        self.wrap_mode = WRAP_NONE
        self.trim_trailing_whitespace = False
        self.ensure_final_newline = False
        self.compress_kwargs = False
        self.cursor_blink = False
        self.section = 0
        self.selected_action = -1
        self.focus = _FOCUS_SECTIONS
        self.editor = ActionEditor()
        self._list_scroll = 0
        self._last_scroll_action = -2
        self._last_scroll_dict = -2
        self._last_scroll_language = -2
        self._buttons = List[_PlacedButton]()
        self._buttons.append(_PlacedButton(
            ShadowButton(String(" + Add "), 0, 0), _FOCUS_ADD, True,
        ))
        self._buttons.append(_PlacedButton(
            ShadowButton(String(" Edit "), 0, 0), _FOCUS_EDIT, True,
        ))
        self._buttons.append(_PlacedButton(
            ShadowButton(String(" - Remove "), 0, 0), _FOCUS_REMOVE, True,
        ))
        self._buttons.append(_PlacedButton(
            ShadowButton(String(" Close "), 0, 0), _FOCUS_CLOSE, True,
        ))
        self._buttons.append(_PlacedButton(
            ShadowButton(String(" + Install "), 0, 0),
            _FOCUS_DICT_INSTALL, True,
        ))
        self._buttons.append(_PlacedButton(
            ShadowButton(String(" - Remove "), 0, 0),
            _FOCUS_DICT_REMOVE, True,
        ))
        self._buttons.append(_PlacedButton(
            ShadowButton(String(" + Add "), 0, 0), _FOCUS_LANG_ADD, True,
        ))
        self._buttons.append(_PlacedButton(
            ShadowButton(String(" Edit "), 0, 0), _FOCUS_LANG_EDIT, True,
        ))
        self._buttons.append(_PlacedButton(
            ShadowButton(String(" - Remove "), 0, 0),
            _FOCUS_LANG_REMOVE, True,
        ))
        self._buttons.append(_PlacedButton(
            ShadowButton(String(" - "), 0, 0), _FOCUS_FONT_SMALLER, True,
        ))
        self._buttons.append(_PlacedButton(
            ShadowButton(String(" + "), 0, 0), _FOCUS_FONT_LARGER, True,
        ))
        self._buttons.append(_PlacedButton(
            ShadowButton(String(" Restore ideal "), 0, 0),
            _FOCUS_FONT_IDEAL, True,
        ))
        self._save_dropdown = Dropdown(_save_behavior_options(), 0)
        self._save_dd_anchor = Rect(0, 0, 0, 0)
        self._wrap_dropdown = Dropdown(_wrap_mode_options(), 0)
        self._wrap_dd_anchor = Rect(0, 0, 0, 0)
        self.smart_wrap_comma_text = String("")
        self._comma_input_anchor = Rect(0, 0, 0, 0)
        self._trim_cb = Checkbox(
            String("Trim trailing whitespace"), 0, 0, False,
        )
        self._final_nl_cb = Checkbox(
            String("Ensure newline at end of files"), 0, 0, False,
        )
        self._compress_cb = Checkbox(
            String("Compress keyword arguments"), 0, 0, False,
        )
        self._blink_cb = Checkbox(
            String("Blinking cursor"), 0, 0, False,
        )
        self.dict_specs = List[DownloadableDictionary]()
        self.selected_dict = 0
        self.pending_dict_install_lang = String("")
        self.pending_dict_remove_lang = String("")
        self.language_overrides = List[LanguageServerOverride]()
        self.languages_view = List[LanguageSpec]()
        self.selected_language = -1
        self.language_editor = LanguageEditor()
        self.theme_choice = String("Turbo C++ 3.0")
        self.selected_theme = 0
        self._theme_names = theme_names()
        self.font_choice = String("")
        self.selected_font = 0
        self._font_names = List[String]()
        self._last_scroll_font = -2
        self.font_size_choice = 0
        self._font_effective_size = 0
        self._font_ideal_size = 0
        self.detached = False
        self.bounds = Rect(0, 0, 0, 0)
        self._moving = False
        self._move_dx = 0
        self._move_dy = 0
        self._resizing = False
        self._rs_left = False
        self._rs_right = False
        self._rs_bottom = False
        self._type_ahead = TypeAhead()

    def open(
        mut self, var actions: List[OnSaveAction], auto_save: Bool,
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
        cursor_blink: Bool = True,
    ):
        self.actions = actions^
        self.auto_save = auto_save
        self.wrap_mode = wrap_mode
        self.trim_trailing_whitespace = trim_trailing_whitespace
        self.ensure_final_newline = ensure_final_newline
        self.compress_kwargs = compress_kwargs
        self.cursor_blink = cursor_blink
        self._trim_cb.on = trim_trailing_whitespace
        self._final_nl_cb.on = ensure_final_newline
        self._compress_cb.on = compress_kwargs
        self._blink_cb.on = cursor_blink
        self.active = True
        self.dirty = False
        self.section = 0
        self.selected_action = 0 if len(self.actions) > 0 else -1
        self.focus = _FOCUS_SECTIONS
        self._list_scroll = 0
        self._last_scroll_action = -2
        self._last_scroll_dict = -2
        self._last_scroll_language = -2
        self._last_scroll_font = -2
        self._save_dropdown = Dropdown(
            _save_behavior_options(), 1 if auto_save else 0,
        )
        self._wrap_dropdown = Dropdown(_wrap_mode_options(), wrap_mode)
        # Negative sentinel renders as an empty field; any value >= 0 shows
        # its digits.
        if comma_threshold < 0:
            self.smart_wrap_comma_text = String("")
        else:
            self.smart_wrap_comma_text = String(comma_threshold)
        self.dict_specs = built_in_downloadable_dictionaries()
        self.selected_dict = 0 if len(self.dict_specs) > 0 else -1
        self.pending_dict_install_lang = String("")
        self.pending_dict_remove_lang = String("")
        self.language_overrides = language_overrides^
        self._rebuild_languages_view()
        # Pre-select the focused editor's language so the Languages
        # section opens on the row the user is most likely to care
        # about — the scroll-snap in _paint_languages_list brings it
        # into view on the next paint.
        var lang_idx = -1
        if len(current_language_ext.as_bytes()) > 0:
            lang_idx = find_language_for_extension(
                self.languages_view, current_language_ext,
            )
        if lang_idx < 0:
            lang_idx = 0 if len(self.languages_view) > 0 else -1
        self.selected_language = lang_idx
        # Theme section: snapshot the catalog and select the active theme.
        self._theme_names = theme_names()
        self.theme_choice = theme
        self.selected_theme = 0
        for i in range(len(self._theme_names)):
            if self._theme_names[i] == theme:
                self.selected_theme = i
                break
        # Font section: host-provided labels (empty on the terminal
        # frontend, which hides the section). Select the active font.
        self._font_names = font_names^
        self.font_choice = font
        self.selected_font = 0
        for i in range(len(self._font_names)):
            if self._font_names[i] == font:
                self.selected_font = i
                break
        self.font_size_choice = font_size
        self._font_effective_size = font_effective_size
        self._font_ideal_size = font_ideal_size

    def update_font_info(mut self, effective: Int, ideal: Int):
        """Host pushes the live effective/ideal sizes every paint —
        a font-family change mid-dialog changes both, and the values
        only become known a frame after the host applies the font.
        Display-only; never touches ``dirty``."""
        self._font_effective_size = effective
        self._font_ideal_size = ideal

    def _rebuild_languages_view(mut self):
        self.languages_view = apply_language_overrides(
            built_in_servers(), self.language_overrides,
        )

    def close(mut self):
        self.active = False
        # Drop any in-flight move/resize drag; ``bounds`` itself is kept so
        # the next open reuses the user's size + position.
        self._moving = False
        self._resizing = False
        self.actions = List[OnSaveAction]()
        self.auto_save = False
        self.trim_trailing_whitespace = False
        self.ensure_final_newline = False
        self.compress_kwargs = False
        self.cursor_blink = False
        self.section = 0
        self.selected_action = -1
        self.focus = _FOCUS_SECTIONS
        self._list_scroll = 0
        self.editor.close()
        self._save_dropdown.close()
        self._wrap_dropdown.close()
        self._trim_cb.pressed = False
        self._trim_cb.pressed_inside = False
        self._final_nl_cb.pressed = False
        self._final_nl_cb.pressed_inside = False
        self._compress_cb.pressed = False
        self._compress_cb.pressed_inside = False
        self._blink_cb.pressed = False
        self._blink_cb.pressed_inside = False
        self.dict_specs = List[DownloadableDictionary]()
        self.selected_dict = -1
        self.pending_dict_install_lang = String("")
        self.pending_dict_remove_lang = String("")
        self.language_overrides = List[LanguageServerOverride]()
        self.languages_view = List[LanguageSpec]()
        self.selected_language = -1
        self.language_editor.close()
        self._type_ahead.reset()
        for i in range(len(self._buttons)):
            self._buttons[i].button.pressed = False
            self._buttons[i].button.pressed_inside = False

    def ack_dirty(mut self):
        """Host calls this after persisting ``self.actions`` to disk."""
        self.dirty = False

    # --- painting ---------------------------------------------------

    def paint(mut self, mut canvas: Canvas, screen: Rect):
        if not self.active:
            return
        self._ensure_bounds(screen)
        var rect = self._workspace_rect(screen)
        # In-grid the dialog floats over the workspace — drop a shadow so it
        # reads as lifted (the host window provides this when detached).
        if not self.detached:
            paint_drop_shadow(canvas, rect)
        var bg = Attr(BLACK, LIGHT_GRAY)
        # Bind every write inside the Settings dialog to its workspace
        # rect — ``rect`` excludes the menu bar above and status bar
        # below, so even an over-wide section row can't bleed into
        # them.
        var painter = Painter(rect)
        painter.fill(canvas, rect, String(" "), bg)
        # In-grid the dialog draws its own window chrome (border + title);
        # detached the native window's title bar already provides both, so
        # painting them again would be redundant.
        if not self.detached:
            var border = Attr(BORDER_FOCUS, LIGHT_GRAY)
            painter.draw_box(canvas, rect, border, True)
            paint_window_title(canvas, rect, String(" Settings "), bg, bg)
        # Left rail.
        self._paint_sections(canvas, painter, rect)
        # Right pane: section header + per-section content.
        self._paint_right_pane(canvas, painter, rect)
        # Bottom-right Close button.
        self._paint_close_button(canvas, rect)
        # Save-behavior popup floats above the right pane so a long
        # option list isn't clipped by neighbouring widgets. Painted
        # before the action editor so a modal Add/Edit dialog still
        # wins z-order.
        if self.section == _SECTION_EDITOR and self._save_dropdown.is_open:
            self._save_dropdown.paint_popup(
                canvas, self._save_dd_anchor, screen,
            )
        if self.section == _SECTION_EDITOR and self._wrap_dropdown.is_open:
            self._wrap_dropdown.paint_popup(
                canvas, self._wrap_dd_anchor, screen,
            )
        # Editor floats on top.
        if self.editor.active:
            self.editor.paint(canvas, screen)
        if self.language_editor.active:
            self.language_editor.paint(canvas, screen)

    def _workspace_rect(self, screen: Rect) -> Rect:
        """The dialog's rect. Detached (native settings window) it fills the
        whole surface; in-grid (terminal) it's the movable / resizable
        ``bounds``, which ``_ensure_bounds`` keeps valid against the current
        screen. Every geometry helper and hit-test derives from this, so the
        whole dialog follows a move/resize for free."""
        if self.detached:
            return screen
        return self.bounds

    def _host_workspace(self, screen: Rect) -> Rect:
        """The area the in-grid dialog may occupy — ``screen`` minus the
        menu bar (row 0) and status bar (last row), which the host keeps
        painting so the user keeps their bearings."""
        var top = 1 if screen.b.y > 2 else 0
        var bottom = screen.b.y - 1 if screen.b.y > 2 else screen.b.y
        return Rect(screen.a.x, top, screen.b.x, bottom)

    def _ensure_bounds(mut self, screen: Rect):
        """Initialize ``bounds`` (centered default) on first open and clamp
        it back into the workspace after a terminal resize. No-op when the
        host owns the window (detached)."""
        if self.detached:
            return
        var ws = self._host_workspace(screen)
        var w = self.bounds.width()
        var h = self.bounds.height()
        if w < _SETTINGS_MIN_W or h < _SETTINGS_MIN_H:
            # First open (or degenerate): centered, big enough to be
            # comfortable, small enough to leave the workspace visible
            # around it (that's the point — live theme preview).
            w = ws.width() - 8
            if w > 104:
                w = 104
            h = ws.height() - 4
            if h > 30:
                h = 30
            var x = ws.a.x + (ws.width() - w) // 2
            var y = ws.a.y + (ws.height() - h) // 2
            self.bounds = Rect(x, y, x + w, y + h)
        # Shrink to fit, then slide fully on-screen.
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
        mut self, event: Event, rect: Rect, screen: Rect,
    ) -> Bool:
        """In-grid window chrome: drag the title row to move, drag the
        left / right / bottom border (corners included) to resize. An
        in-flight drag owns every event until the button is released —
        even when the cursor wanders outside the dialog (mirrors
        ``WindowStack``'s drag/resize state machine). Returns True when
        the event was consumed."""
        if self.detached:
            return False
        var ws = self._host_workspace(screen)
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
                if bx - ax < _SETTINGS_MIN_W:
                    ax = bx - _SETTINGS_MIN_W
            if self._rs_right:
                bx = event.pos.x + 1
                if bx > ws.b.x:
                    bx = ws.b.x
                if bx - ax < _SETTINGS_MIN_W:
                    bx = ax + _SETTINGS_MIN_W
            if self._rs_bottom:
                by = event.pos.y + 1
                if by > ws.b.y:
                    by = ws.b.y
                if by - ay < _SETTINGS_MIN_H:
                    by = ay + _SETTINGS_MIN_H
            self.bounds = Rect(ax, ay, bx, by)
            return True
        if event.button != MOUSE_BUTTON_LEFT or not event.pressed \
                or event.motion:
            return False
        var inside_x = event.pos.x >= rect.a.x and event.pos.x < rect.b.x
        var inside_y = event.pos.y >= rect.a.y and event.pos.y < rect.b.y
        if not (inside_x and inside_y):
            return False
        # Title row (top border) moves; the other three borders resize.
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

    def _labels(self) -> List[String]:
        """Section labels for this instance — the Font section only
        exists when the host registered font options."""
        return _section_labels(len(self._font_names) > 0)

    def _sections_rect(self, rect: Rect) -> Rect:
        """Inner area of the left rail (inside the framed border)."""
        return Rect(
            rect.a.x + 2, rect.a.y + 2,
            rect.a.x + 2 + _SECTION_W, rect.b.y - 2,
        )

    def _right_rect(self, rect: Rect) -> Rect:
        return Rect(
            rect.a.x + 2 + _SECTION_W + 2, rect.a.y + 2,
            rect.b.x - 2, rect.b.y - 2,
        )

    def _paint_sections(
        self, mut canvas: Canvas, painter: Painter, rect: Rect,
    ):
        var inner = self._sections_rect(rect)
        var sub = painter.sub(inner)
        var body_attr = Attr(BLACK, CYAN)
        sub.fill(canvas, inner, String(" "), body_attr)
        var labels = self._labels()
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
                    canvas,
                    Rect(inner.a.x, y, inner.b.x, y + 1),
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
        # Header.
        var labels = self._labels()
        if 0 <= self.section and self.section < len(labels):
            _ = sub.put_text(
                canvas, Point(inner.a.x, inner.a.y),
                labels[self.section], bg,
            )
        # Section content.
        if self.section == _SECTION_ACTIONS:
            self._paint_actions_section(canvas, sub, inner)
        elif self.section == _SECTION_EDITOR:
            self._paint_editor_section(canvas, sub, inner)
        elif self.section == _SECTION_SPELL:
            self._paint_spell_section(canvas, sub, inner)
        elif self.section == _SECTION_LANGUAGES:
            self._paint_languages_section(canvas, sub, inner)
        elif self.section == _SECTION_THEME:
            self._paint_theme_section(canvas, sub, inner)
        elif self.section == _SECTION_FONT:
            self._paint_font_section(canvas, sub, inner)

    def _font_display_size(self) -> Int:
        """The point size to show in the stepper: the explicit choice,
        or the host-reported effective size when the choice is 0 (the
        font's default). Falls back to 16 before the host has reported
        anything (shouldn't happen in practice — the report lands on
        the first frame)."""
        if self.font_size_choice > 0:
            return self.font_size_choice
        if self._font_effective_size > 0:
            return self._font_effective_size
        return 16

    def _bump_font_size(mut self, delta: Int):
        """Step the size by ``delta`` from the currently displayed
        value, clamped, committing an explicit size + ``dirty``."""
        var s = self._font_display_size() + delta
        if s < MIN_FONT_SIZE:
            s = MIN_FONT_SIZE
        if s > MAX_FONT_SIZE:
            s = MAX_FONT_SIZE
        if s != self.font_size_choice:
            self.font_size_choice = s
            self.dirty = True

    def _restore_ideal_font_size(mut self):
        """Snap the size back to the active font's design size (the
        host-reported ideal). No-op when the host reported none."""
        if self._font_ideal_size <= 0:
            return
        if self.font_size_choice != self._font_ideal_size:
            self.font_size_choice = self._font_ideal_size
            self.dirty = True

    def _paint_font_section(
        mut self, mut canvas: Canvas, painter: Painter, inner: Rect,
    ):
        """A size stepper row, then a scrollable list of the host's
        monospace font families (the built-in bitmap font first).
        Selecting a row applies it live — the whole UI re-renders in
        the new font, which *is* the preview — so there's no separate
        sample pane like the Theme section's."""
        var hint = Attr(BLUE, LIGHT_GRAY)
        var bg = Attr(BLACK, LIGHT_GRAY)
        # Size stepper: ``Size: [ - ] 16 pt [ + ]   [ Restore ideal ]``.
        # Buttons claim two rows (face + drop shadow).
        var size_y = inner.a.y + 2
        var x = inner.a.x
        _ = painter.put_text(canvas, Point(x, size_y), String("Size:"), bg)
        x += 6
        self._buttons[_BTN_FONT_SMALLER].button.move_to(x, size_y)
        self._buttons[_BTN_FONT_SMALLER].enabled = (
            self._font_display_size() > MIN_FONT_SIZE
        )
        x += self._buttons[_BTN_FONT_SMALLER].button.total_width() + 1
        var size_label = String(self._font_display_size()) + String(" pt")
        if self.font_size_choice == 0:
            size_label += String(" (default)")
        _ = painter.put_text(canvas, Point(x, size_y), size_label, bg)
        x += display_columns(size_label) + 1
        self._buttons[_BTN_FONT_LARGER].button.move_to(x, size_y)
        self._buttons[_BTN_FONT_LARGER].enabled = (
            self._font_display_size() < MAX_FONT_SIZE
        )
        x += self._buttons[_BTN_FONT_LARGER].button.total_width() + 3
        # "Restore ideal" only renders when the active font has a known
        # design size (the built-in bitmap font, or a font with embedded
        # bitmap strikes) *and* it fits — buttons paint straight to the
        # canvas (no painter clipping), so an overflow would spill past
        # the dialog border. Greyed out while already at that size.
        var ideal_visible = False
        if self._font_ideal_size > 0:
            self._buttons[_BTN_FONT_IDEAL].button.label = (
                String(" Restore ideal (")
                + String(self._font_ideal_size) + String(" pt) ")
            )
            ideal_visible = (
                x + self._buttons[_BTN_FONT_IDEAL].button.total_width()
                <= inner.b.x
            )
        if ideal_visible:
            self._buttons[_BTN_FONT_IDEAL].button.move_to(x, size_y)
            self._buttons[_BTN_FONT_IDEAL].enabled = (
                self._font_display_size() != self._font_ideal_size
            )
        else:
            self._buttons[_BTN_FONT_IDEAL].enabled = False
        self._paint_button(canvas, _BTN_FONT_SMALLER)
        self._paint_button(canvas, _BTN_FONT_LARGER)
        if ideal_visible:
            self._paint_button(canvas, _BTN_FONT_IDEAL)
        var list_top = inner.a.y + 5
        var list_bottom = inner.b.y - 1
        if list_bottom <= list_top:
            return
        var list_rect = Rect(inner.a.x, list_top, inner.b.x, list_bottom)
        var visible = list_rect.height()
        # Change-only viewport snap — see _paint_actions_list.
        if self.selected_font >= 0 \
                and self.selected_font != self._last_scroll_font:
            if self.selected_font < self._list_scroll:
                self._list_scroll = self.selected_font
            elif self.selected_font >= self._list_scroll + visible:
                self._list_scroll = self.selected_font - visible + 1
        self._last_scroll_font = self.selected_font
        if self._list_scroll < 0:
            self._list_scroll = 0
        var max_scroll = len(self._font_names) - visible
        if max_scroll < 0:
            max_scroll = 0
        if self._list_scroll > max_scroll:
            self._list_scroll = max_scroll
        var body_attr = Attr(BLACK, CYAN)
        painter.fill(canvas, list_rect, String(" "), body_attr)
        for r in range(visible):
            var idx = self._list_scroll + r
            if idx >= len(self._font_names):
                break
            var y = list_rect.a.y + r
            var attr = body_attr
            if idx == self.selected_font:
                attr = (
                    Attr(WHITE, BLUE) if self.focus == _FOCUS_FONT_LIST
                    else Attr(BLACK, GREEN)
                )
                painter.fill(
                    canvas, Rect(list_rect.a.x, y, list_rect.b.x, y + 1),
                    String(" "), attr,
                )
            _ = painter.put_text(
                canvas, Point(list_rect.a.x + 1, y),
                self._font_names[idx], attr,
            )
        _ = painter.put_text(
            canvas, Point(inner.a.x, inner.b.y),
            String("↑↓ to preview live — change is saved automatically"),
            hint,
        )

    def _paint_theme_section(
        mut self, mut canvas: Canvas, painter: Painter, inner: Rect,
    ):
        """Left: scrollable list of theme names. Right: a live preview that
        paints a faux title bar, menu strip, and a few syntax-colored code
        lines using the active palette's chrome + reserved syntax indices.
        Selecting a theme applies it live (the whole dialog retints on the
        next frame), so the preview tracks the real thing."""
        var hint = Attr(BLUE, LIGHT_GRAY)
        var list_top = inner.a.y + 2
        var list_bottom = inner.b.y - 1
        if list_bottom <= list_top:
            return
        # The list occupies the left ~18 columns of the right pane; the
        # preview fills the remainder.
        var list_w = 20
        var split = inner.a.x + list_w
        if split > inner.b.x - 12:
            split = inner.b.x - 12
        var list_rect = Rect(inner.a.x, list_top, split, list_bottom)
        var body_attr = Attr(BLACK, CYAN)
        painter.fill(canvas, list_rect, String(" "), body_attr)
        for i in range(len(self._theme_names)):
            var y = list_rect.a.y + i
            if y >= list_rect.b.y:
                break
            var attr = body_attr
            if i == self.selected_theme:
                attr = (
                    Attr(WHITE, BLUE) if self.focus == _FOCUS_THEME_LIST
                    else Attr(BLACK, GREEN)
                )
                painter.fill(
                    canvas, Rect(list_rect.a.x, y, list_rect.b.x, y + 1),
                    String(" "), attr,
                )
            _ = painter.put_text(
                canvas, Point(list_rect.a.x + 1, y),
                self._theme_names[i], attr,
            )
        _ = painter.put_text(
            canvas, Point(inner.a.x, inner.b.y),
            String("↑↓ to preview live — change is saved automatically"),
            hint,
        )
        # Preview pane to the right of the list.
        var px = split + 2
        if px < inner.b.x - 4:
            self._paint_theme_preview(
                canvas, painter,
                Rect(px, list_top, inner.b.x, list_bottom),
            )

    def _paint_theme_preview(
        self, mut canvas: Canvas, painter: Painter, box: Rect,
    ):
        """Sample of the active theme: a title bar, a menu strip, and a few
        lines of fake code colored with the reserved syntax slots. All cells
        carry palette indices; the frontend resolves them through the live
        theme, so this mirrors exactly how editors will look."""
        if box.width() < 8 or box.height() < 6:
            return
        var menu_bar = Attr(BLACK, LIGHT_GRAY)
        var menu_key = Attr(RED, LIGHT_GRAY)
        var title = Attr(BLACK, LIGHT_GRAY)
        var ed = Attr(EDITOR_FG, EDITOR_BG)
        # Title row.
        painter.fill(canvas, Rect(box.a.x, box.a.y, box.b.x, box.a.y + 1),
                     String("─"), title)
        _ = painter.put_text(
            canvas, Point(box.a.x + 1, box.a.y), String(" sample.py "), title,
        )
        # Menu strip.
        var my = box.a.y + 1
        painter.fill(canvas, Rect(box.a.x, my, box.b.x, my + 1),
                     String(" "), menu_bar)
        _ = painter.put_text(canvas, Point(box.a.x + 1, my),
                             String("File  Edit  View"), menu_bar)
        _ = painter.put_text(canvas, Point(box.a.x + 1, my), String("F"),
                             menu_key)
        # Editor body.
        var body = Rect(box.a.x, my + 1, box.b.x, box.b.y)
        painter.fill(canvas, body, String(" "), ed)
        var ky = Attr(SYN_KEYWORD, EDITOR_BG)
        var st = Attr(SYN_STRING, EDITOR_BG)
        var cm = Attr(SYN_COMMENT, EDITOR_BG)
        var nu = Attr(SYN_NUMBER, EDITOR_BG)
        # Identifiers (function names, calls) paint with the ident slot —
        # same as the editor's real scope mapping (entity.name.function /
        # support.function → ident), which is also the unhighlighted-text
        # baseline. ``ed`` is only the punctuation/plain-cell color.
        var id = Attr(SYN_IDENT, EDITOR_BG)
        var x0 = body.a.x + 1
        var ry = body.a.y
        if ry < body.b.y:
            _ = painter.put_text(canvas, Point(x0, ry),
                                 String("# greet the world"), cm)
        ry += 1
        if ry < body.b.y:
            var cx = x0
            cx += painter.put_text(canvas, Point(cx, ry), String("def "), ky)
            cx += painter.put_text(canvas, Point(cx, ry), String("main"), id)
            _ = painter.put_text(canvas, Point(cx, ry), String("():"), ed)
        ry += 1
        if ry < body.b.y:
            var cx2 = x0 + 4
            cx2 += painter.put_text(canvas, Point(cx2, ry), String("print"), id)
            cx2 += painter.put_text(canvas, Point(cx2, ry), String("("), ed)
            cx2 += painter.put_text(canvas, Point(cx2, ry),
                                    String('"hello"'), st)
            _ = painter.put_text(canvas, Point(cx2, ry), String(")"), ed)
        ry += 1
        if ry < body.b.y:
            var cx3 = x0 + 4
            cx3 += painter.put_text(canvas, Point(cx3, ry), String("return "),
                                    ky)
            _ = painter.put_text(canvas, Point(cx3, ry), String("42"), nu)

    def _paint_actions_section(
        mut self, mut canvas: Canvas, painter: Painter, inner: Rect,
    ):
        """List of configured on-save actions plus the action-row of
        buttons. The list draws on a cyan strip; the buttons live on
        the dialog body (light gray) below it."""
        var hint = Attr(BLUE, LIGHT_GRAY)
        var list_top = inner.a.y + 2
        var list_bottom = inner.b.y - 5
        if list_bottom <= list_top:
            return
        var list_rect = Rect(inner.a.x, list_top, inner.b.x, list_bottom)
        var body_attr = Attr(BLACK, CYAN)
        painter.fill(canvas, list_rect, String(" "), body_attr)
        if len(self.actions) == 0:
            _ = painter.put_text(
                canvas, Point(list_rect.a.x + 1, list_rect.a.y),
                String("(no actions configured — press [+ Add])"),
                hint,
            )
        else:
            self._paint_actions_list(canvas, painter, list_rect)
        # Helper line under the list.
        _ = painter.put_text(
            canvas, Point(inner.a.x, list_bottom),
            String("Runs after a successful save when language matches."),
            hint,
        )
        # Buttons row anchored just below the list. ``_paint_buttons``
        # repositions in place so the press latches survive across
        # paints.
        var btn_y = list_bottom + 2
        var add_x = inner.a.x
        self._buttons[_BTN_ADD].button.move_to(add_x, btn_y)
        var edit_x = add_x + self._buttons[_BTN_ADD].button.total_width() + 1
        self._buttons[_BTN_EDIT].button.move_to(edit_x, btn_y)
        var rm_x = edit_x + self._buttons[_BTN_EDIT].button.total_width() + 1
        self._buttons[_BTN_REMOVE].button.move_to(rm_x, btn_y)
        var has_sel = (self.selected_action >= 0
                       and self.selected_action < len(self.actions))
        self._buttons[_BTN_EDIT].enabled = has_sel
        self._buttons[_BTN_REMOVE].enabled = has_sel
        self._paint_button(canvas, _BTN_ADD)
        self._paint_button(canvas, _BTN_EDIT)
        self._paint_button(canvas, _BTN_REMOVE)

    def _paint_actions_list(
        mut self, mut canvas: Canvas, painter: Painter, list_rect: Rect,
    ):
        var visible = list_rect.height()
        # Only snap the viewport to the selection when the selection
        # has actually changed since the previous paint — otherwise the
        # mouse wheel could never move the viewport without immediately
        # being snapped back.
        if self.selected_action >= 0 \
                and self.selected_action != self._last_scroll_action:
            if self.selected_action < self._list_scroll:
                self._list_scroll = self.selected_action
            elif self.selected_action >= self._list_scroll + visible:
                self._list_scroll = self.selected_action - visible + 1
        self._last_scroll_action = self.selected_action
        if self._list_scroll < 0:
            self._list_scroll = 0
        var max_scroll = len(self.actions) - visible
        if max_scroll < 0:
            max_scroll = 0
        if self._list_scroll > max_scroll:
            self._list_scroll = max_scroll
        var body_attr = Attr(BLACK, CYAN)
        for r in range(visible):
            var idx = self._list_scroll + r
            if idx >= len(self.actions):
                break
            var act = self.actions[idx].copy()
            var attr = body_attr
            if idx == self.selected_action:
                attr = (
                    Attr(WHITE, BLUE) if self.focus == _FOCUS_LIST
                    else Attr(BLACK, GREEN)
                )
                painter.fill(
                    canvas,
                    Rect(list_rect.a.x, list_rect.a.y + r,
                         list_rect.b.x, list_rect.a.y + r + 1),
                    String(" "), attr,
                )
            var line = _format_action(act)
            _ = painter.put_text(
                canvas, Point(list_rect.a.x + 1, list_rect.a.y + r),
                line, attr,
            )

    def _paint_editor_section(
        mut self, mut canvas: Canvas, painter: Painter, inner: Rect,
    ):
        """Editor preferences pane: the inline ``Save behavior`` dropdown
        plus the two on-save transform checkboxes."""
        var bg = Attr(BLACK, LIGHT_GRAY)
        var hint = Attr(BLUE, LIGHT_GRAY)
        var label = String("Save behavior:")
        var label_y = inner.a.y + 2
        _ = painter.put_text(
            canvas, Point(inner.a.x, label_y), label, bg,
        )
        # Anchor the strip directly to the right of the label, leaving
        # one column of padding so the value isn't flush against the
        # colon.
        var dd_x = inner.a.x + display_columns(label) + 1
        var dd_w = _SAVE_DD_W
        if dd_x + dd_w > inner.b.x:
            dd_w = inner.b.x - dd_x
            if dd_w < 4:
                return
        var dd_rect = Rect(dd_x, label_y, dd_x + dd_w, label_y + 1)
        self._save_dd_anchor = dd_rect
        # Keep ``_save_dropdown.index`` in sync with ``auto_save`` —
        # the user can mutate ``auto_save`` directly via tests, and
        # we don't want a stale index to override that.
        var want_idx = 1 if self.auto_save else 0
        if self._save_dropdown.index != want_idx:
            self._save_dropdown.index = want_idx
        var has_focus = self.focus == _FOCUS_SAVE_BEHAVIOR
        self._save_dropdown.paint(
            canvas, dd_rect, has_focus,
            Attr(WHITE, BLUE), Attr(BLACK, CYAN),
        )
        _ = painter.put_text(
            canvas, Point(inner.a.x, label_y + 2),
            String("Manual: save with Ctrl+S. Automatic: save on focus changes."),
            hint,
        )
        # Wrap-mode dropdown, anchored after its label the same way the
        # Save-behavior strip is. Index stays in lock-step with
        # ``self.wrap_mode`` (mutable directly in tests, same contract).
        var wrap_label = String("Wrap:")
        var wrap_y = label_y + 4
        _ = painter.put_text(
            canvas, Point(inner.a.x, wrap_y), wrap_label, bg,
        )
        var wrap_dd_x = inner.a.x + display_columns(wrap_label) + 1
        var wrap_dd_w = _SAVE_DD_W
        if wrap_dd_x + wrap_dd_w > inner.b.x:
            wrap_dd_w = inner.b.x - wrap_dd_x
        if wrap_dd_w >= 4:
            var wrap_rect = Rect(
                wrap_dd_x, wrap_y, wrap_dd_x + wrap_dd_w, wrap_y + 1,
            )
            self._wrap_dd_anchor = wrap_rect
            if self._wrap_dropdown.index != self.wrap_mode:
                self._wrap_dropdown.index = self.wrap_mode
            self._wrap_dropdown.paint(
                canvas, wrap_rect, self.focus == _FOCUS_WRAP_MODE,
                Attr(WHITE, BLUE), Attr(BLACK, CYAN),
            )
        _ = painter.put_text(
            canvas, Point(inner.a.x, wrap_y + 2),
            String("Smart wrap breaks long calls one item per line (code files)."),
            hint,
        )
        # Smart-wrap comma trigger: a small inline numeric field. Empty means
        # "only window width breaks lines"; a number N means "also break a
        # call with more than N commas even when it fits". Sits on its own row
        # under the wrap hint; the trailing copy explains the empty case.
        var comma_y = wrap_y + 3
        var comma_label = String("Also break over:")
        _ = painter.put_text(
            canvas, Point(inner.a.x, comma_y), comma_label, bg,
        )
        var box_x = inner.a.x + display_columns(comma_label) + 1
        var box_w = 5
        var box_attr = (
            Attr(WHITE, BLUE) if self.focus == _FOCUS_COMMA_WRAP
            else Attr(BLACK, CYAN)
        )
        var box_rect = Rect(box_x, comma_y, box_x + box_w, comma_y + 1)
        self._comma_input_anchor = box_rect
        painter.fill(canvas, box_rect, String(" "), box_attr)
        # Field text is left-aligned with one column of padding. An empty
        # field shows a faint "—" placeholder so the box doesn't read as a
        # rendering glitch.
        var shown = self.smart_wrap_comma_text
        if len(shown.as_bytes()) == 0 and self.focus != _FOCUS_COMMA_WRAP:
            _ = painter.put_text(
                canvas, Point(box_x + 1, comma_y), String("—"), box_attr,
            )
        else:
            _ = painter.put_text(
                canvas, Point(box_x + 1, comma_y), shown, box_attr,
            )
        _ = painter.put_text(
            canvas, Point(box_x + box_w + 1, comma_y),
            String("commas (blank = window width only)"), hint,
        )
        # On-save transform checkboxes. Both keep their glyph in lock-step
        # with the working-copy bools (the bools can be mutated directly
        # in tests, same contract as the dropdown's ``want_idx`` sync).
        self._trim_cb.on = self.trim_trailing_whitespace
        self._final_nl_cb.on = self.ensure_final_newline
        var chip = Attr(BLACK, CYAN)
        var focus_attr = Attr(WHITE, BLUE)
        self._trim_cb.move_to(inner.a.x, label_y + 8)
        paint_checkbox(
            canvas, self._trim_cb, chip, focus_attr,
            self.focus == _FOCUS_TRIM_WS, inner.b.x,
        )
        self._final_nl_cb.move_to(inner.a.x, label_y + 9)
        paint_checkbox(
            canvas, self._final_nl_cb, chip, focus_attr,
            self.focus == _FOCUS_FINAL_NL, inner.b.x,
        )
        _ = painter.put_text(
            canvas, Point(inner.a.x, label_y + 11),
            String("Applied on every save unless a project .editorconfig overrides it."),
            hint,
        )
        # Display-only toggle (not a save transform), so it sits below the
        # save-behavior hint with its own one-liner.
        self._compress_cb.on = self.compress_kwargs
        self._compress_cb.move_to(inner.a.x, label_y + 13)
        paint_checkbox(
            canvas, self._compress_cb, chip, focus_attr,
            self.focus == _FOCUS_COMPRESS_KW, inner.b.x,
        )
        _ = painter.put_text(
            canvas, Point(inner.a.x, label_y + 14),
            String("Hide redundant name=name call args off the caret line (Python/Mojo/Swift)."),
            hint,
        )
        # Caret blink toggle — like compress, a pure display preference, so
        # it sits below with its own one-liner.
        self._blink_cb.on = self.cursor_blink
        self._blink_cb.move_to(inner.a.x, label_y + 16)
        paint_checkbox(
            canvas, self._blink_cb, chip, focus_attr,
            self.focus == _FOCUS_BLINK_CURSOR, inner.b.x,
        )
        _ = painter.put_text(
            canvas, Point(inner.a.x, label_y + 17),
            String("Blink the text cursor when idle; it stays solid while you type."),
            hint,
        )

    def _paint_spell_section(
        mut self, mut canvas: Canvas, painter: Painter, inner: Rect,
    ):
        """List of catalog dictionaries with an "[X] installed" marker
        plus an Install / Remove button row. English is built-in (OS
        ``/usr/share/dict/words`` plus the bundled programmer wordlists)
        and isn't shown — these are the optional extra-language packs."""
        var hint = Attr(BLUE, LIGHT_GRAY)
        var list_top = inner.a.y + 2
        var list_bottom = inner.b.y - 5
        if list_bottom <= list_top:
            return
        var list_rect = Rect(inner.a.x, list_top, inner.b.x, list_bottom)
        var body_attr = Attr(BLACK, CYAN)
        painter.fill(canvas, list_rect, String(" "), body_attr)
        if len(self.dict_specs) == 0:
            _ = painter.put_text(
                canvas, Point(list_rect.a.x + 1, list_rect.a.y),
                String("(no downloadable dictionaries available)"),
                hint,
            )
        else:
            self._paint_dict_list(canvas, painter, list_rect)
        # Helper line under the list. Different copy depending on whether
        # the highlighted row is installed, so the user knows which button
        # is meaningful.
        var help = String(
            "Press Install to download; words appear on the next paint."
        )
        var sel_installed = False
        if 0 <= self.selected_dict and self.selected_dict < len(self.dict_specs):
            sel_installed = user_dictionary_installed(
                self.dict_specs[self.selected_dict].language_id,
            )
            if sel_installed:
                help = String(
                    "Press Remove to delete the on-disk wordlist."
                )
        _ = painter.put_text(
            canvas, Point(inner.a.x, list_bottom), help, hint,
        )
        # Install / Remove buttons row.
        var btn_y = list_bottom + 2
        var ix_x = inner.a.x
        self._buttons[_BTN_DICT_INSTALL].button.move_to(ix_x, btn_y)
        var rm_x = ix_x \
            + self._buttons[_BTN_DICT_INSTALL].button.total_width() + 1
        self._buttons[_BTN_DICT_REMOVE].button.move_to(rm_x, btn_y)
        var has_sel = (self.selected_dict >= 0
                       and self.selected_dict < len(self.dict_specs))
        # Install enabled when a row is selected and not yet installed;
        # Remove enabled when selected row is installed. Both greyed out
        # when no selection (catalog empty) or when the action would be a
        # no-op against the current state.
        self._buttons[_BTN_DICT_INSTALL].enabled = (
            has_sel and not sel_installed
        )
        self._buttons[_BTN_DICT_REMOVE].enabled = (
            has_sel and sel_installed
        )
        self._paint_button(canvas, _BTN_DICT_INSTALL)
        self._paint_button(canvas, _BTN_DICT_REMOVE)

    def _paint_dict_list(
        mut self, mut canvas: Canvas, painter: Painter, list_rect: Rect,
    ):
        """One row per catalog entry: ``[X] German    (de)``.

        Uses the same scroll bookkeeping as the actions list so a long
        catalog stays usable in a short window."""
        var visible = list_rect.height()
        # See _paint_actions_list for the rationale behind the
        # change-only snap.
        if self.selected_dict >= 0 \
                and self.selected_dict != self._last_scroll_dict:
            if self.selected_dict < self._list_scroll:
                self._list_scroll = self.selected_dict
            elif self.selected_dict >= self._list_scroll + visible:
                self._list_scroll = self.selected_dict - visible + 1
        self._last_scroll_dict = self.selected_dict
        if self._list_scroll < 0:
            self._list_scroll = 0
        var max_scroll = len(self.dict_specs) - visible
        if max_scroll < 0:
            max_scroll = 0
        if self._list_scroll > max_scroll:
            self._list_scroll = max_scroll
        var body_attr = Attr(BLACK, CYAN)
        for r in range(visible):
            var idx = self._list_scroll + r
            if idx >= len(self.dict_specs):
                break
            var spec = self.dict_specs[idx]
            var attr = body_attr
            if idx == self.selected_dict:
                attr = (
                    Attr(WHITE, BLUE) if self.focus == _FOCUS_DICT_LIST
                    else Attr(BLACK, GREEN)
                )
                painter.fill(
                    canvas,
                    Rect(list_rect.a.x, list_rect.a.y + r,
                         list_rect.b.x, list_rect.a.y + r + 1),
                    String(" "), attr,
                )
            var mark = String("[X] ") if user_dictionary_installed(
                spec.language_id,
            ) else String("[ ] ")
            var line = mark + spec.display + String("  (") \
                + spec.language_id + String(")")
            _ = painter.put_text(
                canvas, Point(list_rect.a.x + 1, list_rect.a.y + r),
                line, attr,
            )

    def _paint_languages_section(
        mut self, mut canvas: Canvas, painter: Painter, inner: Rect,
    ):
        """List of languages (built-in + user) with their effective
        server priority. Add / Edit / Remove buttons mirror the
        Actions section layout."""
        var hint = Attr(BLUE, LIGHT_GRAY)
        var list_top = inner.a.y + 2
        var list_bottom = inner.b.y - 5
        if list_bottom <= list_top:
            return
        var list_rect = Rect(inner.a.x, list_top, inner.b.x, list_bottom)
        var body_attr = Attr(BLACK, CYAN)
        painter.fill(canvas, list_rect, String(" "), body_attr)
        if len(self.languages_view) == 0:
            _ = painter.put_text(
                canvas, Point(list_rect.a.x + 1, list_rect.a.y),
                String("(no languages — press [+ Add])"),
                hint,
            )
        else:
            self._paint_languages_list(canvas, painter, list_rect)
        # Helper line.
        var help: String
        if self.selected_language >= 0 \
                and self.selected_language < len(self.languages_view):
            var spec = self.languages_view[self.selected_language].copy()
            if _has_override(self.language_overrides, spec.language_id):
                help = String(
                    "Edit to change priority. Remove restores defaults."
                )
            else:
                help = String(
                    "Edit to override the built-in server priority."
                )
        else:
            help = String(
                "Edit a language to change its server priority."
            )
        _ = painter.put_text(
            canvas, Point(inner.a.x, list_bottom), help, hint,
        )
        # Buttons row.
        var btn_y = list_bottom + 2
        var add_x = inner.a.x
        self._buttons[_BTN_LANG_ADD].button.move_to(add_x, btn_y)
        var edit_x = (
            add_x
            + self._buttons[_BTN_LANG_ADD].button.total_width() + 1
        )
        self._buttons[_BTN_LANG_EDIT].button.move_to(edit_x, btn_y)
        var rm_x = (
            edit_x
            + self._buttons[_BTN_LANG_EDIT].button.total_width() + 1
        )
        self._buttons[_BTN_LANG_REMOVE].button.move_to(rm_x, btn_y)
        var has_sel = (
            self.selected_language >= 0
            and self.selected_language < len(self.languages_view)
        )
        self._buttons[_BTN_LANG_EDIT].enabled = has_sel
        # Remove only meaningful for languages with a user override —
        # there's no built-in "default" to revert to otherwise.
        var remove_enabled = False
        if has_sel:
            var spec = self.languages_view[self.selected_language].copy()
            remove_enabled = _has_override(
                self.language_overrides, spec.language_id,
            )
        self._buttons[_BTN_LANG_REMOVE].enabled = remove_enabled
        self._paint_button(canvas, _BTN_LANG_ADD)
        self._paint_button(canvas, _BTN_LANG_EDIT)
        self._paint_button(canvas, _BTN_LANG_REMOVE)

    def _paint_languages_list(
        mut self, mut canvas: Canvas, painter: Painter, list_rect: Rect,
    ):
        var visible = list_rect.height()
        # See _paint_actions_list for the rationale behind the
        # change-only snap.
        if self.selected_language >= 0 \
                and self.selected_language != self._last_scroll_language:
            if self.selected_language < self._list_scroll:
                self._list_scroll = self.selected_language
            elif self.selected_language >= self._list_scroll + visible:
                self._list_scroll = self.selected_language - visible + 1
        self._last_scroll_language = self.selected_language
        if self._list_scroll < 0:
            self._list_scroll = 0
        var max_scroll = len(self.languages_view) - visible
        if max_scroll < 0:
            max_scroll = 0
        if self._list_scroll > max_scroll:
            self._list_scroll = max_scroll
        var body_attr = Attr(BLACK, CYAN)
        for r in range(visible):
            var idx = self._list_scroll + r
            if idx >= len(self.languages_view):
                break
            var spec = self.languages_view[idx].copy()
            var attr = body_attr
            if idx == self.selected_language:
                attr = (
                    Attr(WHITE, BLUE) if self.focus == _FOCUS_LANG_LIST
                    else Attr(BLACK, GREEN)
                )
                painter.fill(
                    canvas,
                    Rect(list_rect.a.x, list_rect.a.y + r,
                         list_rect.b.x, list_rect.a.y + r + 1),
                    String(" "), attr,
                )
            var line = _format_language(
                spec, _has_override(
                    self.language_overrides, spec.language_id,
                ),
            )
            _ = painter.put_text(
                canvas, Point(list_rect.a.x + 1, list_rect.a.y + r),
                line, attr,
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
        # Editor on top eats events first.
        if self.editor.active:
            _ = self.editor.handle_key(event)
            self._maybe_consume_editor()
            return True
        if self.language_editor.active:
            _ = self.language_editor.handle_key(event)
            self._maybe_consume_language_editor()
            return True
        if event.kind != EVENT_KEY:
            return True
        # Save-behavior dropdown swallows keys while open (the popup
        # is modal-ish — see ``Dropdown.handle_key``). Esc closes the
        # popup before it would close the whole Settings view.
        if (self.focus == _FOCUS_SAVE_BEHAVIOR
                and self._save_dropdown.is_open):
            var prev_idx = self._save_dropdown.index
            _ = self._save_dropdown.handle_key(event)
            self._sync_dropdown_commit(prev_idx)
            return True
        if (self.focus == _FOCUS_WRAP_MODE
                and self._wrap_dropdown.is_open):
            var prev_idx = self._wrap_dropdown.index
            _ = self._wrap_dropdown.handle_key(event)
            self._sync_wrap_commit(prev_idx)
            return True
        var k = event.key
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
            elif self.focus == _FOCUS_LIST:
                self._step_action(-1)
            elif self.focus == _FOCUS_DICT_LIST:
                self._step_dict(-1)
            elif self.focus == _FOCUS_LANG_LIST:
                self._step_language(-1)
            elif self.focus == _FOCUS_THEME_LIST:
                self._step_theme(-1)
            elif self.focus == _FOCUS_FONT_LIST:
                self._step_font(-1)
            return True
        if k == KEY_DOWN:
            if self.focus == _FOCUS_SECTIONS:
                self._step_section(1)
            elif self.focus == _FOCUS_LIST:
                self._step_action(1)
            elif self.focus == _FOCUS_DICT_LIST:
                self._step_dict(1)
            elif self.focus == _FOCUS_LANG_LIST:
                self._step_language(1)
            elif self.focus == _FOCUS_THEME_LIST:
                self._step_theme(1)
            elif self.focus == _FOCUS_FONT_LIST:
                self._step_font(1)
            elif self.focus == _FOCUS_SAVE_BEHAVIOR:
                # Closed: open the popup. Forward the keystroke so
                # the highlight starts on the committed row.
                var prev_idx = self._save_dropdown.index
                _ = self._save_dropdown.handle_key(event)
                self._sync_dropdown_commit(prev_idx)
            elif self.focus == _FOCUS_WRAP_MODE:
                var prev_idx = self._wrap_dropdown.index
                _ = self._wrap_dropdown.handle_key(event)
                self._sync_wrap_commit(prev_idx)
            return True
        # Space toggles a focused Editor-section checkbox (matches the
        # cluster-item behavior in the modal dialogs). Intercepted ahead
        # of the type-to-jump fallthrough so it doesn't leak in as a
        # search character.
        if k == KEY_SPACE:
            if self.focus == _FOCUS_TRIM_WS:
                self._toggle_trim_ws()
                return True
            if self.focus == _FOCUS_FINAL_NL:
                self._toggle_final_nl()
                return True
            if self.focus == _FOCUS_COMPRESS_KW:
                self._toggle_compress_kwargs()
                return True
            if self.focus == _FOCUS_BLINK_CURSOR:
                self._toggle_blink_cursor()
                return True
        # Comma-threshold field owns digits + Backspace while focused, ahead
        # of the type-to-jump fallthrough so the digits edit the value
        # instead of leaking in as a list search prefix.
        if self.focus == _FOCUS_COMMA_WRAP:
            if self._comma_input_key(k):
                return True
        # Type-to-jump on whichever section list currently owns focus.
        # Each section produces its own row labels so the user can
        # type "py" to land on the python row regardless of which
        # list (actions / dictionaries / languages) is in front of
        # them.
        if is_printable_ascii(k):
            self._handle_type_to_jump(chr(Int(k)))
            return True
        return True

    def _handle_type_to_jump(mut self, ch: String):
        """Route a printable keystroke into the type-to-jump helper
        and update the focused list's selection. No-op when focus is
        on a non-list widget; the keystroke is still consumed by the
        caller so it doesn't leak back to the underlying workspace."""
        if self.focus == _FOCUS_LIST:
            var labels = List[String]()
            for i in range(len(self.actions)):
                labels.append(_format_action(self.actions[i]))
            var hit = type_ahead_pick(self._type_ahead, labels, ch)
            if hit >= 0:
                self.selected_action = hit
        elif self.focus == _FOCUS_DICT_LIST:
            var labels = List[String]()
            for i in range(len(self.dict_specs)):
                labels.append(self.dict_specs[i].display)
            var hit = type_ahead_pick(self._type_ahead, labels, ch)
            if hit >= 0:
                self.selected_dict = hit
        elif self.focus == _FOCUS_LANG_LIST:
            var labels = List[String]()
            for i in range(len(self.languages_view)):
                labels.append(self.languages_view[i].language_id)
            var hit = type_ahead_pick(self._type_ahead, labels, ch)
            if hit >= 0:
                self.selected_language = hit
        elif self.focus == _FOCUS_THEME_LIST:
            var hit = type_ahead_pick(self._type_ahead, self._theme_names, ch)
            if hit >= 0:
                self._commit_theme(hit)
        elif self.focus == _FOCUS_FONT_LIST:
            var hit = type_ahead_pick(self._type_ahead, self._font_names, ch)
            if hit >= 0:
                self._commit_font(hit)

    def _sync_dropdown_commit(mut self, prev_idx: Int):
        """If the dropdown's committed index moved, propagate it back
        to ``auto_save`` and raise ``dirty``. Called after every event
        that's been routed into ``_save_dropdown`` so the host's
        persistence loop sees the change on the next paint."""
        if self._save_dropdown.index == prev_idx:
            return
        var new_auto = self._save_dropdown.index == 1
        if new_auto != self.auto_save:
            self.auto_save = new_auto
            self.dirty = True

    def _sync_wrap_commit(mut self, prev_idx: Int):
        """If the Wrap dropdown's committed index moved, propagate it to
        ``wrap_mode`` and raise ``dirty`` (the index *is* the
        ``WRAP_*`` value). Mirrors ``_sync_dropdown_commit``."""
        if self._wrap_dropdown.index == prev_idx:
            return
        if self._wrap_dropdown.index != self.wrap_mode:
            self.wrap_mode = self._wrap_dropdown.index
            self.dirty = True

    def _toggle_trim_ws(mut self):
        """Flip the trailing-whitespace toggle, keep the checkbox glyph
        in sync, and raise ``dirty`` so the host persists it."""
        self.trim_trailing_whitespace = not self.trim_trailing_whitespace
        self._trim_cb.on = self.trim_trailing_whitespace
        self.dirty = True

    def _toggle_final_nl(mut self):
        """Counterpart for the final-newline toggle."""
        self.ensure_final_newline = not self.ensure_final_newline
        self._final_nl_cb.on = self.ensure_final_newline
        self.dirty = True

    def _toggle_compress_kwargs(mut self):
        """Counterpart for the compress-keyword-arguments toggle."""
        self.compress_kwargs = not self.compress_kwargs
        self._compress_cb.on = self.compress_kwargs
        self.dirty = True

    def _toggle_blink_cursor(mut self):
        """Counterpart for the blinking-cursor toggle."""
        self.cursor_blink = not self.cursor_blink
        self._blink_cb.on = self.cursor_blink
        self.dirty = True

    def comma_threshold_value(self) -> Int:
        """Parse ``smart_wrap_comma_text`` into the persisted int. Empty
        input → ``-1`` (no comma trigger). The text only ever holds digits
        (the key handler rejects everything else), so this never has to
        cope with sign or stray characters."""
        var bytes = self.smart_wrap_comma_text.as_bytes()
        if len(bytes) == 0:
            return -1
        var v = 0
        for i in range(len(bytes)):
            var d = Int(bytes[i]) - 0x30
            if d < 0 or d > 9:
                return -1
            v = v * 10 + d
        return v

    def _comma_input_key(mut self, k: UInt32) -> Bool:
        """Edit the comma-threshold field. Digits append (capped at 3 so the
        value stays sane and fits the box); Backspace removes the last digit.
        Returns True when the keystroke was consumed."""
        if k == KEY_BACKSPACE:
            var bytes = self.smart_wrap_comma_text.as_bytes()
            if len(bytes) > 0:
                var keep = String("")
                for i in range(len(bytes) - 1):
                    keep += chr(Int(bytes[i]))
                self.smart_wrap_comma_text = keep
                self.dirty = True
            return True
        if k >= UInt32(0x30) and k <= UInt32(0x39):
            if len(self.smart_wrap_comma_text.as_bytes()) >= 3:
                return True
            self.smart_wrap_comma_text += chr(Int(k))
            self.dirty = True
            return True
        return False

    def _next_focus(self, current: UInt8, backward: Bool) -> UInt8:
        # Walk only the widgets that exist on the active section;
        # otherwise Tab from the rail would land on Add/Edit even
        # when Editor is selected.
        var ordered = List[UInt8]()
        ordered.append(_FOCUS_SECTIONS)
        if self.section == _SECTION_ACTIONS:
            # Skip Edit / Remove when there's no selection — same
            # disabled logic the buttons use.
            if len(self.actions) > 0:
                ordered.append(_FOCUS_LIST)
            ordered.append(_FOCUS_ADD)
            if self.selected_action >= 0:
                ordered.append(_FOCUS_EDIT)
                ordered.append(_FOCUS_REMOVE)
        elif self.section == _SECTION_EDITOR:
            ordered.append(_FOCUS_SAVE_BEHAVIOR)
            ordered.append(_FOCUS_WRAP_MODE)
            ordered.append(_FOCUS_COMMA_WRAP)
            ordered.append(_FOCUS_TRIM_WS)
            ordered.append(_FOCUS_FINAL_NL)
            ordered.append(_FOCUS_COMPRESS_KW)
            ordered.append(_FOCUS_BLINK_CURSOR)
        elif self.section == _SECTION_SPELL:
            if len(self.dict_specs) > 0:
                ordered.append(_FOCUS_DICT_LIST)
            # Mirror the actions section: skip whichever button isn't
            # meaningful for the current selection so Tab doesn't land
            # on a greyed-out button.
            var sel_installed = False
            if 0 <= self.selected_dict \
                    and self.selected_dict < len(self.dict_specs):
                sel_installed = user_dictionary_installed(
                    self.dict_specs[self.selected_dict].language_id,
                )
            if self.selected_dict >= 0 and not sel_installed:
                ordered.append(_FOCUS_DICT_INSTALL)
            if self.selected_dict >= 0 and sel_installed:
                ordered.append(_FOCUS_DICT_REMOVE)
        elif self.section == _SECTION_LANGUAGES:
            if len(self.languages_view) > 0:
                ordered.append(_FOCUS_LANG_LIST)
            ordered.append(_FOCUS_LANG_ADD)
            if self.selected_language >= 0 \
                    and self.selected_language < len(self.languages_view):
                ordered.append(_FOCUS_LANG_EDIT)
                var spec = self.languages_view[self.selected_language].copy()
                if _has_override(
                    self.language_overrides, spec.language_id,
                ):
                    ordered.append(_FOCUS_LANG_REMOVE)
        elif self.section == _SECTION_THEME:
            if len(self._theme_names) > 0:
                ordered.append(_FOCUS_THEME_LIST)
        elif self.section == _SECTION_FONT:
            if len(self._font_names) > 0:
                ordered.append(_FOCUS_FONT_LIST)
            ordered.append(_FOCUS_FONT_SMALLER)
            ordered.append(_FOCUS_FONT_LARGER)
            if self._font_ideal_size > 0:
                ordered.append(_FOCUS_FONT_IDEAL)
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

    def _step_section(mut self, delta: Int):
        var labels = self._labels()
        if len(labels) == 0:
            return
        var s = self.section + delta
        if s < 0:
            s = 0
        if s >= len(labels):
            s = len(labels) - 1
        if s != self.section:
            # Switching sections invalidates dropdown popup state from
            # the previous section — close them so a stale popup doesn't
            # paint over the new pane.
            self._save_dropdown.close()
            self._wrap_dropdown.close()
            # Drop any in-flight type-to-jump prefix so the first
            # keystroke after the jump starts a fresh search.
            self._type_ahead.reset()
        self.section = s

    def _step_action(mut self, delta: Int):
        if len(self.actions) == 0:
            return
        var s = self.selected_action + delta
        if s < 0:
            s = 0
        if s >= len(self.actions):
            s = len(self.actions) - 1
        self.selected_action = s

    def _step_dict(mut self, delta: Int):
        if len(self.dict_specs) == 0:
            return
        var s = self.selected_dict + delta
        if s < 0:
            s = 0
        if s >= len(self.dict_specs):
            s = len(self.dict_specs) - 1
        self.selected_dict = s

    def _step_language(mut self, delta: Int):
        if len(self.languages_view) == 0:
            return
        var s = self.selected_language + delta
        if s < 0:
            s = 0
        if s >= len(self.languages_view):
            s = len(self.languages_view) - 1
        self.selected_language = s

    def _commit_theme(mut self, idx: Int):
        """Select theme row ``idx`` and, if it changed the choice, commit it
        and raise ``dirty`` so the host applies + persists it."""
        if idx < 0 or idx >= len(self._theme_names):
            return
        self.selected_theme = idx
        if self._theme_names[idx] != self.theme_choice:
            self.theme_choice = self._theme_names[idx]
            self.dirty = True

    def _step_theme(mut self, delta: Int):
        if len(self._theme_names) == 0:
            return
        var s = self.selected_theme + delta
        if s < 0:
            s = 0
        if s >= len(self._theme_names):
            s = len(self._theme_names) - 1
        self._commit_theme(s)

    def _commit_font(mut self, idx: Int):
        """Select font row ``idx`` and, if it changed the choice, commit it
        and raise ``dirty`` so the host applies + persists it."""
        if idx < 0 or idx >= len(self._font_names):
            return
        self.selected_font = idx
        if self._font_names[idx] != self.font_choice:
            self.font_choice = self._font_names[idx]
            self.dirty = True

    def _step_font(mut self, delta: Int):
        if len(self._font_names) == 0:
            return
        var s = self.selected_font + delta
        if s < 0:
            s = 0
        if s >= len(self._font_names):
            s = len(self._font_names) - 1
        self._commit_font(s)

    def _add_language(mut self):
        var argvs = List[String]()
        var ft = List[String]()
        self.language_editor.open(
            String(""), ft^, argvs^, False,
        )

    def _edit_language(mut self):
        if self.selected_language < 0 \
                or self.selected_language >= len(self.languages_view):
            return
        var spec = self.languages_view[self.selected_language].copy()
        var argvs = List[String]()
        for i in range(len(spec.candidates)):
            argvs.append(_join_argv(spec.candidates[i].argv))
        var built_in = built_in_servers()
        var is_existing = find_language_by_id(
            built_in, spec.language_id,
        ) >= 0
        var file_types = spec.file_types.copy()
        self.language_editor.open(
            spec.language_id, file_types^, argvs^, is_existing,
        )

    def _remove_language_override(mut self):
        if self.selected_language < 0 \
                or self.selected_language >= len(self.languages_view):
            return
        var spec = self.languages_view[self.selected_language].copy()
        var rebuilt = List[LanguageServerOverride]()
        for i in range(len(self.language_overrides)):
            if self.language_overrides[i].language_id == spec.language_id:
                continue
            rebuilt.append(self.language_overrides[i].copy())
        self.language_overrides = rebuilt^
        self.dirty = True
        self._rebuild_languages_view()
        if self.selected_language >= len(self.languages_view):
            self.selected_language = len(self.languages_view) - 1

    def _maybe_consume_language_editor(mut self):
        if not self.language_editor.submitted:
            return
        var entry = self.language_editor.value()
        self.language_editor.close()
        if len(entry.language_id.as_bytes()) == 0:
            return
        # Splice the override into ``language_overrides``: replace if a
        # row already exists for this language id, append otherwise.
        var rebuilt = List[LanguageServerOverride]()
        var replaced = False
        for i in range(len(self.language_overrides)):
            if self.language_overrides[i].language_id \
                    == entry.language_id:
                rebuilt.append(entry.copy())
                replaced = True
            else:
                rebuilt.append(self.language_overrides[i].copy())
        if not replaced:
            rebuilt.append(entry.copy())
        self.language_overrides = rebuilt^
        self.dirty = True
        self._rebuild_languages_view()
        # Keep the cursor on the just-edited language so a follow-up
        # Enter / Edit lands back on it.
        for i in range(len(self.languages_view)):
            if self.languages_view[i].language_id == entry.language_id:
                self.selected_language = i
                break
        self.focus = _FOCUS_LANG_LIST

    def _activate_focus(mut self) -> Bool:
        if self.focus == _FOCUS_ADD:
            self._add_new()
            return True
        if self.focus == _FOCUS_EDIT:
            self._edit_selected()
            return True
        if self.focus == _FOCUS_REMOVE:
            self._remove_selected()
            return True
        if self.focus == _FOCUS_CLOSE:
            self.close()
            return True
        if self.focus == _FOCUS_LIST:
            self._edit_selected()
            return True
        if self.focus == _FOCUS_SAVE_BEHAVIOR:
            var prev_idx = self._save_dropdown.index
            self._save_dropdown.toggle()
            self._sync_dropdown_commit(prev_idx)
            return True
        if self.focus == _FOCUS_WRAP_MODE:
            var prev_idx = self._wrap_dropdown.index
            self._wrap_dropdown.toggle()
            self._sync_wrap_commit(prev_idx)
            return True
        if self.focus == _FOCUS_TRIM_WS:
            self._toggle_trim_ws()
            return True
        if self.focus == _FOCUS_FINAL_NL:
            self._toggle_final_nl()
            return True
        if self.focus == _FOCUS_COMPRESS_KW:
            self._toggle_compress_kwargs()
            return True
        if self.focus == _FOCUS_BLINK_CURSOR:
            self._toggle_blink_cursor()
            return True
        if self.focus == _FOCUS_DICT_INSTALL:
            self._request_dict_install()
            return True
        if self.focus == _FOCUS_DICT_REMOVE:
            self._request_dict_remove()
            return True
        if self.focus == _FOCUS_DICT_LIST:
            # Enter on a row triggers the action that's meaningful for it
            # — the same as if the user had Tabbed to the corresponding
            # button and pressed Enter. Saves a keystroke for the common
            # "highlight, install" flow.
            if 0 <= self.selected_dict \
                    and self.selected_dict < len(self.dict_specs):
                var lang = self.dict_specs[self.selected_dict].language_id
                if user_dictionary_installed(lang):
                    self._request_dict_remove()
                else:
                    self._request_dict_install()
            return True
        if self.focus == _FOCUS_LANG_ADD:
            self._add_language()
            return True
        if self.focus == _FOCUS_LANG_EDIT:
            self._edit_language()
            return True
        if self.focus == _FOCUS_LANG_REMOVE:
            self._remove_language_override()
            return True
        if self.focus == _FOCUS_LANG_LIST:
            self._edit_language()
            return True
        if self.focus == _FOCUS_FONT_SMALLER:
            self._bump_font_size(-1)
            return True
        if self.focus == _FOCUS_FONT_LARGER:
            self._bump_font_size(1)
            return True
        if self.focus == _FOCUS_FONT_IDEAL:
            self._restore_ideal_font_size()
            return True
        return True

    def _request_dict_install(mut self):
        if self.selected_dict < 0 \
                or self.selected_dict >= len(self.dict_specs):
            return
        var lang = self.dict_specs[self.selected_dict].language_id
        if user_dictionary_installed(lang):
            return
        self.pending_dict_install_lang = lang

    def _request_dict_remove(mut self):
        if self.selected_dict < 0 \
                or self.selected_dict >= len(self.dict_specs):
            return
        var lang = self.dict_specs[self.selected_dict].language_id
        if not user_dictionary_installed(lang):
            return
        self.pending_dict_remove_lang = lang

    def ack_dict_install(mut self):
        """Host calls this after picking up ``pending_dict_install_lang``
        and starting the install — clears the field so the request fires
        once."""
        self.pending_dict_install_lang = String("")

    def ack_dict_remove(mut self):
        """Host calls this after performing the remove."""
        self.pending_dict_remove_lang = String("")

    def _add_new(mut self):
        var fresh = OnSaveAction()
        self.editor.open(fresh^, -1)

    def _edit_selected(mut self):
        if self.selected_action < 0 or self.selected_action >= len(self.actions):
            return
        self.editor.open(
            self.actions[self.selected_action].copy(), self.selected_action,
        )

    def _remove_selected(mut self):
        if self.selected_action < 0 or self.selected_action >= len(self.actions):
            return
        var rebuilt = List[OnSaveAction]()
        for i in range(len(self.actions)):
            if i == self.selected_action:
                continue
            rebuilt.append(self.actions[i].copy())
        self.actions = rebuilt^
        self.dirty = True
        if len(self.actions) == 0:
            self.selected_action = -1
            self.focus = _FOCUS_ADD
        elif self.selected_action >= len(self.actions):
            self.selected_action = len(self.actions) - 1

    def _maybe_consume_editor(mut self):
        if not self.editor.submitted:
            return
        var idx = self.editor.edit_index
        var entry = self.editor.value()
        self.editor.close()
        if idx < 0:
            self.actions.append(entry^)
            self.selected_action = len(self.actions) - 1
        else:
            if 0 <= idx and idx < len(self.actions):
                self.actions[idx] = entry^
                self.selected_action = idx
        self.dirty = True
        self.focus = _FOCUS_LIST

    # --- mouse ------------------------------------------------------

    def handle_mouse(mut self, event: Event, screen: Rect) -> Bool:
        if not self.active:
            return False
        if self.editor.active:
            _ = self.editor.handle_mouse(event, screen)
            self._maybe_consume_editor()
            return True
        if self.language_editor.active:
            _ = self.language_editor.handle_mouse(event, screen)
            self._maybe_consume_language_editor()
            return True
        if event.kind != EVENT_MOUSE:
            return True
        self._ensure_bounds(screen)
        var rect = self._workspace_rect(screen)
        # Move / resize chrome first — an in-flight drag owns every event,
        # and border presses must win over the widgets inside.
        if self._handle_window_chrome(event, rect, screen):
            return True
        # Save-behavior dropdown gets first crack on the editor section
        # — both for body clicks (which would otherwise miss the focus
        # walk) and for popup clicks (which sit *above* the dialog
        # body so subsequent hit-tests must skip them).
        if self.section == _SECTION_EDITOR:
            var prev_idx = self._save_dropdown.index
            var hit = self._save_dropdown.handle_mouse(
                self._save_dd_anchor, screen, event,
            )
            self._sync_dropdown_commit(prev_idx)
            if hit == DROPDOWN_HIT_BODY:
                self.focus = _FOCUS_SAVE_BEHAVIOR
                return True
            if hit == DROPDOWN_HIT_POPUP:
                return True
            # ``DROPDOWN_HIT_OUTSIDE`` and ``DROPDOWN_HIT_NONE`` both
            # fall through to the regular dispatch; the popup has
            # already auto-closed in the OUTSIDE case.
            # Wrap-mode dropdown — same first-crack treatment.
            var prev_wrap = self._wrap_dropdown.index
            var wrap_hit = self._wrap_dropdown.handle_mouse(
                self._wrap_dd_anchor, screen, event,
            )
            self._sync_wrap_commit(prev_wrap)
            if wrap_hit == DROPDOWN_HIT_BODY:
                self.focus = _FOCUS_WRAP_MODE
                return True
            if wrap_hit == DROPDOWN_HIT_POPUP:
                return True
            # On-save transform checkboxes. Each runs the shared press /
            # drag / release state machine; we own the toggle so it only
            # flips on a release that lands back on the chip.
            var trim_status = self._trim_cb.handle_mouse(event)
            if trim_status != BUTTON_NONE:
                if trim_status == BUTTON_FIRED:
                    self.focus = _FOCUS_TRIM_WS
                    self._toggle_trim_ws()
                return True
            var nl_status = self._final_nl_cb.handle_mouse(event)
            if nl_status != BUTTON_NONE:
                if nl_status == BUTTON_FIRED:
                    self.focus = _FOCUS_FINAL_NL
                    self._toggle_final_nl()
                return True
            var compress_status = self._compress_cb.handle_mouse(event)
            if compress_status != BUTTON_NONE:
                if compress_status == BUTTON_FIRED:
                    self.focus = _FOCUS_COMPRESS_KW
                    self._toggle_compress_kwargs()
                return True
            var blink_status = self._blink_cb.handle_mouse(event)
            if blink_status != BUTTON_NONE:
                if blink_status == BUTTON_FIRED:
                    self.focus = _FOCUS_BLINK_CURSOR
                    self._toggle_blink_cursor()
                return True
            # Click the comma-threshold box to focus it; editing is keyboard.
            if event.button == MOUSE_BUTTON_LEFT and event.pressed \
                    and not event.motion \
                    and self._comma_input_anchor.contains(event.pos):
                self.focus = _FOCUS_COMMA_WRAP
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
            var labels = self._labels()
            if 0 <= idx and idx < len(labels):
                if idx != self.section:
                    self._save_dropdown.close()
                    self._wrap_dropdown.close()
                self.section = idx
                self.focus = _FOCUS_SECTIONS
            return True
        # Right pane list — both the actions list and the dictionaries
        # list share geometry; dispatch by section.
        if self.section == _SECTION_ACTIONS:
            var list_top = rect.a.y + 2 + 2
            var list_bottom = rect.b.y - 2 - 5
            var inner = self._right_rect(rect)
            var list_rect = Rect(inner.a.x, list_top, inner.b.x, list_bottom)
            if list_rect.contains(event.pos):
                var idx = self._list_scroll + (event.pos.y - list_rect.a.y)
                if 0 <= idx and idx < len(self.actions):
                    self.selected_action = idx
                self.focus = _FOCUS_LIST
                return True
        elif self.section == _SECTION_SPELL:
            var list_top = rect.a.y + 2 + 2
            var list_bottom = rect.b.y - 2 - 5
            var inner = self._right_rect(rect)
            var list_rect = Rect(inner.a.x, list_top, inner.b.x, list_bottom)
            if list_rect.contains(event.pos):
                var idx = self._list_scroll + (event.pos.y - list_rect.a.y)
                if 0 <= idx and idx < len(self.dict_specs):
                    self.selected_dict = idx
                self.focus = _FOCUS_DICT_LIST
                return True
        elif self.section == _SECTION_LANGUAGES:
            var list_top = rect.a.y + 2 + 2
            var list_bottom = rect.b.y - 2 - 5
            var inner = self._right_rect(rect)
            var list_rect = Rect(inner.a.x, list_top, inner.b.x, list_bottom)
            if list_rect.contains(event.pos):
                var idx = self._list_scroll + (event.pos.y - list_rect.a.y)
                if 0 <= idx and idx < len(self.languages_view):
                    self.selected_language = idx
                self.focus = _FOCUS_LANG_LIST
                if Int(event.click_count) >= 2 \
                        and 0 <= self.selected_language \
                        and self.selected_language < len(self.languages_view):
                    self._edit_language()
                return True
        elif self.section == _SECTION_THEME:
            var inner = self._right_rect(rect)
            var split = inner.a.x + 20
            if split > inner.b.x - 12:
                split = inner.b.x - 12
            var list_rect = Rect(
                inner.a.x, inner.a.y + 2, split, inner.b.y - 1,
            )
            if list_rect.contains(event.pos):
                var idx = event.pos.y - list_rect.a.y
                self._commit_theme(idx)
                self.focus = _FOCUS_THEME_LIST
                return True
        elif self.section == _SECTION_FONT:
            var inner = self._right_rect(rect)
            # +5: the size-stepper row (face + shadow + a blank row)
            # sits above the family list — keep in sync with
            # ``_paint_font_section``.
            var list_rect = Rect(
                inner.a.x, inner.a.y + 5, inner.b.x, inner.b.y - 1,
            )
            if list_rect.contains(event.pos):
                var idx = self._list_scroll + (event.pos.y - list_rect.a.y)
                self._commit_font(idx)
                self.focus = _FOCUS_FONT_LIST
                return True
        return True

    def _dispatch_buttons(mut self, event: Event) -> Bool:
        # Only dispatch buttons that belong to the current section (plus
        # the always-on Close button). Buttons not painted this frame
        # still hold their last-painted positions from a different
        # section; without this gate, a click in the spell pane that
        # happens to fall under where Add/Edit/Remove last rendered
        # would fire them.
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
        if self.section == _SECTION_ACTIONS:
            return idx == _BTN_ADD or idx == _BTN_EDIT or idx == _BTN_REMOVE
        if self.section == _SECTION_SPELL:
            return idx == _BTN_DICT_INSTALL or idx == _BTN_DICT_REMOVE
        if self.section == _SECTION_LANGUAGES:
            return (
                idx == _BTN_LANG_ADD or idx == _BTN_LANG_EDIT
                or idx == _BTN_LANG_REMOVE
            )
        if self.section == _SECTION_FONT:
            if idx == _BTN_FONT_IDEAL:
                # Not painted at all when the host reported no ideal —
                # its stale rect must not eat clicks.
                return self._font_ideal_size > 0
            return idx == _BTN_FONT_SMALLER or idx == _BTN_FONT_LARGER
        return False


# --- helpers --------------------------------------------------------------


def _has_override(
    overrides: List[LanguageServerOverride], language_id: String,
) -> Bool:
    for i in range(len(overrides)):
        if overrides[i].language_id == language_id:
            return True
    return False


def _format_language(spec: LanguageSpec, has_override: Bool) -> String:
    """One-line label: ``<id>  <ext1 ext2>  <count> server(s)``.

    A ``*`` prefix marks languages with a user override so the section
    list doubles as a "what have I customized" dashboard.
    """
    var prefix = String("* ") if has_override else String("  ")
    var line = prefix + spec.language_id
    var ft_text = String("")
    for i in range(len(spec.file_types)):
        if i > 0:
            ft_text = ft_text + String(" ")
        ft_text = ft_text + spec.file_types[i]
    if len(ft_text.as_bytes()) > 0:
        line = line + String("  (") + ft_text + String(")")
    var count = len(spec.candidates)
    var count_str: String
    if count == 0:
        count_str = String("no servers")
    elif count == 1:
        count_str = String("1 server")
    else:
        count_str = String(count) + String(" servers")
    line = line + String("  — ") + count_str
    return line^


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
    return String(StringSlice(ptr=buf.unsafe_ptr(), length=len(buf)))


def _format_action(act: OnSaveAction) -> String:
    """One-line label: ``<lang>  <program> <args>``. Empty language
    renders as ``(any)`` so the user can tell why an action fires for
    every save."""
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
