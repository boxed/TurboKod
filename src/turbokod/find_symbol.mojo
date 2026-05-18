"""FindSymbol: type-to-filter project symbol picker.

Triggered by Cmd+Option+O. The picker is a streaming search:

1. As the user types, a ``rg`` child runs in the background scanning
   every file under the project root for word-boundary-anchored
   identifiers that contain the query as a substring (e.g. ``asd``
   surfaces ``qweasdzxc``, ``asdfg``, ``my_asdf``, etc.).
2. Each rg match line gives us a ``(path, line, col, line-text)``
   tuple. We extract the *full identifier* sitting at the matched
   column (walk left + right while the byte is an identifier
   character) and use that as the symbol name.
3. The first occurrence of each unique symbol name lands in the
   picker's list. Subsequent occurrences of the same name are
   ignored — the goal is one entry per symbol, not one entry per
   usage.
4. On ``Enter`` the host sends ``textDocument/definition`` to the
   relevant LSP at the *first occurrence* of the selected name. The
   LSP follows the (probably-a-usage) hit to the actual definition.
   Same convergence trick as before, just gated on a list pick
   instead of a blind first-rg-result.

The runner streams output line-by-line so very large projects
don't block the UI thread on a synchronous full scan; restarts on
every query change cancel the previous child via ``SIGTERM``.
"""

from std.collections.list import List
from std.collections.optional import Optional

from .canvas import Canvas, paint_drop_shadow
from .painter import Painter
from .cell import Cell
from .colors import Attr, BLACK, BLUE, LIGHT_GRAY, RED, YELLOW
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_ENTER, KEY_ESC,
    MOUSE_BUTTON_LEFT,
)
from .file_io import ci_less
from .geometry import Point, Rect
from .lsp import LspProcess
from .picker_input import picker_nav_key, picker_wheel_scroll
from .posix import alloc_zero_buffer, poll_stdin, read_into
from .string_utils import starts_with
from .text_field import TextField
from .type_ahead import starts_with_ci
from .view import RowCursor
from .window import paint_window_title


comptime _LABEL = String(" Find: ")
comptime _LABEL_W = 7
"""Columns occupied by the inline search label (``" Find: "``)."""


@fieldwise_init
struct _Layout(ImplicitlyCopyable, Movable):
    """Pre-computed rects for the picker. Shared by ``paint`` and
    ``handle_mouse`` so list hit-testing and list rendering see the
    exact same top/height."""
    var input_rect: Rect
    var input_label_pt: Point
    var list_top: Int
    var list_height: Int
    var hint_y: Int


def _build_layout(rect: Rect) -> _Layout:
    var cursor = RowCursor(rect.a.y + 1)
    var input_y = cursor.place()
    var list_y = cursor.place()
    var hint_y = rect.b.y - 1
    var list_h = hint_y - list_y
    if list_h < 0:
        list_h = 0
    return _Layout(
        Rect(rect.a.x + 2 + _LABEL_W, input_y, rect.b.x - 1, input_y + 1),
        Point(rect.a.x + 2, input_y),
        list_y, list_h, hint_y,
    )


comptime _ENTRIES_CAP: Int = 500
"""Hard cap on how many unique symbol names we collect per query.
Past this point further rg output is dropped on the floor and the
runner is cancelled — the user can keep narrowing the query.

500 is generous: even a one-letter query against a large repo gives
the user something to scroll, and at this size the picker is still
responsive (the dedupe set is a flat name list)."""

comptime _MIN_QUERY_LEN: Int = 2
"""Minimum query length before we kick off a search. A single-letter
query against a large repo would match tens of thousands of words —
mostly noise. Two characters is enough to make the result list
useful for casual typing."""


@fieldwise_init
struct FindSymbolMatch(ImplicitlyCopyable, Movable):
    """One picker entry: the symbol name plus the location of its
    first textual occurrence (used as the seed for the LSP definition
    lookup on submit)."""
    var name: String
    var path: String        # absolute path
    var line: Int           # 1-based, as rg reports
    var column: Int         # 1-based, as rg reports


# --- streaming rg runner ---------------------------------------------------


