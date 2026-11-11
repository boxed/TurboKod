"""The test panes' results view: a run's live report, laid out.

Shared by the two panes that run tests — ``TestPane`` (the pty-backed pane)
and the tmux tests pane (``TerminalPane`` with ``tests``) — which own the
child and the terminal grid and hand their body to this view when the user
picks Results over Output (``config.test_results_view``). The view owns the
``TestReport`` the runner writes (see ``test_report.mojo``), and paints:

* row 0, a progress bar with the counts per outcome;
* row 1, the test in progress, or how the run ended;
* below, split in two: the **list** of every test with an icon for its
  state, and the **detail** of the selected one — its id (a link to the
  test), outcome and duration, message, and the traceback and captured
  output, wrapped, with ``File "...", line N`` / ``path:N`` spans clickable
  like the terminal grid's. A landscape body (wider than tall, in pixels:
  cells are twice as tall as wide) puts the list on the left and the detail
  on the right; a portrait one the list on top. The divider is a
  ``SplitArea``, so it drags (a double click resets it), with each
  orientation's position remembered on its own (the host keeps them in
  ``config.test_split_wide`` / ``test_split_tall``). Each half scrolls with
  its own ``ScrollBarArea``.

Until the user picks a test the first failure is selected as soon as it
arrives. Up / Down move the selection, Page Up / Down scroll the detail,
Home / End go to the first / last test and Enter opens the selected one.

The pane paints the view into the terminal-font grid it would have put the
``Vt`` in, so the view's coordinates are the grid's (``origin`` is the
grid's corner in ``GridSelection.grid_event`` coordinates).

In the macOS-style and Mac OS 9 looks (``Canvas.host_widgets``) the view
paints only blank cells and leaves itself to the host: three ``HostItem``s
(``HOST_TEST_HEADER`` / ``_LIST`` / ``_DETAIL``, tagged ``host_tag``) say
where its regions are, ``native_state`` / ``native_detail`` what's in them
— the list incrementally, by each test's ``stamp`` — and ``native_act``
takes the host's clicks back. The split divider stays the core's.
"""

from std.collections.list import List
from std.collections.optional import Optional

from .canvas import (
    Canvas, HOST_TEST_DETAIL, HOST_TEST_HEADER, HOST_TEST_LIST, HostItem,
    SCALE_ONE,
)
from .json import JsonValue, json_array, json_bool, json_int, json_object, json_str
from .cell import Cell
from .colors import (
    Attr, BLACK, DARK_GRAY, LIGHT_BLUE, LIGHT_CYAN, LIGHT_GRAY, LIGHT_GREEN,
    LIGHT_MAGENTA, LIGHT_RED, LIGHT_YELLOW, PANE_BG, PANE_FG, STYLE_BOLD,
    STYLE_UNDERLINE, WHITE,
)
from .events import (
    Event, EVENT_KEY, KEY_DOWN, KEY_END, KEY_ENTER, KEY_HOME, KEY_PAGEDOWN,
    KEY_PAGEUP, KEY_UP, MOD_NONE, MOUSE_BUTTON_LEFT, MOUSE_WHEEL_DOWN,
    MOUSE_WHEEL_UP,
)
from .geometry import Point, Rect
from .output_links import extract_all_links, link_at, OutputLink
from .scrollbar import ScrollBarArea
from .split_area import SplitArea
from .string_utils import char_width, display_columns
from .test_report import (
    OUTCOME_ERROR, OUTCOME_FAILED, OUTCOME_PASSED, OUTCOME_RUNNING,
    OUTCOME_SKIPPED, OUTCOME_XFAILED, OUTCOME_XPASSED, TestReport,
    TestResult,
)


comptime TEST_TOGGLE_VIEW = String("test:toggle_view")
"""The title-strip command both test panes carry to switch between the
results view and the terminal output; the host flips
``config.test_results_view``."""

comptime RESULTS_LABEL = String("[☰ Results]")
comptime OUTPUT_LABEL = String("[▤ Output]")
"""The title-strip toggle's two faces: what clicking it switches to."""


