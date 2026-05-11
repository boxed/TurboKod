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
    BUTTON_FIRED, BUTTON_NONE, ShadowButton, paint_shadow_button,
)
from .canvas import Canvas
from .painter import Painter
from .cell import Cell
from .colors import (
    Attr, BLACK, BLUE, CYAN, DARK_GRAY, GREEN, LIGHT_GRAY, WHITE,
)
from .config import LanguageServerOverride, OnSaveAction
from .dictionary_install import (
    DownloadableDictionary, built_in_downloadable_dictionaries,
    user_dictionary_installed,
)
from .language_config import (
    LanguageSpec, ServerCandidate, apply_language_overrides,
    built_in_servers, find_language_by_id,
)
from .language_editor import LanguageEditor
from .dropdown import (
    DROPDOWN_HIT_BODY, DROPDOWN_HIT_NONE, DROPDOWN_HIT_OUTSIDE,
    DROPDOWN_HIT_POPUP, Dropdown,
)
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_DOWN, KEY_ENTER, KEY_ESC, KEY_TAB, KEY_UP,
    MOD_NONE, MOD_SHIFT, MOUSE_BUTTON_LEFT,
    MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .geometry import Point, Rect
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
comptime _FOCUS_DICT_LIST     = UInt8(7)
comptime _FOCUS_DICT_INSTALL  = UInt8(8)
comptime _FOCUS_DICT_REMOVE   = UInt8(9)
comptime _FOCUS_LANG_LIST     = UInt8(10)
comptime _FOCUS_LANG_ADD      = UInt8(11)
comptime _FOCUS_LANG_EDIT     = UInt8(12)
comptime _FOCUS_LANG_REMOVE   = UInt8(13)


# --- section indices ------------------------------------------------------

comptime _SECTION_ACTIONS   = 0
comptime _SECTION_EDITOR    = 1
comptime _SECTION_SPELL     = 2
comptime _SECTION_LANGUAGES = 3


# --- layout ---------------------------------------------------------------

comptime _SECTION_W = 22


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

# Width of the inline dropdown strip in the Editor section. Wide enough
# for "Automatic" plus the right-edge ``▼`` indicator.
comptime _SAVE_DD_W = 16


fn _section_labels() -> List[String]:
    """Section names rendered in the left rail. Add new section names
    here and a matching ``_paint_section_*`` / ``_handle_*`` branch
    below; nothing else needs to change."""
    var out = List[String]()
    out.append(String("Actions on save"))
    out.append(String("Editor"))
    out.append(String("Spell check"))
    out.append(String("Languages"))
    return out^


