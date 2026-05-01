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
from .canvas import Canvas
from .cell import Cell
from .colors import (
    Attr, BLACK, BLUE, CYAN, GREEN, LIGHT_GRAY, LIGHT_RED, RED, WHITE,
)
from .debugger_config import built_in_debuggers
from .dropdown import (
    DROPDOWN_HIT_BODY, DROPDOWN_HIT_NONE, DROPDOWN_HIT_OUTSIDE,
    DROPDOWN_HIT_POPUP, Dropdown,
)
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_BACKSPACE, KEY_DOWN, KEY_ENTER, KEY_ESC, KEY_LEFT, KEY_RIGHT,
    KEY_TAB, KEY_UP,
    MOD_NONE, MOD_SHIFT, MOUSE_BUTTON_LEFT, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .geometry import Point, Rect
from .project_targets import ProjectTargets, RunTarget


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
"""Width of the left-side targets list (including its border)."""
comptime _LIST_TOP = 3   # rows from dialog top to list top
comptime _LIST_BOT = 4   # rows from dialog bottom to list bottom (room for buttons)


fn _dialog_rect(screen: Rect, pos: Optional[Point]) -> Rect:
    var width = _DIALOG_W
    var height = _DIALOG_H
    if width > screen.b.x - 4: width = screen.b.x - 4
    if height > screen.b.y - 4: height = screen.b.y - 4
    var x: Int
    var y: Int
    if pos:
        x = pos.value().x
        y = pos.value().y
        if x < 0: x = 0
        if y < 0: y = 0
        if x + width > screen.b.x: x = screen.b.x - width
        if y + height > screen.b.y: y = screen.b.y - height
    else:
        x = (screen.b.x - width) // 2
        y = (screen.b.y - height) // 2
    return Rect(x, y, x + width, y + height)


fn _list_rect(dialog: Rect) -> Rect:
    """Inner area of the targets list (inside the framing border)."""
    return Rect(
        dialog.a.x + 2, dialog.a.y + _LIST_TOP,
        dialog.a.x + 2 + _LIST_W, dialog.b.y - _LIST_BOT,
    )


fn _input_rect(dialog: Rect, row: Int, label_w: Int = 18) -> Rect:
    """One-row editable strip on the right side of the dialog. ``row``
    is the offset from the dialog top (so the layout is described in
    one place rather than scattered). ``label_w`` carves out the
    column the label occupies; the strip starts after it."""
    var x0 = dialog.a.x + 2 + _LIST_W + 2 + label_w
    return Rect(x0, dialog.a.y + row, dialog.b.x - 2, dialog.a.y + row + 1)


fn _label_at(dialog: Rect, row: Int) -> Point:
    return Point(dialog.a.x + 2 + _LIST_W + 2, dialog.a.y + row)


# Per-field row offset within the dialog. The cwd hint (row 9)
# carries no input — it's a static help line below the cwd field.
fn _row_for_focus(focus: UInt8) -> Int:
    if focus == _FOCUS_NAME:    return 2
    if focus == _FOCUS_PROGRAM: return 4
    if focus == _FOCUS_ARGS:    return 6
    if focus == _FOCUS_CWD:     return 8
    if focus == _FOCUS_LANG:    return 11
    return -1


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


