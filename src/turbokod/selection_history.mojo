"""SelectionHistory: a paned "show git history for selection" modal.

The user selects a line range in an editor and asks for its history; this
view shows, side by side, the commits that touched those lines (left) and
the range-scoped patch of the focused commit (right). It is the
``git log -L<start>,<end>:<file>`` feature — git follows the lines across
renames, so the list is the true evolution of *that code*, not just the
file.

Like every other modal here it is a frontend-agnostic in-grid surface
(``Canvas`` out, ``Event`` in): it paints into the canvas and consumes
events, so it works identically in the terminal and native macOS
frontends with no host-specific code. The whole thing is fully modal —
``handle_event`` swallows every event while active, the same shape as the
ReviewMode picker — so the ``Desktop`` routes input to it ahead of the
hotkey table.

The left list reuses :struct:`ListBox` for selection + scroll state; the
right pane paints the unified diff with the usual diff colors (added
green, removed red, hunk-header cyan, file-header yellow), vertically
scrolled by ``patch_scroll``.
"""

from std.collections.list import List

from .canvas import Canvas
from .colors import (
    Attr, BLUE, CYAN, DARK_GRAY, EDITOR_BG, EDITOR_FG, GREEN, LIGHT_RED,
    WHITE, YELLOW,
)
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_DOWN, KEY_END, KEY_ESC, KEY_HOME, KEY_PAGEDOWN, KEY_PAGEUP, KEY_UP,
    MOUSE_BUTTON_LEFT, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .geometry import Point, Rect
from .git_changes import LineHistoryEntry
from .list_box import ListBox
from .painter import Painter
from .string_utils import display_columns, split_lines_no_trailing, starts_with


@fieldwise_init
struct _HistLayout(Copyable, Movable):
    """Pre-computed geometry shared by ``paint`` and ``handle_event`` so
    the two never disagree about where the panes are."""
    var title_y: Int
    var hint_y: Int
    var divider_x: Int
    var list_rect: Rect
    var patch_rect: Rect


def _patch_attr(line: String) -> Attr:
    """Diff color for one patch line: hunk header cyan, file headers
    yellow/gray, added green, removed red, context the editor fg."""
    if starts_with(line, String("@@")):
        return Attr(CYAN, EDITOR_BG)
    if starts_with(line, String("+++")) or starts_with(line, String("---")):
        return Attr(DARK_GRAY, EDITOR_BG)
    if starts_with(line, String("diff --git")) \
            or starts_with(line, String("index ")) \
            or starts_with(line, String("new file")) \
            or starts_with(line, String("deleted file")) \
            or starts_with(line, String("rename ")) \
            or starts_with(line, String("similarity ")):
        return Attr(YELLOW, EDITOR_BG)
    var b = line.as_bytes()
    if len(b) > 0 and b[0] == 0x2B:  # '+'
        return Attr(GREEN, EDITOR_BG)
    if len(b) > 0 and b[0] == 0x2D:  # '-'
        return Attr(LIGHT_RED, EDITOR_BG)
    return Attr(EDITOR_FG, EDITOR_BG)


