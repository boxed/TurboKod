"""ProjectFind: debounced full-text project search (Find / Replace in
Project).

The search state behind the picker: query, replace text, path scope,
filename glob and the case / word / regex toggles, the streaming match
list, and the selected match's file for the preview. Every projector
draws it from ``Desktop.picker_ui``; edits come back through
``set_field`` / ``set_option`` / ``select`` / ``submit``.

Search runs a streaming ``rg`` after a 300 ms debounce so typing doesn't
thrash the filesystem; the host calls ``tick(now_ms)`` every frame and
``ProjectFind`` decides when the debounce has elapsed. The preview file
is read lazily and cached — typical navigation stays inside one file.
"""

from std.collections.list import List
from std.collections.optional import Optional

from .canvas import Canvas, RunCells
from .painter import Painter
from .cell import Cell
from .colors import Attr
from .file_io import join_path, project_relative, read_file, stat_file
from .geometry import Point, Rect
from .highlight import (
    GrammarRegistry, Highlight, HighlightCache, HighlightList, extension_of,
    highlight_for_extension_cached, sync_highlights,
)
from .posix import monotonic_ms
from .lsp import capture_command
from .project import ProjectMatch
from .query_memory import QueryMemory
from .search_options import SearchOptions
from .string_utils import (
    byte_slice, char_width, codepoint_at, display_columns, utf8_prefix,
    is_ascii_ident_byte, prev_codepoint_start, split_lines, TAB_WIDTH,
)
from .text_field import TextField
from .case_fold import find_exact
from .line_stream import LineStream
from .rg import parse_rg_row, rg_base_argv


