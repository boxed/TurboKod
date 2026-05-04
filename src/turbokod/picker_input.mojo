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


comptime _PAGE_STEP: Int = 10
comptime _WHEEL_STEP: Int = 3


fn picker_nav_key(k: UInt32, matched_len: Int, mut selected: Int) -> Bool:
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


fn picker_wheel_scroll(
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
