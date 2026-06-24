"""Popup that opens when the user clicks the per-line bar in the
git-changes gutter, or jumps to a change chunk with Ctrl+Shift+Up/Down.

It does two things at once:

* paints the block's **old code** (the lines at HEAD) directly above the
  changed lines, column-aligned with them, so the user can eyeball the
  before/after without leaving the editor; and
* offers a **Revert this chunk** action (Enter, Cmd+Alt+Z, or click) that
  restores the block to HEAD.

While open it also forwards Ctrl+Shift+Up/Down back to the host as
``GUTTER_ACTION_PREV`` / ``GUTTER_ACTION_NEXT`` so the user can walk
through every change chunk, re-anchoring the preview at each one.

The host (Desktop) owns opening it from ``Editor.consume_git_revert_request``
and routing keyboard / mouse events to it before any other widget.
"""

from std.collections.list import List

from .canvas import Canvas, paint_drop_shadow
from .painter import Painter
from .cell import Cell
from .colors import (
    Attr, BLACK, GREEN, LIGHT_GRAY, RED, WHITE,
)
from .events import (
    Event, EVENT_KEY,
    KEY_DOWN, KEY_ENTER, KEY_ESC, KEY_UP,
    MENU_HIT_NONE,
    MOD_ALT, MOD_CTRL, MOD_META, MOD_SHIFT,
)
from .geometry import Point, Rect
from .git_changes import GitRevertRequest
from .string_utils import display_columns
from .anchored_menu import anchored_menu_mouse


# Action codes returned to the host on resolve.
comptime GUTTER_ACTION_NONE   = 0
comptime GUTTER_ACTION_REVERT = 1
comptime GUTTER_ACTION_PREV   = 2
comptime GUTTER_ACTION_NEXT   = 3


comptime _LABEL_REVERT = String("Revert this chunk")


@fieldwise_init
struct _GutterLayout(Copyable, Movable):
    """Resolved on-screen placement of the popup, shared by paint and
    hit-testing. ``rect`` is the whole popup (header + old-code rows);
    ``header_row`` is the screen row of the actionable Revert bar;
    ``old_start`` is the screen row of the first old-code line."""
    var rect: Rect
    var header_row: Int
    var old_start: Int