comptime _DEBOUNCE_MS: Int = 300
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
    # False == plain Find-in-Project; True == Replace-in-Project, which
    # reuses the entire find surface (streaming results, context preview,
    # scope/glob, toggles) and adds the ``replace`` strip + a ``[ Replace
    # All ]`` action. Set by ``open`` / ``open_replace`` and stable for the
    # session, so geometry / paint / focus all branch on it.
    var replace_mode: Bool
    var root: String
    var query: TextField
    # Replace-mode only: the replacement text. Edited via Tab between it
    # and the query field; changing it does *not* re-run the search (the
    # match set depends only on the query), unlike the other fields.
    var replace: TextField
    # Relative-path scope: when non-empty, the search is restricted to
    # this subdirectory (or file) of the project. Empty == whole project.
    # Edited via Tab between it and the query field; changing it kicks
    # off a fresh debounced search the same as the query does.
    var scope: TextField
    # Filename glob: when non-empty, restricts the search to files whose
    # path matches one of these rg ``-g`` globs (e.g. ``*.mojo`` or
    # ``!*_test.py`` to exclude). Multiple patterns are comma-separated.
    # Empty == every file. Edited via Tab like the scope field; a change
    # kicks off a fresh debounced search.
    var glob: TextField
    var _last_searched_opts: SearchOptions   # toggle state at last search
    var _query_dirty_at_ms: Int        # 0 when no debounce pending
    var matches: List[ProjectMatch]
    var selected: Int
    # Output, set when the user hits Enter.
    var selected_path: String
    var selected_line: Int
    # Search-mode toggles. Mirror the Find prompt's ``Cc`` / ``W`` /
    # ``.*`` chips so the project-wide flow honors the same flags.
    # State persists across opens; flipping a toggle while the dialog
    # is open kicks off a new debounced search.
    var opts: SearchOptions
    # Context cache: lines of the file containing ``matches[selected]``.
    # We reload only when the path changes — typical up/down navigation
    # stays in one file. ``_context_highlights`` is the syntax-highlight
    # overlay computed once per file load.
    var _context_path: String
    var _context_lines: List[String]
    var _context_highlights: HighlightList
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
    # Output flag, set when the user asks to dock the current result set
    # into the persistent Find Results pane (via the title-bar ``[ Panel ]``
    # button or Cmd+Enter). The host polls it the same frame it polls
    # ``submitted``, hands ``matches`` / ``query`` / ``root`` to the pane,
    # and closes the dialog. ``matches`` is left intact for the handoff.
    var send_to_panel: Bool
    # Replace-mode output flag: set when the user fires Replace All (the
    # title-bar ``[ Replace All ]`` button or Cmd+Enter). The host polls it
    # the same frame it polls ``submitted`` / ``send_to_panel``, runs
    # ``replace_in_project`` over ``query`` → ``replace``, and closes the
    # dialog. Mutually exclusive with ``send_to_panel`` (that's find-mode
    # only).
    var do_replace: Bool
    # The last query per project root, for an open that can't resume
    # (another project's state is up): ``close`` stores it.
    var _queries: QueryMemory

    def __init__(out self):
        self._queries = QueryMemory()
        self.active = False
        self.submitted = False
        self.replace_mode = False
        self.root = String("")
        self.query = TextField()
        self.replace = TextField()
        self.scope = TextField()
        self.glob = TextField()
        self._last_searched_opts = SearchOptions()
        self._query_dirty_at_ms = 0
        self.matches = List[ProjectMatch]()
        self.selected = 0
        self.selected_path = String("")
        self.selected_line = 0
        self.opts = SearchOptions()
        self._context_path = String("")
        self._context_lines = List[String]()
        self._context_highlights = HighlightList()
        self._runner = _RgRunner()
        self._truncated = False
        self.send_to_panel = False
        self.do_replace = False

    def open_replace(
        mut self,
        var root: String,
        var prefill: String = String(""),
        select_prefill: Bool = False,
    ):
        """Open the dialog in Replace-in-Project mode — the find surface
        plus a Replace strip and a ``[ Replace All ]`` action. Thin wrapper
        over ``open`` so the two entry points share all the resume / reset
        logic."""
        self.open(root^, prefill^, select_prefill, replace=True)

    def open(
        mut self,
        var root: String,
        var prefill: String = String(""),
        select_prefill: Bool = False,
        replace: Bool = False,
    ):
        """Open the Find-in-Project dialog.

        State (query, results, selection, scroll, context) is preserved
        across opens — closing and reopening lands the user back where
        they left off. A non-empty ``prefill`` (typically the editor's
        current selection) overrides the saved query and kicks off a
        fresh search; an empty prefill against the same project root
        restores prior state and leaves the saved query fully selected
        so the next typed key replaces it. Opening in another project
        starts over from that project's previous query, fully selected.

        ``select_prefill=True`` leaves the seeded text fully selected
        so the next typed key replaces it — mirrors the basic Find
        prompt and lets the user either keep the seeded term (Enter)
        or overwrite it (type).
        """
        self._runner.cancel()
        # Mode is set before the resume early-return so flipping between
        # Find (Cmd+Shift+F) and Replace (Cmd+Shift+R) over the same saved
        # query lands in the right surface.
        self.replace_mode = replace
        var has_prefill = len(prefill.as_bytes()) > 0
        var same_root = root == self.root
        var have_saved = len(self.query.text.as_bytes()) > 0
        # Resume path: no new prefill, same project, and we have a
        # prior query — keep everything (query / replace / matches /
        # scroll / selected / context) and just re-select the query text
        # so a type-over still replaces it.
        if not has_prefill and same_root and have_saved:
            self.root = root^
            self.query.select_all()
            self._query_dirty_at_ms = 0
            self.active = True
            self.submitted = False
            self.send_to_panel = False
            self.do_replace = False
            # ``close`` dropped the previewed file; load it again.
            self._refresh_context_for_selection()
            return
        self.root = root^
        self.query = TextField()
        self.replace = TextField()
        if not has_prefill:
            prefill = self._queries.get(self.root)
            has_prefill = len(prefill.as_bytes()) > 0
            if has_prefill:
                self.query.set_text(prefill^)
                self.query.select_all()
        else:
            self.query.set_text(prefill^)
            if select_prefill:
                self.query.select_all()
        # Scope + glob reset to whole-project on a fresh open (a prior
        # project's subpath / filter is meaningless against a new root, and
        # a prefill search wants the broadest results). Focus starts on the
        # query field.
        self.scope = TextField()
        self.glob = TextField()
        self._last_searched_opts = SearchOptions()
        # ``1`` is the "fire on next tick" sentinel (see _mark_toggle_changed).
        self._query_dirty_at_ms = 1 if has_prefill else 0
        self.matches = List[ProjectMatch]()
        self.selected = 0
        self.selected_path = String("")
        self.selected_line = 0
        # Toggle state persists across opens — leave ``opts``
        # untouched so the user keeps the flags they had on for the
        # previous Find-in-Project.
        self._context_path = String("")
        self._context_lines = List[String]()
        self._context_highlights = HighlightList()
        self._truncated = False
        self.active = True
        self.submitted = False
        self.send_to_panel = False
        self.do_replace = False

    def close(mut self):
        """Hide the dialog and stop any in-flight ``rg`` child, but
        keep query / results / selection / scroll so the next ``open()``
        can resume where the user left off."""
        if self.active:
            self._queries.put(self.root, self.query.text)
        self._runner.cancel()
        self.active = False
        self.submitted = False
        self.send_to_panel = False
        self.do_replace = False
        # Any pending debounce belongs to the just-closed session;
        # the next open decides whether to fire a fresh search.
        self._query_dirty_at_ms = 0
        # The previewed file (up to 4 MB of lines plus its highlights) is
        # re-read on the next open; the matches are what resuming needs.
        self._context_path = String("")
        self._context_lines = List[String]()
        self._context_highlights = HighlightList()

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
            self._truncated = False

    def _run_search(mut self):
        var opts = self.opts
        self._last_searched_opts = opts
        self.matches = List[ProjectMatch]()
        self.selected = 0
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
        _ = self._runner.start(
            self.root, self.query.text, self.scope.text, self.glob.text, opts,
        )

    def _refresh_context_for_selection(mut self):
        """Reload the preview file for the current selection. The
        retokenize defers to ``preview_window`` (which has the shared
        ``GrammarRegistry``) by leaving ``_context_highlights`` empty
        here, via ``_ensure_context_highlights``."""
        if self.selected < 0 or self.selected >= len(self.matches):
            self._context_path = String("")
            self._context_lines = List[String]()
            self._context_highlights = HighlightList()
            return
        var path = self.matches[self.selected].path
        if path == self._context_path and len(self._context_lines) > 0:
            return
        self._context_path = path
        self._context_lines = List[String]()
        self._context_highlights = HighlightList()
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
        # Kept in the compact form: a preview of a 4 MB file was 14 MB of
        # 40-byte ``Highlight``s for as long as the dialog showed it.
        var ctx_cache = HighlightCache()
        sync_highlights(
            extension_of(self._context_path), self._context_lines, 0,
            registry, ctx_cache, self._context_highlights,
        )

    def submit(mut self):
        """Open the selected match (Enter): the host reads
        ``selected_path`` / ``selected_line``."""
        if self.selected < 0 or self.selected >= len(self.matches):
            return
        var m = self.matches[self.selected]
        self.selected_path = m.path
        self.selected_line = m.line_no
        self.submitted = True

    # --- native host (macOS-style UI) ------------------------------------
    #
    # The native panel owns the text fields and toggles; it pushes their
    # values here and the search runs exactly as if they'd been typed.

    def set_field(mut self, field: String, var text: String, now_ms: Int):
        """Set ``query`` / ``replace`` / ``scope`` / ``glob``. Every field
        but ``replace`` re-runs the (debounced) search when it changes."""
        if field == String("replace"):
            self.replace.set_text(text^)
            return
        if field == String("query"):
            if text == self.query.text:
                return
            self.query.set_text(text^)
        elif field == String("scope"):
            if text == self.scope.text:
                return
            self.scope.set_text(text^)
        elif field == String("glob"):
            if text == self.glob.text:
                return
            self.glob.set_text(text^)
        else:
            return
        self._mark_query_dirty(now_ms)

    def set_option(mut self, name: String, on: Bool):
        """Set the ``case`` / ``word`` / ``regex`` toggle."""
        var was: Bool
        if name == String("case"):
            was = self.opts.case_sensitive
            self.opts.case_sensitive = on
        elif name == String("word"):
            was = self.opts.whole_word
            self.opts.whole_word = on
        elif name == String("regex"):
            was = self.opts.regex
            self.opts.regex = on
        else:
            return
        if was != on:
            self._mark_toggle_changed()

    def select(mut self, idx: Int):
        if idx < 0 or idx >= len(self.matches):
            return
        self.selected = idx
        self._refresh_context_for_selection()

    def searching(self) -> Bool:
        return self._runner.is_active() or self._query_dirty_at_ms != 0

    def truncated(self) -> Bool:
        return self._truncated

    def row_hit(self, idx: Int) -> Tuple[String, Int]:
        """Row ``idx``'s displayed text (leading whitespace stripped) and
        the byte offset of the highlighted hit in it, or -1."""
        var text = _lstrip_tabs(self.matches[idx].line_text)
        var q = self.query.text
        var hit = find_hit(
            text.as_bytes(), q.as_bytes(), self.opts.whole_word,
        ) if len(q.as_bytes()) > 0 else -1
        return (text^, hit)

    def preview_window(
        mut self, mut registry: GrammarRegistry, first: Int, end: Int,
    ) -> Tuple[Int, List[String], List[Highlight]]:
        """Lines ``[first, end)`` of the selected match's file and their
        syntax spans, plus its line count — the window of it a list view
        shows."""
        self._ensure_context_highlights(registry)
        var n = len(self._context_lines)
        var lines = List[String]()
        for i in range(max(first, 0), min(end, n)):
            lines.append(self._context_lines[i])
        var hls = List[Highlight]()
        for i in range(len(self._context_highlights)):
            var r = self._context_highlights.row(i)
            if r >= first and r < end:
                hls.append(self._context_highlights[i])
        return (n, lines^, hls^)

