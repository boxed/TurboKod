"""Modal dialog for editing one ``OnSaveAction``.

Mirrors the shape of ``TargetsDialog``'s right-pane form but focused on
a single record. Layout::

    ╔════════ Edit on-save action ════════════════════════╗
    ║                                                     ║
    ║ Language:   < python              >                 ║
    ║                                                     ║
    ║ Program:    [/usr/local/bin/black…………]  [ Browse ]  ║
    ║                                                     ║
    ║ Arguments:  [--quiet $FilePath$………………]                ║
    ║             ($FilePath$ expands to the saved path)  ║
    ║ Working dir [………………………………………………]                    ║
    ║             (empty = project root)                  ║
    ║                                                     ║
    ║                          [ Save ]    [ Cancel ]     ║
    ╚═════════════════════════════════════════════════════╝

Browse opens an embedded ``FileDialog`` and pipes its ``selected_path``
back into the Program field on submit. Save sets ``submitted=True`` and
the host reads ``self.value()``. Cancel closes without submitting.

The dialog edits a private copy of the action — ``open`` snapshots, and
the host only commits the in-memory copy back to the config when it
sees ``submitted``.
"""

from std.collections.list import List
from std.collections.optional import Optional

from .buttons import (
    BUTTON_FIRED, BUTTON_NONE, ShadowButton, paint_shadow_button,
)
from .canvas import Canvas, paint_drop_shadow
from .painter import Painter
from .cell import Cell
from .colors import (
    Attr, BLACK, BLUE, CYAN, GREEN, LIGHT_GRAY, RED, WHITE,
)
from .config import OnSaveAction
from .dropdown import (
    DROPDOWN_HIT_BODY, DROPDOWN_HIT_NONE, DROPDOWN_HIT_OUTSIDE,
    DROPDOWN_HIT_POPUP, Dropdown,
)
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_DOWN, KEY_ENTER, KEY_ESC, KEY_LEFT, KEY_RIGHT,
    KEY_TAB, KEY_UP,
    MOD_NONE, MOD_SHIFT, MOUSE_BUTTON_LEFT,
)
from .file_dialog import FileDialog
from .geometry import Point, Rect, compute_dialog_rect
from .language_config import built_in_servers
from .text_field import Form
from .view import RowCursor
from .window import (
    hit_close_button, paint_close_button, paint_window_title,
)


# --- focus discriminants --------------------------------------------------
comptime _FOCUS_LANG     = UInt8(0)
comptime _FOCUS_PROGRAM  = UInt8(1)
comptime _FOCUS_BROWSE   = UInt8(2)
comptime _FOCUS_ARGS     = UInt8(3)
comptime _FOCUS_CWD      = UInt8(4)
comptime _FOCUS_SAVE     = UInt8(5)
comptime _FOCUS_CANCEL   = UInt8(6)
comptime _FOCUS_COUNT    = 7


# --- layout ---------------------------------------------------------------

comptime _DIALOG_W = 64
comptime _DIALOG_H = 16
comptime _LABEL_COL_W = 14   # width of the left-side label column
comptime _BROWSE_BTN_W = 9
"""Width of the Browse button (face " Browse " = 8 cols + 1-col
shadow). Used to carve out space at the right edge of the Program
row so the editable strip doesn't overrun the button."""


fn _dialog_rect(screen: Rect, pos: Optional[Point]) -> Rect:
    return compute_dialog_rect(screen, pos, _DIALOG_W, _DIALOG_H)


@fieldwise_init
struct _Layout(ImplicitlyCopyable, Movable):
    """Pre-computed rects + row anchors for the action editor.

    Built once per paint / mouse event so painted geometry and
    hit-test geometry can't drift apart. Form rows flow top-down
    through ``RowCursor``; the Arguments and Working-dir fields each
    occupy a 2-row block so the hint line glued underneath them
    serves as the visual separator from the next control without
    needing an extra blank row.
    """
    var lang_rect: Rect
    var program_rect: Rect
    var args_rect: Rect
    var args_hint_y: Int
    var cwd_rect: Rect
    var cwd_hint_y: Int
    var bottom_buttons_y: Int
    var label_x: Int

    fn field_rects(self) -> List[Rect]:
        """Form-input row rects in registration order
        (``_FOCUS_PROGRAM``, ``_FOCUS_ARGS``, ``_FOCUS_CWD``) — what
        ``Form.handle_mouse`` expects."""
        var rects = List[Rect]()
        rects.append(self.program_rect)
        rects.append(self.args_rect)
        rects.append(self.cwd_rect)
        return rects^


