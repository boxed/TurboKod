"""Shared input handling for list pickers.

The four full-screen pickers (``QuickOpen``, ``DocPick``, ``SymbolPick``,
``ProjectFind``) plus a couple of inline ones drive their selection /
scroll the same way: arrow keys + page-up/down step ``selected``, mouse
wheel scrolls the visible window, and both clamp at the bounds. Without
this shared helper that block of conditionals lives in 4–5 places and
silently drifts (one of the page-up cases used to forget the
``< 0`` re-clamp after the negative ``selected -= 10``).

These helpers don't touch ``_scroll_to_selection`` or any picker-specific
layout — that stays in the call site since each picker has its own
visible-list-height calculation. The contract is: pass in the bookkeeping
state by ``mut``, and the function returns ``True`` iff it consumed the
input. The caller wraps the call in ``if picker_nav_key(...): self._scroll_to_selection(); return True``.
"""

from .events import (
    KEY_DOWN, KEY_PAGEDOWN, KEY_PAGEUP, KEY_UP,
    MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .geometry import Point, Rect
from .view import RowCursor


comptime _PAGE_STEP: Int = 10
comptime _WHEEL_STEP: Int = 3


@fieldwise_init
struct PickerLayout(ImplicitlyCopyable, Movable):
    """Pre-computed rects for a filtered-list picker, shared by ``paint``
    and ``handle_mouse`` so list hit-testing and rendering agree on the
    top/height. Built by ``build_picker_layout``; ``label_w`` is the width
    of the leading input label (``Find:`` etc.) the query field starts
    after."""
    var input_rect: Rect
    var input_label_pt: Point
    var list_top: Int
    var list_height: Int
    var hint_y: Int


def build_picker_layout(rect: Rect, label_w: Int) -> PickerLayout:
    var cursor = RowCursor(rect.a.y + 1)
    var input_y = cursor.place()
    var list_y = cursor.place()
    var hint_y = rect.b.y - 1
    var list_h = hint_y - list_y
    if list_h < 0:
        list_h = 0
    return PickerLayout(
        Rect(rect.a.x + 2 + label_w, input_y, rect.b.x - 1, input_y + 1),
        Point(rect.a.x + 2, input_y),
        list_y, list_h, hint_y,
    )


def scroll_to_reveal(scroll: Int, target: Int, window: Int) -> Int:
    """Return ``scroll`` adjusted so row ``target`` is visible in a
    ``window``-row viewport: scroll up to ``target`` when it's above the
    window, down to ``target - window + 1`` when below, never past 0.

    The "keep the selected row on screen" arithmetic shared by
    ``ListBox`` and the ``Dropdown`` popup, which each used to inline the
    same if/elif. Does NOT clamp to a maximum scroll — that needs the
    item count, so the caller applies its own upper bound afterward."""
    var s = scroll
    if target < s:
        s = target
    elif target >= s + window:
        s = target - window + 1
    if s < 0:
        s = 0
    return s


def picker_nav_key(k: UInt32, matched_len: Int, mut selected: Int) -> Bool:
    """Apply UP / DOWN / PAGEUP / PAGEDOWN to ``selected``, clamped to
    ``[0, matched_len)``. Returns ``True`` iff ``k`` was one of those
    keys (caller should consume the event and refresh scroll)."""
    if k == KEY_UP:
        if selected > 0:
            selected -= 1
        return True
    if k == KEY_DOWN:
        if selected + 1 < matched_len:
            selected += 1
        return True
    if k == KEY_PAGEUP:
        selected -= _PAGE_STEP
        if selected < 0:
            selected = 0
        return True
    if k == KEY_PAGEDOWN:
        selected += _PAGE_STEP
        if selected >= matched_len:
            selected = matched_len - 1
        if selected < 0:
            selected = 0
        return True
    return False


def picker_wheel_scroll(
    button: UInt8, mut scroll: Int, matched_len: Int, list_height: Int,
) -> Bool:
    """Apply wheel-up / wheel-down to ``scroll``, clamped to
    ``[0, max(0, matched_len - list_height)]``. Returns ``True`` iff
    ``button`` was a wheel button."""
    if button == MOUSE_WHEEL_UP:
        if scroll > 0:
            scroll -= _WHEEL_STEP
            if scroll < 0:
                scroll = 0
        return True
    if button == MOUSE_WHEEL_DOWN:
        var max_scroll = matched_len - list_height
        if max_scroll < 0:
            max_scroll = 0
        if scroll < max_scroll:
            scroll += _WHEEL_STEP
            if scroll > max_scroll:
                scroll = max_scroll
        return True
    return False