struct SelectionHistory(Movable):
    var active: Bool
    var title: String
    """Display title, e.g. ``editor.mojo:40-46``."""
    var entries: List[LineHistoryEntry]
    var list: ListBox
    var patch_scroll: Int

    def __init__(out self):
        self.active = False
        self.title = String("")
        self.entries = List[LineHistoryEntry]()
        self.list = ListBox()
        self.patch_scroll = 0

    def open(mut self, var title: String, var entries: List[LineHistoryEntry]):
        self.title = title^
        self.entries = entries^
        self.list.reset()
        if len(self.entries) > 0:
            self.list.set_selected(0)
        self.patch_scroll = 0
        self.active = True

    def close(mut self):
        self.active = False
        self.title = String("")
        self.entries = List[LineHistoryEntry]()
        self.list.reset()
        self.patch_scroll = 0

    def _list_items(self) -> List[String]:
        """``<sha>  <date>  <subject>`` per commit. Truncation to the
        pane width is the list widget's job (it clips to its bounds)."""
        var out = List[String]()
        for i in range(len(self.entries)):
            var e = self.entries[i]
            out.append(
                e.short_sha + String("  ") + e.date + String("  ") + e.subject
            )
        return out^

    def _patch_lines(self) -> List[String]:
        var sel = self.list.selected
        if sel < 0 or sel >= len(self.entries):
            return List[String]()
        return split_lines_no_trailing(self.entries[sel].patch)

    def _layout(self, screen: Rect, top_y: Int) -> _HistLayout:
        var x0 = screen.a.x
        var x1 = screen.b.x
        var total_w = x1 - x0
        var lw = (total_w * 4) // 10
        if lw > 48:
            lw = 48
        if lw < 16:
            lw = 16
        if lw > total_w - 6:
            lw = total_w // 2
        var divider_x = x0 + lw
        var body_y0 = top_y + 1
        var hint_y = screen.b.y - 1
        var body_y1 = hint_y
        return _HistLayout(
            top_y, hint_y, divider_x,
            Rect(x0, body_y0, divider_x, body_y1),
            Rect(divider_x + 1, body_y0, x1, body_y1),
        )

    def _clamp_patch_scroll(mut self, viewport_h: Int):
        var n = len(self._patch_lines())
        var maxs = n - viewport_h
        if maxs < 0:
            maxs = 0
        if self.patch_scroll > maxs:
            self.patch_scroll = maxs
        if self.patch_scroll < 0:
            self.patch_scroll = 0

    def paint(mut self, mut canvas: Canvas, screen: Rect, top_y: Int):
        if not self.active:
            return
        var lay = self._layout(screen, top_y)
        var x0 = screen.a.x
        var x1 = screen.b.x
        var bar_attr = Attr(WHITE, BLUE)
        var body_attr = Attr(EDITOR_FG, EDITOR_BG)
        # Mask the whole surface (title row through hint row) so the
        # windows beneath don't bleed through.
        canvas.fill(
            Rect(x0, lay.title_y, x1, screen.b.y), String(" "), body_attr,
        )
        # Title bar.
        canvas.fill(
            Rect(x0, lay.title_y, x1, lay.title_y + 1), String(" "), bar_attr,
        )
        var title_painter = Painter(
            Rect(x0, lay.title_y, x1, lay.title_y + 1)
        )
        _ = title_painter.put_text(
            canvas, Point(x0 + 1, lay.title_y),
            String("Git History — ") + self.title, bar_attr,
        )
        if len(self.entries) == 0:
            var msg = String(
                "No history for this selection (file untracked or unchanged)."
            )
            var mid_y = (lay.title_y + 1 + lay.hint_y) // 2
            var mx = x0 + ((x1 - x0) - display_columns(msg)) // 2
            if mx < x0:
                mx = x0
            var body_painter = Painter(
                Rect(x0, lay.title_y + 1, x1, lay.hint_y)
            )
            _ = body_painter.put_text(
                canvas, Point(mx, mid_y), msg, Attr(DARK_GRAY, EDITOR_BG),
            )
            self._paint_hint(canvas, lay, bar_attr, x0, x1)
            return
        # Vertical divider between the panes.
        canvas.fill(
            Rect(lay.divider_x, lay.title_y + 1, lay.divider_x + 1, lay.hint_y),
            String("│"), Attr(DARK_GRAY, EDITOR_BG),
        )
        # Left pane — commit list.
        var items = self._list_items()
        self.list.paint(canvas, lay.list_rect, items, True, body_attr)
        # Right pane — patch of the selected commit.
        self._clamp_patch_scroll(lay.patch_rect.height())
        canvas.fill(lay.patch_rect, String(" "), body_attr)
        var patch_painter = Painter(lay.patch_rect)
        var lines = self._patch_lines()
        var visible = lay.patch_rect.height()
        for r in range(visible):
            var idx = self.patch_scroll + r
            if idx >= len(lines):
                break
            _ = patch_painter.put_text(
                canvas, Point(lay.patch_rect.a.x, lay.patch_rect.a.y + r),
                lines[idx], _patch_attr(lines[idx]),
            )
        self._paint_hint(canvas, lay, bar_attr, x0, x1)

    def _paint_hint(
        self, mut canvas: Canvas, lay: _HistLayout, bar_attr: Attr,
        x0: Int, x1: Int,
    ):
        canvas.fill(
            Rect(x0, lay.hint_y, x1, lay.hint_y + 1), String(" "), bar_attr,
        )
        var hint_painter = Painter(Rect(x0, lay.hint_y, x1, lay.hint_y + 1))
        _ = hint_painter.put_text(
            canvas, Point(x0 + 1, lay.hint_y),
            String("↑↓ commit · PgUp/PgDn scroll · Esc close"), bar_attr,
        )

    def handle_event(mut self, event: Event, screen: Rect, top_y: Int) -> Bool:
        """Fully modal: returns True for every event while active so
        nothing leaks to the editor behind the overlay."""
        if not self.active:
            return False
        var lay = self._layout(screen, top_y)
        var n = len(self.entries)
        if event.kind == EVENT_KEY:
            var k = event.key
            if k == KEY_ESC:
                self.close()
                return True
            if k == KEY_UP:
                if self.list.move_selection(-1, n):
                    self.patch_scroll = 0
                return True
            if k == KEY_DOWN:
                if self.list.move_selection(1, n):
                    self.patch_scroll = 0
                return True
            if k == KEY_HOME:
                if n > 0:
                    self.list.set_selected(0)
                    self.patch_scroll = 0
                return True
            if k == KEY_END:
                if n > 0:
                    self.list.set_selected(n - 1)
                    self.patch_scroll = 0
                return True
            if k == KEY_PAGEUP:
                self.patch_scroll -= lay.patch_rect.height()
                self._clamp_patch_scroll(lay.patch_rect.height())
                return True
            if k == KEY_PAGEDOWN:
                self.patch_scroll += lay.patch_rect.height()
                self._clamp_patch_scroll(lay.patch_rect.height())
                return True
            return True
        if event.kind == EVENT_MOUSE:
            # Wheel over the right pane scrolls the patch; everywhere
            # else (incl. wheel over the list) is the list widget's job.
            if event.button == MOUSE_WHEEL_UP \
                    and lay.patch_rect.contains(event.pos):
                self.patch_scroll -= 3
                self._clamp_patch_scroll(lay.patch_rect.height())
                return True
            if event.button == MOUSE_WHEEL_DOWN \
                    and lay.patch_rect.contains(event.pos):
                self.patch_scroll += 3
                self._clamp_patch_scroll(lay.patch_rect.height())
                return True
            if self.list.handle_mouse_press(event, lay.list_rect, n):
                # A left-click changes selection — reset the patch view.
                # A wheel-scroll over the list only moves the viewport.
                if event.button == MOUSE_BUTTON_LEFT:
                    self.patch_scroll = 0
                return True
            return True
        return True
