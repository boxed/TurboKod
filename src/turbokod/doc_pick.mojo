"""DocPick: type-to-filter list of documentation entries.

A modal centered dialog (same shape as ``SymbolPick`` and ``QuickOpen``)
populated from a ``DocStore``'s ``entries``. The Desktop opens the
picker after ensuring docs are installed and loaded; selecting an
entry submits ``selected_index``, which the host uses to open the
rendered HTML body in a read-only editor pane.

The match algorithm is borrowed from ``quick_open_match`` so users get
the same fuzzy-with-word-boundary feel as Quick Open / Go to Symbol.

A two-line preview of the rendered body is painted under each row so
the user can disambiguate ``str.find`` from ``re.find`` without opening
each one. The preview is computed lazily on selection change to avoid
rendering thousands of HTML bodies up front.
"""

from std.collections.list import List

from .canvas import Canvas
from .cell import Cell
from .colors import Attr, BLACK, BLUE, LIGHT_GRAY, WHITE, YELLOW
from .doc_store import DocEntry, html_to_text
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_BACKSPACE, KEY_DOWN, KEY_ENTER, KEY_ESC, KEY_PAGEDOWN, KEY_PAGEUP,
    KEY_UP, MOD_ALT, MOD_CTRL,
    MOUSE_BUTTON_LEFT, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .geometry import Point, Rect
from .quick_open import quick_open_match
from .text_field import text_field_clipboard_key
from .window import paint_drop_shadow


struct DocPick(Movable):
    var active: Bool
    var submitted: Bool
    var display: String          # docset name shown in title ("Python 3.12")
    var query: String
    var entries: List[DocEntry]
    var matched: List[Int]
    var selected: Int
    var scroll: Int
    # Submission output — index into ``entries`` (not ``matched``), set
    # before ``submitted`` flips True so the host doesn't have to keep
    # the picker alive after consuming.
    var selected_index: Int

    fn __init__(out self):
        self.active = False
        self.submitted = False
        self.display = String("")
        self.query = String("")
        self.entries = List[DocEntry]()
        self.matched = List[Int]()
        self.selected = 0
        self.scroll = 0
        self.selected_index = -1

    fn open(
        mut self, var display: String, var entries: List[DocEntry],
    ):
        """Open the picker with ``entries`` already loaded."""
        self.display = display^
        self.entries = entries^
        self.query = String("")
        self.active = True
        self.submitted = False
        self.matched = List[Int]()
        self.selected = 0
        self.scroll = 0
        self.selected_index = -1
        self._refilter()

    fn close(mut self):
        self.active = False
        self.submitted = False
        self.display = String("")
        self.query = String("")
        self.entries = List[DocEntry]()
        self.matched = List[Int]()
        self.selected = 0
        self.scroll = 0
        self.selected_index = -1

    # --- filtering --------------------------------------------------------

    fn _refilter(mut self):
        self.matched = List[Int]()
        if len(self.query.as_bytes()) == 0:
            for i in range(len(self.entries)):
                self.matched.append(i)
        else:
            for i in range(len(self.entries)):
                # Match against ``type.name`` so the user can type a
                # section prefix (e.g. ``stdt`` for ``str.find`` under
                # "Standard Types") to narrow nested entries.
                var hay: String
                if len(self.entries[i].type_name.as_bytes()) > 0:
                    hay = self.entries[i].type_name + String(".") \
                        + self.entries[i].name
                else:
                    hay = self.entries[i].name
                if quick_open_match(hay, self.query):
                    self.matched.append(i)
        self.selected = 0
        self.scroll = 0

    # --- geometry ---------------------------------------------------------

    fn _rect(self, screen: Rect) -> Rect:
        var width = 80
        var height = 22
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

    fn is_input_at(self, pos: Point, screen: Rect) -> Bool:
        if not self.active:
            return False
        var rect = self._rect(screen)
        return Rect(rect.a.x + 2, rect.a.y + 1, rect.b.x - 1, rect.a.y + 2).contains(pos)

    # --- paint ------------------------------------------------------------

    fn paint(self, mut canvas: Canvas, screen: Rect):
        if not self.active:
            return
        var bg          = Attr(BLACK,  LIGHT_GRAY)
        var title_attr  = Attr(WHITE,  BLUE)
        var sel_attr    = Attr(BLACK,  YELLOW)
        var hint_attr   = Attr(BLUE,   LIGHT_GRAY)
        var type_attr   = Attr(BLUE,   LIGHT_GRAY)
        var sel_type    = Attr(BLUE,   YELLOW)
        var rect = self._rect(screen)
        paint_drop_shadow(canvas, rect)
        canvas.fill(rect, String(" "), bg)
        canvas.draw_box(rect, bg, False)
        var title = String(" Docs: ") + self.display + String(" ")
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
        if len(self.matched) == 0:
            var msg: String
            if len(self.entries) == 0:
                msg = String("No entries.")
            else:
                msg = String("No matches.")
            _ = canvas.put_text(
                Point(rect.a.x + 2, top), msg, hint_attr, rect.b.x - 1,
            )
        for i in range(h):
            var idx = self.scroll + i
            if idx >= len(self.matched):
                break
            var ent = self.entries[self.matched[idx]]
            var is_sel = (idx == self.selected)
            var row_attr = sel_attr if is_sel else bg
            var t_attr = sel_type if is_sel else type_attr
            canvas.fill(
                Rect(rect.a.x + 1, top + i, rect.b.x - 1, top + i + 1),
                String(" "), row_attr,
            )
            _ = canvas.put_text(
                Point(rect.a.x + 2, top + i), ent.name, row_attr,
                rect.b.x - 1,
            )
            if len(ent.type_name.as_bytes()) > 0:
                var tx2 = rect.a.x + 2 + len(ent.name.as_bytes()) + 2
                if tx2 < rect.b.x - 2:
                    _ = canvas.put_text(
                        Point(tx2, top + i),
                        String("(") + ent.type_name + String(")"),
                        t_attr, rect.b.x - 1,
                    )
        # Bottom hint.
        _ = canvas.put_text(
            Point(rect.a.x + 2, rect.b.y - 1),
            String(" Enter: open  ESC: cancel "),
            hint_attr, rect.b.x - 1,
        )

    # --- events -----------------------------------------------------------

    fn handle_key(mut self, event: Event) -> Bool:
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
            self.selected_index = self.matched[self.selected]
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
        var clip = text_field_clipboard_key(event, self.query)
        if clip.consumed:
            if clip.changed:
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
            self.selected_index = self.matched[idx]
            self.submitted = True
            return True
        self.selected = idx
        return True

    fn _scroll_to_selection(mut self):
        var visible = 16
        if self.selected < self.scroll:
            self.scroll = self.selected
        elif self.selected >= self.scroll + visible:
            self.scroll = self.selected - visible + 1
