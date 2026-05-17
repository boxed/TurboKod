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

from .buttons import (
    BUTTON_FIRED, BUTTON_NONE,
    ShadowButton, paint_shadow_button,
)
from .canvas import Canvas, paint_drop_shadow
from .painter import Painter
from .cell import Cell
from .colors import Attr, BLACK, BLUE, GREEN, LIGHT_GRAY, WHITE
from .dir_browser import DirBrowser
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_BACKSPACE, KEY_DOWN, KEY_ENTER, KEY_ESC, KEY_TAB, KEY_UP,
    KEY_PAGEDOWN, KEY_PAGEUP,
    MOUSE_BUTTON_LEFT,
)
from .file_io import basename, join_path, parent_path
from .geometry import Point, Rect, compute_dialog_rect
from .text_field import TextField
from .view import RowCursor
from .window import (
    hit_close_button, paint_close_button, paint_window_title,
)


comptime _DIALOG_W = 60
comptime _DIALOG_H = 20
comptime _LIST_HEIGHT = _DIALOG_H - 9
"""Visible rows in the directory listing. The -9 budget covers:
1 top border + 1 padding + 1 input + 1 padding + 1 current-dir +
1 trailing gap + 1 buttons face + 1 buttons shadow + 1 hint/bottom."""

# Focus modes — kept as small ints since Mojo enums aren't widely used in
# this codebase yet.
comptime _FOCUS_INPUT   = UInt8(0)
comptime _FOCUS_LISTING = UInt8(1)


def _dialog_rect(screen: Rect, pos: Optional[Point]) -> Rect:
    return compute_dialog_rect(screen, pos, _DIALOG_W, _DIALOG_H)


comptime _SAVE_BUTTON_LABEL = String(" Save ")
comptime _SAVE_BUTTON_FACE_W = 6
"""Width of ``_SAVE_BUTTON_LABEL`` in cells. Hard-coded so
``_build_layout`` can size the input strip at compile time without
spinning up a temporary ``ShadowButton`` to ask its ``face_width``."""


@fieldwise_init
struct _Layout(ImplicitlyCopyable, Movable):
    """Pre-computed rects + row anchors for the save-as dialog.

    The top section (``File:`` label + input + current-dir line) is
    laid out through ``RowCursor`` so each pair of distinct controls
    is separated by a blank row. The listing + bottom button strip
    + hint line are anchored to the bottom so the listing grows
    with the dialog.
    """
    var label_pt: Point
    var input_rect: Rect
    var save_button_pt: Point
    """Top-left of the ``Save`` button, anchored to the right edge
    of the input row. Shadow extends one column right and one row
    down — the down row is the blank gap before ``current_dir_y``,
    so the shadow doesn't collide with anything."""
    var current_dir_y: Int
    var list_rect: Rect
    var buttons_rect: Rect
    var hint_y: Int


def _build_layout(rect: Rect) -> _Layout:
    var cursor = RowCursor(rect.a.y + 2)
    var input_y = cursor.place()
    var current_dir_y = cursor.place()
    var left = rect.a.x + 2
    var right = rect.b.x - 1
    var buttons_y = rect.b.y - 3
    # Save button sits on the input row, right-aligned to ``right``
    # with one column of breathing room before the right border —
    # matches how ``FileDialog`` places its " Open Project " button.
    var save_x = right - _SAVE_BUTTON_FACE_W - 1
    # Input strip stops one column before the Save button so the
    # field's right edge has visible separation from the green face.
    var input_right = save_x - 1
    return _Layout(
        Point(left, input_y),
        # Input strip starts after the 5-char "File:" label plus one
        # column of breathing room.
        Rect(rect.a.x + 8, input_y, input_right, input_y + 1),
        Point(save_x, input_y),
        current_dir_y,
        # List sits one row below the current-dir line (it's the
        # content of that header — no gap).
        Rect(left, current_dir_y + 1, right, rect.b.y - 4),
        Rect(left, buttons_y, right, buttons_y + 2),
        rect.b.y - 1,
    )