struct _FindSymbolRunner(Movable):
    """Spawns ``rg`` and incrementally drains its stdout into match
    rows on each ``tick``. One running child at a time; ``start``
    cancels any prior child first so a fast typist can't pile up
    zombie rg processes.

    We deliberately don't use ``LspProcess.poll_message`` (the
    Content-Length framer) — rg writes plain newline-terminated
    text. The line splitting is local to this runner.
    """

    var proc: LspProcess
    var active: Bool
    var _buf: List[UInt8]
    var _scan_pos: Int

    def __init__(out self):
        self.proc = LspProcess()
        self.active = False
        self._buf = List[UInt8]()
        self._scan_pos = 0

    def is_active(self) -> Bool:
        return self.active

    def cancel(mut self):
        """Stop the running child (if any) and reset state. Idempotent."""
        if self.active:
            self.proc.terminate()
        self.active = False
        self._buf = List[UInt8]()
        self._scan_pos = 0

    def start(mut self, query: String, root: String) -> Bool:
        """Spawn ``rg`` for ``query`` rooted at ``root``. The pattern
        is ``\\b[\\w]*<query>[\\w]*\\b`` so any identifier *containing*
        the query — anywhere — counts as a hit. Returns False on
        spawn failure (e.g. ``rg`` missing from PATH).
        """
        self.cancel()
        var argv = List[String]()
        argv.append(String("rg"))
        argv.append(String("--no-heading"))
        argv.append(String("--line-number"))
        argv.append(String("--column"))
        argv.append(String("--color=never"))
        argv.append(String("--smart-case"))
        # Cap per-line preview so a hit inside a minified bundle can't
        # smuggle multi-MB lines into our buffer (mirrors the cap
        # ``project_find`` uses for the same reason).
        argv.append(String("--max-columns"))
        argv.append(String("1024"))
        argv.append(String("--max-columns-preview"))
        argv.append(String("-e"))
        argv.append(
            String("\\b[A-Za-z0-9_]*") + query + String("[A-Za-z0-9_]*\\b"),
        )
        argv.append(String("--"))
        argv.append(root)
        try:
            self.proc = LspProcess.spawn(argv)
        except:
            return False
        self.active = True
        return True

    def tick(mut self) -> List[Tuple[String, Int, Int, String]]:
        """Drain whatever bytes are queued on rg's stdout, parse as
        many complete lines as possible, and return them as
        ``(path, line, column, text)`` tuples. The caller owns the
        per-symbol-name dedupe.

        Reads in a single capped batch (~64 KB) so a noisy query
        can't hijack the frame budget. Anything we don't read this
        frame stays in the kernel pipe buffer for the next ``tick``.
        """
        var out = List[Tuple[String, Int, Int, String]]()
        if not self.active:
            return out^
        var scratch = alloc_zero_buffer(8192)
        var total = 0
        var got_eof = False
        while total < 65536:
            if not poll_stdin(self.proc.stdout_fd, Int32(0)):
                break
            var n = read_into(self.proc.stdout_fd, scratch, 8192)
            if n < 0:
                break
            if n == 0:
                got_eof = True
                break
            for i in range(n):
                self._buf.append(scratch[i])
            total += n
        # Walk only the new bytes — ``_scan_pos`` carries forward
        # so a single huge unterminated tail isn't rescanned every
        # tick.
        var consumed = 0
        var i = self._scan_pos
        while i < len(self._buf):
            if self._buf[i] == 0x0A:
                if i > consumed:
                    var line_str = String(StringSlice(
                        unsafe_from_utf8=Span(self._buf)[consumed:i],
                    ))
                    var parsed = _parse_rg_match_line(line_str)
                    if parsed:
                        out.append(parsed.value())
                consumed = i + 1
            i += 1
        if consumed > 0:
            var tail = List[UInt8]()
            for j in range(consumed, len(self._buf)):
                tail.append(self._buf[j])
            self._buf = tail^
            self._scan_pos = 0
        else:
            self._scan_pos = len(self._buf)
        if got_eof:
            self.proc.terminate()
            self.active = False
            self._buf = List[UInt8]()
            self._scan_pos = 0
        return out^


# --- Picker ----------------------------------------------------------------


comptime _STATE_IDLE       = UInt8(0)
"""Picker open, accepting input. Default state."""
comptime _STATE_PENDING    = UInt8(1)
"""User submitted a selection; an LSP definition request is in flight."""
comptime _STATE_ERROR      = UInt8(2)
"""A previous submit hit an error; ``status_message`` holds the text."""


