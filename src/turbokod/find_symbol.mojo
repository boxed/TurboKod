"""FindSymbol: type-to-search workspace-wide symbol picker.

Triggered by Cmd+Option+O. Sibling of ``SymbolPick`` (which is the
file-local Go-to-Symbol picker bound to Ctrl/Cmd+T) but driven by
``workspace/symbol`` instead of ``textDocument/documentSymbol``:

* The picker has no candidate set at open time — every keystroke that
  changes the query kicks off a fresh ``workspace/symbol`` LSP request.
* Stale responses are discarded: the host stamps each ``set_entries``
  call with the query that produced it, and the picker drops the
  payload if the user has moved on.
* Selection submits ``(path, line, character)`` (vs. the file-local
  picker which only knows about ``(line, character)``) so the host can
  open the file before jumping the cursor.
"""

from std.collections.list import List

from .canvas import Canvas
from .cell import Cell
from .colors import Attr, BLACK, BLUE, LIGHT_GRAY, WHITE, YELLOW
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_BACKSPACE, KEY_ENTER, KEY_ESC,
    MOD_ALT, MOD_CTRL,
    MOUSE_BUTTON_LEFT,
)
from .geometry import Point, Rect
from .lsp_dispatch import WorkspaceSymbolItem
from .picker_input import picker_nav_key, picker_wheel_scroll
from .symbol_pick import symbol_kind_label
from .text_field import text_field_clipboard_key
from .window import paint_drop_shadow