fn _build_layout(rect: Rect) -> _Layout:
    var cursor = RowCursor(rect.a.y + 2)
    var lang_y = cursor.place()
    var program_y = cursor.place()
    # Arguments + its $FilePath$ hint read as one logical control;
    # place(2) reserves both rows so the next gap lands below the
    # hint.
    var args_y = cursor.place(2)
    # Working dir + its (empty = project root) hint is glued under
    # args — the hint is the visual separator, no additional gap.
    var cwd_y = cursor.place_tight(2)
    var label_x = rect.a.x + 2
    var field_x = label_x + _LABEL_COL_W
    var right_max = rect.b.x - 2
    var program_right = right_max - (_BROWSE_BTN_W + 2)
    return _Layout(
        Rect(field_x, lang_y, right_max, lang_y + 1),
        Rect(field_x, program_y, program_right, program_y + 1),
        Rect(field_x, args_y, right_max, args_y + 1),
        args_y + 1,
        Rect(field_x, cwd_y, right_max, cwd_y + 1),
        cwd_y + 1,
        rect.b.y - 3,
        label_x,
    )


@fieldwise_init
struct _PlacedButton(ImplicitlyCopyable, Movable):
    var button: ShadowButton
    var focus: UInt8
    var enabled: Bool


# --- ActionEditor ---------------------------------------------------------


