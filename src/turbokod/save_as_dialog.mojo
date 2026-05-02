"""Modal save-as dialog: filename input plus a directory chooser.

Open with ``open(start_path)``: the dialog seeds the filename input from
``basename(start_path)`` and the directory listing from
``parent_path(start_path)``. Typing keys edit the filename; Up/Down/PgUp/
PgDn always move the directory selection; Tab toggles keyboard focus
between the input and the listing. Enter submits when focus is on the
input, or descends into the highlighted directory when focus is on the
listing. Backspace deletes a filename character (input-focused) or
ascends to the parent directory (listing-focused). Esc cancels.

The directory listing is filtered to directories only — files would be
visual noise here, since the user is choosing a *folder* to save into,
not picking a file to overwrite. Code is shared with ``FileDialog`` via
``DirBrowser``.

On submit, ``submitted=True`` and ``selected_path`` holds the joined
``<dir>/<filename>``. The host calls ``close()`` to dismiss.
"""

from std.collections.optional import Optional

from .canvas import Canvas
from .cell import Cell
from .colors import Attr, BLACK, BLUE, LIGHT_GRAY, WHITE
from .dir_browser import DirBrowser
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_BACKSPACE, KEY_DOWN, KEY_ENTER, KEY_ESC, KEY_TAB, KEY_UP,
    KEY_PAGEDOWN, KEY_PAGEUP,
    MOUSE_BUTTON_LEFT,
)
from .file_io import basename, join_path, parent_path
from .geometry import Point, Rect
from .text_field import text_field_clipboard_key
from .window import hit_close_button, paint_close_button, paint_drop_shadow


comptime _DIALOG_W = 60
comptime _DIALOG_H = 20

# Focus modes — kept as small ints since Mojo enums aren't widely used in
# this codebase yet.
comptime _FOCUS_INPUT   = UInt8(0)
comptime _FOCUS_LISTING = UInt8(1)


fn _dialog_rect(screen: Rect, pos: Optional[Point]) -> Rect:
    """Compute the dialog's screen rect. ``pos`` is the user-chosen
    top-left after a title-bar drag; when unset, the dialog auto-
    centers. Out-of-bounds positions are clamped so the title bar
    can't be pushed off the screen and become unreachable."""
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


fn _input_rect(dialog: Rect) -> Rect:
    """One-row strip that holds the editable filename. Sits at y+2 so y+1
    can carry the static ``File:`` label."""
    return Rect(dialog.a.x + 8, dialog.a.y + 2, dialog.b.x - 1, dialog.a.y + 3)


fn _list_rect(dialog: Rect) -> Rect:
    """Listing starts at y+5; the four rows below it carry a 1-row
    visual gap, the green button face, the half-block drop shadow,
    and the hint line painted over the bottom border — in that
    order. The gap keeps the selection bar from looking like it's
    bleeding into the button face."""
    return Rect(
        dialog.a.x + 2, dialog.a.y + 5,
        dialog.b.x - 1, dialog.b.y - 4,
    )


fn _buttons_rect(dialog: Rect) -> Rect:
    # Two rows tall — face row + shadow row — so the TV-style 3D
    # button effect has somewhere to land.
    var y = dialog.b.y - 3
    return Rect(dialog.a.x + 2, y, dialog.b.x - 1, y + 2)


