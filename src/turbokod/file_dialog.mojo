"""Modal file-open dialog: directory listing with arrow-key navigation.

Open with ``open(start_dir)``. The user navigates with Up/Down arrows, opens a
directory by pressing Enter on it (the listing refreshes), and selects a file
by pressing Enter on it. Backspace ascends to the parent directory; Esc
cancels. On submit, ``submitted=True`` and ``selected_path`` holds the absolute
(or as-supplied) path; the caller calls ``close()`` to dismiss.

Open with ``open_directory(start_dir, ...)`` instead to enter directory-pick
mode: the listing filters to directories only, the title says "Open Project"
(or whatever ``title`` was passed), and a right-aligned " Open Project "
button submits the *current* directory (``browser.dir``) as the selection.
Enter still descends / ascends; the explicit button is the only path to
submit, since every entry in dirs-only mode is itself navigable.

The directory-listing state and rendering live on ``DirBrowser`` (shared
with ``SaveAsDialog``); this file owns the modal lifecycle, the dialog
chrome, and the open-only key/mouse semantics.
"""

from std.collections.optional import Optional

from .buttons import (
    BUTTON_FIRED, BUTTON_NONE,
    ShadowButton, paint_shadow_button,
)
from .canvas import Canvas, paint_drop_shadow
from .painter import Painter
from .colors import Attr, BLACK, BLUE, GREEN, LIGHT_GRAY, WHITE
from .dir_browser import DirBrowser
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_BACKSPACE, KEY_DOWN, KEY_ENTER, KEY_ESC, KEY_UP, KEY_PAGEDOWN, KEY_PAGEUP,
    MOUSE_BUTTON_LEFT,
)
from .file_io import join_path
from .geometry import Point, Rect, compute_dialog_rect
from .view import RowCursor
from .window import (
    hit_close_button, paint_close_button, paint_window_title,
)


comptime _DIALOG_W = 60
comptime _DIALOG_H = 18
comptime _LIST_HEIGHT = _DIALOG_H - 7
"""Visible rows in the directory listing. The -7 budget covers:
1 top border + 1 current-dir + 1 gap above list + 1 gap below list +
1 button face + 1 button shadow + 1 hint/bottom-border."""


fn _dialog_rect(screen: Rect, pos: Optional[Point]) -> Rect:
    return compute_dialog_rect(screen, pos, _DIALOG_W, _DIALOG_H)


@fieldwise_init
struct _Layout(ImplicitlyCopyable, Movable):
    """Pre-computed rects + row anchors for the file dialog.

    Top section (current-dir line) flows through ``RowCursor``; the
    list + bottom button strip + hint are anchored to the bottom so
    the listing grows with the dialog. Shared by ``paint`` and
    ``handle_mouse`` so geometry doesn't drift.
    """
    var current_dir_y: Int
    var list_rect: Rect
    var buttons_rect: Rect
    var hint_y: Int


