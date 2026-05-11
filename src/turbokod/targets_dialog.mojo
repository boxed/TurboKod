"""Modal dialog for editing the project's run/debug targets.

Replaces the "open targets.json in an editor" flow with a structured
form so the user doesn't have to hand-author JSON.

Layout::

    ╔════════════ Configure Targets ══════════════════════════════╗
    ║ Targets:         Name:    […………………………………………]                ║
    ║ ┌────────────┐                                              ║
    ║ │ tests     ▒│   Run:     […………………………………………]                ║
    ║ │ desktop    │                                              ║
    ║ │ hello      │   Cwd:     […………………………………………]                ║
    ║ │            │                                              ║
    ║ │            │   Debug language: < python              >    ║
    ║ │            │   Debug program:  […………………………]              ║
    ║ │            │   Debug args:     […………………………]              ║
    ║ │            │                                              ║
    ║ └────────────┘                                              ║
    ║ [+ Add]  [- Remove]                  [Save]    [Cancel]     ║
    ╚═════════════════════════════════════════════════════════════╝

The dialog edits a private copy of the targets list. ``Save`` copies
back to the host (``submitted=True``); ``Cancel`` / ESC discard the
copy. Every list operation (add / remove / select) and every input
edit is immediate-feedback — no per-field "commit" step.

Focus model: a single ``UInt8`` discriminant (``_FOCUS_*`` constants)
selects which widget receives keystrokes. Tab cycles forward, Shift-
Tab backward; mouse clicks set focus to whatever was clicked. The
right-side input fields are simple String slots with cursor-at-end
editing — same shape as ``Prompt`` — since multi-line / mid-line
caret movement isn't worth the complexity for one-shot config.
"""

from std.collections.list import List
from std.collections.optional import Optional

from .buttons import (
    BUTTON_CANCELED, BUTTON_CAPTURED, BUTTON_FIRED, BUTTON_NONE,
    ShadowButton, paint_shadow_button,
)
from .canvas import Canvas, paint_drop_shadow
from .painter import Painter
from .cell import Cell
from .colors import (
    Attr, BLACK, BLUE, CYAN, GREEN, LIGHT_GRAY, LIGHT_RED, RED, WHITE,
)
from .dropdown import (
    DROPDOWN_HIT_BODY, DROPDOWN_HIT_NONE, DROPDOWN_HIT_OUTSIDE,
    DROPDOWN_HIT_POPUP, Dropdown,
)
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_DOWN, KEY_ENTER, KEY_ESC, KEY_LEFT, KEY_RIGHT,
    KEY_TAB, KEY_UP,
    MOD_NONE, MOD_SHIFT, MOUSE_BUTTON_LEFT, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .geometry import Point, Rect, compute_dialog_rect
from .language_config import built_in_servers
from .project_targets import ProjectTargets, RunTarget
from .text_field import TextField
from .view import RowCursor
from .window import (
    hit_close_button, paint_close_button, paint_window_title,
)


# --- focus discriminants --------------------------------------------------
# One slot per focusable widget. Tab cycles in this declaration order;
# the same ints index ``_focus_order_next`` for fast Shift-Tab dispatch.

comptime _FOCUS_LIST     = UInt8(0)
comptime _FOCUS_NAME     = UInt8(1)
comptime _FOCUS_PROGRAM  = UInt8(2)
comptime _FOCUS_ARGS     = UInt8(3)
comptime _FOCUS_CWD      = UInt8(4)
comptime _FOCUS_LANG     = UInt8(5)
comptime _FOCUS_ADD      = UInt8(6)
comptime _FOCUS_REMOVE   = UInt8(7)
comptime _FOCUS_SAVE     = UInt8(8)
comptime _FOCUS_CANCEL   = UInt8(9)
comptime _FOCUS_COUNT    = 10


# --- layout ---------------------------------------------------------------

comptime _DIALOG_W = 76
comptime _DIALOG_H = 22
comptime _LIST_W   = 18
"""Width of the left-side targets list."""
comptime _LIST_TOP = 3
"""Rows from the dialog top to the list top — the row above is the
``Targets:`` label, on the same row as the first form field."""
comptime _LIST_BOT = 4
"""Rows from the dialog bottom to the list bottom — leaves room for
the bottom button strip plus border."""
comptime _LABEL_W = 18
"""Column width reserved for right-side form labels."""


fn _dialog_rect(screen: Rect, pos: Optional[Point]) -> Rect:
    return compute_dialog_rect(screen, pos, _DIALOG_W, _DIALOG_H)


