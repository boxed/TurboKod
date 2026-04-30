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
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_DOWN, KEY_ENTER, KEY_LEFT, KEY_RIGHT, KEY_UP,
    MOUSE_BUTTON_LEFT, MOUSE_BUTTON_NONE,
)
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
    var selected_item: Int   # row index inside the open dropdown (kbd nav / hover)
    var tracking: Bool       # True between mouse press and release — drag-select gesture

    fn __init__(out self):
        self.menus = List[Menu]()
        self.open_idx = -1
        self.selected_item = 0
        self.tracking = False

    fn add(mut self, var menu: Menu):
        self.menus.append(menu^)

    fn set_visible_by_label(mut self, label: String, visible: Bool):
        for i in range(len(self.menus)):
            if self.menus[i].label == label:
                self.menus[i].visible = visible
                if not visible and self.open_idx == i:
                    self.open_menu(-1)
                return

    fn is_open(self) -> Bool:
        return self.open_idx >= 0

    fn close(mut self):
        self.open_menu(-1)

    fn open_menu(mut self, idx: Int):
        """Open menu ``idx`` (or close, if -1) and seat the keyboard
        selection on the first non-separator item. Use this rather than
        writing to ``open_idx`` directly so the highlight stays in sync."""
        self.open_idx = idx
        if idx >= 0:
            self.selected_item = self._first_non_separator(idx)
        else:
            self.selected_item = 0
            self.tracking = False

    fn _first_non_separator(self, menu_idx: Int) -> Int:
        if menu_idx < 0 or menu_idx >= len(self.menus):
            return 0
        var menu = self.menus[menu_idx]
        for i in range(len(menu.items)):
            if not menu.items[i].is_separator:
                return i
        return 0

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
        var sel_attr = Attr(BLACK, GREEN)
        var sel_key  = Attr(WHITE, GREEN)
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
            var is_sel = (i == self.selected_item)
            var row_attr = sel_attr if is_sel else attr
            var row_key = sel_key if is_sel else attr_key
            if is_sel:
                # Fill the row so the green background spans label → shortcut.
                canvas.fill(
                    Rect(rect.a.x + 1, y, rect.b.x - 1, y + 1),
                    String(" "), row_attr,
                )
            var label_bytes = menu.items[i].label.as_bytes()
            for j in range(len(label_bytes)):
                var ch = String(chr(Int(label_bytes[j])))
                var a = row_key if j == 0 else row_attr
                canvas.set(rect.a.x + 2 + j, y, Cell(ch, a, 1))
            # Right-aligned shortcut text — last cell sits at rect.b.x - 2
            # (one in from the right border), so the start x is computed
            # backwards from there. ``_dropdown_rect`` already widened the
            # rect to guarantee no overlap with the label.
            var sc = menu.items[i].shortcut
            var sc_w = len(sc.as_bytes())
            if sc_w > 0:
                var sx = rect.b.x - 1 - sc_w
                _ = canvas.put_text(Point(sx, y), sc, row_attr, rect.b.x - 1)

    # --- keyboard navigation ----------------------------------------------

    fn _display_order_indices(self) -> List[Int]:
        """Indices of visible menus in painted left-to-right order: rank-
        sorted left-aligned menus first, then right-aligned menus reversed
        so the leftmost-visible (last-inserted) right menu comes first."""
        var left = List[Int]()
        var right = List[Int]()
        for i in range(len(self.menus)):
            if not self.menus[i].visible:
                continue
            if self.menus[i].right_aligned:
                right.append(i)
            else:
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
        var k = len(right) - 1
        while k >= 0:
            left.append(right[k])
            k -= 1
        return left^

    fn _step_item(mut self, delta: Int):
        if self.open_idx < 0:
            return
        var n = len(self.menus[self.open_idx].items)
        if n == 0:
            return
        var i = self.selected_item
        for _ in range(n):
            i = (i + delta + n) % n
            if not self.menus[self.open_idx].items[i].is_separator:
                self.selected_item = i
                return

    fn _step_menu(mut self, delta: Int):
        var order = self._display_order_indices()
        if len(order) == 0:
            return
        var pos = -1
        for i in range(len(order)):
            if order[i] == self.open_idx:
                pos = i
                break
        if pos < 0:
            self.open_menu(order[0])
            return
        var new_pos = pos + delta
        if new_pos < 0:
            new_pos = len(order) - 1
        elif new_pos >= len(order):
            new_pos = 0
        self.open_menu(order[new_pos])

    fn _activate_selected(mut self) -> MenuResult:
        if self.open_idx < 0:
            return MenuResult(Optional[String](), False)
        var menu = self.menus[self.open_idx]
        if self.selected_item < 0 or self.selected_item >= len(menu.items):
            return MenuResult(Optional[String](), True)
        var item = menu.items[self.selected_item]
        if item.is_separator:
            return MenuResult(Optional[String](), True)
        var action = item.action
        self.open_menu(-1)
        return MenuResult(Optional[String](action), True)

    fn handle_key(mut self, event: Event) -> MenuResult:
        """Keyboard navigation while a menu is open. ESC is handled by the
        owning Desktop (so it can also clear ESC-prefix state, etc.); we
        only handle Up/Down/Left/Right/Enter here."""
        if not self.is_open():
            return MenuResult(Optional[String](), False)
        if event.kind != EVENT_KEY:
            return MenuResult(Optional[String](), False)
        var k = event.key
        if k == KEY_UP:
            self._step_item(-1)
            return MenuResult(Optional[String](), True)
        if k == KEY_DOWN:
            self._step_item(1)
            return MenuResult(Optional[String](), True)
        if k == KEY_LEFT:
            self._step_menu(-1)
            return MenuResult(Optional[String](), True)
        if k == KEY_RIGHT:
            self._step_menu(1)
            return MenuResult(Optional[String](), True)
        if k == KEY_ENTER:
            return self._activate_selected()
        return MenuResult(Optional[String](), False)

    # --- events ------------------------------------------------------------

    fn _menu_at(self, pos: Point, screen_width: Int) -> Int:
        """Index of the visible menu-bar entry under ``pos``, or -1."""
        if pos.y != 0:
            return -1
        var rects = self._layout(screen_width)
        for i in range(len(rects)):
            if not self.menus[i].visible:
                continue
            if rects[i].contains(pos):
                return i
        return -1

    fn _item_at(self, pos: Point, screen_width: Int) -> Int:
        """Index of the dropdown item under ``pos``, or -1 (also -1 for
        separators and hits on the dropdown border)."""
        if self.open_idx < 0:
            return -1
        var dr = self._dropdown_rect(screen_width)
        if not dr.contains(pos):
            return -1
        var item_idx = pos.y - dr.a.y - 1
        if item_idx < 0 or item_idx >= len(self.menus[self.open_idx].items):
            return -1
        if self.menus[self.open_idx].items[item_idx].is_separator:
            return -1
        return item_idx

    fn handle_event(mut self, event: Event, screen_width: Int) -> MenuResult:
        if event.kind != EVENT_MOUSE:
            return MenuResult(Optional[String](), False)

        # --- motion / hover --------------------------------------------------
        # Mouse-mode 1003 delivers motion both with a button held (drag) and
        # without (hover). When a menu is open we treat both the same: hover
        # over a different menu in the bar switches to it, hover over a
        # dropdown row repaints the highlight there.
        if event.motion:
            if self.open_idx < 0:
                return MenuResult(Optional[String](), False)
            var bar_hit = self._menu_at(event.pos, screen_width)
            if bar_hit >= 0:
                if bar_hit != self.open_idx:
                    self.open_menu(bar_hit)
                return MenuResult(Optional[String](), True)
            var item_hit = self._item_at(event.pos, screen_width)
            if item_hit >= 0:
                self.selected_item = item_hit
                return MenuResult(Optional[String](), True)
            # Motion outside the bar and dropdown: don't consume so other
            # widgets (e.g., the focused editor's drag-select) still see it.
            return MenuResult(Optional[String](), False)

        # --- press / release of the left button -----------------------------
        if event.button != MOUSE_BUTTON_LEFT:
            return MenuResult(Optional[String](), False)

        if event.pressed:
            # PRESS: starts a possible drag-select gesture.
            var bar_hit = self._menu_at(event.pos, screen_width)
            if bar_hit >= 0:
                if bar_hit == self.open_idx:
                    self.open_menu(-1)
                else:
                    self.open_menu(bar_hit)
                    self.tracking = True
                return MenuResult(Optional[String](), True)
            if self.open_idx >= 0:
                # In sticky mode, pressing on a dropdown item triggers it.
                var item_hit = self._item_at(event.pos, screen_width)
                if item_hit >= 0:
                    var action = self.menus[self.open_idx].items[item_hit].action
                    self.open_menu(-1)
                    return MenuResult(Optional[String](action), True)
                # Press on a dropdown separator or border: eat it, stay open.
                var dr = self._dropdown_rect(screen_width)
                if dr.contains(event.pos):
                    return MenuResult(Optional[String](), True)
                # Press anywhere else: close (clicked off the menu).
                self.open_menu(-1)
                return MenuResult(Optional[String](), True)
            return MenuResult(Optional[String](), False)

        # RELEASE: only meaningful while we're tracking a drag-select.
        if not self.tracking:
            return MenuResult(Optional[String](), False)
        var item_hit = self._item_at(event.pos, screen_width)
        if item_hit >= 0:
            var action = self.menus[self.open_idx].items[item_hit].action
            self.open_menu(-1)
            return MenuResult(Optional[String](action), True)
        # Release on the open menu's bar label or anywhere inside its dropdown
        # (separator / border): drop tracking and stay open in sticky mode.
        # Release outside both: close — drag-select that ends off-menu is a
        # cancellation gesture.
        var dr = self._dropdown_rect(screen_width)
        var bar_rect = self._layout(screen_width)[self.open_idx]
        if dr.contains(event.pos) or bar_rect.contains(event.pos):
            self.tracking = False
            return MenuResult(Optional[String](), True)
        self.open_menu(-1)
        return MenuResult(Optional[String](), True)
