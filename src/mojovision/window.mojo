"""Window: a managed sub-window with TV-style chrome (close, resize, move).

A ``Window`` is a value-typed widget: title, rect, and a list of content lines.
A ``WindowManager`` owns a stack of them and handles the tedious bits — z-order,
focus, click-to-front, drag-by-title-bar, resize-by-grip, close-by-button — so
the application code only has to construct them and react to higher-level events.

Visual style is hard-coded to classic Turbo Vision: white border on blue, yellow
content text, ``[■]`` close in the top-left, window number in the top-right,
``◢`` resize grip in the bottom-right.
"""

from std.collections.list import List

from .canvas import Canvas
from .cell import Cell
from .colors import Attr, BLACK, BLUE, GREEN, LIGHT_GRAY, WHITE, YELLOW
from .events import Event, EVENT_MOUSE, MOUSE_BUTTON_LEFT
from .geometry import Point, Rect


comptime MIN_WIN_W: Int = 12
comptime MIN_WIN_H: Int = 4


struct Window(ImplicitlyCopyable, Movable):
    var title: String
    var rect: Rect
    var content: List[String]
    var is_maximized: Bool
    var _restore_rect: Rect

    fn __init__(out self, var title: String, rect: Rect, var content: List[String]):
        self.title = title^
        self.rect = rect
        self.content = content^
        self.is_maximized = False
        self._restore_rect = rect

    fn __copyinit__(out self, copy: Self):
        self.title = copy.title
        self.rect = copy.rect
        self.content = copy.content.copy()
        self.is_maximized = copy.is_maximized
        self._restore_rect = copy._restore_rect

    fn toggle_maximize(mut self, workspace: Rect):
        if self.is_maximized:
            self.rect = self._restore_rect
            self.is_maximized = False
        else:
            self._restore_rect = self.rect
            self.rect = workspace
            self.is_maximized = True

    fn paint(self, mut canvas: Canvas, focused: Bool, number: Int):
        var border: Attr
        if focused:
            border = Attr(WHITE, BLUE)
        else:
            border = Attr(LIGHT_GRAY, BLUE)
        var content_attr = Attr(YELLOW, BLUE)
        var interior = self.rect.inset(1, 1)
        if not interior.is_empty():
            canvas.fill(interior, String(" "), Attr(LIGHT_GRAY, BLUE))
        # Focused windows get the classic TV double-line border; others single.
        canvas.draw_box(self.rect, border, focused)
        # Title centered on the top edge, padded with a space either side.
        # The title shares the border's colors — focusing must not flip it to a
        # contrasting reverse-video patch, only the line weight (single → double)
        # and the border brightness change.
        var title_padded = String(" ") + self.title + String(" ")
        var title_len = len(title_padded.as_bytes())
        if self.rect.width() >= title_len + 6:
            var tx = self.rect.a.x + (self.rect.width() - title_len) // 2
            _ = canvas.put_text(Point(tx, self.rect.a.y), title_padded, border)
        # Close button [■] at top-LEFT (TV convention) — focused only.
        # The ■ glyph is green like in classic Turbo Vision; brackets keep the
        # border color.
        if focused and self.rect.width() >= 8:
            var close_glyph = Attr(GREEN, BLUE)
            canvas.set(self.rect.a.x + 1, self.rect.a.y, Cell(String("["), border, 1))
            canvas.set(self.rect.a.x + 2, self.rect.a.y, Cell(String("■"), close_glyph, 1))
            canvas.set(self.rect.a.x + 3, self.rect.a.y, Cell(String("]"), border, 1))
        # Window number (and, when focused, a maximize/restore button) at top-RIGHT.
        # Format: ``<num>=[↑]`` while normal, ``<num>=[↓]`` while maximized.
        # Unfocused windows show only the bare number.
        var num_str = String(number)
        var num_len = len(num_str.as_bytes())
        if focused and self.rect.width() >= num_len + 9:
            var arrow: String
            if self.is_maximized:
                arrow = String("↓")
            else:
                arrow = String("↑")
            var indicator = num_str + String("=[") + arrow + String("]")
            _ = canvas.put_text(
                Point(self.rect.b.x - num_len - 5, self.rect.a.y),
                indicator,
                border,
            )
        elif self.rect.width() >= num_len + 6:
            _ = canvas.put_text(
                Point(self.rect.b.x - num_len - 2, self.rect.a.y),
                num_str,
                border,
            )
        # Content, left-aligned. Clipped to the interior on both axes:
        # the loop bound clips vertically; the ``max_x`` arg clips horizontally
        # so a long line can't bleed onto (or past) the right border.
        var inner_h = self.rect.height() - 2
        var content_right = self.rect.b.x - 1   # exclusive: stop before right border
        for i in range(len(self.content)):
            if i >= inner_h:
                break
            _ = canvas.put_text(
                Point(self.rect.a.x + 2, self.rect.a.y + 1 + i),
                self.content[i],
                content_attr,
                content_right,
            )

    fn close_button_hit(self, p: Point) -> Bool:
        return p.y == self.rect.a.y and self.rect.a.x + 1 <= p.x and p.x <= self.rect.a.x + 3

    fn maximize_button_hit(self, p: Point) -> Bool:
        # The `[↑]` / `[↓]` triplet sits one cell in from the right corner.
        return p.y == self.rect.a.y and self.rect.b.x - 4 <= p.x and p.x <= self.rect.b.x - 2

    fn title_bar_hit(self, p: Point) -> Bool:
        return p.y == self.rect.a.y \
            and not self.close_button_hit(p) \
            and not self.maximize_button_hit(p)

    fn resize_edges_hit(self, p: Point) -> Tuple[Bool, Bool, Bool]:
        """Which edges of the border ``p`` is on: ``(left, right, bottom)``.

        The top row is reserved for the title bar (drag-to-move), so it never
        counts as a resize edge — even at the top corners.
        """
        if p.y == self.rect.a.y:
            return (False, False, False)
        var left = (p.x == self.rect.a.x)
        var right = (p.x == self.rect.b.x - 1)
        var bottom = (p.y == self.rect.b.y - 1)
        return (left, right, bottom)