@fieldwise_init
struct _Layout(ImplicitlyCopyable, Movable):
    """Pre-computed rects + row anchors for the targets dialog.

    Built once per paint / mouse event from the dialog rect via
    ``_build_layout``, so painted geometry and hit-test geometry
    can't drift out of sync. The right-column form rows flow
    top-down through ``RowCursor`` with one blank row between them;
    the cwd help line is glued to the cwd field (no gap) and the
    left-column list is anchored against ``_LIST_TOP`` /
    ``_LIST_BOT`` independently of the form flow.
    """
    var list_rect: Rect
    var list_label_pt: Point
    """Where the ``Targets:`` label sits — on the same row as the
    first form field, in the left column."""
    var name_rect: Rect
    var program_rect: Rect
    var args_rect: Rect
    var cwd_rect: Rect
    var cwd_hint_y: Int
    var lang_rect: Rect
    var buttons_y: Int
    var label_x: Int


fn _build_layout(rect: Rect) -> _Layout:
    var cursor = RowCursor(rect.a.y + 2)
    var name_y = cursor.place()
    var program_y = cursor.place()
    var args_y = cursor.place()
    var cwd_y = cursor.place()
    # Hint line is glued to the cwd field (label-and-its-help-text
    # read as one logical control) — no gap, then consume the row.
    var cwd_hint_y = cwd_y + 1
    cursor.skip(1)
    var lang_y = cursor.place()
    var list_left = rect.a.x + 2
    var list_right = list_left + _LIST_W
    var label_x = list_right + 2
    var field_x = label_x + _LABEL_W
    var right_max = rect.b.x - 2
    return _Layout(
        Rect(list_left, rect.a.y + _LIST_TOP, list_right, rect.b.y - _LIST_BOT),
        Point(rect.a.x + 2, name_y),
        Rect(field_x, name_y, right_max, name_y + 1),
        Rect(field_x, program_y, right_max, program_y + 1),
        Rect(field_x, args_y, right_max, args_y + 1),
        Rect(field_x, cwd_y, right_max, cwd_y + 1),
        cwd_hint_y,
        Rect(field_x, lang_y, right_max, lang_y + 1),
        rect.b.y - 3,
        label_x,
    )


fn _input_rect_for(layout: _Layout, focus: UInt8) -> Rect:
    if focus == _FOCUS_NAME:    return layout.name_rect
    if focus == _FOCUS_PROGRAM: return layout.program_rect
    if focus == _FOCUS_ARGS:    return layout.args_rect
    if focus == _FOCUS_CWD:     return layout.cwd_rect
    if focus == _FOCUS_LANG:    return layout.lang_rect
    return Rect(0, 0, 0, 0)


fn _label_pt_for(layout: _Layout, focus: UInt8) -> Point:
    return Point(layout.label_x, _input_rect_for(layout, focus).a.y)


@fieldwise_init
struct _PlacedButton(ImplicitlyCopyable, Movable):
    """One button captured at paint time so mouse routing can hit
    exactly the cells we drew on. ``focus`` is the field's discriminant,
    ``enabled`` lets disabled buttons stay visible but un-clickable."""
    var button: ShadowButton
    var focus: UInt8
    var enabled: Bool


# --- helpers --------------------------------------------------------------


fn _join_args(args: List[String]) -> String:
    """Render ``debug_args`` as a single space-separated string for
    display. Targets with spaces in individual args lose their
    grouping in this view — advanced users can hand-edit the JSON."""
    var out = String("")
    for i in range(len(args)):
        if i > 0:
            out = out + String(" ")
        out = out + args[i]
    return out^


fn _split_args(text: String) -> List[String]:
    """Inverse of ``_join_args``. Splits on runs of spaces — empty
    pieces are dropped so leading / trailing whitespace doesn't
    produce phantom arg entries."""
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


# --- TargetsDialog --------------------------------------------------------