fn _str_pop_byte(s: String) -> String:
    var b = s.as_bytes()
    if len(b) == 0:
        return s
    return String(StringSlice(unsafe_from_utf8=b[:len(b) - 1]))


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
    var _buttons: List[_PlacedButton]
    """Persistent button table. Each entry's ``ShadowButton`` carries
    its own press latch (see ``ShadowButton.handle_mouse``), so the
    table must outlive paint cycles — ``_paint_buttons`` repositions
    in place rather than rebuilding from scratch. Layout indices are
    stable: entries 0..3 are Add / Remove / Save / Cancel in order."""

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
        var t = RunTarget()
        t.name = self._unique_name(String("new"))
        self.entries.append(t^)
        self.selected = len(self.entries) - 1
        self.focus = _FOCUS_NAME
        self._scroll_selection_into_view()

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
        var title_attr = Attr(BLACK, LIGHT_GRAY)
        var rect = _dialog_rect(screen, self.pos)
        canvas.fill(rect, String(" "), bg)
        canvas.draw_box(rect, border, True)
        # Title.
        var title = String(" Configure Targets ")
        var tx = rect.a.x + (rect.width() - len(title.as_bytes())) // 2
        _ = canvas.put_text(Point(tx, rect.a.y), title, title_attr)
        # Section labels.
        _ = canvas.put_text(
            Point(rect.a.x + 2, rect.a.y + 2), String("Targets:"), bg,
        )
        # Render the targets list.
        self._paint_list(canvas, _list_rect(rect))
        # Right-pane labels and inputs.
        self._paint_form(canvas, rect)
        # Bottom button row.
        self._paint_buttons(canvas, rect)

    fn _paint_list(mut self, mut canvas: Canvas, list_rect: Rect):
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
        canvas.fill(inner, String(" "), body_attr)
        var visible = inner.height()
        # Re-clip scroll so an entry-add or -remove can't leave us
        # showing past the end of the list.
        if self.selected >= 0:
            if self.selected < self._list_scroll:
                self._list_scroll = self.selected
            elif self.selected >= self._list_scroll + visible:
                self._list_scroll = self.selected - visible + 1
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
                canvas.fill(
                    Rect(inner.a.x, inner.a.y + r,
                         inner.b.x, inner.a.y + r + 1),
                    String(" "), attr,
                )
            _ = canvas.put_text(
                Point(inner.a.x, inner.a.y + r), line, attr, inner.b.x,
            )

    fn _paint_form(self, mut canvas: Canvas, rect: Rect):
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
            var hx = _label_at(rect, 6).x
            _ = canvas.put_text(Point(hx, rect.a.y + 6), hint, hint_attr)
            return
        var t = self.entries[self.selected]
        _ = canvas.put_text(_label_at(rect, 2), String("Name:"), bg)
        _ = canvas.put_text(_label_at(rect, 4), String("Program:"), bg)
        _ = canvas.put_text(_label_at(rect, 6), String("Args:"), bg)
        _ = canvas.put_text(_label_at(rect, 8), String("Working dir:"), bg)
        # Helper line under the cwd input — same column as the input
        # so the connection reads at a glance.
        _ = canvas.put_text(
            Point(_input_rect(rect, 8).a.x, rect.a.y + 9),
            String("(empty = project root; relative paths join the project)"),
            hint_attr, rect.b.x - 2,
        )
        _ = canvas.put_text(
            _label_at(rect, 11), String("Debug language:"), bg,
        )
        # Helper line under the language dropdown — explains the
        # cycler interaction and the meaning of the empty slot.
        _ = canvas.put_text(
            Point(_input_rect(rect, 11).a.x, rect.a.y + 12),
            String("(left/right to choose; (none) disables Cmd+D)"),
            hint_attr, rect.b.x - 2,
        )
        self._paint_input(canvas, rect, _FOCUS_NAME, t.name)
        self._paint_input(canvas, rect, _FOCUS_PROGRAM, t.program)
        self._paint_input(canvas, rect, _FOCUS_ARGS, _join_args(t.args))
        self._paint_input(canvas, rect, _FOCUS_CWD, t.cwd)
        self._paint_lang_dropdown(canvas, rect, t.debug_language)

    fn _paint_input(
        self, mut canvas: Canvas, dialog: Rect, focus: UInt8, text: String,
    ):
        """Single-line input strip in the Turbo Vision style: cyan
        face when blurred, blue with white text when focused. The
        cyan/blue contrast against the LIGHT_GRAY dialog body reads
        as a pressed-in field at a glance — the same idiom the C++
        original used for ``Save File As`` / ``Open File`` inputs.
        """
        var row = _row_for_focus(focus)
        if row < 0:
            return
        var ir = _input_rect(dialog, row)
        var has_focus = self.focus == focus
        var fill_attr = (
            Attr(WHITE, BLUE) if has_focus else Attr(BLACK, CYAN)
        )
        canvas.fill(ir, String(" "), fill_attr)
        _ = canvas.put_text(
            Point(ir.a.x, ir.a.y), text, fill_attr, ir.b.x,
        )
        if has_focus:
            var cur_x = ir.a.x + len(text.as_bytes())
            if cur_x < ir.b.x:
                canvas.set(
                    cur_x, ir.a.y, Cell(String(" "), Attr(BLACK, LIGHT_GRAY), 1),
                )

    fn _lang_dropdown(self, current: String) -> Dropdown:
        """Build a fresh ``Dropdown`` for the debug-language slot,
        seeded from ``current``. The option list is the empty slot
        (Cmd+D disabled) followed by every ``DebuggerSpec.language_id``
        in the built-in registry — adding a new spec automatically
        surfaces in the dialog without touching this file."""
        var options = List[String]()
        options.append(String(""))
        var specs = built_in_debuggers()
        for i in range(len(specs)):
            options.append(specs[i].language_id)
        var dd = Dropdown(options^, 0)
        dd.set_value(current)
        return dd^

    fn _paint_lang_dropdown(
        self, mut canvas: Canvas, dialog: Rect, current: String,
    ):
        """Render the debug-language dropdown using the same focus
        colours as ``_paint_input`` so the form reads as a uniform
        row of editable strips."""
        var row = _row_for_focus(_FOCUS_LANG)
        if row < 0:
            return
        var ir = _input_rect(dialog, row)
        var has_focus = self.focus == _FOCUS_LANG
        var dd = self._lang_dropdown(current)
        dd.paint(
            canvas, ir, has_focus,
            Attr(WHITE, BLUE), Attr(BLACK, CYAN),
        )

    fn _paint_buttons(mut self, mut canvas: Canvas, rect: Rect):
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
        var y = rect.b.y - 3
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
            if self.focus == _FOCUS_LIST:
                self._move_selection(-1)
                return True
            return True
        if k == KEY_DOWN:
            if self.focus == _FOCUS_LIST:
                self._move_selection(1)
                return True
            return True
        if k == KEY_LEFT or k == KEY_RIGHT:
            if self.focus == _FOCUS_LANG:
                self._cycle_lang(event)
            return True
        if k == KEY_BACKSPACE:
            return self._backspace_focused()
        if UInt32(0x20) <= k and k < UInt32(0x7F):
            return self._type_focused(chr(Int(k)))
        return True

    fn _cycle_lang(mut self, event: Event):
        """Step the debug-language dropdown in response to a Left /
        Right press. Round-trips through ``Dropdown`` so unknown
        loaded values are preserved (see ``Dropdown.set_value``)."""
        if self.selected < 0:
            return
        var t = self._selected_target()
        var dd = self._lang_dropdown(t.debug_language)
        if not dd.handle_key(event):
            return
        t.debug_language = dd.value()
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
        self.selected = s
        self._scroll_selection_into_view()

    fn _scroll_selection_into_view(mut self):
        # The visible row count depends on the list rect, which we
        # don't have here; clip on next paint where it's known.
        # Reset enough that paint will pick up.
        if self.selected >= 0 and self.selected < self._list_scroll:
            self._list_scroll = self.selected

    fn _backspace_focused(mut self) -> Bool:
        if self.focus == _FOCUS_NAME:
            var t = self._selected_target()
            t.name = _str_pop_byte(t.name)
            self._put_selected(t^)
            return True
        if self.focus == _FOCUS_PROGRAM:
            var t = self._selected_target()
            t.program = _str_pop_byte(t.program)
            self._put_selected(t^)
            return True
        if self.focus == _FOCUS_ARGS:
            var t = self._selected_target()
            var joined = _join_args(t.args)
            joined = _str_pop_byte(joined)
            t.args = _split_args(joined)
            self._put_selected(t^)
            return True
        if self.focus == _FOCUS_CWD:
            var t = self._selected_target()
            t.cwd = _str_pop_byte(t.cwd)
            self._put_selected(t^)
            return True
        # _FOCUS_LANG is a dropdown — backspace is a no-op there.
        return True

    fn _type_focused(mut self, ch: String) -> Bool:
        if self.focus == _FOCUS_NAME:
            var t = self._selected_target()
            t.name = t.name + ch
            self._put_selected(t^)
            return True
        if self.focus == _FOCUS_PROGRAM:
            var t = self._selected_target()
            t.program = t.program + ch
            self._put_selected(t^)
            return True
        if self.focus == _FOCUS_ARGS:
            var t = self._selected_target()
            var joined = _join_args(t.args) + ch
            t.args = _split_args(joined)
            self._put_selected(t^)
            return True
        if self.focus == _FOCUS_CWD:
            var t = self._selected_target()
            t.cwd = t.cwd + ch
            self._put_selected(t^)
            return True
        # _FOCUS_LANG is a dropdown — typing letters is a no-op there;
        # left/right are routed via ``_cycle_lang`` instead.
        return True

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
        var rows = List[UInt8]()
        rows.append(_FOCUS_NAME)
        rows.append(_FOCUS_PROGRAM)
        rows.append(_FOCUS_ARGS)
        rows.append(_FOCUS_CWD)
        rows.append(_FOCUS_LANG)
        for i in range(len(rows)):
            var row = _row_for_focus(rows[i])
            if row < 0:
                continue
            if _input_rect(rect, row).contains(pos):
                return True
        return False

    fn handle_mouse(mut self, event: Event, screen: Rect) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_MOUSE:
            return True
        var rect = _dialog_rect(screen, self.pos)
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
        if event.button == MOUSE_BUTTON_LEFT and event.pressed \
                and not event.motion and event.pos.y == rect.a.y \
                and rect.a.x <= event.pos.x and event.pos.x < rect.b.x:
            self._drag = Optional[Point](Point(
                event.pos.x - rect.a.x, event.pos.y - rect.a.y,
            ))
            return True
        # Wheel scroll inside the list.
        var list_rect = _list_rect(rect)
        if event.button == MOUSE_WHEEL_UP \
                and list_rect.contains(event.pos):
            self._list_scroll -= 1
            if self._list_scroll < 0:
                self._list_scroll = 0
            return True
        if event.button == MOUSE_WHEEL_DOWN \
                and list_rect.contains(event.pos):
            self._list_scroll += 1
            return True
        if event.button != MOUSE_BUTTON_LEFT or not event.pressed \
                or event.motion:
            return True
        # Click inside the list: select the row that was hit. With
        # the framing border gone, every row of ``list_rect`` is a
        # data row — no inset to skip past.
        if list_rect.contains(event.pos):
            var idx = self._list_scroll + (event.pos.y - list_rect.a.y)
            if 0 <= idx and idx < len(self.entries):
                self.selected = idx
            self.focus = _FOCUS_LIST
            return True
        # Click into a form input.
        var fields = List[UInt8]()
        fields.append(_FOCUS_NAME)
        fields.append(_FOCUS_PROGRAM)
        fields.append(_FOCUS_ARGS)
        fields.append(_FOCUS_CWD)
        fields.append(_FOCUS_LANG)
        for i in range(len(fields)):
            var row = _row_for_focus(fields[i])
            if row < 0:
                continue
            var ir = _input_rect(rect, row)
            if ir.contains(event.pos):
                if self.selected < 0:
                    return True
                self.focus = fields[i]
                if fields[i] == _FOCUS_LANG:
                    self._click_lang(ir, screen, event)
                return True
        return True

    fn _click_lang(mut self, ir: Rect, screen: Rect, event: Event):
        """Forward a click on the language field to the dropdown.
        The dropdown is rebuilt fresh each paint so it has no
        persistent open state — body clicks just set focus (already
        done by the caller); popup interactions are unreachable
        from this stateless instance.
        """
        if self.selected < 0:
            return
        var t = self._selected_target()
        var dd = self._lang_dropdown(t.debug_language)
        _ = dd.handle_mouse(ir, screen, event)
        t.debug_language = dd.value()
        self._put_selected(t^)
