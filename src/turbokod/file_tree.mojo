"""FileTree: side-docked collapsible project file browser.

The tree docks on the right edge by default; the View-menu cycle (hidden →
right → left) can flip it to the left edge instead. It is conceptually
outside the floating-window workspace — when shown, ``Desktop.workspace_rect``
shrinks by ``FILE_TREE_WIDTH`` on the docked side so floating windows get
moved/resized to fit the smaller area, exactly as if the terminal itself
had narrowed by that amount.

Internally ``entries`` is a flat list with a ``depth`` per entry — expanding
a directory inserts its children right after it with ``depth + 1``; collapsing
removes the contiguous run of deeper entries that follow.
"""

from std.collections.list import List
from std.collections.optional import Optional

from .canvas import Canvas
from .painter import Painter
from .cell import Cell
from .colors import (
    Attr, BLACK, BLUE, GREEN, LIGHT_GRAY, LIGHT_GREEN, WHITE, YELLOW,
)
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_DOWN, KEY_END, KEY_ENTER, KEY_ESC, KEY_HOME,
    KEY_PAGEDOWN, KEY_PAGEUP, KEY_UP,
    MOUSE_BUTTON_LEFT, MOUSE_BUTTON_NONE, MOUSE_WHEEL_UP, MOUSE_WHEEL_DOWN,
)
from .file_io import (
    join_path, list_directory, sort_directory_listing, stat_file,
)
from .geometry import Point, Rect
from .project import GitignoreMatcher, load_project_gitignore
from .type_ahead import TypeAhead, is_printable_ascii, type_ahead_pick


comptime FILE_TREE_WIDTH: Int = 28
comptime FILE_TREE_MIN_WIDTH: Int = 10
"""Lower bound for resize drags: enough to keep a usable filename
column once the indent + marker glyphs are accounted for."""
comptime FILE_TREE_RIGHT_RESERVE: Int = 20
"""Min editor columns left after the tree eats its share of the
container_bounds. Keeps the user from accidentally dragging the tree across
the whole window."""


@fieldwise_init
struct FileTreeEntry(ImplicitlyCopyable, Movable):
    var name: String
    var path: String
    var depth: Int
    var is_dir: Bool
    var is_expanded: Bool


def _strip_root_prefix(root: String, full: String) -> String:
    """Return ``full`` minus the ``root + "/"`` prefix, or ``""`` when they
    coincide. Falls back to ``full`` if the prefix doesn't match, so the
    caller still gets a usable path."""
    var rb = root.as_bytes()
    var fb = full.as_bytes()
    if len(fb) == len(rb):
        return String("")
    if len(fb) < len(rb) + 1:
        return full
    for k in range(len(rb)):
        if fb[k] != rb[k]:
            return full
    if fb[len(rb)] != 0x2F:
        return full
    return String(StringSlice(unsafe_from_utf8=fb[len(rb) + 1:]))


