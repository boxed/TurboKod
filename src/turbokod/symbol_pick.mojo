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

from .canvas import Canvas, paint_drop_shadow
from .painter import Painter
from .cell import Cell
from .colors import Attr, BLACK, BLUE, LIGHT_GRAY, YELLOW
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_ENTER, KEY_ESC,
    MOUSE_BUTTON_LEFT,
)
from .geometry import Point, Rect
from .lsp_dispatch import SymbolItem
from .picker_input import picker_nav_key, picker_wheel_scroll
from .quick_open import quick_open_match
from .text_field import TextField
from .view import RowCursor
from .window import paint_window_title


comptime _LABEL = String(" Find: ")
comptime _LABEL_W = 7
"""Columns occupied by the inline search label (``" Find: "``)."""


@fieldwise_init
struct _Layout(ImplicitlyCopyable, Movable):
    """Pre-computed rects for the picker. Shared by ``paint`` and
    ``handle_mouse``."""
    var input_rect: Rect
    var input_label_pt: Point
    var list_top: Int
    var list_height: Int
    var hint_y: Int


fn _build_layout(rect: Rect) -> _Layout:
    var cursor = RowCursor(rect.a.y + 1)
    var input_y = cursor.place()
    var list_y = cursor.place()
    var hint_y = rect.b.y - 1
    var list_h = hint_y - list_y
    if list_h < 0:
        list_h = 0
    return _Layout(
        Rect(rect.a.x + 2 + _LABEL_W, input_y, rect.b.x - 1, input_y + 1),
        Point(rect.a.x + 2, input_y),
        list_y, list_h, hint_y,
    )


struct SymbolPick(Movable):
    var active: Bool
    var loading: Bool       # True while waiting for the LSP response
    var submitted: Bool
    var path: String        # the file the symbols belong to
    var query: TextField
    var entries: List[SymbolItem]
    var matched: List[Int]
    var selected: Int
    var scroll: Int
    # Submission output — read after ``submitted`` flips True.
    var selected_line: Int
    var selected_character: Int
    # Cached input strip rect for mouse routing.
    var _input_rect: Rect

    fn __init__(out self):
        self.active = False
        self.loading = False
        self.submitted = False
        self.path = String("")
        self.query = TextField()
        self.entries = List[SymbolItem]()
        self.matched = List[Int]()
        self.selected = 0
        self.scroll = 0
        self.selected_line = 0
        self.selected_character = 0
        self._input_rect = Rect(0, 0, 0, 0)

    fn open(mut self, var path: String):
        """Open the picker in a loading state for ``path``. Entries arrive
        later via ``set_entries`` once the LSP responds."""
        self.path = path^
        self.query = TextField()
        self.active = True
        self.loading = True
        self.submitted = False
        self.entries = List[SymbolItem]()
        self.matched = List[Int]()
        self.selected = 0
        self.scroll = 0
        self.selected_line = 0
        self.selected_character = 0
        self._input_rect = Rect(0, 0, 0, 0)

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
        self.query = TextField()
        self.entries = List[SymbolItem]()
        self.matched = List[Int]()
        self.selected = 0
        self.scroll = 0
        self._input_rect = Rect(0, 0, 0, 0)

    # --- filtering --------------------------------------------------------

    fn _refilter(mut self):
        self.matched = List[Int]()
        if len(self.query.text.as_bytes()) == 0:
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
                if quick_open_match(hay, self.query.text):
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

    fn is_input_at(self, pos: Point, screen: Rect) -> Bool:
        """True iff ``pos`` lies on the ``Find:`` query row."""
        if not self.active:
            return False
        var rect = self._rect(screen)
        return _build_layout(rect).input_rect.contains(pos)

    # --- paint ------------------------------------------------------------

    fn paint(mut self, mut canvas: Canvas, screen: Rect):
        if not self.active:
            return
        var bg          = Attr(BLACK,  LIGHT_GRAY)
        var sel_attr    = Attr(BLACK,  YELLOW)
        var hint_attr   = Attr(BLUE,   LIGHT_GRAY)
        var kind_attr   = Attr(BLUE,   LIGHT_GRAY)
        var sel_kind    = Attr(BLUE,   YELLOW)
        var rect = self._rect(screen)
        var layout = _build_layout(rect)
        paint_drop_shadow(canvas, rect)
        var painter = Painter(rect)
        painter.fill(canvas, rect, String(" "), bg)
        painter.draw_box(canvas, rect, bg, False)
        paint_window_title(canvas, rect, String(" Go to Symbol "), bg, bg)
        # Search line.
        _ = painter.put_text(canvas, layout.input_label_pt, _LABEL, bg)
        self._input_rect = layout.input_rect
        self.query.paint(canvas, layout.input_rect, True)
        # Listing.
        var top = layout.list_top
        var h = layout.list_height
        if self.loading:
            _ = painter.put_text(
                canvas, Point(rect.a.x + 2, top),
                String("Loading symbols..."),
                hint_attr,
            )
        elif len(self.matched) == 0:
            var msg: String
            if len(self.entries) == 0:
                msg = String("No symbols.")
            else:
                msg = String("No matches.")
            _ = painter.put_text(
                canvas, Point(rect.a.x + 2, top), msg, hint_attr,
            )
        for i in range(h):
            var idx = self.scroll + i
            if idx >= len(self.matched):
                break
            var sym = self.entries[self.matched[idx]]
            var is_sel = (idx == self.selected)
            var row_attr = sel_attr if is_sel else bg
            var k_attr = sel_kind if is_sel else kind_attr
            painter.fill(
                canvas, Rect(rect.a.x + 1, top + i, rect.b.x - 1, top + i + 1),
                String(" "), row_attr,
            )
            var kind_label = symbol_kind_label(sym.kind)
            _ = painter.put_text(
                canvas, Point(rect.a.x + 2, top + i), kind_label, k_attr,
            )
            var name_x = rect.a.x + 2 + len(kind_label.as_bytes()) + 1
            _ = painter.put_text(
                canvas, Point(name_x, top + i), sym.name, row_attr,
            )
            if len(sym.container.as_bytes()) > 0:
                var cx = name_x + len(sym.name.as_bytes()) + 2
                if cx < rect.b.x - 2:
                    _ = painter.put_text(
                        canvas, Point(cx, top + i),
                        String("(") + sym.container + String(")"),
                        hint_attr,
                    )
        # Bottom hint.
        _ = painter.put_text(
            canvas, Point(rect.a.x + 2, layout.hint_y),
            String(" Enter: jump  ESC: cancel "),
            hint_attr,
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
        if picker_nav_key(k, len(self.matched), self.selected):
            self._scroll_to_selection()
            return True
        var r = self.query.handle_key(event)
        if r.consumed:
            if r.changed:
                self._refilter()
            return True
        return True

    fn handle_mouse(mut self, event: Event, screen: Rect) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_MOUSE:
            return True
        var rect = self._rect(screen)
        var layout = _build_layout(rect)
        if self._input_rect.width() > 0 \
                and self.query.handle_mouse(event, self._input_rect):
            return True
        if event.pressed and not event.motion:
            if picker_wheel_scroll(
                event.button, self.scroll, len(self.matched),
                layout.list_height,
            ):
                return True
        if event.button != MOUSE_BUTTON_LEFT:
            return True
        if not event.pressed or event.motion:
            return True
        if not rect.contains(event.pos):
            return True
        if event.pos.y < layout.list_top \
                or event.pos.y >= layout.list_top + layout.list_height:
            return True
        var idx = self.scroll + (event.pos.y - layout.list_top)
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