struct FindSymbol(Movable):
    var active: Bool
    var query: TextField
    var root: String                 # project root the runner is rooted at
    # Cached input strip rect for mouse routing.
    var _input_rect: Rect
    var entries: List[FindSymbolMatch]
    # Parallel name list — kept in sync with ``entries`` for O(N) dedupe
    # on append. Could swap for a hashed set if dedupe ever becomes hot;
    # at ``_ENTRIES_CAP`` (500) the linear scan is still cheap.
    var seen_names: List[String]
    var selected: Int
    var scroll: Int
    var submitted: Bool
    # Output: the entry the user just submitted. The host reads these
    # after ``take_submitted()`` returns True.
    var selected_path: String
    var selected_line: Int
    var selected_column: Int
    var selected_name: String
    var state: UInt8
    var status_message: String
    var runner: _FindSymbolRunner
    # True once the user has actively navigated (arrow keys, page,
    # home/end, or click-to-select). Drives whether streaming inserts
    # follow the user's chosen entry by name (preserve selection) or
    # pin the selection to the top of the ranked list (best match).
    var _user_navigated: Bool
    # True when ``entries`` was supplied externally (via ``set_choices``)
    # as a static list of resolved locations — i.e. the second step of
    # the workspace/symbol disambiguation flow. In chooser mode the rg
    # runner is silent, the query field freezes, and the rank/alpha
    # reorder is skipped so the host's curated order is preserved.
    var _chooser_mode: Bool
    # The name the user picked in the first step. Shown in the input
    # row so they can see what they're disambiguating; empty otherwise.
    var _chooser_name: String

    def __init__(out self):
        self.active = False
        self.query = TextField()
        self.root = String("")
        self.entries = List[FindSymbolMatch]()
        self.seen_names = List[String]()
        self.selected = 0
        self.scroll = 0
        self.submitted = False
        self.selected_path = String("")
        self.selected_line = 0
        self.selected_column = 0
        self.selected_name = String("")
        self.state = _STATE_IDLE
        self.status_message = String("")
        self.runner = _FindSymbolRunner()
        self._input_rect = Rect(0, 0, 0, 0)
        self._user_navigated = False
        self._chooser_mode = False
        self._chooser_name = String("")

    def open(mut self, var root: String):
        self.active = True
        self.query = TextField()
        self.root = root^
        self.entries = List[FindSymbolMatch]()
        self.seen_names = List[String]()
        self.selected = 0
        self.scroll = 0
        self.submitted = False
        self.selected_path = String("")
        self.selected_line = 0
        self.selected_column = 0
        self.selected_name = String("")
        self.state = _STATE_IDLE
        self.status_message = String("")
        self.runner.cancel()
        self._input_rect = Rect(0, 0, 0, 0)
        self._user_navigated = False
        self._chooser_mode = False
        self._chooser_name = String("")

    def close(mut self):
        self.active = False
        self.query = TextField()
        self.root = String("")
        self.entries = List[FindSymbolMatch]()
        self.seen_names = List[String]()
        self.selected = 0
        self.scroll = 0
        self.submitted = False
        self.state = _STATE_IDLE
        self.status_message = String("")
        self.runner.cancel()
        self._input_rect = Rect(0, 0, 0, 0)
        self._user_navigated = False
        self._chooser_mode = False
        self._chooser_name = String("")

    def set_pending(mut self, var msg: String):
        self.state = _STATE_PENDING
        self.status_message = msg^

    def set_error(mut self, var msg: String):
        self.state = _STATE_ERROR
        self.status_message = msg^

    def take_submitted(mut self) -> Bool:
        var s = self.submitted
        self.submitted = False
        return s

    def is_choosing(self) -> Bool:
        """True iff the picker is in location-chooser mode — i.e. the
        host has populated ``entries`` with workspace/symbol results
        and Enter should jump directly rather than firing another LSP
        request."""
        return self._chooser_mode

    def set_choices(
        mut self,
        var name: String,
        var choices: List[FindSymbolMatch],
    ):
        """Switch the picker into chooser mode with ``choices`` as the
        static entry list. Used after a workspace/symbol response
        returns multiple locations for ``name`` — the host hands us the
        candidates and we let the user pick one. Locking the input
        field keeps the chosen name visible without offering a second
        round of rg streaming inside the chooser."""
        self.runner.cancel()
        self.entries = choices^
        self.seen_names = List[String]()
        self.selected = 0
        self.scroll = 0
        self._user_navigated = False
        self._chooser_mode = True
        self._chooser_name = name^
        self.state = _STATE_IDLE
        self.status_message = String("")

    # --- background pump --------------------------------------------------

    def tick(mut self):
        """Drain one batch of rg output and merge new symbol names
        into the entry list. Called every paint frame by the host
        (cheap when the runner is idle).
        """
        if not self.active or not self.runner.is_active():
            return
        var rows = self.runner.tick()
        var added = False
        for i in range(len(rows)):
            if len(self.entries) >= _ENTRIES_CAP:
                # Hit the cap — stop draining and silence the runner
                # so we don't keep paying for parse work the user
                # will never see.
                self.runner.cancel()
                break
            var row = rows[i]
            var path = row[0]
            var line_no = row[1]
            var col = row[2]
            var text = row[3]
            var name = _extract_identifier(text, col)
            if len(name.as_bytes()) == 0:
                continue
            if _list_contains(self.seen_names, name):
                continue
            self.seen_names.append(name)
            self.entries.append(FindSymbolMatch(name, path, line_no, col))
            added = True
        if not added:
            return
        # Remember which entry the user is sitting on so the rank/alpha
        # reorder below doesn't yank their selection out from under
        # them mid-stream. If they haven't actively navigated yet, the
        # selection sticks to the top (the best-ranked entry).
        var prev_selected_name = String("")
        if self._user_navigated \
                and 0 <= self.selected \
                and self.selected < len(self.entries):
            prev_selected_name = self.entries[self.selected].name
        _sort_entries_ranked(self.entries, self.query.text)
        if len(prev_selected_name.as_bytes()) > 0:
            for i in range(len(self.entries)):
                if self.entries[i].name == prev_selected_name:
                    self.selected = i
                    self._scroll_to_selection()
                    return
        self.selected = 0
        self.scroll = 0

    def restart_runner(mut self):
        """Cancel any in-flight rg and start a fresh search for
        ``self.query`` rooted at ``self.root``. Picker entries are
        cleared so the new query gets a clean slate.

        Short queries (under ``_MIN_QUERY_LEN`` characters) skip the
        spawn — the result list would be too noisy to be useful.
        """
        self.entries = List[FindSymbolMatch]()
        self.seen_names = List[String]()
        self.selected = 0
        self.scroll = 0
        self._user_navigated = False
        self.runner.cancel()
        if len(self.query.text.as_bytes()) < _MIN_QUERY_LEN:
            return
        if len(self.root.as_bytes()) == 0:
            return
        _ = self.runner.start(self.query.text, self.root)

    # --- geometry ---------------------------------------------------------

    def _rect(self, screen: Rect) -> Rect:
        var width = 80
        var height = 22
        if width > screen.b.x - 4: width = screen.b.x - 4
        if height > screen.b.y - 4: height = screen.b.y - 4
        var x = (screen.b.x - width) // 2
        var y = (screen.b.y - height) // 2
        return Rect(x, y, x + width, y + height)

    def is_input_at(self, pos: Point, screen: Rect) -> Bool:
        if not self.active:
            return False
        var rect = self._rect(screen)
        return _build_layout(rect).input_rect.contains(pos)

    # --- paint ------------------------------------------------------------

    def paint(mut self, mut canvas: Canvas, screen: Rect):
        if not self.active:
            return
        var bg          = Attr(BLACK,  LIGHT_GRAY)
        var sel_attr    = Attr(BLACK,  YELLOW)
        var hint_attr   = Attr(BLUE,   LIGHT_GRAY)
        var error_attr  = Attr(RED,    LIGHT_GRAY)
        var rect = self._rect(screen)
        var layout = _build_layout(rect)
        paint_drop_shadow(canvas, rect)
        var painter = Painter(rect)
        painter.fill(canvas, rect, String(" "), bg)
        painter.draw_box(canvas, rect, bg, False)
        # Title switches to the chooser variant once the user has
        # picked a name and the LSP has handed back >1 location, so
        # the second-step purpose is obvious without an extra label
        # row eating from the list height.
        var title: String
        if self._chooser_mode:
            title = String(" Find Symbol — choose location for ") \
                + self._chooser_name + String(" ")
        else:
            title = String(" Find Symbol ")
        paint_window_title(canvas, rect, title, bg, bg)
        _ = painter.put_text(canvas, layout.input_label_pt, _LABEL, bg)
        self._input_rect = layout.input_rect
        if self._chooser_mode:
            # Locked label in place of the editable input — the query
            # is the name they already picked, retyping isn't useful
            # here, and a non-blinking row reads as "frozen".
            painter.fill(
                canvas, layout.input_rect, String(" "), bg,
            )
            _ = painter.put_text(
                canvas, Point(layout.input_rect.a.x, layout.input_rect.a.y),
                self._chooser_name, bg,
            )
        else:
            self.query.paint(canvas, layout.input_rect, True)
        var top = layout.list_top
        var h = layout.list_height
        # Status / placeholder. Chooser mode skips this whole branch:
        # entries are pre-populated by the host, so neither the query-
        # too-short hint nor the "searching…" copy applies.
        if self._chooser_mode:
            pass
        elif self.state == _STATE_PENDING:
            _ = painter.put_text(
                canvas, Point(rect.a.x + 2, top),
                self.status_message, hint_attr,
            )
        elif self.state == _STATE_ERROR:
            _ = painter.put_text(
                canvas, Point(rect.a.x + 2, top),
                self.status_message, error_attr,
            )
        elif len(self.query.text.as_bytes()) < _MIN_QUERY_LEN:
            _ = painter.put_text(
                canvas, Point(rect.a.x + 2, top),
                String("Type at least 2 letters of a symbol name."),
                hint_attr,
            )
        elif len(self.entries) == 0:
            var msg: String
            if self.runner.is_active():
                msg = String("Searching…")
            else:
                msg = String("No matches.")
            _ = painter.put_text(
                canvas, Point(rect.a.x + 2, top), msg, hint_attr,
            )
        # Listing — paints regardless of state so a leftover error
        # message above the list doesn't hide already-collected hits.
        # In the initial (picker) mode each row is a unique symbol
        # name with a single rg-derived ``entry.path`` (the first
        # textual occurrence); the path adds noise without
        # disambiguation power, so the row is just the name. In
        # chooser mode the *name is identical on every row* (that's
        # the whole point of the chooser), so we drop the name and
        # render the relative ``path:line`` instead — that's the
        # only thing that distinguishes candidates.
        for i in range(h):
            var idx = self.scroll + i
            if idx >= len(self.entries):
                break
            var entry = self.entries[idx]
            var is_sel = (idx == self.selected)
            var row_attr = sel_attr if is_sel else bg
            painter.fill(
                canvas, Rect(rect.a.x + 1, top + i, rect.b.x - 1, top + i + 1),
                String(" "), row_attr,
            )
            var name_x = rect.a.x + 2
            if not self._chooser_mode:
                _ = painter.put_text(
                    canvas, Point(name_x, top + i), entry.name, row_attr,
                )
                continue
            # Chooser row: ``relative-path:line``. Show just the path,
            # not the symbol name (every row in this list shares the
            # name we're disambiguating, so repeating it eats space
            # and reads like noise).
            var rel = _relativize(entry.path, self.root)
            var label = rel + String(":") + String(entry.line)
            var avail = rect.b.x - 1 - name_x
            if avail < 1:
                continue
            var display = _truncate_path_to(label, avail)
            _ = painter.put_text(
                canvas, Point(name_x, top + i), display, row_attr,
            )
        # Bottom hint.
        _ = painter.put_text(
            canvas, Point(rect.a.x + 2, layout.hint_y),
            String(" Enter: jump  ESC: cancel "),
            hint_attr,
        )

    # --- events -----------------------------------------------------------

    def handle_key(mut self, event: Event) -> Bool:
        """Returns True iff consumed (always True while active)."""
        if not self.active:
            return False
        if event.kind != EVENT_KEY:
            return True
        var k = event.key
        if k == KEY_ESC:
            self.close()
            return True
        # While a submit is in flight, swallow everything but ESC so
        # the in-flight LSP response lands against a stable selection.
        if self.state == _STATE_PENDING:
            return True
        if k == KEY_ENTER:
            if self.selected < 0 or self.selected >= len(self.entries):
                return True
            var entry = self.entries[self.selected]
            self.selected_path = entry.path
            self.selected_line = entry.line
            self.selected_column = entry.column
            self.selected_name = entry.name
            self.submitted = True
            return True
        if picker_nav_key(k, len(self.entries), self.selected):
            self._user_navigated = True
            self._scroll_to_selection()
            return True
        # In chooser mode the entry list is locked, so any further
        # typing in the input field is swallowed. Letting the field
        # capture keys would scramble the visible chosen name without
        # any effect on the static list — confusing, never useful.
        if self._chooser_mode:
            return True
        var prev_query = self.query.text
        var r = self.query.handle_key(event)
        if not r.consumed:
            return True
        if r.changed:
            # Filter the new value down to identifier bytes only — the
            # query is interpolated into rg's regex, so leaving
            # punctuation (or worse, a leading ``-``) in place would let
            # the user accidentally write a regex / flag. This applies
            # to typed printables and pasted text alike.
            var sanitized = sanitize_symbol_query(self.query.text)
            if sanitized != self.query.text:
                self.query.set_text(sanitized)
            if self.query.text != prev_query:
                if self.state == _STATE_ERROR:
                    self.state = _STATE_IDLE
                    self.status_message = String("")
                self.restart_runner()
        return True

    def handle_mouse(mut self, event: Event, screen: Rect) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_MOUSE:
            return True
        var rect = self._rect(screen)
        var layout = _build_layout(rect)
        # Skip text-field mouse routing in chooser mode — the input is
        # frozen and the field isn't visibly painted, so capturing
        # clicks there would just move an invisible cursor.
        if not self._chooser_mode and self._input_rect.width() > 0 \
                and self.query.handle_mouse(event, self._input_rect):
            return True
        if event.pressed and not event.motion:
            if picker_wheel_scroll(
                event.button, self.scroll, len(self.entries),
                layout.list_height,
            ):
                return True
        if event.button != MOUSE_BUTTON_LEFT:
            return True
        if not event.pressed or event.motion:
            return True
        if not rect.contains(event.pos):
            return True
        if event.pos.y < layout.list_top \
                or event.pos.y >= layout.list_top + layout.list_height:
            return True
        var idx = self.scroll + (event.pos.y - layout.list_top)
        if idx < 0 or idx >= len(self.entries):
            return True
        if idx == self.selected:
            var entry = self.entries[idx]
            self.selected_path = entry.path
            self.selected_line = entry.line
            self.selected_column = entry.column
            self.selected_name = entry.name
            self.submitted = True
            return True
        self.selected = idx
        self._user_navigated = True
        return True

    def _scroll_to_selection(mut self):
        var visible = 16
        if self.selected < self.scroll:
            self.scroll = self.selected
        elif self.selected >= self.scroll + visible:
            self.scroll = self.selected - visible + 1


