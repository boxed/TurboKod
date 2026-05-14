"""Bottom-docked terminal pane: a long-lived shell on a real pty.

Layout (when active, docked at the bottom above the status bar)::

    ─[■] Terminal ───────────────────────────── - [Clear] [Restart]  T
    $ claude
    ✻ Welcome to Claude Code!
       /help for help
    ╭───────────────────────────────────────────────────────╮
    │ >                                                     │
    ╰───────────────────────────────────────────────────────╯

The pane reuses the same chrome (title bar, min/max state, resize
drag, ESC ladder, title-command strip, hotkey hint) as the debug pane
via the shared ``BottomDockedPanel`` helpers in ``window.mojo``. The
body is owned by a ``Vt`` emulator that turns the pty child's output
(including cursor-positioning escapes) into a 2D ``Cell`` grid we
paint each frame.

A single persistent shell subprocess (``$SHELL`` if set, else
``/bin/sh``) is spawned under a controlling pty (``PtyProcess`` →
``tk_pty_spawn``). The child sees a real ``isatty(0)`` and can run
interactive programs — ``claude``, ``vim``, ``less``, ``htop``,
``fzf``, … — that the previous pipe-backed implementation couldn't
host. The pane is a thin shim: drain bytes off the master fd each
tick, feed them into the emulator, paint the grid; forward
keystrokes the other way.

UI intents flow back to ``Desktop`` through the same pattern as the
debug pane: a ``pending_command_id`` latched by chrome clicks, polled
and cleared by the host each tick.
"""

from std.collections.list import List
from std.ffi import external_call
from std.memory.span import Span

from .canvas import Canvas
from .cell import Cell
from .claude_detect import (
    CLAUDE_NONE, claude_state_label, detect_claude_state,
)
from .clipboard import clipboard_copy
from .colors import Attr, BLACK, LIGHT_GRAY, WHITE
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE, EVENT_PASTE,
    KEY_BACKSPACE, KEY_DELETE, KEY_DOWN, KEY_END, KEY_ENTER, KEY_ESC,
    KEY_F1, KEY_F2, KEY_F3, KEY_F4, KEY_F5, KEY_F6, KEY_F7, KEY_F8,
    KEY_F9, KEY_F10, KEY_F11, KEY_F12,
    KEY_HOME, KEY_INSERT, KEY_LEFT, KEY_PAGEDOWN, KEY_PAGEUP,
    KEY_RIGHT, KEY_TAB, KEY_UP,
    MOD_ALT, MOD_CTRL, MOD_META, MOD_NONE, MOD_SHIFT,
    MOUSE_BUTTON_LEFT, MOUSE_BUTTON_NONE,
    MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .geometry import Point, Rect
from .painter import Painter
from .posix import (
    alloc_zero_buffer, getenv_value, poll_stdin, read_into,
)
from .pty import PtyProcess
from .vt import Vt
from .window import (
    BottomDockedPanel, TitleCommand,
    handle_bottom_dock_chrome_mouse, handle_bottom_dock_esc,
    paint_bottom_dock_chrome,
)


comptime _TERMINAL_CLEAR = String("terminal:clear")
comptime _TERMINAL_RESTART = String("terminal:restart")
comptime TERMINAL_PANE_CLOSE = String("terminal:close")
"""Pending-command id dispatched when the pane's window-style ``[■]``
close button (top-LEFT, painted by the shared bottom-dock chrome) is
clicked. Public so the host (``Desktop.terminal_tick``) can recognize
the click and remove the pane from its list — the pane can't pop
itself off a container it doesn't know about."""


