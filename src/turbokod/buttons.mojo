"""Turbo Vision–style push button with drop shadow.

The iconic look from Borland's Turbo C++ 3.x dialogs: a green button
face with black text, a half-block shadow on the right edge and a
half-block shadow row underneath — together they read as a thin
drop shadow that sits the button above the dialog surface.

The widget is purely positional: caller picks ``(x, y)`` and a
label, the helper computes face width / hit rect from the label.
Colours are caller-controlled so the same component can carry a
"focused" / "disabled" / "default" face while keeping the shadow
mechanics in one place.

Half-block rendering relies on the terminal font lining ``▄`` and
``▀`` up vertically — DOS / Cascadia Code / Iosevka all do this,
but a few minimalist ttf packs leave a sub-cell gap. When the gap
shows, switching fonts is the fix; the widget can't paper over a
font issue.
"""

from .canvas import Canvas
from .cell import Cell
from .colors import Attr, BLACK
from .events import Event, EVENT_MOUSE, MOUSE_BUTTON_LEFT
from .geometry import Point, Rect


@fieldwise_init
struct ShadowButton(ImplicitlyCopyable, Movable):
    """One placed button. Construct with a label + top-left cell;
    the rest is derived.

    ``label`` should already include any cosmetic padding (most
    callers use ``" OK "`` / ``" Cancel "`` to give the green face
    breathing room around the letters).
    """
    var label: String
    var x: Int
    var y: Int

    fn face_width(self) -> Int:
        return len(self.label.as_bytes())

    fn total_width(self) -> Int:
        """Cells the button claims horizontally: face + the 1-column
        right-edge shadow. Use to lay out two buttons side by side
        without their shadows colliding."""
        return self.face_width() + 1

    fn hit_rect(self) -> Rect:
        """Click region: the face row plus the right-shadow column
        and the bottom-shadow row. Generous on purpose — users
        regularly miss-click downward by a row, and the bottom
        shadow row is visually associated with the button anyway."""
        return Rect(
            self.x, self.y,
            self.x + self.face_width() + 1, self.y + 2,
        )


fn paint_shadow_button(
    mut canvas: Canvas, button: ShadowButton, face: Attr, shadow_bg: UInt8,
    max_x: Int = -1,
):
    """Render ``button`` with ``face`` colours.

    ``shadow_bg`` is the *background* color of the dialog surface
    underneath the button — the shadow itself is BLACK on that
    background, which is what makes a green button look "lifted"
    rather than smeared against an arbitrary surface. Callers pass
    in their dialog body's bg (typically ``LIGHT_GRAY``) so the
    shadow tone always matches.

    ``max_x`` is forwarded to ``put_text``'s clip arg; when set, the
    shadow column / row are also clipped against it so a button at
    the right edge doesn't spill past its container.
    """
    var shadow = Attr(BLACK, shadow_bg)
    # Face row.
    _ = canvas.put_text(Point(button.x, button.y), button.label, face, max_x)
    var face_w = button.face_width()
    # Right-edge shadow column. ``▄`` is a lower-half block — painted
    # in BLACK on the dialog bg, the dark bar sits at the bottom of
    # the cell and lines up with the bottom-shadow row painted below.
    var right_x = button.x + face_w
    if max_x < 0 or right_x < max_x:
        canvas.set(right_x, button.y, Cell(String("▄"), shadow, 1))
    # Bottom-shadow row, shifted right by one column. ``▀`` is the
    # upper-half block — its dark bar at the top of the cell lines
    # up with the right-shadow column above. The +1 offset is what
    # produces the diagonal "lifted" 3D effect.
    var sx_end = button.x + face_w + 1
    if max_x >= 0 and sx_end > max_x:
        sx_end = max_x
    for sx in range(button.x + 1, sx_end):
        canvas.set(sx, button.y + 1, Cell(String("▀"), shadow, 1))


fn shadow_button_hit(button: ShadowButton, event: Event) -> Bool:
    """True when ``event`` is a left-button press landing on
    ``button``'s hit rect (face or shadow rows). Drag-motion and
    release are excluded — the host's modal handler should treat a
    hit as a fully-consumed click."""
    if event.kind != EVENT_MOUSE:
        return False
    if event.button != MOUSE_BUTTON_LEFT or not event.pressed:
        return False
    if event.motion:
        return False
    return button.hit_rect().contains(event.pos)