def outcome_icon(outcome: UInt8) -> Tuple[String, UInt8]:
    """The list's icon for a test's state, and its color."""
    if outcome == OUTCOME_PASSED:
        return (String("✓"), LIGHT_GREEN)
    if outcome == OUTCOME_FAILED:
        return (String("✗"), LIGHT_RED)
    if outcome == OUTCOME_ERROR:
        return (String("⚠"), LIGHT_MAGENTA)
    if outcome == OUTCOME_SKIPPED:
        return (String("↷"), LIGHT_YELLOW)
    if outcome == OUTCOME_XFAILED:
        return (String("x"), LIGHT_GRAY)
    if outcome == OUTCOME_XPASSED:
        return (String("!"), LIGHT_YELLOW)
    return (String("▸"), LIGHT_CYAN)


def outcome_name(outcome: UInt8) -> String:
    if outcome == OUTCOME_PASSED:
        return String("passed")
    if outcome == OUTCOME_FAILED:
        return String("failed")
    if outcome == OUTCOME_ERROR:
        return String("error")
    if outcome == OUTCOME_SKIPPED:
        return String("skipped")
    if outcome == OUTCOME_XFAILED:
        return String("expected failure")
    if outcome == OUTCOME_XPASSED:
        return String("unexpectedly passed")
    return String("running")


comptime DEFAULT_SPLIT = 400
"""The list's share of the split (thousandths) until the user drags it."""


def is_landscape(width: Int, height: Int) -> Bool:
    """Whether a ``width`` x ``height`` cell area is wider than tall on
    screen — a cell is half as wide as it is tall."""
    return width >= 2 * height


