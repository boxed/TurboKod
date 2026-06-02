"""Modal dialog for editing the project's syntax-grammar overrides,
persisted to ``<project>/.turbokod/grammars.json``.

The bundled extension → grammar map is one-size-fits-all (``.html``
always means vanilla HTML, etc.). A project opens this dialog from
``Project ▸ Configure project grammars…`` to say "use the django-html
grammar for .html files here" without touching the shipped map.

Layout::

    ╔═══════════ Configure Project Grammars ══════════════════════╗
    ║ Extensions:              Extension: […………………]               ║
    ║ ┌──────────────────────┐                                    ║
    ║ │ html → django-html  ▒│ Language:  < django-html        >  ║
    ║ │ txt  → django-txt    │                                    ║
    ║ │                      │ (pick a bundled or downloadable    ║
    ║ │                      │  grammar; uninstalled ones prompt  ║
    ║ │                      │  to download on save)              ║
    ║ └──────────────────────┘                                    ║
    ║ [+ Add]  [- Remove]                   [Save]    [Cancel]    ║
    ╚═════════════════════════════════════════════════════════════╝

A trimmed sibling of ``TargetsDialog`` — same FocusGroup / list /
ShadowButton machinery, two right-side controls instead of five. The
dialog edits a private copy; ``Save`` sets ``submitted`` and the host
reads ``into_overrides()`` then persists + refreshes the registry.
``Cancel`` / ESC / close-box discard the copy.
"""

from std.collections.list import List
from std.collections.optional import Optional

from .buttons import (
    BUTTON_FIRED, BUTTON_NONE, ShadowButton, paint_shadow_button,
)
from .canvas import Canvas, paint_drop_shadow
from .painter import Painter
from .colors import (
    Attr, BLACK, BLUE, CYAN, GREEN, LIGHT_GRAY, WHITE,
)
from .dropdown import (
    DROPDOWN_HIT_NONE, DROPDOWN_HIT_OUTSIDE, Dropdown,
)
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_DOWN, KEY_ENTER, KEY_ESC, KEY_LEFT, KEY_RIGHT,
    KEY_TAB, KEY_UP,
    MOD_SHIFT, MOUSE_BUTTON_LEFT, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .geometry import Point, Rect, compute_dialog_rect
from .grammar_install import built_in_downloadable_grammars
from .highlight import bundled_grammar_languages
from .project_grammars import GrammarOverride
from .text_field import TextField
from .view import FocusGroup, RowCursor
from .window import (
    hit_close_button, paint_close_button, paint_window_title,
)


# --- focus slot indices --------------------------------------------------

comptime _SLOT_LIST    = 0
comptime _SLOT_EXT     = 1
comptime _SLOT_LANG    = 2
comptime _SLOT_ADD     = 3
comptime _SLOT_REMOVE  = 4
comptime _SLOT_SAVE    = 5
comptime _SLOT_CANCEL  = 6
comptime _SLOT_COUNT   = 7


# --- layout ---------------------------------------------------------------

comptime _DIALOG_W = 64
comptime _DIALOG_H = 16
comptime _LIST_W   = 24
"""Width of the left-side extensions list — wide enough for
``ext → language-id``."""
comptime _LIST_TOP = 3
comptime _LIST_BOT = 4
comptime _LABEL_W  = 12


def _dialog_rect(screen: Rect, pos: Optional[Point]) -> Rect:
    return compute_dialog_rect(screen, pos, _DIALOG_W, _DIALOG_H)


@fieldwise_init
struct _Layout(ImplicitlyCopyable, Movable):
    var list_rect: Rect
    var list_label_pt: Point
    var ext_rect: Rect
    var lang_rect: Rect
    var hint_y: Int
    var buttons_y: Int
    var label_x: Int


