"""LocalChanges: fullscreen "what's changed in my worktree?" view.

Two stacked panels:

* a left sidebar listing each file modified relative to ``HEAD`` (taken
  from ``git diff HEAD --no-color``),
* a right pane showing the unified-diff text for the focused file with
  +/- / hunk-header lines colorized by prefix.

Same shape as ``ProjectFind`` from a host perspective: ``open(root)``
populates the panels; ``handle_key`` / ``handle_mouse`` drive nav;
``submitted`` + ``selected_path`` + ``selected_line`` carry the user's
"open this file" choice back to ``Desktop``.

The diff is computed once on ``open`` (no debounced re-run — the user
re-opens the panel to refresh). Per-file colorization is hand-rolled
rather than going through TextMate so the renderer doesn't have to
synthesize a fake ``.diff`` file extension and pay the regex-compile
cost on every paint.
"""

from std.collections.list import List
from std.collections.optional import Optional

from .canvas import Canvas
from .cell import Cell
from .colors import (
    Attr, BLACK, BLUE, CYAN, DARK_GRAY, LIGHT_GRAY, LIGHT_GREEN, LIGHT_RED,
    WHITE, YELLOW,
)
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_DOWN, KEY_END, KEY_ENTER, KEY_ESC, KEY_HOME, KEY_PAGEDOWN, KEY_PAGEUP,
    KEY_UP,
    MOUSE_BUTTON_LEFT, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .geometry import Point, Rect
from .git_changes import (
    ChangedFile, compute_local_changes, parse_unified_diff_files,
)


comptime _SIDEBAR_MIN: Int = 24
comptime _SIDEBAR_MAX: Int = 50


fn _split_lines(text: String) -> List[String]:
    var out = List[String]()
    var b = text.as_bytes()
    var s = 0
    for i in range(len(b)):
        if b[i] == 0x0A:
            out.append(String(StringSlice(unsafe_from_utf8=b[s:i])))
            s = i + 1
    if s < len(b):
        out.append(String(StringSlice(unsafe_from_utf8=b[s:len(b)])))
    return out^


fn _line_attr(line: String, default: Attr, add: Attr, rem: Attr,
              hunk: Attr, header: Attr) -> Attr:
    """Pick a color for a unified-diff line based on its prefix.

    Order matters: ``+++`` and ``---`` are *headers*, not adds /
    deletes, so they have to be checked before the bare ``+`` / ``-``
    test. Same with ``@@`` (hunk-marker) which would otherwise look
    like a normal context line."""
    var b = line.as_bytes()
    if len(b) == 0:
        return default
    var c0 = Int(b[0])
    if len(b) >= 3:
        var c1 = Int(b[1])
        var c2 = Int(b[2])
        if c0 == 0x2B and c1 == 0x2B and c2 == 0x2B:    # +++
            return header
        if c0 == 0x2D and c1 == 0x2D and c2 == 0x2D:    # ---
            return header
        if c0 == 0x40 and c1 == 0x40:                   # @@
            return hunk
    if c0 == 0x2B:    # +
        return add
    if c0 == 0x2D:    # -
        return rem
    # ``diff --git``, ``index``, ``new file mode``, ``rename`` etc.
    if c0 == 0x64 and len(b) >= 4 \
            and Int(b[1]) == 0x69 and Int(b[2]) == 0x66 and Int(b[3]) == 0x66:
        return header
    if c0 == 0x69 and len(b) >= 6 \
            and Int(b[1]) == 0x6E and Int(b[2]) == 0x64 \
            and Int(b[3]) == 0x65 and Int(b[4]) == 0x78:
        return header
    return default