struct TestResultsView(Copyable, Movable):
    var report: TestReport
    """What the runner reported about the current run (nothing, for a
    runner that doesn't speak the protocol)."""
    var selected: Int
    """``report.tests`` position of the test the detail shows; -1 none."""
    var _picked: Bool
    """The user chose ``selected``; until then it follows the first
    failure."""
    var _reveal: Bool
    """Scroll the list to ``selected`` on the next paint."""
    var split_wide: SplitArea
    """The divider of the side-by-side layout (list left)."""
    var split_tall: SplitArea
    """The divider of the stacked layout (list on top)."""
    var _list_scroll: Int
    var _list_moved: Bool
    """The user scrolled the list. Until then, while nothing is selected,
    it follows the newest test."""
    var _list_bar: ScrollBarArea
    var _list_rect: Rect
    """Where the list was last painted, in grid cells (``Rect.empty``
    when it wasn't)."""
    var _detail_scroll: Int
    var _detail_bar: ScrollBarArea
    var _detail_rect: Rect
    var _rows: List[ResultRow]
    """The detail laid out for ``_rows_width`` columns from report
    ``_rows_version`` and test ``_rows_selected``; rebuilt when any
    changes."""
    var _rows_version: Int
    var _rows_width: Int
    var _rows_selected: Int
    var _last_links: List[OutputLink]
    var _clicked: Optional[OutputLink]
    var host_tag: Int
    """The pane this view belongs to, on its host items (0 the test pane,
    1 + i the tmux tests pane ``terminal_panes[i]``). Set by the host."""
    var _running: Bool
    var _started: Bool
    var _exited: Bool
    var _exit_code: Int
    """The run's state as of the last paint, for ``native_state``."""

    def __init__(out self):
        self.report = TestReport()
        self.selected = -1
        self._picked = False
        self._reveal = False
        self.split_wide = SplitArea(
            DEFAULT_SPLIT, min_first=12, min_second=16,
        )
        self.split_tall = SplitArea(DEFAULT_SPLIT, min_first=2, min_second=3)
        self._list_scroll = 0
        self._list_moved = False
        self._list_bar = ScrollBarArea()
        self._list_rect = Rect.empty()
        self._detail_scroll = 0
        self._detail_bar = ScrollBarArea()
        self._detail_rect = Rect.empty()
        self._rows = List[ResultRow]()
        self._rows_version = -1
        self._rows_width = -1
        self._rows_selected = -1
        self._last_links = List[OutputLink]()
        self._clicked = Optional[OutputLink]()
        self.host_tag = 0
        self._running = False
        self._started = False
        self._exited = False
        self._exit_code = 0

    def _forget_view(mut self):
        self.selected = -1
        self._picked = False
        self._list_scroll = 0
        self._list_moved = False
        self._detail_scroll = 0

    def start(mut self, report_path: String):
        """A new run, reporting into ``report_path`` (empty: not at all)."""
        self.report.reset(report_path)
        self._forget_view()

    def attach(mut self, report_path: String):
        """Follow a run already in progress (a tmux session that outlived
        the app): read its report from the start, keeping the file."""
        self.report.reset(report_path, fresh=False)
        self._forget_view()

    def poll(mut self):
        _ = self.report.poll()

    def discard(mut self):
        self.report.discard()

    def set_splits(mut self, wide: Int, tall: Int):
        """Put the dividers where the host remembers them (thousandths),
        unless one is being dragged."""
        if not self.split_wide.dragging:
            self.split_wide.fraction = wide
        if not self.split_tall.dragging:
            self.split_tall.fraction = tall

    def take_split_change(mut self) -> Bool:
        """True once after the user moved a divider."""
        var a = self.split_wide.take_changed()
        var b = self.split_tall.take_changed()
        return a or b

    def pointer_shape(self, pos: Point) -> String:
        """The resize cursor over a divider (``pos`` in grid cells from
        the grid's corner); empty elsewhere."""
        var s = self.split_wide.pointer_shape(pos)
        if len(s.as_bytes()) > 0:
            return s
        return self.split_tall.pointer_shape(pos)

    def hide(mut self):
        """The view isn't on screen this frame."""
        self.split_wide.hide()
        self.split_tall.hide()
        self._list_bar.hide()
        self._detail_bar.hide()
        self._list_rect = Rect.empty()
        self._detail_rect = Rect.empty()
        self._last_links = List[OutputLink]()

    def take_link(mut self) -> Optional[OutputLink]:
        """The link clicked (or opened with Enter) since the last call."""
        var l = self._clicked
        self._clicked = Optional[OutputLink]()
        return l

    def title_suffix(self) -> String:
        """`` · 45/120 · 3 failed`` for the pane's title; empty while the
        runner hasn't reported."""
        ref r = self.report
        if not r.reporting():
            return String("")
        var s = String(" · ") + String(r.done())
        if r.total >= 0:
            s = s + String("/") + String(r.total)
        var f = r.failed()
        if f > 0:
            s = s + String(" · ") + String(f) + String(" failed")
        return s

    # --- selection ------------------------------------------------------

    def select(mut self, index: Int):
        """Show test ``index`` (clamped) — the user's pick from now on."""
        var n = len(self.report.tests)
        if n == 0:
            return
        var i = max(0, min(index, n - 1))
        if i != self.selected:
            self._detail_scroll = 0
        self.selected = i
        self._picked = True
        self._reveal = True

    def _follow_first_failure(mut self):
        if self._picked:
            return
        ref tests = self.report.tests
        for i in range(len(tests)):
            if tests[i].outcome == OUTCOME_FAILED \
                    or tests[i].outcome == OUTCOME_ERROR:
                if self.selected != i:
                    self.selected = i
                    self._detail_scroll = 0
                    self._reveal = True
                return

    # --- paint ----------------------------------------------------------

    def paint(
        mut self, mut grid: Canvas, origin: Point, running: Bool,
        started: Bool, exited: Bool, exit_code: Int,
    ):
        var w = grid.width
        var h = grid.height
        self._last_links = List[OutputLink]()
        self._running = running
        self._started = started
        self._exited = exited
        self._exit_code = exit_code
        if grid.host_widgets:
            self._paint_for_host(grid)
            return
        self._paint_progress(grid, w, running, started)
        if h >= 2:
            var status = self._status_line(running, exited, exit_code)
            _ = grid.put_text(Point(1, 1), status[0], status[1], max_x=w)
        var top = 2 if h > 2 else h
        if h - top <= 0 or w < 4:
            self.hide()
            return
        self._follow_first_failure()
        var body = Rect(0, top, w, h)
        var halves: Tuple[Rect, Rect]
        if is_landscape(w, h - top):
            self.split_tall.hide()
            halves = self.split_wide.layout(body, True)
            self.split_wide.paint(grid)
        else:
            self.split_wide.hide()
            halves = self.split_tall.layout(body, False)
            self.split_tall.paint(grid)
        self._list_rect = halves[0]
        self._detail_rect = halves[1]
        self._paint_list(grid)
        if self._detail_rect.is_empty():
            self._detail_bar.hide()
        else:
            self._paint_detail(grid, origin)

    def _paint_for_host(mut self, mut grid: Canvas):
        """The native looks: the same layout, the regions as host items
        over blank cells (the grid comes cleared), the divider the split's
        own item."""
        var w = grid.width
        var h = grid.height
        self._list_bar.hide()
        self._detail_bar.hide()
        self._follow_first_failure()
        var top = min(2, h)
        self._host_region(grid, HOST_TEST_HEADER, Rect(0, 0, w, top))
        if h - top <= 0 or w < 4:
            self.split_wide.hide()
            self.split_tall.hide()
            self._list_rect = Rect.empty()
            self._detail_rect = Rect.empty()
            return
        var body = Rect(0, top, w, h)
        var halves: Tuple[Rect, Rect]
        if is_landscape(w, h - top):
            self.split_tall.hide()
            halves = self.split_wide.layout(body, True)
            self.split_wide.paint(grid)
        else:
            self.split_wide.hide()
            halves = self.split_tall.layout(body, False)
            self.split_tall.paint(grid)
        self._list_rect = halves[0]
        self._detail_rect = halves[1]
        self._host_region(grid, HOST_TEST_LIST, halves[0])
        if not halves[1].is_empty():
            self._host_region(grid, HOST_TEST_DETAIL, halves[1])

    def _host_region(self, mut grid: Canvas, kind: UInt8, r: Rect):
        grid.add_host_item(HostItem(
            kind, (r.a.x - grid.origin.x) * SCALE_ONE,
            (r.a.y - grid.origin.y) * SCALE_ONE,
            r.width() * SCALE_ONE, r.height() * SCALE_ONE, False, False,
            0, 0, Attr(WHITE, PANE_BG), self.host_tag,
        ))

    # --- the host's side (native looks) ---------------------------------

    def native_state(self, generation: Int, version: Int) -> JsonValue:
        """What the native header and list show: ``{generation, version,
        count, rows: [[index, outcome, id]], selected, picked, reporting,
        total, done, failed, counts, status, tone, waiting}``. ``rows`` are
        the tests changed since ``version`` of run ``generation`` — all of
        them when the host has another run's. ``outcome`` is an
        ``OUTCOME_*`` (6 running); ``tone`` 0 neutral, 1 good, 2 bad."""
        ref r = self.report
        var o = json_object()
        o.put(String("generation"), json_int(r.generation))
        o.put(String("version"), json_int(r.version))
        o.put(String("count"), json_int(len(r.tests)))
        var all = generation != r.generation
        var rows = json_array()
        for i in range(len(r.tests)):
            ref t = r.tests[i]
            if not all and t.stamp <= version:
                continue
            var row = json_array()
            row.append(json_int(i))
            row.append(json_int(Int(t.outcome)))
            row.append(json_str(t.id))
            rows.append(row)
        o.put(String("rows"), rows)
        o.put(String("selected"), json_int(self.selected))
        o.put(String("picked"), json_bool(self._picked))
        o.put(String("reporting"), json_bool(r.reporting()))
        o.put(String("total"), json_int(r.total))
        o.put(String("done"), json_int(r.done()))
        o.put(String("failed"), json_int(r.failed()))
        var counts = json_array()
        for i in range(len(r.counts)):
            counts.append(json_int(r.counts[i]))
        o.put(String("counts"), counts)
        var st = self._status_line(self._running, self._exited, self._exit_code)
        o.put(String("status"), json_str(st[0]))
        var tone = 0
        if st[1].fg == LIGHT_GREEN:
            tone = 1
        elif st[1].fg == LIGHT_RED:
            tone = 2
        o.put(String("tone"), json_int(tone))
        o.put(String("waiting"), json_str(
            String("") if r.reporting()
            else _waiting_message(self._running, self._started)
        ))
        return o^

    def native_detail(self) -> JsonValue:
        """The selected test for the native detail: ``{index, outcome, id,
        file, line, state, text, links: [[line, start, end, path, n,
        url]]}`` — ``text`` the message and output (escape sequences
        removed), ``links`` the spans in it to make clickable (0-based
        line, codepoint columns, the target's 1-based line ``n``).
        ``index`` -1 when nothing is selected."""
        var o = json_object()
        ref tests = self.report.tests
        if self.selected < 0 or self.selected >= len(tests):
            o.put(String("index"), json_int(-1))
            o.put(String("hint"), json_str(
                String("Select a test to see its output.") if len(tests) > 0
                else String("")
            ))
            return o^
        ref t = tests[self.selected]
        o.put(String("index"), json_int(self.selected))
        o.put(String("outcome"), json_int(Int(t.outcome)))
        o.put(String("id"), json_str(t.id))
        o.put(String("file"), json_str(t.file))
        o.put(String("line"), json_int(t.line))
        var state = outcome_name(t.outcome)
        if t.outcome != OUTCOME_RUNNING:
            state = state + String(" in ") + _duration(t.duration_ms)
        o.put(String("state"), json_str(state))
        var text = clean_output(t.message)
        var out = clean_output(t.output)
        if len(out.as_bytes()) > 0:
            if len(text.as_bytes()) > 0:
                text = text + String("\n\n")
            text = text + out
        o.put(String("text"), json_str(text))
        var links = json_array()
        var lines = text.split("\n")
        for k in range(len(lines)):
            var hits = extract_all_links(String(lines[k]))
            for j in range(len(hits)):
                var l = json_array()
                l.append(json_int(k))
                l.append(json_int(hits[j].cell_start))
                l.append(json_int(hits[j].cell_end))
                l.append(json_str(hits[j].path))
                l.append(json_int(hits[j].line))
                l.append(json_bool(hits[j].is_url))
                links.append(l)
        o.put(String("links"), links)
        return o^

    def native_act(mut self, op: Int, index: Int, text: String):
        """A native view's action: ``op`` 0 select test ``index``, 1 open
        test ``index``, 2 open file ``text`` at line ``index``, 3 open URL
        ``text``. An open waits in ``take_link``."""
        if op == 0:
            self.select(index)
        elif op == 1:
            if index >= 0 and index < len(self.report.tests):
                ref t = self.report.tests[index]
                if len(t.file.as_bytes()) > 0:
                    self._clicked = Optional[OutputLink](OutputLink(
                        0, 0, 0, t.file, max(t.line, 1), False,
                    ))
        elif op == 2 and len(text.as_bytes()) > 0:
            self._clicked = Optional[OutputLink](OutputLink(
                0, 0, 0, text, max(index, 1), False,
            ))
        elif op == 3 and len(text.as_bytes()) > 0:
            self._clicked = Optional[OutputLink](OutputLink(
                0, 0, 0, text, 0, True,
            ))

    def _paint_list(mut self, mut grid: Canvas):
        var area = self._list_rect
        var rows = area.height()
        ref tests = self.report.tests
        var n = len(tests)
        if self._reveal and self.selected >= 0:
            if self.selected < self._list_scroll:
                self._list_scroll = self.selected
            elif self.selected >= self._list_scroll + rows:
                self._list_scroll = self.selected - rows + 1
            self._reveal = False
        elif self.selected < 0 and not self._list_moved:
            self._list_scroll = n - rows
        self._list_scroll = max(0, min(self._list_scroll, n - rows))
        var right = area.b.x - grid.scroll_bar_cells  # the scroll bar's
        for i in range(rows):
            var ti = self._list_scroll + i
            if ti >= n:
                break
            var y = area.a.y + i
            var icon = outcome_icon(tests[ti].outcome)
            var sel = ti == self.selected
            var text_attr = Attr(BLACK, LIGHT_GRAY) if sel \
                else Attr(WHITE, PANE_BG)
            if sel:
                for x in range(area.a.x, right):
                    grid.set(x, y, Cell(String(" "), text_attr))
            var icon_attr = Attr(icon[1], LIGHT_GRAY if sel else PANE_BG)
            if sel and icon[1] == LIGHT_GRAY:
                icon_attr = Attr(BLACK, LIGHT_GRAY)
            _ = grid.put_text(Point(area.a.x + 1, y), icon[0], icon_attr, max_x=right)
            _ = grid.put_text(
                Point(area.a.x + 3, y), tests[ti].id, text_attr, max_x=right,
            )
        self._list_bar.paint(
            grid, area, n, self._list_scroll, Attr(PANE_FG, PANE_BG),
        )

    def _paint_detail(mut self, mut grid: Canvas, origin: Point):
        var area = self._detail_rect
        var rows = area.height()
        var x0 = area.a.x + 1
        var right = area.b.x - grid.scroll_bar_cells
        self._layout_detail(right - x0)
        var total = len(self._rows)
        self._detail_scroll = max(0, min(self._detail_scroll, total - rows))
        var link_attr = Attr(LIGHT_BLUE, PANE_BG, STYLE_UNDERLINE)
        for i in range(rows):
            var ri = self._detail_scroll + i
            if ri >= total:
                break
            ref row = self._rows[ri]
            var y = area.a.y + i
            var adv = grid.put_text(Point(x0, y), row.text, row.attr, max_x=right)
            if len(row.path.as_bytes()) > 0:
                self._last_links.append(OutputLink(
                    origin.y + y, origin.x + x0, origin.x + x0 + adv,
                    row.path, max(row.line, 1), False,
                ))
                continue
            var hits = extract_all_links(row.text)
            for k in range(len(hits)):
                var hit = hits[k]
                var a = x0 + max(hit.cell_start, 0)
                var b = min(x0 + hit.cell_end, right)
                if b <= a:
                    continue
                for x in range(a, b):
                    grid.set_attr(x, y, link_attr)
                self._last_links.append(OutputLink(
                    origin.y + y, origin.x + a, origin.x + b,
                    hit.path, hit.line, hit.is_url,
                ))
        self._detail_bar.paint(
            grid, area, total, self._detail_scroll, Attr(PANE_FG, PANE_BG),
        )

    def _layout_detail(mut self, width: Int):
        """Lay the selected test out as detail rows ``width`` columns
        wide, unless nothing changed since the last layout."""
        if self._rows_version == self.report.version \
                and self._rows_width == width \
                and self._rows_selected == self.selected:
            return
        self._rows_version = self.report.version
        self._rows_width = width
        self._rows_selected = self.selected
        self._rows = List[ResultRow]()
        if width <= 2:
            return
        var dim = Attr(LIGHT_GRAY, PANE_BG)
        if self.selected < 0 or self.selected >= len(self.report.tests):
            if len(self.report.tests) > 0:
                self._rows.append(ResultRow(
                    String("Select a test to see its output."), dim,
                    String(""), 0,
                ))
            return
        ref t = self.report.tests[self.selected]
        var icon = outcome_icon(t.outcome)
        self._rows.append(ResultRow(
            icon[0] + String(" ") + t.id, Attr(icon[1], PANE_BG, STYLE_BOLD),
            t.file, t.line,
        ))
        var state = outcome_name(t.outcome)
        if t.outcome != OUTCOME_RUNNING:
            state = state + String(" in ") + _duration(t.duration_ms)
        self._rows.append(ResultRow(String("  ") + state, dim, String(""), 0))
        if len(t.message.as_bytes()) > 0:
            self._rows.append(ResultRow(String(""), dim, String(""), 0))
            _append_wrapped(
                self._rows, t.message, String(""), width, Attr(WHITE, PANE_BG),
            )
        if len(t.output.as_bytes()) > 0:
            self._rows.append(ResultRow(String(""), dim, String(""), 0))
            _append_wrapped(self._rows, t.output, String(""), width, dim)

    def _paint_progress(
        self, mut grid: Canvas, w: Int, running: Bool, started: Bool,
    ):
        """Row 0: ``45/120 [█████░░░░] ✓ 40  ✗ 3  ↷ 2``."""
        ref r = self.report
        if not r.reporting():
            var msg = _waiting_message(running, started)
            _ = grid.put_text(Point(1, 0), msg, Attr(LIGHT_GRAY, PANE_BG), max_x=w)
            return
        var segs = List[Tuple[String, Attr]]()
        _count_seg(segs, OUTCOME_PASSED, r.count(OUTCOME_PASSED))
        _count_seg(segs, OUTCOME_FAILED, r.count(OUTCOME_FAILED))
        _count_seg(segs, OUTCOME_ERROR, r.count(OUTCOME_ERROR))
        _count_seg(segs, OUTCOME_SKIPPED, r.count(OUTCOME_SKIPPED))
        _count_seg(segs, OUTCOME_XFAILED, r.count(OUTCOME_XFAILED))
        _count_seg(segs, OUTCOME_XPASSED, r.count(OUTCOME_XPASSED))
        var right_w = 0
        for i in range(len(segs)):
            right_w += display_columns(segs[i][0]) + 2
        var done = r.done()
        var left = String(" ") + String(done)
        if r.total >= 0:
            left = left + String("/") + String(r.total)
        left = left + String(" ")
        var x = grid.put_text(Point(0, 0), left, Attr(WHITE, PANE_BG, STYLE_BOLD), max_x=w)
        var bar_w = w - x - right_w - 1
        if r.total > 0 and bar_w >= 4:
            var fill = min(done, r.total) * bar_w // r.total
            var fg = LIGHT_RED if r.failed() > 0 else LIGHT_GREEN
            for i in range(bar_w):
                if i < fill:
                    grid.set(x + i, 0, Cell(String("█"), Attr(fg, PANE_BG)))
                else:
                    grid.set(x + i, 0, Cell(String("░"), Attr(DARK_GRAY, PANE_BG)))
            x += bar_w + 1
        for i in range(len(segs)):
            x += grid.put_text(Point(x, 0), segs[i][0], segs[i][1], max_x=w)
            x += 2

    def _status_line(
        self, running: Bool, exited: Bool, exit_code: Int,
    ) -> Tuple[String, Attr]:
        """Row 1: the test in progress, or how the run ended."""
        ref r = self.report
        if running:
            if len(r.current.as_bytes()) > 0:
                return (String("▸ ") + r.current, Attr(LIGHT_GRAY, PANE_BG))
            if r.reporting():
                return (String("Running…"), Attr(LIGHT_GRAY, PANE_BG))
            return (String(""), Attr(LIGHT_GRAY, PANE_BG))
        if not exited or not r.reporting():
            return (String(""), Attr(LIGHT_GRAY, PANE_BG))
        if r.failed() == 0 and exit_code == 0:
            return (
                String("All ") + String(r.done()) + String(" tests passed"),
                Attr(LIGHT_GREEN, PANE_BG),
            )
        if r.failed() == 0:
            return (
                String("Exited with ") + String(exit_code),
                Attr(LIGHT_RED, PANE_BG),
            )
        return (
            String(r.failed()) + String(" of ") + String(r.done())
                + String(" tests failed"),
            Attr(LIGHT_RED, PANE_BG),
        )

    # --- input ----------------------------------------------------------

    def handle_mouse(
        mut self, event: Event, origin: Point, inside: Bool,
    ) -> Bool:
        """The scroll bars, the wheel, picking a test in the list, and
        clicks on the detail's links. ``event`` is in grid cells
        (``GridSelection.grid_event``), ``origin`` the grid's corner in
        them; ``inside`` whether the event is over the pane. False for a
        press outside it, which takes focus away. A clicked link waits in
        ``take_link``."""
        var local = event
        local.pos = Point(event.pos.x - origin.x, event.pos.y - origin.y)
        if self.split_wide.handle_mouse(local) \
                or self.split_tall.handle_mouse(local):
            return True
        var s = self._list_bar.handle_mouse(local)
        if s >= 0:
            self._list_scroll = s
            self._list_moved = True
            return True
        s = self._detail_bar.handle_mouse(local)
        if s >= 0:
            self._detail_scroll = s
            return True
        if not inside:
            return False
        var in_list = self._list_rect.contains(local.pos)
        if event.button == MOUSE_WHEEL_UP or event.button == MOUSE_WHEEL_DOWN:
            if event.pressed:
                var d = -3 if event.button == MOUSE_WHEEL_UP else 3
                if in_list:
                    self._list_scroll = max(0, self._list_scroll + d)
                    self._list_moved = True
                else:
                    self.scroll_by(d)
            return True
        if event.button == MOUSE_BUTTON_LEFT and event.pressed \
                and not event.motion:
            if in_list:
                var row = self._list_scroll + local.pos.y - self._list_rect.a.y
                if row < len(self.report.tests):
                    self.select(row)
                return True
            var li = link_at(self._last_links, event.pos)
            if li >= 0:
                self._clicked = Optional[OutputLink](self._last_links[li])
        return True

    def scroll_by(mut self, delta: Int):
        """Scroll the detail."""
        self._detail_scroll = max(0, self._detail_scroll + delta)

    def handle_key(mut self, event: Event) -> Bool:
        """Up / Down pick the previous / next test, Home / End the first /
        last, Page Up / Down scroll the detail, Enter opens the selected
        test. False for the rest, which go to the child as usual."""
        if event.kind != EVENT_KEY or event.mods != MOD_NONE:
            return False
        var page = max(self._detail_rect.height() - 1, 1)
        if event.key == KEY_UP:
            self.select(self.selected - 1 if self.selected > 0 else 0)
            return True
        if event.key == KEY_DOWN:
            self.select(self.selected + 1)
            return True
        if event.key == KEY_HOME:
            self.select(0)
            return True
        if event.key == KEY_END:
            self.select(len(self.report.tests) - 1)
            return True
        if event.key == KEY_PAGEUP:
            self.scroll_by(-page)
            return True
        if event.key == KEY_PAGEDOWN:
            self.scroll_by(page)
            return True
        if event.key == KEY_ENTER:
            if self.selected >= 0 and self.selected < len(self.report.tests):
                ref t = self.report.tests[self.selected]
                if len(t.file.as_bytes()) > 0:
                    self._clicked = Optional[OutputLink](OutputLink(
                        0, 0, 0, t.file, max(t.line, 1), False,
                    ))
                return True
            return False
        return False