struct TargetsDialog(Movable):
    var active: Bool
    var submitted: Bool
    """Set on Save. Host reads ``entries`` then calls ``close()``."""
    var entries: List[RunTarget]
    """Editable copy. Mutations go here; the host's ProjectTargets is
    only updated on submit."""
    var selected: Int
    """Index into ``entries`` whose form is shown on the right. -1
    when ``entries`` is empty (the right panel paints in a hint
    state)."""
    var active_name: String
    """Name of the target the host treats as active. Preserved
    verbatim through edits so renaming the active target keeps it
    selected on save."""
    var focus: UInt8
    var pos: Optional[Point]
    var _drag: Optional[Point]
    var _list_scroll: Int
    var _last_scroll_sel: Int
    """Last ``selected`` value snapped into view by paint. The list
    paint only scrolls to the selection when this differs from
    ``selected`` — so wheel-scrolling moves the viewport independently
    and isn't snapped back on the next frame."""
    var _buttons: List[_PlacedButton]
    """Persistent button table. Each entry's ``ShadowButton`` carries
    its own press latch (see ``ShadowButton.handle_mouse``), so the
    table must outlive paint cycles — ``_paint_buttons`` repositions
    in place rather than rebuilding from scratch. Layout indices are
    stable: entries 0..3 are Add / Remove / Save / Cancel in order."""
    # Editable input strips for the currently-selected entry. The
    # field text is the canonical source of truth while the dialog
    # is open; ``_sync_fields_into_entries`` writes them back into
    # ``entries[selected]`` before any selection change or Save.
    var name_tf: TextField
    var program_tf: TextField
    var args_tf: TextField
    var cwd_tf: TextField
    var lang_dropdown: Dropdown
    """Persistent language picker. Stateful so clicking the strip
    actually opens a popup the user can pick from — a stateless
    rebuild-each-paint dropdown silently drops the toggle, making
    clicks feel like no-ops. Re-seeded from the selected target's
    ``debug_language`` whenever the selection changes."""

    fn __init__(out self):
        self.active = False
        self.submitted = False
        self.entries = List[RunTarget]()
        self.selected = -1
        self.active_name = String("")
        self.focus = _FOCUS_LIST
        self.pos = Optional[Point]()
        self._drag = Optional[Point]()
        self._list_scroll = 0
        self._last_scroll_sel = -2
        self.name_tf = TextField()
        self.program_tf = TextField()
        self.args_tf = TextField()
        self.cwd_tf = TextField()
        self.lang_dropdown = _build_lang_dropdown(String(""))
        # Build the persistent button table once — ``_paint_buttons``
        # repositions and updates ``enabled`` per frame, but the press
        # latch on each ShadowButton has to survive across paints.
        self._buttons = List[_PlacedButton]()
        self._buttons.append(_PlacedButton(
            ShadowButton(String(" + Add "), 0, 0), _FOCUS_ADD, True,
        ))
        self._buttons.append(_PlacedButton(
            ShadowButton(String(" - Remove "), 0, 0), _FOCUS_REMOVE, True,
        ))
        self._buttons.append(_PlacedButton(
            ShadowButton(String(" Save "), 0, 0), _FOCUS_SAVE, True,
        ))
        self._buttons.append(_PlacedButton(
            ShadowButton(String(" Cancel "), 0, 0), _FOCUS_CANCEL, True,
        ))

    fn open(mut self, var targets: ProjectTargets):
        """Take a snapshot of ``targets`` for editing. Subsequent
        edits never touch the host's copy until Save."""
        self.entries = targets.targets.copy()
        self.selected = targets.active if targets.has_active() else -1
        if self.selected < 0 and len(self.entries) > 0:
            self.selected = 0
        if targets.has_active():
            self.active_name = targets.targets[targets.active].name
        else:
            self.active_name = String("")
        self.active = True
        self.submitted = False
        self.focus = _FOCUS_LIST if len(self.entries) > 0 else _FOCUS_ADD
        self.pos = Optional[Point]()
        self._drag = Optional[Point]()
        self._list_scroll = 0
        self._last_scroll_sel = -2
        self._load_fields_from_selected()

    fn close(mut self):
        self.active = False
        self.submitted = False
        self.entries = List[RunTarget]()
        self.selected = -1
        self.active_name = String("")
        self.focus = _FOCUS_LIST
        self.pos = Optional[Point]()
        self._drag = Optional[Point]()
        self._list_scroll = 0
        self.lang_dropdown = _build_lang_dropdown(String(""))
        # Drop any in-flight press latches so re-opening the dialog
        # starts with a clean button row.
        for i in range(len(self._buttons)):
            self._buttons[i].button.pressed = False
            self._buttons[i].button.pressed_inside = False

    fn into_targets(self) -> ProjectTargets:
        """Build a fresh ProjectTargets from the editable state. The
        active selection follows ``active_name`` when it still
        resolves, otherwise falls back to the highlighted row."""
        var out = ProjectTargets()
        out.targets = self.entries.copy()
        out.active = -1
        if len(out.targets) == 0:
            return out^
        if len(self.active_name.as_bytes()) > 0:
            for i in range(len(out.targets)):
                if out.targets[i].name == self.active_name:
                    out.active = i
                    break
        if out.active < 0:
            out.active = self.selected if self.selected >= 0 else 0
            if out.active >= len(out.targets):
                out.active = 0
        return out^

    # --- editing operations -----------------------------------------

    fn _add_new(mut self):
        """Append a fresh target with placeholder values. Selecting it
        immediately and shifting focus to the Name field is what users
        expect — the next keystroke lands where they're already
        thinking ("OK, what should I call this thing?")."""
        # Stash the currently-edited fields back into their row so the
        # newly-appended entry doesn't overwrite them.
        self._commit_fields_to_selected()
        var t = RunTarget()
        t.name = self._unique_name(String("new"))
        self.entries.append(t^)
        self.selected = len(self.entries) - 1
        self.focus = _FOCUS_NAME
        self._scroll_selection_into_view()
        self._load_fields_from_selected()

    fn _unique_name(self, base: String) -> String:
        """Return ``base`` if no entry uses it, else ``base 2``,
        ``base 3``, ... — adding two ``new`` targets in a row should
        not produce a duplicate-name list."""
        var taken = False
        for i in range(len(self.entries)):
            if self.entries[i].name == base:
                taken = True
                break
        if not taken:
            return base
        # Bounded loop: the suffix can collide at most ``len(entries)``
        # times before we hit a free number, so cap and fall through
        # to a duplicate-allowed name in the pathological case.
        var n = 2
        var max_iters = len(self.entries) + 2
        for _ in range(max_iters):
            var candidate = base + String(" ") + String(n)
            var hit = False
            for i in range(len(self.entries)):
                if self.entries[i].name == candidate:
                    hit = True
                    break
            if not hit:
                return candidate^
            n += 1
        return base + String(" ") + String(n)

    fn _remove_selected(mut self):
        if self.selected < 0 or self.selected >= len(self.entries):
            return
        var rebuilt = List[RunTarget]()
        for i in range(len(self.entries)):
            if i == self.selected:
                continue
            rebuilt.append(self.entries[i])
        # If the removed entry was the active one, fall back to the
        # row that takes its place (or clear when the list goes empty).
        var was_active = (
            self.selected >= 0
            and self.selected < len(self.entries)
            and self.entries[self.selected].name == self.active_name
        )
        self.entries = rebuilt^
        if len(self.entries) == 0:
            self.selected = -1
            self.focus = _FOCUS_ADD
        else:
            if self.selected >= len(self.entries):
                self.selected = len(self.entries) - 1
            self.focus = _FOCUS_LIST
        if was_active:
            self.active_name = (
                self.entries[self.selected].name
                if self.selected >= 0 else String("")
            )
        # Reload the editable strips from whichever row we landed on.
        self._load_fields_from_selected()

    fn _selected_target(self) -> RunTarget:
        if self.selected < 0 or self.selected >= len(self.entries):
            return RunTarget()
        return self.entries[self.selected]

    fn _put_selected(mut self, var t: RunTarget):
        """Write ``t`` back to the selected slot. Mojo can't mutate a
        list element through field access, so callers do
        ``var t = _selected_target(); t.field = …; _put_selected(t^)``.
        """
        if self.selected < 0 or self.selected >= len(self.entries):
            return
        self.entries[self.selected] = t^

    fn _load_fields_from_selected(mut self):
        """Populate the editable strips from ``entries[selected]`` —
        called after every selection change (open, add, remove,
        list-arrow-key, list click). Empty fields when no row is
        selected so the right-side strips don't show stale text from
        whichever row was last viewed."""
        if self.selected < 0 or self.selected >= len(self.entries):
            self.name_tf = TextField()
            self.program_tf = TextField()
            self.args_tf = TextField()
            self.cwd_tf = TextField()
            self.lang_dropdown = _build_lang_dropdown(String(""))
            return
        var t = self.entries[self.selected]
        self.name_tf = TextField()
        self.name_tf.set_text(t.name)
        self.program_tf = TextField()
        self.program_tf.set_text(t.program)
        self.args_tf = TextField()
        self.args_tf.set_text(_join_args(t.args))
        self.cwd_tf = TextField()
        self.cwd_tf.set_text(t.cwd)
        self.lang_dropdown = _build_lang_dropdown(t.debug_language)

    fn _commit_fields_to_selected(mut self):
        """Write the editable strip values back into
        ``entries[selected]``. Called before any selection change, and
        on Save, so the entries snapshot is always up-to-date with
        what the user typed."""
        if self.selected < 0 or self.selected >= len(self.entries):
            return
        var t = self.entries[self.selected]
        t.name = self.name_tf.text
        t.program = self.program_tf.text
        t.args = _split_args(self.args_tf.text)
        t.cwd = self.cwd_tf.text
        self.entries[self.selected] = t^

    # --- focus walk -------------------------------------------------

    fn _next_focus(self, current: UInt8, backward: Bool) -> UInt8:
        """Cycle to the next/previous focusable widget, skipping the
        Remove button when the list is empty (no row to remove) and
        all the right-side fields when no row is selected."""
        var n = _FOCUS_COUNT
        var idx = Int(current)
        for _ in range(n):
            if backward:
                idx = (idx - 1 + n) % n
            else:
                idx = (idx + 1) % n
            var f = UInt8(idx)
            if self._focus_visitable(f):
                return f
        return current

    fn _focus_visitable(self, focus: UInt8) -> Bool:
        if focus == _FOCUS_LIST:
            return len(self.entries) > 0
        if focus == _FOCUS_REMOVE:
            return len(self.entries) > 0
        if focus == _FOCUS_NAME or focus == _FOCUS_PROGRAM \
                or focus == _FOCUS_ARGS or focus == _FOCUS_CWD \
                or focus == _FOCUS_LANG:
            return self.selected >= 0
        return True

    # --- painting ---------------------------------------------------

    fn paint(mut self, mut canvas: Canvas, screen: Rect):
        if not self.active:
            return
        var bg = Attr(BLACK, LIGHT_GRAY)
        var border = Attr(WHITE, LIGHT_GRAY)
        var rect = _dialog_rect(screen, self.pos)
        var layout = _build_layout(rect)
        # Drop shadow first — see ``FileDialog.paint`` for the rationale.
        paint_drop_shadow(canvas, rect)
        var painter = Painter(rect)
        painter.fill(canvas, rect, String(" "), bg)
        painter.draw_box(canvas, rect, border, True)
        paint_window_title(canvas, rect, String(" Configure Targets "), bg, bg)
        # Close button [■] in the top-left corner — same chrome as
        # editor windows, drawn by the framework helper.
        paint_close_button(canvas, Point(rect.a.x, rect.a.y), border)
        # Section labels.
        _ = painter.put_text(canvas, layout.list_label_pt, String("Targets:"), bg)
        # Render the targets list.
        self._paint_list(canvas, painter, layout.list_rect)
        # Right-pane labels and inputs.
        self._paint_form(canvas, painter, layout)
        # Bottom button row.
        self._paint_buttons(canvas, rect, layout)
        # Language dropdown popup overlays the rest of the dialog when
        # open — paint last so it sits on top of the form and buttons.
        if self.lang_dropdown.is_open:
            self.lang_dropdown.paint_popup(canvas, layout.lang_rect, screen)

    fn _paint_list(
        mut self, mut canvas: Canvas, painter: Painter, list_rect: Rect,
    ):
        """Paint each list entry on a cyan field — no border. The
        cyan-vs-light-gray contrast already separates the list from
        the form; a frame on top would just be visual noise.
        Selection bar is white-on-blue when the list itself has
        focus; same scheme but black-on-green when focus is
        elsewhere — so the user can always see *which* target the
        right-side form belongs to, not just whether the list has
        focus."""
        var body_attr = Attr(BLACK, CYAN)
        # No interior gap — every cell of ``list_rect`` is a list row
        # (or empty space), painting straight against the dialog body.
        var inner = list_rect
        painter.fill(canvas, inner, String(" "), body_attr)
        var visible = inner.height()
        # Re-clip scroll so an entry-add or -remove can't leave us
        # showing past the end of the list. Snap-to-selection only
        # fires when ``selected`` has changed since the previous paint,
        # so the mouse wheel can move the viewport independently
        # without being snapped back on the next frame.
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
            var name = self.entries[idx].name
            # The active-on-disk target gets a leading marker so the
            # user can tell which one Cmd+R / Cmd+D currently targets.
            var marker = String("● ") if name == self.active_name \
                else String("  ")
            var line = marker + name
            var attr = body_attr
            if idx == self.selected:
                attr = (
                    Attr(WHITE, BLUE) if self.focus == _FOCUS_LIST
                    else Attr(BLACK, GREEN)
                )
                # Fill the row so the highlight reaches the right edge,
                # not just under the text.
                painter.fill(
                    canvas, Rect(inner.a.x, inner.a.y + r,
                         inner.b.x, inner.a.y + r + 1),
                    String(" "), attr,
                )
            _ = painter.put_text(
                canvas, Point(inner.a.x, inner.a.y + r), line, attr,
            )

    fn _paint_form(
        mut self, mut canvas: Canvas, painter: Painter, layout: _Layout,
    ):
        """Paint the labels + editable strips for the selected target.
        When nothing is selected, paint a centered hint — the form
        rows would otherwise show empty boxes the user can't actually
        focus into."""
        var bg = Attr(BLACK, LIGHT_GRAY)
        # Hint colour: blue on the dialog body — a soft accent that
        # doesn't compete with the BLACK labels for attention but
        # still reads as text rather than chrome.
        var hint_attr = Attr(BLUE, LIGHT_GRAY)
        if self.selected < 0:
            var hint = String("(no target selected — use [+ Add])")
            _ = painter.put_text(
                canvas, Point(layout.label_x, layout.args_rect.a.y),
                hint, hint_attr,
            )
            return
        _ = painter.put_text(
            canvas, _label_pt_for(layout, _FOCUS_NAME), String("Name:"), bg,
        )
        _ = painter.put_text(
            canvas, _label_pt_for(layout, _FOCUS_PROGRAM), String("Program:"), bg,
        )
        _ = painter.put_text(
            canvas, _label_pt_for(layout, _FOCUS_ARGS), String("Args:"), bg,
        )
        _ = painter.put_text(
            canvas, _label_pt_for(layout, _FOCUS_CWD), String("Working dir:"), bg,
        )
        # Helper line under the cwd input — same column as the input
        # so the connection reads at a glance.
        _ = painter.put_text(
            canvas, Point(layout.cwd_rect.a.x, layout.cwd_hint_y),
            String("(empty = project root; relative paths join the project)"),
            hint_attr,
        )
        _ = painter.put_text(
            canvas, _label_pt_for(layout, _FOCUS_LANG),
            String("Debug language:"), bg,
        )
        # Paint each field's ``TextField`` directly — ``TextField.paint``
        # mutates the field (it owns the horizontal scroll offset and
        # reconciles it against the strip width), so we have to call
        # it on the owned ``self.<field>`` rather than on a copy.
        # ``TextField`` caches its own input_rect internally for
        # ``consume_pending_drag``, so the dialog no longer needs to
        # stash per-field rects.
        self.name_tf.paint(canvas, layout.name_rect, self.focus == _FOCUS_NAME)
        self.program_tf.paint(
            canvas, layout.program_rect, self.focus == _FOCUS_PROGRAM,
        )
        self.args_tf.paint(canvas, layout.args_rect, self.focus == _FOCUS_ARGS)
        self.cwd_tf.paint(canvas, layout.cwd_rect, self.focus == _FOCUS_CWD)
        self._paint_lang_dropdown(canvas, layout)

    fn _paint_lang_dropdown(self, mut canvas: Canvas, layout: _Layout):
        """Render the debug-language dropdown using the same focus
        colours as ``_paint_input`` so the form reads as a uniform
        row of editable strips. Reads from the persistent
        ``lang_dropdown`` so its open / scroll / highlight state
        survives across paints."""
        var has_focus = self.focus == _FOCUS_LANG
        self.lang_dropdown.paint(
            canvas, layout.lang_rect, has_focus,
            Attr(WHITE, BLUE), Attr(BLACK, CYAN),
        )

    fn _paint_buttons(mut self, mut canvas: Canvas, rect: Rect, layout: _Layout):
        """Layout: Add and Remove on the bottom-left, Save and Cancel
        on the bottom-right. Each button is painted with the shared
        ``ShadowButton`` widget so the drop-shadow look matches the
        Desktop / Home / Root buttons in the file dialogs.

        ``y`` reserves a row below the button face for the bottom
        shadow, then a row for the bottom border — so layout from the
        dialog bottom up is: border (y-1), shadow (y-2), face (y-3).
        Repositions the persistent ``_buttons`` table in place — the
        press latch on each entry has to survive across paints, so
        we ``move_to`` rather than re-allocate. Disabled buttons
        (Remove, with an empty list) get a dim attr; their
        ``handle_mouse`` is still called but ``enabled=False`` makes
        ``_dispatch_buttons`` ignore any FIRED status.
        """
        # Lay out left-to-right from the body's left margin; each
        # button claims face + 1 shadow column, plus 1 column gap
        # before the next so adjacent shadows don't collide.
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
            self._paint_button(canvas, i)

    fn _paint_button(mut self, mut canvas: Canvas, idx: Int):
        var pb = self._buttons[idx]
        var face: Attr
        if not pb.enabled:
            # Dim face — same hue, but light-gray text on green
            # signals "not actionable right now" without dropping
            # the visual weight of the button entirely.
            face = Attr(LIGHT_GRAY, GREEN)
        elif self.focus == pb.focus:
            # Focused: blue face. Matches the focus colour used for
            # input strips so the eye groups them as "where typing
            # / Enter goes next".
            face = Attr(WHITE, BLUE)
        else:
            face = Attr(BLACK, GREEN)
        # Shadow tone tracks the dialog body bg (LIGHT_GRAY) — that's
        # what makes the button look "lifted" rather than smeared.
        # ``paint_shadow_button`` reads ``button.show_pressed()`` to
        # decide whether to draw the shadow or paint flush.
        paint_shadow_button(canvas, pb.button, face, LIGHT_GRAY)

    # --- key handling -----------------------------------------------

    fn handle_key(mut self, event: Event) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_KEY:
            return True
        var k = event.key
        # Open dropdown popup eats Esc / Up / Down / Enter before the
        # dialog's own handlers: arrow keys navigate inside the popup,
        # Esc closes just the popup (not the whole dialog), and Enter
        # commits.
        if self.focus == _FOCUS_LANG and self.lang_dropdown.is_open:
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
            self.focus = self._next_focus(self.focus, backward)
            return True
        if k == KEY_ENTER:
            # Enter on the closed lang dropdown opens the popup —
            # cheaper to discover than left/right cycling. Once open,
            # the branch above takes over.
            if self.focus == _FOCUS_LANG:
                self.lang_dropdown.open()
                return True
            return self._activate_focus()
        if k == KEY_UP:
            if self.focus == _FOCUS_LIST:
                self._move_selection(-1)
                return True
            return True
        if k == KEY_DOWN:
            if self.focus == _FOCUS_LIST:
                self._move_selection(1)
                return True
            # Down on the closed lang dropdown opens it (matches the
            # convention of every native picker).
            if self.focus == _FOCUS_LANG:
                self.lang_dropdown.open()
                return True
            return True
        # Lang dropdown left/right cycles options without opening the
        # popup; for editable inputs we let the field handle them
        # (cursor movement, selection).
        if (k == KEY_LEFT or k == KEY_RIGHT) and self.focus == _FOCUS_LANG:
            self._cycle_lang(event)
            return True
        # Route to the focused editable strip. Save / Cancel / Add /
        # Remove / List have no field, so we fall through.
        if self.focus == _FOCUS_NAME:
            var r = self.name_tf.handle_key(event)
            if r.consumed:
                self._commit_fields_to_selected()
                return True
        elif self.focus == _FOCUS_PROGRAM:
            var r = self.program_tf.handle_key(event)
            if r.consumed:
                self._commit_fields_to_selected()
                return True
        elif self.focus == _FOCUS_ARGS:
            var r = self.args_tf.handle_key(event)
            if r.consumed:
                self._commit_fields_to_selected()
                return True
        elif self.focus == _FOCUS_CWD:
            var r = self.cwd_tf.handle_key(event)
            if r.consumed:
                self._commit_fields_to_selected()
                return True
        return True

    fn _cycle_lang(mut self, event: Event):
        """Forward a Left / Right press to the persistent dropdown. The
        dropdown ignores these when collapsed (its primary interaction
        is the popup), but routing through it keeps any future cycle
        behavior in one place."""
        if self.selected < 0:
            return
        if not self.lang_dropdown.handle_key(event):
            return
        self._commit_lang_dropdown()

    fn _commit_lang_dropdown(mut self):
        """Push the dropdown's currently-committed value back into the
        selected target so Save round-trips it."""
        if self.selected < 0:
            return
        var t = self._selected_target()
        t.debug_language = self.lang_dropdown.value()
        self._put_selected(t^)

    fn _activate_focus(mut self) -> Bool:
        if self.focus == _FOCUS_ADD:
            self._add_new()
            return True
        if self.focus == _FOCUS_REMOVE:
            self._remove_selected()
            return True
        if self.focus == _FOCUS_SAVE:
            self.submitted = True
            return True
        if self.focus == _FOCUS_CANCEL:
            self.close()
            return True
        # Enter on an input/list moves to the next field — mimics the
        # form-traversal behavior of every IDE settings dialog.
        self.focus = self._next_focus(self.focus, False)
        return True

    fn _move_selection(mut self, delta: Int):
        if len(self.entries) == 0:
            return
        var s = self.selected + delta
        if s < 0:
            s = 0
        if s >= len(self.entries):
            s = len(self.entries) - 1
        if s == self.selected:
            return
        # Save the editable strips back into the row we're leaving,
        # then load the row we're moving to.
        self._commit_fields_to_selected()
        self.selected = s
        self._scroll_selection_into_view()
        self._load_fields_from_selected()

    fn _scroll_selection_into_view(mut self):
        # The visible row count depends on the list rect, which we
        # don't have here; clip on next paint where it's known.
        # Reset enough that paint will pick up.
        if self.selected >= 0 and self.selected < self._list_scroll:
            self._list_scroll = self.selected

    # --- mouse ------------------------------------------------------

    fn _dispatch_buttons(mut self, event: Event) -> Bool:
        """Route ``event`` through every button's ``handle_mouse``.
        Returns True if any button consumed the event. On
        ``BUTTON_FIRED`` the button's action runs before returning;
        on ``BUTTON_CAPTURED`` / ``BUTTON_CANCELED`` the event is
        consumed without firing.

        Disabled buttons still receive the event (so a stale press
        latch from an enabled-then-disabled transition resolves
        cleanly), but a FIRED status from a disabled button is
        ignored — clicking through to "fire" requires the button to
        be enabled at release time."""
        for i in range(len(self._buttons)):
            var status = self._buttons[i].button.handle_mouse(event)
            if status == BUTTON_NONE:
                continue
            if status == BUTTON_FIRED and self._buttons[i].enabled:
                self.focus = self._buttons[i].focus
                _ = self._activate_focus()
            return True
        return False

    fn is_input_at(self, pos: Point, screen: Rect) -> Bool:
        """True if ``pos`` would land on an editable strip — used by
        the host to surface a text-cursor pointer over those cells."""
        if not self.active:
            return False
        var rect = _dialog_rect(screen, self.pos)
        var layout = _build_layout(rect)
        return (
            layout.name_rect.contains(pos)
            or layout.program_rect.contains(pos)
            or layout.args_rect.contains(pos)
            or layout.cwd_rect.contains(pos)
            or layout.lang_rect.contains(pos)
        )

    fn handle_mouse(mut self, event: Event, screen: Rect) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_MOUSE:
            return True
        var rect = _dialog_rect(screen, self.pos)
        var layout = _build_layout(rect)
        # Open dropdown popup gets first dibs on the click — same as the
        # keyboard branch. ``handle_mouse`` toggles open on body click,
        # commits + closes on a popup-row click, and closes on an
        # outside click.
        if self.lang_dropdown.is_open:
            var hit = self.lang_dropdown.handle_mouse(
                layout.lang_rect, screen, event,
            )
            if hit != DROPDOWN_HIT_NONE and hit != DROPDOWN_HIT_OUTSIDE:
                self._commit_lang_dropdown()
                self.focus = _FOCUS_LANG
                return True
            # On OUTSIDE the popup auto-closed; let the click fall
            # through to whatever it was actually targeting.
        # Buttons run their own press / move / release state machine
        # (see ``ShadowButton.handle_mouse``). Dispatch first so a
        # captured button continues to receive drag-motion + release
        # events without the title-bar / list code intercepting them.
        # ``_dispatch_buttons`` returns True for any consumed event,
        # and runs the button's action on FIRED before doing so.
        if self._dispatch_buttons(event):
            return True
        # Title-bar drag: same model as the file dialogs.
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
        # Close button [■] dismisses the dialog. Resolved before the
        # title-bar drag so a click on the glyph doesn't start a move.
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
        # Wheel scroll inside the list.
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
        # Every mouse event goes through every text field. Each
        # field consumes only when a press lands inside its strip or
        # when it's mid-drag — at most one claims any given event.
        # Drag tracking, click counting, focus-on-press, and
        # motion / release dispatch all live inside ``TextField``.
        # Gated on ``self.selected >= 0`` because the fields aren't
        # painted in the empty-state (no selected row), and clicking
        # phantom geometry shouldn't position a cursor that's not
        # visible.
        if self.selected >= 0:
            if self.name_tf.handle_mouse(event, layout.name_rect):
                self.focus = _FOCUS_NAME
                return True
            if self.program_tf.handle_mouse(event, layout.program_rect):
                self.focus = _FOCUS_PROGRAM
                return True
            if self.args_tf.handle_mouse(event, layout.args_rect):
                self.focus = _FOCUS_ARGS
                return True
            if self.cwd_tf.handle_mouse(event, layout.cwd_rect):
                self.focus = _FOCUS_CWD
                return True
        # Remaining widgets are press-only (the candidate list and
        # the lang dropdown have no drag semantics here).
        if event.button != MOUSE_BUTTON_LEFT or not event.pressed \
                or event.motion:
            return True
        # Click inside the list: select the row that was hit. With
        # the framing border gone, every row of ``list_rect`` is a
        # data row — no inset to skip past.
        if layout.list_rect.contains(event.pos):
            var idx = self._list_scroll + (event.pos.y - layout.list_rect.a.y)
            if 0 <= idx and idx < len(self.entries) and idx != self.selected:
                # Save the right-side fields back into the previous
                # row before swapping, then load the clicked row.
                self._commit_fields_to_selected()
                self.selected = idx
                self._load_fields_from_selected()
            elif 0 <= idx and idx < len(self.entries):
                self.selected = idx
            self.focus = _FOCUS_LIST
            return True
        if self.selected >= 0 and layout.lang_rect.contains(event.pos):
            self.focus = _FOCUS_LANG
            self._click_lang(layout.lang_rect, screen, event)
            return True
        return True

    fn _click_lang(mut self, ir: Rect, screen: Rect, event: Event):
        """Forward a click on the language strip to the persistent
        dropdown. A click on the closed strip toggles the popup open;
        when already open, popup-row clicks are routed through the
        ``handle_mouse`` branch at the top of the dispatcher."""
        if self.selected < 0:
            return
        var hit = self.lang_dropdown.handle_mouse(ir, screen, event)
        if hit != DROPDOWN_HIT_NONE:
            self._commit_lang_dropdown()


# --- helpers --------------------------------------------------------------


fn _build_lang_dropdown(var current: String) -> Dropdown:
    """Empty slot ("(none)" — disables Cmd+D) followed by every known
    language id from the LSP catalog. The catalog is the broadest list
    of programming languages we ship: anything with a Helix entry
    surfaces here automatically. ``set_value`` preserves a current id
    that isn't in the list (e.g. a hand-edited config) by appending it
    as a synthetic entry rather than silently snapping to a different
    choice."""
    var options = List[String]()
    options.append(String(""))
    var specs = built_in_servers()
    for i in range(len(specs)):
        options.append(specs[i].language_id)
    var dd = Dropdown(options^, 0)
    dd.set_value(current^)
    return dd^
