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


struct MenuItem(ImplicitlyCopyable, Movable):
    var label: String
    var action: String
    var is_separator: Bool
    var shortcut: String     # rendered right-aligned in the dropdown

    fn __init__(
        out self,
        var label: String,
        var action: String,
        is_separator: Bool = False,
    ):
        self.label = label^
        self.action = action^
        self.is_separator = is_separator
        self.shortcut = String("")

    @staticmethod
    fn separator() -> Self:
        """Build a non-interactive divider for grouping items in a dropdown."""
        return MenuItem(String(""), String(""), True)

    fn __copyinit__(out self, copy: Self):
        self.label = copy.label
        self.action = copy.action
        self.is_separator = copy.is_separator
        self.shortcut = copy.shortcut


struct Menu(ImplicitlyCopyable, Movable):
    var label: String
    var items: List[MenuItem]
    var visible: Bool
    var right_aligned: Bool

    fn __init__(
        out self,
        var label: String,
        var items: List[MenuItem],
        right_aligned: Bool = False,
    ):
        self.label = label^
        self.items = items^
        self.visible = True
        self.right_aligned = right_aligned

    fn __copyinit__(out self, copy: Self):
        self.label = copy.label
        self.items = copy.items.copy()
        self.visible = copy.visible
        self.right_aligned = copy.right_aligned


@fieldwise_init
struct MenuResult(Movable):
    """What ``MenuBar.handle_event`` returns: the clicked action and whether
    the menu bar consumed the event (so the caller knows not to forward it)."""
    var action: Optional[String]
    var consumed: Bool


fn _menu_rank(label: String) -> Int:
    """Display order rank for a left-aligned menu.

    Smaller rank → further left. Pinned slots are spread far apart so future
    custom rules can slot between them without colliding with each other.
    The framework treats all four labels case-sensitively; menus with any
    other label fall into the middle slot in insertion order.
    """
    if label == String("File"):    return 0
    if label == String("Edit"):    return 10
    if label == String("Window"):  return 90
    if label == String("Help"):    return 100
    return 50


