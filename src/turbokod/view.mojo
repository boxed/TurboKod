"""Views: composable units that paint themselves and react to events.

The C++ TurboVision design uses deep single-inheritance: TView → TGroup →
TWindow → TDialog. Mojo structs don't have inheritance, so we lean on
*composition*: a small `Drawable` trait that anything paintable implements,
and concrete widget structs that hold state. A real "view hierarchy" with
parent/child dispatch is a TODO — for now this layer is enough to compose
windowed UIs out of plain functions and small structs.

This file is intentionally bare. The `widgets` module (or just direct calls
into Canvas) gives you immediate-mode drawing if you don't want to build
state-bearing widget structs.
"""

from std.collections.list import List
from std.collections.optional import Optional

from .canvas import Canvas
from .painter import Painter
from .colors import Attr, default_attr, WHITE, BLUE, PANE_BG, PANE_FG
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE, KEY_TAB, MOD_SHIFT, MOUSE_BUTTON_LEFT,
)
from .geometry import Point, Rect, compute_dialog_rect
from .string_utils import display_columns


trait Drawable:
    """Anything that can paint itself into a Canvas at a given rect.

    Conformed by the immediate-mode demo widgets below (``Label`` /
    ``Frame`` / ``Fill``) that ``examples/`` builds on. The larger
    stateful widgets (editor, dialogs, panels) deliberately do *not*
    conform: each needs extra paint inputs (focus flag, item list,
    body attr) and a richer return contract than a single trait can
    capture, so they expose concrete ``paint`` methods instead.
    """
    def paint(self, mut canvas: Canvas, bounds: Rect): ...


# --- Concrete widgets -------------------------------------------------------


struct Label(Copyable, Movable, Drawable):
    var text: String
    var attr: Attr

    def __init__(out self, var text: String):
        self.text = text^
        self.attr = default_attr()

    def __init__(out self, var text: String, attr: Attr):
        self.text = text^
        self.attr = attr

    def paint(self, mut canvas: Canvas, bounds: Rect):
        if bounds.is_empty():
            return
        # Center horizontally, top-align vertically.
        var text_len = display_columns(self.text)
        var x = bounds.a.x + (bounds.width() - text_len) // 2
        if x < bounds.a.x:
            x = bounds.a.x
        var painter = Painter(bounds)
        _ = painter.put_text(canvas, Point(x, bounds.a.y), self.text, self.attr)


struct Frame(Copyable, Movable, Drawable):
    """A bordered window with an optional title in the top edge."""
    var title: String
    var attr: Attr
    var double_line: Bool

    def __init__(out self, var title: String):
        self.title = title^
        self.attr = Attr(WHITE, BLUE)
        self.double_line = False

    def __init__(out self, var title: String, attr: Attr, double_line: Bool = False):
        self.title = title^
        self.attr = attr
        self.double_line = double_line

    def paint(self, mut canvas: Canvas, bounds: Rect):
        if bounds.width() < 2 or bounds.height() < 2:
            return
        var painter = Painter(bounds)
        # Fill interior with the frame's background color so contents inherit it.
        var interior = Rect(bounds.a.x + 1, bounds.a.y + 1, bounds.b.x - 1, bounds.b.y - 1)
        if not interior.is_empty():
            painter.fill(canvas, interior, String(" "), self.attr)
        painter.draw_box(canvas, bounds, self.attr, self.double_line)
        if self.title.byte_length() > 0 and bounds.width() >= display_columns(self.title) + 4:
            var label = String(" ") + self.title + String(" ")
            var label_len = display_columns(label)
            var x = bounds.a.x + (bounds.width() - label_len) // 2
            _ = painter.put_text(canvas, Point(x, bounds.a.y), label, self.attr)


struct Fill(Copyable, Movable, Drawable):
    """Solid fill — useful as a background panel."""
    var glyph: String
    var attr: Attr

    def __init__(out self):
        self.glyph = String(" ")
        self.attr = Attr(PANE_FG, PANE_BG)

    def __init__(out self, var glyph: String, attr: Attr):
        self.glyph = glyph^
        self.attr = attr

    def paint(self, mut canvas: Canvas, bounds: Rect):
        var painter = Painter(bounds)
        painter.fill(canvas, bounds, self.glyph, self.attr)


