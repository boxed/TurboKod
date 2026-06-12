"""Mouse-drag text selection for the byte-per-cell Find panels.

The Find-in-Project context panel (``project_find``) and the docked Find
Results pane (``find_results_pane``) paint their text one screen cell per
byte (ASCII-degrading: a non-ASCII byte renders as ``?``). That makes byte
offsets line up exactly with screen columns, so a selection can be tracked
in plain ``(key, byte)`` pairs without any codepoint/width math — unlike
``TextLog`` (text_view.mojo), which soft-wraps and so needs the full
``VisualLine`` machinery.

``PaneTextSelect`` owns the selection + drag-gesture state. Each frame the
panel calls ``begin_frame`` then ``add_row`` for every painted, selectable
row (stamping its on-screen geometry); afterwards it calls ``paint_overlay``
to recolor the selected cells and routes mouse events through
``handle_mouse``. ``text()`` returns the selected substring for Cmd+C.

``key`` is the row's stable identity — the source-line index for the
context panel, the match index for the results pane — so the selection
survives scrolling and re-paints. Both panels keep their visible rows
contiguous in ``key`` order, so ``text()`` can stitch a multi-row span from
the stamped rows alone (no separate backing-line list needed).
"""

from std.collections.list import List

from .canvas import Canvas
from .clipboard import clipboard_copy
from .colors import Attr
from .events import Event, EVENT_MOUSE, MOUSE_BUTTON_LEFT
from .geometry import Point, Rect
from .painter import Painter
from .string_utils import byte_slice


@fieldwise_init
struct PaneRow(ImplicitlyCopyable, Movable):
    """On-screen geometry of one painted, selectable text row.

    Byte==cell model: byte ``b`` of ``text`` (for ``b >= byte_start``) was
    painted at screen column ``text_x + (b - byte_start)``.
    """
    var key: Int          # stable row identity (source-line / match index)
    var text: String      # full underlying string (what Cmd+C copies)
    var y: Int            # screen row the text was painted on
    var text_x: Int       # screen x of byte ``byte_start``
    var byte_start: Int   # first painted byte (left-slide offset; 0 if none)
    var byte_end: Int     # one past the last painted byte (right clip)
    var clip_x: Int       # exclusive right edge for the overlay