def _build_layout(rect: Rect) -> _Layout:
    var cursor = RowCursor(rect.a.y + 2)
    var ext_y = cursor.place()
    cursor.skip(1)
    var lang_y = cursor.place()
    var list_left = rect.a.x + 2
    var list_right = list_left + _LIST_W
    var label_x = list_right + 2
    var field_x = label_x + _LABEL_W
    var right_max = rect.b.x - 2
    return _Layout(
        Rect(list_left, rect.a.y + _LIST_TOP, list_right, rect.b.y - _LIST_BOT),
        Point(rect.a.x + 2, ext_y),
        Rect(field_x, ext_y, right_max, ext_y + 1),
        Rect(field_x, lang_y, right_max, lang_y + 1),
        lang_y + 2,
        rect.b.y - 3,
        label_x,
    )


@fieldwise_init
struct _PlacedButton(ImplicitlyCopyable, Movable):
    var button: ShadowButton
    var slot: Int
    var enabled: Bool


def _build_grammar_dropdown(var current: String) -> Dropdown:
    """``(none)`` followed by every grammar language the user can map
    an extension onto: bundled grammars first, then downloadable ones
    not already bundled. ``set_value`` keeps a hand-authored id that
    isn't in the list by appending it rather than snapping away."""
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


# --- GrammarsDialog -------------------------------------------------------


