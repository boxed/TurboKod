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
from .geometry import Point, Rect, center_in
from .lsp_dispatch import SymbolItem
from .picker_input import (
    build_picker_layout, picker_nav_key, picker_wheel_scroll,
    scroll_to_reveal,
)
from .quick_open import quick_open_match
from .string_utils import display_columns
from .text_field import TextField
from .window import close_button_clicked, paint_close_button, paint_window_title


comptime _LABEL = String(" Find: ")
comptime _LABEL_W = 7
"""Columns occupied by the inline search label (``" Find: "``)."""


struct SymbolPick(Movable):
    var active: Bool
    var loading: Bool       # True while waiting for the LSP response
    var submitted: Bool
    var path: String        # the file the symbols belong to
    var query: TextField
    var entries: List[SymbolItem]
    # Precomputed ``container.name`` (or bare ``name``) match haystacks,
    # parallel to ``entries`` — built once in ``set_entries`` so
    # ``_refilter`` doesn't reconcatenate per entry on every keystroke.
    var _haystacks: List[String]
    var matched: List[Int]
    var selected: Int
    var scroll: Int
    # Submission output — read after ``submitted`` flips True.
    var selected_line: Int
    var selected_character: Int
    # Cached input strip rect for mouse routing.
    var _input_rect: Rect
    # Visible list height captured on the most recent ``paint`` so
    # ``_scroll_to_selection`` reveals against the real (clamped) viewport.
    var _revealed_height: Int

    def __init__(out self):
        self.active = False
        self.loading = False
        self.submitted = False
        self.path = String("")
        self.query = TextField()
        self.entries = List[SymbolItem]()
        self._haystacks = List[String]()
        self.matched = List[Int]()
        self.selected = 0
        self.scroll = 0
        self.selected_line = 0
        self.selected_character = 0
        self._input_rect = Rect(0, 0, 0, 0)
        self._revealed_height = 14

    def open(mut self, var path: String):
        """Open the picker in a loading state for ``path``. Entries arrive
        later via ``set_entries`` once the LSP responds."""
        self.path = path^
        self.query = TextField()
        self.active = True
        self.loading = True
        self.submitted = False
        self.entries = List[SymbolItem]()
        self._haystacks = List[String]()
        self.matched = List[Int]()
        self.selected = 0
        self.scroll = 0
        self.selected_line = 0
        self.selected_character = 0
        self._input_rect = Rect(0, 0, 0, 0)
        self._revealed_height = 14

    def set_entries(mut self, var items: List[SymbolItem]):
        """Populate the picker with the response and clear the loading flag.
        Refilters with the current query in case the user typed while we
        were waiting."""
        self.entries = items^
        # Precompute the ``container.name`` haystacks once so ``_refilter``
        # is a pure per-entry match with no string concatenation.
        self._haystacks = List[String]()
        for i in range(len(self.entries)):
            if len(self.entries[i].container.as_bytes()) > 0:
                self._haystacks.append(
                    self.entries[i].container + String(".")
                    + self.entries[i].name
                )
            else:
                self._haystacks.append(self.entries[i].name)
        self.loading = False
        self._refilter()

    def close(mut self):
        self.active = False
        self.loading = False
        self.submitted = False
        self.path = String("")
        self.query = TextField()
        self.entries = List[SymbolItem]()
        self._haystacks = List[String]()
        self.matched = List[Int]()
        self.selected = 0
        self.scroll = 0
        self._input_rect = Rect(0, 0, 0, 0)
        self._revealed_height = 14

    # --- filtering --------------------------------------------------------

    def _refilter(mut self):
        self.matched = List[Int]()
        if len(self.query.text.as_bytes()) == 0:
            for i in range(len(self.entries)):
                self.matched.append(i)
        else:
            # Match against the precomputed ``container.name`` haystacks so
            # users can type a parent-class prefix to narrow nested methods.
            # Fall back to computing inline if the cache is somehow out of
            # sync with ``entries`` (it shouldn't be — ``set_entries`` builds
            # both together).
            var cached = len(self._haystacks) == len(self.entries)
            for i in range(len(self.entries)):
                var hay: String
                if cached:
                    hay = self._haystacks[i]
                elif len(self.entries[i].container.as_bytes()) > 0:
                    hay = self.entries[i].container + String(".") \
                        + self.entries[i].name
                else:
                    hay = self.entries[i].name
                if quick_open_match(hay, self.query.text):
                    self.matched.append(i)
        self.selected = 0
        self.scroll = 0

    # --- geometry ---------------------------------------------------------

    def _rect(self, container_bounds: Rect) -> Rect:
        var width = 70
        var height = 20
        if width > container_bounds.b.x - 4: width = container_bounds.b.x - 4
        if height > container_bounds.b.y - 4: height = container_bounds.b.y - 4
        return center_in(container_bounds, width, height)

    def is_input_at(self, pos: Point, container_bounds: Rect) -> Bool:
        """True iff ``pos`` lies on the ``Find:`` query row."""
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
        var kind_attr   = Attr(BLUE,   LIGHT_GRAY)
        var sel_kind    = Attr(BLUE,   YELLOW)
        var rect = self._rect(container_bounds)
        var layout = build_picker_layout(rect, _LABEL_W)
        paint_drop_shadow(canvas, rect)
        var painter = Painter(rect)
        painter.fill(canvas, rect, String(" "), bg)
        painter.draw_box(canvas, rect, bg, False)
        paint_window_title(canvas, rect, String(" Go to Symbol "), bg, bg)
        # Standard ``[■]`` close button at the top-LEFT — equivalent to
        # ESC / cancel. Same chrome the editor windows and other dialogs
        # use, painted via the shared ``paint_close_button`` helper.
        paint_close_button(canvas, Point(rect.a.x, rect.a.y), bg)
        # Search line.
        _ = painter.put_text(canvas, layout.input_label_pt, _LABEL, bg)
        self._input_rect = layout.input_rect
        self.query.paint(canvas, layout.input_rect, True)
        # Listing.
        var top = layout.list_top
        var h = layout.list_height
        self._revealed_height = h
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
            var name_x = rect.a.x + 2 + display_columns(kind_label) + 1
            _ = painter.put_text(
                canvas, Point(name_x, top + i), sym.name, row_attr,
            )
            if len(sym.container.as_bytes()) > 0:
                var cx = name_x + display_columns(sym.name) + 2
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

    def handle_key(mut self, event: Event) -> Bool:
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
            var sym = self.entries[self.matched[idx]]
            self.selected_line = sym.line
            self.selected_character = sym.character
            self.submitted = True
            return True
        self.selected = idx
        return True

    def _scroll_to_selection(mut self):
        self.scroll = scroll_to_reveal(self.scroll, self.selected, self._revealed_height)


def symbol_kind_label(kind: Int) -> String:
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