struct GitGutterMenu(Movable):
    """Modal popup anchored to a git-change block — shows the old code and
    a Revert action."""

    var active: Bool
    var submitted: Bool
    var action: Int
    var row: Int
    """Buffer row the request targets. Forwarded back to the host so it
    recomputes the revert block at submission time (the buffer can't shift
    while the modal is up, but recomputing keeps the cached baseline the
    single source of truth)."""

    var anchor_x: Int
    var anchor_y: Int
    var text_x: Int
    var block_top_y: Int
    var new_count: Int
    var head_lines: List[String]
    var is_deletion: Bool
    """Mirrors ``GitRevertRequest.is_deletion`` — True when the popup was
    opened from a ``_`` deletion marker. The host's submit handler reads it
    to pick ``compute_deletion_revert_block`` over ``compute_revert_block``."""
    var selected: Int
    var tracking: Bool
    """True between a captured left-press on the Revert bar and its matching
    release — the action only fires on release, like a button."""

    def __init__(out self):
        self.active = False
        self.submitted = False
        self.action = GUTTER_ACTION_NONE
        self.row = -1
        self.anchor_x = 0
        self.anchor_y = 0
        self.text_x = 0
        self.block_top_y = -1
        self.new_count = 1
        self.head_lines = List[String]()
        self.is_deletion = False
        self.selected = 0
        self.tracking = False

    def open(mut self, req: GitRevertRequest):
        self.row = req.row
        self.anchor_x = req.anchor_x
        self.anchor_y = req.anchor_y
        self.text_x = req.text_x
        self.block_top_y = req.block_top_y
        self.new_count = req.new_count if req.new_count > 0 else 1
        self.head_lines = req.head_lines.copy()
        self.is_deletion = req.is_deletion
        self.active = True
        self.submitted = False
        self.action = GUTTER_ACTION_NONE
        self.selected = 0
        self.tracking = False

    def close(mut self):
        self.active = False
        self.submitted = False
        self.action = GUTTER_ACTION_NONE
        self.row = -1
        self.head_lines = List[String]()
        self.is_deletion = False
        self.tracking = False

    def _resolve(mut self, action: Int):
        self.action = action
        self.submitted = True

    def _body_width(self) -> Int:
        """Display columns of the widest thing the popup must fit — the
        Revert label or any old-code line."""
        var w = display_columns(_LABEL_REVERT)
        for i in range(len(self.head_lines)):
            var lw = display_columns(self.head_lines[i])
            if lw > w:
                w = lw
        return w

    def _layout(self, container: Rect) -> _GutterLayout:
        """Place the popup. Preferred: old code stacked directly *below* the
        changed block (first old line on the row just under the last changed
        line, header at the bottom) so columns line up with the new code
        above — and the drop shadow falls on the code below, never over the
        chunk itself. Flips *above* the block when there isn't room below;
        falls back to the click anchor when the block isn't on screen."""
        var n = len(self.head_lines)
        var rows_total = n + 1   # old-code lines + header
        # Left edge sits one column left of the text so a ``-`` marker can
        # share the gutter column while the code itself stays at ``text_x``,
        # exactly under the new code.
        var left = self.text_x - 1
        if left < container.a.x:
            left = container.a.x
        var width = self._body_width() + 2   # marker column + 1 trailing pad
        var right = left + width
        if right > container.b.x:
            right = container.b.x

        var header_row: Int
        var old_start: Int
        var top: Int
        if self.block_top_y >= 0:
            var top_below = self.block_top_y + self.new_count
            if top_below + rows_total <= container.b.y:
                # Below: [old…][header], first old line abuts the change.
                top = top_below
                old_start = top
                header_row = top + n
            else:
                # Above: [header][old…], last old line abuts the change.
                top = self.block_top_y - rows_total
                if top < container.a.y:
                    top = container.a.y
                header_row = top
                old_start = top + 1
        else:
            top = self.anchor_y + 1
            old_start = top
            header_row = top + n
            if top + rows_total > container.b.y:
                top = container.b.y - rows_total
                if top < container.a.y:
                    top = container.a.y
                old_start = top
                header_row = top + n
        return _GutterLayout(
            Rect(left, top, right, top + rows_total), header_row, old_start,
        )

    def paint(self, mut canvas: Canvas, container: Rect):
        if not self.active:
            return
        var lay = self._layout(container)
        var rect = lay.rect
        paint_drop_shadow(canvas, rect)
        var painter = Painter(rect)
        # Old code reads as "removed": white-on-red, with a ``-`` marker in
        # the gutter column, matching the diff convention used elsewhere.
        var rem_attr = Attr(WHITE, RED)
        var n = len(self.head_lines)
        for i in range(n):
            var ry = lay.old_start + i
            painter.fill(
                canvas, Rect(rect.a.x, ry, rect.b.x, ry + 1),
                String(" "), rem_attr,
            )
            painter.set(canvas, rect.a.x, ry, Cell(String("-"), rem_attr, 1))
            _ = painter.put_text(
                canvas, Point(self.text_x, ry), self.head_lines[i], rem_attr,
            )
        # Header / Revert bar — a green button so it reads as the action.
        var hdr_attr = Attr(BLACK, GREEN)
        painter.fill(
            canvas, Rect(rect.a.x, lay.header_row, rect.b.x, lay.header_row + 1),
            String(" "), hdr_attr,
        )
        _ = painter.put_text(
            canvas, Point(self.text_x, lay.header_row), _LABEL_REVERT, hdr_attr,
        )

    def handle_key(mut self, event: Event) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_KEY:
            return True
        var k = event.key
        var m = event.mods
        if k == KEY_ESC:
            self._resolve(GUTTER_ACTION_NONE)
            return True
        # Ctrl+Shift+Up/Down walks to the previous / next chunk — the host
        # re-navigates the editor and re-opens the popup there.
        if (m & MOD_CTRL) != 0 and (m & MOD_SHIFT) != 0 \
                and (m & MOD_ALT) == 0 and (m & MOD_META) == 0:
            if k == KEY_UP:
                self._resolve(GUTTER_ACTION_PREV)
                return True
            if k == KEY_DOWN:
                self._resolve(GUTTER_ACTION_NEXT)
                return True
        # Cmd+Alt+Z is the same revert the action bar performs.
        if (m & MOD_META) != 0 and (m & MOD_ALT) != 0 \
                and k == UInt32(ord("z")):
            self._resolve(GUTTER_ACTION_REVERT)
            return True
        if k == KEY_ENTER:
            self._resolve(GUTTER_ACTION_REVERT)
            return True
        # Modal — swallow everything else so it doesn't reach the editor.
        return True

    def handle_mouse(mut self, event: Event, container: Rect) -> Int:
        """Button-like press / release on the Revert bar (see
        ``anchored_menu_mouse``): press inside arms tracking, release on the
        bar fires the revert. Clicks elsewhere (including the old-code rows)
        are swallowed; a press/release outside dismisses."""
        if not self.active:
            return MENU_HIT_NONE
        var lay = self._layout(container)
        var r = anchored_menu_mouse(
            event, lay.rect, lay.header_row, 1,
            self.selected, self.tracking,
        )
        if r.cancel:
            self._resolve(GUTTER_ACTION_NONE)
        elif r.fired_row == 0:
            self._resolve(GUTTER_ACTION_REVERT)
        return r.hit
