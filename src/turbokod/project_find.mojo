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
from std.collections.optional import Optional

from .buttons import (
    BUTTON_FIRED, OptionToggle, paint_option_toggle,
)
from .canvas import Canvas
from .painter import Painter
from .cell import Cell
from .colors import (
    Attr, BLACK, BLUE, CYAN, LIGHT_GRAY, RED, WHITE, YELLOW,
)
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_ENTER, KEY_ESC,
    MOUSE_BUTTON_LEFT,
)
from .file_io import read_file, stat_file
from .geometry import Point, Rect
from .highlight import (
    GrammarRegistry, Highlight, HighlightCache,
    extension_of, highlight_for_extension, highlight_for_extension_cached,
)
from .lsp import CaptureResult, LspProcess, capture_command
from .picker_input import picker_nav_key, picker_wheel_scroll
from .posix import alloc_zero_buffer, poll_stdin, read_into
from .project import ProjectMatch
from .search_options import SearchOptions
from .string_utils import display_columns, split_lines
from .text_field import TextField
from .window import paint_window_title


comptime _DEBOUNCE_MS: Int = 200
comptime _CONTEXT_LINES: Int = 5     # lines on each side of the match
# Hard caps on per-line work. Minified JS / CSS bundles routinely have a
# single multi-MB line — without these the TextMate tokenizer would burn
# whole seconds on it per paint frame, pegging the UI thread at 100% CPU
# while ESC and keystrokes wait their turn behind paint.
comptime _MATCH_TEXT_CAP: Int = 1024     # truncate rg's matched-line text
comptime _ROW_HIGHLIGHT_CAP: Int = 2048  # skip syntax overlay above this
comptime _CTX_LINE_CAP: Int = 4096       # skip context tokenize above this
comptime _CTX_FILE_CAP: Int = 4 * 1024 * 1024   # 4 MB total ctx file
# Hard cap on the result list. A query like ``a`` over a large tree can
# yield hundreds of thousands of hits; carrying them all is pointless
# (no user pages past a few hundred) and the per-row paint cost adds up.
# We accept one extra match as the "there's more" sentinel — when the
# (cap + 1)th lands we drop it, mark the result truncated, and kill rg.
comptime _MAX_MATCHES: Int = 1000