struct MenuBar(Movable):
    var menus: List[Menu]
    var open_idx: Int

    fn __init__(out self):
        self.menus = List[Menu]()
        self.open_idx = -1

    fn add(mut self, var menu: Menu):
        self.menus.append(menu^)

    fn set_visible_by_label(mut self, label: String, visible: Bool):
        for i in range(len(self.menus)):
            if self.menus[i].label == label:
                self.menus[i].visible = visible
                if not visible and self.open_idx == i:
                    self.open_idx = -1
                return

    fn is_open(self) -> Bool:
        return self.open_idx >= 0

    fn close(mut self):
        self.open_idx = -1

    # --- layout ------------------------------------------------------------

    fn _layout(self, screen_width: Int) -> List[Rect]:
        """Per-menu hit-test rects. Hidden menus get an empty rect at (0,0).

        Left-aligned menus pack from x=3 rightward; right-aligned menus pack
        from x=screen_width leftward. Left-aligned menus are sorted by rank
        (File → Edit → other → Window → Help) at layout time so insertion
        order doesn't matter; rank ties preserve insertion order. The
        ``self.menus`` list is *not* reshuffled, so any external indices
        (e.g., a Desktop's cached project / window menu index) stay valid.
        On a very narrow screen the two groups may visually overlap.
        """
        var rects = List[Rect]()
        for _ in range(len(self.menus)):
            rects.append(Rect(0, 0, 0, 0))
        # Collect left-aligned visible indices and insertion-sort by rank.
        var left = List[Int]()
        for i in range(len(self.menus)):
            if self.menus[i].visible and not self.menus[i].right_aligned:
                left.append(i)
        for i in range(1, len(left)):
            var j = i
            while j > 0:
                var ra = _menu_rank(self.menus[left[j]].label)
                var rb = _menu_rank(self.menus[left[j - 1]].label)
                if ra >= rb:
                    break
                var tmp = left[j]
                left[j] = left[j - 1]
                left[j - 1] = tmp
                j -= 1
        var x = 3                                   # past `≡ `
        for k in range(len(left)):
            var i = left[k]
            var w = len(self.menus[i].label.as_bytes()) + 2
            rects[i] = Rect(x, 0, x + w, 1)
            x += w + 1
        var rx = screen_width
        for i in range(len(self.menus)):
            if not self.menus[i].visible or not self.menus[i].right_aligned:
                continue
            var w = len(self.menus[i].label.as_bytes()) + 2
            rects[i] = Rect(rx - w, 0, rx, 1)
            rx -= w + 1
        return rects^

    fn _dropdown_rect(self, screen_width: Int) -> Rect:
        if self.open_idx < 0:
            return Rect(0, 0, 0, 0)
        var anchor = self._layout(screen_width)[self.open_idx]
        var menu = self.menus[self.open_idx]
        # Width = max(2 + label + 2, 2 + label + gap + shortcut + 2). The +4
        # constant covers left padding, right padding; the +6 form adds the
        # 2-cell gap that separates the label from the shortcut.
        var width = 8
        for i in range(len(menu.items)):
            if menu.items[i].is_separator:
                continue
            var label_w = len(menu.items[i].label.as_bytes())
            var sc_w = len(menu.items[i].shortcut.as_bytes())
            var w = label_w + 4
            if sc_w > 0:
                w = label_w + sc_w + 6
            if w > width:
                width = w
        var height = len(menu.items) + 2
        if menu.right_aligned:
            # Anchor the dropdown's right edge to the label's right edge so
            # it never spills off-screen.
            return Rect(anchor.b.x - width, 1, anchor.b.x, 1 + height)
        return Rect(anchor.a.x, 1, anchor.a.x + width, 1 + height)

    # --- paint -------------------------------------------------------------

    fn paint(self, mut canvas: Canvas, screen: Rect):
        var bar      = Attr(BLACK, LIGHT_GRAY)
        var bar_key  = Attr(RED,   LIGHT_GRAY)
        var open_bg  = Attr(BLACK, GREEN)
        var open_key = Attr(WHITE, GREEN)
        canvas.fill(Rect(0, 0, screen.b.x, 1), String(" "), bar)
        canvas.set(1, 0, Cell(String("≡"), bar, 1))
        var rects = self._layout(screen.b.x)
        for i in range(len(self.menus)):
            if not self.menus[i].visible:
                continue
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
            self._paint_dropdown(canvas, screen.b.x)

    fn _paint_dropdown(self, mut canvas: Canvas, screen_width: Int):
        var rect = self._dropdown_rect(screen_width)
        var attr     = Attr(BLACK, LIGHT_GRAY)
        var attr_key = Attr(RED,   LIGHT_GRAY)
        canvas.fill(rect, String(" "), attr)
        canvas.draw_box(rect, attr, False)
        var menu = self.menus[self.open_idx]
        for i in range(len(menu.items)):
            var y = rect.a.y + 1 + i
            if menu.items[i].is_separator:
                # Horizontal divider across the dropdown's interior.
                for x in range(rect.a.x + 1, rect.b.x - 1):
                    canvas.set(x, y, Cell(String("─"), attr, 1))
                continue
            var label_bytes = menu.items[i].label.as_bytes()
            for j in range(len(label_bytes)):
                var ch = String(chr(Int(label_bytes[j])))
                var a = attr_key if j == 0 else attr
                canvas.set(rect.a.x + 2 + j, y, Cell(ch, a, 1))
            # Right-aligned shortcut text — last cell sits at rect.b.x - 2
            # (one in from the right border), so the start x is computed
            # backwards from there. ``_dropdown_rect`` already widened the
            # rect to guarantee no overlap with the label.
            var sc = menu.items[i].shortcut
            var sc_w = len(sc.as_bytes())
            if sc_w > 0:
                var sx = rect.b.x - 1 - sc_w
                _ = canvas.put_text(Point(sx, y), sc, attr, rect.b.x - 1)

    # --- events ------------------------------------------------------------

    fn handle_event(mut self, event: Event, screen_width: Int) -> MenuResult:
        if event.kind != EVENT_MOUSE or event.button != MOUSE_BUTTON_LEFT:
            return MenuResult(Optional[String](), False)
        if not (event.pressed and not event.motion):
            return MenuResult(Optional[String](), False)
        # Click on the menu-bar row toggles a menu open/closed.
        if event.pos.y == 0:
            var rects = self._layout(screen_width)
            for i in range(len(rects)):
                if not self.menus[i].visible:
                    continue
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
            var dr = self._dropdown_rect(screen_width)
            if dr.contains(event.pos):
                var item_idx = event.pos.y - dr.a.y - 1
                if 0 <= item_idx and item_idx < len(self.menus[self.open_idx].items):
                    var item = self.menus[self.open_idx].items[item_idx]
                    if item.is_separator:
                        # Click on a divider: eat the event, leave menu open.
                        return MenuResult(Optional[String](), True)
                    var action = item.action
                    self.open_idx = -1
                    return MenuResult(Optional[String](action), True)
                return MenuResult(Optional[String](), True)
            self.open_idx = -1
            return MenuResult(Optional[String](), True)
        return MenuResult(Optional[String](), False)
