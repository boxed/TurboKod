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
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_DOWN, KEY_END, KEY_ENTER, KEY_ESC, KEY_HOME,
    KEY_PAGEDOWN, KEY_PAGEUP, KEY_UP,
    MOUSE_BUTTON_LEFT, MOUSE_BUTTON_NONE, MOUSE_WHEEL_UP, MOUSE_WHEEL_DOWN,
)
from .file_io import (
    basename, join_path, list_directory, sort_directory_listing, stat_file,
)
from .geometry import Point, Rect


comptime FILE_TREE_WIDTH: Int = 28
comptime FILE_TREE_MIN_WIDTH: Int = 10
"""Lower bound for resize drags: enough to keep a usable filename
column once the indent + marker glyphs are accounted for."""
comptime FILE_TREE_RIGHT_RESERVE: Int = 20
"""Min editor columns left after the tree eats its share of the
screen. Keeps the user from accidentally dragging the tree across
the whole window."""


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
    var focused: Bool
    """When True, arrow / Enter keystrokes route to this panel
    (set by the host on Ctrl+0). Mirrors the same field on
    ``DebugPane`` so the keyboard-focus model is uniform across
    docked side panels."""
    var _resizing: Bool
    """True while the user holds the left button after pressing on
    the panel's left border. Mouse motion in this state updates
    ``width``; the next non-pressed event clears the flag."""

    fn __init__(out self):
        self.visible = False
        self.root = String("")
        self.width = FILE_TREE_WIDTH
        self.entries = List[FileTreeEntry]()
        self.selected = -1
        self.scroll = 0
        self.opened_path = String("")
        self.submitted = False
        self.focused = False
        self._resizing = False

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
        self.focused = False
        self._resizing = False

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
        ext4, alphabetical on APFS) — ``sort_directory_listing`` is the
        same helper the open-file dialog uses, so both views show the
        user identical ordering.
        """
        var raw = list_directory(path)
        var names = List[String]()
        var is_dirs = List[Bool]()
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
            names.append(name)
            is_dirs.append(is_dir)
        sort_directory_listing(names, is_dirs)
        var out = List[FileTreeEntry]()
        for i in range(len(names)):
            out.append(FileTreeEntry(
                names[i], join_path(path, names[i]),
                depth, is_dirs[i], False,
            ))
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
        # Title row gets the focused tint when keyboard focus lands
        # here — same convention windows use (their title brightens
        # with the same color flip).
        var title_attr: Attr
        if self.focused:
            title_attr = Attr(WHITE, BLUE)
        else:
            title_attr = Attr(LIGHT_GRAY, BLUE)
        # Left separator column lives at area.a.x. Focus is shown via line
        # weight (single → double), mirroring how normal windows render
        # their frame.
        var sep_glyph = String("║") if self.focused else String("│")
        for y in range(area.a.y, area.b.y):
            canvas.set(area.a.x, y, Cell(sep_glyph, bg, 1))
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
        # Number indicator at the top-right, mirroring the per-window
        # ``Ctrl+N`` shortcut hint. ``0`` is the file tree's slot —
        # paired with ``Ctrl+0`` to focus it from anywhere.
        if area.b.x - area.a.x >= 4:
            _ = canvas.put_text(
                Point(area.b.x - 2, area.a.y), String("0"),
                title_attr,
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

    fn handle_key(mut self, event: Event) -> Bool:
        """Arrow / Enter / Esc when the panel has keyboard focus.
        Returns True iff the key was consumed. Esc releases focus
        without affecting visibility — the panel stays open and the
        host's window dispatch picks up subsequent keys."""
        if not self.focused or not self.visible:
            return False
        if event.kind != EVENT_KEY:
            return False
        if event.key == KEY_ESC:
            self.focused = False
            return True
        if event.key == KEY_UP:
            if self.selected > 0:
                self.selected -= 1
            elif self.selected < 0 and len(self.entries) > 0:
                self.selected = 0
            self._scroll_to_selection()
            return True
        if event.key == KEY_DOWN:
            if self.selected < 0 and len(self.entries) > 0:
                self.selected = 0
            elif self.selected + 1 < len(self.entries):
                self.selected += 1
            self._scroll_to_selection()
            return True
        if event.key == KEY_PAGEUP:
            self.selected -= 10
            if self.selected < 0:
                self.selected = 0
            self._scroll_to_selection()
            return True
        if event.key == KEY_PAGEDOWN:
            self.selected += 10
            if self.selected >= len(self.entries):
                self.selected = len(self.entries) - 1
            self._scroll_to_selection()
            return True
        if event.key == KEY_HOME:
            self.selected = 0 if len(self.entries) > 0 else -1
            self._scroll_to_selection()
            return True
        if event.key == KEY_END:
            self.selected = len(self.entries) - 1
            self._scroll_to_selection()
            return True
        if event.key == KEY_ENTER:
            if self.selected < 0 or self.selected >= len(self.entries):
                return True
            if self.entries[self.selected].is_dir:
                self._toggle_expand(self.selected)
            else:
                self.opened_path = self.entries[self.selected].path
                self.submitted = True
            return True
        return False

    fn _clamp_width(self, want: Int, screen: Rect) -> Int:
        """Pin a proposed width to ``[FILE_TREE_MIN_WIDTH, screen.b.x -
        FILE_TREE_RIGHT_RESERVE]`` so a runaway drag can't shrink the
        editor area below something usable. Order of clamps matters on
        very narrow terminals: when the upper bound would fall below the
        lower, the lower wins (we'd rather have an unusable workspace
        for one frame than a 0-column tree)."""
        var w = want
        var hi = screen.b.x - FILE_TREE_RIGHT_RESERVE
        if w > hi:
            w = hi
        if w < FILE_TREE_MIN_WIDTH:
            w = FILE_TREE_MIN_WIDTH
        return w

    fn _scroll_to_selection(mut self):
        # Visible-window height isn't known without ``screen``, so
        # use a conservative fixed visible count — the listing is
        # right-docked at a fixed width and the host gives us at
        # least 10 rows in practice. Erring small means we may
        # over-scroll on tiny terminals; that's preferable to
        # leaving the selection off-screen.
        var visible = 10
        if self.selected < 0:
            return
        if self.selected < self.scroll:
            self.scroll = self.selected
        elif self.selected >= self.scroll + visible:
            self.scroll = self.selected - visible + 1

    fn is_on_resize_edge(self, pos: Point, screen: Rect) -> Bool:
        """Hit-test for the left border column — the row-tall handle the
        user drags to widen / narrow the panel. Used by the host to
        switch the mouse pointer to ``ew-resize`` while hovering."""
        if not self.visible:
            return False
        var area = self.rect(screen)
        return pos.x == area.a.x and pos.y >= area.a.y and pos.y < area.b.y

    fn is_resizing(self) -> Bool:
        return self._resizing

    fn handle_mouse(mut self, event: Event, screen: Rect) -> Bool:
        """Returns True iff the event was inside the panel (consumed)."""
        if not self.visible:
            return False
        if event.kind != EVENT_MOUSE:
            return False
        var area = self.rect(screen)
        # Resize-drag: once started, every subsequent mouse event
        # belongs to the resize until the button is released — even
        # when the cursor leaves the original panel rect. Checked
        # before the area-contains gate for that reason.
        if self._resizing:
            if event.button == MOUSE_BUTTON_LEFT and not event.pressed:
                self._resizing = False
                return True
            # Any pressed event (motion or otherwise) updates width.
            # Bare hover events under 1003 also flow here while a drag
            # is in progress, but they have button=NONE & motion=True;
            # we still want them to update the width since some
            # terminals report drag motion that way.
            self.width = self._clamp_width(screen.b.x - event.pos.x, screen)
            return True
        if event.button == MOUSE_BUTTON_LEFT and event.pressed and not event.motion:
            if event.pos.x == area.a.x \
                    and event.pos.y >= area.a.y and event.pos.y < area.b.y:
                self._resizing = True
                return True
        if not area.contains(event.pos):
            # Only an actual click outside loses focus; bare hover (button
            # NONE) under mouse-mode 1003 must not steal it on every move.
            if event.button != MOUSE_BUTTON_NONE and event.pressed and not event.motion:
                self.focused = False
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
        # Any click inside the panel takes keyboard focus, mirroring
        # the debug pane's click-to-focus behaviour.
        self.focused = True
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


