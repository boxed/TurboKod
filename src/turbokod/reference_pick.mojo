"""ReferencePick: list-of-locations picker for ``textDocument/references``.

A modal centered dialog, like ``SymbolPick``, but populated from a
references response. Each row is one usage site (path + 1-based line +
0-based column). Enter / click jumps to the selected entry; ESC cancels.

The host opens this only when a references response has two or more
entries — zero is a status-bar message, one is a direct jump. So the
picker doesn't have to model a loading state or a "no results" view.
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
from .file_io import basename
from .geometry import Point, Rect
from .lsp_dispatch import DefinitionResolved
from .picker_input import picker_nav_key, picker_wheel_scroll
from .string_utils import display_columns, starts_with
from .window import paint_window_title


struct ReferencePick(Movable):
    var active: Bool
    var submitted: Bool
    var entries: List[DefinitionResolved]
    var word: String
    var project_root: String     # for displaying paths relative to the project
    var selected: Int
    var scroll: Int
    # Submission output — read after ``submitted`` flips True.
    var selected_path: String
    var selected_line: Int
    var selected_character: Int

    def __init__(out self):
        self.active = False
        self.submitted = False
        self.entries = List[DefinitionResolved]()
        self.word = String("")
        self.project_root = String("")
        self.selected = 0
        self.scroll = 0
        self.selected_path = String("")
        self.selected_line = 0
        self.selected_character = 0

    def open(
        mut self, var entries: List[DefinitionResolved],
        var word: String, var project_root: String,
    ):
        """Open the picker with ``entries``. ``word`` is shown in the
        title bar; ``project_root`` (may be empty) is used to render
        paths relative to the project for readability."""
        self.entries = entries^
        self.word = word^
        self.project_root = project_root^
        self.active = True
        self.submitted = False
        self.selected = 0
        self.scroll = 0
        self.selected_path = String("")
        self.selected_line = 0
        self.selected_character = 0

    def close(mut self):
        self.active = False
        self.submitted = False
        self.entries = List[DefinitionResolved]()
        self.word = String("")
        self.project_root = String("")
        self.selected = 0
        self.scroll = 0

    # --- geometry ---------------------------------------------------------

    def _rect(self, screen: Rect) -> Rect:
        var width = 80
        var height = 20
        if width > screen.b.x - 4: width = screen.b.x - 4
        if height > screen.b.y - 4: height = screen.b.y - 4
        var x = (screen.b.x - width) // 2
        var y = (screen.b.y - height) // 2
        return Rect(x, y, x + width, y + height)

    def _list_top(self, rect: Rect) -> Int:
        return rect.a.y + 1

    def _list_height(self, rect: Rect) -> Int:
        var hint_y = rect.b.y - 1
        var top = self._list_top(rect)
        var h = hint_y - top
        if h < 0:
            h = 0
        return h

    # --- paint ------------------------------------------------------------

    def _display_path(self, path: String) -> String:
        """Render ``path`` relative to the project root when possible,
        falling back to the absolute path."""
        if len(self.project_root.as_bytes()) == 0:
            return path
        var root = self.project_root
        if not _ends_with_slash(root):
            root = root + String("/")
        if starts_with(path, root):
            var pb = path.as_bytes()
            var rb = root.as_bytes()
            return String(StringSlice(unsafe_from_utf8=pb[len(rb):]))
        return path

    def paint(mut self, mut canvas: Canvas, screen: Rect):
        if not self.active:
            return
        var bg          = Attr(BLACK,  LIGHT_GRAY)
        var sel_attr    = Attr(BLACK,  YELLOW)
        var hint_attr   = Attr(BLUE,   LIGHT_GRAY)
        var meta_attr   = Attr(BLUE,   LIGHT_GRAY)
        var sel_meta    = Attr(BLUE,   YELLOW)
        var rect = self._rect(screen)
        paint_drop_shadow(canvas, rect)
        var painter = Painter(rect)
        painter.fill(canvas, rect, String(" "), bg)
        painter.draw_box(canvas, rect, bg, False)
        var title = String(" References")
        if len(self.word.as_bytes()) > 0:
            title = title + String(": ") + self.word
        title = title + String(" ")
        paint_window_title(canvas, rect, title^, bg, bg)
        var top = self._list_top(rect)
        var h = self._list_height(rect)
        for i in range(h):
            var idx = self.scroll + i
            if idx >= len(self.entries):
                break
            var entry = self.entries[idx]
            var is_sel = (idx == self.selected)
            var row_attr = sel_attr if is_sel else bg
            var m_attr = sel_meta if is_sel else meta_attr
            painter.fill(
                canvas, Rect(rect.a.x + 1, top + i, rect.b.x - 1, top + i + 1),
                String(" "), row_attr,
            )
            var disp = self._display_path(entry.path)
            _ = painter.put_text(
                canvas, Point(rect.a.x + 2, top + i), disp, row_attr,
            )
            # Right-aligned line:col stamp.
            var stamp = String(":") + String(entry.line + 1) \
                + String(":") + String(entry.character + 1)
            var stamp_w = display_columns(stamp)
            var stamp_x = rect.b.x - 2 - stamp_w
            if stamp_x > rect.a.x + 2 + display_columns(disp):
                _ = painter.put_text(
                    canvas, Point(stamp_x, top + i), stamp, m_attr,
                )
        # Bottom hint.
        _ = painter.put_text(
            canvas, Point(rect.a.x + 2, rect.b.y - 1),
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
            if self.selected < 0 or self.selected >= len(self.entries):
                return True
            var entry = self.entries[self.selected]
            self.selected_path = entry.path
            self.selected_line = entry.line
            self.selected_character = entry.character
            self.submitted = True
            return True
        if picker_nav_key(k, len(self.entries), self.selected):
            self._scroll_to_selection()
            return True
        return True

    def handle_mouse(mut self, event: Event, screen: Rect) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_MOUSE:
            return True
        var rect = self._rect(screen)
        var top = self._list_top(rect)
        var h = self._list_height(rect)
        if event.pressed and not event.motion:
            if picker_wheel_scroll(event.button, self.scroll, len(self.entries), h):
                return True
        if event.button != MOUSE_BUTTON_LEFT:
            return True
        if not event.pressed or event.motion:
            return True
        if not rect.contains(event.pos):
            return True
        if event.pos.y < top or event.pos.y >= top + h:
            return True
        var idx = self.scroll + (event.pos.y - top)
        if idx < 0 or idx >= len(self.entries):
            return True
        if idx == self.selected:
            var entry = self.entries[idx]
            self.selected_path = entry.path
            self.selected_line = entry.line
            self.selected_character = entry.character
            self.submitted = True
            return True
        self.selected = idx
        return True

    def _scroll_to_selection(mut self):
        var visible = 14
        if self.selected < self.scroll:
            self.scroll = self.selected
        elif self.selected >= self.scroll + visible:
            self.scroll = self.selected - visible + 1


def _ends_with_slash(s: String) -> Bool:
    var b = s.as_bytes()
    if len(b) == 0:
        return False
    return b[len(b) - 1] == 0x2F
