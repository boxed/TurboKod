"""DocPick: type-to-filter list of documentation entries.

A modal centered dialog (same shape as ``SymbolPick`` and ``QuickOpen``)
populated from a ``DocStore``'s ``entries``. The Desktop opens the
picker after ensuring docs are installed and loaded; selecting an
entry submits ``selected_index``, which the host uses to open the
rendered HTML body in a read-only editor pane.

The match algorithm is borrowed from ``quick_open_match`` so users get
the same fuzzy-with-word-boundary feel as Quick Open / Go to Symbol.
"""

from std.collections.list import List

from .canvas import Canvas
from .cell import Cell
from .colors import Attr, BLACK, BLUE, LIGHT_GRAY, YELLOW
from .doc_store import DocEntry
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_ENTER, KEY_ESC,
    MOUSE_BUTTON_LEFT,
)
from .geometry import Point, Rect, center_in
from .picker_input import (
    build_picker_layout, picker_nav_key, picker_wheel_scroll,
    scroll_to_reveal,
)
from .quick_open import quick_open_match
from .string_utils import display_columns
from .text_field import TextField
from .window import close_button_clicked, paint_modal_frame, paint_window_title


comptime _LABEL = String(" Find: ")
comptime _LABEL_W = 7
"""Columns occupied by the inline search label (``" Find: "``)."""


struct DocPick(Movable):
    var active: Bool
    var submitted: Bool
    var display: String          # docset name shown in title ("Python 3.12")
    var query: TextField
    var entries: List[DocEntry]
    # Precomputed ``type_name.name`` (or bare ``name``) match haystacks,
    # parallel to ``entries`` — built once in ``open`` so ``_refilter``
    # doesn't reconcatenate per entry on every keystroke.
    var _haystacks: List[String]
    var matched: List[Int]
    var selected: Int
    var scroll: Int
    # Submission output — index into ``entries`` (not ``matched``), set
    # before ``submitted`` flips True so the host doesn't have to keep
    # the picker alive after consuming.
    var selected_index: Int
    # Cached input strip rect for mouse routing.
    var _input_rect: Rect
    # Visible list height captured on the most recent ``paint`` so
    # ``_scroll_to_selection`` reveals against the real (clamped) viewport.
    var _revealed_height: Int

    def __init__(out self):
        self.active = False
        self.submitted = False
        self.display = String("")
        self.query = TextField()
        self.entries = List[DocEntry]()
        self._haystacks = List[String]()
        self.matched = List[Int]()
        self.selected = 0
        self.scroll = 0
        self.selected_index = -1
        self._input_rect = Rect(0, 0, 0, 0)
        self._revealed_height = 16

    def open(
        mut self, var display: String, var entries: List[DocEntry],
    ):
        """Open the picker with ``entries`` already loaded."""
        self.display = display^
        self.entries = entries^
        # Precompute the ``type_name.name`` haystacks once so ``_refilter``
        # is a pure per-entry match with no string concatenation.
        self._haystacks = List[String]()
        for i in range(len(self.entries)):
            if len(self.entries[i].type_name.as_bytes()) > 0:
                self._haystacks.append(
                    self.entries[i].type_name + String(".")
                    + self.entries[i].name
                )
            else:
                self._haystacks.append(self.entries[i].name)
        self.query = TextField()
        self.active = True
        self.submitted = False
        self.matched = List[Int]()
        self.selected = 0
        self.scroll = 0
        self.selected_index = -1
        self._input_rect = Rect(0, 0, 0, 0)
        self._revealed_height = 16
        self._refilter()

    def close(mut self):
        self.active = False
        self.submitted = False
        self.display = String("")
        self.query = TextField()
        self.entries = List[DocEntry]()
        self._haystacks = List[String]()
        self.matched = List[Int]()
        self.selected = 0
        self.scroll = 0
        self.selected_index = -1
        self._input_rect = Rect(0, 0, 0, 0)
        self._revealed_height = 16

    # --- filtering --------------------------------------------------------

    def _refilter(mut self):
        self.matched = List[Int]()
        if len(self.query.text.as_bytes()) == 0:
            for i in range(len(self.entries)):
                self.matched.append(i)
        else:
            # Match against the precomputed ``type.name`` haystacks so the
            # user can type a section prefix (e.g. ``stdt`` for ``str.find``
            # under "Standard Types") to narrow nested entries. Fall back to
            # computing inline if the cache is somehow out of sync with
            # ``entries`` (it shouldn't be — ``open`` builds both together).
            var cached = len(self._haystacks) == len(self.entries)
            for i in range(len(self.entries)):
                var hay: String
                if cached:
                    hay = self._haystacks[i]
                elif len(self.entries[i].type_name.as_bytes()) > 0:
                    hay = self.entries[i].type_name + String(".") \
                        + self.entries[i].name
                else:
                    hay = self.entries[i].name
                if quick_open_match(hay, self.query.text):
                    self.matched.append(i)
        self.selected = 0
        self.scroll = 0

    # --- geometry ---------------------------------------------------------

    def _rect(self, container_bounds: Rect) -> Rect:
        var width = 80
        var height = 22
        if width > container_bounds.b.x - 4: width = container_bounds.b.x - 4
        if height > container_bounds.b.y - 4: height = container_bounds.b.y - 4
        return center_in(container_bounds, width, height)

    def is_input_at(self, pos: Point, container_bounds: Rect) -> Bool:
        if not self.active:
            return False
        var rect = self._rect(container_bounds)
        return build_picker_layout(rect, _LABEL_W).input_rect.contains(pos)

    # --- paint ------------------------------------------------------------

    def paint(mut self, mut canvas: Canvas, container_bounds: Rect):
        if not self.active:
            return
        var bg          = Attr(BLACK,  LIGHT_GRAY)
        var sel_attr    = Attr(BLACK,  YELLOW)
        var hint_attr   = Attr(BLUE,   LIGHT_GRAY)
        var type_attr   = Attr(BLUE,   LIGHT_GRAY)
        var sel_type    = Attr(BLUE,   YELLOW)
        var rect = self._rect(container_bounds)
        var layout = build_picker_layout(rect, _LABEL_W)
        var painter = paint_modal_frame(canvas, rect, bg)
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
        self._revealed_height = h
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
                var tx2 = rect.a.x + 2 + display_columns(ent.name) + 2
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

    def handle_key(mut self, event: Event) -> Bool:
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

    def handle_mouse(mut self, event: Event, container_bounds: Rect) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_MOUSE:
            return True
        var rect = self._rect(container_bounds)
        var layout = build_picker_layout(rect, _LABEL_W)
        # Standard ``[■]`` close button — equivalent to ESC. Checked
        # before input/list routing so a click on the chrome glyph
        # always dismisses the dialog.
        if close_button_clicked(rect, event):
            self.close()
            return True
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

    def _scroll_to_selection(mut self):
        self.scroll = scroll_to_reveal(self.scroll, self.selected, self._revealed_height)
