"""Status bar with classic F-key shortcut display."""

from std.collections.list import List

from .canvas import Canvas
from .colors import Attr, BLACK, LIGHT_GRAY, RED, YELLOW
from .geometry import Point, Rect


@fieldwise_init
struct StatusItem(ImplicitlyCopyable, Movable):
    var key: String
    var desc: String


struct StatusBar(Movable):
    var items: List[StatusItem]
    var message: String         # right-aligned diagnostic / status text
    var message_attr: Attr      # color for the diagnostic; default = subtle

    fn __init__(out self):
        self.items = List[StatusItem]()
        self.message = String("")
        self.message_attr = Attr(BLACK, LIGHT_GRAY)

    fn add(mut self, var key: String, var desc: String):
        self.items.append(StatusItem(key^, desc^))

    fn set_message(mut self, var text: String, attr: Attr):
        """Set the right-aligned status text (LSP state, errors, etc.)."""
        self.message = text^
        self.message_attr = attr

    fn paint(self, mut canvas: Canvas, screen: Rect):
        # Same palette as the menu bar: dark text on light gray, hot keys in red.
        var bg = Attr(BLACK, LIGHT_GRAY)
        var key_attr = Attr(RED, LIGHT_GRAY)
        var desc_attr = Attr(BLACK, LIGHT_GRAY)
        var y = screen.b.y - 1
        canvas.fill(Rect(0, y, screen.b.x, screen.b.y), String(" "), bg)
        var x = 1
        for i in range(len(self.items)):
            var k = self.items[i].key
            var d = self.items[i].desc
            _ = canvas.put_text(Point(x, y), k, key_attr)
            x += len(k.as_bytes()) + 1
            _ = canvas.put_text(Point(x, y), d, desc_attr)
            x += len(d.as_bytes()) + 2
        # Right-aligned status message — clamped so it never collides with
        # the F-key list on narrow terminals (left side wins).
        if len(self.message.as_bytes()) > 0:
            var msg_w = len(self.message.as_bytes())
            var mx = screen.b.x - msg_w - 1
            if mx < x + 1:
                return
            _ = canvas.put_text(Point(mx, y), self.message, self.message_attr)
