"""Focused tests for the new ``ShadowButton.handle_mouse`` state
machine and the ``paint_shadow_button`` press visual.

Lives outside ``test_basic.mojo`` so it can be exercised independently
of pre-existing breakage in unrelated tests (highlight, etc.) — run
with ``./run.sh tests/test_buttons.mojo``.
"""

from std.collections.list import List
from std.testing import assert_equal, assert_false, assert_true

from turbokod.buttons import (
    BUTTON_CANCELED, BUTTON_CAPTURED, BUTTON_FIRED, BUTTON_NONE,
    ShadowButton, paint_shadow_button, shadow_button_hit,
)
from turbokod.canvas import Canvas
from turbokod.colors import Attr, BLACK, GREEN, LIGHT_GRAY
from turbokod.dir_browser import DirBrowser, jump_shortcuts
from turbokod.events import Event, MOUSE_BUTTON_LEFT
from turbokod.geometry import Point, Rect
from turbokod.project_targets import ProjectTargets, RunTarget
from turbokod.targets_dialog import TargetsDialog


fn test_shadow_button_press_captures_and_release_fires() raises:
    """A press inside the hit rect captures the mouse; a release
    inside the same rect fires. The latch clears on release."""
    var btn = ShadowButton(String(" OK "), 2, 1)
    var press = Event.mouse_event(Point(3, 1), MOUSE_BUTTON_LEFT)
    assert_equal(btn.handle_mouse(press), BUTTON_CAPTURED)
    assert_true(btn.pressed)
    assert_true(btn.pressed_inside)
    var release = Event.mouse_event(
        Point(3, 1), MOUSE_BUTTON_LEFT, pressed=False,
    )
    assert_equal(btn.handle_mouse(release), BUTTON_FIRED)
    assert_false(btn.pressed)


fn test_shadow_button_release_outside_cancels() raises:
    """Press inside, drag outside, release: button must NOT fire.
    The state machine returns ``BUTTON_CANCELED`` so the host can
    distinguish "ran the action" from "user backed out"."""
    var btn = ShadowButton(String(" OK "), 2, 1)
    var press = Event.mouse_event(Point(3, 1), MOUSE_BUTTON_LEFT)
    assert_equal(btn.handle_mouse(press), BUTTON_CAPTURED)
    # Drag-motion off the button: still captured, but inside flag clears.
    var drag_off = Event.mouse_event(
        Point(50, 1), MOUSE_BUTTON_LEFT, pressed=True, motion=True,
    )
    assert_equal(btn.handle_mouse(drag_off), BUTTON_CAPTURED)
    assert_true(btn.pressed)
    assert_false(btn.pressed_inside)
    # Release outside.
    var release_off = Event.mouse_event(
        Point(50, 1), MOUSE_BUTTON_LEFT, pressed=False,
    )
    assert_equal(btn.handle_mouse(release_off), BUTTON_CANCELED)
    assert_false(btn.pressed)


fn test_shadow_button_drag_back_in_re_fires() raises:
    """Press, drag out, drag back in, release: must fire — matches
    native button affordance where re-entering the held button
    re-arms it for the click."""
    var btn = ShadowButton(String(" OK "), 2, 1)
    _ = btn.handle_mouse(Event.mouse_event(Point(3, 1), MOUSE_BUTTON_LEFT))
    _ = btn.handle_mouse(Event.mouse_event(
        Point(50, 1), MOUSE_BUTTON_LEFT, pressed=True, motion=True,
    ))
    assert_false(btn.pressed_inside)
    _ = btn.handle_mouse(Event.mouse_event(
        Point(3, 1), MOUSE_BUTTON_LEFT, pressed=True, motion=True,
    ))
    assert_true(btn.pressed_inside)
    var release = Event.mouse_event(
        Point(3, 1), MOUSE_BUTTON_LEFT, pressed=False,
    )
    assert_equal(btn.handle_mouse(release), BUTTON_FIRED)


fn test_shadow_button_press_outside_returns_none() raises:
    """A press that doesn't land on the button is unconsumed —
    callers can then route it elsewhere without their own
    hit-test."""
    var btn = ShadowButton(String(" OK "), 2, 1)
    var press = Event.mouse_event(Point(50, 50), MOUSE_BUTTON_LEFT)
    assert_equal(btn.handle_mouse(press), BUTTON_NONE)
    assert_false(btn.pressed)


fn test_shadow_button_motion_without_capture_returns_none() raises:
    """Drag motion when no button is captured is not ours to
    consume — must return NONE so the host can route it to e.g.
    a title-bar drag."""
    var btn = ShadowButton(String(" OK "), 2, 1)
    var drag = Event.mouse_event(
        Point(3, 1), MOUSE_BUTTON_LEFT, pressed=True, motion=True,
    )
    assert_equal(btn.handle_mouse(drag), BUTTON_NONE)


fn test_paint_shadow_button_pressed_omits_shadow() raises:
    """When the button is captured AND the cursor is over it, the
    drop-shadow cells are overpainted with the dialog body so the
    button reads as sunken-flush."""
    var canvas = Canvas(20, 4)
    canvas.fill(Rect(0, 0, 20, 4), String(" "), Attr(BLACK, LIGHT_GRAY))
    var btn = ShadowButton(String(" OK "), 2, 1)
    btn.pressed = True
    btn.pressed_inside = True
    paint_shadow_button(canvas, btn, Attr(BLACK, GREEN), LIGHT_GRAY)
    # Face row still carries the label on green.
    assert_equal(canvas.get(3, 1).glyph, String("O"))
    assert_equal(canvas.get(3, 1).attr.bg, GREEN)
    # Shadow column overpainted to body.
    assert_equal(canvas.get(2 + 4, 1).glyph, String(" "))
    assert_equal(canvas.get(2 + 4, 1).attr.bg, LIGHT_GRAY)
    # Bottom-shadow row collapses to body cells.
    assert_equal(canvas.get(3, 2).glyph, String(" "))
    assert_equal(canvas.get(2 + 4, 2).glyph, String(" "))