struct FileTree(Movable):
    var visible: Bool
    var root: String
    var width: Int
    var top: Int
    """First container_bounds row of the panel. Row 0 belongs to the in-grid menu
    bar on the terminal frontend (top=1, the default); when the host
    owns the menu (Swift/AppKit) the workspace starts at row 0 and the
    Desktop syncs this to 0 so the panel doesn't show a blank row above
    its title."""
    var dock_left: Bool
    """False → docked on the right edge (default), True → left edge.
    Cycled by the View-menu file-tree item: hidden → right → left."""
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
    the panel's separator border. Mouse motion in this state updates
    ``width``; the next non-pressed event clears the flag."""
    var _type_ahead: TypeAhead
    """Type-to-jump prefix buffer. Auto-resets after the
    ``_SEARCH_RESET_MS`` pause; explicit reset on ``open`` /
    ``close`` so a fresh tree starts with a clean slate."""
    var _gitignore: GitignoreMatcher
    """Loaded once from the project root's ``.gitignore`` on ``open``
    so listings hide ``.pixi``/``.build``/etc. without re-parsing per
    directory. ``.git`` is always hidden — it's not in ``.gitignore``
    but git itself treats it as implicitly ignored."""
    var modified_paths: List[String]
    """Full paths of files with uncommitted changes — synced by the
    Desktop from the open editors before every paint. Rows whose path
    matches are tinted with the same green scheme the tab bar uses for
    dirty tabs."""

    def __init__(out self):
        self.visible = False
        self.root = String("")
        self.width = FILE_TREE_WIDTH
        self.top = 1
        self.dock_left = False
        self.entries = List[FileTreeEntry]()
        self.selected = -1
        self.scroll = 0
        self.opened_path = String("")
        self.submitted = False
        self.focused = False
        self._resizing = False
        self._type_ahead = TypeAhead()
        self._gitignore = GitignoreMatcher()
        self.modified_paths = List[String]()

    def open(mut self, var root: String):
        self.root = root^
        self._gitignore = load_project_gitignore(self.root)
        self.entries = List[FileTreeEntry]()
        var children = self._list_dir(self.root, 0)
        for i in range(len(children)):
            self.entries.append(children[i])
        self.visible = True
        self.selected = -1
        self.scroll = 0
        self.opened_path = String("")
        self.submitted = False
        self._type_ahead.reset()

    def close(mut self):
        self.visible = False
        self.entries = List[FileTreeEntry]()
        self.root = String("")
        self.selected = -1
        self.scroll = 0
        self._type_ahead.reset()
        self.opened_path = String("")
        self.submitted = False
        self.focused = False
        self._resizing = False
        self._gitignore = GitignoreMatcher()

    def consume_open(mut self) -> Optional[String]:
        """If a file was just opened, return its path and clear the flag."""
        if not self.submitted:
            return Optional[String]()
        self.submitted = False
        var p = self.opened_path
        self.opened_path = String("")
        return Optional[String](p)

    # --- tree mechanics ---------------------------------------------------

    def _list_dir(self, path: String, depth: Int) -> List[FileTreeEntry]:
        """Return the immediate children of ``path``, dirs first then files,
        each group sorted case-insensitively by name. ``.git`` is hidden
        and ``.gitignore``-matched entries are dropped; other dotfiles
        (``.gitignore`` itself, ``.editorconfig``, …) are shown.

        ``readdir`` order is filesystem-defined (often inode order on
        ext4, alphabetical on APFS) — ``sort_directory_listing`` is the
        same helper the open-file dialog uses, so both views show the
        user identical ordering.
        """
        var raw = list_directory(path)
        var names = List[String]()
        var is_dirs = List[Bool]()
        var rel_prefix = _strip_root_prefix(self.root, path)
        for i in range(len(raw)):
            var name = raw[i]
            if name == String(".") or name == String("..") \
                    or name == String(".git"):
                continue
            var full = join_path(path, name)
            var info = stat_file(full)
            var is_dir = info.is_dir() if info.ok else False
            var rel = name if len(rel_prefix.as_bytes()) == 0 \
                else join_path(rel_prefix, name)
            if self._gitignore.ignored(rel, is_dir):
                continue
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

    def _toggle_expand(mut self, idx: Int):
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

    def reveal(mut self, path: String):
        """Expand every ancestor directory of ``path`` and land the
        selection on its entry. Silent no-op when the path lies outside
        the project root or one of its components is hidden from the
        listing (gitignored)."""
        if not self.visible:
            return
        var rel = _strip_root_prefix(self.root, path)
        var rb = rel.as_bytes()
        if len(rb) == 0:
            return
        if rb[0] == 0x2F:
            # ``_strip_root_prefix`` echoed the absolute path back —
            # the prefix didn't match, so the file is outside the root.
            return
        # Split into components (no leading / trailing slashes by now).
        var parts = List[String]()
        var start = 0
        for i in range(len(rb) + 1):
            if i == len(rb) or rb[i] == 0x2F:
                if i > start:
                    parts.append(
                        String(StringSlice(unsafe_from_utf8=rb[start:i])),
                    )
                start = i + 1
        # Walk the flat entry list one component at a time. A component
        # at depth ``d`` lives somewhere after its parent and before the
        # first entry shallower than ``d`` (end of the parent's subtree).
        var search_from = 0
        for d in range(len(parts)):
            var idx = -1
            var i = search_from
            while i < len(self.entries):
                if self.entries[i].depth < d:
                    break
                if self.entries[i].depth == d \
                        and self.entries[i].name == parts[d]:
                    idx = i
                    break
                i += 1
            if idx < 0:
                return
            if d + 1 < len(parts):
                if not self.entries[idx].is_expanded:
                    self._toggle_expand(idx)
                search_from = idx + 1
            else:
                self.selected = idx
                self._scroll_to_selection()

    def _is_modified(self, path: String) -> Bool:
        for i in range(len(self.modified_paths)):
            if self.modified_paths[i] == path:
                return True
        return False

    # --- geometry & paint -------------------------------------------------

    def rect(self, container_bounds: Rect) -> Rect:
        if self.dock_left:
            return Rect(0, self.top, self.width, container_bounds.b.y - 1)
        return Rect(
            container_bounds.b.x - self.width, self.top, container_bounds.b.x, container_bounds.b.y - 1,
        )

    def _sep_x(self, area: Rect) -> Int:
        """Column of the separator / resize-handle line — always the
        workspace-facing edge: left edge when right-docked, right edge
        when left-docked."""
        return area.b.x - 1 if self.dock_left else area.a.x

    def _content_x(self, area: Rect) -> Int:
        """First column of the title / listing content (the column just
        inside the separator on the docked side)."""
        return area.a.x if self.dock_left else area.a.x + 1

    def paint(self, mut canvas: Canvas, container_bounds: Rect):
        if not self.visible:
            return
        var area = self.rect(container_bounds)
        if area.is_empty():
            return
        var bg          = Attr(BLACK,  LIGHT_GRAY)
        var dir_attr    = Attr(BLUE,   LIGHT_GRAY)
        var sel_attr    = Attr(BLACK,  YELLOW)
        var sel_dir_attr = Attr(BLUE,  YELLOW)
        # Separator column lives on the workspace-facing edge. Focus is
        # shown via line weight (single → double), mirroring how normal
        # windows render their frame.
        var painter = Painter(area)
        var sep_x = self._sep_x(area)
        var content_x = self._content_x(area)
        var content_end = content_x + (area.b.x - area.a.x - 1)
        var sep_glyph = String("║") if self.focused else String("│")
        for y in range(area.a.y, area.b.y):
            painter.set(canvas, sep_x, y, Cell(sep_glyph, bg, 1))
        # Listing fills the whole panel — the root's name needs no title
        # row of its own (the window title / project state already says
        # which project is open).
        var list_top = area.a.y
        var list_h = area.b.y - list_top
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
            # Uncommitted changes recolor the row with the same scheme
            # the tab bar uses for dirty tabs: LIGHT_GREEN surface for
            # plain rows, GREEN (with the active tab's WHITE text) when
            # the row is also the selection.
            if not e.is_dir and self._is_modified(e.path):
                if is_sel:
                    attr = Attr(WHITE, GREEN)
                else:
                    attr = attr.with_bg(LIGHT_GREEN)
            # Paint the row background first so selection covers full width.
            painter.fill(
                canvas,
                Rect(content_x, list_top + i, content_end, list_top + i + 1),
                String(" "),
                attr,
            )
            var marker: String
            if e.is_dir:
                marker = String("▼") if e.is_expanded else String("▶")
            else:
                marker = String(" ")
            # Indent by painting at an offset column rather than building a
            # 2*depth-space prefix string per row per frame; the row
            # background fill above already blanks the indent gap.
            var label = marker + String(" ") + e.name
            _ = painter.put_text(
                canvas, Point(content_x + e.depth * 2, list_top + i), label, attr,
            )

    # --- mouse ------------------------------------------------------------

    def handle_key(mut self, event: Event) -> Bool:
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
        # Framework type-to-jump: any printable letter jumps the
        # selection to the first visible entry whose name starts
        # with the typed prefix. Matches the convention every list
        # widget uses (Settings, dropdowns, dir browser, …).
        if is_printable_ascii(event.key):
            var labels = List[String]()
            for i in range(len(self.entries)):
                labels.append(self.entries[i].name)
            var hit = type_ahead_pick(
                self._type_ahead, labels, chr(Int(event.key)),
            )
            if hit >= 0:
                self.selected = hit
                self._scroll_to_selection()
            return True
        return False

    def _clamp_width(self, want: Int, container_bounds: Rect) -> Int:
        """Pin a proposed width to ``[FILE_TREE_MIN_WIDTH, container_bounds.b.x -
        FILE_TREE_RIGHT_RESERVE]`` so a runaway drag can't shrink the
        editor area below something usable. Order of clamps matters on
        very narrow terminals: when the upper bound would fall below the
        lower, the lower wins (we'd rather have an unusable workspace
        for one frame than a 0-column tree)."""
        var w = want
        var hi = container_bounds.b.x - FILE_TREE_RIGHT_RESERVE
        if w > hi:
            w = hi
        if w < FILE_TREE_MIN_WIDTH:
            w = FILE_TREE_MIN_WIDTH
        return w

    def _scroll_to_selection(mut self):
        # Visible-window height isn't known without ``container_bounds``, so
        # use a conservative fixed visible count — the listing is
        # right-docked at a fixed width and the host gives us at
        # least 10 rows in practice. Erring small means we may
        # over-scroll on tiny terminals; that's preferable to
        # leaving the selection off-container_bounds.
        var visible = 10
        if self.selected < 0:
            return
        if self.selected < self.scroll:
            self.scroll = self.selected
        elif self.selected >= self.scroll + visible:
            self.scroll = self.selected - visible + 1

    def is_on_resize_edge(self, pos: Point, container_bounds: Rect) -> Bool:
        """Hit-test for the separator column — the row-tall handle the
        user drags to widen / narrow the panel. Used by the host to
        switch the mouse pointer to ``ew-resize`` while hovering."""
        if not self.visible:
            return False
        var area = self.rect(container_bounds)
        return pos.x == self._sep_x(area) \
            and pos.y >= area.a.y and pos.y < area.b.y

    def is_resizing(self) -> Bool:
        return self._resizing

    def handle_mouse(mut self, event: Event, container_bounds: Rect) -> Bool:
        """Returns True iff the event was inside the panel (consumed)."""
        if not self.visible:
            return False
        if event.kind != EVENT_MOUSE:
            return False
        var area = self.rect(container_bounds)
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
            # terminals report drag motion that way. The separator sits
            # at column ``width - 1`` when left-docked, hence the +1.
            var want = event.pos.x + 1 if self.dock_left \
                else container_bounds.b.x - event.pos.x
            self.width = self._clamp_width(want, container_bounds)
            return True
        if event.button == MOUSE_BUTTON_LEFT and event.pressed and not event.motion:
            if event.pos.x == self._sep_x(area) \
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
                var list_h = area.b.y - area.a.y
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
        var idx = self.scroll + (event.pos.y - area.a.y)
        if idx < 0 or idx >= len(self.entries):
            return True
        # A click on a directory's expand/collapse chevron toggles it
        # immediately — no select-first round trip.
        if self.entries[idx].is_dir and event.pos.x \
                == self._content_x(area) + 2 * self.entries[idx].depth:
            self.selected = idx
            self._toggle_expand(idx)
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