struct TerminalPane(ImplicitlyCopyable, Movable):
    """Single bottom-docked terminal. Owns one pty child, a ``Vt``
    emulator, and a tiny grid selection state. The shared chrome
    lives in ``dock``."""
    var visible: Bool
    var dock: BottomDockedPanel
    var focused: Bool

    var pty: PtyProcess
    """The shell subprocess on a controlling pty. Spawned lazily on
    first ``ensure_started``; a closed process re-spawns on the next
    ``ensure_started``. ``master_fd`` is bidirectional (reads child
    output, writes child input)."""
    var vt: Vt
    """Terminal emulator state. The pane's body is whatever this grid
    says, top-left anchored. Re-sized whenever the body rect changes
    (paint catches that and calls ``vt.resize`` + ``pty.set_winsize``
    so the child sees a SIGWINCH)."""

    # --- selection state (grid coordinates) ----------------------------
    var sel_active: Bool
    """True when a finished selection is on screen — drives the
    inverted overlay during paint and the value returned by
    ``has_selection``."""
    var sel_dragging: Bool
    """True between LMB-press and LMB-release while the user is
    extending the selection by drag. Painted live."""
    var sel_anchor_r: Int
    var sel_anchor_c: Int
    var sel_focus_r: Int
    var sel_focus_c: Int

    # --- spawn config --------------------------------------------------
    var cwd: String
    """Working directory the shell starts in. Set by the host
    (``Desktop._open_terminal_pane``) to the open project's root so
    new terminals land where the user is editing; empty string means
    "inherit the parent's cwd" (which is usually the directory the
    editor was launched from). Honored on every ``ensure_started`` —
    Restart also lands you back in the project dir."""

    # --- paint-time hit-test bookkeeping -------------------------------
    var _last_body: Rect
    """Body rect from the last ``paint`` — selection mouse handlers
    convert screen positions back to grid coords via this. ``Rect.empty``
    means the body wasn't laid out (minimized / first frame)."""
    var _last_panel_top: Int

    fn __init__(out self):
        self.visible = False
        self.dock = BottomDockedPanel(preferred_height=14)
        # Window-style ``[■]`` close button at the top-LEFT, routed
        # back to the host as ``TERMINAL_PANE_CLOSE`` through the same
        # ``pending_command_id`` slot the title-command strip uses.
        self.dock.close_button_id = TERMINAL_PANE_CLOSE
        self.focused = False
        self.pty = PtyProcess()
        # Initial 80×24 is the universal default — programs spawned
        # before the first paint compute their layout off this; the
        # first paint resizes to the actual body dimensions and
        # children get a SIGWINCH.
        self.vt = Vt(80, 24)
        self.sel_active = False
        self.sel_dragging = False
        self.sel_anchor_r = 0
        self.sel_anchor_c = 0
        self.sel_focus_r = 0
        self.sel_focus_c = 0
        self.cwd = String("")
        self._last_body = Rect.empty()
        self._last_panel_top = 0

    fn __copyinit__(out self, copy: Self):
        self.visible = copy.visible
        self.dock = copy.dock
        self.focused = copy.focused
        # ``PtyProcess`` isn't safely copyable: the master fd is a
        # kernel handle; if both copies' destructors closed it the
        # original would lose the child. Production keeps the pane
        # singleton-style on ``Desktop``; copies are only used by
        # Mojo value semantics in tests. Reset to a fresh process in
        # the copy so neither destructor double-closes.
        self.pty = PtyProcess()
        self.vt = copy.vt
        self.sel_active = copy.sel_active
        self.sel_dragging = copy.sel_dragging
        self.sel_anchor_r = copy.sel_anchor_r
        self.sel_anchor_c = copy.sel_anchor_c
        self.sel_focus_r = copy.sel_focus_r
        self.sel_focus_c = copy.sel_focus_c
        self.cwd = copy.cwd
        self._last_body = copy._last_body
        self._last_panel_top = copy._last_panel_top

    # --- chrome forwarders ---------------------------------------------

    fn is_minimized(self) -> Bool:
        return self.dock.is_minimized()

    fn is_maximized(self) -> Bool:
        return self.dock.is_maximized()

    fn is_resizing(self) -> Bool:
        return self.dock.is_resizing()

    fn is_on_resize_edge(self, pos: Point, panel: Rect) -> Bool:
        if not self.visible:
            return False
        return self.dock.is_on_resize_edge(pos, panel)

    fn consume_command_id(mut self) -> String:
        return self.dock.consume_command_id()

    # --- lifecycle -----------------------------------------------------

    fn open(mut self):
        """Show the pane and start the shell if needed. Idempotent —
        a second open with the pane already up just refocuses it.
        Called from the menu / hotkey toggle on Desktop."""
        self.visible = True
        self.focused = True
        try:
            self.ensure_started()
        except e:
            # No log to write the error into anymore — the Vt grid is
            # the only output surface. Inject a status line so the
            # user sees what went wrong instead of an empty pane.
            self.vt.feed_string(
                String("[terminal] failed to start shell: ") + String(e)
                + String("\r\n"),
            )

    fn close(mut self):
        """Hide the pane and terminate the shell. The grid content is
        preserved (Vt state is intact) so re-opening shows what was on
        screen."""
        self.visible = False
        self.focused = False
        self.pty.terminate()

    fn ensure_started(mut self) raises:
        """Spawn the shell if not already running.

        Honors ``$SHELL`` when set (most users want their login
        shell's environment), falling back to ``/bin/sh`` if not.
        With a real pty the child sees ``isatty(0) == True`` so rc
        files run normally — we can pass the shell to itself without
        worrying about shell-specific flags."""
        if self.pty.alive and self.pty.pid > 0:
            return
        var shell = getenv_value(String("SHELL"))
        if len(shell.as_bytes()) == 0:
            shell = String("/bin/sh")
        var argv = List[String]()
        argv.append(shell)
        # ``-l`` would make the shell run as a login shell (sourcing
        # ~/.profile / ~/.zprofile). We deliberately don't — most users
        # already have an interactive ~/.zshrc / ~/.bashrc that does
        # what they want, and login mode adds startup latency.
        self.pty = PtyProcess.spawn(
            argv, cwd=self.cwd,
            cols=self.vt.cols, rows=self.vt.rows,
        )

    fn restart(mut self):
        """Kill the current shell and spawn a fresh one. Useful when
        the shell ends up in a wedged state."""
        self.pty.terminate()
        # Wipe the visible grid so the new session starts clean.
        # Equivalent to ``ESC c`` (RIS) which we honor anyway, but
        # explicit reset is more obvious for a UI-driven restart.
        self.vt = Vt(self.vt.cols, self.vt.rows)
        try:
            self.ensure_started()
        except e:
            self.vt.feed_string(
                String("[terminal] failed to restart shell: ") + String(e)
                + String("\r\n"),
            )

    fn clear(mut self):
        """Wipe the visible grid. Doesn't kill the shell — equivalent
        to pressing Ctrl+L in most shells (and what the user expects
        from a Clear button)."""
        self.vt.feed_string(String("\x1b[H\x1b[2J"))

    # --- per-tick drain ------------------------------------------------

    fn tick(mut self):
        """Drain whatever's on the pty master right now and feed it
        into the emulator. Called by ``Desktop`` each frame so output
        appears live without the user pressing a key. Also flushes
        any DSR/DA/clipboard side-effects the parse may have queued."""
        if not self.pty.alive or self.pty.master_fd < 0:
            return
        var scratch = alloc_zero_buffer(4096)
        var total = 0
        # 64 KB cap per tick so a child flooding output (e.g. ``cat
        # big.log``) doesn't lock up the UI loop — we'll drain the
        # rest next frame.
        while poll_stdin(self.pty.master_fd, Int32(0)) and total < 65536:
            var n = read_into(self.pty.master_fd, scratch, 4096)
            if n <= 0:
                if n == 0:
                    # EOF / EIO from the slave side closing — child
                    # gone. The next ``ensure_started`` will respawn.
                    self.pty.alive = False
                break
            var span = Span[UInt8, origin_of(scratch)](
                ptr=scratch.unsafe_ptr(), length=n,
            )
            self.vt.feed(span)
            total += n
        # Drain emulator side-effects:
        #   * DSR / DA replies, OSC-with-reply → bytes back to child.
        #   * OSC 52 clipboard writes → system clipboard.
        # Without this, prompts that probe (oh-my-zsh / starship) stall,
        # and ``vim`` / ``tmux`` yank to clipboard silently drops.
        var reply = self.vt.take_reply()
        if len(reply.as_bytes()) > 0:
            self._write_to_pty(reply^)
        var clip = self.vt.take_clipboard()
        if len(clip.as_bytes()) > 0:
            clipboard_copy(clip)

    fn notify_focus_change(mut self, focused: Bool):
        """Forward the host's focus-in / focus-out to the child when
        the child has enabled focus reporting (``?1004h``). Called by
        ``Desktop`` on ``EVENT_FOCUS_IN/OUT``. The reply is queued in
        the Vt and flushed on the next ``tick``."""
        self.vt.notify_focus_change(focused)

    # --- title strip + chrome commands ---------------------------------

    fn build_commands(self) -> List[TitleCommand]:
        """Title-row strip — Clear and Restart. Close lives in the
        dock's own ``[■]`` button at the top-LEFT (see
        ``BottomDockedPanel.close_button_id``); both routes dispatch
        through the host on ``TERMINAL_PANE_CLOSE``."""
        var out = List[TitleCommand]()
        out.append(TitleCommand(String("[Clear]"), _TERMINAL_CLEAR))
        out.append(TitleCommand(String("[Restart]"), _TERMINAL_RESTART))
        return out^

    fn handle_command(mut self, id: String) -> Bool:
        """Dispatch a title-command id that the host pulled off
        ``consume_command_id``. Returns True if handled."""
        if id == _TERMINAL_CLEAR:
            self.clear()
            return True
        if id == _TERMINAL_RESTART:
            self.restart()
            return True
        return False

    # --- paint ---------------------------------------------------------

    fn paint(mut self, mut canvas: Canvas, panel: Rect):
        if not self.visible or panel.is_empty():
            return
        var bg = Attr(WHITE, BLACK)
        var painter = Painter(panel)
        painter.fill(canvas, panel, String(" "), bg)
        self._last_panel_top = panel.a.y
        if len(self.dock.commands) == 0:
            self.dock.commands = self.build_commands()
        # Title comes from (in order): Claude state when detected,
        # then the OSC title the child has set, then a static default.
        # Claude wins because users opening a Claude session care
        # more about its state than the shell's PS1-derived title.
        var displayed_title = String("Terminal")
        if len(self.vt.title.as_bytes()) > 0:
            displayed_title = self.vt.title
        var tail = self.vt.tail_rows(12)
        var claude_state = detect_claude_state(tail)
        if claude_state != CLAUDE_NONE:
            displayed_title = String("Claude · ") \
                + claude_state_label(claude_state)
        var body = paint_bottom_dock_chrome(
            canvas, painter, panel, displayed_title,
            self.focused, self.dock, String("T"),
        )
        if body.is_empty():
            self._last_body = Rect.empty()
            return
        # Sync the emulator's grid size to the body. Anything other
        # than a no-op here ALSO needs to push the new winsize to the
        # child via TIOCSWINSZ so ``claude`` / ``vim`` / ``less``
        # redraw at the new size — without that they'd keep writing
        # at the old dimensions and the layout falls apart.
        var bw = body.width()
        var bh = body.height()
        if bw <= 0 or bh <= 0:
            self._last_body = Rect.empty()
            return
        if bw != self.vt.cols or bh != self.vt.rows:
            self.vt.resize(bw, bh)
            if self.pty.alive:
                _ = self.pty.set_winsize(bw, bh)
        self._last_body = body
        # Iterate cells, painting through the painter so the panel
        # clip rect protects neighbors. We always paint, even unchanged
        # cells, because ``canvas`` is the back buffer that gets diffed
        # against the front on present — repainting an identical cell
        # is essentially free (eq check, no SGR emit).
        #
        # When the user is scrolled back, the historical rows live in
        # ``self.vt.scrollback`` as ``List[List[Cell]]``. Reading
        # ``scrollback[abs_row]`` returns by value (Mojo can't borrow
        # a non-implicitly-copyable nested List in this version), so
        # we copy each scrollback row exactly ONCE per paint pass
        # rather than once per cell. ``view_cell_at`` would copy the
        # whole row on every cell lookup — O(rows×cols²) allocs and
        # measurable lag when the user is scrolled back into a long
        # history. The per-row copy here is the same total amount of
        # data without the cell-quadratic blowup.
        var sb_len = len(self.vt.scrollback)
        var scrolled_back = self.vt.view_offset > 0 and not self.vt.using_alt
        for r in range(self.vt.rows):
            var sb_row = List[Cell]()
            var use_sb = False
            if scrolled_back:
                var abs_row = (sb_len - self.vt.view_offset) + r
                if abs_row >= 0 and abs_row < sb_len:
                    sb_row = self.vt.scrollback[abs_row].copy()
                    use_sb = True
            for c in range(self.vt.cols):
                var cell: Cell
                if use_sb:
                    if c < len(sb_row):
                        cell = sb_row[c]
                    else:
                        cell = Cell(String(" "), Attr(WHITE, BLACK), 1)
                elif scrolled_back:
                    # Scrolled back into the live tail's residual rows
                    # (when scrollback is shorter than view_offset).
                    var abs_row = (sb_len - self.vt.view_offset) + r
                    cell = self.vt.cell_at(abs_row - sb_len, c)
                else:
                    cell = self.vt.cell_at(r, c)
                var attr = cell.attr
                # Selection overlay: invert the selected cells. This
                # is the same affordance every terminal uses (xterm,
                # iTerm, alacritty) — invert fg/bg over a contiguous
                # range from anchor to focus.
                if self._cell_in_selection(r, c):
                    attr = _invert_attr(attr)
                painter.set(
                    canvas, body.a.x + c, body.a.y + r,
                    Cell(cell.glyph, attr, cell.width),
                )
        # Cursor caret: paint a reverse-video block over the cell at
        # the cursor when the pane is focused, the child hasn't hidden
        # the cursor (``?25l``), the cursor is in bounds, and the user
        # isn't scrolled back. Scrolled-back view is read-only history;
        # painting the live cursor on a historical row would be
        # confusing because it doesn't reflect where keystrokes go.
        if self.focused and self.vt.cursor_visible \
                and self.vt.view_offset == 0:
            var cr = self.vt.cur_r
            var cc = self.vt.cur_c
            if 0 <= cr and cr < self.vt.rows \
                    and 0 <= cc and cc < self.vt.cols:
                var cell = self.vt.cell_at(cr, cc)
                painter.set(
                    canvas, body.a.x + cc, body.a.y + cr,
                    Cell(cell.glyph, _invert_attr(cell.attr), cell.width),
                )

    # --- selection helpers ---------------------------------------------

    fn _cell_in_selection(self, r: Int, c: Int) -> Bool:
        if not (self.sel_active or self.sel_dragging):
            return False
        var sr0 = self.sel_anchor_r
        var sc0 = self.sel_anchor_c
        var sr1 = self.sel_focus_r
        var sc1 = self.sel_focus_c
        # Order so (sr0, sc0) is the top-left in reading order.
        if sr1 < sr0 or (sr1 == sr0 and sc1 < sc0):
            var tmpr = sr0; sr0 = sr1; sr1 = tmpr
            var tmpc = sc0; sc0 = sc1; sc1 = tmpc
        if r < sr0 or r > sr1:
            return False
        if sr0 == sr1:
            return c >= sc0 and c < sc1
        if r == sr0:
            return c >= sc0
        if r == sr1:
            return c < sc1
        return True

    fn _clear_selection(mut self):
        self.sel_active = False
        self.sel_dragging = False

    # --- copy / selection delegates ------------------------------------

    fn has_selection(self) -> Bool:
        return self.sel_active

    fn selected_text(self) -> String:
        if not self.sel_active:
            return String("")
        return self._extract_selection()

    fn copy_selection_to_clipboard(self) -> Bool:
        var text = self.selected_text()
        if len(text.as_bytes()) == 0:
            return False
        clipboard_copy(text)
        return True

    fn _extract_selection(self) -> String:
        var sr0 = self.sel_anchor_r
        var sc0 = self.sel_anchor_c
        var sr1 = self.sel_focus_r
        var sc1 = self.sel_focus_c
        if sr1 < sr0 or (sr1 == sr0 and sc1 < sc0):
            var tmpr = sr0; sr0 = sr1; sr1 = tmpr
            var tmpc = sc0; sc0 = sc1; sc1 = tmpc
        var out = String("")
        for r in range(sr0, sr1 + 1):
            var c_start = sc0 if r == sr0 else 0
            var c_end   = sc1 if r == sr1 else self.vt.cols
            if c_end > self.vt.cols: c_end = self.vt.cols
            if c_start < 0: c_start = 0
            var row_bytes = List[UInt8]()
            for c in range(c_start, c_end):
                # Use view-aware lookup so a selection made while
                # scrolled-back captures the historical text, not the
                # live tail. Selection is in view-row coordinates by
                # construction.
                var g = self.vt.view_cell_at(r, c).glyph.as_bytes()
                for k in range(len(g)):
                    row_bytes.append(g[k])
            # Strip trailing spaces on each row — the grid is
            # rectangular but actual content rarely fills the row to
            # the right edge, and the user expects copy to give them
            # the visible text without trailing padding.
            var end = len(row_bytes)
            while end > 0 and row_bytes[end - 1] == 0x20:
                end -= 1
            out = out + String(StringSlice(
                ptr=row_bytes.unsafe_ptr(), length=end,
            ))
            if r < sr1:
                out = out + String("\n")
        return out^

    # --- mouse ---------------------------------------------------------

    fn handle_mouse(mut self, event: Event, panel: Rect) -> Bool:
        if event.kind != EVENT_MOUSE:
            return False
        # Chrome wins first — close button, resize edge, etc.
        var cr = handle_bottom_dock_chrome_mouse(event, panel, self.dock)
        if cr.consumed:
            if cr.focus_request:
                self.focused = True
            return True
        # In-flight drag selection keeps consuming events even past
        # the body edge so the user can drag-select fast without the
        # selection cutting off when they overshoot.
        if self.sel_dragging:
            if event.button == MOUSE_BUTTON_LEFT and not event.pressed:
                self._end_drag(event.pos)
                return True
            if event.motion:
                self._extend_drag(event.pos)
                return True
        if not panel.contains(event.pos):
            if event.button != MOUSE_BUTTON_NONE \
                    and event.pressed and not event.motion:
                self.focused = False
            return False
        # Wheel inside the body: if the child has enabled mouse
        # tracking we forward (apps like ``less`` interpret wheel as
        # cursor moves); otherwise it shifts the scrollback view. The
        # body-relative check above already excluded chrome rows.
        if event.button == MOUSE_WHEEL_UP or event.button == MOUSE_WHEEL_DOWN:
            if not event.pressed:
                return True
            self.focused = True
            if self.vt.tracks_mouse() \
                    and (event.mods & MOD_SHIFT) == 0:
                self._forward_mouse_to_pty(event, motion=False, released=False)
                return True
            var dir = 3 if event.button == MOUSE_WHEEL_UP else -3
            self.vt.scroll_view_by(dir)
            return True
        # Press / release / motion. With tracking on and Shift not
        # held, route the event to the child instead of selection —
        # that's what every modern terminal does. Shift-drag is the
        # universal "I want to select, ignore the child's tracking"
        # override.
        var shift_held = (event.mods & MOD_SHIFT) != 0
        var routes_to_child = self.vt.tracks_mouse() and not shift_held
        if event.button == MOUSE_BUTTON_LEFT and event.pressed \
                and not event.motion:
            self.focused = True
            if routes_to_child:
                self._forward_mouse_to_pty(event, motion=False, released=False)
                return True
            # Double-click selects the word under the cursor; triple
            # selects the whole row. The terminal input parser stamps
            # ``click_count`` so we don't need timing state of our own
            # — same machinery already drives editor word-selection.
            if event.click_count >= 3:
                self._select_line_at(event.pos)
                return True
            if event.click_count == 2:
                self._select_word_at(event.pos)
                return True
            self._begin_drag(event.pos)
            return True
        if routes_to_child:
            # Release / motion / non-left presses. We pass motion=True
            # when the event flag says so, released=True when the
            # event isn't a press. The encoder filters out non-tracked
            # motion events (e.g. plain hover when only 1000 is on).
            if event.motion and not self.vt.mouse_track_btn_motion \
                    and not self.vt.mouse_track_any_motion:
                return True
            self._forward_mouse_to_pty(
                event,
                motion=event.motion,
                released=event.button != MOUSE_BUTTON_NONE \
                    and not event.pressed,
            )
            return True
        return True

    fn _forward_mouse_to_pty(
        self, event: Event, motion: Bool, released: Bool,
    ):
        """Convert a panel-relative ``Event`` to an xterm mouse byte
        sequence and write it to the pty master. No-op outside the
        body or when the encoder can't represent the coordinates
        (legacy mode at column > 223)."""
        if self._last_body.is_empty():
            return
        var r = event.pos.y - self._last_body.a.y
        var c = event.pos.x - self._last_body.a.x
        if r < 0 or r >= self.vt.rows or c < 0 or c >= self.vt.cols:
            return
        var btn_for_encoder = Int(event.button) - 1
        if event.button == MOUSE_BUTTON_NONE:
            # Motion without a button-change — encode as button 0 with
            # the motion bit set, matching xterm's "release-button"
            # semantics for SGR encoding.
            btn_for_encoder = 0
        if Int(event.button) == 4:    # MOUSE_WHEEL_UP
            btn_for_encoder = 4
        elif Int(event.button) == 5:  # MOUSE_WHEEL_DOWN
            btn_for_encoder = 5
        var encoded = self.vt.encode_mouse(
            button=btn_for_encoder,
            col=c, row=r,
            motion=motion,
            released=released,
            shift=(event.mods & MOD_SHIFT) != 0,
            meta=(event.mods & MOD_ALT) != 0,
            ctrl=(event.mods & MOD_CTRL) != 0,
        )
        if len(encoded.as_bytes()) > 0:
            self._write_to_pty(encoded^)

    fn _grid_xy_for_pos(self, pos: Point) -> Tuple[Int, Int]:
        """Convert a screen position to ``(row, col)`` in the VT grid.
        Out-of-body positions clamp to the nearest edge — that's what
        you want for a drag that left the body."""
        if self._last_body.is_empty():
            return (0, 0)
        var r = pos.y - self._last_body.a.y
        var c = pos.x - self._last_body.a.x
        if r < 0: r = 0
        if r >= self.vt.rows: r = self.vt.rows - 1
        if c < 0: c = 0
        if c > self.vt.cols: c = self.vt.cols
        return (r, c)

    fn _begin_drag(mut self, pos: Point):
        var rc = self._grid_xy_for_pos(pos)
        self.sel_anchor_r = rc[0]
        self.sel_anchor_c = rc[1]
        self.sel_focus_r  = rc[0]
        self.sel_focus_c  = rc[1]
        self.sel_dragging = True
        self.sel_active   = False

    fn _extend_drag(mut self, pos: Point):
        var rc = self._grid_xy_for_pos(pos)
        self.sel_focus_r = rc[0]
        self.sel_focus_c = rc[1]

    fn _select_word_at(mut self, pos: Point):
        """Expand selection to the word boundary at ``pos`` — the
        contiguous run of word-class cells around the click. "Word"
        is everything that isn't whitespace or punctuation; same
        definition every terminal uses for double-click."""
        var rc = self._grid_xy_for_pos(pos)
        var r = rc[0]
        var c = rc[1]
        if c >= self.vt.cols: c = self.vt.cols - 1
        if c < 0:
            self.sel_active = False
            return
        if not _is_word_glyph(self.vt.view_cell_at(r, c).glyph):
            # Click landed on a separator — select just that cell so
            # the user gets *some* feedback (and a single-cell copy is
            # often what they wanted with punctuation anyway).
            self.sel_anchor_r = r
            self.sel_anchor_c = c
            self.sel_focus_r = r
            self.sel_focus_c = c + 1
            self.sel_dragging = False
            self.sel_active = True
            return
        # Walk left while still on a word glyph.
        var lo = c
        while lo > 0:
            if not _is_word_glyph(self.vt.view_cell_at(r, lo - 1).glyph):
                break
            lo -= 1
        # Walk right.
        var hi = c
        while hi + 1 < self.vt.cols:
            if not _is_word_glyph(self.vt.view_cell_at(r, hi + 1).glyph):
                break
            hi += 1
        self.sel_anchor_r = r
        self.sel_anchor_c = lo
        self.sel_focus_r = r
        self.sel_focus_c = hi + 1
        self.sel_dragging = False
        self.sel_active = True

    fn _select_line_at(mut self, pos: Point):
        """Expand selection to the full visual row at ``pos`` — same
        as triple-click in every terminal."""
        var rc = self._grid_xy_for_pos(pos)
        var r = rc[0]
        self.sel_anchor_r = r
        self.sel_anchor_c = 0
        self.sel_focus_r = r
        self.sel_focus_c = self.vt.cols
        self.sel_dragging = False
        self.sel_active = True

    fn _end_drag(mut self, pos: Point):
        self._extend_drag(pos)
        self.sel_dragging = False
        # Tiny drag (or single click) → no selection. Saves the user
        # from accidentally clobbering the clipboard with a one-cell
        # capture when they meant to focus the pane.
        if self.sel_anchor_r == self.sel_focus_r \
                and self.sel_anchor_c == self.sel_focus_c:
            self.sel_active = False
            return
        self.sel_active = True

    # --- keys ----------------------------------------------------------

    fn handle_key(mut self, event: Event) -> Bool:
        if not self.focused:
            return False
        if event.kind == EVENT_PASTE:
            # Bracketed paste (DECSET 2004): when the child has enabled
            # it, wrap the payload with ``ESC[200~`` / ``ESC[201~`` so
            # multi-line paste into shells / vim doesn't run each line
            # as a command. Without it the child sees the raw text and
            # treats embedded newlines as Enter.
            if self.vt.bracketed_paste:
                self._write_to_pty(
                    String("\x1b[200~") + event.text + String("\x1b[201~")
                )
            else:
                self._write_to_pty(event.text)
            return True
        if event.kind != EVENT_KEY:
            return False
        # ESC routes through the chrome ladder first (collapses any
        # in-flight resize / focus state); only if the chrome doesn't
        # consume it do we forward to the child.
        if event.key == KEY_ESC and event.mods == MOD_NONE:
            if handle_bottom_dock_esc(self.dock):
                return True
            self._write_to_pty(String("\x1b"))
            return True
        # Shift+PgUp/PgDn → scrollback navigation (keyboard-only users
        # need this since wheel only works with a pointer). Page-sized
        # chunks match the wheel-scrollback step pattern.
        if event.key == KEY_PAGEUP and (event.mods & MOD_SHIFT) != 0:
            self.vt.scroll_view_by(self.vt.rows - 2)
            return True
        if event.key == KEY_PAGEDOWN and (event.mods & MOD_SHIFT) != 0:
            self.vt.scroll_view_by(-(self.vt.rows - 2))
            return True
        # Cmd+C with an active selection copies. Without selection,
        # fall through so the child gets a real Ctrl+C (the more
        # likely intent when typing in a shell or in claude). The
        # host's edit:copy dispatch in Desktop also calls
        # ``copy_selection_to_clipboard`` directly — this branch is
        # here so terminal-focused Cmd+C still works in code paths
        # that don't go through that dispatcher.
        if event.key == UInt32(ord("c")) and event.mods == MOD_META \
                and self.sel_active:
            _ = self.copy_selection_to_clipboard()
            self._clear_selection()
            return True
        # Any keystroke clears a finished selection — same as every
        # terminal app.
        if self.sel_active:
            self.sel_active = False
        # Snap back to the live tail. Typing into the shell almost
        # always means the user wants to interact with the live prompt
        # rather than scroll history; making them manually scroll back
        # to live every time would be annoying. iTerm / GNOME terminal
        # / kitty all do this.
        if self.vt.view_offset != 0:
            self.vt.reset_view()
        var encoded = _encode_key(
            event.key, event.mods, self.vt.app_cursor_keys,
        )
        if len(encoded.as_bytes()) > 0:
            self._write_to_pty(encoded^)
            return True
        return False

    fn _write_to_pty(self, payload: String):
        if not self.pty.alive or self.pty.master_fd < 0:
            return
        var bytes = payload.as_bytes()
        var n = len(bytes)
        if n == 0:
            return
        var sent = 0
        # Tiny retry loop. The pty master accepts kilobytes at a time
        # normally; a partial write only happens if the kernel's pty
        # buffer is full (a stuck child not draining). For typical
        # keystroke payloads (1..10 bytes) this loop runs once.
        while sent < n:
            var rc = self.pty.write_bytes(bytes.unsafe_ptr() + sent, n - sent)
            if rc < 0:
                return  # EPIPE / EBADF — child gone. Next tick reaps.
            if rc == 0:
                # EAGAIN. We could spin; instead drop the rest and
                # let the user re-press. Holding the loop here risks
                # locking the UI on a misbehaving child.
                return
            sent += rc