# --- helpers ---------------------------------------------------------------


def _eq_ci(a: String, b: String) -> Bool:
    """ASCII case-insensitive string equality. Used for the ``rank 0``
    (exact match) test in the picker's ordering — identifiers are
    ASCII per the rg regex, and rg's ``--smart-case`` is itself
    case-insensitive on all-lowercase queries, so a case-sensitive
    equality here would inconsistently exclude obvious matches."""
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    if len(ab) != len(bb):
        return False
    for i in range(len(ab)):
        var ca = Int(ab[i])
        var cb = Int(bb[i])
        if 0x41 <= ca and ca <= 0x5A: ca += 0x20
        if 0x41 <= cb and cb <= 0x5A: cb += 0x20
        if ca != cb:
            return False
    return True


def _query_has_upper(q: String) -> Bool:
    """True iff ``q`` contains any ASCII uppercase byte. Gates the
    smart-case promotion in ``_rank``: a capitalized query treats
    case-different hits as a second-tier bucket so 'Project'
    doesn't surface 'project' at the top of the list."""
    var b = q.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        if 0x41 <= c and c <= 0x5A:
            return True
    return False


def _rank(name: String, query: String) -> Int:
    """Picker-row sort priority. Lower wins.

    Smart-case promotion: when ``query`` contains any uppercase byte
    we treat it as case-sensitive, so a same-case hit beats a
    case-different one. All-lowercase queries skip the case-sensitive
    bucket pair and fall back to the plain case-insensitive ranking —
    same idiom rg's ``--smart-case`` uses on the underlying search.

    Ranks (lowest first):
    0 — case-sensitive exact (uppercase queries only)
    1 — case-sensitive startswith (uppercase queries only)
    2 — case-insensitive exact
    3 — case-insensitive startswith
    4 — case-insensitive substring (the rg regex floor)
    """
    if _query_has_upper(query):
        if name == query:
            return 0
        if starts_with(name, query):
            return 1
    if _eq_ci(name, query):
        return 2
    if starts_with_ci(name, query):
        return 3
    return 4