# --- internals --------------------------------------------------------------


@fieldwise_init
struct RowTextGeom(ImplicitlyCopyable, Movable):
    """Where ``paint_match_row`` painted the row's selectable line text, so
    a caller wiring up ``PaneTextSelect`` (text_select.mojo) can stamp it.
    Byte==cell: byte ``b`` (for ``b >= byte_start``) landed at column
    ``text_x + (b - byte_start)``. ``clip_x <= text_x`` means the row was
    too narrow to paint any text (nothing selectable)."""
    var text: String      # the displayed line (left-stripped match text)
    var text_x: Int       # screen x of byte ``byte_start``
    var byte_start: Int   # first painted byte (left-slide offset)
    var byte_end: Int     # one past the last painted byte
    var clip_x: Int       # exclusive right edge (before the path label)


def find_hit(
    hb: Span[UInt8, _], needle: Span[UInt8, _], whole_word: Bool,
) -> Int:
    """Byte offset of the first occurrence of ``needle`` in ``hb`` to
    highlight, or -1. With ``whole_word`` an occurrence flanked by
    identifier bytes (``wait`` inside ``await``) is skipped, matching
    what ``rg --word-regexp`` accepted the line for."""
    var at = find_exact(hb, needle, 0)
    if not whole_word:
        return at
    var n = len(needle)
    while at >= 0:
        var before_ok = at == 0 or not is_ascii_ident_byte(hb[at - 1])
        var after_ok = at + n >= len(hb) \
            or not is_ascii_ident_byte(hb[at + n])
        if before_ok and after_ok:
            return at
        at = find_exact(hb, needle, at + 1)
    return -1