# --- key encoding ---------------------------------------------------------


fn _encode_key(key: UInt32, mods: UInt8, app_cursor: Bool = False) -> String:
    """Translate a Mojo key + modifier into the byte sequence a real
    pty child expects on its stdin. Mirrors what xterm sends.

    Modifiers:
      * Ctrl + letter → 0x01..0x1A (the canonical "control character").
      * Alt + key     → ESC prefix, same as xterm's meta-as-prefix.
      * Shift / Ctrl / Alt with named keys (arrows, Home/End/PageUp/
        PageDown, F1..F12, Tab) use the xterm CSI 1;Nc format where
        N = 1 + shift*1 + alt*2 + ctrl*4. Without this, word-motion
        bindings in zsh/bash and vim window-nav (Ctrl+Right etc.)
        don't work.
      * ``app_cursor`` honors DECCKM (``?1``) — arrow / Home / End
        come out as SS3 (``ESC O A``) instead of CSI (``ESC [ A``).
        ``less`` / ``man`` flip this on; without honoring it their
        readline bindings break.
      * Cmd/Meta is reserved for the host (Cmd+C copy, etc.)."""
    var alt = (mods & MOD_ALT) != 0
    var ctrl = (mods & MOD_CTRL) != 0
    var shift = (mods & MOD_SHIFT) != 0
    var prefix = String("\x1b") if alt else String("")
    # xterm-style modifier byte: 1 + shift*1 + alt*2 + ctrl*4 (encoded
    # as ASCII digits in the CSI parameter slot). 1 == no modifier;
    # we only insert the param block when the byte > 1.
    var mod_byte = 1
    if shift: mod_byte += 1
    if alt:   mod_byte += 2
    if ctrl:  mod_byte += 4
    var has_mods = mod_byte > 1
    # When the modifier param is set we drop the ESC prefix — the
    # modifier param IS the encoding for alt now; doubling it would
    # send ESC ESC [ 1;N…, which apps would parse as alt-ESC.
    if has_mods:
        prefix = String("")

    if key == KEY_ENTER:
        # ``\r`` (CR). Most tty drivers translate CR → NL via
        # ICRNL, so the child reads it as ``\n``. Sending ``\n``
        # directly would skip that translation and confuse programs
        # that distinguish (e.g. ``read -r`` in bash).
        return prefix + String("\r")
    if key == KEY_TAB:
        # Shift+Tab → ``CSI Z`` (kcbt) so reverse-tab navigation
        # works (fzf, completion menus, vim's window cycler).
        if shift and not ctrl and not alt:
            return String("\x1b[Z")
        return prefix + String("\t")
    if key == KEY_BACKSPACE:
        # Most modern terminals send DEL (0x7F) for Backspace and let
        # the line discipline translate it via ``stty erase``. Sending
        # 0x08 (BS) here would make a lot of CLIs print ^? or eat the
        # wrong character. Ctrl+Backspace sends BS (0x08) — many
        # readline configs (zsh, bash) bind it to backward-kill-word.
        if ctrl:
            return prefix + String("\x08")
        return prefix + String("\x7f")
    if key == KEY_ESC:
        return prefix + String("\x1b")
    # Arrows / Home / End — three forms depending on DECCKM + mods:
    #   1. modified              → ``ESC [ 1 ; N c``  (xterm modifyOtherKeys)
    #   2. unmodified, no app    → ``ESC [ c``       (CSI form)
    #   3. unmodified, app on    → ``ESC O c``       (SS3 form)
    if key == KEY_UP:
        if has_mods: return _csi_mod(String("A"), mod_byte)
        return prefix + (String("\x1bOA") if app_cursor else String("\x1b[A"))
    if key == KEY_DOWN:
        if has_mods: return _csi_mod(String("B"), mod_byte)
        return prefix + (String("\x1bOB") if app_cursor else String("\x1b[B"))
    if key == KEY_RIGHT:
        if has_mods: return _csi_mod(String("C"), mod_byte)
        return prefix + (String("\x1bOC") if app_cursor else String("\x1b[C"))
    if key == KEY_LEFT:
        if has_mods: return _csi_mod(String("D"), mod_byte)
        return prefix + (String("\x1bOD") if app_cursor else String("\x1b[D"))
    if key == KEY_HOME:
        if has_mods: return _csi_mod(String("H"), mod_byte)
        return prefix + (String("\x1bOH") if app_cursor else String("\x1b[H"))
    if key == KEY_END:
        if has_mods: return _csi_mod(String("F"), mod_byte)
        return prefix + (String("\x1bOF") if app_cursor else String("\x1b[F"))
    # ``~``-terminated nav / function keys — modifier param goes
    # before the tilde (``ESC [ 5 ; N ~``).
    if key == KEY_PAGEUP:
        if has_mods: return _csi_mod_tilde(5, mod_byte)
        return prefix + String("\x1b[5~")
    if key == KEY_PAGEDOWN:
        if has_mods: return _csi_mod_tilde(6, mod_byte)
        return prefix + String("\x1b[6~")
    if key == KEY_INSERT:
        if has_mods: return _csi_mod_tilde(2, mod_byte)
        return prefix + String("\x1b[2~")
    if key == KEY_DELETE:
        if has_mods: return _csi_mod_tilde(3, mod_byte)
        return prefix + String("\x1b[3~")
    # Function keys — SS3 form for F1..F4, CSI ~ form for F5+. Matches
    # xterm-256color's terminfo.
    if key == KEY_F1:
        if has_mods: return _csi_mod(String("P"), mod_byte)
        return prefix + String("\x1bOP")
    if key == KEY_F2:
        if has_mods: return _csi_mod(String("Q"), mod_byte)
        return prefix + String("\x1bOQ")
    if key == KEY_F3:
        if has_mods: return _csi_mod(String("R"), mod_byte)
        return prefix + String("\x1bOR")
    if key == KEY_F4:
        if has_mods: return _csi_mod(String("S"), mod_byte)
        return prefix + String("\x1bOS")
    if key == KEY_F5:
        if has_mods: return _csi_mod_tilde(15, mod_byte)
        return prefix + String("\x1b[15~")
    if key == KEY_F6:
        if has_mods: return _csi_mod_tilde(17, mod_byte)
        return prefix + String("\x1b[17~")
    if key == KEY_F7:
        if has_mods: return _csi_mod_tilde(18, mod_byte)
        return prefix + String("\x1b[18~")
    if key == KEY_F8:
        if has_mods: return _csi_mod_tilde(19, mod_byte)
        return prefix + String("\x1b[19~")
    if key == KEY_F9:
        if has_mods: return _csi_mod_tilde(20, mod_byte)
        return prefix + String("\x1b[20~")
    if key == KEY_F10:
        if has_mods: return _csi_mod_tilde(21, mod_byte)
        return prefix + String("\x1b[21~")
    if key == KEY_F11:
        if has_mods: return _csi_mod_tilde(23, mod_byte)
        return prefix + String("\x1b[23~")
    if key == KEY_F12:
        if has_mods: return _csi_mod_tilde(24, mod_byte)
        return prefix + String("\x1b[24~")

    # Printable character key.
    var ch = Int(key)
    if ch >= 0x20 and ch < 0x10FFFF and ch < 0xE000:
        # Ctrl + ascii letter / @ / [ / \ / ] / ^ / _ → C0 control byte.
        if ctrl:
            var upper = ch
            if upper >= 0x61 and upper <= 0x7A:  # lower → upper
                upper = upper - 0x20
            if upper >= 0x40 and upper <= 0x5F:
                var b = upper - 0x40
                return prefix + _ascii_to_string(UInt8(b))
            # Ctrl+space / Ctrl+2 → NUL.
            if upper == 0x20 or upper == 0x32:
                return prefix + _ascii_to_string(UInt8(0))
            # Other Ctrl+printable → just send the character; xterm's
            # behavior is similar (some glyphs aren't C0-mappable).
        return prefix + _codepoint_to_utf8(UInt32(ch))
    return String("")


