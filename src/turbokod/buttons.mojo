"""Turbo Vision–style push button with drop shadow.

The iconic look from Borland's Turbo C++ 3.x dialogs: a green button
face with black text, a half-block shadow on the right edge and a
half-block shadow row underneath — together they read as a thin
drop shadow that sits the button above the dialog surface.

The widget owns its own mouse tracking. On a left press inside the
hit rect ``handle_mouse`` "captures" the mouse — the button latches,
paints flush (no shadow) so the user sees the press registered, and
returns ``BUTTON_CAPTURED`` on every subsequent move/release event
until the mouse comes up. On release the button reports whether the
release landed inside the hit rect (``BUTTON_FIRED``, run the action)
or outside (``BUTTON_CANCELED``, drop the click silently).

That state machine — press-down captures, move tracks, up either
fires or cancels — is exactly what the user expects from any native
button. Hosts get a one-call API: route every mouse event to each
button's ``handle_mouse``; whichever returns non-``BUTTON_NONE`` has
consumed the event, and ``BUTTON_FIRED`` is the cue to run the
button's action. No dialog-level press latch, no "did the release
land where the press did?" bookkeeping — the button owns it.

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


# --- handle_mouse return values -----------------------------------------
# A four-state status enum: did the button consume the event, and
# (on release) which way did the click resolve. Hosts dispatch every
# mouse event through ``handle_mouse`` and treat any return other
# than ``BUTTON_NONE`` as "consumed by this button".

comptime BUTTON_NONE     = UInt8(0)
"""Event ignored: didn't hit the button and no capture was active."""
comptime BUTTON_CAPTURED = UInt8(1)
"""Press latched, or drag-motion continued. The button now owns
subsequent mouse events until release; the host should keep routing
events through this button's ``handle_mouse`` and treat each as
consumed."""
comptime BUTTON_FIRED    = UInt8(2)
"""Release inside the hit rect after a captured press: the action
should run. The latch is already cleared by the time this returns."""
comptime BUTTON_CANCELED = UInt8(3)
"""Release outside the hit rect after a captured press: the user
dragged away to back out. Latch cleared, no action."""


