"""Modal file-open dialog: directory listing with arrow-key navigation.

Open with ``open(start_dir)``. The user navigates with Up/Down arrows, opens a
directory by pressing Enter on it (the listing refreshes), and selects a file
by pressing Enter on it. Backspace ascends to the parent directory; Esc
cancels. On submit, ``submitted=True`` and ``selected_path`` holds the absolute
(or as-supplied) path; the caller calls ``close()`` to dismiss.

The directory-listing state and rendering live on ``DirBrowser`` (shared
with ``SaveAsDialog``); this file owns the modal lifecycle, the dialog
chrome, and the open-only key/mouse semantics.
"""

from std.collections.optional import Optional

from .canvas import Canvas
from .colors import Attr, BLACK, BLUE, LIGHT_GRAY, WHITE
from .dir_browser import DirBrowser
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_BACKSPACE, KEY_DOWN, KEY_ENTER, KEY_ESC, KEY_UP, KEY_PAGEDOWN, KEY_PAGEUP,
    MOUSE_BUTTON_LEFT,
)
from .file_io import join_path
from .geometry import Point, Rect, compute_dialog_rect
from .window import hit_close_button, paint_close_button, paint_drop_shadow


# Geometry must stay in sync between ``paint`` and ``handle_mouse`` —
# kept here so a tweak to one updates the other.
comptime _DIALOG_W = 60
comptime _DIALOG_H = 18


fn _dialog_rect(screen: Rect, pos: Optional[Point]) -> Rect:
    return compute_dialog_rect(screen, pos, _DIALOG_W, _DIALOG_H)


fn _list_rect(dialog: Rect) -> Rect:
    # Below the listing we reserve four rows: a 1-row visual gap
    # (so the listing's selection bar doesn't appear to bleed into
    # the green button face), the button face, the button shadow,
    # and the bottom-edge hint.
    var list_top = dialog.a.y + 3
    var list_bottom = dialog.b.y - 4
    return Rect(dialog.a.x + 2, list_top, dialog.b.x - 1, list_bottom)


fn _buttons_rect(dialog: Rect) -> Rect:
    # Two rows tall: ``b.y-3`` is the green button face, ``b.y-2``
    # the half-block drop shadow underneath. ``b.y-1`` is left for
    # the hint line painted over the bottom border.
    var y = dialog.b.y - 3
    return Rect(dialog.a.x + 2, y, dialog.b.x - 1, y + 2)


