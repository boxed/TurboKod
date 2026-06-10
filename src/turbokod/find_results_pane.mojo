"""FindResultsPane: a persistent, bottom-dockable + floatable list of
Find-in-Project results.

The Cmd+Shift+F modal (``ProjectFind``) is the live-search entry point;
when the user clicks its ``[ Panel ]`` button (or hits Cmd+Enter) the host
hands the current result set to this pane so they can keep it open and
triage it while working — the modal closes, the hits live on.

Unlike the modal (single-shot: Enter opens one hit and dismisses), the
pane supports multi-select: Cmd-click toggles a row, Shift-click selects a
contiguous range from the anchor, Space toggles the cursor row. Enter or a
double-click opens every selected hit (falling back to the cursor row when
nothing is marked) — the host drains ``pending_opens`` each frame and opens
each in its own editor window.

It wraps a ``BottomDockedPanel`` for chrome (title row, min/max/close,
resize) exactly like the debug / test panes, so the docking + floating
layout machinery treats it as just another tool pane. Row rendering reuses
``project_find.paint_match_row`` so the list looks identical to the modal's.
"""

from std.collections.list import List

from .canvas import Canvas
from .cell import Cell
from .colors import (
    Attr, BLACK, CYAN, EDITOR_BG, EDITOR_FG, RED, WHITE, YELLOW,
)
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE, KEY_ENTER, KEY_SPACE,
    MOD_META, MOD_SHIFT, MOUSE_BUTTON_LEFT, MOUSE_BUTTON_NONE,
)
from .geometry import Point, Rect
from .highlight import GrammarRegistry, Highlight
from .painter import Painter
from .picker_input import picker_nav_key, picker_wheel_scroll, scroll_to_reveal
from .posix import monotonic_ms
from .project import ProjectMatch
from .project_find import paint_match_row
from .string_utils import display_columns
from .window import (
    BottomDockedPanel, handle_bottom_dock_chrome_mouse,
    paint_bottom_dock_chrome,
)


# Per-paint-frame budget for *fresh* row tokenization — same rationale as
# ``ProjectFind`` (cached rows are free; cache misses are gated so a result
# set that lands on a minified bundle can't freeze arrow navigation).
comptime _ROW_HL_BUDGET_MS: Int = 20
# Fallback visible-row count for scroll-reveal before the first paint
# stamps the real list height.
comptime _DEFAULT_LIST_H: Int = 8