fn _save_behavior_options() -> List[String]:
    """Dropdown options for the Editor ▸ Save behavior picker. Order
    here is the order rendered in the popup; index 0 is the default
    when no value is committed."""
    var out = List[String]()
    out.append(String("Manual"))
    out.append(String("Automatic"))
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
    var _type_ahead: TypeAhead
    """Shared type-to-jump prefix buffer for whichever section list
    currently owns focus. Reset on focus / section changes so a
    stale buffer doesn't misroute the first keystroke after the
    user moves between panes."""

    fn __init__(out self):
        self.active = False
        self.dirty = False
        self.actions = List[OnSaveAction]()
        self.auto_save = False
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
        self._save_dropdown = Dropdown(_save_behavior_options(), 0)
        self._save_dd_anchor = Rect(0, 0, 0, 0)
        self.dict_specs = List[DownloadableDictionary]()
        self.selected_dict = 0
        self.pending_dict_install_lang = String("")
        self.pending_dict_remove_lang = String("")
        self.language_overrides = List[LanguageServerOverride]()
        self.languages_view = List[LanguageSpec]()
        self.selected_language = -1
        self.language_editor = LanguageEditor()
        self._type_ahead = TypeAhead()

    fn open(
        mut self, var actions: List[OnSaveAction], auto_save: Bool,
        var language_overrides: List[LanguageServerOverride] = List[LanguageServerOverride](),
    ):
        self.actions = actions^
        self.auto_save = auto_save
        self.active = True
        self.dirty = False
        self.section = 0
        self.selected_action = 0 if len(self.actions) > 0 else -1
        self.focus = _FOCUS_SECTIONS
        self._list_scroll = 0
        self._last_scroll_action = -2
        self._last_scroll_dict = -2
        self._last_scroll_language = -2
        self._save_dropdown = Dropdown(
            _save_behavior_options(), 1 if auto_save else 0,
        )
        self.dict_specs = built_in_downloadable_dictionaries()
        self.selected_dict = 0 if len(self.dict_specs) > 0 else -1
        self.pending_dict_install_lang = String("")
        self.pending_dict_remove_lang = String("")
        self.language_overrides = language_overrides^
        self._rebuild_languages_view()
        self.selected_language = (
            0 if len(self.languages_view) > 0 else -1
        )

    fn _rebuild_languages_view(mut self):
        self.languages_view = apply_language_overrides(
            built_in_servers(), self.language_overrides,
        )

    fn close(mut self):
        self.active = False
        self.actions = List[OnSaveAction]()
        self.auto_save = False
        self.section = 0
        self.selected_action = -1
        self.focus = _FOCUS_SECTIONS
        self._list_scroll = 0
        self.editor.close()
        self._save_dropdown.close()
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

    fn ack_dirty(mut self):
        """Host calls this after persisting ``self.actions`` to disk."""
        self.dirty = False

    # --- painting ---------------------------------------------------

    fn paint(mut self, mut canvas: Canvas, screen: Rect):
        if not self.active:
            return
        var rect = self._workspace_rect(screen)
        var bg = Attr(BLACK, LIGHT_GRAY)
        var border = Attr(WHITE, LIGHT_GRAY)
        # Bind every write inside the Settings dialog to its workspace
        # rect — ``rect`` excludes the menu bar above and status bar
        # below, so even an over-wide section row can't bleed into
        # them.
        var painter = Painter(rect)
        painter.fill(canvas, rect, String(" "), bg)
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
        # Editor floats on top.
        if self.editor.active:
            self.editor.paint(canvas, screen)
        if self.language_editor.active:
            self.language_editor.paint(canvas, screen)

    fn _workspace_rect(self, screen: Rect) -> Rect:
        """Settings takes the workspace area — ``screen`` minus the
        menu bar (row 0) and status bar (last row). The host paints
        those above/below us so the user keeps their bearings."""
        var top = 1 if screen.b.y > 2 else 0
        var bottom = screen.b.y - 1 if screen.b.y > 2 else screen.b.y
        return Rect(screen.a.x, top, screen.b.x, bottom)

    fn _sections_rect(self, rect: Rect) -> Rect:
        """Inner area of the left rail (inside the framed border)."""
        return Rect(
            rect.a.x + 2, rect.a.y + 2,
            rect.a.x + 2 + _SECTION_W, rect.b.y - 2,
        )

    fn _right_rect(self, rect: Rect) -> Rect:
        return Rect(
            rect.a.x + 2 + _SECTION_W + 2, rect.a.y + 2,
            rect.b.x - 2, rect.b.y - 2,
        )

    fn _paint_sections(
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
                    canvas,
                    Rect(inner.a.x, y, inner.b.x, y + 1),
                    String(" "), attr,
                )
            _ = sub.put_text(
                canvas, Point(inner.a.x + 1, y), labels[i], attr,
            )

    fn _paint_right_pane(
        mut self, mut canvas: Canvas, painter: Painter, rect: Rect,
    ):
        var inner = self._right_rect(rect)
        var sub = painter.sub(inner)
        var bg = Attr(BLACK, LIGHT_GRAY)
        # Header.
        var labels = _section_labels()
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

    fn _paint_actions_section(
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

    fn _paint_actions_list(
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
            var act = self.actions[idx]
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

    fn _paint_editor_section(
        mut self, mut canvas: Canvas, painter: Painter, inner: Rect,
    ):
        """Editor preferences pane. Single row for now: a label and an
        inline ``Save behavior`` dropdown."""
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
        var dd_x = inner.a.x + len(label.as_bytes()) + 1
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

    fn _paint_spell_section(
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

    fn _paint_dict_list(
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

    fn _paint_languages_section(
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
            var spec = self.languages_view[self.selected_language]
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
            var spec = self.languages_view[self.selected_language]
            remove_enabled = _has_override(
                self.language_overrides, spec.language_id,
            )
        self._buttons[_BTN_LANG_REMOVE].enabled = remove_enabled
        self._paint_button(canvas, _BTN_LANG_ADD)
        self._paint_button(canvas, _BTN_LANG_EDIT)
        self._paint_button(canvas, _BTN_LANG_REMOVE)

    fn _paint_languages_list(
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
            var spec = self.languages_view[idx]
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

    fn _paint_close_button(mut self, mut canvas: Canvas, rect: Rect):
        var close = self._buttons[_BTN_CLOSE]
        var btn_w = close.button.face_width()
        var btn_x = rect.b.x - 2 - (btn_w + 1)
        var btn_y = rect.b.y - 3
        self._buttons[_BTN_CLOSE].button.move_to(btn_x, btn_y)
        self._paint_button(canvas, _BTN_CLOSE)

    fn _paint_button(mut self, mut canvas: Canvas, idx: Int):
        var pb = self._buttons[idx]
        var face: Attr
        if not pb.enabled:
            face = Attr(LIGHT_GRAY, GREEN)
        elif self.focus == pb.focus:
            face = Attr(WHITE, BLUE)
        else:
            face = Attr(BLACK, GREEN)
        paint_shadow_button(canvas, pb.button, face, LIGHT_GRAY)

    # --- key handling -----------------------------------------------

    fn handle_key(mut self, event: Event) -> Bool:
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
            elif self.focus == _FOCUS_SAVE_BEHAVIOR:
                # Closed: open the popup. Forward the keystroke so
                # the highlight starts on the committed row.
                var prev_idx = self._save_dropdown.index
                _ = self._save_dropdown.handle_key(event)
                self._sync_dropdown_commit(prev_idx)
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

    fn _handle_type_to_jump(mut self, ch: String):
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

    fn _sync_dropdown_commit(mut self, prev_idx: Int):
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

    fn _next_focus(self, current: UInt8, backward: Bool) -> UInt8:
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
                var spec = self.languages_view[self.selected_language]
                if _has_override(
                    self.language_overrides, spec.language_id,
                ):
                    ordered.append(_FOCUS_LANG_REMOVE)
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

    fn _step_section(mut self, delta: Int):
        var labels = _section_labels()
        if len(labels) == 0:
            return
        var s = self.section + delta
        if s < 0:
            s = 0
        if s >= len(labels):
            s = len(labels) - 1
        if s != self.section:
            # Switching sections invalidates dropdown popup state from
            # the previous section — close it so a stale popup doesn't
            # paint over the new pane.
            self._save_dropdown.close()
            # Drop any in-flight type-to-jump prefix so the first
            # keystroke after the jump starts a fresh search.
            self._type_ahead.reset()
        self.section = s

    fn _step_action(mut self, delta: Int):
        if len(self.actions) == 0:
            return
        var s = self.selected_action + delta
        if s < 0:
            s = 0
        if s >= len(self.actions):
            s = len(self.actions) - 1
        self.selected_action = s

    fn _step_dict(mut self, delta: Int):
        if len(self.dict_specs) == 0:
            return
        var s = self.selected_dict + delta
        if s < 0:
            s = 0
        if s >= len(self.dict_specs):
            s = len(self.dict_specs) - 1
        self.selected_dict = s

    fn _step_language(mut self, delta: Int):
        if len(self.languages_view) == 0:
            return
        var s = self.selected_language + delta
        if s < 0:
            s = 0
        if s >= len(self.languages_view):
            s = len(self.languages_view) - 1
        self.selected_language = s

    fn _add_language(mut self):
        var argvs = List[String]()
        var ft = List[String]()
        self.language_editor.open(
            String(""), ft^, argvs^, False,
        )

    fn _edit_language(mut self):
        if self.selected_language < 0 \
                or self.selected_language >= len(self.languages_view):
            return
        var spec = self.languages_view[self.selected_language]
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

    fn _remove_language_override(mut self):
        if self.selected_language < 0 \
                or self.selected_language >= len(self.languages_view):
            return
        var spec = self.languages_view[self.selected_language]
        var rebuilt = List[LanguageServerOverride]()
        for i in range(len(self.language_overrides)):
            if self.language_overrides[i].language_id == spec.language_id:
                continue
            rebuilt.append(self.language_overrides[i])
        self.language_overrides = rebuilt^
        self.dirty = True
        self._rebuild_languages_view()
        if self.selected_language >= len(self.languages_view):
            self.selected_language = len(self.languages_view) - 1

    fn _maybe_consume_language_editor(mut self):
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
                rebuilt.append(entry)
                replaced = True
            else:
                rebuilt.append(self.language_overrides[i])
        if not replaced:
            rebuilt.append(entry)
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

    fn _activate_focus(mut self) -> Bool:
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
        return True

    fn _request_dict_install(mut self):
        if self.selected_dict < 0 \
                or self.selected_dict >= len(self.dict_specs):
            return
        var lang = self.dict_specs[self.selected_dict].language_id
        if user_dictionary_installed(lang):
            return
        self.pending_dict_install_lang = lang

    fn _request_dict_remove(mut self):
        if self.selected_dict < 0 \
                or self.selected_dict >= len(self.dict_specs):
            return
        var lang = self.dict_specs[self.selected_dict].language_id
        if not user_dictionary_installed(lang):
            return
        self.pending_dict_remove_lang = lang

    fn ack_dict_install(mut self):
        """Host calls this after picking up ``pending_dict_install_lang``
        and starting the install — clears the field so the request fires
        once."""
        self.pending_dict_install_lang = String("")

    fn ack_dict_remove(mut self):
        """Host calls this after performing the remove."""
        self.pending_dict_remove_lang = String("")

    fn _add_new(mut self):
        var fresh = OnSaveAction()
        self.editor.open(fresh^, -1)

    fn _edit_selected(mut self):
        if self.selected_action < 0 or self.selected_action >= len(self.actions):
            return
        self.editor.open(
            self.actions[self.selected_action], self.selected_action,
        )

    fn _remove_selected(mut self):
        if self.selected_action < 0 or self.selected_action >= len(self.actions):
            return
        var rebuilt = List[OnSaveAction]()
        for i in range(len(self.actions)):
            if i == self.selected_action:
                continue
            rebuilt.append(self.actions[i])
        self.actions = rebuilt^
        self.dirty = True
        if len(self.actions) == 0:
            self.selected_action = -1
            self.focus = _FOCUS_ADD
        elif self.selected_action >= len(self.actions):
            self.selected_action = len(self.actions) - 1

    fn _maybe_consume_editor(mut self):
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

    fn handle_mouse(mut self, event: Event, screen: Rect) -> Bool:
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
        var rect = self._workspace_rect(screen)
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
            var labels = _section_labels()
            if 0 <= idx and idx < len(labels):
                if idx != self.section:
                    self._save_dropdown.close()
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
                return True
        return True

    fn _dispatch_buttons(mut self, event: Event) -> Bool:
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

    fn _button_active_for_section(self, idx: Int) -> Bool:
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
        return False


# --- helpers --------------------------------------------------------------


fn _has_override(
    overrides: List[LanguageServerOverride], language_id: String,
) -> Bool:
    for i in range(len(overrides)):
        if overrides[i].language_id == language_id:
            return True
    return False


fn _format_language(spec: LanguageSpec, has_override: Bool) -> String:
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


fn _join_argv(argv: List[String]) -> String:
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


fn _shell_quote(s: String) -> String:
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


fn _format_action(act: OnSaveAction) -> String:
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