struct ProjectFind(Movable):
    var active: Bool
    var submitted: Bool
    var root: String
    var query: TextField
    # Cached input strip rect for mouse routing.
    var _input_rect: Rect
    var _last_searched_query: String   # what we last ran a search for
    var _last_searched_opts: SearchOptions   # toggle state at last search
    var _query_dirty_at_ms: Int        # 0 when no debounce pending
    var matches: List[ProjectMatch]
    var selected: Int
    var scroll: Int
    # Output, set when the user hits Enter.
    var selected_path: String
    var selected_line: Int
    # Search-mode toggles. Mirror the Find prompt's ``Cc`` / ``W`` /
    # ``.*`` chips so the project-wide flow honors the same flags.
    # State persists across opens; flipping a toggle while the dialog
    # is open kicks off a new debounced search.
    var toggle_case: OptionToggle
    var toggle_word: OptionToggle
    var toggle_regex: OptionToggle
    # Context cache: lines of the file containing ``matches[selected]``.
    # We reload only when the path changes — typical up/down navigation
    # stays in one file. ``_context_highlights`` is the syntax-highlight
    # overlay computed once per file load.
    var _context_path: String
    var _context_lines: List[String]
    var _context_highlights: List[Highlight]
    # Streaming ripgrep runner. Holds the spawned child for the in-flight
    # search (if any); a fresh keystroke after the debounce kills the old
    # one and starts a new one, so a query that turns out to be too broad
    # never blocks the UI thread. ``close()`` also cancels.
    var _runner: _RgRunner
    # True when the in-flight (or just-completed) search hit ``_MAX_MATCHES``
    # and we had to drop trailing hits. The paint pass overlays a notice
    # on the bottom border so the user knows their result list isn't the
    # whole picture.
    var _truncated: Bool

    def __init__(out self):
        self.active = False
        self.submitted = False
        self.root = String("")
        self.query = TextField()
        self._input_rect = Rect(0, 0, 0, 0)
        self._last_searched_query = String("")
        self._last_searched_opts = SearchOptions()
        self._query_dirty_at_ms = 0
        self.matches = List[ProjectMatch]()
        self.selected = 0
        self.scroll = 0
        self.selected_path = String("")
        self.selected_line = 0
        self.toggle_case = OptionToggle(
            String("Cc"), String("Match case"),
        )
        self.toggle_word = OptionToggle(
            String("W"), String("Whole word"),
        )
        self.toggle_regex = OptionToggle(
            String(".*"), String("Regular expression"),
        )
        self._context_path = String("")
        self._context_lines = List[String]()
        self._context_highlights = List[Highlight]()
        self._runner = _RgRunner()
        self._truncated = False

    def open(
        mut self,
        var root: String,
        var prefill: String = String(""),
        select_prefill: Bool = False,
    ):
        """Open the Find-in-Project dialog.

        ``prefill`` seeds the query field. With ``select_prefill=True``
        the seeded text is left fully selected so the next typed key
        replaces it — mirrors the basic Find prompt and lets the user
        either keep the seeded term (Enter) or overwrite it (type).

        A non-empty prefill also kicks off a search on the next tick
        so results appear immediately without a keystroke.
        """
        self._runner.cancel()
        self.root = root^
        self.query = TextField()
        var has_prefill = len(prefill.as_bytes()) > 0
        if has_prefill:
            self.query.set_text(prefill^)
            if select_prefill:
                self.query.select_all()
        self._input_rect = Rect(0, 0, 0, 0)
        self._last_searched_query = String("")
        self._last_searched_opts = SearchOptions()
        # ``1`` is the "fire on next tick" sentinel (see _mark_toggle_changed).
        self._query_dirty_at_ms = 1 if has_prefill else 0
        self.matches = List[ProjectMatch]()
        self.selected = 0
        self.scroll = 0
        self.selected_path = String("")
        self.selected_line = 0
        # Toggle state persists across opens — leave ``toggle_*.on``
        # untouched so the user keeps the flags they had on for the
        # previous Find-in-Project. Hover state is a paint-frame
        # artifact, drop it to avoid stale tooltips.
        self.toggle_case.hovered = False
        self.toggle_word.hovered = False
        self.toggle_regex.hovered = False
        self._context_path = String("")
        self._context_lines = List[String]()
        self._context_highlights = List[Highlight]()
        self._truncated = False
        self.active = True
        self.submitted = False

    def close(mut self):
        self._runner.cancel()
        self.active = False
        self.submitted = False
        self.root = String("")
        self.query = TextField()
        self._input_rect = Rect(0, 0, 0, 0)
        self._last_searched_query = String("")
        self._last_searched_opts = SearchOptions()
        self._query_dirty_at_ms = 0
        self.matches = List[ProjectMatch]()
        self.selected = 0
        self.scroll = 0
        self.selected_path = String("")
        self.selected_line = 0
        self.toggle_case.hovered = False
        self.toggle_word.hovered = False
        self.toggle_regex.hovered = False
        self._context_path = String("")
        self._context_lines = List[String]()
        self._context_highlights = List[Highlight]()
        self._truncated = False

    def _current_options(self) -> SearchOptions:
        return SearchOptions(
            self.toggle_case.on, self.toggle_word.on, self.toggle_regex.on,
        )

    # --- per-frame tick ---------------------------------------------------

    def tick(mut self, now_ms: Int):
        """Run the pending search if the debounce window has elapsed,
        and pump any in-flight streaming runner.

        ``now_ms`` is a monotonic wall-clock reading; the host pulls it
        from ``posix.monotonic_ms()`` once per frame. ``_query_dirty_at_ms``
        carries the timestamp of the most recent keystroke, with ``0``
        meaning "nothing pending".
        """
        if not self.active:
            return
        # Debounce expiry: kick off (or restart) the search.
        if self._query_dirty_at_ms != 0 \
                and now_ms - self._query_dirty_at_ms >= _DEBOUNCE_MS:
            self._query_dirty_at_ms = 0
            self._run_search()
        # Pump the streaming runner each frame so partial results stream
        # into ``self.matches`` as ``rg`` writes them.
        if self._runner.is_active():
            var changed = self._runner.tick()
            if changed:
                # Append any newly-parsed matches into the public list.
                # The runner only ever appends, so this is just a tail
                # copy from runner.drain_new() to keep the snapshot in
                # sync without disturbing ``selected`` / ``scroll``.
                var fresh = self._runner.drain_new()
                if len(fresh) > 0:
                    var was_empty = len(self.matches) == 0
                    for k in range(len(fresh)):
                        self.matches.append(fresh[k])
                    # Hit the cap: the (_MAX_MATCHES + 1)th match (or
                    # later — a single ``tick`` can drain many lines at
                    # once) is the "there's more" sentinel. Drop the
                    # overflow back to _MAX_MATCHES, mark the result
                    # truncated, and cancel rg so we don't keep streaming
                    # hits the user will never see.
                    if len(self.matches) > _MAX_MATCHES:
                        while len(self.matches) > _MAX_MATCHES:
                            _ = self.matches.pop()
                        self._truncated = True
                        self._runner.cancel()
                    if was_empty:
                        # First match just landed: seed the context panel
                        # so the user sees something useful immediately
                        # instead of "(loading <rel>)".
                        self._refresh_context_for_selection()

    def _mark_toggle_changed(mut self):
        """Force the next ``tick`` to re-run the search with the
        current toggle state. Uses the existing debounce path so a
        rapid sequence of toggle clicks coalesces into one rg
        spawn. ``_query_dirty_at_ms = 1`` is a sentinel "fire on the
        next tick" — the host's ``now_ms`` is always >= the debounce
        window from 1, so the search kicks off immediately."""
        # Cancel any in-flight rg the same way ``_mark_query_dirty``
        # does — its results would belong to the previous toggle
        # state and mixing them with the new ones would confuse the
        # match list.
        if self._runner.is_active():
            self._runner.cancel()
            self.matches = List[ProjectMatch]()
            self.selected = 0
            self.scroll = 0
        self._truncated = False
        self._query_dirty_at_ms = 1

    def _mark_query_dirty(mut self, now_ms: Int):
        # Reset the debounce on every keystroke. ``now_ms == 0`` (clock
        # syscall failure) gets clamped to 1 so the "no pending" sentinel
        # stays distinguishable.
        self._query_dirty_at_ms = now_ms if now_ms > 0 else 1
        # Cancel any in-flight search now — the user has typed something
        # new, and the old query's results are stale. Without this, a
        # slow query (e.g. "a" across a huge tree) would keep streaming
        # into ``self.matches`` even after the user typed something more
        # specific, mixing two queries' results until the old one
        # completes.
        if self._runner.is_active():
            self._runner.cancel()
            self.matches = List[ProjectMatch]()
            self.selected = 0
            self.scroll = 0
            self._truncated = False

    def _run_search(mut self):
        self._last_searched_query = self.query.text
        var opts = self._current_options()
        self._last_searched_opts = opts
        self.matches = List[ProjectMatch]()
        self.selected = 0
        self.scroll = 0
        self._truncated = False
        # Cancel any previous in-flight rg before spawning a new one.
        self._runner.cancel()
        if len(self.query.text.as_bytes()) == 0:
            return
        # Streaming ripgrep: spawns a child that writes match lines to
        # stdout as they're found. ``ProjectFind.tick`` drains those
        # incrementally so the UI thread never blocks on a slow query.
        # Callers gate ``open()`` on ``rg`` being on PATH, so a spawn
        # failure here is a transient OS error — leave matches empty
        # and let the user retry.
        _ = self._runner.start(self.root, self.query.text, opts)

    def _refresh_context_for_selection(mut self):
        """Reload + retokenize the context panel for the current
        selection. The retokenize defers to ``paint`` (which has the
        shared ``GrammarRegistry``) by leaving ``_context_highlights``
        empty here; the panel falls back to plain text until the next
        paint frame fills it in via ``_ensure_context_highlights``."""
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
        # Skip oversized files entirely: a multi-MB minified bundle
        # would still be readable but the next-frame tokenize step
        # would burn seconds on it. The ±5-line context view isn't
        # the right surface for those anyway — the user can hit Enter
        # to open the file in a real editor window.
        var info = stat_file(path)
        if info.ok and Int(info.size) > _CTX_FILE_CAP:
            return
        var text: String
        try:
            text = read_file(path)
        except:
            return
        self._context_lines = split_lines(text)
        # Highlights are filled in lazily during paint via
        # ``_ensure_context_highlights`` — that's where the cached
        # ``GrammarRegistry`` is in scope.

    def _ensure_context_highlights(
        mut self, mut registry: GrammarRegistry,
    ):
        """Tokenize the loaded context file once, using the shared
        registry. No-op when the file is empty or already tokenized.

        Skips the tokenizer when any line is over ``_CTX_LINE_CAP``:
        that's the minified-bundle signature (one giant line), and
        running the TextMate grammar over it is what was hanging the
        UI thread on Cmd+F-into-minified-JS. The context panel still
        renders as plain text, just without syntax color."""
        if len(self._context_lines) == 0:
            return
        if len(self._context_highlights) > 0:
            return
        for i in range(len(self._context_lines)):
            if len(self._context_lines[i].as_bytes()) > _CTX_LINE_CAP:
                return
        var ctx_cache = HighlightCache()
        self._context_highlights = highlight_for_extension_cached(
            extension_of(self._context_path),
            self._context_lines,
            registry, ctx_cache,
        )

    # --- geometry ---------------------------------------------------------

    def _input_y(self, screen: Rect) -> Int:
        return screen.a.y + 1

    def _list_top(self, screen: Rect) -> Int:
        return screen.a.y + 3

    def _context_height(self, screen: Rect) -> Int:
        # 1 separator + ``2 * _CONTEXT_LINES + 1`` content rows.
        return 2 * _CONTEXT_LINES + 2

    def _list_bottom(self, screen: Rect) -> Int:
        return screen.b.y - 1 - self._context_height(screen)

    def _list_height(self, screen: Rect) -> Int:
        var h = self._list_bottom(screen) - self._list_top(screen)
        if h < 0:
            return 0
        return h

    def is_input_at(self, pos: Point, screen: Rect) -> Bool:
        """True iff ``pos`` lies on the ``Search:`` query row."""
        if not self.active:
            return False
        var y = self._input_y(screen)
        return Rect(screen.a.x + 1, y, screen.b.x - 1, y + 1).contains(pos)

    # --- paint ------------------------------------------------------------

    def paint(mut self, mut canvas: Canvas, screen: Rect,
             mut registry: GrammarRegistry):
        if not self.active:
            return
        var bg          = Attr(YELLOW, BLUE)
        var border      = Attr(WHITE,  BLUE)
        var title_attr  = Attr(WHITE,  BLUE)
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
        # Bind every write to the dialog rect so an over-long match
        # path or context line can't leak onto the modal's border or
        # outside ``screen`` entirely.
        var painter = Painter(screen)
        painter.fill(canvas, screen, String(" "), bg)
        painter.draw_box(canvas, screen, border, True)
        # Title — framework helper enforces title bg = body bg.
        paint_window_title(
            canvas, screen, String(" Find in Project "), title_attr, bg,
        )
        # Input row: ``Search: <query>_   Cc  W  .*``.
        var input_y = self._input_y(screen)
        var label = String(" Search: ")
        _ = painter.put_text(
            canvas, Point(screen.a.x + 1, input_y), label, label_attr,
        )
        var qx = screen.a.x + 1 + display_columns(label)
        # Reserve room on the right edge of the input row for the
        # three search-mode toggles. Lay them out right-aligned with
        # one cell of gap between each chip — same idiom the Find
        # prompt uses so the two surfaces feel related.
        var gap = 1
        var toggles_w = self.toggle_case.width() \
            + gap + self.toggle_word.width() \
            + gap + self.toggle_regex.width()
        var toggles_right = screen.b.x - 1
        var tx = toggles_right - toggles_w
        if tx < qx + 4:
            # Pathologically narrow window — give the input what little
            # room is left and shove the toggles right up against the
            # border.
            tx = qx + 4
        self.toggle_case.move_to(tx, input_y)
        tx += self.toggle_case.width() + gap
        self.toggle_word.move_to(tx, input_y)
        tx += self.toggle_word.width() + gap
        self.toggle_regex.move_to(tx, input_y)
        var qw_max = self.toggle_case.x - 1 - qx
        if qw_max < 0:
            qw_max = 0
        var input_rect = Rect(qx, input_y, qx + qw_max, input_y + 1)
        self._input_rect = input_rect
        self.query.paint(canvas, input_rect, True)
        # Toggle chips. Off uses a darker on-blue paint so an inactive
        # chip blends with the dialog body; on inverts to the standard
        # yellow selection background.
        var toggle_off = Attr(LIGHT_GRAY, BLUE)
        var toggle_on  = Attr(BLACK, YELLOW)
        paint_option_toggle(
            canvas, self.toggle_case, toggle_off, toggle_on, screen.b.x - 1,
        )
        paint_option_toggle(
            canvas, self.toggle_word, toggle_off, toggle_on, screen.b.x - 1,
        )
        paint_option_toggle(
            canvas, self.toggle_regex, toggle_off, toggle_on, screen.b.x - 1,
        )
        # Separator under the input. When a toggle is hovered the
        # separator gives way to the chip's tooltip text so the user
        # learns what each abbreviation means without leaving the
        # search flow.
        var sep1_y = input_y + 1
        var hovered_tooltip = String("")
        if self.toggle_case.hovered:
            hovered_tooltip = self.toggle_case.tooltip
        elif self.toggle_word.hovered:
            hovered_tooltip = self.toggle_word.tooltip
        elif self.toggle_regex.hovered:
            hovered_tooltip = self.toggle_regex.tooltip
        if len(hovered_tooltip.as_bytes()) > 0:
            painter.fill(
                canvas,
                Rect(screen.a.x + 1, sep1_y, screen.b.x - 1, sep1_y + 1),
                String(" "), bg,
            )
            _ = painter.put_text(
                canvas, Point(screen.a.x + 2, sep1_y),
                hovered_tooltip, ctx_attr,
            )
        else:
            for x in range(screen.a.x + 1, screen.b.x - 1):
                painter.set(canvas, x, sep1_y, Cell(String("─"), sep_attr, 1))
        # Match list.
        var top = self._list_top(screen)
        var h = self._list_height(screen)
        if len(self.matches) == 0:
            var msg: String
            if len(self.query.text.as_bytes()) == 0:
                msg = String("Type to search.")
            elif self._query_dirty_at_ms != 0 \
                    or self.query.text != self._last_searched_query \
                    or self._runner.is_active():
                msg = String("Searching...")
            else:
                msg = String("No matches.")
            _ = painter.put_text(
                canvas, Point(screen.a.x + 2, top), msg, ctx_attr,
            )
        for i in range(h):
            var idx = self.scroll + i
            if idx >= len(self.matches):
                break
            # Copy the match out before the call: ``_paint_match_row``
            # takes ``mut self``, so an aliased ``self.matches[idx]``
            # reference would fail Mojo's exclusivity check.
            var m = self.matches[idx]
            self._paint_match_row(
                canvas, screen, painter, top + i, m, idx == self.selected,
                line_attr, sel_line, hl_attr, sel_hl_attr, path_attr, sel_path,
                registry,
            )
        # Separator above the context panel.
        var ctx_top = self._list_bottom(screen)
        for x in range(screen.a.x + 1, screen.b.x - 1):
            painter.set(canvas, x, ctx_top, Cell(String("─"), sep_attr, 1))
        var ctx_label = String(" Context ")
        var lx = screen.a.x + (screen.width() - display_columns(ctx_label)) // 2
        _ = painter.put_text(canvas, Point(lx, ctx_top), ctx_label, title_attr)
        # Context body. Lazy-tokenize the loaded file using the shared
        # registry so the grammar's regexes only get compiled once per
        # session (not per paint frame).
        self._ensure_context_highlights(registry)
        self._paint_context(
            canvas, screen, painter, ctx_top + 1, ctx_attr, ctx_match,
        )
        # Hint at the very bottom (overlays the bottom border).
        var hint = String(" Enter: open  ESC: cancel  Up/Down: navigate ")
        var hx = screen.b.x - display_columns(hint) - 1
        if hx < screen.a.x + 1:
            hx = screen.a.x + 1
        _ = painter.put_text(canvas, Point(hx, screen.b.y - 1), hint, hint_attr)
        # Truncation notice — left-aligned on the bottom border so the
        # user knows the result list is capped and more hits exist
        # outside it. Painted only when we actually had to drop hits
        # (``_truncated``); the cap is large enough that most queries
        # won't trip it.
        if self._truncated:
            var warn = String(" More than ") + String(_MAX_MATCHES) \
                + String(" matches — refine your search ")
            var warn_attr = Attr(WHITE, RED)
            var wx = screen.a.x + 2
            # Clip against the hint so the two strips can't overpaint
            # each other on narrow windows.
            if wx + display_columns(warn) >= hx:
                # No room — drop the leading/trailing spaces and the
                # explanatory tail to fit. Keep enough that "More: N"
                # at least signals what happened.
                warn = String(" >") + String(_MAX_MATCHES) + String(" ")
            if wx + display_columns(warn) < hx:
                _ = painter.put_text(
                    canvas, Point(wx, screen.b.y - 1), warn, warn_attr,
                )

    def _paint_match_row(
        mut self, mut canvas: Canvas, screen: Rect, painter: Painter,
        y: Int, m: ProjectMatch, is_sel: Bool,
        line_attr: Attr, sel_line: Attr,
        hl_attr: Attr, sel_hl_attr: Attr,
        path_attr: Attr, sel_path: Attr,
        mut registry: GrammarRegistry,
    ):
        var row_attr = sel_line if is_sel else line_attr
        var row_path = sel_path if is_sel else path_attr
        var row_hl = sel_hl_attr if is_sel else hl_attr
        var inner_left = screen.a.x + 1
        var inner_right = screen.b.x - 1
        painter.fill(
            canvas, Rect(inner_left, y, inner_right, y + 1),
            String(" "), row_attr,
        )
        # Right-aligned ``rel:line``.
        var path_label = m.rel + String(":") + String(m.line_no)
        var path_len = display_columns(path_label)
        var path_x = inner_right - path_len - 1
        if path_x < inner_left + 1:
            path_x = inner_left + 1
        _ = painter.put_text(
            canvas, Point(path_x, y), path_label, row_path,
        )
        # Line text (left-aligned, clipped before the path label).
        var line_x = inner_left + 1
        var line_max = path_x - 1
        if line_max <= line_x:
            return
        var line_stripped = _lstrip_tabs(m.line_text)
        var bytes = line_stripped.as_bytes()
        var hit = _find_bytes(line_stripped, self.query.text)
        # Slide so the hit (if any) is visible inside the available width.
        var avail = line_max - line_x
        var start = 0
        if hit >= 0 and hit + len(self.query.text.as_bytes()) > avail:
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
            painter.set(canvas, line_x + (i - start), y, Cell(ch, row_attr, 1))
        # Syntax-highlight overlay (attr-only). Skipped on the selected
        # row because the solid yellow selection background clashes with
        # the highlighter's blue-background palette — keeping the
        # selection a clean color block reads better than mixing the two.
        # We tokenize just this one line, so a token that opened on a
        # prior line (e.g. a triple-quoted string) won't be recognized;
        # acceptable for a one-line preview.
        if not is_sel and len(bytes) <= _ROW_HIGHLIGHT_CAP:
            var one_line = List[String]()
            one_line.append(line_stripped)
            # Cached path: the shared ``GrammarRegistry`` keeps compiled
            # grammars across paint frames, so each visible row only
            # pays the regex-compile cost the first time we see a new
            # extension this session — not on every paint. (Going
            # through ``highlight_for_extension`` instead would re-load
            # and re-compile the grammar 30+ times per frame, pegging
            # the UI thread at 100% CPU on any sizable result set.)
            #
            # Long-line guard: tokenizing a 5 KB+ single line with a
            # complex grammar (e.g. TypeScript on minified JS output)
            # walks every regex across the whole string, easily eating
            # 100 ms per row. The plain-text rendering above is
            # already correct without highlights — we just lose color
            # for that row, which is the right tradeoff vs. a hang.
            var row_cache = HighlightCache()
            var hls = highlight_for_extension_cached(
                extension_of(m.path), one_line, registry, row_cache,
            )
            for h in range(len(hls)):
                var hl = hls[h]
                if hl.row != 0:
                    continue
                var hs = hl.col_start
                var he = hl.col_end
                if hs < start: hs = start
                if he > end:   he = end
                for i in range(hs, he):
                    var b = Int(bytes[i])
                    var ch = chr(b) if b < 0x80 else String("?")
                    painter.set(canvas, line_x + (i - start), y, Cell(ch, hl.attr, 1))
        # Highlight overlay for the hit.
        if hit >= 0 and len(self.query.text.as_bytes()) > 0:
            var hl_start = hit
            var hl_end = hit + len(self.query.text.as_bytes())
            if hl_start < start: hl_start = start
            if hl_end > end:     hl_end = end
            for i in range(hl_start, hl_end):
                var b = Int(bytes[i])
                var ch = chr(b) if b < 0x80 else String("?")
                painter.set(canvas, line_x + (i - start), y, Cell(ch, row_hl, 1))
        # Leading "…" hint when the line was sliced from the left.
        if start > 0:
            painter.set(canvas, line_x, y, Cell(String("…"), row_attr, 1))

    def _paint_context(
        self, mut canvas: Canvas, screen: Rect, painter: Painter,
        top_y: Int, ctx_attr: Attr, match_attr: Attr,
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
            _ = painter.put_text(
                canvas, Point(inner_left + 1, top_y),
                String("(loading ") + m.rel + String(")"),
                ctx_attr,
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
            _ = painter.put_text(canvas, Point(x, y), marker, marker_attr)
            x += display_columns(marker)
            _ = painter.put_text(canvas, Point(x, y), lineno, ctx_attr)
            x += display_columns(lineno)
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
                painter.set(canvas, x + i, y, Cell(ch, ctx_attr, 1))
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
                    painter.set(canvas, x + i, y, Cell(ch, hl.attr, 1))
            # Match-substring highlight on the center row only.
            if is_match and len(self.query.text.as_bytes()) > 0:
                var hit = _find_bytes(line, self.query.text)
                if hit >= 0:
                    var hs = hit
                    var he = hit + len(self.query.text.as_bytes())
                    if he > end: he = end
                    for i in range(hs, he):
                        if i < 0 or i >= end:
                            continue
                        var b = Int(bytes[i])
                        var ch = chr(b) if b < 0x80 else String("?")
                        painter.set(canvas, x + i, y, Cell(ch, hit_attr, 1))

    # --- events -----------------------------------------------------------

    def handle_key(mut self, event: Event, now_ms: Int) -> Bool:
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
        if picker_nav_key(k, len(self.matches), self.selected):
            self._scroll_to_selection()
            self._refresh_context_for_selection()
            return True
        var r = self.query.handle_key(event)
        if r.consumed:
            if r.changed:
                self._mark_query_dirty(now_ms)
            return True
        return True

    def handle_mouse(mut self, event: Event, screen: Rect) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_MOUSE:
            return True
        # Toggles run first so a click on a chip doesn't slip through
        # to the input field and reposition the cursor; the same call
        # also updates per-toggle hover state from bare-motion events
        # so the tooltip strip pops on the next paint.
        var rc = self.toggle_case.handle_mouse(event)
        if rc == BUTTON_FIRED:
            self.toggle_case.on = not self.toggle_case.on
            self._mark_toggle_changed()
            return True
        var rw = self.toggle_word.handle_mouse(event)
        if rw == BUTTON_FIRED:
            self.toggle_word.on = not self.toggle_word.on
            self._mark_toggle_changed()
            return True
        var rr = self.toggle_regex.handle_mouse(event)
        if rr == BUTTON_FIRED:
            self.toggle_regex.on = not self.toggle_regex.on
            self._mark_toggle_changed()
            return True
        if self.toggle_case.pressed or self.toggle_word.pressed \
                or self.toggle_regex.pressed:
            return True
        if self._input_rect.width() > 0 \
                and self.query.handle_mouse(event, self._input_rect):
            return True
        if event.pressed and not event.motion:
            if picker_wheel_scroll(
                event.button, self.scroll, len(self.matches),
                self._list_height(screen),
            ):
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

    def _scroll_to_selection(mut self):
        # Conservative window: assume ~12 visible rows; the actual list
        # height depends on the screen so we re-clamp on paint.
        var visible = 12
        if self.selected < self.scroll:
            self.scroll = self.selected
        elif self.selected >= self.scroll + visible:
            self.scroll = self.selected - visible + 1


# --- internals --------------------------------------------------------------


def _lstrip_tabs(s: String) -> String:
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


struct _RgRunner(Movable):
    """Streaming ripgrep child: spawns ``rg`` as a non-blocking
    subprocess and parses its line-oriented output incrementally as it
    arrives, so a query that scans a huge tree never blocks the UI
    thread. Cancellable mid-search by sending SIGTERM to the child.

    State machine:

    * idle: ``active == False``, ``proc.alive == False``.
    * running: ``active == True``; ``tick()`` drains stdout.
    * draining: ``active == True``, child has exited (EOF on stdout)
      but our line buffer might still hold bytes. ``tick()`` walks them
      out and then transitions back to idle.

    The runner only ever *appends* to its match list — callers can
    snapshot via ``drain_new()`` mid-search without losing earlier
    rows. Re-spawning via ``start()`` cancels any in-flight child first.
    """

    var proc: LspProcess
    var active: Bool
    var root: String
    var query: String
    var _buf: List[UInt8]   # incoming bytes not yet split on '\n'
    # How far we've already scanned ``_buf`` for a newline. Persists
    # across ticks so a single huge unterminated line (e.g. a multi-MB
    # match preview that ``--max-columns`` somehow let through) doesn't
    # rescan ``_buf[0..]`` on every tick — that turned line-finding
    # into O(N²) over the search lifetime.
    var _scan_pos: Int
    var _new: List[ProjectMatch]   # parsed but not yet handed to caller

    def __init__(out self):
        self.proc = LspProcess()
        self.active = False
        self.root = String("")
        self.query = String("")
        self._buf = List[UInt8]()
        self._scan_pos = 0
        self._new = List[ProjectMatch]()

    def is_active(self) -> Bool:
        return self.active

    def cancel(mut self):
        """Stop the running child (if any) and reset state.

        Safe to call when idle. Sends SIGTERM via ``LspProcess.terminate``
        and waits for the child to exit; ``rg`` reacts immediately to
        SIGTERM so the wait is microseconds in practice."""
        if self.active:
            self.proc.terminate()
        self.active = False
        self.root = String("")
        self.query = String("")
        self._buf = List[UInt8]()
        self._scan_pos = 0
        self._new = List[ProjectMatch]()

    def start(
        mut self, root: String, query: String, opts: SearchOptions,
    ) -> Bool:
        """Spawn a fresh ``rg`` child for ``(root, query)``. Returns
        False when the spawn syscall failed (callers gate on rg being
        on PATH before opening the find UI).

        Any previous in-flight search is cancelled first, so calling
        ``start`` repeatedly (one per debounced keystroke) never lets
        old children pile up.

        ``opts`` maps onto rg's flags: ``Cc`` ↔ ``-s`` / ``-i``
        (replacing the default ``--smart-case``), ``W`` ↔ ``-w``,
        ``.*`` toggles between ``-F`` (fixed-string) and rg's regex
        default. ``-w`` works with both modes."""
        self.cancel()
        var argv = List[String]()
        argv.append(String("rg"))
        argv.append(String("--no-heading"))
        argv.append(String("--line-number"))
        argv.append(String("--column"))
        argv.append(String("--color=never"))
        # Case mode: explicit ``-s`` / ``-i`` so the toggle's behavior
        # is unambiguous. Smart-case (the previous default) felt
        # slightly magical and would silently override the user's
        # intent when the query happened to contain an uppercase byte.
        if opts.case_sensitive:
            argv.append(String("--case-sensitive"))
        else:
            argv.append(String("--ignore-case"))
        if opts.whole_word:
            argv.append(String("--word-regexp"))
        if not opts.regex:
            argv.append(String("-F"))            # fixed-string
        # Cap how much rg emits per matched line. Without this, a hit
        # in a minified JS / CSS bundle would push a single multi-MB
        # match line into our pipe; we'd have to buffer it whole
        # before finding the trailing ``\n`` (since lines are our
        # match boundary), and a paint-frame's worth of work would
        # turn into seconds. ``--max-columns-preview`` keeps the
        # matched substring visible so the user still sees what they
        # found, just truncated.
        argv.append(String("--max-columns"))
        argv.append(String("1024"))
        argv.append(String("--max-columns-preview"))
        argv.append(String("--"))                # end of options
        argv.append(query)
        argv.append(root)
        try:
            self.proc = LspProcess.spawn(argv)
        except:
            return False
        self.active = True
        self.root = root
        self.query = query
        return True

    def tick(mut self) -> Bool:
        """Drain any bytes available on the child's stdout and parse
        complete lines. Returns True when at least one new match was
        appended (or the search just completed) so the caller knows to
        refresh UI state for that frame.

        Reads in non-blocking, capped-per-tick batches so a single
        frame can't be hijacked by a high-volume query — anything we
        don't read this frame stays in the kernel pipe buffer for the
        next ``tick``."""
        if not self.active:
            return False
        var changed = False
        # Read up to ~64 KB per frame. rg writes line-buffered when its
        # stdout is a pipe; for typical queries this is plenty per
        # frame, and it bounds the cost of pumping a runaway query.
        var scratch = alloc_zero_buffer(8192)
        var total = 0
        var got_eof = False
        while total < 65536:
            if not poll_stdin(self.proc.stdout_fd, Int32(0)):
                break
            var n = read_into(self.proc.stdout_fd, scratch, 8192)
            if n < 0:
                # EAGAIN-equivalent: nothing ready right now.
                break
            if n == 0:
                got_eof = True
                break
            for i in range(n):
                self._buf.append(scratch[i])
            total += n
        # Parse complete lines (terminated by '\n'). Scan only the
        # newly-appended bytes (``_scan_pos`` carries forward from
        # last tick) so a long unterminated tail doesn't get rescanned
        # on every tick.
        var consumed = 0
        var i = self._scan_pos
        while i < len(self._buf):
            if self._buf[i] == 0x0A:
                if i > consumed:
                    var line_str = String(StringSlice(
                        unsafe_from_utf8=Span(self._buf)[consumed:i],
                    ))
                    var m = _parse_rg_line(line_str, self.root)
                    if m:
                        self._new.append(m.value())
                        changed = True
                consumed = i + 1
            i += 1
        if consumed > 0:
            # Drop the parsed prefix from _buf in one tail-copy. The
            # unscanned remainder (``_buf[consumed:]``) becomes the new
            # ``_buf`` and the scan resumes at its start next tick.
            var tail = List[UInt8]()
            for j in range(consumed, len(self._buf)):
                tail.append(self._buf[j])
            self._buf = tail^
            self._scan_pos = 0
        else:
            # No newline this tick: remember how far we got so the
            # next tick picks up where we left off.
            self._scan_pos = len(self._buf)
        # Process exited (EOF on stdout): reap the child, drop any
        # trailing partial line (rg always terminates lines), and
        # transition to idle. ``terminate`` is safe to call after a
        # natural exit — ``kill`` returns ESRCH, ``waitpid`` reaps
        # the zombie.
        if got_eof:
            self.proc.terminate()
            self.active = False
            self._buf = List[UInt8]()
            self._scan_pos = 0
            changed = True
        return changed

    def drain_new(mut self) -> List[ProjectMatch]:
        """Move out the matches parsed since the last ``drain_new``.
        Caller appends them to its own snapshot."""
        var out = self._new^
        self._new = List[ProjectMatch]()
        return out^


def _parse_rg_line(line: String, root: String) -> Optional[ProjectMatch]:
    """Decode one ``--no-heading --line-number --column`` output line
    (``path:line:col:text``) into a ``ProjectMatch``. Returns None when
    the prefix doesn't have three colons (rg sometimes emits other
    informational lines)."""
    var p1 = _scan_to(line, 0, len(line.as_bytes()), 0x3A)       # first ':'
    if p1 < 0:
        return Optional[ProjectMatch]()
    var p2 = _scan_to(line, p1 + 1, len(line.as_bytes()), 0x3A)  # second ':'
    if p2 < 0:
        return Optional[ProjectMatch]()
    var p3 = _scan_to(line, p2 + 1, len(line.as_bytes()), 0x3A)  # third ':'
    if p3 < 0:
        return Optional[ProjectMatch]()
    var path = _slice_str(line, 0, p1)
    var line_no = _parse_uint(line, p1 + 1, p2)
    var text = _slice_str(line, p3 + 1, len(line.as_bytes()))
    if line_no <= 0:
        return Optional[ProjectMatch]()
    # Truncate the matched-line text up front. We display at most a few
    # hundred cells of it, and storing the full line keeps multi-MB
    # minified-file matches alive in memory across the whole result
    # list. The cap is well above any plausible visible width.
    if len(text.as_bytes()) > _MATCH_TEXT_CAP:
        text = _slice_str(text, 0, _MATCH_TEXT_CAP)
    return Optional[ProjectMatch](ProjectMatch(
        path, _strip_root(path, root), line_no, text,
    ))


def _scan_to_newline(s: String, start: Int) -> Int:
    var b = s.as_bytes()
    var i = start
    while i < len(b) and b[i] != 0x0A:
        i += 1
    return i


def _scan_to(s: String, start: Int, end: Int, target: UInt8) -> Int:
    var b = s.as_bytes()
    var i = start
    while i < end:
        if b[i] == target:
            return i
        i += 1
    return -1


def _parse_uint(s: String, start: Int, end: Int) -> Int:
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


def _slice_str(s: String, start: Int, end: Int) -> String:
    var b = s.as_bytes()
    if start >= end:
        return String("")
    return String(StringSlice(unsafe_from_utf8=b[start:end]))


def _strip_root(path: String, root: String) -> String:
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


def _find_bytes(haystack: String, needle: String) -> Int:
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
