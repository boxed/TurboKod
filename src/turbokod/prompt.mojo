"""Simple modal prompt for commands like Find and Go-to-Line.

Open it with ``open(label)`` to capture all subsequent key events. The user
types into ``input``; Enter sets ``submitted=True`` (the caller reads
``input`` and then calls ``close()``); Esc closes without submitting.

The dialog is 60 columns wide. A short ``label`` shares the line with the
input (``Find: ▮``); a label that doesn't fit in 60 cells goes through
``Canvas.put_wrapped_text`` and the input drops onto its own line below.
Both layouts read off the same ``wrap_to_width`` framework primitive, so
confirm prompts that embed a long install command stay inside the
dialog instead of bleeding across the workspace.
"""

from .canvas import Canvas, utf8_codepoint_count, wrap_to_width
from .cell import Cell
from .colors import Attr, BLACK, LIGHT_GRAY
from .events import (
    Event, EVENT_KEY, KEY_BACKSPACE, KEY_ENTER, KEY_ESC,
)
from .geometry import Point, Rect
from .text_field import text_field_clipboard_key
from .window import paint_drop_shadow


comptime _DEFAULT_WIDTH = 60
comptime _MIN_INLINE_INPUT = 10
"""Cells reserved for the input strip when the label shares its row.
Below this we drop the input onto its own line so the user always has a
visible place to type."""


struct Prompt(Movable):
    var label: String
    var input: String
    var active: Bool
    var submitted: Bool

    fn __init__(out self):
        self.label = String("")
        self.input = String("")
        self.active = False
        self.submitted = False

    fn open(mut self, var label: String, var prefill: String = String("")):
        self.label = label^
        self.input = prefill^
        self.active = True
        self.submitted = False

    fn close(mut self):
        self.active = False
        self.submitted = False
        self.label = String("")
        self.input = String("")

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

    fn paint(self, mut canvas: Canvas, screen: Rect):
        if not self.active:
            return
        var attr = Attr(BLACK, LIGHT_GRAY)
        var input_attr = Attr(BLACK, LIGHT_GRAY)
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
        _ = canvas.put_text(
            Point(input_x, input_y), self.input, input_attr, clip_x,
        )
        # Reverse-video cursor at end of input.
        var cur_x = input_x + utf8_codepoint_count(self.input)
        if cur_x < clip_x:
            canvas.set(
                cur_x, input_y,
                Cell(String(" "), Attr(LIGHT_GRAY, BLACK), 1),
            )

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
        var clip = text_field_clipboard_key(event, self.input)
        if clip.consumed:
            return True
        if k == KEY_BACKSPACE:
            var bytes = self.input.as_bytes()
            if len(bytes) > 0:
                self.input = String(StringSlice(
                    unsafe_from_utf8=bytes[:len(bytes) - 1]
                ))
            return True
        if UInt32(0x20) <= k and k < UInt32(0x7F):
            self.input = self.input + chr(Int(k))
            return True
        return True
