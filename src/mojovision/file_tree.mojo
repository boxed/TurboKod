"""FileTree: right-docked collapsible project file browser.

The tree is conceptually outside the floating-window workspace — when shown,
``Desktop.workspace_rect`` shrinks by ``FILE_TREE_WIDTH`` so floating windows
get moved/resized to fit the smaller area, exactly as if the terminal itself
had narrowed by that amount.

Internally ``entries`` is a flat list with a ``depth`` per entry — expanding
a directory inserts its children right after it with ``depth + 1``; collapsing
removes the contiguous run of deeper entries that follow.
"""

from std.collections.list import List
from std.collections.optional import Optional

from .canvas import Canvas
from .cell import Cell
from .colors import Attr, BLACK, BLUE, LIGHT_GRAY, WHITE, YELLOW
from .events import (
    Event, EVENT_MOUSE,
    MOUSE_BUTTON_LEFT, MOUSE_WHEEL_UP, MOUSE_WHEEL_DOWN,
)
from .file_io import basename, join_path, list_directory, stat_file
from .geometry import Point, Rect


comptime FILE_TREE_WIDTH: Int = 28


@fieldwise_init
struct FileTreeEntry(ImplicitlyCopyable, Movable):
    var name: String
    var path: String
    var depth: Int
    var is_dir: Bool
    var is_expanded: Bool