fn test_paint_shadow_button_dragged_off_shows_shadow_again() raises:
    """While the button is captured but the cursor has moved off
    the hit rect, the shadow returns — the user sees the click is
    armed to cancel."""
    var canvas = Canvas(20, 4)
    canvas.fill(Rect(0, 0, 20, 4), String(" "), Attr(BLACK, LIGHT_GRAY))
    var btn = ShadowButton(String(" OK "), 2, 1)
    btn.pressed = True
    btn.pressed_inside = False  # dragged off
    paint_shadow_button(canvas, btn, Attr(BLACK, GREEN), LIGHT_GRAY)
    assert_equal(canvas.get(2 + 4, 1).glyph, String("▄"))
    assert_equal(canvas.get(3, 2).glyph, String("▀"))


fn test_dir_browser_jump_button_release_inside_jumps() raises:
    """Press + release inside the Root jump button must navigate
    via ``jump_to``. Press alone must not navigate (release-fire
    semantics)."""
    var browser = DirBrowser()
    var start_dir = browser.dir
    var row = Rect(2, 10, 60, 12)
    var layout = jump_shortcuts(row.a.x)
    var idx = len(layout) - 1
    var b = layout[idx]
    var inside = Point(b.x + 1, row.a.y)
    var press = Event.mouse_event(inside, MOUSE_BUTTON_LEFT)
    assert_true(browser.handle_jump_click(press, row))
    # Press alone hasn't navigated.
    assert_true(browser.dir == start_dir)
    var release = Event.mouse_event(
        inside, MOUSE_BUTTON_LEFT, pressed=False,
    )
    assert_true(browser.handle_jump_click(release, row))
    assert_true(browser.dir == String("/"))


fn test_dir_browser_jump_button_release_outside_cancels() raises:
    """Press inside Root, release way outside — must NOT navigate."""
    var browser = DirBrowser()
    var start_dir = browser.dir
    var row = Rect(2, 10, 60, 12)
    var layout = jump_shortcuts(row.a.x)
    var idx = len(layout) - 1
    var b = layout[idx]
    var inside = Point(b.x + 1, row.a.y)
    _ = browser.handle_jump_click(
        Event.mouse_event(inside, MOUSE_BUTTON_LEFT), row,
    )
    # Release in a clearly-outside cell.
    var release = Event.mouse_event(
        Point(row.b.x - 1, row.a.y), MOUSE_BUTTON_LEFT, pressed=False,
    )
    _ = browser.handle_jump_click(release, row)
    assert_true(browser.dir == start_dir)


fn test_targets_dialog_save_release_outside_cancels() raises:
    """Press the Save button, drag away, release: dialog must NOT
    submit. Symmetric with the dir_browser test."""
    var src = ProjectTargets()
    var t1 = RunTarget()
    t1.name = String("only")
    src.targets.append(t1^)
    src.active = 0
    var dlg = TargetsDialog()
    dlg.open(src^)
    var screen = Rect(0, 0, 100, 30)
    var canvas = Canvas(100, 30)
    dlg.paint(canvas, screen)
    # Save is at index 2 in the persistent _buttons table.
    var save_btn = dlg._buttons[2].button
    var press = Event.mouse_event(
        Point(save_btn.x + 1, save_btn.y), MOUSE_BUTTON_LEFT,
    )
    _ = dlg.handle_mouse(press, screen)
    assert_false(dlg.submitted)
    # Drag off and release.
    _ = dlg.handle_mouse(Event.mouse_event(
        Point(save_btn.x + 1, save_btn.y + 5),
        MOUSE_BUTTON_LEFT, pressed=True, motion=True,
    ), screen)
    _ = dlg.handle_mouse(Event.mouse_event(
        Point(save_btn.x + 1, save_btn.y + 5),
        MOUSE_BUTTON_LEFT, pressed=False,
    ), screen)
    assert_false(dlg.submitted)


fn test_targets_dialog_save_release_inside_submits() raises:
    """Press + release on the Save button submits the dialog."""
    var src = ProjectTargets()
    var t1 = RunTarget()
    t1.name = String("only")
    src.targets.append(t1^)
    src.active = 0
    var dlg = TargetsDialog()
    dlg.open(src^)
    var screen = Rect(0, 0, 100, 30)
    var canvas = Canvas(100, 30)
    dlg.paint(canvas, screen)
    var save_btn = dlg._buttons[2].button
    var press_pos = Point(save_btn.x + 1, save_btn.y)
    _ = dlg.handle_mouse(
        Event.mouse_event(press_pos, MOUSE_BUTTON_LEFT), screen,
    )
    assert_false(dlg.submitted)
    _ = dlg.handle_mouse(Event.mouse_event(
        press_pos, MOUSE_BUTTON_LEFT, pressed=False,
    ), screen)
    assert_true(dlg.submitted)


fn main() raises:
    test_shadow_button_press_captures_and_release_fires()
    test_shadow_button_release_outside_cancels()
    test_shadow_button_drag_back_in_re_fires()
    test_shadow_button_press_outside_returns_none()
    test_shadow_button_motion_without_capture_returns_none()
    test_paint_shadow_button_pressed_omits_shadow()
    test_paint_shadow_button_dragged_off_shows_shadow_again()
    test_dir_browser_jump_button_release_inside_jumps()
    test_dir_browser_jump_button_release_outside_cancels()
    test_targets_dialog_save_release_outside_cancels()
    test_targets_dialog_save_release_inside_submits()
    print("all button tests passed")
