"""ProjectFind: fullscreen, debounced full-text project search.

Three stacked panels:

* a top input row (the query string),
* a middle list of matches — each row is the matching line with the hit
  span highlighted, and the relative path + line number right-aligned,
* a bottom context panel showing ±N source lines around the focused
  match.

Search runs through ``find_in_project`` after a 200 ms debounce so
typing doesn't thrash the filesystem; the host calls ``tick(now_ms)``
every frame and ``ProjectFind`` decides when the debounce has elapsed.
The widget reads files lazily for the context panel and caches the most
recently opened one — typical navigation stays inside the same file.
"""

from std.collections.list import List

from .canvas import Canvas
from .cell import Cell
from .colors import (
    Attr, BLACK, BLUE, CYAN, LIGHT_GRAY, RED, WHITE, YELLOW,
)
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_BACKSPACE, KEY_DOWN, KEY_ENTER, KEY_ESC, KEY_PAGEDOWN, KEY_PAGEUP,
    KEY_UP, MOD_ALT, MOD_CTRL,
    MOUSE_BUTTON_LEFT, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .file_io import read_file
from .geometry import Point, Rect
from .highlight import Highlight, extension_of, highlight_for_extension
from .lsp import CaptureResult, capture_command
from .project import ProjectMatch, find_in_project


comptime _DEBOUNCE_MS: Int = 200
comptime _CONTEXT_LINES: Int = 5     # lines on each side of the match