struct FileDialog(Movable):
    var active: Bool
    var submitted: Bool
    var selected_path: String
    var browser: DirBrowser
    var pos: Optional[Point]
    """Top-left of the dialog, or ``None`` to let ``_dialog_rect``
    auto-center. Stays unset until the user drags the title bar —
    each call to ``open`` resets it so a freshly-opened dialog
    always starts centered, even if the previous run was moved."""
    var _drag: Optional[Point]
    """Cursor offset within the dialog at drag-start. ``None`` =
    not currently dragging. Stored as offset rather than as a
    starting absolute point so the move tracks the cursor exactly,
    not relative to where the press happened on screen."""

    fn __init__(out self):
        self.active = False
        self.submitted = False
        self.selected_path = String("")
        self.browser = DirBrowser(False)
        self.pos = Optional[Point]()
        self._drag = Optional[Point]()

    fn open(mut self, var start_dir: String):
        self.active = True
        self.submitted = False
        self.selected_path = String("")
        self.browser.open(start_dir^)
        self.pos = Optional[Point]()
        self._drag = Optional[Point]()

    fn set_project(mut self, project: Optional[String]):
        """Tell the dialog about the active project so the listing's
        jump-button row gets a ``Project`` entry pointing to its
        root. Pass ``Optional[String]()`` to clear it. Cheap and
        idempotent — call after ``open`` from the host."""
        self.browser.set_project(project)

    fn close(mut self):
        self.active = False
        self.submitted = False
        self.selected_path = String("")
        self.browser = DirBrowser(False)
        self.pos = Optional[Point]()
        self._drag = Optional[Point]()

    # --- painting ----------------------------------------------------------

    fn paint(mut self, mut canvas: Canvas, screen: Rect):
        if not self.active:
            return
        # Turbo Vision palette: the dialog body sits on a light-gray
        # field with a bright double-line frame; the title chunk
        # paints over the top edge in the same body colours so it
        # reads as a label set into the border.
        var bg = Attr(BLACK, LIGHT_GRAY)
        var border = Attr(WHITE, LIGHT_GRAY)
        var title_attr = Attr(BLACK, LIGHT_GRAY)
        var dir_attr = Attr(BLUE, LIGHT_GRAY)
        var rect = _dialog_rect(screen, self.pos)
        # Drop shadow first — it darkens cells *outside* ``rect`` so
        # whatever workspace content sits behind the dialog reads as
        # dim-on-black underneath the right and bottom edges.
        paint_drop_shadow(canvas, rect)
        canvas.fill(rect, String(" "), bg)
        canvas.draw_box(rect, border, True)
        var title = String(" Open File ")
        var tx = rect.a.x + (rect.width() - len(title.as_bytes())) // 2
        _ = canvas.put_text(Point(tx, rect.a.y), title, title_attr)
        # TV-style close button in the top-left corner. Same chrome as
        # editor windows — the framework helper paints all three cells.
        paint_close_button(canvas, Point(rect.a.x, rect.a.y), border)
        _ = canvas.put_text(
            Point(rect.a.x + 2, rect.a.y + 1),
            self.browser.dir, dir_attr, rect.b.x - 1,
        )
        self.browser.paint(canvas, _list_rect(rect), True)
        # Desktop / Home / Root quick-jump strip just above the hint
        # — green TV-style buttons with shadows; colours are owned
        # by ``paint_jump_buttons`` so all dialogs stay consistent.
        self.browser.paint_jump_buttons(canvas, _buttons_rect(rect))
        _ = canvas.put_text(
            Point(rect.a.x + 2, rect.b.y - 1),
            String(" Enter: open  ⌫: parent  ESC: cancel "),
            dir_attr,
            rect.b.x - 1,
        )

    # --- events ------------------------------------------------------------

    fn handle_key(mut self, event: Event) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_KEY:
            return True
        var k = event.key
        # ``list_h`` is recovered from the canonical layout — keeping the
        # geometry computation in one place means navigation can't drift
        # against painting. ``-7`` accounts for: 1 (top border) + 1
        # (current-dir line) + 1 (gap above list) + 1 (gap below list) +
        # 1 (button face) + 1 (button shadow / hint share) + 1 (bottom).
        var list_h = _DIALOG_H - 7
        if k == KEY_ESC:
            self.close()
            return True
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
        if k == KEY_BACKSPACE:
            self.browser.ascend()
            return True
        if k == KEY_ENTER:
            self._activate_selection()
            return True
        # Type-to-search: printable ASCII jumps the selection to the
        # first entry whose name starts with the accumulated buffer
        # (case-insensitive). Standard fast-search behaviour from
        # Finder / Explorer / GNOME Files. Anything non-printable
        # (control chars, function keys, etc.) is just swallowed
        # by the trailing ``return True`` below.
        if UInt32(0x20) <= k and k < UInt32(0x7F):
            _ = self.browser.type_to_search(chr(Int(k)), list_h)
            return True
        return True

    fn _activate_selection(mut self):
        var name = self.browser.current_name()
        if len(name.as_bytes()) == 0:
            return
        if name == String(".."):
            self.browser.ascend()
            return
        if self.browser.current_is_dir():
            self.browser.descend(name)
            return
        self.selected_path = join_path(self.browser.dir, name)
        self.submitted = True

    # --- mouse -------------------------------------------------------------

    fn handle_mouse(mut self, event: Event, screen: Rect) -> Bool:
        """Click in entry list selects; click on already-selected entry opens.
        Wheel up/down scrolls the listing. Clicks outside the dialog are
        swallowed (modal). Pressing on the title row begins a move-by-
        drag; subsequent motion repositions the dialog and release
        ends the drag."""
        if not self.active:
            return False
        if event.kind != EVENT_MOUSE:
            return True
        var rect = _dialog_rect(screen, self.pos)
        # --- title-bar drag: start / continue / end ---------------
        # Resolved before any other mouse handling so a click that
        # *starts* on the title row never also triggers list / button
        # behaviour even if the cursor crosses into them mid-drag.
        if self._drag:
            if event.button == MOUSE_BUTTON_LEFT and event.pressed \
                    and event.motion:
                var off = self._drag.value()
                self.pos = Optional[Point](Point(
                    event.pos.x - off.x, event.pos.y - off.y,
                ))
                return True
            if not event.pressed:
                # Release ends the drag regardless of position.
                self._drag = Optional[Point]()
                return True
            # In-progress drag swallows everything else.
            return True
        # Close button [■] dismisses the dialog. Checked before the
        # title-bar drag-start below so a click on the close glyph
        # doesn't also begin a move.
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
        var list_rect = _list_rect(rect)
        # Jump-button strip is checked first — the listing area is
        # one row above it, so a click landing on the buttons would
        # otherwise fall through ``handle_list_mouse`` as
        # out-of-list and be silently swallowed.
        if self.browser.handle_jump_click(event, _buttons_rect(rect)):
            return True
        var idx = self.browser.handle_list_mouse(event, list_rect)
        if idx == -2:
            return True   # wheel handled
        if idx < 0:
            # Outside the list (or wrong button) — swallow regardless,
            # since the dialog is modal and shouldn't leak clicks.
            _ = rect       # silence unused warning if compiler reports it
            return True
        # ``..`` activates on a single click — matches the "parent
        # shortcut" expectation.
        if self.browser.entries[idx] == String(".."):
            self.browser.ascend()
            return True
        if idx == self.browser.selected:
            # Second click on the same entry: act like Enter.
            var name = self.browser.entries[idx]
            if self.browser.entry_is_dir[idx]:
                self.browser.descend(name)
            else:
                self.selected_path = join_path(self.browser.dir, name)
                self.submitted = True
            return True
        self.browser.set_selection(idx, list_rect.height())
        return True
