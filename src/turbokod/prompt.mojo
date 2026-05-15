"""Simple modal prompt for commands like Find and Go-to-Line.

Open it with ``open(label)`` to capture all subsequent key events. The user
types into ``input``; Enter sets ``submitted=True`` (the caller reads
``input.text`` and then calls ``close()``); Esc closes without submitting.

The dialog is 60 columns wide. A short ``label`` shares the line with the
input (``Find: ▮``); a label that doesn't fit in 60 cells goes through
``Canvas.put_wrapped_text`` and the input drops onto its own line below.
Both layouts read off the same ``wrap_to_width`` framework primitive, so
confirm prompts that embed a long install command stay inside the
dialog instead of bleeding across the workspace.

The input strip is a full ``TextField`` — arrow keys, word jumps,
Home/End, selection (shift+arrow), Cmd+A select-all, and mouse
positioning all behave the same as in any editor field.
"""

from .buttons import (
    BUTTON_FIRED, OptionToggle, paint_option_toggle,
)
from .canvas import Canvas, paint_drop_shadow, utf8_codepoint_count, wrap_to_width
from .painter import Painter
from .cell import Cell
from .colors import Attr, BLACK, LIGHT_GRAY, WHITE, YELLOW
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE, KEY_ENTER, KEY_ESC,
)
from .geometry import Point, Rect
from .search_options import SearchOptions
from .text_field import TextField


comptime _DEFAULT_WIDTH = 60
comptime _MIN_INLINE_INPUT = 10
"""Cells reserved for the input strip when the label shares its row.
Below this we drop the input onto its own line so the user always has a
visible place to type."""


