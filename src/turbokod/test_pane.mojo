"""Bottom-docked test runner pane: pytest on a real pty, rendered
through the ``Vt`` emulator.

Unlike the run/debug pane (``DebugPane``, pipe-backed ``TextLog``), the
test child runs on a controlling pty (``PtyProcess`` → ``tk_pty_spawn``)
so it sees ``isatty(0) == True``: pytest auto-detects color, sizes its
output to the actual pane width (and reflows on a SIGWINCH when the pane
is resized), and its live progress line — which uses ``\\r`` + erase
sequences a plain ``TextLog`` can't interpret — renders correctly
because the ``Vt`` emulator handles those.

The grid view (paint, selection, copy, scrollback, key→pty / mouse→pty
encoding) is the same machinery the shell terminal uses, shared via
``terminal_view.GridSelection`` + ``paint_grid``. On top of that the
pane adds the test-runner concerns the shell terminal doesn't have:
spawning a fixed command, surfacing the child's exit code in the title,
clickable ``File "<path>", line N`` / ``<path>:<N>`` traceback links,
and a Stop / Re-run / Clear command strip.

UI intents flow back to ``Desktop`` through the same pattern as the
other panes: ``consume_command_id`` for chrome clicks and
``consume_open_request`` for a clicked traceback link, both polled and
cleared by the host each tick.
"""

from std.collections.list import List
from std.ffi import external_call

from .canvas import Canvas
from .clipboard import clipboard_copy
from .colors import (
    Attr, LIGHT_BLUE, PANE_BG, STYLE_UNDERLINE, WHITE,
)
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE, EVENT_PASTE,
    KEY_ESC, KEY_PAGEDOWN, KEY_PAGEUP,
    MOD_META, MOD_NONE, MOD_SHIFT,
    MOUSE_BUTTON_LEFT, MOUSE_BUTTON_NONE,
    MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .geometry import Point, Rect
from .output_links import (
    OutputLink, extract_path_line_links, extract_python_traceback_links,
    extract_url_links,
)
from .painter import Painter
from .posix import (
    alloc_zero_buffer, close_fd, exit_code_from_status, poll_stdin,
    read_into, untrack_child, waitpid_nohang,
)
from .pty import PtyProcess
from .terminal_view import GridSelection, encode_key, paint_grid
from .vt import Vt
from .window import (
    BottomDockedPanel, TitleCommand,
    handle_bottom_dock_chrome_mouse, handle_bottom_dock_esc,
    paint_bottom_dock_chrome,
)


comptime _RAW_CAP = 2_000_000
"""Cap on the captured output stream used for lossless resize replay
(see ``_capture`` / ``_rebuild_vt``). ~2 MB covers any realistic test
run; past it we stop capturing and resize falls back to the destructive
``Vt.resize`` (a shell-terminal-style truncate) rather than growing the
buffer without bound."""


comptime TEST_STOP          = String("test:stop")
comptime TEST_RERUN         = String("test:rerun")
comptime TEST_CLEAR_OUTPUT  = String("test:clear_output")
comptime TEST_PANE_CLOSE    = String("test:pane_close")
"""Pending-command ids dispatched to the host. ``TEST_PANE_CLOSE`` is the
window-style ``[■]`` close button; the other three are the title strip.
Defined here (the pane owns its command vocabulary) and imported by
``Desktop`` for the dispatch side."""