# --- Layout helpers ---------------------------------------------------------


def centered(outer: Rect, width: Int, height: Int) -> Rect:
    """Return the rectangle of ``width × height`` centered inside ``outer``."""
    var x = outer.a.x + (outer.width() - width) // 2
    var y = outer.a.y + (outer.height() - height) // 2
    return Rect(x, y, x + width, y + height)


struct RowCursor(Copyable, Movable):
    """Vertical layout cursor that automatically inserts a blank row
    between consecutive control placements.

    Dialogs that hand-code Y offsets routinely end up gluing controls
    together — the next placement is `y + height`, with no breathing
    room — and the bug surfaces as a labelled field sitting directly on
    top of the list below it. ``RowCursor`` makes the gap the default:
    every ``place()`` after the first reserves ``gap`` rows of vertical
    whitespace *before* the new control's start. Callers get correct
    spacing by writing the obvious thing.

    Use ``place(height)`` for normal controls (label + field row, list,
    button row). Use ``place_tight(height)`` for a follow-on that's part
    of the same logical unit as the previous placement (e.g. a block
    label glued to the list it heads). Use ``skip(rows)`` for explicit
    extra whitespace beyond the automatic gap.

    ```
    var c = RowCursor(rect.a.y + 1)
    var lang_y = c.place()              # rect.a.y + 1
    var ft_y   = c.place()              # rect.a.y + 3 — one row gap
    var lbl_y  = c.place()              # rect.a.y + 5
    var list_y = c.place_tight(5)       # rect.a.y + 6 — no gap from label
    ```
    """
    var y: Int
    var gap: Int
    var _first: Bool

    def __init__(out self, start_y: Int, gap: Int = 1):
        self.y = start_y
        self.gap = gap
        self._first = True

    def place(mut self, height: Int = 1) -> Int:
        if not self._first:
            self.y = self.y + self.gap
        self._first = False
        var start = self.y
        self.y = self.y + height
        return start

    def place_tight(mut self, height: Int = 1) -> Int:
        self._first = False
        var start = self.y
        self.y = self.y + height
        return start

    def skip(mut self, rows: Int):
        self.y = self.y + rows


# --- Focus management ------------------------------------------------------


@fieldwise_init
struct FocusableSlot(ImplicitlyCopyable, Movable):
    """One focusable widget's screen rect + whether it currently
    participates in the tab walk / click hit-test.

    ``rect`` is refreshed every paint (and every event dispatch) so the
    hit-test never lags the actual geometry. ``visitable`` lets dialogs
    register all possible slots up front and toggle inclusion based on
    runtime state (e.g. a "Remove" button that's only enabled when the
    target list is non-empty); a non-visitable slot is skipped by both
    Tab cycling and click hit-testing.
    """
    var rect: Rect
    var visitable: Bool