struct LocalChanges(Movable):
    var active: Bool
    var submitted: Bool
    var root: String
    var files: List[ChangedFile]
    # Cached split of the focused file's diff into individual lines,
    # so paint doesn't re-split on every frame and Up/Down only pays
    # the cost when the selection moves.
    var _diff_lines: List[String]
    var _diff_lines_for: Int
    var selected: Int
    var sidebar_scroll: Int
    var diff_scroll: Int
    var diff_scroll_x: Int
    # ``submitted`` carries (path, line_no=0) back to the host on Enter
    # so the dispatcher can route through the same ``_jump_to`` helper
    # that ``ProjectFind`` uses.
    var selected_path: String
    var selected_line: Int
    # Banner text to show in place of the file list when the diff was
    # empty / git failed. Empty means "render the list normally".
    var status_message: String

    fn __init__(out self):
        self.active = False
        self.submitted = False
        self.root = String("")
        self.files = List[ChangedFile]()
        self._diff_lines = List[String]()
        self._diff_lines_for = -1
        self.selected = 0
        self.sidebar_scroll = 0
        self.diff_scroll = 0
        self.diff_scroll_x = 0
        self.selected_path = String("")
        self.selected_line = 0
        self.status_message = String("")

    fn open(mut self, var root: String):
        """Run ``git diff HEAD`` against ``root`` and populate the
        per-file list. Synchronous: the diff for a real project is
        kilobytes, and tearing down the modal is the user's "refresh"
        gesture so we don't need a debounced re-run."""
        self.root = root^
        self.active = True
        self.submitted = False
        self.files = List[ChangedFile]()
        self._diff_lines = List[String]()
        self._diff_lines_for = -1
        self.selected = 0
        self.sidebar_scroll = 0
        self.diff_scroll = 0
        self.diff_scroll_x = 0
        self.selected_path = String("")
        self.selected_line = 0
        self.status_message = String("")
        var diff_text: String
        try:
            diff_text = compute_local_changes(self.root)
        except:
            self.status_message = String("git not available")
            return
        if len(diff_text.as_bytes()) == 0:
            self.status_message = \
                String("No local changes (worktree matches HEAD).")
            return
        self.files = parse_unified_diff_files(diff_text)
        if len(self.files) == 0:
            self.status_message = String("No file diffs were parsed.")

    fn close(mut self):
        self.active = False
        self.submitted = False
        self.root = String("")
        self.files = List[ChangedFile]()
        self._diff_lines = List[String]()
        self._diff_lines_for = -1
        self.selected = 0
        self.sidebar_scroll = 0
        self.diff_scroll = 0
        self.diff_scroll_x = 0
        self.selected_path = String("")
        self.selected_line = 0
        self.status_message = String("")

    # --- geometry ---------------------------------------------------------

    fn _sidebar_width(self, screen: Rect) -> Int:
        var w = screen.width() // 3
        if w < _SIDEBAR_MIN: w = _SIDEBAR_MIN
        if w > _SIDEBAR_MAX: w = _SIDEBAR_MAX
        # Don't eat more than half the screen on a narrow terminal.
        if w > screen.width() // 2:
            w = screen.width() // 2
        if w < 12:
            w = 12
        return w

    fn _list_top(self, screen: Rect) -> Int:
        return screen.a.y + 2

    fn _list_bottom(self, screen: Rect) -> Int:
        return screen.b.y - 1

    fn _list_height(self, screen: Rect) -> Int:
        var h = self._list_bottom(screen) - self._list_top(screen)
        return 0 if h < 0 else h

    fn _diff_left(self, screen: Rect) -> Int:
        # +1 leaves the vertical separator column visible at sidebar
        # right edge, +2 gives the diff body a one-cell padding.
        return screen.a.x + self._sidebar_width(screen) + 1

    fn _diff_right(self, screen: Rect) -> Int:
        return screen.b.x - 1

    fn _diff_width(self, screen: Rect) -> Int:
        var w = self._diff_right(screen) - self._diff_left(screen) - 1
        return 0 if w < 0 else w

    fn _diff_height(self, screen: Rect) -> Int:
        return self._list_height(screen)

    fn is_input_at(self, pos: Point, screen: Rect) -> Bool:
        # No editable input field; cursor stays in default shape.
        return False

    # --- paint ------------------------------------------------------------

    fn _ensure_diff_lines(mut self):
        """Re-split the focused file's diff if the selection moved."""
        if self.selected < 0 or self.selected >= len(self.files):
            self._diff_lines = List[String]()
            self._diff_lines_for = -1
            return
        if self._diff_lines_for == self.selected \
                and len(self._diff_lines) > 0:
            return
        self._diff_lines = _split_lines(self.files[self.selected].diff)
        self._diff_lines_for = self.selected

    fn paint(mut self, mut canvas: Canvas, screen: Rect):
        if not self.active:
            return
        var bg          = Attr(YELLOW, BLUE)
        var border      = Attr(WHITE,  BLUE)
        var title_attr  = Attr(WHITE,  BLUE)
        var sep_attr    = Attr(WHITE,  BLUE)
        var hint_attr   = Attr(BLACK,  LIGHT_GRAY)
        var list_attr   = Attr(YELLOW, BLUE)
        var list_dim    = Attr(LIGHT_GRAY, BLUE)
        var sel_attr    = Attr(BLACK,  YELLOW)
        var ctx_attr    = Attr(LIGHT_GRAY, BLUE)
        var add_attr    = Attr(LIGHT_GREEN, BLUE)
        var rem_attr    = Attr(LIGHT_RED,   BLUE)
        var hunk_attr   = Attr(CYAN,  BLUE)
        var header_attr = Attr(WHITE, BLUE)
        canvas.fill(screen, String(" "), bg)
        canvas.draw_box(screen, border, True)
        # Title row.
        var title = String(" Local changes ")
        var tx = screen.a.x + (screen.width() - len(title.as_bytes())) // 2
        _ = canvas.put_text(Point(tx, screen.a.y), title, title_attr)
        # Sub-title: project root (or status message).
        var sub_y = screen.a.y + 1
        var sub: String
        if len(self.status_message.as_bytes()) > 0:
            sub = String(" ") + self.status_message
        elif len(self.files) == 0:
            sub = String(" (no files)")
        else:
            sub = String(" ") + String(len(self.files)) \
                + String(" files changed in ") + self.root
        _ = canvas.put_text(
            Point(screen.a.x + 1, sub_y), sub, list_dim, screen.b.x - 1,
        )
        # Vertical separator between sidebar and diff pane.
        var sw = self._sidebar_width(screen)
        var sep_x = screen.a.x + sw
        for y in range(self._list_top(screen), self._list_bottom(screen)):
            canvas.set(sep_x, y, Cell(String("│"), sep_attr, 1))
        # Sidebar: the file list.
        self._paint_sidebar(
            canvas, screen, list_attr, sel_attr, list_dim,
        )
        # Right pane: the focused file's diff.
        self._ensure_diff_lines()
        self._paint_diff(
            canvas, screen,
            ctx_attr, add_attr, rem_attr, hunk_attr, header_attr,
        )
        # Bottom hint (overlays the bottom border).
        var hint = String(
            " Enter: open file  Up/Down: file  PgUp/PgDn: scroll diff  ESC: close ",
        )
        var hx = screen.b.x - len(hint.as_bytes()) - 1
        if hx < screen.a.x + 1:
            hx = screen.a.x + 1
        _ = canvas.put_text(Point(hx, screen.b.y - 1), hint, hint_attr)

    fn _paint_sidebar(
        self, mut canvas: Canvas, screen: Rect,
        list_attr: Attr, sel_attr: Attr, dim_attr: Attr,
    ):
        var top = self._list_top(screen)
        var height = self._list_height(screen)
        var left = screen.a.x + 1
        var right = screen.a.x + self._sidebar_width(screen) - 1
        if right <= left:
            return
        if len(self.files) == 0:
            return
        for i in range(height):
            var idx = self.sidebar_scroll + i
            if idx >= len(self.files):
                break
            var y = top + i
            var is_sel = (idx == self.selected)
            var attr = sel_attr if is_sel else list_attr
            canvas.fill(
                Rect(left, y, right + 1, y + 1), String(" "), attr,
            )
            # Path is shown right-truncated so the basename always wins
            # the visible columns; full path is in the right pane's
            # ``+++`` header anyway.
            var path = self.files[idx].path
            var pb = path.as_bytes()
            var avail = right - left - 1
            if avail < 1:
                avail = 1
            if len(pb) > avail:
                # Mark the truncation with a leading ``…``, then drop
                # one extra byte off the front to make room for it.
                canvas.set(left + 1, y, Cell(String("…"), attr, 1))
                var start = len(pb) - avail + 1
                _ = canvas.put_text(
                    Point(left + 2, y),
                    String(StringSlice(unsafe_from_utf8=pb[start:len(pb)])),
                    attr, right + 1,
                )
            else:
                _ = canvas.put_text(
                    Point(left + 1, y), path, attr, right + 1,
                )

    fn _paint_diff(
        self, mut canvas: Canvas, screen: Rect,
        ctx_attr: Attr, add_attr: Attr, rem_attr: Attr,
        hunk_attr: Attr, header_attr: Attr,
    ):
        var top = self._list_top(screen)
        var height = self._diff_height(screen)
        var left = self._diff_left(screen)
        var right = self._diff_right(screen)
        if right <= left:
            return
        if len(self._diff_lines) == 0:
            var msg: String
            if len(self.files) == 0:
                msg = String(" Nothing to show.")
            else:
                msg = String(" (empty diff)")
            _ = canvas.put_text(
                Point(left, top), msg, ctx_attr, right,
            )
            return
        for i in range(height):
            var idx = self.diff_scroll + i
            if idx >= len(self._diff_lines):
                break
            var y = top + i
            var line = self._diff_lines[idx]
            var attr = _line_attr(
                line, ctx_attr, add_attr, rem_attr, hunk_attr, header_attr,
            )
            # Apply horizontal scroll: byte-level slice is fine for
            # ASCII diff content; the rare multi-byte glyph (e.g. a
            # name in a comment) gets a non-aligned cut on heavy
            # horizontal scroll, which is visible but doesn't crash.
            var bytes = line.as_bytes()
            var start = self.diff_scroll_x
            if start >= len(bytes):
                continue
            var visible = String(StringSlice(
                unsafe_from_utf8=bytes[start:len(bytes)],
            ))
            _ = canvas.put_text(Point(left, y), visible, attr, right)

    # --- events -----------------------------------------------------------

    fn _select(mut self, idx: Int, screen: Rect):
        if len(self.files) == 0:
            return
        var n = len(self.files)
        var new = idx
        if new < 0:
            new = 0
        if new >= n:
            new = n - 1
        if new == self.selected:
            return
        self.selected = new
        # Reset diff scroll so the new file starts at the top of the
        # right pane — much less disorienting than carrying the old
        # offset onto a different file.
        self.diff_scroll = 0
        self.diff_scroll_x = 0
        # Make sure ``selected`` is inside the visible window.
        var h = self._list_height(screen)
        if self.selected < self.sidebar_scroll:
            self.sidebar_scroll = self.selected
        elif self.selected >= self.sidebar_scroll + h:
            self.sidebar_scroll = self.selected - h + 1
        if self.sidebar_scroll < 0:
            self.sidebar_scroll = 0

    fn _scroll_diff(mut self, delta: Int, screen: Rect):
        self._ensure_diff_lines()
        var n = len(self._diff_lines)
        var h = self._diff_height(screen)
        var max_scroll = n - h
        if max_scroll < 0:
            max_scroll = 0
        var s = self.diff_scroll + delta
        if s < 0:
            s = 0
        if s > max_scroll:
            s = max_scroll
        self.diff_scroll = s

    fn handle_key(mut self, event: Event, screen: Rect) -> Bool:
        if not self.active or event.kind != EVENT_KEY:
            return False
        var k = event.key
        if k == KEY_ESC:
            self.close()
            return True
        if k == KEY_UP:
            self._select(self.selected - 1, screen)
            return True
        if k == KEY_DOWN:
            self._select(self.selected + 1, screen)
            return True
        if k == KEY_HOME:
            self._select(0, screen)
            return True
        if k == KEY_END:
            self._select(len(self.files) - 1, screen)
            return True
        if k == KEY_PAGEUP:
            self._scroll_diff(-self._diff_height(screen), screen)
            return True
        if k == KEY_PAGEDOWN:
            self._scroll_diff(self._diff_height(screen), screen)
            return True
        if k == KEY_ENTER:
            if 0 <= self.selected and self.selected < len(self.files):
                # Compose the absolute-ish path: caller will resolve
                # against project root via ``_jump_to``'s open_file
                # path-handling, which already accepts both forms.
                self.selected_path = self.files[self.selected].path
                self.selected_line = 0
                self.submitted = True
            return True
        return False

    fn handle_mouse(mut self, event: Event, screen: Rect) -> Bool:
        if not self.active or event.kind != EVENT_MOUSE:
            return False
        var pos = event.pos
        var sw = self._sidebar_width(screen)
        var sidebar_right = screen.a.x + sw
        var top = self._list_top(screen)
        var bottom = self._list_bottom(screen)
        # Wheel: forward to whichever pane the cursor sits over.
        if event.button == MOUSE_WHEEL_UP:
            if pos.x < sidebar_right:
                if self.sidebar_scroll > 0:
                    self.sidebar_scroll -= 1
            else:
                self._scroll_diff(-3, screen)
            return True
        if event.button == MOUSE_WHEEL_DOWN:
            if pos.x < sidebar_right:
                var max_top = len(self.files) - self._list_height(screen)
                if max_top < 0: max_top = 0
                if self.sidebar_scroll < max_top:
                    self.sidebar_scroll += 1
            else:
                self._scroll_diff(3, screen)
            return True
        if event.button == MOUSE_BUTTON_LEFT and event.pressed:
            if pos.x < sidebar_right and top <= pos.y and pos.y < bottom:
                var idx = self.sidebar_scroll + (pos.y - top)
                if 0 <= idx and idx < len(self.files):
                    self._select(idx, screen)
                return True
        return False
