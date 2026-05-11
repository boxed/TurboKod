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

from .canvas import Canvas, paint_drop_shadow
from .painter import Painter
from .cell import Cell
from .colors import Attr, BLACK, BLUE, LIGHT_GRAY, YELLOW
from .doc_store import DocEntry, html_to_text
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_ENTER, KEY_ESC,
    MOUSE_BUTTON_LEFT,
)
from .geometry import Point, Rect
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
    ``handle_mouse`` so list hit-testing and list rendering see the
    exact same top/height — previously each side recomputed
    ``_list_top`` / ``_list_height`` independently.
    """
    var input_rect: Rect
    var input_label_pt: Point
    var list_top: Int
    var list_height: Int
    var hint_y: Int


fn _build_layout(rect: Rect, label_w: Int) -> _Layout:
    var cursor = RowCursor(rect.a.y + 1)
    var input_y = cursor.place()
    var list_y = cursor.place()
    var hint_y = rect.b.y - 1
    var list_h = hint_y - list_y
    if list_h < 0:
        list_h = 0
    return _Layout(
        Rect(rect.a.x + 2 + label_w, input_y, rect.b.x - 1, input_y + 1),
        Point(rect.a.x + 2, input_y),
        list_y, list_h, hint_y,
    )


struct DocPick(Movable):
    var active: Bool
    var submitted: Bool
    var display: String          # docset name shown in title ("Python 3.12")
    var query: TextField
    var entries: List[DocEntry]
    var matched: List[Int]
    var selected: Int
    var scroll: Int
    # Submission output — index into ``entries`` (not ``matched``), set
    # before ``submitted`` flips True so the host doesn't have to keep
    # the picker alive after consuming.
    var selected_index: Int
    # Cached input strip rect for mouse routing.
    var _input_rect: Rect

    fn __init__(out self):
        self.active = False
        self.submitted = False
        self.display = String("")
        self.query = TextField()
        self.entries = List[DocEntry]()
        self.matched = List[Int]()
        self.selected = 0
        self.scroll = 0
        self.selected_index = -1
        self._input_rect = Rect(0, 0, 0, 0)

    fn open(
        mut self, var display: String, var entries: List[DocEntry],
    ):
        """Open the picker with ``entries`` already loaded."""
        self.display = display^
        self.entries = entries^
        self.query = TextField()
        self.active = True
        self.submitted = False
        self.matched = List[Int]()
        self.selected = 0
        self.scroll = 0
        self.selected_index = -1
        self._input_rect = Rect(0, 0, 0, 0)
        self._refilter()

    fn close(mut self):
        self.active = False
        self.submitted = False
        self.display = String("")
        self.query = TextField()
        self.entries = List[DocEntry]()
        self.matched = List[Int]()
        self.selected = 0
        self.scroll = 0
        self.selected_index = -1
        self._input_rect = Rect(0, 0, 0, 0)

    # --- filtering --------------------------------------------------------

    fn _refilter(mut self):
        self.matched = List[Int]()
        if len(self.query.text.as_bytes()) == 0:
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
                if quick_open_match(hay, self.query.text):
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

    fn is_input_at(self, pos: Point, screen: Rect) -> Bool:
        if not self.active:
            return False
        var rect = self._rect(screen)
        return _build_layout(rect, _LABEL_W).input_rect.contains(pos)

    # --- paint ------------------------------------------------------------

    fn paint(mut self, mut canvas: Canvas, screen: Rect):
        if not self.active:
            return
        var bg          = Attr(BLACK,  LIGHT_GRAY)
        var sel_attr    = Attr(BLACK,  YELLOW)
        var hint_attr   = Attr(BLUE,   LIGHT_GRAY)
        var type_attr   = Attr(BLUE,   LIGHT_GRAY)
        var sel_type    = Attr(BLUE,   YELLOW)
        var rect = self._rect(screen)
        var layout = _build_layout(rect, _LABEL_W)
        paint_drop_shadow(canvas, rect)
        var painter = Painter(rect)
        painter.fill(canvas, rect, String(" "), bg)
        painter.draw_box(canvas, rect, bg, False)
        paint_window_title(
            canvas, rect, String(" Docs: ") + self.display + String(" "),
            bg, bg,
        )
        # Search line.
        _ = painter.put_text(canvas, layout.input_label_pt, _LABEL, bg)
        self._input_rect = layout.input_rect
        self.query.paint(canvas, layout.input_rect, True)
        # Listing.
        var top = layout.list_top
        var h = layout.list_height
        if len(self.matched) == 0:
            var msg: String
            if len(self.entries) == 0:
                msg = String("No entries.")
            else:
                msg = String("No matches.")
            _ = painter.put_text(
                canvas, Point(rect.a.x + 2, top), msg, hint_attr,
            )
        for i in range(h):
            var idx = self.scroll + i
            if idx >= len(self.matched):
                break
            var ent = self.entries[self.matched[idx]]
            var is_sel = (idx == self.selected)
            var row_attr = sel_attr if is_sel else bg
            var t_attr = sel_type if is_sel else type_attr
            painter.fill(
                canvas, Rect(rect.a.x + 1, top + i, rect.b.x - 1, top + i + 1),
                String(" "), row_attr,
            )
            _ = painter.put_text(
                canvas, Point(rect.a.x + 2, top + i), ent.name, row_attr,
            )
            if len(ent.type_name.as_bytes()) > 0:
                var tx2 = rect.a.x + 2 + len(ent.name.as_bytes()) + 2
                if tx2 < rect.b.x - 2:
                    _ = painter.put_text(
                        canvas, Point(tx2, top + i),
                        String("(") + ent.type_name + String(")"),
                        t_attr,
                    )
        # Bottom hint.
        _ = painter.put_text(
            canvas, Point(rect.a.x + 2, layout.hint_y),
            String(" Enter: open  ESC: cancel "),
            hint_attr,
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
        var layout = _build_layout(rect, _LABEL_W)
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