struct ShadowButton(ImplicitlyCopyable, Movable):
    """One placed button. Construct with a label + top-left cell;
    the rest is derived.

    ``label`` should already include any cosmetic padding (most
    callers use ``" OK "`` / ``" Cancel "`` to give the green face
    breathing room around the letters).

    The button is *stateful*: ``handle_mouse`` runs a press / move /
    release machine that captures the mouse on press and reports
    ``BUTTON_FIRED`` only when the release lands back inside. Hosts
    must keep one ``ShadowButton`` per visible button alive across
    paints — re-instantiating per frame would drop the latch
    mid-press. Use ``move_to`` to update geometry between paints
    without disturbing tracking.
    """
    var label: String
    var x: Int
    var y: Int
    var pressed: Bool
    """True between a captured press and the matching release.
    While set, ``handle_mouse`` consumes every mouse event."""
    var pressed_inside: Bool
    """Last seen cursor position relative to the hit rect, while
    pressed. Drives the paint flag — the shadow returns the moment
    the cursor leaves the held button so the user can see the click
    is now armed to cancel — and also decides ``FIRED`` vs.
    ``CANCELED`` on release."""

    fn __init__(out self, var label: String, x: Int, y: Int):
        self.label = label^
        self.x = x
        self.y = y
        self.pressed = False
        self.pressed_inside = False

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

    fn move_to(mut self, x: Int, y: Int):
        """Reposition without disturbing tracking state. Layouts that
        depend on a parent rect (e.g. dialogs that re-flow when
        dragged) update geometry every paint; an in-progress press
        must keep tracking against the *current* hit rect, not the
        rect at press-time, so this just re-points the button at the
        new top-left."""
        self.x = x
        self.y = y

    fn show_pressed(self) -> Bool:
        """True when the button should paint flush (no drop-shadow):
        currently captured *and* the cursor is still over the hit
        rect. ``paint_shadow_button`` consults this; reading it
        directly lets callers paint surrounding affordances (e.g.
        focus rings) consistently."""
        return self.pressed and self.pressed_inside

    fn handle_mouse(mut self, event: Event) -> UInt8:
        """Press / move / release state machine. See module docstring
        for the high-level model. Returns one of ``BUTTON_NONE`` /
        ``BUTTON_CAPTURED`` / ``BUTTON_FIRED`` / ``BUTTON_CANCELED``.

        The button only ever consumes left-button mouse events;
        wheel, right, key, paste, resize all return ``BUTTON_NONE``
        so callers can keep their existing dispatch order. Once
        captured (``self.pressed = True``) the button consumes
        every left-button event until release, regardless of where
        the cursor went."""
        if event.kind != EVENT_MOUSE:
            return BUTTON_NONE
        if event.button != MOUSE_BUTTON_LEFT:
            return BUTTON_NONE
        # Press (initial click, not drag-motion).
        if event.pressed and not event.motion:
            # A second press without an intervening release means the
            # host dropped a release event somewhere — discard the
            # stale latch rather than getting stuck in a permanent
            # "pressed" state. Then re-arm if this press hits.
            if self.pressed:
                self.pressed = False
                self.pressed_inside = False
            if self.hit_rect().contains(event.pos):
                self.pressed = True
                self.pressed_inside = True
                return BUTTON_CAPTURED
            return BUTTON_NONE
        # Drag motion: only consume while we hold capture. The
        # ``pressed_inside`` flag tracks whether the cursor is
        # currently over the hit rect so the paint can flip the
        # shadow back on the moment the user drags off (and back to
        # flush on re-entry — same as native buttons).
        if event.pressed and event.motion:
            if not self.pressed:
                return BUTTON_NONE
            self.pressed_inside = self.hit_rect().contains(event.pos)
            return BUTTON_CAPTURED
        # Release. Only meaningful when we hold capture; spurious
        # releases (no press preceded) are not ours to consume. The
        # release position is what decides FIRED vs CANCELED, not
        # the cached ``pressed_inside`` — terminals don't always
        # interleave a motion event before release, and "did the
        # mouse come up over me?" is the question that matters.
        if not event.pressed:
            if not self.pressed:
                return BUTTON_NONE
            self.pressed = False
            self.pressed_inside = False
            if self.hit_rect().contains(event.pos):
                return BUTTON_FIRED
            return BUTTON_CANCELED
        return BUTTON_NONE


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

    When the button is currently captured *and* the cursor is over
    its hit rect (``button.show_pressed()``), the drop-shadow cells
    are overpainted with the dialog body so the button reads as
    sunken-flush — the standard "I'm being held" affordance. The
    moment the cursor drags off the held button, the shadow returns
    so the user can see the click is now armed to cancel.
    """
    var shadow = Attr(BLACK, shadow_bg)
    # Face row.
    _ = canvas.put_text(Point(button.x, button.y), button.label, face, max_x)
    var face_w = button.face_width()
    var right_x = button.x + face_w
    var sx_end = button.x + face_w + 1
    if max_x >= 0 and sx_end > max_x:
        sx_end = max_x
    if button.show_pressed():
        # Sunken state: overpaint shadow cells with the dialog body
        # so a previous frame's shadow can't linger across the
        # press → flush transition.
        var body = Cell(String(" "), Attr(BLACK, shadow_bg), 1)
        if max_x < 0 or right_x < max_x:
            canvas.set(right_x, button.y, body)
        for sx in range(button.x + 1, sx_end):
            canvas.set(sx, button.y + 1, body)
        return
    # Right-edge shadow column. ``▄`` is a lower-half block — painted
    # in BLACK on the dialog bg, the dark bar sits at the bottom of
    # the cell and lines up with the bottom-shadow row painted below.
    if max_x < 0 or right_x < max_x:
        canvas.set(right_x, button.y, Cell(String("▄"), shadow, 1))
    # Bottom-shadow row, shifted right by one column. ``▀`` is the
    # upper-half block — its dark bar at the top of the cell lines
    # up with the right-shadow column above. The +1 offset is what
    # produces the diagonal "lifted" 3D effect.
    for sx in range(button.x + 1, sx_end):
        canvas.set(sx, button.y + 1, Cell(String("▀"), shadow, 1))


fn shadow_button_hit(button: ShadowButton, event: Event) -> Bool:
    """True when ``event`` is a left-button press landing on
    ``button``'s hit rect (face or shadow rows). Drag-motion and
    release are excluded.

    Kept for niche callers that only care about the press-down
    geometry (e.g. cursor-shape hinting). Anything that runs an
    action in response to a click should call ``handle_mouse``
    instead — that's what gives press / drag-cancel / release-fire
    behaviour."""
    if event.kind != EVENT_MOUSE:
        return False
    if event.button != MOUSE_BUTTON_LEFT or not event.pressed:
        return False
    if event.motion:
        return False
    return button.hit_rect().contains(event.pos)