struct FindSymbol(Movable):
    var active: Bool
    var loading: Bool       # True while a request is in flight
    var submitted: Bool
    var query: String
    # Query string that produced ``entries``. Used to discard stale
    # responses when the user has typed past the request that produced
    # them. Empty until the first response lands.
    var entries_query: String
    var entries: List[WorkspaceSymbolItem]
    var selected: Int
    var scroll: Int
    # Submission output — read after ``submitted`` flips True.
    var selected_path: String
    var selected_line: Int
    var selected_character: Int
    # ``True`` once the user has typed at least one character — drives
    # the "Type to search…" placeholder vs. "No matches" message.
    var has_typed: Bool
    # Set by host when the most recent request couldn't be sent (no LSP
    # ready, etc.) so the picker can show a helpful message instead of
    # spinning at "Loading…" forever.
    var error_message: String
    # Set by host when the most recent response was empty — distinct
    # from "still loading" so we can show "No matches" once the reply
    # has actually landed.
    var got_empty: Bool

    fn __init__(out self):
        self.active = False
        self.loading = False
        self.submitted = False
        self.query = String("")
        self.entries_query = String("")
        self.entries = List[WorkspaceSymbolItem]()
        self.selected = 0
        self.scroll = 0
        self.selected_path = String("")
        self.selected_line = 0
        self.selected_character = 0
        self.has_typed = False
        self.error_message = String("")
        self.got_empty = False

    fn open(mut self):
        self.active = True
        self.loading = False
        self.submitted = False
        self.query = String("")
        self.entries_query = String("")
        self.entries = List[WorkspaceSymbolItem]()
        self.selected = 0
        self.scroll = 0
        self.selected_path = String("")
        self.selected_line = 0
        self.selected_character = 0
        self.has_typed = False
        self.error_message = String("")
        self.got_empty = False

    fn close(mut self):
        self.active = False
        self.loading = False
        self.submitted = False
        self.query = String("")
        self.entries_query = String("")
        self.entries = List[WorkspaceSymbolItem]()
        self.selected = 0
        self.scroll = 0

    fn mark_loading(mut self):
        """Host calls this right after sending a workspace/symbol request
        for the current ``self.query``. Clears the prior error and the
        empty-result latch."""
        self.loading = True
        self.error_message = String("")
        self.got_empty = False

    fn set_error(mut self, var msg: String):
        """Host calls this when it could not send a request (LSP not
        ready, etc.). Replaces the loading state with a one-line
        message shown in the result area."""
        self.loading = False
        self.error_message = msg^

    fn set_entries(
        mut self, var items: List[WorkspaceSymbolItem], for_query: String,
    ):
        """Populate the picker with the response. Discards the payload
        if ``for_query`` doesn't match the current query — that means
        the user has typed since this request went out, and the host
        either already kicked off a fresher one or will soon.
        """
        if for_query != self.query:
            return
        self.entries = items^
        self.entries_query = for_query
        self.loading = False
        self.error_message = String("")
        self.got_empty = (len(self.entries) == 0)
        if self.selected >= len(self.entries):
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
        var kind_attr   = Attr(BLUE,   LIGHT_GRAY)
        var sel_kind    = Attr(BLUE,   YELLOW)
        var rect = self._rect(screen)
        paint_drop_shadow(canvas, rect)
        canvas.fill(rect, String(" "), bg)
        canvas.draw_box(rect, bg, False)
        var title = String(" Find Symbol ")
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
        if len(self.error_message.as_bytes()) > 0:
            _ = canvas.put_text(
                Point(rect.a.x + 2, top),
                self.error_message,
                hint_attr, rect.b.x - 1,
            )
        elif self.loading:
            _ = canvas.put_text(
                Point(rect.a.x + 2, top),
                String("Searching..."),
                hint_attr, rect.b.x - 1,
            )
        elif not self.has_typed:
            _ = canvas.put_text(
                Point(rect.a.x + 2, top),
                String("Type to search workspace symbols..."),
                hint_attr, rect.b.x - 1,
            )
        elif len(self.entries) == 0:
            _ = canvas.put_text(
                Point(rect.a.x + 2, top),
                String("No matches."),
                hint_attr, rect.b.x - 1,
            )
        for i in range(h):
            var idx = self.scroll + i
            if idx >= len(self.entries):
                break
            var sym = self.entries[idx]
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
            # Path/container on the right side of the row, dim-coloured
            # so the eye lands on the symbol name first.
            var tail = sym.path
            if len(sym.container.as_bytes()) > 0:
                tail = sym.container + String("  ") + tail
            var tail_x = name_x + len(sym.name.as_bytes()) + 2
            if tail_x < rect.b.x - 2 and len(tail.as_bytes()) > 0:
                _ = canvas.put_text(
                    Point(tail_x, top + i), tail, hint_attr, rect.b.x - 1,
                )
        # Bottom hint.
        _ = canvas.put_text(
            Point(rect.a.x + 2, rect.b.y - 1),
            String(" Enter: jump  ESC: cancel "),
            hint_attr, rect.b.x - 1,
        )

    # --- events -----------------------------------------------------------

    fn handle_key(mut self, event: Event) -> Bool:
        """Returns ``(consumed, query_changed)`` packed: True iff
        consumed; the host inspects ``self.query`` after the call to
        decide whether to fire a fresh LSP request. Consumption is
        always True while active so global hotkeys don't fire through.
        """
        if not self.active:
            return False
        if event.kind != EVENT_KEY:
            return True
        var k = event.key
        if k == KEY_ESC:
            self.close()
            return True
        if k == KEY_ENTER:
            if self.selected < 0 or self.selected >= len(self.entries):
                return True
            var sym = self.entries[self.selected]
            self.selected_path = sym.path
            self.selected_line = sym.line
            self.selected_character = sym.character
            self.submitted = True
            return True
        if picker_nav_key(k, len(self.entries), self.selected):
            self._scroll_to_selection()
            return True
        if k == KEY_BACKSPACE:
            var qb = self.query.as_bytes()
            if len(qb) > 0:
                self.query = String(StringSlice(
                    unsafe_from_utf8=qb[:len(qb) - 1],
                ))
                # Empty query → forget previous results immediately so
                # we don't briefly show stale matches before the host
                # decides whether to re-query.
                if len(self.query.as_bytes()) == 0:
                    self.entries = List[WorkspaceSymbolItem]()
                    self.entries_query = String("")
                    self.has_typed = False
                    self.got_empty = False
            return True
        var clip = text_field_clipboard_key(event, self.query)
        if clip.consumed:
            if clip.changed:
                self.has_typed = True
            return True
        if (event.mods & MOD_CTRL) != 0 or (event.mods & MOD_ALT) != 0:
            return True
        if UInt32(0x20) <= k and k < UInt32(0x7F):
            self.query = self.query + chr(Int(k))
            self.has_typed = True
            return True
        return True

    fn handle_mouse(mut self, event: Event, screen: Rect) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_MOUSE:
            return True
        var rect = self._rect(screen)
        if event.pressed and not event.motion:
            if picker_wheel_scroll(
                event.button, self.scroll, len(self.entries),
                self._list_height(rect),
            ):
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
        if idx < 0 or idx >= len(self.entries):
            return True
        if idx == self.selected:
            var sym = self.entries[idx]
            self.selected_path = sym.path
            self.selected_line = sym.line
            self.selected_character = sym.character
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