struct ActionEditor(Movable):
    var active: Bool
    var submitted: Bool
    """Set on Save. Host reads ``self.value()`` then calls ``close()``."""
    var entry: OnSaveAction
    """Editable copy. ``open`` snapshots the host's record into here;
    Save returns this via ``value()`` so the host can splice it back
    into its list at the appropriate index."""
    var edit_index: Int
    """Original index in the host's list (-1 for "new", else the slot
    being replaced). Carried verbatim so the host can re-find the
    record without keeping its own pending state."""
    var focus: UInt8
    var pos: Optional[Point]
    var _drag: Optional[Point]
    var file_dialog: FileDialog
    """Inline browse picker. When ``file_dialog.active`` is True it
    eats all events on top of this dialog; ``handle_*`` route to it
    first, then on submit the chosen path lands in ``entry.program``."""
    var lang_dropdown: Dropdown
    """Persistent language picker. Stateful so clicks on the strip
    actually open a popup the user can pick from — a stateless
    rebuild-each-paint version (which we used originally) silently
    drops the toggle so clicks felt like no-ops. Re-seeded from
    ``built_in_servers()`` on every ``open`` so a freshly-loaded LSP
    catalog is reflected."""
    # Editable input strips, grouped as a ``Form`` so the dialog
    # never touches mouse / keyboard / drag plumbing for individual
    # fields. Three fields registered in order:
    # ``_FOCUS_PROGRAM`` (idx 0), ``_FOCUS_ARGS`` (idx 1),
    # ``_FOCUS_CWD`` (idx 2). Programmatic state (``entry.program``,
    # ``entry.cwd``, args list) is recomputed from these on Save, so
    # edits during the dialog's lifetime don't poke at the host
    # snapshot.
    #
    # The Args field's text is kept as a single free-form string
    # (with spaces / trailing whitespace preserved) and is only
    # committed to ``entry.args`` via ``_split_args`` on Save.
    var form: Form
    var _buttons: List[_PlacedButton]

    fn __init__(out self):
        self.active = False
        self.submitted = False
        self.entry = OnSaveAction()
        self.edit_index = -1
        self.focus = _FOCUS_LANG
        self.pos = Optional[Point]()
        self._drag = Optional[Point]()
        self.file_dialog = FileDialog()
        self.lang_dropdown = _build_lang_dropdown(String(""))
        self.form = Form()
        self.form.add(_FOCUS_PROGRAM)
        self.form.add(_FOCUS_ARGS)
        self.form.add(_FOCUS_CWD)
        self._buttons = List[_PlacedButton]()
        self._buttons.append(_PlacedButton(
            ShadowButton(String(" Browse "), 0, 0), _FOCUS_BROWSE, True,
        ))
        self._buttons.append(_PlacedButton(
            ShadowButton(String(" Save "), 0, 0), _FOCUS_SAVE, True,
        ))
        self._buttons.append(_PlacedButton(
            ShadowButton(String(" Cancel "), 0, 0), _FOCUS_CANCEL, True,
        ))

    fn open(mut self, var entry: OnSaveAction, edit_index: Int):
        """Begin editing ``entry``. ``edit_index = -1`` signals
        "new"; any other value is the host-list slot being edited."""
        # Capture the language id before consuming the entry — Mojo's
        # exclusivity check rejects reading a field on a value we're
        # about to move.
        var seed_lang = entry.language_id
        var seed_args = _join_args(entry.args)
        var seed_program = entry.program
        var seed_cwd = entry.cwd
        self.entry = entry^
        self.edit_index = edit_index
        self.active = True
        self.submitted = False
        self.focus = _FOCUS_LANG
        self.pos = Optional[Point]()
        self._drag = Optional[Point]()
        self.lang_dropdown = _build_lang_dropdown(seed_lang^)
        self.form = Form()
        self.form.add(_FOCUS_PROGRAM)
        self.form.add(_FOCUS_ARGS)
        self.form.add(_FOCUS_CWD)
        self.form.set_text(_FOCUS_PROGRAM, seed_program^)
        self.form.set_text(_FOCUS_ARGS, seed_args^)
        self.form.set_text(_FOCUS_CWD, seed_cwd^)

    fn close(mut self):
        self.active = False
        self.submitted = False
        self.entry = OnSaveAction()
        self.edit_index = -1
        self.focus = _FOCUS_LANG
        self.pos = Optional[Point]()
        self._drag = Optional[Point]()
        self.file_dialog.close()
        self.lang_dropdown = _build_lang_dropdown(String(""))
        self.form = Form()
        self.form.add(_FOCUS_PROGRAM)
        self.form.add(_FOCUS_ARGS)
        self.form.add(_FOCUS_CWD)
        for i in range(len(self._buttons)):
            self._buttons[i].button.pressed = False
            self._buttons[i].button.pressed_inside = False

    fn value(self) -> OnSaveAction:
        # Snapshot the editable fields back into ``entry`` before
        # returning. Edits during the dialog's life live on the
        # TextFields; ``entry`` is the host-facing record, populated
        # only on ``value()`` (and read by Save).
        var out = self.entry.copy()
        out.program = self.form.text(_FOCUS_PROGRAM)
        out.cwd = self.form.text(_FOCUS_CWD)
        out.args = _split_args(self.form.text(_FOCUS_ARGS))
        return out^

    # --- painting ---------------------------------------------------

    fn paint(mut self, mut canvas: Canvas, screen: Rect):
        if not self.active:
            return
        var bg = Attr(BLACK, LIGHT_GRAY)
        var border = Attr(WHITE, LIGHT_GRAY)
        var hint = Attr(BLUE, LIGHT_GRAY)
        var rect = _dialog_rect(screen, self.pos)
        var layout = _build_layout(rect)
        paint_drop_shadow(canvas, rect)
        var painter = Painter(rect)
        painter.fill(canvas, rect, String(" "), bg)
        painter.draw_box(canvas, rect, border, True)
        paint_window_title(
            canvas, rect, String(" Edit on-save action "), bg, bg,
        )
        paint_close_button(canvas, Point(rect.a.x, rect.a.y), border)
        # Labels.
        _ = painter.put_text(
            canvas, Point(layout.label_x, layout.lang_rect.a.y),
            String("Language:"), bg,
        )
        _ = painter.put_text(
            canvas, Point(layout.label_x, layout.program_rect.a.y),
            String("Program:"), bg,
        )
        _ = painter.put_text(
            canvas, Point(layout.label_x, layout.args_rect.a.y),
            String("Arguments:"), bg,
        )
        _ = painter.put_text(
            canvas, Point(layout.args_rect.a.x, layout.args_hint_y),
            String("$FilePath$ expands to the saved file path"),
            hint,
        )
        _ = painter.put_text(
            canvas, Point(layout.label_x, layout.cwd_rect.a.y),
            String("Working dir:"), bg,
        )
        _ = painter.put_text(
            canvas, Point(layout.cwd_rect.a.x, layout.cwd_hint_y),
            String("(empty = project root)"), hint,
        )
        # Inputs are painted through the ``Form`` widget — one call
        # per row so labels and hints can interleave between them.
        # ``Form.paint_field`` looks the field up by focus ID and
        # forwards to its internal ``TextField.paint`` (which owns
        # the horizontal scroll offset, hence why the form takes
        # ``mut self``).
        self._paint_lang(canvas, layout)
        self.form.paint_field(
            canvas, _FOCUS_PROGRAM, layout.program_rect,
            self.focus == _FOCUS_PROGRAM,
        )
        self.form.paint_field(
            canvas, _FOCUS_ARGS, layout.args_rect,
            self.focus == _FOCUS_ARGS,
        )
        self.form.paint_field(
            canvas, _FOCUS_CWD, layout.cwd_rect,
            self.focus == _FOCUS_CWD,
        )
        # Buttons.
        self._paint_buttons(canvas, rect, layout)
        # Dropdown popup overlays the form when open. Paint after the
        # form so it sits on top, but before the file dialog so a Browse
        # popup wins over it.
        if self.lang_dropdown.is_open:
            self.lang_dropdown.paint_popup(canvas, layout.lang_rect, screen)
        # The file dialog floats on top when open — paint last so it
        # overlays the edit form.
        if self.file_dialog.active:
            self.file_dialog.paint(canvas, screen)

    fn _lang_dropdown(self, current: String) -> Dropdown:
        """Test-only convenience: build a one-shot dropdown the way
        ``open`` would. Production paint/event paths read from
        ``self.lang_dropdown`` directly so the open state persists."""
        return _build_lang_dropdown(current)

    fn _paint_lang(self, mut canvas: Canvas, layout: _Layout):
        var has_focus = self.focus == _FOCUS_LANG
        self.lang_dropdown.paint(
            canvas, layout.lang_rect, has_focus,
            Attr(WHITE, BLUE), Attr(BLACK, CYAN),
        )

    fn _paint_buttons(mut self, mut canvas: Canvas, rect: Rect, layout: _Layout):
        # Browse sits at the right edge of the Program row.
        var browse_y = layout.program_rect.a.y
        var browse_w = self._buttons[0].button.face_width()
        var browse_x = rect.b.x - 2 - (browse_w + 1)
        self._buttons[0].button.move_to(browse_x, browse_y)
        # Save / Cancel pinned to the bottom-right.
        var bottom_y = layout.bottom_buttons_y
        var cancel_w = self._buttons[2].button.face_width()
        var cancel_x = rect.b.x - 2 - (cancel_w + 1)
        var save_w = self._buttons[1].button.face_width()
        var save_x = cancel_x - 1 - (save_w + 1)
        self._buttons[1].button.move_to(save_x, bottom_y)
        self._buttons[2].button.move_to(cancel_x, bottom_y)
        for i in range(len(self._buttons)):
            self._paint_button(canvas, i)

    fn _paint_button(mut self, mut canvas: Canvas, idx: Int):
        var pb = self._buttons[idx]
        var face: Attr
        if self.focus == pb.focus:
            face = Attr(WHITE, BLUE)
        else:
            face = Attr(BLACK, GREEN)
        paint_shadow_button(canvas, pb.button, face, LIGHT_GRAY)

    # --- key handling -----------------------------------------------

    fn handle_key(mut self, event: Event) -> Bool:
        if not self.active:
            return False
        if self.file_dialog.active:
            _ = self.file_dialog.handle_key(event)
            self._maybe_consume_browse()
            return True
        if event.kind != EVENT_KEY:
            return True
        var k = event.key
        # Open dropdown popup eats Up/Down/Enter/Esc before the
        # dialog's own focus walk: the user expects arrow-key
        # navigation inside the popup, and Esc to close just the
        # popup (not the whole dialog).
        if self.focus == _FOCUS_LANG and self.lang_dropdown.is_open:
            if k == KEY_ESC:
                self.lang_dropdown.close()
                return True
            if self.lang_dropdown.handle_key(event):
                self.entry.language_id = self.lang_dropdown.value()
                return True
        if k == KEY_ESC:
            self.close()
            return True
        if k == KEY_TAB:
            var backward = (event.mods & MOD_SHIFT) != 0
            self.focus = self._next_focus(self.focus, backward)
            return True
        if k == KEY_ENTER:
            # Enter on the focused (closed) lang dropdown opens the
            # popup — cheaper-to-discover than "press right-arrow to
            # cycle." Once open, the branch above takes over.
            if self.focus == _FOCUS_LANG:
                self.lang_dropdown.open()
                return True
            return self._activate_focus()
        if k == KEY_DOWN:
            # Down on the closed lang dropdown also opens it (matches
            # how every other native picker behaves).
            if self.focus == _FOCUS_LANG:
                self.lang_dropdown.open()
                return True
            return True
        # Lang dropdown left/right cycles options; for editable inputs
        # we let the field handle them (cursor movement).
        if (k == KEY_LEFT or k == KEY_RIGHT) and self.focus == _FOCUS_LANG:
            self._cycle_lang(event)
            return True
        # Route to the focused editable strip via the ``Form``. The
        # form looks up the field by focus key and runs its key
        # handler; non-field focus (Save / Cancel / Browse) returns
        # ``consumed=False`` and falls through to the swallow below.
        var r = self.form.handle_key(event, self.focus)
        if r.consumed:
            return True
        return True

    fn _next_focus(self, current: UInt8, backward: Bool) -> UInt8:
        var n = _FOCUS_COUNT
        var idx = Int(current)
        if backward:
            idx = (idx - 1 + n) % n
        else:
            idx = (idx + 1) % n
        return UInt8(idx)

    fn _cycle_lang(mut self, event: Event):
        if not self.lang_dropdown.handle_key(event):
            return
        self.entry.language_id = self.lang_dropdown.value()

    fn _activate_focus(mut self) -> Bool:
        if self.focus == _FOCUS_BROWSE:
            self._open_browse()
            return True
        if self.focus == _FOCUS_SAVE:
            # Snapshot the field-backed values into ``entry`` so the
            # host (which reads ``value()``) sees what the user typed.
            self.entry.program = self.form.text(_FOCUS_PROGRAM)
            self.entry.cwd = self.form.text(_FOCUS_CWD)
            self.entry.args = _split_args(self.form.text(_FOCUS_ARGS))
            self.submitted = True
            return True
        if self.focus == _FOCUS_CANCEL:
            self.close()
            return True
        # Enter on a field walks to the next focus.
        self.focus = self._next_focus(self.focus, False)
        return True

    fn _open_browse(mut self):
        """Seed the file dialog at the directory of the current program
        path, or at the user's home when that's empty. The picker is
        modal-on-top of this dialog — events route to it until it
        submits or cancels."""
        var seed = self.form.text(_FOCUS_PROGRAM)
        if len(seed.as_bytes()) == 0:
            seed = String("/")
        else:
            # Use the parent directory so the user lands next to a
            # path they've already typed.
            var b = seed.as_bytes()
            var i = len(b) - 1
            while i >= 0 and b[i] != 0x2F:
                i -= 1
            if i > 0:
                seed = String(StringSlice(unsafe_from_utf8=b[:i]))
            elif i == 0:
                seed = String("/")
        self.file_dialog.open(seed^)

    fn _maybe_consume_browse(mut self):
        if not self.file_dialog.submitted:
            return
        var path = self.file_dialog.selected_path
        self.file_dialog.close()
        self.form.set_text(_FOCUS_PROGRAM, path^)
        self.focus = _FOCUS_PROGRAM

    # --- mouse ------------------------------------------------------

    fn handle_mouse(mut self, event: Event, screen: Rect) -> Bool:
        if not self.active:
            return False
        if self.file_dialog.active:
            _ = self.file_dialog.handle_mouse(event, screen)
            self._maybe_consume_browse()
            return True
        if event.kind != EVENT_MOUSE:
            return True
        var rect = _dialog_rect(screen, self.pos)
        var layout = _build_layout(rect)
        # Open dropdown popup gets first dibs on the click — same as
        # the keyboard branch. ``handle_mouse`` toggles open on body
        # click, commits + closes on a popup-row click, and closes on
        # an outside click.
        if self.lang_dropdown.is_open:
            var hit = self.lang_dropdown.handle_mouse(
                layout.lang_rect, screen, event,
            )
            if hit != DROPDOWN_HIT_NONE and hit != DROPDOWN_HIT_OUTSIDE:
                self.entry.language_id = self.lang_dropdown.value()
                self.focus = _FOCUS_LANG
                return True
            if hit == DROPDOWN_HIT_OUTSIDE:
                # Popup auto-closed; let the click fall through to
                # whatever it was actually targeting.
                pass
        # Buttons first so a click on a button focused elsewhere works.
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
        # All input-field mouse handling lives inside the ``Form``
        # widget — drag tracking, click counting, motion / release
        # dispatch, focus-on-press: every input affordance is
        # internal to the framework. The dialog hands the form the
        # event and its current row rects (in registration order)
        # and reads back whichever field's focus key was hit.
        var hit = self.form.handle_mouse(event, layout.field_rects())
        if hit:
            self.focus = hit.value()
            return True
        # Remaining widgets are press-only (no drag semantics): the
        # lang dropdown opens on a left press, nothing else.
        if event.button != MOUSE_BUTTON_LEFT or not event.pressed \
                or event.motion:
            return True
        if layout.lang_rect.contains(event.pos):
            # Closed dropdown clicked: forward to dd.handle_mouse so the
            # popup actually opens. Without this the strip just took
            # focus and the user had no way to discover the options
            # short of pressing arrow keys.
            var hit = self.lang_dropdown.handle_mouse(
                layout.lang_rect, screen, event,
            )
            if hit != DROPDOWN_HIT_NONE:
                self.entry.language_id = self.lang_dropdown.value()
            self.focus = _FOCUS_LANG
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


