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

from .canvas import Canvas
from .cell import Cell
from .colors import Attr, BLACK, BLUE, LIGHT_GRAY, RED, WHITE, YELLOW
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_BACKSPACE, KEY_ENTER, KEY_ESC,
    MOD_ALT, MOD_CTRL,
    MOUSE_BUTTON_LEFT,
)
from .geometry import Point, Rect
from .lsp import LspProcess
from .picker_input import picker_nav_key, picker_wheel_scroll
from .posix import alloc_zero_buffer, poll_stdin, read_into
from .text_field import text_field_clipboard_key
from .window import paint_drop_shadow


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

    fn __init__(out self):
        self.proc = LspProcess()
        self.active = False
        self._buf = List[UInt8]()
        self._scan_pos = 0

    fn is_active(self) -> Bool:
        return self.active

    fn cancel(mut self):
        """Stop the running child (if any) and reset state. Idempotent."""
        if self.active:
            self.proc.terminate()
        self.active = False
        self._buf = List[UInt8]()
        self._scan_pos = 0

    fn start(mut self, query: String, root: String) -> Bool:
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

    fn tick(mut self) -> List[Tuple[String, Int, Int, String]]:
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
    var query: String
    var root: String                 # project root the runner is rooted at
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

    fn __init__(out self):
        self.active = False
        self.query = String("")
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

    fn open(mut self, var root: String):
        self.active = True
        self.query = String("")
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

    fn close(mut self):
        self.active = False
        self.query = String("")
        self.root = String("")
        self.entries = List[FindSymbolMatch]()
        self.seen_names = List[String]()
        self.selected = 0
        self.scroll = 0
        self.submitted = False
        self.state = _STATE_IDLE
        self.status_message = String("")
        self.runner.cancel()

    fn set_pending(mut self, var msg: String):
        self.state = _STATE_PENDING
        self.status_message = msg^

    fn set_error(mut self, var msg: String):
        self.state = _STATE_ERROR
        self.status_message = msg^

    fn take_submitted(mut self) -> Bool:
        var s = self.submitted
        self.submitted = False
        return s

    # --- background pump --------------------------------------------------

    fn tick(mut self):
        """Drain one batch of rg output and merge new symbol names
        into the entry list. Called every paint frame by the host
        (cheap when the runner is idle).
        """
        if not self.active or not self.runner.is_active():
            return
        var rows = self.runner.tick()
        for i in range(len(rows)):
            if len(self.entries) >= _ENTRIES_CAP:
                # Hit the cap — stop draining and silence the runner
                # so we don't keep paying for parse work the user
                # will never see.
                self.runner.cancel()
                return
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

    fn restart_runner(mut self):
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
        self.runner.cancel()
        if len(self.query.as_bytes()) < _MIN_QUERY_LEN:
            return
        if len(self.root.as_bytes()) == 0:
            return
        _ = self.runner.start(self.query, self.root)

    # --- geometry ---------------------------------------------------------

    fn _rect(self, screen: Rect) -> Rect:
        var width = 80
        var height = 22
        if width > screen.b.x - 4: width = screen.b.x - 4
        if height > screen.b.y - 4: height = screen.b.y - 4
        var x = (screen.b.x - width) // 2
        var y = (screen.b.y - height) // 2
        return Rect(x, y, x + width, y + height)

    fn _list_top(self, rect: Rect) -> Int:
        return rect.a.y + 3

    fn _list_height(self, rect: Rect) -> Int:
        var h = (rect.b.y - 1) - self._list_top(rect)
        if h < 0:
            return 0
        return h

    fn is_input_at(self, pos: Point, screen: Rect) -> Bool:
        if not self.active:
            return False
        var rect = self._rect(screen)
        return Rect(rect.a.x + 2, rect.a.y + 1, rect.b.x - 1, rect.a.y + 2).contains(pos)

    # --- paint ------------------------------------------------------------

    fn paint(self, mut canvas: Canvas, screen: Rect):
        if not self.active:
            return
        var bg          = Attr(BLACK,  LIGHT_GRAY)
        var title_attr  = Attr(WHITE,  BLUE)
        var sel_attr    = Attr(BLACK,  YELLOW)
        var hint_attr   = Attr(BLUE,   LIGHT_GRAY)
        var error_attr  = Attr(RED,    LIGHT_GRAY)
        var rect = self._rect(screen)
        paint_drop_shadow(canvas, rect)
        canvas.fill(rect, String(" "), bg)
        canvas.draw_box(rect, bg, False)
        var title = String(" Find Symbol ")
        var tx = rect.a.x + (rect.width() - len(title.as_bytes())) // 2
        _ = canvas.put_text(Point(tx, rect.a.y), title, title_attr)
        var label = String(" Find: ")
        _ = canvas.put_text(
            Point(rect.a.x + 2, rect.a.y + 1), label, bg, rect.b.x - 1,
        )
        var qx = rect.a.x + 2 + len(label.as_bytes())
        _ = canvas.put_text(
            Point(qx, rect.a.y + 1), self.query, bg, rect.b.x - 1,
        )
        var cur = qx + len(self.query.as_bytes())
        if cur < rect.b.x - 1:
            canvas.set(cur, rect.a.y + 1, Cell(String(" "), Attr(LIGHT_GRAY, BLACK), 1))
        var top = self._list_top(rect)
        var h = self._list_height(rect)
        # Status / placeholder.
        if self.state == _STATE_PENDING:
            _ = canvas.put_text(
                Point(rect.a.x + 2, top),
                self.status_message,
                hint_attr, rect.b.x - 1,
            )
        elif self.state == _STATE_ERROR:
            _ = canvas.put_text(
                Point(rect.a.x + 2, top),
                self.status_message,
                error_attr, rect.b.x - 1,
            )
        elif len(self.query.as_bytes()) < _MIN_QUERY_LEN:
            _ = canvas.put_text(
                Point(rect.a.x + 2, top),
                String("Type at least 2 letters of a symbol name."),
                hint_attr, rect.b.x - 1,
            )
        elif len(self.entries) == 0:
            var msg: String
            if self.runner.is_active():
                msg = String("Searching…")
            else:
                msg = String("No matches.")
            _ = canvas.put_text(
                Point(rect.a.x + 2, top), msg, hint_attr, rect.b.x - 1,
            )
        # Listing — paints regardless of state so a leftover error
        # message above the list doesn't hide already-collected hits.
        for i in range(h):
            var idx = self.scroll + i
            if idx >= len(self.entries):
                break
            var entry = self.entries[idx]
            var is_sel = (idx == self.selected)
            var row_attr = sel_attr if is_sel else bg
            canvas.fill(
                Rect(rect.a.x + 1, top + i, rect.b.x - 1, top + i + 1),
                String(" "), row_attr,
            )
            _ = canvas.put_text(
                Point(rect.a.x + 2, top + i),
                entry.name, row_attr, rect.b.x - 1,
            )
            # Intentionally no path column: ``entry.path`` is the
            # location of the *first textual occurrence* (a usage,
            # almost always), not the definition the LSP will
            # eventually take us to. Showing it would mislead the
            # user about where the symbol actually lives.
        # Bottom hint.
        _ = canvas.put_text(
            Point(rect.a.x + 2, rect.b.y - 1),
            String(" Enter: jump  ESC: cancel "),
            hint_attr, rect.b.x - 1,
        )

    # --- events -----------------------------------------------------------

    fn handle_key(mut self, event: Event) -> Bool:
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
            self._scroll_to_selection()
            return True
        var prev_query = self.query
        if k == KEY_BACKSPACE:
            var qb = self.query.as_bytes()
            if len(qb) > 0:
                self.query = String(StringSlice(
                    unsafe_from_utf8=qb[:len(qb) - 1],
                ))
        else:
            var clip = text_field_clipboard_key(event, self.query)
            if clip.consumed:
                # Paste lands raw; strip non-identifier bytes so rg's
                # regex doesn't see ``-``, ``;`` etc.
                self.query = sanitize_symbol_query(self.query)
            else:
                if (event.mods & MOD_CTRL) != 0 \
                        or (event.mods & MOD_ALT) != 0:
                    return True
                if UInt32(0x20) <= k and k < UInt32(0x7F):
                    # Filter to identifier bytes only — the rg regex
                    # would otherwise interpret punctuation as meta
                    # characters or, for a leading ``-``, as a flag.
                    if _is_ident_byte(UInt8(Int(k))):
                        self.query = self.query + chr(Int(k))
        if self.query != prev_query:
            # Editing reverts an error state (the message would
            # otherwise hang around stale).
            if self.state == _STATE_ERROR:
                self.state = _STATE_IDLE
                self.status_message = String("")
            self.restart_runner()
        return True

    fn handle_mouse(mut self, event: Event, screen: Rect) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_MOUSE:
            return True
        var rect = self._rect(screen)
        if event.pressed and not event.motion:
            if picker_wheel_scroll(
                event.button, self.scroll, len(self.entries),
                self._list_height(rect),
            ):
                return True
        if event.button != MOUSE_BUTTON_LEFT:
            return True
        if not event.pressed or event.motion:
            return True
        if not rect.contains(event.pos):
            return True
        var top = self._list_top(rect)
        var h = self._list_height(rect)
        if event.pos.y < top or event.pos.y >= top + h:
            return True
        var idx = self.scroll + (event.pos.y - top)
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
        return True

    fn _scroll_to_selection(mut self):
        var visible = 16
        if self.selected < self.scroll:
            self.scroll = self.selected
        elif self.selected >= self.scroll + visible:
            self.scroll = self.selected - visible + 1


# --- helpers ---------------------------------------------------------------


fn _list_contains(haystack: List[String], needle: String) -> Bool:
    """Linear membership check. Used for the symbol-name dedupe set;
    capped by ``_ENTRIES_CAP`` so the O(N²) total cost stays bounded."""
    for i in range(len(haystack)):
        if haystack[i] == needle:
            return True
    return False


fn _is_ident_byte(b: UInt8) -> Bool:
    var c = Int(b)
    return (0x30 <= c and c <= 0x39) \
        or (0x41 <= c and c <= 0x5A) \
        or (0x61 <= c and c <= 0x7A) \
        or c == 0x5F


fn _extract_identifier(line: String, col_1based: Int) -> String:
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


fn _parse_rg_match_line(
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


fn _parse_int(b: Span[UInt8, _], start: Int, end: Int) -> Int:
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


fn sanitize_symbol_query(query: String) -> String:
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