struct FindResultsPane(Movable):
    var visible: Bool
    var focused: Bool
    var dock: BottomDockedPanel
    var matches: List[ProjectMatch]
    var query: String                  # the search term (for hit highlight)
    var root: String
    var selected: Int                  # cursor row (keyboard nav + range end)
    var anchor: Int                    # Shift-range origin
    var scroll: Int
    var marked: List[Bool]             # multi-select set, parallel to matches
    # Output queue: matches the user asked to open this frame. The host
    # drains it via ``take_pending_opens`` and opens each in its own editor.
    var pending_opens: List[ProjectMatch]
    # Per-row syntax-highlight cache (aligned 1:1 with ``matches``), same
    # shape ``ProjectFind`` keeps so ``paint_match_row`` can reuse it.
    var _row_hl_cache: List[List[Highlight]]
    var _row_hl_cached: List[Bool]
    # Stamped each paint so ``handle_mouse`` maps clicks back to rows.
    var _list_top: Int
    var _list_height: Int

    def __init__(out self):
        self.visible = False
        self.focused = False
        self.dock = BottomDockedPanel(preferred_height=12)
        self.matches = List[ProjectMatch]()
        self.query = String("")
        self.root = String("")
        self.selected = 0
        self.anchor = 0
        self.scroll = 0
        self.marked = List[Bool]()
        self.pending_opens = List[ProjectMatch]()
        self._row_hl_cache = List[List[Highlight]]()
        self._row_hl_cached = List[Bool]()
        self._list_top = 0
        self._list_height = 0

    def load(
        mut self, var matches: List[ProjectMatch], var query: String,
        var root: String,
    ):
        """Replace the displayed result set and show the pane. Resets
        selection / scroll / marks; the dock's size + min/max state is left
        as the user last set it so re-running a search keeps the layout."""
        self.matches = matches^
        self.query = query^
        self.root = root^
        self.selected = 0
        self.anchor = 0
        self.scroll = 0
        self.marked = List[Bool]()
        for _i in range(len(self.matches)):
            self.marked.append(False)
        self.pending_opens = List[ProjectMatch]()
        self._row_hl_cache = List[List[Highlight]]()
        self._row_hl_cached = List[Bool]()
        self.visible = True

    def close(mut self):
        self.visible = False
        self.focused = False

    def is_resizing(self) -> Bool:
        return self.dock.is_resizing()

    def is_on_resize_edge(self, pos: Point, panel: Rect) -> Bool:
        return self.dock.is_on_resize_edge(pos, panel)

    def consume_command_id(mut self) -> String:
        """Title-strip / ``[■]`` close command the user clicked, or empty.
        Polled by the host each frame — same channel the other panes use."""
        return self.dock.consume_command_id()

    def take_pending_opens(mut self) -> List[ProjectMatch]:
        """Move out the hits the user asked to open since the last call."""
        var out = self.pending_opens^
        self.pending_opens = List[ProjectMatch]()
        return out^

    # --- selection helpers ------------------------------------------------

    def _marked_count(self) -> Int:
        var n = 0
        for i in range(len(self.marked)):
            if self.marked[i]:
                n += 1
        return n

    def _select_only(mut self, i: Int):
        """Plain click / nav: ``i`` becomes the cursor + anchor and the
        multi-select set is cleared."""
        self.selected = i
        self.anchor = i
        for k in range(len(self.marked)):
            self.marked[k] = False

    def _toggle_mark(mut self, i: Int):
        if 0 <= i and i < len(self.marked):
            self.marked[i] = not self.marked[i]
            self.selected = i
            self.anchor = i

    def _range_to(mut self, i: Int):
        """Shift-select: mark the contiguous range between ``anchor`` and
        ``i`` (replacing any prior marks), leaving the cursor on ``i``."""
        var lo = self.anchor
        var hi = i
        if lo > hi:
            lo = i
            hi = self.anchor
        for k in range(len(self.marked)):
            self.marked[k] = (k >= lo and k <= hi)
        self.selected = i

    def _queue_opens(mut self):
        """Push the hits to open: every marked row, or the cursor row when
        nothing is marked."""
        if self._marked_count() > 0:
            for i in range(len(self.matches)):
                if i < len(self.marked) and self.marked[i]:
                    self.pending_opens.append(self.matches[i])
        elif 0 <= self.selected and self.selected < len(self.matches):
            self.pending_opens.append(self.matches[self.selected])

    def _reveal_selection(mut self):
        var window = self._list_height if self._list_height > 0 \
            else _DEFAULT_LIST_H
        self.scroll = scroll_to_reveal(self.scroll, self.selected, window)

    # --- paint ------------------------------------------------------------

    def paint(
        mut self, mut canvas: Canvas, panel: Rect, mut registry: GrammarRegistry,
    ):
        if not self.visible or panel.is_empty():
            return
        # Body uses the editor/document background so the pane matches the
        # Find-in-Project modal it was sent from (the title row stays the
        # standard tool-pane chrome painted by ``paint_bottom_dock_chrome``).
        var bg          = Attr(YELLOW, EDITOR_BG)
        var line_attr   = Attr(YELLOW, EDITOR_BG)
        var sel_line    = Attr(BLACK,  YELLOW)
        var mark_line   = Attr(BLACK,  CYAN)
        var hl_attr     = Attr(WHITE,  RED)
        var path_attr   = Attr(EDITOR_FG, EDITOR_BG)
        var sel_path    = Attr(BLACK,  YELLOW)
        var mark_path   = Attr(BLACK,  CYAN)
        var dim         = Attr(EDITOR_FG, EDITOR_BG)
        var painter = Painter(panel)
        painter.fill(canvas, panel, String(" "), bg)
        # Title row: ``Find: <query> (N hits, M selected)``.
        var title = String("Find Results")
        if len(self.query.as_bytes()) > 0:
            title = String("Find: ") + self.query
        var info = String(" (") + String(len(self.matches)) + String(" hits")
        var sel_n = self._marked_count()
        if sel_n > 0:
            info += String(", ") + String(sel_n) + String(" selected")
        info += String(")")
        var body = paint_bottom_dock_chrome(
            canvas, painter, panel, title + info, self.focused, self.dock,
            hotkey_label=String(""),
        )
        # MINIMIZED → only the title row painted; nothing more to do, but
        # keep a clean list-geometry record so a stray click can't hit a
        # stale row mapping.
        if body.is_empty():
            self._list_top = panel.a.y + 1
            self._list_height = 0
            return
        self._list_top = body.a.y
        self._list_height = body.b.y - body.a.y
        if len(self.matches) == 0:
            _ = painter.put_text(
                canvas, Point(panel.a.x + 2, body.a.y), String("No results."), dim,
            )
            return
        # Clamp scroll to the current list (a min/max toggle or resize can
        # shrink the viewport out from under a deep scroll position).
        var max_scroll = len(self.matches) - self._list_height
        if max_scroll < 0:
            max_scroll = 0
        if self.scroll > max_scroll:
            self.scroll = max_scroll
        if self.scroll < 0:
            self.scroll = 0
        # Keep the row-highlight cache aligned 1:1 with ``matches``.
        while len(self._row_hl_cache) < len(self.matches):
            self._row_hl_cache.append(List[Highlight]())
            self._row_hl_cached.append(False)
        var hl_deadline = monotonic_ms() + _ROW_HL_BUDGET_MS
        for i in range(self._list_height):
            var idx = self.scroll + i
            if idx >= len(self.matches):
                break
            var m = self.matches[idx]
            var is_sel = idx == self.selected
            var is_marked = idx < len(self.marked) and self.marked[idx]
            # Cursor row → yellow (no overlay). Marked-but-not-cursor →
            # cyan tint + ✓, overlay forced off so the tint stays clean.
            # Plain row → normal text + syntax overlay.
            var row_line = line_attr
            var row_path = path_attr
            var force_plain = False
            if not is_sel and is_marked:
                row_line = mark_line
                row_path = mark_path
                force_plain = True
            var mark = String("✓") if is_marked else String("")
            paint_match_row(
                canvas, panel, painter, body.a.y + i, m, is_sel, self.query,
                row_line, sel_line, hl_attr, hl_attr, row_path, sel_path,
                registry, idx, hl_deadline,
                self._row_hl_cache, self._row_hl_cached,
                mark, force_plain,
            )

    # --- events -----------------------------------------------------------

    def handle_key(mut self, event: Event) -> Bool:
        """Consume nav / Space / Enter when focused; return False for
        anything else so the host's global dispatch still runs."""
        if not self.focused or not self.visible:
            return False
        if event.kind != EVENT_KEY:
            return False
        var k = event.key
        if picker_nav_key(k, len(self.matches), self.selected):
            self.anchor = self.selected
            self._reveal_selection()
            return True
        if k == KEY_ENTER:
            self._queue_opens()
            return True
        if k == KEY_SPACE:
            self._toggle_mark(self.selected)
            return True
        return False

    def handle_mouse(
        mut self, event: Event, panel: Rect, allow_resize: Bool = True,
    ) -> Bool:
        if event.kind != EVENT_MOUSE:
            return False
        # Chrome (top border + min/max/close + resize) gets first dibs.
        var cr = handle_bottom_dock_chrome_mouse(
            event, panel, self.dock, allow_resize,
        )
        if cr.consumed:
            if cr.focus_request:
                self.focused = True
            return True
        if not panel.contains(event.pos):
            # A bare press outside the pane drops focus (mouse-mode 1003
            # delivers hover with no button — don't steal focus on those).
            if event.button != MOUSE_BUTTON_NONE and event.pressed \
                    and not event.motion:
                self.focused = False
            return False
        # Wheel scrolls the list.
        if event.pressed and not event.motion:
            if picker_wheel_scroll(
                event.button, self.scroll, len(self.matches), self._list_height,
            ):
                self.focused = True
                return True
        if event.button != MOUSE_BUTTON_LEFT:
            return True
        if not event.pressed or event.motion:
            return True
        self.focused = True
        # Below the title row but inside the pane: a row click.
        if self._list_height <= 0 \
                or event.pos.y < self._list_top \
                or event.pos.y >= self._list_top + self._list_height:
            return True
        var idx = self.scroll + (event.pos.y - self._list_top)
        if idx < 0 or idx >= len(self.matches):
            return True
        if (event.mods & MOD_META) != 0:
            self._toggle_mark(idx)
            return True
        if (event.mods & MOD_SHIFT) != 0:
            self._range_to(idx)
            return True
        # Plain click selects only this row; a double-click opens.
        self._select_only(idx)
        if event.click_count >= 2:
            self._queue_opens()
        return True
