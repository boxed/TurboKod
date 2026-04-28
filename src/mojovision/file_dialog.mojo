"""Modal file-open dialog: directory listing with arrow-key navigation.

Open with ``open(start_dir)``. The user navigates with Up/Down arrows, opens a
directory by pressing Enter on it (the listing refreshes), and selects a file
by pressing Enter on it. Backspace ascends to the parent directory; Esc
cancels. On submit, ``submitted=True`` and ``selected_path`` holds the absolute
(or as-supplied) path; the caller calls ``close()`` to dismiss.
"""

from std.collections.list import List

from .canvas import Canvas
from .cell import Cell
from .colors import Attr, BLACK, BLUE, LIGHT_GRAY, WHITE, YELLOW
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_BACKSPACE, KEY_DOWN, KEY_ENTER, KEY_ESC, KEY_UP, KEY_PAGEDOWN, KEY_PAGEUP,
    MOUSE_BUTTON_LEFT, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .file_io import join_path, list_directory, parent_path, stat_file
from .geometry import Point, Rect
from .posix import realpath


struct FileDialog(Movable):
    var active: Bool
    var submitted: Bool
    var dir: String
    var entries: List[String]
    var entry_is_dir: List[Bool]
    var selected: Int
    var scroll: Int
    var selected_path: String

    fn __init__(out self):
        self.active = False
        self.submitted = False
        self.dir = String(".")
        self.entries = List[String]()
        self.entry_is_dir = List[Bool]()
        self.selected = 0
        self.scroll = 0
        self.selected_path = String("")

    fn open(mut self, var start_dir: String):
        self.dir = start_dir^
        self.active = True
        self.submitted = False
        self.selected = 0
        self.scroll = 0
        self.selected_path = String("")
        self._refresh()

    fn _ascend(mut self):
        """Move ``self.dir`` to its parent. Canonicalizes via
        ``realpath`` first so a relative start dir like ``"."`` —
        whose parent under POSIX dirname semantics is itself — still
        ascends. ``find_git_project`` uses the same trick for the
        same reason. Falls back to plain ``parent_path`` if
        ``realpath`` can't resolve (e.g. the dir was deleted from
        under us)."""
        var resolved = realpath(self.dir)
        if len(resolved.as_bytes()) > 0:
            self.dir = parent_path(resolved)
        else:
            self.dir = parent_path(self.dir)
        self._refresh()

    fn close(mut self):
        self.active = False
        self.submitted = False
        self.entries = List[String]()
        self.entry_is_dir = List[Bool]()
        self.selected_path = String("")

    fn _refresh(mut self):
        self.entries = List[String]()
        self.entry_is_dir = List[Bool]()
        # Always offer ".." so users can ascend even at non-root dirs.
        self.entries.append(String(".."))
        self.entry_is_dir.append(True)
        var raw = list_directory(self.dir)
        for i in range(len(raw)):
            var name = raw[i]
            if name == String(".") or name == String(".."):
                continue
            var info = stat_file(join_path(self.dir, name))
            self.entries.append(name)
            self.entry_is_dir.append(info.is_dir() if info.ok else False)
        self.selected = 0
        self.scroll = 0

    # --- painting ----------------------------------------------------------

    fn paint(self, mut canvas: Canvas, screen: Rect):
        if not self.active:
            return
        var bg = Attr(BLACK, LIGHT_GRAY)
        var title_attr = Attr(WHITE, BLUE)
        var dir_attr = Attr(BLUE, LIGHT_GRAY)
        var sel_attr = Attr(BLACK, YELLOW)
        var dir_entry_attr = Attr(BLUE, LIGHT_GRAY)
        var width = 60
        var height = 18
        if width > screen.b.x - 4: width = screen.b.x - 4
        if height > screen.b.y - 4: height = screen.b.y - 4
        var x = (screen.b.x - width) // 2
        var y = (screen.b.y - height) // 2
        var rect = Rect(x, y, x + width, y + height)
        canvas.fill(rect, String(" "), bg)
        canvas.draw_box(rect, bg, False)
        # Title bar
        var title = String(" Open File ")
        var tx = x + (width - len(title.as_bytes())) // 2
        _ = canvas.put_text(Point(tx, y), title, title_attr)
        # Current directory line
        _ = canvas.put_text(Point(x + 2, y + 1), self.dir, dir_attr, x + width - 1)
        # Listing
        var list_top = y + 3
        var list_h = (y + height - 2) - list_top
        for i in range(list_h):
            var idx = self.scroll + i
            if idx >= len(self.entries):
                break
            var name = self.entries[idx]
            var is_dir = self.entry_is_dir[idx]
            var attr: Attr
            if idx == self.selected:
                attr = sel_attr
            else:
                attr = dir_entry_attr if is_dir else bg
            var label: String
            if is_dir:
                label = name + String("/")
            else:
                label = name
            _ = canvas.put_text(Point(x + 2, list_top + i), label, attr, x + width - 1)
        # Hint at bottom
        _ = canvas.put_text(
            Point(x + 2, y + height - 1),
            String(" Enter: open  ⌫: parent  ESC: cancel "),
            dir_attr,
            x + width - 1,
        )

    # --- events ------------------------------------------------------------

    fn handle_key(mut self, event: Event) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_KEY:
            return True
        var k = event.key
        if k == KEY_ESC:
            self.close()
            return True
        if k == KEY_UP:
            if self.selected > 0:
                self.selected -= 1
            self._scroll_to_selection()
            return True
        if k == KEY_DOWN:
            if self.selected + 1 < len(self.entries):
                self.selected += 1
            self._scroll_to_selection()
            return True
        if k == KEY_PAGEUP:
            self.selected -= 10
            if self.selected < 0: self.selected = 0
            self._scroll_to_selection()
            return True
        if k == KEY_PAGEDOWN:
            self.selected += 10
            if self.selected >= len(self.entries):
                self.selected = len(self.entries) - 1
            self._scroll_to_selection()
            return True
        if k == KEY_BACKSPACE:
            self._ascend()
            return True
        if k == KEY_ENTER:
            if self.selected < 0 or self.selected >= len(self.entries):
                return True
            var name = self.entries[self.selected]
            if name == String(".."):
                self._ascend()
                return True
            var path = join_path(self.dir, name)
            if self.entry_is_dir[self.selected]:
                self.dir = path
                self._refresh()
                return True
            self.selected_path = path
            self.submitted = True
            return True
        return True

    fn _scroll_to_selection(mut self):
        # Keep the selection in view; visible window height is approximate.
        var visible = 10
        if self.selected < self.scroll:
            self.scroll = self.selected
        elif self.selected >= self.scroll + visible:
            self.scroll = self.selected - visible + 1

    # --- mouse -------------------------------------------------------------

    fn handle_mouse(mut self, event: Event, screen: Rect) -> Bool:
        """Click in entry list selects; click on already-selected entry opens.
        Wheel up/down scrolls the listing. Clicks outside the dialog are
        swallowed (modal)."""
        if not self.active:
            return False
        if event.kind != EVENT_MOUSE:
            return True
        # Geometry must match ``paint``.
        var width = 60
        var height = 18
        if width > screen.b.x - 4: width = screen.b.x - 4
        if height > screen.b.y - 4: height = screen.b.y - 4
        var x = (screen.b.x - width) // 2
        var y = (screen.b.y - height) // 2
        var rect = Rect(x, y, x + width, y + height)
        var list_top = y + 3
        var list_bottom = y + height - 2
        var list_h = list_bottom - list_top
        # Wheel scroll works anywhere over the dialog.
        if event.pressed and not event.motion:
            if event.button == MOUSE_WHEEL_UP:
                if self.scroll > 0:
                    self.scroll -= 3
                    if self.scroll < 0: self.scroll = 0
                return True
            if event.button == MOUSE_WHEEL_DOWN:
                var max_scroll = len(self.entries) - list_h
                if max_scroll < 0: max_scroll = 0
                if self.scroll < max_scroll:
                    self.scroll += 3
                    if self.scroll > max_scroll: self.scroll = max_scroll
                return True
        if event.button != MOUSE_BUTTON_LEFT:
            return True
        if not event.pressed or event.motion:
            return True
        if not rect.contains(event.pos):
            return True   # swallow clicks outside the dialog (still modal)
        if event.pos.y < list_top or event.pos.y >= list_bottom:
            return True
        var idx = self.scroll + (event.pos.y - list_top)
        if idx < 0 or idx >= len(self.entries):
            return True
        # ``..`` has exactly one meaningful action — ascend. Skip the
        # select-then-second-click dance so a single click on the
        # parent shortcut just works. (This also makes the
        # second-click branch below unreachable for ``..``.)
        if self.entries[idx] == String(".."):
            self._ascend()
            return True
        if idx == self.selected:
            # Second click on the same entry: act like Enter.
            var name = self.entries[self.selected]
            var path = join_path(self.dir, name)
            if self.entry_is_dir[self.selected]:
                self.dir = path
                self._refresh()
                return True
            self.selected_path = path
            self.submitted = True
            return True
        self.selected = idx
        return True