def _sort_entries_ranked(
    mut entries: List[FindSymbolMatch], query: String,
):
    """Reorder ``entries`` so exact matches lead, then startswith,
    then plain substring. Within each rank bucket, entries land in
    case-insensitive alphabetical order so the user sees a stable
    sweep regardless of which file rg happened to scan first.

    Two-pass: bucket-split (preserves insertion order), then a
    case-insensitive insertion sort inside each bucket. Bucket sizes
    are bounded by ``_ENTRIES_CAP`` (500), so the O(N²) insertion
    sort is comfortably under the per-frame budget.
    """
    var b0 = List[FindSymbolMatch]()
    var b1 = List[FindSymbolMatch]()
    var b2 = List[FindSymbolMatch]()
    var b3 = List[FindSymbolMatch]()
    var b4 = List[FindSymbolMatch]()
    for i in range(len(entries)):
        var r = _rank(entries[i].name, query)
        if r == 0:
            b0.append(entries[i])
        elif r == 1:
            b1.append(entries[i])
        elif r == 2:
            b2.append(entries[i])
        elif r == 3:
            b3.append(entries[i])
        else:
            b4.append(entries[i])
    _sort_bucket_alpha(b0)
    _sort_bucket_alpha(b1)
    _sort_bucket_alpha(b2)
    _sort_bucket_alpha(b3)
    _sort_bucket_alpha(b4)
    # Write back in place — reassigning ``entries`` would only rebind
    # the local parameter and the caller's list would stay unsorted.
    var w = 0
    for i in range(len(b0)):
        entries[w] = b0[i]
        w += 1
    for i in range(len(b1)):
        entries[w] = b1[i]
        w += 1
    for i in range(len(b2)):
        entries[w] = b2[i]
        w += 1
    for i in range(len(b3)):
        entries[w] = b3[i]
        w += 1
    for i in range(len(b4)):
        entries[w] = b4[i]
        w += 1


