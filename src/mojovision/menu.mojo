"""Menu bar with Turbo-Vision-style hotkey rendering and dropdown handling.

A `MenuBar` owns a list of `Menu`s, each holding `MenuItem`s. It paints itself
across the top row (with the system-menu marker, hotkey letters in red, and a
green-highlighted open menu) and exposes one ``handle_event`` entry point that
returns the action string of any clicked item.
"""

from std.collections.list import List
from std.collections.optional import Optional

from .canvas import Canvas
from .cell import Cell
from .colors import Attr, BLACK, GREEN, LIGHT_GRAY, RED, WHITE
from .events import Event, EVENT_MOUSE, MOUSE_BUTTON_LEFT
from .geometry import Point, Rect


@fieldwise_init
struct MenuItem(ImplicitlyCopyable, Movable):
    var label: String
    var action: String


struct Menu(ImplicitlyCopyable, Movable):
    var label: String
    var items: List[MenuItem]

    fn __init__(out self, var label: String, var items: List[MenuItem]):
        self.label = label^
        self.items = items^

    fn __copyinit__(out self, copy: Self):
        self.label = copy.label
        self.items = copy.items.copy()


@fieldwise_init
struct MenuResult(Movable):
    """What ``MenuBar.handle_event`` returns: the clicked action and whether
    the menu bar consumed the event (so the caller knows not to forward it)."""
    var action: Optional[String]
    var consumed: Bool


struct MenuBar(Movable):
    var menus: List[Menu]
    var open_idx: Int

    fn __init__(out self):
        self.menus = List[Menu]()
        self.open_idx = -1

    fn add(mut self, var menu: Menu):
        self.menus.append(menu^)

    fn is_open(self) -> Bool:
        return self.open_idx >= 0

    fn close(mut self):
        self.open_idx = -1

    # --- layout ------------------------------------------------------------

    fn _layout(self) -> List[Rect]:
        var rects = List[Rect]()
        var x = 3                                   # past `≡ `
        for i in range(len(self.menus)):
            var w = len(self.menus[i].label.as_bytes()) + 2
            rects.append(Rect(x, 0, x + w, 1))
            x += w + 1
        return rects^

    fn _dropdown_rect(self) -> Rect:
        if self.open_idx < 0:
            return Rect(0, 0, 0, 0)
        var anchor = self._layout()[self.open_idx]
        var menu = self.menus[self.open_idx]
        var width = 8
        for i in range(len(menu.items)):
            var w = len(menu.items[i].label.as_bytes()) + 4
            if w > width:
                width = w
        var height = len(menu.items) + 2
        return Rect(anchor.a.x, 1, anchor.a.x + width, 1 + height)

    # --- paint -------------------------------------------------------------

    fn paint(self, mut canvas: Canvas, screen: Rect):
        var bar      = Attr(BLACK, LIGHT_GRAY)
        var bar_key  = Attr(RED,   LIGHT_GRAY)
        var open_bg  = Attr(BLACK, GREEN)
        var open_key = Attr(WHITE, GREEN)
        canvas.fill(Rect(0, 0, screen.b.x, 1), String(" "), bar)
        canvas.set(1, 0, Cell(String("≡"), bar, 1))
        var rects = self._layout()
        for i in range(len(self.menus)):
            var bg: Attr
            var key: Attr
            if i == self.open_idx:
                bg = open_bg; key = open_key
            else:
                bg = bar; key = bar_key
            var r = rects[i]
            canvas.set(r.a.x, 0, Cell(String(" "), bg, 1))
            var label_bytes = self.menus[i].label.as_bytes()
            for j in range(len(label_bytes)):
                var ch = String(chr(Int(label_bytes[j])))
                var attr = key if j == 0 else bg
                canvas.set(r.a.x + 1 + j, 0, Cell(ch, attr, 1))
            canvas.set(r.b.x - 1, 0, Cell(String(" "), bg, 1))
        if self.open_idx >= 0:
            self._paint_dropdown(canvas)

    fn _paint_dropdown(self, mut canvas: Canvas):
        var rect = self._dropdown_rect()
        var attr     = Attr(BLACK, LIGHT_GRAY)
        var attr_key = Attr(RED,   LIGHT_GRAY)
        canvas.fill(rect, String(" "), attr)
        canvas.draw_box(rect, attr, False)
        var menu = self.menus[self.open_idx]
        for i in range(len(menu.items)):
            var label_bytes = menu.items[i].label.as_bytes()
            var y = rect.a.y + 1 + i
            for j in range(len(label_bytes)):
                var ch = String(chr(Int(label_bytes[j])))
                var a = attr_key if j == 0 else attr
                canvas.set(rect.a.x + 2 + j, y, Cell(ch, a, 1))

    # --- events ------------------------------------------------------------

    fn handle_event(mut self, event: Event) -> MenuResult:
        if event.kind != EVENT_MOUSE or event.button != MOUSE_BUTTON_LEFT:
            return MenuResult(Optional[String](), False)
        if not (event.pressed and not event.motion):
            return MenuResult(Optional[String](), False)
        # Click on the menu-bar row toggles a menu open/closed.
        if event.pos.y == 0:
            var rects = self._layout()
            for i in range(len(rects)):
                if rects[i].contains(event.pos):
                    if i == self.open_idx:
                        self.open_idx = -1
                    else:
                        self.open_idx = i
                    return MenuResult(Optional[String](), True)
            # Click on the bar but not on a menu name still belongs to us.
            return MenuResult(Optional[String](), True)
        # Click anywhere while a menu is open: dropdown item, or close.
        if self.open_idx >= 0:
            var dr = self._dropdown_rect()
            if dr.contains(event.pos):
                var item_idx = event.pos.y - dr.a.y - 1
                if 0 <= item_idx and item_idx < len(self.menus[self.open_idx].items):
                    var action = self.menus[self.open_idx].items[item_idx].action
                    self.open_idx = -1
                    return MenuResult(Optional[String](action), True)
                return MenuResult(Optional[String](), True)
            self.open_idx = -1
            return MenuResult(Optional[String](), True)
        return MenuResult(Optional[String](), False)