def paint_match_row(
    mut canvas: Canvas, container_bounds: Rect, painter: Painter,
    y: Int, m: ProjectMatch, is_sel: Bool, query: String,
    line_attr: Attr, sel_line: Attr,
    hl_attr: Attr, sel_hl_attr: Attr,
    path_attr: Attr, sel_path: Attr,
    mut registry: GrammarRegistry,
    idx: Int, hl_deadline: Int,
    mut row_hl_cache: List[List[Highlight]],
    mut row_hl_cached: List[Bool],
    mark: String = String(""),
    force_plain: Bool = False,
    whole_word: Bool = False,
) -> RowTextGeom:
    """Paint one search-result row inside ``container_bounds`` at row ``y``:
    the matched line text (hit span highlighted) on the left, the
    right-aligned ``rel:line`` label, and an optional attr-only syntax
    overlay gated by ``hl_deadline``. ``query`` is the search term used to
    locate + highlight the hit. ``row_hl_cache`` / ``row_hl_cached`` are the
    caller's per-row highlight cache (kept aligned 1:1 with its result list);
    a non-empty ``mark`` is painted in the row's left-margin cell (the Find
    Results pane uses it for the multi-select tick). Shared verbatim by the
    Find-in-Project modal and the Find Results pane so the two surfaces
    render identical rows."""
    var row_attr = sel_line if is_sel else line_attr
    var row_path = sel_path if is_sel else path_attr
    var row_hl = sel_hl_attr if is_sel else hl_attr
    var inner_left = container_bounds.a.x + 1
    var inner_right = container_bounds.b.x - 1
    painter.fill(
        canvas, Rect(inner_left, y, inner_right, y + 1),
        String(" "), row_attr,
    )
    # Multi-select marker in the left-margin cell (blank otherwise). The
    # text run starts at ``inner_left + 1`` so this never collides with it.
    if len(mark.as_bytes()) > 0:
        painter.set(canvas, inner_left, y, Cell(mark, row_attr, 1))
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
        return RowTextGeom(String(""), line_x, 0, 0, line_x)
    var line_stripped = _lstrip_tabs(m.line_text)
    var bytes = line_stripped.as_bytes()
    var hit = find_hit(bytes, query.as_bytes(), whole_word) \
        if len(query.as_bytes()) > 0 else -1
    # Slide so the hit (if any) is visible inside the available width.
    # All of this is in *cells*, not bytes: the row is painted one cell
    # per codepoint, so a line with non-ASCII in it has fewer columns
    # than bytes and byte arithmetic both over-slid and under-filled it.
    var avail = line_max - line_x
    var start = 0
    if hit >= 0:
        # Walking *backwards* from the hit keeps this bounded by the
        # pane width instead of the line length — a mapping of the whole
        # line would allocate per row per frame, and these lines can be
        # minified JS. Reaching byte 0 within ``avail`` columns means the
        # hit is already on screen and no slide is needed.
        if _back_cells(line_stripped, hit + len(query.as_bytes()), avail) > 0:
            # Center the hit, keeping start >= 0.
            start = _back_cells(line_stripped, hit, avail // 3)
    var end = _clip_to_cells(line_stripped, start, avail)
    # Render plain run. ``put_text`` is what gives one cell per
    # codepoint; painting byte-by-byte with ``?`` for anything >= 0x80
    # is what showed an ``ö`` as ``??``.
    var vis = byte_slice(line_stripped, start, end)
    var run = RunCells(vis, line_x, start)
    _ = painter.put_text(canvas, Point(line_x, y), vis, row_attr)
    # Syntax-highlight overlay (attr-only). Skipped on the selected
    # row because the solid yellow selection background clashes with
    # the highlighter's blue-background palette — keeping the
    # selection a clean color block reads better than mixing the two.
    # We tokenize just this one line, so a token that opened on a
    # prior line (e.g. a triple-quoted string) won't be recognized;
    # acceptable for a one-line preview.
    if not is_sel and not force_plain and len(bytes) <= _ROW_HIGHLIGHT_CAP:
        # Resolve this row's highlights, preferring the per-match
        # cache. The shared ``GrammarRegistry`` keeps compiled
        # grammars across the session, but tokenizing a single line
        # still walks every regex across the whole string — for a
        # ~1 KB minified-JS line that's tens of ms, and a screenful
        # of them re-tokenized every paint is what made arrow-key
        # navigation crawl. So:
        #   - cache hit  → reuse, free, always painted;
        #   - cache miss → tokenize only while the frame's
        #     ``hl_deadline`` budget holds, then store the result;
        #   - over budget → render plain this frame, leave it
        #     uncached so a later frame fills it in.
        var have_hls = False
        var hls = List[Highlight]()
        if idx >= 0 and idx < len(row_hl_cached) \
                and row_hl_cached[idx]:
            hls = row_hl_cache[idx].copy()
            have_hls = True
        elif monotonic_ms() < hl_deadline:
            var one_line = List[String]()
            one_line.append(line_stripped)
            var row_cache = HighlightCache()
            hls = highlight_for_extension_cached(
                extension_of(m.path), one_line, registry, row_cache,
            )
            if idx >= 0 and idx < len(row_hl_cache):
                row_hl_cache[idx] = hls.copy()
                row_hl_cached[idx] = True
            have_hls = True
        if have_hls:
            # Attr-only, as the comment above always claimed: the glyph
            # pass already ran, and re-writing glyphs here is what made
            # every overlay a second place that had to get UTF-8 right.
            for h in range(len(hls)):
                var hl = hls[h]
                if hl.row != 0:
                    continue
                for c in range(
                    run.cell_of(hl.col_start), run.cell_of(hl.col_end),
                ):
                    painter.set_attr(canvas, line_x + c, y, hl.attr)
    # Highlight overlay for the hit.
    if hit >= 0 and len(query.as_bytes()) > 0:
        var hl_end = hit + len(query.as_bytes())
        for c in range(run.cell_of(hit), run.cell_of(hl_end)):
            painter.set_attr(canvas, line_x + c, y, row_hl)
    # Leading "…" hint when the line was sliced from the left.
    if start > 0:
        painter.set(canvas, line_x, y, Cell(String("…"), row_attr, 1))
    return RowTextGeom(line_stripped, line_x, start, end, line_max)


def _back_cells(text: String, from_byte: Int, n_cells: Int) -> Int:
    """Byte offset ``n_cells`` display columns left of ``from_byte``,
    clamped to 0. Walks at most ``n_cells`` codepoints, so it costs the
    pane's width rather than the line's length.

    A tab counts as a full ``TAB_WIDTH`` here — its true width depends
    on the absolute column we don't know walking backwards. This only
    feeds the horizontal-slide heuristic, and ``_lstrip_tabs`` has
    already removed the leading run, so the imprecision is invisible."""
    var b = text.as_bytes()
    var i = from_byte
    if i > len(b):
        i = len(b)
    var left = n_cells
    while i > 0 and left > 0:
        var prev = prev_codepoint_start(text, i)
        if Int(b[prev]) == 0x09:
            left -= TAB_WIDTH
        else:
            left -= char_width(codepoint_at(text, prev)[0])
        i = prev
    return i


def _clip_to_cells(text: String, start: Int, max_cells: Int) -> Int:
    """Byte offset one past the last codepoint of ``text[start:]`` that
    still fits in ``max_cells`` screen columns.

    These panes used to clip by *bytes*, which under-fills the row for
    any non-ASCII text (an ``ö`` is two bytes, one column) and could cut
    a multi-byte sequence in half. Mirrors ``put_text``'s stopping rule
    exactly, tabs and wide glyphs included: a glyph that would straddle
    the limit is excluded rather than half-painted."""
    var b = text.as_bytes()
    var n = len(b)
    if max_cells <= 0:
        return start
    var i = start
    var cell = 0
    while i < n:
        var w: Int
        var step: Int
        if Int(b[i]) == 0x09:
            w = TAB_WIDTH - (cell % TAB_WIDTH)
            step = 1
        else:
            var info = codepoint_at(text, i)
            w = char_width(info[0])
            step = info[1]
        if cell + w > max_cells:
            break
        cell += w
        i += step
    return i


def _clean_scope(s: String) -> String:
    """Normalize a user-typed scope path: drop surrounding whitespace
    and any leading ``/`` so ``join_path(root, scope)`` always produces
    a path *inside* the project (a leading slash would otherwise read as
    absolute / yield a doubled separator). Returns ``""`` for a path
    that's all whitespace / slashes — i.e. "search the whole project"."""
    var b = s.as_bytes()
    var lo = 0
    var hi = len(b)
    while lo < hi and (b[lo] == 0x20 or b[lo] == 0x09 or b[lo] == 0x2F):
        lo += 1
    while hi > lo and (b[hi - 1] == 0x20 or b[hi - 1] == 0x09):
        hi -= 1
    if lo >= hi:
        return String("")
    return String(StringSpan(unsafe_from_utf8=b[lo:hi]))


def _split_globs(s: String) -> List[String]:
    """Split a comma-separated glob string into individual rg patterns,
    trimming surrounding whitespace and dropping empties. ``"*.mojo,
    !*_test.py"`` → ``["*.mojo", "!*_test.py"]``; an all-whitespace or
    empty input yields ``[]`` (no ``-g`` flags, so every file is scanned).
    """
    var out = List[String]()
    var b = s.as_bytes()
    var start = 0
    var i = 0
    while i <= len(b):
        if i == len(b) or b[i] == 0x2C:   # ',' or end of string
            # Trim leading/trailing spaces + tabs from [start, i).
            var lo = start
            var hi = i
            while lo < hi and (b[lo] == 0x20 or b[lo] == 0x09):
                lo += 1
            while hi > lo and (b[hi - 1] == 0x20 or b[hi - 1] == 0x09):
                hi -= 1
            if lo < hi:
                out.append(String(StringSpan(unsafe_from_utf8=b[lo:hi])))
            start = i + 1
        i += 1
    return out^


def _lstrip_tabs(s: String) -> String:
    """Drop leading whitespace (tabs/spaces) so the first non-blank
    character of the line lines up at the row's left edge — search hits
    in deeply indented code stay on-container_bounds."""
    var b = s.as_bytes()
    var i = 0
    while i < len(b) and (b[i] == 0x20 or b[i] == 0x09):
        i += 1
    if i == 0:
        return s
    return String(StringSpan(unsafe_from_utf8=b[i:len(b)]))


def _project_find_argv(
    root: String, query: String, scope: String,
    glob: String, opts: SearchOptions,
) -> List[String]:
    """Build the ``rg`` argv for one project-wide find.

    Split out from ``ProjectFindRunner.start`` so the flag set is
    assertable without spawning a child — the bug this guards
    against (a missing ``--hidden``, so nothing under ``.github/``
    was ever searched) is invisible in any test that only checks
    parsing or match plumbing."""
    # Resolve the search root. A blank / slash-only scope falls back
    # to the whole project; otherwise we search the joined subpath.
    # rg silently reports nothing (errors land on stderr, which we
    # don't read) when the subpath doesn't exist, so a typo just
    # yields an empty result list rather than a crash.
    var clean = _clean_scope(scope)
    var search_dir = root
    if len(clean.as_bytes()) > 0:
        search_dir = join_path(root, clean)
    var argv = rg_base_argv()
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
    # Filename globs: one ``-g`` per comma-separated pattern. rg
    # applies these as include/exclude filters on the file walk, so a
    # query like ``foo`` with glob ``*.mojo`` only scans Mojo files.
    var globs = _split_globs(glob)
    for gi in range(len(globs)):
        argv.append(String("-g"))
        argv.append(globs[gi])
    argv.append(String("--"))                # end of options
    argv.append(query)
    argv.append(search_dir)
    return argv^


def project_find_files(
    root: String, query: String, scope: String, glob: String,
    opts: SearchOptions,
) raises -> List[String]:
    """The files the Find in Project search for these fields has a match
    in — with its own command line, so the scope, the globs and what rg
    leaves out are the same: what Replace All may change."""
    var argv = _project_find_argv(root, query, scope, glob, opts)
    var listed = List[String]()
    var options = True
    for a in argv:
        if options and a == String("--"):
            listed.append(String("--files-with-matches"))
            options = False
        listed.append(a)
    var out = List[String]()
    for path in capture_command(listed).stdout.split("\0"):
        if path.byte_length() > 0:
            out.append(String(path))
    return out^


struct _RgRunner(Movable):
    """Streaming ripgrep child: spawns ``rg`` as a non-blocking
    subprocess and parses its line-oriented output incrementally as it
    arrives, so a query that scans a huge tree never blocks the UI
    thread. Cancellable mid-search by sending SIGTERM to the child.

    State machine:

    * idle: the ``LineStream`` is inactive.
    * running: ``tick()`` drains stdout and parses complete lines; at
      EOF the stream reaps the child and goes idle again.

    The runner only ever *appends* to its match list — callers can
    snapshot via ``drain_new()`` mid-search without losing earlier
    rows. Re-spawning via ``start()`` cancels any in-flight child first.
    """

    var stream: LineStream
    var root: String
    var query: String
    var _new: List[ProjectMatch]   # parsed but not yet handed to caller

    def __init__(out self):
        self.stream = LineStream()
        self.root = String("")
        self.query = String("")
        self._new = List[ProjectMatch]()

    def is_active(self) -> Bool:
        return self.stream.is_active()

    def cancel(mut self):
        """Stop the running child (if any) and reset state.

        Safe to call when idle; ``rg`` exits on SIGTERM at once."""
        self.stream.cancel()
        self.root = String("")
        self.query = String("")
        self._new = List[ProjectMatch]()

    def start(
        mut self, root: String, query: String, scope: String,
        glob: String, opts: SearchOptions,
    ) -> Bool:
        """Spawn a fresh ``rg`` child for ``(root, query)``. Returns
        False when the spawn syscall failed (callers gate on rg being
        on PATH before opening the find UI).

        ``scope`` is an optional project-relative path: when non-empty,
        ``rg`` searches ``<root>/<scope>`` instead of the whole project.
        Match paths are still reported relative to ``root`` (the parse
        side keeps ``self.root = root``), so the result list reads the
        same regardless of scope.

        ``glob`` is an optional comma-separated list of rg filename globs
        (``*.mojo``, ``!*_test.py``, …); each non-empty pattern becomes a
        ``-g`` flag, so the search only touches matching files.

        Any previous in-flight search is cancelled first, so calling
        ``start`` repeatedly (one per debounced keystroke) never lets
        old children pile up.

        ``opts`` maps onto rg's flags: ``Cc`` ↔ ``-s`` / ``-i``
        (replacing the default ``--smart-case``), ``W`` ↔ ``-w``,
        ``.*`` toggles between ``-F`` (fixed-string) and rg's regex
        default. ``-w`` works with both modes."""
        self.cancel()
        var argv = _project_find_argv(root, query, scope, glob, opts)
        if not self.stream.start(argv):
            return False
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
        if not self.stream.is_active():
            return False
        var got = self.stream.tick()
        var changed = got[1]   # a finished search is a change too
        for line in got[0]:
            var m = _parse_rg_line(line, self.root)
            if m:
                self._new.append(m.value())
                changed = True
        return changed

    def drain_new(mut self) -> List[ProjectMatch]:
        """Move out the matches parsed since the last ``drain_new``.
        Caller appends them to its own snapshot."""
        var out = self._new^
        self._new = List[ProjectMatch]()
        return out^


def _parse_rg_line(line: String, root: String) -> Optional[ProjectMatch]:
    """One ``parse_rg_row`` row as a ``ProjectMatch``, or None."""
    var row = parse_rg_row(line)
    if not row:
        return Optional[ProjectMatch]()
    var path = row.value()[0]
    var line_no = row.value()[1]
    var text = row.value()[3]
    # Truncate the matched-line text up front. We display at most a few
    # hundred cells of it, and storing the full line keeps multi-MB
    # minified-file matches alive in memory across the whole result
    # list. The cap is well above any plausible visible width.
    # On a codepoint boundary, so the cut can't leave invalid UTF-8.
    if len(text.as_bytes()) > _MATCH_TEXT_CAP:
        var cut = utf8_prefix(text, _MATCH_TEXT_CAP)
        text = cut^
    return Optional[ProjectMatch](ProjectMatch(
        path, project_relative(root, path), line_no, text,
    ))