def _relativize(path: String, root: String) -> String:
    """If ``path`` lives under ``root``, return the suffix after the
    root + ``/`` separator. Otherwise return ``path`` unchanged.

    Used to format chooser-row labels: ``/Users/x/proj/foo/bar.py``
    becomes ``foo/bar.py`` so the dialog isn't dominated by the
    leading workspace prefix that's the same for every row anyway."""
    var rb = root.as_bytes()
    var pb = path.as_bytes()
    if len(rb) == 0 or len(pb) < len(rb):
        return path
    for i in range(len(rb)):
        if pb[i] != rb[i]:
            return path
    if len(pb) == len(rb):
        return path
    if pb[len(rb)] != 0x2F:   # '/'
        return path
    return String(StringSlice(unsafe_from_utf8=pb[len(rb) + 1:len(pb)]))


def _truncate_path_to(s: String, max_cols: Int) -> String:
    """Truncate ``s`` to at most ``max_cols`` cells, dropping bytes
    from the *front* and marking elision with a leading ``…``. Paths
    are most informative at their tail (the filename), so a head-
    elide keeps the meaningful end visible.

    Byte-length is used in place of ``display_columns`` because
    paths are almost always ASCII; a non-ASCII char will at worst
    over-advance by a cell, which is fine for a display label."""
    if max_cols <= 0:
        return String("")
    var b = s.as_bytes()
    if len(b) <= max_cols:
        return s
    if max_cols == 1:
        return String("…")
    var start = len(b) - max_cols + 1
    return String("…") \
        + String(StringSlice(unsafe_from_utf8=b[start:len(b)]))