fn _build_lang_dropdown(var current: String) -> Dropdown:
    """Empty slot ("any file") followed by every known language id
    from the LSP registry. Built once per ``open`` and held as a
    persistent dropdown — clicking the strip toggles its popup, which
    only makes sense if the open state survives across paints.

    A registry-load failure (the bundled languages.json missing or
    cwd in an unexpected place) falls through to the empty sentinel
    plus a small hand-curated list so the user still gets a usable
    picker rather than a one-row dropdown. Tests guarantee at least
    one real entry under the normal cwd.
    """
    var options = List[String]()
    options.append(String(""))
    var specs = built_in_servers()
    for i in range(len(specs)):
        options.append(specs[i].language_id)
    if len(specs) == 0:
        # Defensive fallback for shipping configurations that don't
        # reach the bundled JSON. Better to give the user *some*
        # choice than nothing at all.
        options.append(String("python"))
        options.append(String("rust"))
        options.append(String("typescript"))
        options.append(String("javascript"))
        options.append(String("go"))
        options.append(String("c"))
        options.append(String("cpp"))
        options.append(String("ruby"))
        options.append(String("bash"))
        options.append(String("html"))
        options.append(String("css"))
        options.append(String("json"))
        options.append(String("yaml"))
        options.append(String("markdown"))
    var dd = Dropdown(options^, 0)
    dd.set_value(current^)
    return dd^


fn _join_args(args: List[String]) -> String:
    var out = String("")
    for i in range(len(args)):
        if i > 0:
            out = out + String(" ")
        out = out + args[i]
    return out^


fn _split_args(text: String) -> List[String]:
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
