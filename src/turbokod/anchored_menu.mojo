"""The small anchored popup menus. ``AnchoredMenu`` is a whole one — a
list of action rows anchored to a cell (the spell, test-gutter and
LSP-status menus). The git-gutter and diagnostic menus lay out rows of
their own, so they compose the shared pieces instead:

* ``anchored_menu_rect`` — the anchor-clamped placement (open below /
  above, flip on overflow, snap left).
* ``paint_anchored_chrome`` — the shadow + fill + box frame.
* ``anchored_menu_mouse`` — the button-like press / release machine.

The menus compose these as free functions rather than inheriting a base
struct (Mojo has no inheritance), so each keeps full control of its rows.
"""

from .canvas import Canvas, paint_drop_shadow
from .painter import Painter
from .colors import Attr, BLACK, DARK_GRAY, GREEN, LIGHT_GRAY, WHITE
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_DOWN, KEY_ENTER, KEY_ESC, KEY_UP,
    MENU_HIT_INSIDE, MENU_HIT_NONE, MENU_HIT_OUTSIDE,
    MOUSE_BUTTON_LEFT,
)
from .geometry import Point, Rect
from .string_utils import display_columns


def anchored_menu_rect(
    anchor_x: Int, anchor_y: Int, width: Int, height: Int,
    container_bounds: Rect, prefer_above: Bool,
) -> Rect:
    """Place a ``width`` x ``height`` popup against ``(anchor_x, anchor_y)``,
    clamped inside ``container_bounds``.

    ``prefer_above=False`` opens one row below the anchor and flips above
    when it would overflow the bottom edge (gutter / diagnostic / spell
    menus, anchored to an editor row). ``prefer_above=True`` opens above
    the anchor and flips below (the LSP-status menu, anchored to the bottom
    status bar). X snaps left so the full width stays on screen.
    """
    var x = anchor_x
    if x + width > container_bounds.b.x:
        x = container_bounds.b.x - width
    if x < 0:
        x = 0
    var y: Int
    if prefer_above:
        y = anchor_y - height
        if y < 0:
            y = anchor_y + 1
            if y + height > container_bounds.b.y:
                y = container_bounds.b.y - height
                if y < 0:
                    y = 0
    else:
        y = anchor_y + 1
        if y + height > container_bounds.b.y:
            y = anchor_y - height
            if y < 0:
                y = 0
    return Rect(x, y, x + width, y + height)


def paint_anchored_chrome(mut canvas: Canvas, rect: Rect, attr: Attr):
    """Paint the popup frame: drop shadow, ``attr``-filled interior, box
    border. Callers then paint their own rows over the fill."""
    paint_drop_shadow(canvas, rect)
    var painter = Painter(rect)
    painter.fill(canvas, rect, String(" "), attr)
    painter.draw_box(canvas, rect, attr, False)


@fieldwise_init
struct MenuMouseResult(ImplicitlyCopyable, Movable):
    """Outcome of ``anchored_menu_mouse``. ``hit`` is the ``MENU_HIT_*`` the
    caller should return from ``handle_mouse``. ``cancel`` means a
    press/release landed outside — the caller resolves its no-op action.
    ``fired_row >= 0`` means a tracked release landed on that row — the
    caller maps it to an action and resolves."""
    var hit: Int
    var cancel: Bool
    var fired_row: Int


def anchored_menu_mouse(
    event: Event, rect: Rect, row_y0: Int, row_count: Int,
    mut selected: Int, mut tracking: Bool,
) -> MenuMouseResult:
    """Button-like press / release machine shared by the anchored menus.

    A left-press inside a valid row arms tracking and sets ``selected``;
    the matching release inside reports ``fired_row``; a press or release
    outside cancels; a release with no prior tracked press is a no-op (so
    the right-click release that opened the menu can't auto-fire). Only
    left-button, non-motion mouse events are acted on.
    """
    if event.kind != EVENT_MOUSE:
        return MenuMouseResult(MENU_HIT_NONE, False, -1)
    if event.button != MOUSE_BUTTON_LEFT or event.motion:
        return MenuMouseResult(MENU_HIT_NONE, False, -1)
    var inside = rect.contains(event.pos)
    if event.pressed:
        if not inside:
            return MenuMouseResult(MENU_HIT_OUTSIDE, True, -1)
        var row = event.pos.y - row_y0
        if row < 0 or row >= row_count:
            return MenuMouseResult(MENU_HIT_INSIDE, False, -1)
        selected = row
        tracking = True
        return MenuMouseResult(MENU_HIT_INSIDE, False, -1)
    # Release.
    if not tracking:
        return MenuMouseResult(MENU_HIT_NONE, False, -1)
    tracking = False
    if not inside:
        return MenuMouseResult(MENU_HIT_OUTSIDE, True, -1)
    var row = event.pos.y - row_y0
    if row < 0 or row >= row_count:
        return MenuMouseResult(MENU_HIT_INSIDE, False, -1)
    return MenuMouseResult(MENU_HIT_INSIDE, False, row)


def menu_row_y(rect: Rect) -> Int:
    """Screen row of an anchored menu's first item: just inside the top
    border."""
    return rect.a.y + 1


def menu_step_wrap(selected: Int, delta: Int, n: Int) -> Int:
    """``selected`` moved by ``delta`` over ``n`` rows, wrapping past
    either end (Up on the first row lands on the last)."""
    if n == 0:
        return selected
    var i = selected + delta
    if i < 0:
        return n - 1
    if i >= n:
        return 0
    return i