def _sort_bucket_alpha(mut bucket: List[FindSymbolMatch]):
    """In-place case-insensitive insertion sort on entry name."""
    for i in range(1, len(bucket)):
        var j = i
        while j > 0 and ci_less(bucket[j].name, bucket[j - 1].name):
            var tmp = bucket[j]
            bucket[j] = bucket[j - 1]
            bucket[j - 1] = tmp
            j -= 1


def _list_contains(haystack: List[String], needle: String) -> Bool:
    """Linear membership check. Used for the symbol-name dedupe set;
    capped by ``_ENTRIES_CAP`` so the O(N²) total cost stays bounded."""
    for i in range(len(haystack)):
        if haystack[i] == needle:
            return True
    return False


def _is_ident_byte(b: UInt8) -> Bool:
    var c = Int(b)
    return (0x30 <= c and c <= 0x39) \
        or (0x41 <= c and c <= 0x5A) \
        or (0x61 <= c and c <= 0x7A) \
        or c == 0x5F


def _extract_identifier(line: String, col_1based: Int) -> String:
    """Walk left + right from ``col_1based`` (rg's 1-based byte column)
    while the byte is in ``[A-Za-z0-9_]``. Returns the full identifier
    sitting at that position, or an empty string if the column doesn't
    land on an identifier byte (e.g. line was truncated past the
    column, or the match started on something unusual).
    """
    var b = line.as_bytes()
    if col_1based <= 0 or col_1based > len(b):
        return String("")
    var start = col_1based - 1
    if not _is_ident_byte(b[start]):
        return String("")
    while start > 0 and _is_ident_byte(b[start - 1]):
        start -= 1
    var end = col_1based - 1
    while end < len(b) and _is_ident_byte(b[end]):
        end += 1
    return String(StringSlice(unsafe_from_utf8=b[start:end]))


