"""Simple single-line modal prompt for commands like Find and Go-to-Line.

Open it with ``open(label)`` to capture all subsequent key events. The user
types into ``input``; Enter sets ``submitted=True`` (the caller reads
``input`` and then calls ``close()``); Esc closes without submitting.
"""

from .canvas import Canvas
from .cell import Cell
from .colors import Attr, BLACK, LIGHT_GRAY
from .events import (
    Event, EVENT_KEY, KEY_BACKSPACE, KEY_ENTER, KEY_ESC,
)
from .geometry import Point, Rect
from .text_field import text_field_clipboard_key
from .window import paint_drop_shadow


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

    fn paint(self, mut canvas: Canvas, screen: Rect):
        if not self.active:
            return
        var attr = Attr(BLACK, LIGHT_GRAY)
        var input_attr = Attr(BLACK, LIGHT_GRAY)
        var width = 60
        if width > screen.b.x - 4: width = screen.b.x - 4
        var x = (screen.b.x - width) // 2
        var y = (screen.b.y - 3) // 2
        var rect = Rect(x, y, x + width, y + 3)
        paint_drop_shadow(canvas, rect)
        canvas.fill(rect, String(" "), attr)
        canvas.draw_box(rect, attr, False)
        var label_x = x + 2
        _ = canvas.put_text(Point(label_x, y + 1), self.label, attr)
        var input_x = label_x + len(self.label.as_bytes())
        _ = canvas.put_text(
            Point(input_x, y + 1), self.input, input_attr, x + width - 1,
        )
        # Reverse-video cursor at end of input.
        var cur_x = input_x + len(self.input.as_bytes())
        if cur_x < x + width - 1:
            canvas.set(cur_x, y + 1, Cell(String(" "), Attr(LIGHT_GRAY, BLACK), 1))

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