struct FocusGroup(Movable):
    """Framework-level focus manager — one per dialog or panel.

    Owns the ordered list of focusable widgets, the currently-focused
    slot index, and the policies for moving focus (Tab/Shift-Tab cycle,
    click → focus on press-and-not-motion). Dialogs no longer hand-roll
    their own ``_focus`` int + ``_next_focus`` walk + click-routing
    block; they register slots in declaration order, refresh rects each
    paint, and let the group eat Tab and clicks.

    Tab order = registration order. Slot indices are stable across the
    dialog's lifetime — fields are allocated once in ``__init__`` (a
    fixed-size list), then their rect + ``visitable`` are updated each
    paint via ``update``. The focused index survives paints; if it
    points to a slot that becomes non-visitable, call ``reconcile`` to
    advance to the next visitable one.

    The group does NOT forward events to widgets — that's still the
    dialog's job, because widget handlers have heterogeneous
    signatures (some need a rect argument, some return rich result
    types). The group's contract is narrow on purpose: "who has focus,
    and how does focus move."
    """
    var slots: List[FocusableSlot]
    var focused: Int

    def __init__(out self, slot_count: Int):
        """Pre-allocate ``slot_count`` slots. The dialog ``update``s each
        one per paint with the current rect + visitability. Slots
        default to ``visitable=True`` so a freshly-opened dialog can
        cycle focus before its first paint runs — conditional slots
        (e.g. the second input in the find/replace prompt when
        ``has_second`` is False) opt out by passing ``visitable=False``
        in their ``update`` call. Rects default to (0,0,0,0) so a click
        before first paint can't accidentally land on a slot — the
        empty rect contains no point."""
        self.slots = List[FocusableSlot]()
        for _ in range(slot_count):
            self.slots.append(FocusableSlot(Rect(0, 0, 0, 0), True))
        self.focused = -1

    def update(mut self, idx: Int, rect: Rect, visitable: Bool = True):
        """Refresh slot ``idx``'s rect + visitability. Called from the
        dialog's paint (and from handle_mouse just before hit-testing)
        so geometry never lags the screen."""
        if 0 <= idx and idx < len(self.slots):
            self.slots[idx] = FocusableSlot(rect, visitable)

    def is_focused(self, idx: Int) -> Bool:
        return idx == self.focused

    def focus(mut self, idx: Int):
        """Seed focus on slot ``idx``. Does nothing if the slot isn't
        visitable yet — open() callers that focus a slot whose
        visitability depends on first paint should call ``reconcile``
        afterward, or just pass a slot that's always visitable."""
        if 0 <= idx and idx < len(self.slots) and self.slots[idx].visitable:
            self.focused = idx

    def focus_force(mut self, idx: Int):
        """Set focus without consulting visitability. For seeding focus
        before the first paint (when all slots are still non-visitable
        by default) or for hosts that know what they're doing."""
        if 0 <= idx and idx < len(self.slots):
            self.focused = idx

    def slot_count(self) -> Int:
        return len(self.slots)

    def is_visitable(self, idx: Int) -> Bool:
        if idx < 0 or idx >= len(self.slots):
            return False
        return self.slots[idx].visitable

    def cycle(mut self, backward: Bool = False):
        """Advance focus to the next/previous visitable slot. Wraps
        around. If no slot is visitable, focus becomes -1."""
        var n = len(self.slots)
        if n == 0:
            self.focused = -1
            return
        var cur = self.focused
        if cur < 0:
            # Bias the seed so the first forward step lands on slot 0
            # and the first backward step lands on slot n-1.
            cur = -1 if not backward else n
        for _ in range(n):
            if backward:
                cur = (cur - 1 + n) % n
            else:
                cur = (cur + 1) % n
            if self.slots[cur].visitable:
                self.focused = cur
                return
        self.focused = -1

    def handle_tab(mut self, event: Event) -> Bool:
        """Eat Tab / Shift+Tab and cycle focus. Returns True iff the
        event was consumed."""
        if event.kind != EVENT_KEY:
            return False
        if event.key != KEY_TAB:
            return False
        var backward = (event.mods & MOD_SHIFT) != 0
        self.cycle(backward)
        return True

    def hit_test(self, event: Event) -> Int:
        """If ``event`` is a left-press (press-and-not-motion, i.e. a
        real click rather than a hover or drag), return the index of
        the visitable slot whose rect contains the point, or -1. Hover
        events and drag-motion events return -1 — focus must NOT shift
        as the mouse passes over a widget."""
        if event.kind != EVENT_MOUSE:
            return -1
        if event.button != MOUSE_BUTTON_LEFT:
            return -1
        if not event.pressed or event.motion:
            return -1
        for i in range(len(self.slots)):
            if not self.slots[i].visitable:
                continue
            if self.slots[i].rect.contains(event.pos):
                return i
        return -1

    def handle_click(mut self, event: Event) -> Int:
        """If ``event`` is a real click inside a visitable slot, move
        focus there and return that slot index. Otherwise return -1.

        Hover and drag-motion never trigger a focus change — that's
        the whole point: previously each dialog reinvented this and
        some of them got it wrong (mere hover moved focus).
        """
        var hit = self.hit_test(event)
        if hit < 0:
            return -1
        self.focused = hit
        return hit

    def reconcile(mut self):
        """If the currently-focused slot is no longer visitable, advance
        to the next visitable one. Call after a layout pass that has
        toggled a slot's ``visitable`` flag (e.g. a button row whose
        Remove button just became disabled because the list emptied)."""
        if self.focused < 0 or self.focused >= len(self.slots) \
                or not self.slots[self.focused].visitable:
            self.cycle()