struct ProjectFind(Movable):
    var active: Bool
    var submitted: Bool
    var root: String
    var query: String
    var _last_searched_query: String   # what we last ran a search for
    var _query_dirty_at_ms: Int        # 0 when no debounce pending
    var matches: List[ProjectMatch]
    var selected: Int
    var scroll: Int
    # Output, set when the user hits Enter.
    var selected_path: String
    var selected_line: Int
    # Context cache: lines of the file containing ``matches[selected]``.
    # We reload only when the path changes — typical up/down navigation
    # stays in one file. ``_context_highlights`` is the syntax-highlight
    # overlay computed once per file load.
    var _context_path: String
    var _context_lines: List[String]
    var _context_highlights: List[Highlight]

    fn __init__(out self):
        self.active = False
        self.submitted = False
        self.root = String("")
        self.query = String("")
        self._last_searched_query = String("")
        self._query_dirty_at_ms = 0
        self.matches = List[ProjectMatch]()
        self.selected = 0
        self.scroll = 0
        self.selected_path = String("")
        self.selected_line = 0
        self._context_path = String("")
        self._context_lines = List[String]()
        self._context_highlights = List[Highlight]()

    fn open(mut self, var root: String):
        self.root = root^
        self.query = String("")
        self._last_searched_query = String("")
        self._query_dirty_at_ms = 0
        self.matches = List[ProjectMatch]()
        self.selected = 0
        self.scroll = 0
        self.selected_path = String("")
        self.selected_line = 0
        self._context_path = String("")
        self._context_lines = List[String]()
        self._context_highlights = List[Highlight]()
        self.active = True
        self.submitted = False

    fn close(mut self):
        self.active = False
        self.submitted = False
        self.root = String("")
        self.query = String("")
        self._last_searched_query = String("")
        self._query_dirty_at_ms = 0
        self.matches = List[ProjectMatch]()
        self.selected = 0
        self.scroll = 0
        self.selected_path = String("")
        self.selected_line = 0
        self._context_path = String("")
        self._context_lines = List[String]()
        self._context_highlights = List[Highlight]()

    # --- per-frame tick ---------------------------------------------------

    fn tick(mut self, now_ms: Int):
        """Run the pending search if the debounce window has elapsed.

        ``now_ms`` is a monotonic wall-clock reading; the host pulls it
        from ``posix.monotonic_ms()`` once per frame. ``_query_dirty_at_ms``
        carries the timestamp of the most recent keystroke, with ``0``
        meaning "nothing pending".
        """
        if not self.active:
            return
        if self._query_dirty_at_ms == 0:
            return
        if now_ms - self._query_dirty_at_ms < _DEBOUNCE_MS:
            return
        self._query_dirty_at_ms = 0
        self._run_search()

    fn _mark_query_dirty(mut self, now_ms: Int):
        # Reset the debounce on every keystroke. ``now_ms == 0`` (clock
        # syscall failure) gets clamped to 1 so the "no pending" sentinel
        # stays distinguishable.
        self._query_dirty_at_ms = now_ms if now_ms > 0 else 1

    fn _run_search(mut self):
        self._last_searched_query = self.query
        self.matches = List[ProjectMatch]()
        self.selected = 0
        self.scroll = 0
        if len(self.query.as_bytes()) == 0:
            return
        # Prefer ripgrep — orders of magnitude faster on large trees,
        # honors .gitignore, skips binaries. Fall back to the pure-Mojo
        # walker if ``rg`` isn't installed (or anything else goes wrong).
        var rg = _ripgrep(self.root, self.query)
        if rg.ok:
            self.matches = rg.matches^
            # Re-seat ``rg.matches`` so the struct's auto-destructor has
            # a valid List to destroy after the partial move.
            rg.matches = List[ProjectMatch]()
        else:
            try:
                self.matches = find_in_project(self.root, self.query)
            except:
                self.matches = List[ProjectMatch]()
        # Refresh the context cache for the new top match.
        self._refresh_context_for_selection()

    fn _refresh_context_for_selection(mut self):
        if self.selected < 0 or self.selected >= len(self.matches):
            self._context_path = String("")
            self._context_lines = List[String]()
            self._context_highlights = List[Highlight]()
            return
        var path = self.matches[self.selected].path
        if path == self._context_path and len(self._context_lines) > 0:
            return
        self._context_path = path
        self._context_lines = List[String]()
        self._context_highlights = List[Highlight]()
        var text: String
        try:
            text = read_file(path)
        except:
            return
        self._context_lines = _split_lines(text)
        # Best-effort syntax overlay; languages without a highlighter
        # just get an empty list and the context renders in plain ctx_attr.
        self._context_highlights = highlight_for_extension(
            extension_of(path), self._context_lines,
        )

    # --- geometry ---------------------------------------------------------

    fn _input_y(self, screen: Rect) -> Int:
        return screen.a.y + 1

    fn _list_top(self, screen: Rect) -> Int:
        return screen.a.y + 3

    fn _context_height(self, screen: Rect) -> Int:
        # 1 separator + ``2 * _CONTEXT_LINES + 1`` content rows.
        return 2 * _CONTEXT_LINES + 2

    fn _list_bottom(self, screen: Rect) -> Int:
        return screen.b.y - 1 - self._context_height(screen)

    fn _list_height(self, screen: Rect) -> Int:
        var h = self._list_bottom(screen) - self._list_top(screen)
        if h < 0:
            return 0
        return h

    # --- paint ------------------------------------------------------------

    fn paint(self, mut canvas: Canvas, screen: Rect):
        if not self.active:
            return
        var bg          = Attr(YELLOW, BLUE)
        var border      = Attr(WHITE,  BLUE)
        var title_attr  = Attr(WHITE,  BLUE)
        var input_attr  = Attr(BLACK,  LIGHT_GRAY)
        var label_attr  = Attr(WHITE,  BLUE)
        var line_attr   = Attr(YELLOW, BLUE)
        var sel_line    = Attr(BLACK,  YELLOW)
        var hl_attr     = Attr(WHITE,  RED)            # match highlight
        var sel_hl_attr = Attr(WHITE,  RED)            # same when row selected
        var path_attr   = Attr(LIGHT_GRAY, BLUE)
        var sel_path    = Attr(BLACK,  YELLOW)
        var ctx_attr    = Attr(LIGHT_GRAY, BLUE)
        var ctx_match   = Attr(YELLOW, BLUE)
        var hint_attr   = Attr(BLACK,  LIGHT_GRAY)
        var sep_attr    = Attr(WHITE,  BLUE)
        canvas.fill(screen, String(" "), bg)
        canvas.draw_box(screen, border, True)
        # Title.
        var title = String(" Find in Project ")
        var tx = screen.a.x + (screen.width() - len(title.as_bytes())) // 2
        _ = canvas.put_text(Point(tx, screen.a.y), title, title_attr)
        # Input row: ``Search: <query>_``.
        var input_y = self._input_y(screen)
        var label = String(" Search: ")
        _ = canvas.put_text(
            Point(screen.a.x + 1, input_y), label, label_attr,
            screen.b.x - 1,
        )
        var qx = screen.a.x + 1 + len(label.as_bytes())
        # Visible input strip uses input_attr so the field reads as a box.
        var qw_max = screen.b.x - 2 - qx
        if qw_max < 0:
            qw_max = 0
        canvas.fill(
            Rect(qx, input_y, qx + qw_max, input_y + 1),
            String(" "), input_attr,
        )
        _ = canvas.put_text(
            Point(qx, input_y), self.query, input_attr, screen.b.x - 1,
        )
        var cur = qx + len(self.query.as_bytes())
        if cur < screen.b.x - 1:
            canvas.set(cur, input_y, Cell(String(" "), Attr(LIGHT_GRAY, BLACK), 1))
        # Separator under the input.
        var sep1_y = input_y + 1
        for x in range(screen.a.x + 1, screen.b.x - 1):
            canvas.set(x, sep1_y, Cell(String("─"), sep_attr, 1))
        # Match list.
        var top = self._list_top(screen)
        var h = self._list_height(screen)
        if len(self.matches) == 0:
            var msg: String
            if len(self.query.as_bytes()) == 0:
                msg = String("Type to search.")
            elif self._query_dirty_at_ms != 0 \
                    or self.query != self._last_searched_query:
                msg = String("Searching...")
            else:
                msg = String("No matches.")
            _ = canvas.put_text(
                Point(screen.a.x + 2, top), msg, ctx_attr, screen.b.x - 1,
            )
        for i in range(h):
            var idx = self.scroll + i
            if idx >= len(self.matches):
                break
            self._paint_match_row(
                canvas, screen, top + i, self.matches[idx], idx == self.selected,
                line_attr, sel_line, hl_attr, sel_hl_attr, path_attr, sel_path,
            )
        # Separator above the context panel.
        var ctx_top = self._list_bottom(screen)
        for x in range(screen.a.x + 1, screen.b.x - 1):
            canvas.set(x, ctx_top, Cell(String("─"), sep_attr, 1))
        var ctx_label = String(" Context ")
        var lx = screen.a.x + (screen.width() - len(ctx_label.as_bytes())) // 2
        _ = canvas.put_text(Point(lx, ctx_top), ctx_label, title_attr)
        # Context body.
        self._paint_context(
            canvas, screen, ctx_top + 1, ctx_attr, ctx_match,
        )
        # Hint at the very bottom (overlays the bottom border).
        var hint = String(" Enter: open  ESC: cancel  Up/Down: navigate ")
        var hx = screen.b.x - len(hint.as_bytes()) - 1
        if hx < screen.a.x + 1:
            hx = screen.a.x + 1
        _ = canvas.put_text(Point(hx, screen.b.y - 1), hint, hint_attr)

    fn _paint_match_row(
        self, mut canvas: Canvas, screen: Rect, y: Int,
        m: ProjectMatch, is_sel: Bool,
        line_attr: Attr, sel_line: Attr,
        hl_attr: Attr, sel_hl_attr: Attr,
        path_attr: Attr, sel_path: Attr,
    ):
        var row_attr = sel_line if is_sel else line_attr
        var row_path = sel_path if is_sel else path_attr
        var row_hl = sel_hl_attr if is_sel else hl_attr
        var inner_left = screen.a.x + 1
        var inner_right = screen.b.x - 1
        canvas.fill(Rect(inner_left, y, inner_right, y + 1), String(" "), row_attr)
        # Right-aligned ``rel:line``.
        var path_label = m.rel + String(":") + String(m.line_no)
        var path_len = len(path_label.as_bytes())
        var path_x = inner_right - path_len - 1
        if path_x < inner_left + 1:
            path_x = inner_left + 1
        _ = canvas.put_text(
            Point(path_x, y), path_label, row_path, inner_right,
        )
        # Line text (left-aligned, clipped before the path label).
        var line_x = inner_left + 1
        var line_max = path_x - 1
        if line_max <= line_x:
            return
        var line_stripped = _lstrip_tabs(m.line_text)
        var bytes = line_stripped.as_bytes()
        var hit = _find_bytes(line_stripped, self.query)
        # Slide so the hit (if any) is visible inside the available width.
        var avail = line_max - line_x
        var start = 0
        if hit >= 0 and hit + len(self.query.as_bytes()) > avail:
            # Center the hit, keeping start >= 0.
            start = hit - avail // 3
            if start < 0:
                start = 0
        var end = len(bytes)
        if end - start > avail:
            end = start + avail
        # Render plain run.
        for i in range(start, end):
            var b = Int(bytes[i])
            var ch = chr(b) if b < 0x80 else String("?")
            canvas.set(line_x + (i - start), y, Cell(ch, row_attr, 1))
        # Highlight overlay for the hit.
        if hit >= 0 and len(self.query.as_bytes()) > 0:
            var hl_start = hit
            var hl_end = hit + len(self.query.as_bytes())
            if hl_start < start: hl_start = start
            if hl_end > end:     hl_end = end
            for i in range(hl_start, hl_end):
                var b = Int(bytes[i])
                var ch = chr(b) if b < 0x80 else String("?")
                canvas.set(line_x + (i - start), y, Cell(ch, row_hl, 1))
        # Leading "…" hint when the line was sliced from the left.
        if start > 0:
            canvas.set(line_x, y, Cell(String("…"), row_attr, 1))

    fn _paint_context(
        self, mut canvas: Canvas, screen: Rect, top_y: Int,
        ctx_attr: Attr, match_attr: Attr,
    ):
        var inner_left = screen.a.x + 1
        var inner_right = screen.b.x - 1
        var rows = 2 * _CONTEXT_LINES + 1
        var hit_attr = Attr(WHITE, RED)         # match-substring highlight
        if self.selected < 0 or self.selected >= len(self.matches):
            return
        var m = self.matches[self.selected]
        var center = m.line_no - 1   # 0-based
        if len(self._context_lines) == 0 \
                or self._context_path != m.path:
            _ = canvas.put_text(
                Point(inner_left + 1, top_y),
                String("(loading ") + m.rel + String(")"),
                ctx_attr, inner_right,
            )
            return
        var line_count = len(self._context_lines)
        for k in range(rows):
            var src = center - _CONTEXT_LINES + k
            var y = top_y + k
            if y >= screen.b.y - 1:
                break
            if src < 0 or src >= line_count:
                continue
            var is_match = (src == center)
            # Marker + line-number gutter — kept dim; the match marker
            # is the only color cue for which row is the hit.
            var marker = String("▶ ") if is_match else String("  ")
            var marker_attr = match_attr if is_match else ctx_attr
            var lineno = String(src + 1) + String(": ")
            var x = inner_left + 1
            _ = canvas.put_text(Point(x, y), marker, marker_attr, inner_right)
            x += len(marker.as_bytes())
            _ = canvas.put_text(Point(x, y), lineno, ctx_attr, inner_right)
            x += len(lineno.as_bytes())
            # Plain text pass — establishes glyph + base attr per cell.
            var line = self._context_lines[src]
            var bytes = line.as_bytes()
            var max = inner_right - x
            if max < 0: max = 0
            var end = len(bytes)
            if end > max: end = max
            for i in range(end):
                var b = Int(bytes[i])
                var ch = chr(b) if b < 0x80 else String("?")
                canvas.set(x + i, y, Cell(ch, ctx_attr, 1))
            # Syntax-highlight overlay for this row. Highlights are
            # attr-only (glyph already painted above), so order with
            # respect to the plain pass doesn't matter for content.
            for h in range(len(self._context_highlights)):
                var hl = self._context_highlights[h]
                if hl.row != src:
                    continue
                var hs = hl.col_start
                var he = hl.col_end
                if hs < 0:    hs = 0
                if he > end:  he = end
                for i in range(hs, he):
                    var b = Int(bytes[i])
                    var ch = chr(b) if b < 0x80 else String("?")
                    canvas.set(x + i, y, Cell(ch, hl.attr, 1))
            # Match-substring highlight on the center row only.
            if is_match and len(self.query.as_bytes()) > 0:
                var hit = _find_bytes(line, self.query)
                if hit >= 0:
                    var hs = hit
                    var he = hit + len(self.query.as_bytes())
                    if he > end: he = end
                    for i in range(hs, he):
                        if i < 0 or i >= end:
                            continue
                        var b = Int(bytes[i])
                        var ch = chr(b) if b < 0x80 else String("?")
                        canvas.set(x + i, y, Cell(ch, hit_attr, 1))

    # --- events -----------------------------------------------------------

    fn handle_key(mut self, event: Event, now_ms: Int) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_KEY:
            return True
        var k = event.key
        if k == KEY_ESC:
            self.close()
            return True
        if k == KEY_ENTER:
            if self.selected < 0 or self.selected >= len(self.matches):
                return True
            var m = self.matches[self.selected]
            self.selected_path = m.path
            self.selected_line = m.line_no
            self.submitted = True
            return True
        if k == KEY_UP:
            if self.selected > 0:
                self.selected -= 1
                self._scroll_to_selection()
                self._refresh_context_for_selection()
            return True
        if k == KEY_DOWN:
            if self.selected + 1 < len(self.matches):
                self.selected += 1
                self._scroll_to_selection()
                self._refresh_context_for_selection()
            return True
        if k == KEY_PAGEUP:
            self.selected -= 10
            if self.selected < 0:
                self.selected = 0
            self._scroll_to_selection()
            self._refresh_context_for_selection()
            return True
        if k == KEY_PAGEDOWN:
            self.selected += 10
            if self.selected >= len(self.matches):
                self.selected = len(self.matches) - 1
            if self.selected < 0:
                self.selected = 0
            self._scroll_to_selection()
            self._refresh_context_for_selection()
            return True
        if k == KEY_BACKSPACE:
            var qb = self.query.as_bytes()
            if len(qb) > 0:
                self.query = String(StringSlice(
                    unsafe_from_utf8=qb[:len(qb) - 1],
                ))
                self._mark_query_dirty(now_ms)
            return True
        if (event.mods & MOD_CTRL) != 0 or (event.mods & MOD_ALT) != 0:
            return True
        if UInt32(0x20) <= k and k < UInt32(0x7F):
            self.query = self.query + chr(Int(k))
            self._mark_query_dirty(now_ms)
            return True
        return True

    fn handle_mouse(mut self, event: Event, screen: Rect) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_MOUSE:
            return True
        if event.pressed and not event.motion:
            if event.button == MOUSE_WHEEL_UP:
                if self.scroll > 0:
                    self.scroll -= 3
                    if self.scroll < 0:
                        self.scroll = 0
                return True
            if event.button == MOUSE_WHEEL_DOWN:
                var visible = self._list_height(screen)
                var max_scroll = len(self.matches) - visible
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
        var top = self._list_top(screen)
        var h = self._list_height(screen)
        if event.pos.y < top or event.pos.y >= top + h:
            return True
        var idx = self.scroll + (event.pos.y - top)
        if idx < 0 or idx >= len(self.matches):
            return True
        if idx == self.selected:
            var m = self.matches[idx]
            self.selected_path = m.path
            self.selected_line = m.line_no
            self.submitted = True
            return True
        self.selected = idx
        self._refresh_context_for_selection()
        return True

    fn _scroll_to_selection(mut self):
        # Conservative window: assume ~12 visible rows; the actual list
        # height depends on the screen so we re-clamp on paint.
        var visible = 12
        if self.selected < self.scroll:
            self.scroll = self.selected
        elif self.selected >= self.scroll + visible:
            self.scroll = self.selected - visible + 1