fn _csi_mod(letter: String, mod_byte: Int) -> String:
    """xterm modifier-encoded form: ``ESC [ 1 ; N c`` where ``c`` is
    the final letter (A/B/C/D/H/F/P/Q/R/S). Used for modified arrows,
    Home/End, and F1..F4."""
    return String("\x1b[1;") + String(mod_byte) + letter


fn _csi_mod_tilde(num: Int, mod_byte: Int) -> String:
    """xterm modifier-encoded ``~``-terminated form: ``ESC [ n ; N ~``.
    Used for modified PageUp/PageDown/Insert/Delete and F5..F12."""
    return String("\x1b[") + String(num) + String(";") \
        + String(mod_byte) + String("~")


fn _codepoint_to_utf8(cp: UInt32) -> String:
    """Encode a Unicode codepoint to its UTF-8 byte sequence as a
    String. The pty child reads bytes — we have to convert from
    Mojo's codepoint-as-UInt32 representation back to wire bytes."""
    var c = Int(cp)
    var buf = List[UInt8]()
    if c < 0x80:
        buf.append(UInt8(c))
    elif c < 0x800:
        buf.append(UInt8(0xC0 | (c >> 6)))
        buf.append(UInt8(0x80 | (c & 0x3F)))
    elif c < 0x10000:
        buf.append(UInt8(0xE0 | (c >> 12)))
        buf.append(UInt8(0x80 | ((c >> 6) & 0x3F)))
        buf.append(UInt8(0x80 | (c & 0x3F)))
    else:
        buf.append(UInt8(0xF0 | (c >> 18)))
        buf.append(UInt8(0x80 | ((c >> 12) & 0x3F)))
        buf.append(UInt8(0x80 | ((c >> 6) & 0x3F)))
        buf.append(UInt8(0x80 | (c & 0x3F)))
    return String(StringSlice(ptr=buf.unsafe_ptr(), length=len(buf)))