struct PaneTextSelect(Movable):
    var active: Bool
    """True once a drag has actually moved off its anchor — i.e. there is a
    non-empty span to copy. A bare press leaves this False."""
    var dragging: Bool
    var moved: Bool
    """Motion seen since the press; lets the panel tell a click (select /
    open a row) from a drag (select text) on release."""
    var anchor_key: Int
    var anchor_byte: Int
    var cursor_key: Int
    var cursor_byte: Int
    var _rows: List[PaneRow]

    def __init__(out self):
        self.active = False
        self.dragging = False
        self.moved = False
        self.anchor_key = 0
        self.anchor_byte = 0
        self.cursor_key = 0
        self.cursor_byte = 0
        self._rows = List[PaneRow]()

    # --- per-frame layout -------------------------------------------------

    def begin_frame(mut self):
        """Drop last frame's row geometry; ``add_row`` repopulates it."""
        self._rows = List[PaneRow]()

    def add_row(
        mut self, key: Int, text: String, y: Int, text_x: Int,
        byte_start: Int, byte_end: Int, clip_x: Int,
    ):
        self._rows.append(
            PaneRow(key, text, y, text_x, byte_start, byte_end, clip_x)
        )

    def clear(mut self):
        """Forget any selection / in-flight drag — called when the content
        changes out from under the selection (new search, context reload)."""
        self.active = False
        self.dragging = False
        self.moved = False

    # --- query ------------------------------------------------------------

    def has_selection(self) -> Bool:
        if not self.active:
            return False
        return not (
            self.anchor_key == self.cursor_key
            and self.anchor_byte == self.cursor_byte
        )

    def _normalized(self) -> Tuple[Int, Int, Int, Int]:
        """``(s_key, s_byte, e_key, e_byte)`` sorted in document order."""
        if self.anchor_key < self.cursor_key \
                or (self.anchor_key == self.cursor_key
                    and self.anchor_byte <= self.cursor_byte):
            return (
                self.anchor_key, self.anchor_byte,
                self.cursor_key, self.cursor_byte,
            )
        return (
            self.cursor_key, self.cursor_byte,
            self.anchor_key, self.anchor_byte,
        )

    def text(self) -> String:
        """The selected substring, joining row boundaries with ``\\n``.
        Stitched from the stamped rows between the two endpoints."""
        if not self.has_selection():
            return String("")
        var r = self._normalized()
        var s_key = r[0]; var s_byte = r[1]
        var e_key = r[2]; var e_byte = r[3]
        var out = String("")
        var first = True
        for i in range(len(self._rows)):
            var row = self._rows[i]
            if row.key < s_key or row.key > e_key:
                continue
            var lo = 0
            var hi = len(row.text.as_bytes())
            if row.key == s_key and s_byte > lo:
                lo = s_byte
            if row.key == e_key and e_byte < hi:
                hi = e_byte
            if lo < 0:
                lo = 0
            if not first:
                out += String("\n")
            first = False
            if hi > lo:
                out += byte_slice(row.text, lo, hi)
        return out^

    def copy(self) -> Bool:
        """Push the selection to the clipboard; False when empty."""
        var t = self.text()
        if len(t.as_bytes()) == 0:
            return False
        clipboard_copy(t)
        return True

    # --- hit-test ---------------------------------------------------------

    def _row_at_y(self, y: Int) -> Int:
        """Index into ``_rows`` of the painted row at screen ``y`` (rows are
        in ascending-y order). Clamps to the nearest row; -1 when empty."""
        if len(self._rows) == 0:
            return -1
        var best = 0
        for i in range(len(self._rows)):
            if self._rows[i].y <= y:
                best = i
        return best

    def position_at(self, pos: Point) -> Tuple[Int, Int]:
        """Map a screen point to ``(key, byte)``."""
        var ri = self._row_at_y(pos.y)
        if ri < 0:
            return (0, 0)
        var row = self._rows[ri]
        var b = row.byte_start + (pos.x - row.text_x)
        if b < row.byte_start:
            b = row.byte_start
        if b > row.byte_end:
            b = row.byte_end
        return (row.key, b)

    # --- input ------------------------------------------------------------

    def handle_mouse(mut self, event: Event) -> Bool:
        """Drive a drag selection. Returns True when the event is part of an
        *active drag* (motion after a press, or a release that ended a real
        drag) so the caller can suppress its own click handling. A bare
        press returns False so the caller still treats it as a click
        candidate (row select / open)."""
        if event.kind != EVENT_MOUSE:
            return False
        if event.button == MOUSE_BUTTON_LEFT and not event.pressed:
            var was_drag = self.dragging and self.moved
            self.dragging = False
            return was_drag
        if event.button != MOUSE_BUTTON_LEFT or not event.pressed:
            return False
        if event.motion:
            if not self.dragging:
                return False
            self._extend(event.pos)
            return self.moved
        # Fresh press: arm a potential drag and clear any prior selection.
        # ``active`` stays False until motion fires — a plain click without
        # a drag clears the selection rather than leaving a zero-width one.
        var p = self.position_at(event.pos)
        self.active = False
        self.dragging = True
        self.moved = False
        self.anchor_key = p[0]
        self.anchor_byte = p[1]
        self.cursor_key = p[0]
        self.cursor_byte = p[1]
        return False

    def _extend(mut self, pos: Point):
        var p = self.position_at(pos)
        self.cursor_key = p[0]
        self.cursor_byte = p[1]
        if self.cursor_key != self.anchor_key \
                or self.cursor_byte != self.anchor_byte:
            self.active = True
            self.moved = True

    # --- paint ------------------------------------------------------------

    def paint_overlay(self, mut canvas: Canvas, view: Rect, sel_attr: Attr):
        """Recolor every selected cell across the stamped rows. Attr-only
        (``set_attr``), so the painted glyphs are preserved. Call after the
        panel has drawn its content."""
        if not self.has_selection():
            return
        var r = self._normalized()
        var s_key = r[0]; var s_byte = r[1]
        var e_key = r[2]; var e_byte = r[3]
        var painter = Painter(view)
        for i in range(len(self._rows)):
            var row = self._rows[i]
            if row.key < s_key or row.key > e_key:
                continue
            var lo = row.byte_start
            var hi = row.byte_end
            if row.key == s_key and s_byte > lo:
                lo = s_byte
            if row.key == e_key and e_byte < hi:
                hi = e_byte
            if hi <= lo:
                continue
            var x0 = row.text_x + (lo - row.byte_start)
            var x1 = row.text_x + (hi - row.byte_start)
            if x1 > row.clip_x:
                x1 = row.clip_x
            for x in range(x0, x1):
                painter.set_attr(canvas, x, row.y, sel_attr)