struct TestPane(Copyable, Movable):
    """Test runner output pane backed by a pty + ``Vt`` emulator."""
    var visible: Bool
    var focused: Bool
    var dock: BottomDockedPanel

    var pty: PtyProcess
    """The test child on a controlling pty. Spawned by ``run``; a closed
    process is left as an inert sentinel until the next ``run``."""
    var vt: Vt
    """Terminal emulator state — the pane body is this grid, top-left
    anchored. Resized (+ ``pty.set_winsize``) whenever the body rect
    changes so pytest reflows to the pane width."""
    var sel: GridSelection
    """Mouse selection over the grid, shared with the shell terminal."""

    # --- run state -----------------------------------------------------
    var started: Bool
    """True from the first ``run`` until the pane is reset. With
    ``exited`` it forms the lifecycle: not-started → running → exited."""
    var exited: Bool
    var exit_code: Int
    var _eof: Bool
    """Latched once a read returns EOF (child closed its end). We then
    poll ``waitpid`` over subsequent ticks until it reports the exit
    status — EOF on the master can momentarily precede the child's
    actual exit."""
    var last_command: String
    """Pretty argv of the in-flight / last run, for the ``$`` banner."""

    # --- lossless-resize replay ----------------------------------------
    var _raw: List[UInt8]
    """Every byte fed to the emulator this run (banner + child output +
    exit banner). ``Vt.resize`` is destructive on shrink — it discards
    columns/rows past the new size — and the test pane's static post-exit
    output has no live child to repaint it, so shrinking then growing
    would lose content. Instead we replay this stream into a fresh ``Vt``
    on a settled size change (``_rebuild_vt``), which re-wraps losslessly
    to the new width. Bounded by ``_RAW_CAP``."""
    var _raw_overflow: Bool
    """Set once ``_raw`` would exceed ``_RAW_CAP``; thereafter capture
    stops and resize falls back to the destructive ``Vt.resize``."""

    # --- link bookkeeping (rebuilt each paint) -------------------------
    var _last_links: List[OutputLink]
    var pending_open_path: String
    var pending_open_line: Int    # 1-based; 0 with empty path = none
    var pending_open_url: String  # http(s) link to open in the browser; "" = none

    def __init__(out self):
        self.visible = False
        self.focused = False
        self.dock = BottomDockedPanel(preferred_height=14)
        self.dock.close_button_id = TEST_PANE_CLOSE
        self.pty = PtyProcess()
        # Initial 80×24 — the first paint resizes to the real body and
        # the child gets a SIGWINCH. A run before the first paint spawns
        # at this size and reflows on the next frame.
        self.vt = Vt(80, 24)
        self.sel = GridSelection()
        self.started = False
        self.exited = False
        self.exit_code = 0
        self._eof = False
        self.last_command = String("")
        self._raw = List[UInt8]()
        self._raw_overflow = False
        self._last_links = List[OutputLink]()
        self.pending_open_path = String("")
        self.pending_open_line = 0
        self.pending_open_url = String("")

    def __copyinit__(mut self, copy: Self):
        self.visible = copy.visible
        self.focused = copy.focused
        self.dock = copy.dock
        # ``PtyProcess`` isn't safely copyable (the master fd is a kernel
        # handle). Production keeps the pane singleton on ``Desktop``;
        # copies are only Mojo value-semantics in tests. Reset to a fresh
        # inert process so neither destructor double-closes.
        self.pty = PtyProcess()
        self.vt = copy.vt
        self.sel = copy.sel
        self.started = copy.started
        self.exited = copy.exited
        self.exit_code = copy.exit_code
        self._eof = copy._eof
        self.last_command = copy.last_command
        self._raw = copy._raw
        self._raw_overflow = copy._raw_overflow
        self._last_links = copy._last_links
        self.pending_open_path = copy.pending_open_path
        self.pending_open_line = copy.pending_open_line
        self.pending_open_url = copy.pending_open_url

    # --- chrome forwarders ---------------------------------------------

    def is_minimized(self) -> Bool:
        return self.dock.is_minimized()

    def is_maximized(self) -> Bool:
        return self.dock.is_maximized()

    def is_resizing(self) -> Bool:
        return self.dock.is_resizing()

    def is_on_resize_edge(self, pos: Point, panel: Rect) -> Bool:
        if not self.visible:
            return False
        return self.dock.is_on_resize_edge(pos, panel)

    def consume_command_id(mut self) -> String:
        return self.dock.consume_command_id()

    def consume_open_request(mut self) -> Tuple[String, Int]:
        """Returns ``(path, line)`` (1-based) for a freshly clicked
        traceback link, or ``("", 0)`` when nothing is pending. The host
        calls ``open_file_at`` with ``line - 1`` (0-based rows)."""
        var path = self.pending_open_path
        var line = self.pending_open_line
        self.pending_open_path = String("")
        self.pending_open_line = 0
        return (path^, line)

    def consume_open_url(mut self) -> String:
        """Return a freshly clicked output URL (and clear the latch), or
        ``""`` when nothing is pending. The host hands it to ``open_url``."""
        var u = self.pending_open_url
        self.pending_open_url = String("")
        return u^

    def running(self) -> Bool:
        return self.started and not self.exited

    # --- lifecycle -----------------------------------------------------

    def run(
        mut self, program: String, args: List[String], cwd: String,
    ) raises:
        """Spawn ``program`` + ``args`` on a fresh pty in ``cwd``. Kills
        any prior child first and resets the grid. The child sees a real
        TTY, so no ``--color=yes`` / ``COLUMNS`` plumbing is needed."""
        self.pty.terminate()
        # Preserve the current grid size across re-runs (the last paint
        # sized it to the pane); a never-painted pane keeps the 80×24
        # default and reflows on the first frame.
        var c = self.vt.cols
        var r = self.vt.rows
        self.vt = Vt(c, r)
        self.sel.clear()
        self._raw = List[UInt8]()
        self._raw_overflow = False
        self.exited = False
        self._eof = False
        self.exit_code = 0
        self.started = True
        var cmd = program
        for k in range(len(args)):
            cmd = cmd + String(" ") + args[k]
        self.last_command = cmd
        # Echo the command as a banner — a pty child doesn't echo its own
        # argv, and the user wants to see what ran.
        self._emit(String("$ ") + cmd + String("\r\n"))
        var argv = List[String]()
        argv.append(program)
        for k in range(len(args)):
            argv.append(args[k])
        self.pty = PtyProcess.spawn(
            argv, cwd=cwd, cols=self.vt.cols, rows=self.vt.rows,
        )

    def stop(mut self):
        """Stop button / explicit stop: SIGTERM the child and pin the
        pane into the exited state so the output stays readable."""
        if self.running():
            self.pty.terminate()
            self._emit(String("\r\n[tests stopped]\r\n"))
            self.exited = True
            self.exit_code = 128 + 15  # SIGTERM, matches exit_code_from_status

    def close(mut self):
        """Hide the pane and kill any in-flight child. Resets the
        lifecycle so ``running()`` reads False (the host drives
        visibility off ``running() or held``)."""
        self.visible = False
        self.focused = False
        self.pty.terminate()
        self.started = False
        self.exited = False

    def clear(mut self):
        """Wipe the grid (Clear button). Doesn't kill a running child —
        new output keeps streaming into the fresh grid. Also drops the
        replay buffer so a later resize doesn't bring the cleared output
        back."""
        var c = self.vt.cols
        var r = self.vt.rows
        self.vt = Vt(c, r)
        self.sel.clear()
        self._raw = List[UInt8]()
        self._raw_overflow = False

    # --- per-tick drain ------------------------------------------------

    def tick(mut self):
        """Drain the pty into the emulator, flush its side-effects, and
        detect child exit. Called by ``Desktop`` each frame."""
        if not self.started or self.exited:
            return
        if self.pty.master_fd >= 0:
            var scratch = alloc_zero_buffer(4096)
            var total = 0
            # 64 KB cap per tick so a flood (a test dumping a huge log)
            # doesn't lock the UI — the rest drains next frame.
            while poll_stdin(self.pty.master_fd, Int32(0)) and total < 65536:
                var n = read_into(self.pty.master_fd, scratch, 4096)
                if n <= 0:
                    if n == 0:
                        # EOF — the child closed its end. Reap below.
                        self._eof = True
                        self.pty.alive = False
                    break
                var span = Span[UInt8, origin_of(scratch)](
                    unsafe_ptr=scratch.unsafe_ptr(), length=n,
                )
                self.vt.feed(span)
                self._capture(scratch.unsafe_ptr(), n)
                total += n
        # Flush emulator side-effects (DSR/DA replies, OSC 52 clipboard).
        var reply = self.vt.take_reply()
        if len(reply.as_bytes()) > 0:
            self._write_to_pty(reply^)
        var clip = self.vt.take_clipboard()
        if len(clip.as_bytes()) > 0:
            clipboard_copy(clip)
        # Once EOF is seen, reap the child to harvest its exit code. The
        # reap can lag a tick or two behind EOF; keep trying until
        # ``waitpid`` reports the pid.
        if self._eof and self.pty.pid > 0:
            var pair = waitpid_nohang(self.pty.pid)
            if Int(pair[0]) == Int(self.pty.pid):
                self.exit_code = exit_code_from_status(Int(pair[1]))
                untrack_child(self.pty.pid)
                self.exited = True
                var tag: String
                if self.exit_code == 0:
                    tag = String("\r\n[tests passed]\r\n")
                else:
                    tag = String("\r\n[tests exited with ") \
                        + String(self.exit_code) + String("]\r\n")
                self._emit(tag)
                if self.pty.master_fd >= 0:
                    _ = close_fd(self.pty.master_fd)
                    self.pty.master_fd = -1

    # --- title strip + chrome commands ---------------------------------

    def build_commands(self) -> List[TitleCommand]:
        """Stop (while running) + Re-run + Clear. After exit there's
        nothing to stop, so Stop drops off. ``TEST_RERUN`` replays the
        last command; the host terminates any in-flight child first."""
        var out = List[TitleCommand]()
        if self.running():
            out.append(TitleCommand(String("[■ Stop]"), TEST_STOP))
        out.append(TitleCommand(String("[↻ Re-run]"), TEST_RERUN))
        out.append(TitleCommand(String("[⌫ Clear]"), TEST_CLEAR_OUTPUT))
        return out^

    # --- paint ---------------------------------------------------------

    def paint(mut self, mut canvas: Canvas, panel: Rect):
        if not self.visible or panel.is_empty():
            return
        var bg = Attr(WHITE, PANE_BG)
        var painter = Painter(panel)
        painter.fill(canvas, panel, String(" "), bg)
        # Reset link bookkeeping — only what's on screen this frame
        # counts for click hit-testing.
        self._last_links = List[OutputLink]()
        # Commands change with run state, so rebuild every frame.
        self.dock.commands = self.build_commands()
        var title: String
        if self.exited:
            if self.exit_code == 0:
                title = String("Tests — passed")
            else:
                title = String("Tests — failed (") \
                    + String(self.exit_code) + String(")")
        elif self.started:
            title = String("Tests — running")
        else:
            title = String("Tests")
        var body = paint_bottom_dock_chrome(
            canvas, painter, panel, title, self.focused, self.dock,
            String(""),
        )
        if body.is_empty():
            self.sel._last_body = Rect.empty()
            return
        var bw = body.width()
        var bh = body.height()
        if bw <= 0 or bh <= 0:
            self.sel._last_body = Rect.empty()
            return
        # Sync grid size to the body. ``Vt.resize`` truncates on shrink,
        # which would lose the static post-exit output (nothing repaints
        # it), so instead we replay the captured stream into a fresh grid
        # — the emulator re-wraps to the new width, so a shrink-then-grow
        # round-trips losslessly. ``_raw`` is the source of truth, so
        # this is safe to do every frame (incl. during a resize drag);
        # ``_raw_overflow`` falls back to the cheap destructive resize.
        if bw != self.vt.cols or bh != self.vt.rows:
            if self._raw_overflow:
                self.vt.resize(bw, bh)
            else:
                self._rebuild_vt(bw, bh)
            if self.pty.alive:
                _ = self.pty.set_winsize(bw, bh)
        self.sel._last_body = body
        # Grid + selection overlay + cursor caret (shared with the shell
        # terminal). The caret only shows while running so an exited
        # pane reads as static output.
        paint_grid(
            canvas, painter, self.vt, self.sel, body,
            self.focused and self.running(),
        )
        # Traceback-link overlay: scan each on-screen row's text for
        # ``File "...", line N`` / ``path:N`` spans, underline them, and
        # record the screen rects for click hit-testing. Cell offsets
        # from the scanners are codepoint columns, matching the grid's
        # one-cell-per-column layout (link text is ASCII).
        var link_attr = Attr(LIGHT_BLUE, PANE_BG, STYLE_UNDERLINE)
        for r in range(self.vt.rows):
            var line = self._row_text(r)
            if len(line.as_bytes()) == 0:
                continue
            var hits = extract_python_traceback_links(line)
            hits.extend(extract_path_line_links(line))
            hits.extend(extract_url_links(line))
            for h in range(len(hits)):
                var hit = hits[h]
                var x0 = body.a.x + hit.cell_start
                var x1 = body.a.x + hit.cell_end
                if x0 < body.a.x:
                    x0 = body.a.x
                if x1 > body.b.x:
                    x1 = body.b.x
                if x1 <= x0:
                    continue
                var line_y = body.a.y + r
                for x in range(x0, x1):
                    painter.set_attr(canvas, x, line_y, link_attr)
                self._last_links.append(OutputLink(
                    line_y, x0, x1, hit.path, hit.line, hit.is_url,
                ))

    def _row_text(self, r: Int) -> String:
        """On-screen row ``r`` as a String (view-aware so a scrolled-back
        row scans its historical text). Trailing spaces trimmed."""
        var row_bytes = List[UInt8]()
        for c in range(self.vt.cols):
            var g = self.vt.view_cell_at(r, c).glyph.as_bytes()
            for k in range(len(g)):
                row_bytes.append(g[k])
        var end = len(row_bytes)
        while end > 0 and row_bytes[end - 1] == 0x20:
            end -= 1
        if end == 0:
            return String("")
        return String(StringSpan(unsafe_from_utf8=Span(unsafe_ptr=row_bytes.unsafe_ptr(), length=end)))

    # --- copy / selection delegates ------------------------------------

    def has_selection(self) -> Bool:
        return self.sel.has_selection()

    def selected_text(self) -> String:
        return self.sel.selected_text(self.vt)

    def copy_selection_to_clipboard(self) -> Bool:
        return self.sel.copy_to_clipboard(self.vt)

    # --- mouse ---------------------------------------------------------

    def handle_mouse(
        mut self, event: Event, panel: Rect, allow_resize: Bool = True,
    ) -> Bool:
        if event.kind != EVENT_MOUSE:
            return False
        # Chrome wins first — close button, resize edge, title commands.
        var cr = handle_bottom_dock_chrome_mouse(
            event, panel, self.dock, allow_resize,
        )
        if cr.consumed:
            if cr.focus_request:
                self.focused = True
            return True
        # In-flight drag selection keeps consuming past the body edge.
        if self.sel.sel_dragging:
            if event.button == MOUSE_BUTTON_LEFT and not event.pressed:
                self.sel.end_drag(self.vt, event.pos)
                return True
            if event.motion:
                self.sel.extend_drag(self.vt, event.pos)
                return True
        if not panel.contains(event.pos):
            if event.button != MOUSE_BUTTON_NONE \
                    and event.pressed and not event.motion:
                self.focused = False
            return False
        # Wheel shifts the scrollback view (the body-relative check above
        # already excluded chrome rows).
        if event.button == MOUSE_WHEEL_UP or event.button == MOUSE_WHEEL_DOWN:
            if not event.pressed:
                return True
            self.focused = True
            var dir = 3 if event.button == MOUSE_WHEEL_UP else -3
            self.vt.scroll_view_by(dir)
            return True
        if event.button == MOUSE_BUTTON_LEFT and event.pressed \
                and not event.motion:
            self.focused = True
            # Link hit-test first — clicking a ``File "...", line N`` span
            # opens the file, a ``http(s)://`` span the browser, rather
            # than starting a selection.
            for li in range(len(self._last_links)):
                var link = self._last_links[li]
                if event.pos.y == link.y \
                        and event.pos.x >= link.x_start \
                        and event.pos.x < link.x_end:
                    if link.is_url:
                        self.pending_open_url = link.path
                    else:
                        self.pending_open_path = link.path
                        self.pending_open_line = link.line
                    return True
            # Double-click → word, triple → line, else cell drag.
            if event.click_count >= 3:
                self.sel.select_line_at(self.vt, event.pos)
                return True
            if event.click_count == 2:
                self.sel.select_word_at(self.vt, event.pos)
                return True
            self.sel.begin_drag(self.vt, event.pos)
            return True
        return True

    # --- keys ----------------------------------------------------------

    def handle_key(mut self, event: Event) -> Bool:
        if not self.focused:
            return False
        if event.kind == EVENT_PASTE:
            if self.vt.bracketed_paste:
                self._write_to_pty(
                    String("\x1b[200~") + event.text + String("\x1b[201~")
                )
            else:
                self._write_to_pty(event.text)
            return True
        if event.kind != EVENT_KEY:
            return False
        # Decline Cmd+W so it falls through to the global pane-close
        # binding (same as the shell terminal).
        if event.key == UInt32(ord("w")) and event.mods == MOD_META:
            return False
        # ESC steps the chrome ladder (max → normal → min / dismiss).
        # Forward to the child only if the chrome doesn't consume it —
        # rare for a test runner, but keeps e.g. an interactive ``--pdb``
        # session usable.
        if event.key == KEY_ESC and event.mods == MOD_NONE:
            if handle_bottom_dock_esc(self.dock):
                return True
            self._write_to_pty(String("\x1b"))
            return True
        # Shift+PgUp/PgDn → scrollback.
        if event.key == KEY_PAGEUP and (event.mods & MOD_SHIFT) != 0:
            self.vt.scroll_view_by(self.vt.rows - 2)
            return True
        if event.key == KEY_PAGEDOWN and (event.mods & MOD_SHIFT) != 0:
            self.vt.scroll_view_by(-(self.vt.rows - 2))
            return True
        # Cmd+C copies an active selection; otherwise fall through so the
        # child gets a real Ctrl+C (interrupt the test run).
        if event.key == UInt32(ord("c")) and event.mods == MOD_META \
                and self.sel.sel_active:
            _ = self.copy_selection_to_clipboard()
            self.sel.clear()
            return True
        if self.sel.sel_active:
            self.sel.sel_active = False
        # Typing snaps back to the live tail.
        if self.vt.view_offset != 0:
            self.vt.reset_view()
        # Forward the keystroke to the child (Ctrl+C, ``q`` to quit a
        # pager pytest spawned, pdb input, …). No-op once the child has
        # exited (``_write_to_pty`` guards on a closed fd).
        var encoded = encode_key(
            event.key, event.mods, self.vt.app_cursor_keys,
        )
        if len(encoded.as_bytes()) > 0:
            self._write_to_pty(encoded^)
            return True
        return False

    def _write_to_pty(self, payload: String):
        if not self.pty.alive or self.pty.master_fd < 0:
            return
        var bytes = payload.as_bytes()
        var n = len(bytes)
        if n == 0:
            return
        var sent = 0
        while sent < n:
            var rc = self.pty.write_bytes(bytes.unsafe_ptr().unsafe_offset(sent), n - sent)
            if rc < 0:
                return  # EPIPE / EBADF — child gone.
            if rc == 0:
                return  # EAGAIN — drop the rest; user re-presses.
            sent += rc

    # --- output capture / lossless resize ------------------------------

    def _emit(mut self, s: String):
        """Feed a host-generated banner to the emulator *and* record it
        for resize replay."""
        self.vt.feed_string(s)
        var b = s.as_bytes()
        self._capture(b.unsafe_ptr(), len(b))

    def _capture(mut self, ptr: Pointer[UInt8, _], n: Int):
        """Append ``n`` display-bound bytes to the replay buffer, latching
        overflow at ``_RAW_CAP``. Replies / clipboard writes (Vt→child)
        are deliberately not captured — only what's on screen."""
        if self._raw_overflow:
            return
        for i in range(n):
            self._raw.append(ptr[unsafe_offset=i])
        if len(self._raw) > _RAW_CAP:
            self._raw_overflow = True

    def _rebuild_vt(mut self, cols: Int, rows: Int):
        """Rebuild the grid at ``cols`` × ``rows`` by replaying the
        captured stream. The emulator re-wraps text to the new width, so
        a shrink-then-grow round-trips losslessly — unlike ``Vt.resize``,
        which discards the off-grid columns/rows."""
        self.vt = Vt(cols, rows)
        if len(self._raw) > 0:
            var span = Span[UInt8, origin_of(self._raw)](
                unsafe_ptr=self._raw.unsafe_ptr(), length=len(self._raw),
            )
            self.vt.feed(span)