fn _build_layout(rect: Rect) -> _Layout:
    var cursor = RowCursor(rect.a.y + 1)
    var current_dir_y = cursor.place()
    var list_y = cursor.place()
    var buttons_y = rect.b.y - 3
    return _Layout(
        current_dir_y,
        Rect(rect.a.x + 2, list_y, rect.b.x - 1, rect.b.y - 4),
        Rect(rect.a.x + 2, buttons_y, rect.b.x - 1, buttons_y + 2),
        rect.b.y - 1,
    )


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
    var dirs_only: Bool
    """Directory-pick mode. When True the listing is filtered to
    directories (so the user can browse without files cluttering
    the picker) and the dialog grows a right-aligned button that
    submits ``browser.dir`` rather than a clicked entry. Set by
    ``open_directory``; ``open`` always resets it to False."""
    var title: String
    """Text painted into the top-edge title chunk. Defaults to
    ``" Open File "``; ``open_directory`` overrides it (typically
    ``" Open Project "``) so the same dialog reads correctly in
    either mode."""
    var _open_button: ShadowButton
    """Persistent " Open <X> " button for dirs-only mode. Press
    latch lives here so the button can't lose its captured state
    between paints. Repositioned to the right edge of the buttons
    row on every paint."""

    fn __init__(out self):
        self.active = False
        self.submitted = False
        self.selected_path = String("")
        self.browser = DirBrowser(False)
        self.pos = Optional[Point]()
        self._drag = Optional[Point]()
        self.dirs_only = False
        self.title = String(" Open File ")
        self._open_button = ShadowButton(String(" Open Project "), 0, 0)

    fn open(mut self, var start_dir: String):
        self.active = True
        self.submitted = False
        self.selected_path = String("")
        self.dirs_only = False
        self.title = String(" Open File ")
        self.browser = DirBrowser(False)
        self.browser.open(start_dir^)
        self.pos = Optional[Point]()
        self._drag = Optional[Point]()

    fn open_directory(
        mut self,
        var start_dir: String,
        var title: String = String(" Open Project "),
        var button_label: String = String(" Open Project "),
    ):
        """Open the dialog in directory-pick mode.

        Listing is filtered to directories only; the right-aligned
        button submits ``browser.dir`` as the selection (rather
        than a clicked entry). ``title`` paints into the top-edge
        title chunk; ``button_label`` is the submit button's text
        (host can override both for non-project picks).
        """
        self.active = True
        self.submitted = False
        self.selected_path = String("")
        self.dirs_only = True
        self.title = title^
        self.browser = DirBrowser(True)
        self.browser.open(start_dir^)
        self.pos = Optional[Point]()
        self._drag = Optional[Point]()
        self._open_button = ShadowButton(button_label^, 0, 0)

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
        self.dirs_only = False
        self.title = String(" Open File ")
        self.browser = DirBrowser(False)
        self.pos = Optional[Point]()
        self._drag = Optional[Point]()
        self._open_button = ShadowButton(String(" Open Project "), 0, 0)

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
        var dir_attr = Attr(BLUE, LIGHT_GRAY)
        var rect = _dialog_rect(screen, self.pos)
        var layout = _build_layout(rect)
        # Drop shadow first — it darkens cells *outside* ``rect`` so
        # whatever workspace content sits behind the dialog reads as
        # dim-on-black underneath the right and bottom edges.
        paint_drop_shadow(canvas, rect)
        var painter = Painter(rect)
        painter.fill(canvas, rect, String(" "), bg)
        painter.draw_box(canvas, rect, border, True)
        paint_window_title(canvas, rect, self.title, bg, bg)
        # TV-style close button in the top-left corner. Same chrome as
        # editor windows — the framework helper paints all three cells.
        paint_close_button(canvas, Point(rect.a.x, rect.a.y), border)
        _ = painter.put_text(
            canvas, Point(rect.a.x + 2, layout.current_dir_y),
            self.browser.dir, dir_attr,
        )
        self.browser.paint(canvas, layout.list_rect, True)
        # Desktop / Home / Root quick-jump strip just above the hint
        # — green TV-style buttons with shadows; colours are owned
        # by ``paint_jump_buttons`` so all dialogs stay consistent.
        self.browser.paint_jump_buttons(canvas, layout.buttons_rect)
        # Directory-pick mode adds a right-aligned " Open <X> " button
        # in the same row. The jump buttons leave the right edge
        # untouched, so the submit button sits there without colliding.
        if self.dirs_only:
            var face = Attr(BLACK, GREEN)
            var bw = self._open_button.face_width()
            var bx = layout.buttons_rect.b.x - bw - 1
            self._open_button.move_to(bx, layout.buttons_rect.a.y)
            paint_shadow_button(
                canvas, self._open_button, face, LIGHT_GRAY,
                layout.buttons_rect.b.x,
            )
        var hint = (
            String(" Enter: enter dir  ⌫: parent  ESC: cancel ")
            if self.dirs_only
            else String(" Enter: open  ⌫: parent  ESC: cancel ")
        )
        _ = painter.put_text(
            canvas, Point(rect.a.x + 2, layout.hint_y), hint, dir_attr,
        )

    # --- events ------------------------------------------------------------

    fn handle_key(mut self, event: Event) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_KEY:
            return True
        var k = event.key
        var list_h = _LIST_HEIGHT
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
        var layout = _build_layout(rect)
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
        # Directory-pick mode's submit button shares the buttons row.
        # Route the event through it before the jump-button strip so a
        # click on the right-aligned " Open Project " face doesn't get
        # swallowed by the row's outer hit logic.
        if self.dirs_only:
            var bw = self._open_button.face_width()
            self._open_button.move_to(
                layout.buttons_rect.b.x - bw - 1, layout.buttons_rect.a.y,
            )
            var status = self._open_button.handle_mouse(event)
            if status == BUTTON_FIRED:
                self.selected_path = self.browser.dir
                self.submitted = True
                return True
            if status != BUTTON_NONE:
                return True
        # Jump-button strip is checked next — the listing area is
        # one row above it, so a click landing on the buttons would
        # otherwise fall through ``handle_list_mouse`` as
        # out-of-list and be silently swallowed.
        if self.browser.handle_jump_click(event, layout.buttons_rect):
            return True
        var idx = self.browser.handle_list_mouse(event, layout.list_rect)
        if idx == -2:
            return True   # wheel handled
        if idx < 0:
            # Outside the list (or wrong button) — swallow regardless,
            # since the dialog is modal and shouldn't leak clicks.
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
        self.browser.set_selection(idx, layout.list_rect.height())
        return True
