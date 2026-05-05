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

from .canvas import Canvas, utf8_codepoint_count, wrap_to_width
from .cell import Cell
from .colors import Attr, BLACK, LIGHT_GRAY
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE, KEY_ENTER, KEY_ESC,
)
from .geometry import Point, Rect
from .text_field import TextField
from .window import paint_drop_shadow


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

    fn __init__(out self):
        self.label = String("")
        self.input = TextField()
        self.active = False
        self.submitted = False
        self._input_rect = Rect(0, 0, 0, 0)

    fn open(
        mut self,
        var label: String,
        var prefill: String = String(""),
        select_prefill: Bool = False,
    ):
        """Open the prompt with ``label`` and an optional ``prefill``.

        ``select_prefill=True`` leaves the prefilled text fully selected
        so the next typed key replaces it — used by Find when seeded
        from the editor's current selection, where the user almost
        always wants to either keep it (Enter) or type something else.
        """
        self.label = label^
        self.input = TextField()
        self.input.set_text(prefill^)
        if select_prefill:
            self.input.select_all()
        self.active = True
        self.submitted = False
        self._input_rect = Rect(0, 0, 0, 0)

    fn close(mut self):
        self.active = False
        self.submitted = False
        self.label = String("")
        self.input = TextField()
        self._input_rect = Rect(0, 0, 0, 0)

    fn _layout(self, screen: Rect) -> Rect:
        """Compute the dialog rect for the current label.

        Width caps at ``_DEFAULT_WIDTH`` (or whatever the screen
        allows); height grows to fit the wrapped label. Paint reads
        the same numbers — kept here so the cursor row and the
        painter agree even when the label is long enough to wrap.
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

    fn paint(mut self, mut canvas: Canvas, screen: Rect):
        if not self.active:
            return
        var attr = Attr(BLACK, LIGHT_GRAY)
        var rect = self._layout(screen)
        paint_drop_shadow(canvas, rect)
        canvas.fill(rect, String(" "), attr)
        canvas.draw_box(rect, attr, False)
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
        var ir = Rect(input_x, input_y, clip_x, input_y + 1)
        self._input_rect = ir
        self.input.paint(canvas, ir, True)

    fn handle_key(mut self, event: Event) -> Bool:
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

    fn handle_mouse(mut self, event: Event, screen: Rect) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_MOUSE:
            return True
        if self._input_rect.width() <= 0:
            return True
        _ = self.input.handle_mouse(event, self._input_rect)
        return True
