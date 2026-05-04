"""Fullscreen Settings view.

Activated from the hamburger menu. Layout::

    ╔══ Settings ══════════════════════════════════════════════════════╗
    ║ ┌────────────────┐ Actions on save                               ║
    ║ │ Actions on save│ ┌─────────────────────────────────────────┐   ║
    ║ │                │ │ python  /usr/local/bin/black --quiet $F │   ║
    ║ │                │ │ rust    /usr/local/bin/rustfmt          │   ║
    ║ │                │ └─────────────────────────────────────────┘   ║
    ║ │                │ [+ Add] [✎ Edit] [- Remove]                   ║
    ║ │                │                                               ║
    ║ └────────────────┘                                               ║
    ║                                                                  ║
    ║                                              [ Close ]           ║
    ╚══════════════════════════════════════════════════════════════════╝

Sections live in a left-rail list. The right pane changes per
section. Today there's one section ("Actions on save"); adding a new
one is two entries (a string label in ``_section_labels`` and a
``_paint_section_*`` arm).

Edits commit immediately to ``self.actions``. The host syncs the list
back into ``TurbokodConfig.on_save_actions`` on close and writes the
updated config to disk.

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
from .cell import Cell
from .colors import (
    Attr, BLACK, BLUE, CYAN, DARK_GRAY, GREEN, LIGHT_GRAY, WHITE,
)
from .config import OnSaveAction
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_DOWN, KEY_ENTER, KEY_ESC, KEY_TAB, KEY_UP,
    MOD_NONE, MOD_SHIFT, MOUSE_BUTTON_LEFT,
    MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .geometry import Point, Rect


# --- focus discriminants --------------------------------------------------

comptime _FOCUS_SECTIONS = UInt8(0)
comptime _FOCUS_LIST     = UInt8(1)
comptime _FOCUS_ADD      = UInt8(2)
comptime _FOCUS_EDIT     = UInt8(3)
comptime _FOCUS_REMOVE   = UInt8(4)
comptime _FOCUS_CLOSE    = UInt8(5)


# --- layout ---------------------------------------------------------------

comptime _SECTION_W = 22


fn _section_labels() -> List[String]:
    """Section names rendered in the left rail. Add new section names
    here and a matching ``_paint_section_*`` / ``_handle_*`` branch
    below; nothing else needs to change."""
    var out = List[String]()
    out.append(String("Actions on save"))
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
    """Set when ``actions`` has been mutated. Host watches this flag
    and writes ``TurbokodConfig`` to disk; ``ack_dirty`` clears it
    after a successful write."""
    var actions: List[OnSaveAction]
    """Working copy of the on-save actions. Host snapshots into this
    on ``open``; mutations are immediate (no per-edit commit step).
    """
    var section: Int
    """Index into ``_section_labels`` for the active section."""
    var selected_action: Int
    """Row in ``actions`` that's highlighted in the right pane."""
    var focus: UInt8
    var editor: ActionEditor
    var _list_scroll: Int
    var _buttons: List[_PlacedButton]
    """Persistent button table — Add / Edit / Remove / Close, in order."""

    fn __init__(out self):
        self.active = False
        self.dirty = False
        self.actions = List[OnSaveAction]()
        self.section = 0
        self.selected_action = -1
        self.focus = _FOCUS_SECTIONS
        self.editor = ActionEditor()
        self._list_scroll = 0
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

    fn open(mut self, var actions: List[OnSaveAction]):
        self.actions = actions^
        self.active = True
        self.dirty = False
        self.section = 0
        self.selected_action = 0 if len(self.actions) > 0 else -1
        self.focus = _FOCUS_SECTIONS
        self._list_scroll = 0

    fn close(mut self):
        self.active = False
        self.actions = List[OnSaveAction]()
        self.section = 0
        self.selected_action = -1
        self.focus = _FOCUS_SECTIONS
        self._list_scroll = 0
        self.editor.close()
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
        canvas.fill(rect, String(" "), bg)
        canvas.draw_box(rect, border, True)
        var title = String(" Settings ")
        var tx = rect.a.x + (rect.width() - len(title.as_bytes())) // 2
        _ = canvas.put_text(Point(tx, rect.a.y), title, bg)
        # Left rail.
        self._paint_sections(canvas, rect)
        # Right pane: section header + per-section content.
        self._paint_right_pane(canvas, rect)
        # Bottom-right Close button.
        self._paint_close_button(canvas, rect)
        # Editor floats on top.
        if self.editor.active:
            self.editor.paint(canvas, screen)

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

    fn _paint_sections(self, mut canvas: Canvas, rect: Rect):
        var inner = self._sections_rect(rect)
        var body_attr = Attr(BLACK, CYAN)
        canvas.fill(inner, String(" "), body_attr)
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
                canvas.fill(
                    Rect(inner.a.x, y, inner.b.x, y + 1),
                    String(" "), attr,
                )
            _ = canvas.put_text(
                Point(inner.a.x + 1, y), labels[i], attr, inner.b.x,
            )

    fn _paint_right_pane(mut self, mut canvas: Canvas, rect: Rect):
        var inner = self._right_rect(rect)
        var bg = Attr(BLACK, LIGHT_GRAY)
        # Header.
        var labels = _section_labels()
        if 0 <= self.section and self.section < len(labels):
            _ = canvas.put_text(
                Point(inner.a.x, inner.a.y), labels[self.section], bg,
            )
        # Section content.
        if self.section == 0:
            self._paint_actions_section(canvas, inner)

    fn _paint_actions_section(mut self, mut canvas: Canvas, inner: Rect):
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
        canvas.fill(list_rect, String(" "), body_attr)
        if len(self.actions) == 0:
            _ = canvas.put_text(
                Point(list_rect.a.x + 1, list_rect.a.y),
                String("(no actions configured — press [+ Add])"),
                hint, list_rect.b.x,
            )
        else:
            self._paint_actions_list(canvas, list_rect)
        # Helper line under the list.
        _ = canvas.put_text(
            Point(inner.a.x, list_bottom),
            String("Runs after a successful save when language matches."),
            hint, inner.b.x,
        )
        # Buttons row anchored just below the list. ``_paint_buttons``
        # repositions in place so the press latches survive across
        # paints; layout indices 0..2 are Add/Edit/Remove.
        var btn_y = list_bottom + 2
        var add_x = inner.a.x
        self._buttons[0].button.move_to(add_x, btn_y)
        var edit_x = add_x + self._buttons[0].button.total_width() + 1
        self._buttons[1].button.move_to(edit_x, btn_y)
        var rm_x = edit_x + self._buttons[1].button.total_width() + 1
        self._buttons[2].button.move_to(rm_x, btn_y)
        var has_sel = (self.selected_action >= 0
                       and self.selected_action < len(self.actions))
        self._buttons[1].enabled = has_sel
        self._buttons[2].enabled = has_sel
        for i in range(3):
            self._paint_button(canvas, i)

    fn _paint_actions_list(mut self, mut canvas: Canvas, list_rect: Rect):
        var visible = list_rect.height()
        if self.selected_action >= 0:
            if self.selected_action < self._list_scroll:
                self._list_scroll = self.selected_action
            elif self.selected_action >= self._list_scroll + visible:
                self._list_scroll = self.selected_action - visible + 1
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
                canvas.fill(
                    Rect(list_rect.a.x, list_rect.a.y + r,
                         list_rect.b.x, list_rect.a.y + r + 1),
                    String(" "), attr,
                )
            var line = _format_action(act)
            _ = canvas.put_text(
                Point(list_rect.a.x + 1, list_rect.a.y + r),
                line, attr, list_rect.b.x,
            )

    fn _paint_close_button(mut self, mut canvas: Canvas, rect: Rect):
        var close = self._buttons[3]
        var btn_w = close.button.face_width()
        var btn_x = rect.b.x - 2 - (btn_w + 1)
        var btn_y = rect.b.y - 3
        self._buttons[3].button.move_to(btn_x, btn_y)
        self._paint_button(canvas, 3)

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
        if event.kind != EVENT_KEY:
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
            return True
        if k == KEY_DOWN:
            if self.focus == _FOCUS_SECTIONS:
                self._step_section(1)
            elif self.focus == _FOCUS_LIST:
                self._step_action(1)
            return True
        return True

    fn _next_focus(self, current: UInt8, backward: Bool) -> UInt8:
        # Skip Edit / Remove when there's no selection — same disabled
        # logic the buttons use.
        var ordered = List[UInt8]()
        ordered.append(_FOCUS_SECTIONS)
        if len(self.actions) > 0:
            ordered.append(_FOCUS_LIST)
        ordered.append(_FOCUS_ADD)
        if self.selected_action >= 0:
            ordered.append(_FOCUS_EDIT)
            ordered.append(_FOCUS_REMOVE)
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
        return True

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
        if event.kind != EVENT_MOUSE:
            return True
        var rect = self._workspace_rect(screen)
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
                self.section = idx
                self.focus = _FOCUS_SECTIONS
            return True
        # Right pane list (only meaningful for the actions section).
        if self.section == 0:
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
        return True

    fn _dispatch_buttons(mut self, event: Event) -> Bool:
        for i in range(len(self._buttons)):
            var status = self._buttons[i].button.handle_mouse(event)
            if status == BUTTON_NONE:
                continue
            if status == BUTTON_FIRED and self._buttons[i].enabled:
                self.focus = self._buttons[i].focus
                _ = self._activate_focus()
            return True
        return False


# --- helpers --------------------------------------------------------------


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