# --- internals --------------------------------------------------------------


fn _split_lines(text: String) -> List[String]:
    var out = List[String]()
    var b = text.as_bytes()
    var start = 0
    for i in range(len(b)):
        if b[i] == 0x0A:
            out.append(String(StringSlice(unsafe_from_utf8=b[start:i])))
            start = i + 1
    if start <= len(b):
        out.append(String(StringSlice(unsafe_from_utf8=b[start:len(b)])))
    return out^


fn _lstrip_tabs(s: String) -> String:
    """Drop leading whitespace (tabs/spaces) so the first non-blank
    character of the line lines up at the row's left edge — search hits
    in deeply indented code stay on-screen."""
    var b = s.as_bytes()
    var i = 0
    while i < len(b) and (b[i] == 0x20 or b[i] == 0x09):
        i += 1
    if i == 0:
        return s
    return String(StringSlice(unsafe_from_utf8=b[i:len(b)]))


@fieldwise_init
struct _RgResult(Movable):
    """Internal: ``ok=False`` flags an unusable rg run (binary missing,
    spawn error, malformed output) and tells the caller to fall back."""
    var ok: Bool
    var matches: List[ProjectMatch]


fn _ripgrep(root: String, query: String) -> _RgResult:
    """Shell out to ``rg`` and parse its match-line output.

    We pass ``--no-heading --line-number --column --color=never`` so the
    format is stable across rg versions: match lines look like
    ``path:line:col:text``. ``rel`` is computed by stripping ``root/``
    from the front of the path (rg prints that prefix when invoked with
    a directory). Exit codes 0 and 1 are both success — rg uses 1 to
    mean "no matches", which is a normal outcome here.
    """
    var argv = List[String]()
    argv.append(String("rg"))
    argv.append(String("--no-heading"))
    argv.append(String("--line-number"))
    argv.append(String("--column"))
    argv.append(String("--color=never"))
    argv.append(String("--smart-case"))
    argv.append(String("-F"))                # fixed-string (no regex)
    argv.append(String("--"))                # end of options
    argv.append(query)
    argv.append(root)
    var out: String
    var status: Int32
    try:
        var result = capture_command(argv)
        status = result.status
        out = result.stdout^
        # Reseat the moved field so ``result``'s auto-destructor still
        # has a valid String to drop.
        result.stdout = String("")
    except:
        return _RgResult(False, List[ProjectMatch]())
    var exit_code = (Int(status) >> 8) & 0xFF
    if exit_code != 0 and exit_code != 1:
        return _RgResult(False, List[ProjectMatch]())
    var matches = List[ProjectMatch]()
    var i = 0
    var n = len(out.as_bytes())
    while i < n:
        var line_end = _scan_to_newline(out, i)
        var p1 = _scan_to(out, i, line_end, 0x3A)        # first ':'
        if p1 < 0:
            i = line_end + 1
            continue
        var p2 = _scan_to(out, p1 + 1, line_end, 0x3A)   # second ':'
        if p2 < 0:
            i = line_end + 1
            continue
        var p3 = _scan_to(out, p2 + 1, line_end, 0x3A)   # third ':'
        if p3 < 0:
            i = line_end + 1
            continue
        var path = _slice_str(out, i, p1)
        var line_no = _parse_uint(out, p1 + 1, p2)
        # Column at p2+1..p3 isn't stored — only line is needed for
        # cursor placement; the row highlighter re-finds the match span.
        var text = _slice_str(out, p3 + 1, line_end)
        if line_no > 0:
            matches.append(ProjectMatch(
                path, _strip_root(path, root), line_no, text,
            ))
        i = line_end + 1
    return _RgResult(True, matches^)


