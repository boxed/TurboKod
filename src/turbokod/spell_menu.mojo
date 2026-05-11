"""Popup menu that opens on Alt+Enter over a misspelled word.

Anchored at the on-screen position of the misspelled word, the menu
offers the two ways the user can teach the speller about a word that
isn't really wrong: adding it to the user-wide dictionary or to the
current project's dictionary. The latter is disabled (still listed,
but unselectable) when no project is open — making the option
disappear would be more confusing than greying it out.

Painted in the same light-gray-with-green-selection palette as the
``MenuBar`` dropdown so the look reads as "this is a menu" without
having to explain it. The host (Desktop) is responsible for opening
the menu in response to ``Editor.consume_spell_action_request`` and
for routing keyboard / mouse events to it before any other widget.
"""

from std.collections.list import List

from .canvas import Canvas, paint_drop_shadow
from .painter import Painter
from .cell import Cell
from .colors import (
    Attr, BLACK, DARK_GRAY, GREEN, LIGHT_GRAY, WHITE,
)
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_DOWN, KEY_ENTER, KEY_ESC, KEY_UP,
    MOUSE_BUTTON_LEFT,
)
from .geometry import Point, Rect
from .view import RowCursor


fn _rows_top(rect: Rect) -> Int:
    """Y of the first menu row. Driven by ``RowCursor`` so paint and
    hit-testing share one source of truth — the original code had
    ``rect.a.y + 1`` hardcoded in both ``paint`` and ``handle_mouse``."""
    var cursor = RowCursor(rect.a.y + 1)
    return cursor.place()


# Hit-test result codes for ``SpellMenu.handle_mouse``. Mirrors the
# ``DROPDOWN_HIT_*`` shape so callers can pattern-match similarly.
comptime SPELL_HIT_NONE    = -1
comptime SPELL_HIT_INSIDE  = 1
"""Click landed inside the popup (selection / no-op on disabled row);
the menu has handled the click."""
comptime SPELL_HIT_OUTSIDE = 2
"""Click landed outside the popup. The menu auto-closes; the caller
should treat the event as falling through to its own dispatch."""


# Action codes returned to the host on resolve.
comptime SPELL_ACTION_NONE        = 0
"""The menu was dismissed (Esc / click-outside / Enter on a
disabled row). No persistence work for the host to do."""
comptime SPELL_ACTION_ADD_USER    = 1
"""Add the word to the user-wide dictionary."""
comptime SPELL_ACTION_ADD_PROJECT = 2
"""Add the word to the project-local dictionary."""


# The two items the menu offers, in display order. Kept as comptime
# constants rather than a ``List`` field so the labels can be stamped
# directly into ``paint`` without per-frame string churn.
comptime _LABEL_USER    = String("Add to user dictionary")
comptime _LABEL_PROJECT = String("Add to project dictionary")