struct FileTree(Movable):
    var visible: Bool
    var root: String
    var width: Int
    var entries: List[FileTreeEntry]
    var selected: Int
    var scroll: Int
    var opened_path: String
    var submitted: Bool

    fn __init__(out self):
        self.visible = False
        self.root = String("")
        self.width = FILE_TREE_WIDTH
        self.entries = List[FileTreeEntry]()
        self.selected = -1
        self.scroll = 0
        self.opened_path = String("")
        self.submitted = False

    fn open(mut self, var root: String):
        self.root = root^
        self.entries = List[FileTreeEntry]()
        var children = self._list_dir(self.root, 0)
        for i in range(len(children)):
            self.entries.append(children[i])
        self.visible = True
        self.selected = -1
        self.scroll = 0
        self.opened_path = String("")
        self.submitted = False

    fn close(mut self):
        self.visible = False
        self.entries = List[FileTreeEntry]()
        self.root = String("")
        self.selected = -1
        self.scroll = 0
        self.opened_path = String("")
        self.submitted = False

    fn consume_open(mut self) -> Optional[String]:
        """If a file was just opened, return its path and clear the flag."""
        if not self.submitted:
            return Optional[String]()
        self.submitted = False
        var p = self.opened_path
        self.opened_path = String("")
        return Optional[String](p)

    # --- tree mechanics ---------------------------------------------------

    fn _list_dir(self, path: String, depth: Int) -> List[FileTreeEntry]:
        """Return the immediate children of ``path``, dirs first then files,
        each group sorted case-insensitively by name. Hidden entries
        (dotfiles) are filtered out.

        ``readdir`` order is filesystem-defined (often inode order on
        ext4, alphabetical on APFS) — sorting here gives the user the
        same stable presentation across systems.
        """
        var raw = list_directory(path)
        var dirs = List[FileTreeEntry]()
        var files = List[FileTreeEntry]()
        for i in range(len(raw)):
            var name = raw[i]
            if name == String(".") or name == String(".."):
                continue
            var nbytes = name.as_bytes()
            if len(nbytes) > 0 and nbytes[0] == 0x2E:
                continue
            var full = join_path(path, name)
            var info = stat_file(full)
            var is_dir = info.is_dir() if info.ok else False
            var entry = FileTreeEntry(name, full, depth, is_dir, False)
            if is_dir:
                dirs.append(entry)
            else:
                files.append(entry)
        _sort_entries_ci(dirs)
        _sort_entries_ci(files)
        var out = List[FileTreeEntry]()
        for i in range(len(dirs)):
            out.append(dirs[i])
        for i in range(len(files)):
            out.append(files[i])
        return out^

    fn _toggle_expand(mut self, idx: Int):
        if idx < 0 or idx >= len(self.entries):
            return
        if not self.entries[idx].is_dir:
            return
        if self.entries[idx].is_expanded:
            self.entries[idx].is_expanded = False
            var d = self.entries[idx].depth
            var next_idx = idx + 1
            while next_idx < len(self.entries) and self.entries[next_idx].depth > d:
                next_idx += 1
            for _ in range(next_idx - idx - 1):
                _ = self.entries.pop(idx + 1)
            return
        self.entries[idx].is_expanded = True
        var children = self._list_dir(
            self.entries[idx].path, self.entries[idx].depth + 1,
        )
        # Splice ``children`` in at idx+1 by rebuilding the list — simplest
        # approach with ``List``'s current API.
        var rebuilt = List[FileTreeEntry]()
        for i in range(idx + 1):
            rebuilt.append(self.entries[i])
        for i in range(len(children)):
            rebuilt.append(children[i])
        for i in range(idx + 1, len(self.entries)):
            rebuilt.append(self.entries[i])
        self.entries = rebuilt^

    # --- geometry & paint -------------------------------------------------

    fn rect(self, screen: Rect) -> Rect:
        return Rect(screen.b.x - self.width, 1, screen.b.x, screen.b.y - 1)

    fn paint(self, mut canvas: Canvas, screen: Rect):
        if not self.visible:
            return
        var area = self.rect(screen)
        if area.is_empty():
            return
        var bg          = Attr(BLACK,  LIGHT_GRAY)
        var dir_attr    = Attr(BLUE,   LIGHT_GRAY)
        var sel_attr    = Attr(BLACK,  YELLOW)
        var sel_dir_attr = Attr(BLUE,  YELLOW)
        var title_attr  = Attr(WHITE,  BLUE)
        # Left separator column lives at area.a.x.
        for y in range(area.a.y, area.b.y):
            canvas.set(area.a.x, y, Cell(String("│"), bg, 1))
        # Title bar fills the rest of the top row of the panel.
        canvas.fill(
            Rect(area.a.x + 1, area.a.y, area.b.x, area.a.y + 1),
            String(" "),
            title_attr,
        )
        var title = String(" ") + basename(self.root)
        _ = canvas.put_text(
            Point(area.a.x + 1, area.a.y), title, title_attr, area.b.x,
        )
        # Listing area starts one row below the title.
        var list_top = area.a.y + 1
        var list_h = area.b.y - list_top
        var content_x = area.a.x + 1
        for i in range(list_h):
            var idx = self.scroll + i
            if idx >= len(self.entries):
                break
            var e = self.entries[idx]
            var is_sel = (idx == self.selected)
            var attr: Attr
            if is_sel:
                attr = sel_dir_attr if e.is_dir else sel_attr
            else:
                attr = dir_attr if e.is_dir else bg
            # Paint the row background first so selection covers full width.
            canvas.fill(
                Rect(content_x, list_top + i, area.b.x, list_top + i + 1),
                String(" "),
                attr,
            )
            var indent = String("")
            for _ in range(e.depth):
                indent = indent + String("  ")
            var marker: String
            if e.is_dir:
                marker = String("▼") if e.is_expanded else String("▶")
            else:
                marker = String(" ")
            var label = indent + marker + String(" ") + e.name
            _ = canvas.put_text(
                Point(content_x, list_top + i), label, attr, area.b.x,
            )

    # --- mouse ------------------------------------------------------------

    fn handle_mouse(mut self, event: Event, screen: Rect) -> Bool:
        """Returns True iff the event was inside the panel (consumed)."""
        if not self.visible:
            return False
        if event.kind != EVENT_MOUSE:
            return False
        var area = self.rect(screen)
        if not area.contains(event.pos):
            return False
        # Wheel anywhere over the panel scrolls the listing.
        if event.pressed and not event.motion:
            if event.button == MOUSE_WHEEL_UP:
                if self.scroll > 0:
                    self.scroll -= 3
                    if self.scroll < 0:
                        self.scroll = 0
                return True
            if event.button == MOUSE_WHEEL_DOWN:
                var list_h = area.b.y - (area.a.y + 1)
                var max_scroll = len(self.entries) - list_h
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
        if event.pos.y == area.a.y:
            # Title-bar click: no-op (panel isn't draggable).
            return True
        var list_top = area.a.y + 1
        var idx = self.scroll + (event.pos.y - list_top)
        if idx < 0 or idx >= len(self.entries):
            return True
        if idx == self.selected:
            # Second click on the same entry: directories toggle, files open.
            if self.entries[idx].is_dir:
                self._toggle_expand(idx)
                return True
            self.opened_path = self.entries[idx].path
            self.submitted = True
            return True
        self.selected = idx
        return True


# --- helpers ---------------------------------------------------------------


fn _sort_entries_ci(mut entries: List[FileTreeEntry]):
    """In-place insertion sort by ``name``, case-insensitive. Insertion
    sort is fine here — directory child counts in real projects are
    small (tens to hundreds), and this only runs on expand/refresh."""
    var n = len(entries)
    for i in range(1, n):
        var j = i
        while j > 0 and _ci_less(entries[j].name, entries[j - 1].name):
            var tmp = entries[j]
            entries[j] = entries[j - 1]
            entries[j - 1] = tmp
            j -= 1


fn _ci_less(a: String, b: String) -> Bool:
    """``True`` iff ``a < b`` lexicographically, ignoring ASCII case.

    Non-ASCII bytes compare via raw byte value (no Unicode case
    folding) — fine for the typical mix of English filenames; if the
    user has Cyrillic / CJK names they'll cluster but stay grouped.
    """
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    var n = len(ab) if len(ab) < len(bb) else len(bb)
    for i in range(n):
        var ca = Int(ab[i])
        var cb = Int(bb[i])
        if 0x41 <= ca and ca <= 0x5A: ca += 0x20
        if 0x41 <= cb and cb <= 0x5A: cb += 0x20
        if ca != cb:
            return ca < cb
    return len(ab) < len(bb)