fn _scan_to_newline(s: String, start: Int) -> Int:
    var b = s.as_bytes()
    var i = start
    while i < len(b) and b[i] != 0x0A:
        i += 1
    return i


fn _scan_to(s: String, start: Int, end: Int, target: UInt8) -> Int:
    var b = s.as_bytes()
    var i = start
    while i < end:
        if b[i] == target:
            return i
        i += 1
    return -1


fn _parse_uint(s: String, start: Int, end: Int) -> Int:
    var b = s.as_bytes()
    var n = 0
    var any = False
    var i = start
    while i < end:
        var v = Int(b[i])
        if v < 0x30 or v > 0x39:
            return -1
        n = n * 10 + (v - 0x30)
        any = True
        i += 1
    if not any:
        return -1
    return n


fn _slice_str(s: String, start: Int, end: Int) -> String:
    var b = s.as_bytes()
    if start >= end:
        return String("")
    return String(StringSlice(unsafe_from_utf8=b[start:end]))


fn _strip_root(path: String, root: String) -> String:
    var pb = path.as_bytes()
    var rb = root.as_bytes()
    if len(rb) == 0 or len(pb) <= len(rb) + 1:
        return path
    for k in range(len(rb)):
        if pb[k] != rb[k]:
            return path
    if pb[len(rb)] != 0x2F:
        return path
    return String(StringSlice(unsafe_from_utf8=pb[len(rb) + 1:]))


fn _find_bytes(haystack: String, needle: String) -> Int:
    """First byte offset of ``needle`` in ``haystack``, or ``-1``."""
    var hb = haystack.as_bytes()
    var nb = needle.as_bytes()
    if len(nb) == 0 or len(nb) > len(hb):
        return -1
    var i = 0
    while i + len(nb) <= len(hb):
        var ok = True
        for j in range(len(nb)):
            if hb[i + j] != nb[j]:
                ok = False
                break
        if ok:
            return i
        i += 1
    return -1