def _parse_rg_match_line(
    line: String,
) -> Optional[Tuple[String, Int, Int, String]]:
    """Decode one rg ``--no-heading --line-number --column`` row
    (``path:line:col:matched-line-text``) into
    ``(path, line, column, text)``. Returns ``None`` for any row
    that doesn't have three colons followed by integers.

    Path parsing tolerates colons inside the path itself (Windows
    drive letters etc.) by anchoring on the *last three* colons
    whose right-hand sides parse as ``digits:digits:``.
    """
    var b = line.as_bytes()
    if len(b) == 0:
        return Optional[Tuple[String, Int, Int, String]]()
    var i = 0
    while i < len(b):
        if b[i] == 0x3A:
            var j = i + 1
            while j < len(b) and Int(b[j]) >= 0x30 and Int(b[j]) <= 0x39:
                j += 1
            if j > i + 1 and j < len(b) and b[j] == 0x3A:
                var k = j + 1
                while k < len(b) and Int(b[k]) >= 0x30 and Int(b[k]) <= 0x39:
                    k += 1
                if k > j + 1 and k < len(b) and b[k] == 0x3A:
                    var path = String(StringSlice(unsafe_from_utf8=b[0:i]))
                    var line_no = _parse_int(b, i + 1, j)
                    var col_no = _parse_int(b, j + 1, k)
                    if line_no <= 0 or col_no <= 0:
                        return Optional[Tuple[String, Int, Int, String]]()
                    var text = String(StringSlice(
                        unsafe_from_utf8=b[k + 1:len(b)],
                    ))
                    return Optional[Tuple[String, Int, Int, String]](
                        (path, line_no, col_no, text),
                    )
        i += 1
    return Optional[Tuple[String, Int, Int, String]]()


def _parse_int(b: Span[UInt8, _], start: Int, end: Int) -> Int:
    var n = 0
    var any = False
    for p in range(start, end):
        var v = Int(b[p])
        if v < 0x30 or v > 0x39:
            return -1
        n = n * 10 + (v - 0x30)
        any = True
    if not any:
        return -1
    return n


def sanitize_symbol_query(query: String) -> String:
    """Strip everything that isn't an identifier byte.

    The query is interpolated into rg's regex, so leaving punctuation
    in place would let the user accidentally write something rg
    interprets as a regex (or, worse, a flag — a leading ``-`` would
    be especially trouble). We're looking for symbol names; dropping
    everything else is the right semantics for the input field.
    """
    var b = query.as_bytes()
    var out = List[UInt8]()
    for i in range(len(b)):
        if _is_ident_byte(b[i]):
            out.append(b[i])
    if len(out) == 0:
        return String("")
    return String(StringSlice(ptr=out.unsafe_ptr(), length=len(out)))