struct SaveAsDialog(Movable):
    var active: Bool
    var submitted: Bool
    var filename: String          # editable input text
    var selected_path: String     # populated on submit
    var focus: UInt8              # _FOCUS_INPUT or _FOCUS_LISTING
    var browser: DirBrowser       # dirs-only listing
    var pos: Optional[Point]
    """Top-left of the dialog after a title-bar drag, or ``None`` to
    auto-center. Reset on every ``open`` so a freshly-invoked dialog
    starts in the middle of the screen."""
    var _drag: Optional[Point]
    """Cursor offset within the dialog at drag-start; ``None`` means
    not currently dragging."""

    fn __init__(out self):
        self.active = False
        self.submitted = False
        self.filename = String("")
        self.selected_path = String("")
        self.focus = _FOCUS_INPUT
        self.browser = DirBrowser(True)
        self.pos = Optional[Point]()
        self._drag = Optional[Point]()

    fn open(mut self, var start_path: String):
        """Seed the dialog from a path. ``start_path`` may be empty (a
        brand-new buffer): in that case the listing starts at ``"."``
        and the filename input is empty.
        """
        var dir = String(".")
        var name = String("")
        if len(start_path.as_bytes()) > 0:
            dir = parent_path(start_path)
            if len(dir.as_bytes()) == 0:
                dir = String(".")
            name = basename(start_path)
        self.active = True
        self.submitted = False
        self.filename = name^
        self.selected_path = String("")
        self.focus = _FOCUS_INPUT
        self.browser.open(dir^)
        self.pos = Optional[Point]()
        self._drag = Optional[Point]()

    fn close(mut self):
        self.active = False
        self.submitted = False
        self.filename = String("")
        self.selected_path = String("")
        self.focus = _FOCUS_INPUT
        self.browser = DirBrowser(True)
        self.pos = Optional[Point]()
        self._drag = Optional[Point]()

    # --- painting ----------------------------------------------------------

    fn paint(mut self, mut canvas: Canvas, screen: Rect):
        if not self.active:
            return
        # Same Turbo Vision palette as ``FileDialog``: light-gray
        # body, bright double-line frame, and a title chunk painted
        # in body colours over the top edge.
        var bg = Attr(BLACK, LIGHT_GRAY)
        var border = Attr(WHITE, LIGHT_GRAY)
        var title_attr = Attr(BLACK, LIGHT_GRAY)
        var dir_attr = Attr(BLUE, LIGHT_GRAY)
        var input_focused_attr = Attr(WHITE, BLUE)
        var input_blur_attr = Attr(BLACK, LIGHT_GRAY)
        var rect = _dialog_rect(screen, self.pos)
        # Drop shadow first — see ``FileDialog.paint`` for the rationale.
        paint_drop_shadow(canvas, rect)
        canvas.fill(rect, String(" "), bg)
        canvas.draw_box(rect, border, True)
        # Title bar.
        var title = String(" Save As ")
        var tx = rect.a.x + (rect.width() - len(title.as_bytes())) // 2
        _ = canvas.put_text(Point(tx, rect.a.y), title, title_attr)
        # Close button shares the same chrome as editor windows.
        paint_close_button(canvas, Point(rect.a.x, rect.a.y), border)
        # Filename label + editable strip.
        _ = canvas.put_text(
            Point(rect.a.x + 2, rect.a.y + 2), String("File:"), bg,
        )
        var input_rect = _input_rect(rect)
        var input_attr = (
            input_focused_attr if self.focus == _FOCUS_INPUT
            else input_blur_attr
        )
        canvas.fill(input_rect, String(" "), input_attr)
        _ = canvas.put_text(
            Point(input_rect.a.x, input_rect.a.y),
            self.filename, input_attr, input_rect.b.x,
        )
        if self.focus == _FOCUS_INPUT:
            var cur_x = input_rect.a.x + len(self.filename.as_bytes())
            if cur_x < input_rect.b.x:
                canvas.set(
                    cur_x, input_rect.a.y,
                    Cell(String(" "), Attr(LIGHT_GRAY, BLACK), 1),
                )
        # Current-directory line above the listing.
        _ = canvas.put_text(
            Point(rect.a.x + 2, rect.a.y + 4),
            self.browser.dir, dir_attr, rect.b.x - 1,
        )
        # Listing.
        self.browser.paint(
            canvas, _list_rect(rect), self.focus == _FOCUS_LISTING,
        )
        # Desktop / Home / Root quick-jump strip just above the hint.
        self.browser.paint_jump_buttons(canvas, _buttons_rect(rect))
        # Hint at the bottom — varies with focus to nudge the user toward
        # the right key for the thing they're trying to do.
        var hint: String
        if self.focus == _FOCUS_INPUT:
            hint = String(" Enter: save  Tab: pick folder  ESC: cancel ")
        else:
            hint = String(" Enter: open  ⌫: parent  Tab: edit name  ESC: cancel ")
        _ = canvas.put_text(
            Point(rect.a.x + 2, rect.b.y - 1),
            hint, dir_attr, rect.b.x - 1,
        )

    # --- key handling -----------------------------------------------------

    fn handle_key(mut self, event: Event) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_KEY:
            return True
        var k = event.key
        # ``-9`` accounts for: 1 (top border) + 1 (gap) + 1 (input)
        # + 1 (gap) + 1 (current-dir line) + 1 (gap below list) +
        # 1 (button face) + 1 (button shadow) + 1 (hint / bottom).
        var list_h = _DIALOG_H - 9
        if k == KEY_ESC:
            self.close()
            return True
        if k == KEY_TAB:
            if self.focus == _FOCUS_INPUT:
                self.focus = _FOCUS_LISTING
            else:
                self.focus = _FOCUS_INPUT
            return True
        # Navigation keys always move the listing — they don't have a
        # natural meaning inside a single-line input, and giving the
        # listing a side-channel to its selection avoids an extra Tab.
        if k == KEY_UP:
            self.browser.move_by(-1, list_h)
            return True
        if k == KEY_DOWN:
            self.browser.move_by(1, list_h)
            return True
        if k == KEY_PAGEUP:
            self.browser.move_by(-10, list_h)
            return True
        if k == KEY_PAGEDOWN:
            self.browser.move_by(10, list_h)
            return True
        if k == KEY_ENTER:
            if self.focus == _FOCUS_LISTING:
                # Descend / ascend; never submits from listing focus —
                # users explicitly Tab back to the input to confirm.
                var name = self.browser.current_name()
                if name == String(".."):
                    self.browser.ascend()
                elif self.browser.current_is_dir():
                    self.browser.descend(name)
                return True
            self._submit()
            return True
        if k == KEY_BACKSPACE:
            if self.focus == _FOCUS_INPUT:
                var bytes = self.filename.as_bytes()
                if len(bytes) > 0:
                    self.filename = String(StringSlice(
                        unsafe_from_utf8=bytes[:len(bytes) - 1],
                    ))
                return True
            self.browser.ascend()
            return True
        if self.focus == _FOCUS_INPUT:
            # Cut / copy / paste only edit the filename strip; the
            # listing has no editable text, so a Ctrl+V there should
            # fall through to the type-to-search branch (which itself
            # ignores control codepoints).
            var clip = text_field_clipboard_key(event, self.filename)
            if clip.consumed:
                return True
        if UInt32(0x20) <= k and k < UInt32(0x7F):
            if self.focus == _FOCUS_LISTING:
                # Type-to-search: jump the directory selection to the
                # first folder whose name starts with the accumulated
                # buffer (case-insensitive). 800ms after the last
                # keystroke the buffer resets — Finder / Explorer /
                # GNOME Files all behave this way.
                _ = self.browser.type_to_search(chr(Int(k)), list_h)
                return True
            # Input-focused: the keystroke edits the filename.
            self.filename = self.filename + chr(Int(k))
            return True
        return True

    fn _submit(mut self):
        """Stamp ``selected_path`` and flip the submit flag — but only
        when the filename input has at least one character. An empty
        filename would happily ``join_path`` to a trailing-slash path
        and likely fail the write later; refusing the submit up front
        is friendlier than producing an obviously-broken target.
        """
        if len(self.filename.as_bytes()) == 0:
            self.focus = _FOCUS_INPUT
            return
        self.selected_path = join_path(self.browser.dir, self.filename)
        self.submitted = True

    # --- mouse ------------------------------------------------------------

    fn is_input_at(self, pos: Point, screen: Rect) -> Bool:
        """True iff ``pos`` lies on the editable filename row. Used by
        the host to hint a text-cursor shape over the input but a
        default arrow over the listing and buttons."""
        if not self.active:
            return False
        return _input_rect(_dialog_rect(screen, self.pos)).contains(pos)

    fn handle_mouse(mut self, event: Event, screen: Rect) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_MOUSE:
            return True
        var rect = _dialog_rect(screen, self.pos)
        # Title-bar drag: same handling as ``FileDialog`` — a press on
        # the title row begins a move, motion repositions, release
        # ends. Resolved before any input/listing dispatch so a click
        # that *starts* on the title can never also activate widgets
        # the cursor crosses while moving.
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
            return True
        # Close button [■] dismisses the dialog. Resolved before the
        # title-bar drag so a click on the glyph doesn't begin a move.
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
        var input_rect = _input_rect(rect)
        var list_rect = _list_rect(rect)
        # Click in the filename strip steals focus; the click position
        # itself doesn't move a caret yet (the input has no internal
        # cursor model — typing always appends).
        if event.pressed and not event.motion \
                and event.button == MOUSE_BUTTON_LEFT \
                and input_rect.contains(event.pos):
            self.focus = _FOCUS_INPUT
            return True
        # Quick-jump strip lives between the listing and the hint —
        # check it before the listing's mouse handler so the jump
        # buttons' row doesn't get swallowed as out-of-list.
        if self.browser.handle_jump_click(event, _buttons_rect(rect)):
            self.focus = _FOCUS_LISTING
            return True
        var idx = self.browser.handle_list_mouse(event, list_rect)
        if idx == -2:
            return True   # wheel scroll
        if idx < 0:
            # Click is outside the list; swallow if inside the modal.
            return True
        # Any click on a listing row also pulls focus to the listing —
        # otherwise typing right after a click would unexpectedly land
        # in the filename input.
        self.focus = _FOCUS_LISTING
        if self.browser.entries[idx] == String(".."):
            self.browser.ascend()
            return True
        if idx == self.browser.selected:
            # Second click on the same entry: descend (the listing is
            # dirs-only so there's no "select a file" branch).
            if self.browser.entry_is_dir[idx]:
                var name = self.browser.entries[idx]
                self.browser.descend(name)
            return True
        self.browser.set_selection(idx, list_rect.height())
        return True
