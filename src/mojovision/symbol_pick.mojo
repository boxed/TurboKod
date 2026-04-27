"""SymbolPick: type-to-filter list of LSP document symbols.

A modal centered dialog, like ``QuickOpen``, but populated from a
``textDocument/documentSymbol`` response instead of the project file
walk. The Desktop opens the picker (in a "loading…" state), kicks off
the LSP request, and feeds the result list in via ``set_entries`` once
``lsp.consume_symbols`` returns. Selection submits ``(line, character)``
which the host uses to move the cursor.

The match algorithm is borrowed from ``quick_open_match`` so users get
the same fuzzy-with-word-boundary feel they're already used to.
"""

from std.collections.list import List

from .canvas import Canvas
from .cell import Cell
from .colors import Attr, BLACK, BLUE, LIGHT_GRAY, WHITE, YELLOW
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_BACKSPACE, KEY_DOWN, KEY_ENTER, KEY_ESC, KEY_PAGEDOWN, KEY_PAGEUP,
    KEY_UP, MOD_ALT, MOD_CTRL,
    MOUSE_BUTTON_LEFT, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .geometry import Point, Rect
from .lsp_dispatch import SymbolItem
from .quick_open import quick_open_match


struct SymbolPick(Movable):
    var active: Bool
    var loading: Bool       # True while waiting for the LSP response
    var submitted: Bool
    var path: String        # the file the symbols belong to
    var query: String
    var entries: List[SymbolItem]
    var matched: List[Int]
    var selected: Int
    var scroll: Int
    # Submission output — read after ``submitted`` flips True.
    var selected_line: Int
    var selected_character: Int

    fn __init__(out self):
        self.active = False
        self.loading = False
        self.submitted = False
        self.path = String("")
        self.query = String("")
        self.entries = List[SymbolItem]()
        self.matched = List[Int]()
        self.selected = 0
        self.scroll = 0
        self.selected_line = 0
        self.selected_character = 0

    fn open(mut self, var path: String):
        """Open the picker in a loading state for ``path``. Entries arrive
        later via ``set_entries`` once the LSP responds."""
        self.path = path^
        self.query = String("")
        self.active = True
        self.loading = True
        self.submitted = False
        self.entries = List[SymbolItem]()
        self.matched = List[Int]()
        self.selected = 0
        self.scroll = 0
        self.selected_line = 0
        self.selected_character = 0

    fn set_entries(mut self, var items: List[SymbolItem]):
        """Populate the picker with the response and clear the loading flag.
        Refilters with the current query in case the user typed while we
        were waiting."""
        self.entries = items^
        self.loading = False
        self._refilter()

    fn close(mut self):
        self.active = False
        self.loading = False
        self.submitted = False
        self.path = String("")
        self.query = String("")
        self.entries = List[SymbolItem]()
        self.matched = List[Int]()
        self.selected = 0
        self.scroll = 0

    # --- filtering --------------------------------------------------------

    fn _refilter(mut self):
        self.matched = List[Int]()
        if len(self.query.as_bytes()) == 0:
            for i in range(len(self.entries)):
                self.matched.append(i)
        else:
            for i in range(len(self.entries)):
                # Match against ``container.name`` so users can type a
                # parent-class prefix to narrow nested methods.
                var hay: String
                if len(self.entries[i].container.as_bytes()) > 0:
                    hay = self.entries[i].container + String(".") \
                        + self.entries[i].name
                else:
                    hay = self.entries[i].name
                if quick_open_match(hay, self.query):
                    self.matched.append(i)
        self.selected = 0
        self.scroll = 0

    # --- geometry ---------------------------------------------------------

    fn _rect(self, screen: Rect) -> Rect:
        var width = 70
        var height = 20
        if width > screen.b.x - 4: width = screen.b.x - 4
        if height > screen.b.y - 4: height = screen.b.y - 4
        var x = (screen.b.x - width) // 2
        var y = (screen.b.y - height) // 2
        return Rect(x, y, x + width, y + height)

    fn _list_top(self, rect: Rect) -> Int:
        return rect.a.y + 3

    fn _list_height(self, rect: Rect) -> Int:
        var h = (rect.b.y - 1) - self._list_top(rect)
        if h < 0:
            return 0
        return h

    # --- paint ------------------------------------------------------------

    fn paint(self, mut canvas: Canvas, screen: Rect):
        if not self.active:
            return
        var bg          = Attr(BLACK,  LIGHT_GRAY)
        var title_attr  = Attr(WHITE,  BLUE)
        var sel_attr    = Attr(BLACK,  YELLOW)
        var hint_attr   = Attr(BLUE,   LIGHT_GRAY)
        var kind_attr   = Attr(BLUE,   LIGHT_GRAY)
        var sel_kind    = Attr(BLUE,   YELLOW)
        var rect = self._rect(screen)
        canvas.fill(rect, String(" "), bg)
        canvas.draw_box(rect, bg, False)
        var title = String(" Go to Symbol ")
        var tx = rect.a.x + (rect.width() - len(title.as_bytes())) // 2
        _ = canvas.put_text(Point(tx, rect.a.y), title, title_attr)
        # Search line.
        var label = String(" Find: ")
        _ = canvas.put_text(
            Point(rect.a.x + 2, rect.a.y + 1), label, bg, rect.b.x - 1,
        )
        var qx = rect.a.x + 2 + len(label.as_bytes())
        _ = canvas.put_text(
            Point(qx, rect.a.y + 1), self.query, bg, rect.b.x - 1,
        )
        var cur = qx + len(self.query.as_bytes())
        if cur < rect.b.x - 1:
            canvas.set(cur, rect.a.y + 1, Cell(String(" "), Attr(LIGHT_GRAY, BLACK), 1))
        # Listing.
        var top = self._list_top(rect)
        var h = self._list_height(rect)
        if self.loading:
            _ = canvas.put_text(
                Point(rect.a.x + 2, top),
                String("Loading symbols..."),
                hint_attr, rect.b.x - 1,
            )
        elif len(self.matched) == 0:
            var msg: String
            if len(self.entries) == 0:
                msg = String("No symbols.")
            else:
                msg = String("No matches.")
            _ = canvas.put_text(
                Point(rect.a.x + 2, top), msg, hint_attr, rect.b.x - 1,
            )
        for i in range(h):
            var idx = self.scroll + i
            if idx >= len(self.matched):
                break
            var sym = self.entries[self.matched[idx]]
            var is_sel = (idx == self.selected)
            var row_attr = sel_attr if is_sel else bg
            var k_attr = sel_kind if is_sel else kind_attr
            canvas.fill(
                Rect(rect.a.x + 1, top + i, rect.b.x - 1, top + i + 1),
                String(" "), row_attr,
            )
            var kind_label = symbol_kind_label(sym.kind)
            _ = canvas.put_text(
                Point(rect.a.x + 2, top + i), kind_label, k_attr,
                rect.b.x - 1,
            )
            var name_x = rect.a.x + 2 + len(kind_label.as_bytes()) + 1
            _ = canvas.put_text(
                Point(name_x, top + i), sym.name, row_attr, rect.b.x - 1,
            )
            if len(sym.container.as_bytes()) > 0:
                var cx = name_x + len(sym.name.as_bytes()) + 2
                if cx < rect.b.x - 2:
                    _ = canvas.put_text(
                        Point(cx, top + i),
                        String("(") + sym.container + String(")"),
                        hint_attr, rect.b.x - 1,
                    )
        # Bottom hint.
        _ = canvas.put_text(
            Point(rect.a.x + 2, rect.b.y - 1),
            String(" Enter: jump  ESC: cancel "),
            hint_attr, rect.b.x - 1,
        )

    # --- events -----------------------------------------------------------

    fn handle_key(mut self, event: Event) -> Bool:
        """Returns True if the event was consumed (always True while active)."""
        if not self.active:
            return False
        if event.kind != EVENT_KEY:
            return True
        var k = event.key
        if k == KEY_ESC:
            self.close()
            return True
        if k == KEY_ENTER:
            if self.selected < 0 or self.selected >= len(self.matched):
                return True
            var sym = self.entries[self.matched[self.selected]]
            self.selected_line = sym.line
            self.selected_character = sym.character
            self.submitted = True
            return True
        if k == KEY_UP:
            if self.selected > 0:
                self.selected -= 1
                self._scroll_to_selection()
            return True
        if k == KEY_DOWN:
            if self.selected + 1 < len(self.matched):
                self.selected += 1
                self._scroll_to_selection()
            return True
        if k == KEY_PAGEUP:
            self.selected -= 10
            if self.selected < 0:
                self.selected = 0
            self._scroll_to_selection()
            return True
        if k == KEY_PAGEDOWN:
            self.selected += 10
            if self.selected >= len(self.matched):
                self.selected = len(self.matched) - 1
            if self.selected < 0:
                self.selected = 0
            self._scroll_to_selection()
            return True
        if k == KEY_BACKSPACE:
            var qb = self.query.as_bytes()
            if len(qb) > 0:
                self.query = String(StringSlice(
                    unsafe_from_utf8=qb[:len(qb) - 1],
                ))
                self._refilter()
            return True
        if (event.mods & MOD_CTRL) != 0 or (event.mods & MOD_ALT) != 0:
            return True
        if UInt32(0x20) <= k and k < UInt32(0x7F):
            self.query = self.query + chr(Int(k))
            self._refilter()
            return True
        return True

    fn handle_mouse(mut self, event: Event, screen: Rect) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_MOUSE:
            return True
        var rect = self._rect(screen)
        if event.pressed and not event.motion:
            if event.button == MOUSE_WHEEL_UP:
                if self.scroll > 0:
                    self.scroll -= 3
                    if self.scroll < 0:
                        self.scroll = 0
                return True
            if event.button == MOUSE_WHEEL_DOWN:
                var h = self._list_height(rect)
                var max_scroll = len(self.matched) - h
                if max_scroll < 0:
                    max_scroll = 0
                if self.scroll < max_scroll:
                    self.scroll += 3
                    if self.scroll > max_scroll:
                        self.scroll = max_scroll
                return True
        if event.button != MOUSE_BUTTON_LEFT:
            return True
        if not event.pressed or event.motion:
            return True
        if not rect.contains(event.pos):
            return True
        var top = self._list_top(rect)
        var h = self._list_height(rect)
        if event.pos.y < top or event.pos.y >= top + h:
            return True
        var idx = self.scroll + (event.pos.y - top)
        if idx < 0 or idx >= len(self.matched):
            return True
        if idx == self.selected:
            var sym = self.entries[self.matched[idx]]
            self.selected_line = sym.line
            self.selected_character = sym.character
            self.submitted = True
            return True
        self.selected = idx
        return True

    fn _scroll_to_selection(mut self):
        var visible = 14
        if self.selected < self.scroll:
            self.scroll = self.selected
        elif self.selected >= self.scroll + visible:
            self.scroll = self.selected - visible + 1


fn symbol_kind_label(kind: Int) -> String:
    """Map an LSP ``SymbolKind`` integer to a 5-char fixed-width label so
    list rows align cleanly. Unknown kinds render as ``[ ? ]``."""
    if kind == 5:  return String("[cls]")    # Class
    if kind == 23: return String("[str]")    # Struct
    if kind == 6:  return String("[mtd]")    # Method
    if kind == 9:  return String("[new]")    # Constructor
    if kind == 12: return String("[fn ]")    # Function
    if kind == 13: return String("[var]")    # Variable
    if kind == 14: return String("[con]")    # Constant
    if kind == 7:  return String("[prp]")    # Property
    if kind == 8:  return String("[fld]")    # Field
    if kind == 10: return String("[enm]")    # Enum
    if kind == 22: return String("[em ]")    # EnumMember
    if kind == 11: return String("[ifc]")    # Interface
    if kind == 2:  return String("[mod]")    # Module
    if kind == 3:  return String("[ns ]")    # Namespace
    if kind == 4:  return String("[pkg]")    # Package
    if kind == 26: return String("[tp ]")    # TypeParameter
    return String("[ ? ]")