struct GrammarsDialog(Movable):
    var active: Bool
    var submitted: Bool
    """Set on Save. Host reads ``into_overrides()`` then calls ``close()``."""
    var entries: List[GrammarOverride]
    """Editable copy. Only flows back to the host on submit."""
    var selected: Int
    var _focus: FocusGroup
    var pos: Optional[Point]
    var _drag: Optional[Point]
    var _list_scroll: Int
    var _last_scroll_sel: Int
    var _buttons: List[_PlacedButton]
    var ext_tf: TextField
    var lang_dropdown: Dropdown

    def __init__(out self):
        self.active = False
        self.submitted = False
        self.entries = List[GrammarOverride]()
        self.selected = -1
        self._focus = FocusGroup(_SLOT_COUNT)
        self._focus.focus_force(_SLOT_LIST)
        self.pos = Optional[Point]()
        self._drag = Optional[Point]()
        self._list_scroll = 0
        self._last_scroll_sel = -2
        self.ext_tf = TextField()
        self.lang_dropdown = _build_grammar_dropdown(String(""))
        self._buttons = List[_PlacedButton]()
        self._buttons.append(_PlacedButton(
            ShadowButton(String(" + Add "), 0, 0), _SLOT_ADD, True,
        ))
        self._buttons.append(_PlacedButton(
            ShadowButton(String(" - Remove "), 0, 0), _SLOT_REMOVE, True,
        ))
        self._buttons.append(_PlacedButton(
            ShadowButton(String(" Save "), 0, 0), _SLOT_SAVE, True,
        ))
        self._buttons.append(_PlacedButton(
            ShadowButton(String(" Cancel "), 0, 0), _SLOT_CANCEL, True,
        ))

    def open(mut self, var overrides: List[GrammarOverride]):
        self.entries = overrides^
        self.selected = 0 if len(self.entries) > 0 else -1
        self.active = True
        self.submitted = False
        self._focus.focus_force(
            _SLOT_LIST if len(self.entries) > 0 else _SLOT_ADD
        )
        self.pos = Optional[Point]()
        self._drag = Optional[Point]()
        self._list_scroll = 0
        self._last_scroll_sel = -2
        self._load_fields_from_selected()

    def close(mut self):
        self.active = False
        self.submitted = False
        self.entries = List[GrammarOverride]()
        self.selected = -1
        self._focus.focus_force(_SLOT_LIST)
        self.pos = Optional[Point]()
        self._drag = Optional[Point]()
        self._list_scroll = 0
        self.lang_dropdown = _build_grammar_dropdown(String(""))
        for i in range(len(self._buttons)):
            self._buttons[i].button.pressed = False
            self._buttons[i].button.pressed_inside = False

    def into_overrides(self) -> List[GrammarOverride]:
        """Build the override list for the host. Half-filled rows (empty
        extension or empty language) are dropped — the writer drops them
        too, but doing it here keeps the in-memory registry clean."""
        var out = List[GrammarOverride]()
        for i in range(len(self.entries)):
            var e = self.entries[i].copy()
            if len(e.ext.as_bytes()) == 0 or len(e.language_id.as_bytes()) == 0:
                continue
            out.append(GrammarOverride(e.ext, e.language_id))
        return out^

    # --- editing operations -----------------------------------------

    def _add_new(mut self):
        self._commit_fields_to_selected()
        self.entries.append(GrammarOverride(String(""), String("")))
        self.selected = len(self.entries) - 1
        self._focus.focus_force(_SLOT_EXT)
        self._scroll_selection_into_view()
        self._load_fields_from_selected()

    def _remove_selected(mut self):
        if self.selected < 0 or self.selected >= len(self.entries):
            return
        var rebuilt = List[GrammarOverride]()
        for i in range(len(self.entries)):
            if i == self.selected:
                continue
            rebuilt.append(GrammarOverride(
                self.entries[i].ext, self.entries[i].language_id,
            ))
        self.entries = rebuilt^
        if len(self.entries) == 0:
            self.selected = -1
            self._focus.focus_force(_SLOT_ADD)
        else:
            if self.selected >= len(self.entries):
                self.selected = len(self.entries) - 1
            self._focus.focus_force(_SLOT_LIST)
        self._load_fields_from_selected()

    def _load_fields_from_selected(mut self):
        if self.selected < 0 or self.selected >= len(self.entries):
            self.ext_tf = TextField()
            self.lang_dropdown = _build_grammar_dropdown(String(""))
            return
        var e = self.entries[self.selected].copy()
        self.ext_tf = TextField()
        self.ext_tf.set_text(e.ext)
        self.lang_dropdown = _build_grammar_dropdown(e.language_id)

    def _commit_fields_to_selected(mut self):
        if self.selected < 0 or self.selected >= len(self.entries):
            return
        self.entries[self.selected] = GrammarOverride(
            self.ext_tf.text, self.lang_dropdown.value(),
        )

    def _commit_lang_dropdown(mut self):
        if self.selected < 0:
            return
        self.entries[self.selected] = GrammarOverride(
            self.ext_tf.text, self.lang_dropdown.value(),
        )

    # --- focus walk -------------------------------------------------

    def _refresh_focus_visitability(mut self, layout: _Layout):
        var has_entries = len(self.entries) > 0
        var has_sel = self.selected >= 0
        self._focus.update(_SLOT_LIST, layout.list_rect, has_entries)
        self._focus.update(_SLOT_EXT, layout.ext_rect, has_sel)
        self._focus.update(_SLOT_LANG, layout.lang_rect, has_sel)
        self._focus.slots[_SLOT_REMOVE].visitable = has_entries
        self._focus.slots[_SLOT_ADD].visitable = True
        self._focus.slots[_SLOT_SAVE].visitable = True
        self._focus.slots[_SLOT_CANCEL].visitable = True
        self._focus.reconcile()

    # --- painting ---------------------------------------------------

    def paint(mut self, mut canvas: Canvas, screen: Rect):
        if not self.active:
            return
        var bg = Attr(BLACK, LIGHT_GRAY)
        var border = Attr(WHITE, LIGHT_GRAY)
        var rect = _dialog_rect(screen, self.pos)
        var layout = _build_layout(rect)
        self._refresh_focus_visitability(layout)
        paint_drop_shadow(canvas, rect)
        var painter = Painter(rect)
        painter.fill(canvas, rect, String(" "), bg)
        painter.draw_box(canvas, rect, border, True)
        paint_window_title(
            canvas, rect, String(" Configure Project Grammars "), bg, bg,
        )
        paint_close_button(canvas, Point(rect.a.x, rect.a.y), border)
        _ = painter.put_text(
            canvas, layout.list_label_pt, String("Extensions:"), bg,
        )
        self._paint_list(canvas, painter, layout.list_rect)
        self._paint_form(canvas, painter, layout)
        self._paint_buttons(canvas, rect, layout)
        if self.lang_dropdown.is_open:
            self.lang_dropdown.paint_popup(canvas, layout.lang_rect, screen)

    def _paint_list(
        mut self, mut canvas: Canvas, painter: Painter, list_rect: Rect,
    ):
        var body_attr = Attr(BLACK, CYAN)
        var inner = list_rect
        painter.fill(canvas, inner, String(" "), body_attr)
        var visible = inner.height()
        if self.selected >= 0 and self.selected != self._last_scroll_sel:
            if self.selected < self._list_scroll:
                self._list_scroll = self.selected
            elif self.selected >= self._list_scroll + visible:
                self._list_scroll = self.selected - visible + 1
        self._last_scroll_sel = self.selected
        if self._list_scroll < 0:
            self._list_scroll = 0
        var max_scroll = len(self.entries) - visible
        if max_scroll < 0:
            max_scroll = 0
        if self._list_scroll > max_scroll:
            self._list_scroll = max_scroll
        for r in range(visible):
            var idx = self._list_scroll + r
            if idx >= len(self.entries):
                break
            var e = self.entries[idx].copy()
            var ext_label = e.ext if len(e.ext.as_bytes()) > 0 \
                else String("(ext?)")
            var lang_label = e.language_id if len(e.language_id.as_bytes()) > 0 \
                else String("(language?)")
            var line = ext_label + String(" → ") + lang_label
            var attr = body_attr
            if idx == self.selected:
                attr = (
                    Attr(WHITE, BLUE) if self._focus.is_focused(_SLOT_LIST)
                    else Attr(BLACK, GREEN)
                )
                painter.fill(
                    canvas, Rect(inner.a.x, inner.a.y + r,
                         inner.b.x, inner.a.y + r + 1),
                    String(" "), attr,
                )
            _ = painter.put_text(
                canvas, Point(inner.a.x, inner.a.y + r), line, attr,
            )

    def _paint_form(
        mut self, mut canvas: Canvas, painter: Painter, layout: _Layout,
    ):
        var bg = Attr(BLACK, LIGHT_GRAY)
        var hint_attr = Attr(BLUE, LIGHT_GRAY)
        if self.selected < 0:
            _ = painter.put_text(
                canvas, Point(layout.label_x, layout.ext_rect.a.y),
                String("(no mapping selected — use [+ Add])"), hint_attr,
            )
            return
        _ = painter.put_text(
            canvas, Point(layout.label_x, layout.ext_rect.a.y),
            String("Extension:"), bg,
        )
        _ = painter.put_text(
            canvas, Point(layout.label_x, layout.lang_rect.a.y),
            String("Language:"), bg,
        )
        _ = painter.put_text(
            canvas, Point(layout.label_x, layout.hint_y),
            String("(uninstalled grammars prompt to"), hint_attr,
        )
        _ = painter.put_text(
            canvas, Point(layout.label_x, layout.hint_y + 1),
            String(" download on save)"), hint_attr,
        )
        self.ext_tf.paint(
            canvas, layout.ext_rect, self._focus.is_focused(_SLOT_EXT),
        )
        self.lang_dropdown.paint(
            canvas, layout.lang_rect, self._focus.is_focused(_SLOT_LANG),
            Attr(WHITE, BLUE), Attr(BLACK, CYAN),
        )

    def _paint_buttons(mut self, mut canvas: Canvas, rect: Rect, layout: _Layout):
        var y = layout.buttons_y
        var add_x = rect.a.x + 2
        var rm_x = add_x + self._buttons[0].button.total_width() + 1
        var cancel_w = self._buttons[3].button.face_width()
        var cancel_x = rect.b.x - 2 - (cancel_w + 1)
        var save_w = self._buttons[2].button.face_width()
        var save_x = cancel_x - 1 - (save_w + 1)
        self._buttons[0].button.move_to(add_x, y)
        self._buttons[1].button.move_to(rm_x, y)
        self._buttons[2].button.move_to(save_x, y)
        self._buttons[3].button.move_to(cancel_x, y)
        self._buttons[1].enabled = len(self.entries) > 0
        for i in range(len(self._buttons)):
            var btn = self._buttons[i]
            self._focus.update(btn.slot, btn.button.hit_rect(), btn.enabled)
            self._paint_button(canvas, i)

    def _paint_button(mut self, mut canvas: Canvas, idx: Int):
        var pb = self._buttons[idx]
        var face: Attr
        if not pb.enabled:
            face = Attr(LIGHT_GRAY, GREEN)
        elif self._focus.is_focused(pb.slot):
            face = Attr(WHITE, BLUE)
        else:
            face = Attr(BLACK, GREEN)
        paint_shadow_button(canvas, pb.button, face, LIGHT_GRAY)

    # --- key handling -----------------------------------------------

    def handle_key(mut self, event: Event) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_KEY:
            return True
        var k = event.key
        if self._focus.is_focused(_SLOT_LANG) and self.lang_dropdown.is_open:
            if k == KEY_ESC:
                self.lang_dropdown.close()
                return True
            if self.lang_dropdown.handle_key(event):
                self._commit_lang_dropdown()
                return True
        if k == KEY_ESC:
            self.close()
            return True
        if k == KEY_TAB:
            var backward = (event.mods & MOD_SHIFT) != 0
            self._focus.cycle(backward)
            return True
        if k == KEY_ENTER:
            if self._focus.is_focused(_SLOT_LANG):
                self.lang_dropdown.open()
                return True
            return self._activate_focus()
        if k == KEY_UP:
            if self._focus.is_focused(_SLOT_LIST):
                self._move_selection(-1)
            return True
        if k == KEY_DOWN:
            if self._focus.is_focused(_SLOT_LIST):
                self._move_selection(1)
                return True
            if self._focus.is_focused(_SLOT_LANG):
                self.lang_dropdown.open()
                return True
            return True
        if (k == KEY_LEFT or k == KEY_RIGHT) \
                and self._focus.is_focused(_SLOT_LANG):
            self._cycle_lang(event)
            return True
        if self._focus.is_focused(_SLOT_EXT):
            var r = self.ext_tf.handle_key(event)
            if r.consumed:
                self._commit_fields_to_selected()
                return True
        return True

    def _cycle_lang(mut self, event: Event):
        if self.selected < 0:
            return
        if not self.lang_dropdown.handle_key(event):
            return
        self._commit_lang_dropdown()

    def _activate_focus(mut self) -> Bool:
        if self._focus.is_focused(_SLOT_ADD):
            self._add_new()
            return True
        if self._focus.is_focused(_SLOT_REMOVE):
            self._remove_selected()
            return True
        if self._focus.is_focused(_SLOT_SAVE):
            self._commit_fields_to_selected()
            self.submitted = True
            return True
        if self._focus.is_focused(_SLOT_CANCEL):
            self.close()
            return True
        self._focus.cycle()
        return True

    def _move_selection(mut self, delta: Int):
        if len(self.entries) == 0:
            return
        var s = self.selected + delta
        if s < 0:
            s = 0
        if s >= len(self.entries):
            s = len(self.entries) - 1
        if s == self.selected:
            return
        self._commit_fields_to_selected()
        self.selected = s
        self._scroll_selection_into_view()
        self._load_fields_from_selected()

    def _scroll_selection_into_view(mut self):
        if self.selected >= 0 and self.selected < self._list_scroll:
            self._list_scroll = self.selected

    # --- mouse ------------------------------------------------------

    def _dispatch_buttons(mut self, event: Event) -> Bool:
        for i in range(len(self._buttons)):
            var status = self._buttons[i].button.handle_mouse(event)
            if status == BUTTON_NONE:
                continue
            if status == BUTTON_FIRED and self._buttons[i].enabled:
                self._focus.focus_force(self._buttons[i].slot)
                _ = self._activate_focus()
            return True
        return False

    def is_input_at(self, pos: Point, screen: Rect) -> Bool:
        if not self.active:
            return False
        var rect = _dialog_rect(screen, self.pos)
        var layout = _build_layout(rect)
        return layout.ext_rect.contains(pos)

    def handle_mouse(mut self, event: Event, screen: Rect) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_MOUSE:
            return True
        var rect = _dialog_rect(screen, self.pos)
        var layout = _build_layout(rect)
        self._refresh_focus_visitability(layout)
        if self.lang_dropdown.is_open:
            var hit = self.lang_dropdown.handle_mouse(
                layout.lang_rect, screen, event,
            )
            if hit != DROPDOWN_HIT_NONE and hit != DROPDOWN_HIT_OUTSIDE:
                self._commit_lang_dropdown()
                self._focus.focus_force(_SLOT_LANG)
                return True
        if self._dispatch_buttons(event):
            return True
        if self._drag:
            if event.button == MOUSE_BUTTON_LEFT and event.pressed \
                    and event.motion:
                var off = self._drag.value()
                self.pos = Optional[Point](Point(
                    event.pos.x - off.x, event.pos.y - off.y,
                ))
                return True
            if not event.pressed:
                self._drag = Optional[Point]()
            return True
        if event.button == MOUSE_BUTTON_LEFT and event.pressed \
                and not event.motion \
                and hit_close_button(Point(rect.a.x, rect.a.y), event.pos):
            self.close()
            return True
        if event.button == MOUSE_BUTTON_LEFT and event.pressed \
                and not event.motion and event.pos.y == rect.a.y \
                and rect.a.x <= event.pos.x and event.pos.x < rect.b.x:
            self._drag = Optional[Point](Point(
                event.pos.x - rect.a.x, event.pos.y - rect.a.y,
            ))
            return True
        if event.button == MOUSE_WHEEL_UP \
                and layout.list_rect.contains(event.pos):
            self._list_scroll -= 1
            if self._list_scroll < 0:
                self._list_scroll = 0
            return True
        if event.button == MOUSE_WHEEL_DOWN \
                and layout.list_rect.contains(event.pos):
            self._list_scroll += 1
            return True
        _ = self._focus.handle_click(event)
        if self.selected >= 0:
            if self.ext_tf.handle_mouse(event, layout.ext_rect):
                return True
        if event.button != MOUSE_BUTTON_LEFT or not event.pressed \
                or event.motion:
            return True
        if layout.list_rect.contains(event.pos):
            var idx = self._list_scroll + (event.pos.y - layout.list_rect.a.y)
            if 0 <= idx and idx < len(self.entries) and idx != self.selected:
                self._commit_fields_to_selected()
                self.selected = idx
                self._load_fields_from_selected()
            elif 0 <= idx and idx < len(self.entries):
                self.selected = idx
            self._focus.focus_force(_SLOT_LIST)
            return True
        if self.selected >= 0 and layout.lang_rect.contains(event.pos):
            self._focus.focus_force(_SLOT_LANG)
            self._click_lang(layout.lang_rect, screen, event)
            return True
        return True

    def _click_lang(mut self, ir: Rect, screen: Rect, event: Event):
        if self.selected < 0:
            return
        var hit = self.lang_dropdown.handle_mouse(ir, screen, event)
        if hit != DROPDOWN_HIT_NONE:
            self._commit_lang_dropdown()