struct WindowManager(Movable):
    """Owns a z-ordered stack of Windows and handles their interaction state."""
    var windows: List[Window]
    var focused: Int
    var _dragging: Int
    var _resizing: Int
    var _resize_left: Bool
    var _resize_right: Bool
    var _resize_bottom: Bool
    var _drag_dx: Int
    var _drag_dy: Int

    fn __init__(out self):
        self.windows = List[Window]()
        self.focused = -1
        self._dragging = -1
        self._resizing = -1
        self._resize_left = False
        self._resize_right = False
        self._resize_bottom = False
        self._drag_dx = 0
        self._drag_dy = 0

    fn add(mut self, var window: Window):
        self.windows.append(window^)
        self.focused = len(self.windows) - 1

    fn focus_by_title(mut self, title: String):
        for i in range(len(self.windows)):
            if self.windows[i].title == title:
                self.focused = self._bring_to_front(i)
                return

    fn _bring_to_front(mut self, idx: Int) -> Int:
        if idx < 0 or idx >= len(self.windows):
            return -1
        var w = self.windows.pop(idx)
        self.windows.append(w^)
        return len(self.windows) - 1

    fn paint(self, mut canvas: Canvas):
        for i in range(len(self.windows)):
            if i != self.focused:
                self.windows[i].paint(canvas, False, i + 1)
        if 0 <= self.focused and self.focused < len(self.windows):
            self.windows[self.focused].paint(canvas, True, self.focused + 1)

    fn handle_mouse(mut self, event: Event, workspace: Rect) -> Bool:
        if event.kind != EVENT_MOUSE or event.button != MOUSE_BUTTON_LEFT:
            return False
        if event.pressed and not event.motion:
            return self._handle_press(event, workspace)
        elif event.pressed and event.motion:
            return self._handle_motion(event, workspace)
        else:
            self._dragging = -1
            self._resizing = -1
            self._resize_left = False
            self._resize_right = False
            self._resize_bottom = False
            return True

    fn _handle_press(mut self, event: Event, workspace: Rect) -> Bool:
        var clicked = -1
        var i = len(self.windows) - 1
        while i >= 0:
            if self.windows[i].rect.contains(event.pos):
                clicked = i
                break
            i -= 1
        if clicked < 0:
            return False
        self.focused = self._bring_to_front(clicked)
        if self.windows[self.focused].close_button_hit(event.pos):
            _ = self.windows.pop(self.focused)
            self.focused = len(self.windows) - 1
            return True
        if self.windows[self.focused].maximize_button_hit(event.pos):
            self.windows[self.focused].toggle_maximize(workspace)
            return True
        var edges = self.windows[self.focused].resize_edges_hit(event.pos)
        if edges[0] or edges[1] or edges[2]:
            self._resizing = self.focused
            self._resize_left = edges[0]
            self._resize_right = edges[1]
            self._resize_bottom = edges[2]
            return True
        if self.windows[self.focused].title_bar_hit(event.pos):
            self._dragging = self.focused
            self._drag_dx = event.pos.x - self.windows[self.focused].rect.a.x
            self._drag_dy = event.pos.y - self.windows[self.focused].rect.a.y
        return True

    fn _handle_motion(mut self, event: Event, workspace: Rect) -> Bool:
        if self._dragging >= 0:
            var width = self.windows[self._dragging].rect.width()
            var height = self.windows[self._dragging].rect.height()
            var nx = event.pos.x - self._drag_dx
            var ny = event.pos.y - self._drag_dy
            if nx < workspace.a.x: nx = workspace.a.x
            if ny < workspace.a.y: ny = workspace.a.y
            if nx + width > workspace.b.x: nx = workspace.b.x - width
            if ny + height > workspace.b.y: ny = workspace.b.y - height
            self.windows[self._dragging].rect = Rect(nx, ny, nx + width, ny + height)
            self.windows[self._dragging].is_maximized = False
            return True
        if self._resizing >= 0:
            var rect = self.windows[self._resizing].rect
            var ax = rect.a.x
            var ay = rect.a.y
            var bx = rect.b.x
            var by = rect.b.y
            if self._resize_left:
                ax = event.pos.x
                if ax < workspace.a.x: ax = workspace.a.x
                if bx - ax < MIN_WIN_W: ax = bx - MIN_WIN_W
            if self._resize_right:
                bx = event.pos.x + 1
                if bx > workspace.b.x: bx = workspace.b.x
                if bx - ax < MIN_WIN_W: bx = ax + MIN_WIN_W
            if self._resize_bottom:
                by = event.pos.y + 1
                if by > workspace.b.y: by = workspace.b.y
                if by - ay < MIN_WIN_H: by = ay + MIN_WIN_H
            self.windows[self._resizing].rect = Rect(ax, ay, bx, by)
            self.windows[self._resizing].is_maximized = False
            return True
        return False