struct SpellMenu(Movable):
    """Modal-ish popup menu anchored to a misspelled word."""

    var active: Bool
    """Open / closed flag. ``paint`` and the input handlers are no-ops
    when False, so the host can call them unconditionally."""

    var submitted: Bool
    """True after the user resolves the menu (selection or cancel).
    Host reads ``action`` + ``word`` then calls ``close()``."""

    var action: Int
    """One of the ``SPELL_ACTION_*`` codes. Set on ``_resolve``."""

    var word: String
    """The misspelled word the menu was opened over. Forwarded back to
    the host so it can call the appropriate ``Speller.add_*`` method
    without re-deriving the word from cursor position."""

    var anchor_x: Int
    var anchor_y: Int
    """Screen cell at which to anchor the menu. The menu opens on the
    row *below* the anchor when there's room, or above when not."""

    var selected: Int
    """Highlighted row index. 0 = user, 1 = project."""

    var has_project: Bool
    """When False, the project row is rendered greyed out and Enter on
    it falls through to ``SPELL_ACTION_NONE``. The label still appears
    so the user gets a hint about why it's there."""

    fn __init__(out self):
        self.active = False
        self.submitted = False
        self.action = SPELL_ACTION_NONE
        self.word = String("")
        self.anchor_x = 0
        self.anchor_y = 0
        self.selected = 0
        self.has_project = False

    fn open(
        mut self, var word: String, anchor: Point, has_project: Bool,
    ):
        """Open the menu over ``word`` anchored at ``anchor`` (the
        screen cell the misspelled word starts at). ``has_project``
        gates the second row.
        Default selection is row 0 (user dictionary) — that's the
        choice that always works, and "stay personal unless I deliberately
        share" is the safer default for a tool the user might not yet
        have explained to their teammates."""
        self.word = word^
        self.anchor_x = anchor.x
        self.anchor_y = anchor.y
        self.has_project = has_project
        self.active = True
        self.submitted = False
        self.action = SPELL_ACTION_NONE
        self.selected = 0

    fn close(mut self):
        self.active = False
        self.submitted = False
        self.action = SPELL_ACTION_NONE
        self.word = String("")

    fn _row_count(self) -> Int:
        # Always show both rows; project is greyed when ``not has_project``.
        return 2

    fn _step(mut self, delta: Int):
        var n = self._row_count()
        if n == 0:
            return
        var i = self.selected + delta
        if i < 0:
            i = n - 1
        elif i >= n:
            i = 0
        self.selected = i

    fn _resolve(mut self, action: Int):
        self.action = action
        self.submitted = True

    # --- layout / paint ---------------------------------------------------

    fn _rect(self, screen: Rect) -> Rect:
        """Where the popup will render. Width matches the longer
        label + 4 (left pad + label + right pad + 2 borders); height
        is ``rows + 2`` (two items + top/bottom borders).

        Sits one row below the anchor when there's room; flips above
        when the anchor is too close to the bottom edge. Snaps left
        when the anchor is too close to the right edge."""
        var width = len(_LABEL_PROJECT.as_bytes()) + 4
        if len(_LABEL_USER.as_bytes()) + 4 > width:
            width = len(_LABEL_USER.as_bytes()) + 4
        var height = self._row_count() + 2
        var x = self.anchor_x
        if x + width > screen.b.x:
            x = screen.b.x - width
        if x < 0:
            x = 0
        var y = self.anchor_y + 1
        if y + height > screen.b.y:
            # Flip above the anchor row.
            y = self.anchor_y - height
            if y < 0:
                y = 0
        return Rect(x, y, x + width, y + height)

    fn paint(self, mut canvas: Canvas, screen: Rect):
        if not self.active:
            return
        var rect = self._rect(screen)
        var attr = Attr(BLACK, LIGHT_GRAY)
        var sel_attr = Attr(BLACK, GREEN)
        var sel_attr_disabled = Attr(WHITE, GREEN)
        var disabled_attr = Attr(DARK_GRAY, LIGHT_GRAY)
        paint_drop_shadow(canvas, rect)
        var painter = Painter(rect)
        painter.fill(canvas, rect, String(" "), attr)
        painter.draw_box(canvas, rect, attr, False)
        # Row 0: user dict (always enabled).
        var y0 = _rows_top(rect)
        var is_sel0 = (self.selected == 0)
        var row_attr0 = sel_attr if is_sel0 else attr
        if is_sel0:
            painter.fill(
                canvas, Rect(rect.a.x + 1, y0, rect.b.x - 1, y0 + 1),
                String(" "), row_attr0,
            )
        _ = painter.put_text(
            canvas, Point(rect.a.x + 2, y0), _LABEL_USER, row_attr0,
        )
        # Row 1: project dict — disabled when no project is open.
        var y1 = y0 + 1
        var is_sel1 = (self.selected == 1)
        var enabled1 = self.has_project
        var row_attr1: Attr
        if is_sel1:
            row_attr1 = sel_attr if enabled1 else sel_attr_disabled
        else:
            row_attr1 = attr if enabled1 else disabled_attr
        if is_sel1:
            painter.fill(
                canvas, Rect(rect.a.x + 1, y1, rect.b.x - 1, y1 + 1),
                String(" "), row_attr1,
            )
        _ = painter.put_text(
            canvas, Point(rect.a.x + 2, y1), _LABEL_PROJECT, row_attr1,
        )

    # --- input ------------------------------------------------------------

    fn handle_key(mut self, event: Event) -> Bool:
        """Returns True if the event was consumed."""
        if not self.active:
            return False
        if event.kind != EVENT_KEY:
            return True
        var k = event.key
        if k == KEY_ESC:
            self._resolve(SPELL_ACTION_NONE)
            return True
        if k == KEY_UP:
            self._step(-1)
            return True
        if k == KEY_DOWN:
            self._step(1)
            return True
        if k == KEY_ENTER:
            if self.selected == 0:
                self._resolve(SPELL_ACTION_ADD_USER)
            elif self.selected == 1:
                if self.has_project:
                    self._resolve(SPELL_ACTION_ADD_PROJECT)
                # Disabled row: keep the menu open so the user can
                # arrow back up to the user-dict row instead of having
                # to re-open the menu after a no-op Enter.
            return True
        # Swallow everything else while modal — typing into the
        # underlying editor while the menu is up would be surprising.
        return True

    fn handle_mouse(mut self, event: Event, screen: Rect) -> Int:
        if not self.active:
            return SPELL_HIT_NONE
        if event.kind != EVENT_MOUSE:
            return SPELL_HIT_NONE
        if event.button != MOUSE_BUTTON_LEFT or not event.pressed \
                or event.motion:
            return SPELL_HIT_NONE
        var rect = self._rect(screen)
        if not rect.contains(event.pos):
            self._resolve(SPELL_ACTION_NONE)
            return SPELL_HIT_OUTSIDE
        var row = event.pos.y - _rows_top(rect)
        if row < 0 or row >= self._row_count():
            return SPELL_HIT_INSIDE
        self.selected = row
        if row == 0:
            self._resolve(SPELL_ACTION_ADD_USER)
        elif row == 1 and self.has_project:
            self._resolve(SPELL_ACTION_ADD_PROJECT)
        return SPELL_HIT_INSIDE