struct Prompt(Movable):
    var label: String
    var input: TextField
    var active: Bool
    var submitted: Bool
    # Cached rect for the input strip, captured on the most recent
    # ``paint`` so ``handle_mouse`` can route clicks back to the
    # field without re-running the layout. Negative width means "no
    # paint yet" — mouse handling falls back to a no-op.
    var _input_rect: Rect
    # Search-mode toggles. The three flags persist across ``open()``
    # calls so the user's "Cc"/"W"/".*" choice carries from one Find
    # to the next; ``show_options`` decides whether they actually
    # render and consume mouse events for the current prompt session
    # (Find / Replace turn it on; Go-to-Line and other prompts do
    # not). Tooltip text comes from each toggle's ``tooltip`` field
    # and is painted on the row below the input whenever a toggle is
    # under the cursor.
    var show_options: Bool
    var toggle_case: OptionToggle
    var toggle_word: OptionToggle
    var toggle_regex: OptionToggle

    def __init__(out self):
        self.label = String("")
        self.input = TextField()
        self.active = False
        self.submitted = False
        self._input_rect = Rect(0, 0, 0, 0)
        self.show_options = False
        self.toggle_case = OptionToggle(
            String("Cc"), String("Match case"),
        )
        self.toggle_word = OptionToggle(
            String("W"), String("Whole word"),
        )
        self.toggle_regex = OptionToggle(
            String(".*"), String("Regular expression"),
        )

    def open(
        mut self,
        var label: String,
        var prefill: String = String(""),
        select_prefill: Bool = False,
        show_options: Bool = False,
    ):
        """Open the prompt with ``label`` and an optional ``prefill``.

        ``select_prefill=True`` leaves the prefilled text fully selected
        so the next typed key replaces it — used by Find when seeded
        from the editor's current selection, where the user almost
        always wants to either keep it (Enter) or type something else.

        ``show_options=True`` paints the search-mode toggles on the
        right edge of the input row. The toggle state persists across
        opens so the user keeps their last choice; pass False (the
        default) for non-search prompts so the toggles stay hidden.
        """
        self.label = label^
        self.input = TextField()
        self.input.set_text(prefill^)
        if select_prefill:
            self.input.select_all()
        self.active = True
        self.submitted = False
        self._input_rect = Rect(0, 0, 0, 0)
        self.show_options = show_options

    def close(mut self):
        self.active = False
        self.submitted = False
        self.label = String("")
        self.input = TextField()
        self._input_rect = Rect(0, 0, 0, 0)
        self.show_options = False
        # Drop hover state so a stale tooltip doesn't pop the next time
        # the prompt opens before the cursor has moved.
        self.toggle_case.hovered = False
        self.toggle_word.hovered = False
        self.toggle_regex.hovered = False

    def search_options(self) -> SearchOptions:
        """Read back the toggle states as a ``SearchOptions``. Caller
        uses this after Enter to drive ``find_next`` / ``replace_all``."""
        return SearchOptions(
            self.toggle_case.on,
            self.toggle_word.on,
            self.toggle_regex.on,
        )

    def set_search_options(mut self, opts: SearchOptions):
        """Restore toggle states from a previously captured
        ``SearchOptions``. Used to seed a fresh prompt with whatever
        flags the user had on for the previous Find."""
        self.toggle_case.on = opts.case_sensitive
        self.toggle_word.on = opts.whole_word
        self.toggle_regex.on = opts.regex

    def _layout(self, screen: Rect) -> Rect:
        """Compute the dialog rect for the current label.

        Width caps at ``_DEFAULT_WIDTH`` (or whatever the screen
        allows); height grows to fit the wrapped label. Paint reads
        the same numbers — kept here so the cursor row and the
        painter agree even when the label is long enough to wrap.

        With ``show_options=True`` the dialog reserves an extra row
        below the input for the toggle tooltip strip (always present
        so the layout doesn't jump when the user hovers a toggle).
        """
        var width = _DEFAULT_WIDTH
        if width > screen.b.x - 4:
            width = screen.b.x - 4
        if width < 8:
            width = 8
        var text_w = width - 4
        if text_w < 1:
            text_w = 1
        var label_lines = wrap_to_width(self.label, text_w)
        var inline = False
        if len(label_lines) <= 1:
            var lw = 0
            if len(label_lines) == 1:
                lw = utf8_codepoint_count(label_lines[0])
            if lw + _MIN_INLINE_INPUT <= text_w:
                inline = True
        var height: Int
        if inline:
            height = 3
        else:
            var lines = len(label_lines)
            if lines < 1:
                lines = 1
            height = 2 + lines + 1   # top border + label rows + input row + bottom
        if self.show_options:
            height += 1   # toggle-tooltip row under the input
        if height > screen.b.y - 4:
            height = screen.b.y - 4
        if height < 3:
            height = 3
        var x = (screen.b.x - width) // 2
        var y = (screen.b.y - height) // 2
        if x < 0:
            x = 0
        if y < 0:
            y = 0
        return Rect(x, y, x + width, y + height)

    def paint(mut self, mut canvas: Canvas, screen: Rect):
        if not self.active:
            return
        var attr = Attr(BLACK, LIGHT_GRAY)
        var rect = self._layout(screen)
        paint_drop_shadow(canvas, rect)
        var painter = Painter(rect)
        painter.fill(canvas, rect, String(" "), attr)
        painter.draw_box(canvas, rect, attr, False)
        var content_x = rect.a.x + 2
        var clip_x = rect.b.x - 1
        var text_w = rect.width() - 4
        if text_w < 1:
            text_w = 1
        var label_lines = wrap_to_width(self.label, text_w)
        var inline = False
        var last_label_w = 0
        if len(label_lines) <= 1:
            if len(label_lines) == 1:
                last_label_w = utf8_codepoint_count(label_lines[0])
            if last_label_w + _MIN_INLINE_INPUT <= text_w:
                inline = True
        var max_label_rows = rect.height() - 2
        if not inline:
            max_label_rows -= 1   # reserve a row for the input
        if max_label_rows < 0:
            max_label_rows = 0
        # Paint the label through the canvas's wrap primitive so this
        # path can never paint outside the dialog interior, even if
        # ``wrap_to_width`` produces more lines than we have rows for.
        var label_rect = Rect(
            content_x, rect.a.y + 1,
            clip_x, rect.a.y + 1 + max_label_rows,
        )
        var visible = canvas.put_wrapped_text(label_rect, self.label, attr)
        var input_y: Int
        var input_x: Int
        if inline:
            input_y = rect.a.y + 1
            input_x = content_x + last_label_w
        else:
            input_y = rect.a.y + 1 + visible
            input_x = content_x
        if input_y >= rect.b.y - 1:
            # No room for the input row; clamp to the last interior row
            # so we still draw a cursor instead of silently dropping it.
            input_y = rect.b.y - 2
            if input_y < rect.a.y + 1:
                input_y = rect.a.y + 1
        var input_right = clip_x
        if self.show_options:
            # Lay the three toggles out right-aligned with one cell of
            # gap between each, then shrink the input field's right
            # edge so the cursor never overruns the toggles.
            var gap = 1
            var total_w = self.toggle_case.width() \
                + gap + self.toggle_word.width() \
                + gap + self.toggle_regex.width()
            var tx = clip_x - total_w
            self.toggle_case.move_to(tx, input_y)
            tx += self.toggle_case.width() + gap
            self.toggle_word.move_to(tx, input_y)
            tx += self.toggle_word.width() + gap
            self.toggle_regex.move_to(tx, input_y)
            input_right = self.toggle_case.x - 1
            if input_right < input_x + 1:
                input_right = input_x + 1
        var ir = Rect(input_x, input_y, input_right, input_y + 1)
        self._input_rect = ir
        self.input.paint(canvas, ir, True)
        if self.show_options:
            # Toggles paint after the input so any cursor on the
            # rightmost input cell can't bleed over them. Off state
            # uses the dialog body color; on state inverts to the
            # standard yellow chip.
            var off_attr = attr   # BLACK on LIGHT_GRAY
            var on_attr  = Attr(BLACK, YELLOW)
            paint_option_toggle(canvas, self.toggle_case, off_attr, on_attr, clip_x)
            paint_option_toggle(canvas, self.toggle_word, off_attr, on_attr, clip_x)
            paint_option_toggle(canvas, self.toggle_regex, off_attr, on_attr, clip_x)
            # Tooltip row under the input. Always painted (blank when
            # nothing is hovered) so the dialog's height doesn't jump
            # as the cursor moves over the chips.
            var tip_y = input_y + 1
            if tip_y < rect.b.y - 1:
                var tip = String("")
                if self.toggle_case.hovered:
                    tip = self.toggle_case.tooltip
                elif self.toggle_word.hovered:
                    tip = self.toggle_word.tooltip
                elif self.toggle_regex.hovered:
                    tip = self.toggle_regex.tooltip
                # Clear the row first so the previous frame's tooltip
                # never lingers when the cursor leaves a chip.
                painter.fill(
                    canvas, Rect(content_x, tip_y, clip_x, tip_y + 1),
                    String(" "), attr,
                )
                if len(tip.as_bytes()) > 0:
                    _ = painter.put_text(
                        canvas, Point(content_x, tip_y), tip, attr,
                    )

    def handle_key(mut self, event: Event) -> Bool:
        """Returns True if the event was consumed by the prompt."""
        if not self.active:
            return False
        if event.kind != EVENT_KEY:
            return True   # swallow non-keys while modal
        var k = event.key
        if k == KEY_ENTER:
            self.submitted = True
            return True
        if k == KEY_ESC:
            self.close()
            return True
        var r = self.input.handle_key(event)
        if r.consumed:
            return True
        return True

    def handle_mouse(mut self, event: Event, screen: Rect) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_MOUSE:
            return True
        if self.show_options:
            # Route through the toggles first so a click on a chip
            # doesn't leak into the input field below. ``handle_mouse``
            # also updates ``hovered`` on every event so bare motion
            # under xterm 1003 mode pops the tooltip on the next paint.
            var rc = self.toggle_case.handle_mouse(event)
            if rc == BUTTON_FIRED:
                self.toggle_case.on = not self.toggle_case.on
                return True
            var rw = self.toggle_word.handle_mouse(event)
            if rw == BUTTON_FIRED:
                self.toggle_word.on = not self.toggle_word.on
                return True
            var rr = self.toggle_regex.handle_mouse(event)
            if rr == BUTTON_FIRED:
                self.toggle_regex.on = not self.toggle_regex.on
                return True
            # If any toggle has captured the press, swallow the event
            # so the input field doesn't try to position the cursor
            # while the user is dragging on a chip.
            if self.toggle_case.pressed or self.toggle_word.pressed \
                    or self.toggle_regex.pressed:
                return True
        if self._input_rect.width() <= 0:
            return True
        _ = self.input.handle_mouse(event, self._input_rect)
        return True
