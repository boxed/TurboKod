"""Shared building blocks for the small anchored popup menus — the git /
test gutter menus, the LSP-status menu, the spell menu, and the diagnostic
menu. Each menu keeps its own state, labels, and action resolution; these
helpers factor out the three pieces that were copy-pasted across all of
them:

* ``anchored_menu_rect`` — the anchor-clamped placement (open below /
  above, flip on overflow, snap left).
* ``paint_anchored_chrome`` — the shadow + fill + box frame.
* ``anchored_menu_mouse`` — the button-like press / release machine.

The menus compose these as free functions rather than inheriting a base
struct (Mojo has no inheritance), so each keeps full control of its rows.
"""

from .canvas import Canvas, paint_drop_shadow
from .painter import Painter
from .colors import Attr
from .events import (
    Event, EVENT_MOUSE,
    MENU_HIT_INSIDE, MENU_HIT_NONE, MENU_HIT_OUTSIDE,
    MOUSE_BUTTON_LEFT,
)
from .geometry import Rect


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