# --- Title-bar drag + placement --------------------------------------------


struct DraggableDialog(ImplicitlyCopyable, Movable):
    """Auto-centering placement + title-bar move-by-drag for a modal
    in-grid dialog.

    Every movable dialog (file picker, save-as, action editor, …) was
    carrying a byte-identical copy of the same two fields and the same
    press-on-title / motion / release state machine — the comments
    literally read *"same handling as FileDialog"*. This bundles them so
    a dialog just owns one ``DraggableDialog``, asks it for the placed
    ``rect``, and routes mouse events through it.

    Two fields:

    * ``pos`` — the user-chosen top-left after a drag, or unset to
      auto-center. ``reset()`` (call from ``open``/``close``) returns to
      centered so a freshly-opened dialog never reuses a stale offset.
    * ``_drag`` — the cursor's offset within the dialog at drag-start,
      or unset when no drag is in flight. Stored as an offset (not the
      press point) so the move tracks the cursor exactly.

    Usage in the host's ``handle_mouse`` (after the modal ``if event.kind
    != EVENT_MOUSE: return True`` guard):

    ```
    var rect = self._dlg.rect(screen, WIDTH, HEIGHT)
    if self._dlg.handle_drag_continue(event):
        return True
    if <close-button hit>: ...        # checked between continue and start
    if self._dlg.handle_drag_start(event, rect):
        return True
    # ... normal list/button routing ...
    ```

    The close-button check sits *between* the two calls on purpose: a
    press on the close glyph must dismiss rather than start a move.
    """
    var pos: Optional[Point]
    var _drag: Optional[Point]

    def __init__(out self):
        self.pos = Optional[Point]()
        self._drag = Optional[Point]()

    def reset(mut self):
        """Forget any dragged position and in-flight drag. Call from the
        host's ``open`` and ``close`` so the dialog re-centers."""
        self.pos = Optional[Point]()
        self._drag = Optional[Point]()

    def rect(self, screen: Rect, width: Int, height: Int) -> Rect:
        """Placed rect: the dragged ``pos`` when set (clamped on-screen
        by ``compute_dialog_rect``), else auto-centered in ``screen``."""
        return compute_dialog_rect(screen, self.pos, width, height)

    def is_dragging(self) -> Bool:
        return Bool(self._drag)

    def handle_drag_continue(mut self, event: Event) -> Bool:
        """Advance or end an in-progress title-bar drag. Returns True
        iff the event was consumed — call at the top of the mouse
        handler so an in-flight drag swallows every event until release.

        Returns False (not dragging) immediately when no drag is active,
        letting the caller fall through to its normal routing."""
        if not self._drag:
            return False
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

    def handle_drag_start(mut self, event: Event, rect: Rect) -> Bool:
        """Begin a move-by-drag when ``event`` is a left-press (not
        motion) landing on the dialog's title row (``rect.a.y``).
        Returns True iff a drag was started. Call *after* the host's
        own close-button check so a press on the close glyph dismisses
        instead of starting a move."""
        if event.button == MOUSE_BUTTON_LEFT and event.pressed \
                and not event.motion and event.pos.y == rect.a.y \
                and rect.a.x <= event.pos.x and event.pos.x < rect.b.x:
            self._drag = Optional[Point](Point(
                event.pos.x - rect.a.x, event.pos.y - rect.a.y,
            ))
            return True
        return False