@fieldwise_init
struct NativeMenuItem(Copyable, Movable):
    """One row of an anchored popup as the native host shows it (an
    ``NSMenu`` item, macOS-style UI): its label, the action code
    answering it, and whether it can be picked. Each menu's
    ``native_items`` lists the same rows its ``paint`` draws."""
    var label: String
    var code: Int
    var enabled: Bool

    @staticmethod
    def separator() -> Self:
        """A divider between groups of rows: no label, never picked."""
        return Self(String(""), 0, False)

    def is_separator(self) -> Bool:
        return len(self.label.as_bytes()) == 0


struct AnchoredMenu(Movable):
    """A modal popup of action rows anchored to a screen cell. The host
    opens it with its rows (``NativeMenuItem``s: label, action code,
    enabled), routes keys and mouse to it while ``active``, and once
    ``submitted`` reads ``action`` (0 = dismissed) and ``subject`` (what
    it was opened over: the word, the test's node id), then ``close``s it.
    A disabled row is drawn greyed and can't be picked; Enter on it keeps
    the menu open so the user can arrow to another."""
    var active: Bool
    var submitted: Bool
    var action: Int
    var subject: String
    var items: List[NativeMenuItem]
    var anchor_x: Int
    var anchor_y: Int
    var prefer_above: Bool
    """Open above the anchor (one on the bottom status bar) rather than
    below it (one on an editor row)."""
    var selected: Int
    var tracking: Bool
    """True between a captured left-press inside the menu and its
    matching release. Like a button, a row only fires on release; a
    release without a prior tracked press (the one of the right-click
    that opened the menu) is a non-event."""

    def __init__(out self):
        self.active = False
        self.submitted = False
        self.action = 0
        self.subject = String("")
        self.items = List[NativeMenuItem]()
        self.anchor_x = 0
        self.anchor_y = 0
        self.prefer_above = False
        self.selected = 0
        self.tracking = False

    def open(
        mut self, anchor: Point, var items: List[NativeMenuItem],
        var subject: String = String(""), prefer_above: Bool = False,
    ):
        """Open over ``anchor`` with the first row selected."""
        self = AnchoredMenu()
        self.active = True
        self.items = items^
        self.subject = subject^
        self.anchor_x = anchor.x
        self.anchor_y = anchor.y
        self.prefer_above = prefer_above

    def close(mut self):
        self = AnchoredMenu()

    def native_items(self) -> List[NativeMenuItem]:
        return self.items.copy()

    def choose(mut self, action: Int):
        """Answer the menu (0 = dismissed); the native host's path."""
        self.action = action
        self.submitted = True

    def _pick(mut self, row: Int):
        if 0 <= row and row < len(self.items) and self.items[row].enabled:
            self.choose(self.items[row].code)

    def _rect(self, container_bounds: Rect) -> Rect:
        var width = 0
        for ref item in self.items:
            width = max(width, display_columns(item.label) + 4)
        return anchored_menu_rect(
            self.anchor_x, self.anchor_y, width, len(self.items) + 2,
            container_bounds, self.prefer_above,
        )

    def paint(self, mut canvas: Canvas, container_bounds: Rect):
        if not self.active:
            return
        var rect = self._rect(container_bounds)
        var attr = Attr(BLACK, LIGHT_GRAY)
        paint_anchored_chrome(canvas, rect, attr)
        var painter = Painter(rect)
        for i in range(len(self.items)):
            var y = menu_row_y(rect) + i
            var on = self.items[i].enabled
            var row_attr = attr if on else Attr(DARK_GRAY, LIGHT_GRAY)
            if self.selected == i:
                row_attr = Attr(BLACK if on else WHITE, GREEN)
                painter.fill(
                    canvas, Rect(rect.a.x + 1, y, rect.b.x - 1, y + 1),
                    String(" "), row_attr,
                )
            _ = painter.put_text(
                canvas, Point(rect.a.x + 2, y), self.items[i].label, row_attr,
            )

    def handle_key(mut self, event: Event) -> Bool:
        """Esc dismisses, Up / Down move (wrapping), Enter picks; every
        other key is swallowed while it's up. False when it isn't."""
        if not self.active:
            return False
        if event.kind != EVENT_KEY:
            return True
        var k = event.key
        if k == KEY_ESC:
            self.choose(0)
        elif k == KEY_UP:
            self.selected = menu_step_wrap(self.selected, -1, len(self.items))
        elif k == KEY_DOWN:
            self.selected = menu_step_wrap(self.selected, 1, len(self.items))
        elif k == KEY_ENTER:
            self._pick(self.selected)
        return True

    def handle_mouse(mut self, event: Event, container_bounds: Rect) -> Int:
        """Button-like press / release (``anchored_menu_mouse``); the
        ``MENU_HIT_*`` code. A press or release outside dismisses."""
        if not self.active:
            return MENU_HIT_NONE
        var rect = self._rect(container_bounds)
        var r = anchored_menu_mouse(
            event, rect, menu_row_y(rect), len(self.items),
            self.selected, self.tracking,
        )
        if r.cancel:
            self.choose(0)
        elif r.fired_row >= 0:
            self._pick(r.fired_row)
        return r.hit