struct SaveAsDialog(Movable):
    var active: Bool
    var submitted: Bool
    var filename: TextField       # editable input text + cursor
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
    var _save_button: ShadowButton
    """Persistent " Save " button on the input row. Press-latch state
    lives here so the button can't drop a captured press between
    paints — repositioned each paint via ``move_to``."""

    def __init__(out self):
        self.active = False
        self.submitted = False
        self.filename = TextField()
        self.selected_path = String("")
        self.focus = _FOCUS_INPUT
        self.browser = DirBrowser(True)
        self.pos = Optional[Point]()
        self._drag = Optional[Point]()
        self._save_button = ShadowButton(_SAVE_BUTTON_LABEL, 0, 0)

    def open(mut self, var start_path: String):
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
        self.filename = TextField()
        self.filename.set_text(name^)
        self.selected_path = String("")
        self.focus = _FOCUS_INPUT
        self.browser.open(dir^)
        self.pos = Optional[Point]()
        self._drag = Optional[Point]()
        self._save_button = ShadowButton(_SAVE_BUTTON_LABEL, 0, 0)

    def set_project(mut self, project: Optional[String]):
        """Tell the dialog about the active project so the listing's
        jump-button row gets a ``Project`` entry pointing to its
        root. Pass ``Optional[String]()`` to clear it. The host calls
        this after ``open`` to reflect whatever project the editor
        currently owns."""
        self.browser.set_project(project)

    def close(mut self):
        self.active = False
        self.submitted = False
        self.filename = TextField()
        self.selected_path = String("")
        self.focus = _FOCUS_INPUT
        self.browser = DirBrowser(True)
        self.pos = Optional[Point]()
        self._drag = Optional[Point]()
        self._save_button = ShadowButton(_SAVE_BUTTON_LABEL, 0, 0)

    # --- painting ----------------------------------------------------------

    def paint(mut self, mut canvas: Canvas, screen: Rect):
        if not self.active:
            return
        # Same Turbo Vision palette as ``FileDialog``: light-gray
        # body, bright double-line frame, and a title chunk painted
        # in body colors over the top edge.
        var bg = Attr(BLACK, LIGHT_GRAY)
        var border = Attr(WHITE, LIGHT_GRAY)
        var dir_attr = Attr(BLUE, LIGHT_GRAY)
        var rect = _dialog_rect(screen, self.pos)
        var layout = _build_layout(rect)
        # Drop shadow first — see ``FileDialog.paint`` for the rationale.
        paint_drop_shadow(canvas, rect)
        var painter = Painter(rect)
        painter.fill(canvas, rect, String(" "), bg)
        painter.draw_box(canvas, rect, border, True)
        paint_window_title(canvas, rect, String(" Save As "), bg, bg)
        # Close button shares the same chrome as editor windows.
        paint_close_button(canvas, Point(rect.a.x, rect.a.y), border)
        # Filename label + editable strip.
        _ = painter.put_text(canvas, layout.label_pt, String("File:"), bg)
        self.filename.paint(
            canvas, layout.input_rect, self.focus == _FOCUS_INPUT,
        )
        # Save button right of the input. Same green chrome as the
        # listing's jump buttons so the dialog reads as a coherent
        # button family. ``max_x`` is the dialog's right border so a
        # narrow dialog can't spill the shadow past the frame.
        var save_face = Attr(BLACK, GREEN)
        self._save_button.move_to(
            layout.save_button_pt.x, layout.save_button_pt.y,
        )
        paint_shadow_button(
            canvas, self._save_button, save_face, LIGHT_GRAY, rect.b.x - 1,
        )
        # Current-directory line above the listing.
        _ = painter.put_text(
            canvas, Point(rect.a.x + 2, layout.current_dir_y),
            self.browser.dir, dir_attr,
        )
        # Listing.
        self.browser.paint(
            canvas, layout.list_rect, self.focus == _FOCUS_LISTING,
        )
        # Desktop / Home / Root quick-jump strip just above the hint.
        self.browser.paint_jump_buttons(canvas, layout.buttons_rect)
        # Hint at the bottom — varies with focus to nudge the user toward
        # the right key for the thing they're trying to do.
        var hint: String
        if self.focus == _FOCUS_INPUT:
            hint = String(" Enter: save  Tab: pick folder  ESC: cancel ")
        else:
            hint = String(" Enter: open  ⌫: parent  Tab: edit name  ESC: cancel ")
        _ = painter.put_text(
            canvas, Point(rect.a.x + 2, layout.hint_y), hint, dir_attr,
        )

    # --- key handling -----------------------------------------------------

    def handle_key(mut self, event: Event) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_KEY:
            return True
        var k = event.key
        var list_h = _LIST_HEIGHT
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
        if self.focus == _FOCUS_INPUT:
            # Field gets full cursor / clipboard / selection handling.
            var r = self.filename.handle_key(event)
            if r.consumed:
                return True
        # Backspace on the listing ascends to the parent directory.
        if k == KEY_BACKSPACE and self.focus == _FOCUS_LISTING:
            self.browser.ascend()
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
        return True

    def _submit(mut self):
        """Stamp ``selected_path`` and flip the submit flag — but only
        when the filename input has at least one character. An empty
        filename would happily ``join_path`` to a trailing-slash path
        and likely fail the write later; refusing the submit up front
        is friendlier than producing an obviously-broken target.
        """
        if len(self.filename.text.as_bytes()) == 0:
            self.focus = _FOCUS_INPUT
            return
        self.selected_path = join_path(self.browser.dir, self.filename.text)
        self.submitted = True

    # --- mouse ------------------------------------------------------------

    def is_input_at(self, pos: Point, screen: Rect) -> Bool:
        """True iff ``pos`` lies on the editable filename row. Used by
        the host to hint a text-cursor shape over the input but a
        default arrow over the listing and buttons."""
        if not self.active:
            return False
        return _build_layout(
            _dialog_rect(screen, self.pos),
        ).input_rect.contains(pos)

    def handle_mouse(mut self, event: Event, screen: Rect) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_MOUSE:
            return True
        var rect = _dialog_rect(screen, self.pos)
        var layout = _build_layout(rect)
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
        # Save button — same press/drag/release state machine as the
        # jump buttons. Routed before the input-strip click handler
        # so a press landing on the green face captures cleanly
        # instead of leaking into a (non-overlapping) field handler.
        # ``handle_mouse`` returns ``BUTTON_NONE`` for events outside
        # the hit rect when no capture is held, so the fall-through
        # path stays intact.
        self._save_button.move_to(
            layout.save_button_pt.x, layout.save_button_pt.y,
        )
        var save_status = self._save_button.handle_mouse(event)
        if save_status == BUTTON_FIRED:
            self._submit()
            return True
        if save_status != BUTTON_NONE:
            return True
        # Click in the filename strip steals focus and routes the
        # event to the field so the cursor lands at the click point
        # (with drag-extend selection if the user keeps holding).
        if event.button == MOUSE_BUTTON_LEFT \
                and layout.input_rect.contains(event.pos):
            if event.pressed and not event.motion:
                self.focus = _FOCUS_INPUT
            if self.focus == _FOCUS_INPUT \
                    and self.filename.handle_mouse(event, layout.input_rect):
                return True
        # Quick-jump strip lives between the listing and the hint —
        # check it before the listing's mouse handler so the jump
        # buttons' row doesn't get swallowed as out-of-list.
        if self.browser.handle_jump_click(event, layout.buttons_rect):
            self.focus = _FOCUS_LISTING
            return True
        var idx = self.browser.handle_list_mouse(event, layout.list_rect)
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
        self.browser.set_selection(idx, layout.list_rect.height())
        return True