def _waiting_message(running: Bool, started: Bool) -> String:
    """What the progress row says while the runner hasn't reported."""
    if running:
        return String("Waiting for test results…")
    if started:
        return String(
            "This runner didn't report results — [▤ Output] has its output."
        )
    return String("No test run yet.")


def _duration(ms: Int) -> String:
    if ms < 1000:
        return String(ms) + String(" ms")
    var tenths = ms // 100
    return String(tenths // 10) + String(".") + String(tenths % 10) + String(" s")


@fieldwise_init
struct ResultRow(Copyable, Movable):
    """One row of the detail. A row with a ``path`` is the test's header
    and opens it at ``line``; the others are scanned for links."""
    var text: String
    var attr: Attr
    var path: String
    var line: Int


def _count_seg(mut segs: List[Tuple[String, Attr]], outcome: UInt8, n: Int):
    if n > 0:
        var icon = outcome_icon(outcome)
        segs.append((icon[0] + String(" ") + String(n), Attr(icon[1], PANE_BG)))


def _utf8_step(lead: UInt8) -> Int:
    if lead < 0x80:
        return 1
    if lead < 0xE0:
        return 2
    if lead < 0xF0:
        return 3
    return 4


def _decode_at(b: Span[UInt8, _], i: Int, step: Int) -> Int:
    if step == 1 or i + step > len(b):
        return Int(b[i])
    var cp = Int(b[i]) & (0xFF >> (step + 1))
    for k in range(1, step):
        cp = (cp << 6) | (Int(b[i + k]) & 0x3F)
    return cp


def clean_output(text: String) -> String:
    """``text`` as plain lines for the results list: ANSI escape sequences
    and carriage returns removed, tabs as four spaces."""
    var b = text.as_bytes()
    var out = List[UInt8]()
    var i = 0
    while i < len(b):
        var c = b[i]
        if c == 0x1B:
            # CSI: ESC [ params… final (0x40..0x7E); anything else: ESC x.
            if i + 1 < len(b) and b[i + 1] == 0x5B:
                i += 2
                while i < len(b) and (b[i] < 0x40 or b[i] > 0x7E):
                    i += 1
                i += 1
            else:
                i += 2
            continue
        if c == 0x0D:
            i += 1
            continue
        if c == 0x09:
            for _ in range(4):
                out.append(0x20)
            i += 1
            continue
        out.append(c)
        i += 1
    return String(StringSpan(unsafe_from_utf8=Span(out)))


def wrap_cells(line: String, width: Int) -> List[String]:
    """``line`` cut into pieces at most ``width`` cells wide (at least one
    piece, empty for an empty line). Never splits a codepoint."""
    var out = List[String]()
    var b = line.as_bytes()
    if width <= 0 or len(b) == 0:
        out.append(String(""))
        return out^
    var start = 0
    var cells = 0
    var i = 0
    while i < len(b):
        var step = _utf8_step(b[i])
        if i + step > len(b):
            step = len(b) - i
        var cw = char_width(_decode_at(b, i, step))
        if cells + cw > width and i > start:
            out.append(String(StringSpan(unsafe_from_utf8=b[start:i])))
            start = i
            cells = 0
        cells += cw
        i += step
    out.append(String(StringSpan(unsafe_from_utf8=b[start:len(b)])))
    return out^


def _append_wrapped(
    mut rows: List[ResultRow], text: String, indent: String, width: Int,
    attr: Attr,
):
    """Each line of ``text`` (cleaned), indented and wrapped to ``width``."""
    var avail = width - display_columns(indent)
    if avail < 1:
        avail = 1
    var clean = clean_output(text)
    # Drop trailing blank lines: the list puts its own gap after a failure.
    var lines = clean.split("\n")
    var n = len(lines)
    while n > 0 and len(String(lines[n - 1]).strip().as_bytes()) == 0:
        n -= 1
    for k in range(n):
        var pieces = wrap_cells(String(lines[k]), avail)
        for p in range(len(pieces)):
            rows.append(ResultRow(
                indent + pieces[p], attr, String(""), 0,
            ))