fn _ascii_to_string(b: UInt8) -> String:
    var buf = List[UInt8]()
    buf.append(b)
    return String(StringSlice(ptr=buf.unsafe_ptr(), length=1))


# --- visual helpers -------------------------------------------------------


fn _is_word_glyph(glyph: String) -> Bool:
    """Classify a cell's glyph for double-click word selection. The
    rule: word characters are letters / digits / underscore / dot /
    slash / dash — generous enough that file paths and identifiers
    are one word, but separators like spaces, brackets, and quotes
    still split. Same broad definition every modern terminal uses;
    the exact set is bike-shed territory but matches iTerm's default
    closely."""
    var b = glyph.as_bytes()
    var n = len(b)
    if n == 0:
        return False
    # Look at the first codepoint only — that's good enough for
    # ASCII content and for the common case of CJK / emoji cells
    # (treat any non-ASCII as "word" so a word boundary doesn't
    # accidentally cut a Chinese / Japanese identifier in half).
    var c = Int(b[0])
    if c >= 0x80:
        return True
    if c >= 0x30 and c <= 0x39: return True  # 0-9
    if c >= 0x41 and c <= 0x5A: return True  # A-Z
    if c >= 0x61 and c <= 0x7A: return True  # a-z
    if c == 0x5F: return True                # _
    if c == 0x2E: return True                # .
    if c == 0x2D: return True                # -
    if c == 0x2F: return True                # /
    return False


fn _invert_attr(a: Attr) -> Attr:
    """Swap fg/bg for selection / cursor overlay. We don't toggle
    ``STYLE_REVERSE`` because the underlying cell may already have it
    set (vim's status line, e.g.) — swapping fg/bg lands at the same
    visual either way and saves the parity branch."""
    var r = Attr(a.bg, a.fg, a.style)
    r.underline_color = a.underline_color
    return r
