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

from .canvas import Canvas
from .claude_detect import (
    CLAUDE_CLEAN, CLAUDE_NONE, CLAUDE_WAITING, CLAUDE_WORKING,
    ClaudeStateTracker, claude_state_label,
)
from .clipboard import clipboard_copy
from .colors import Attr, PANE_BG, WHITE
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE, EVENT_PASTE,
    KEY_ESC, KEY_PAGEDOWN, KEY_PAGEUP,
    MOD_META, MOD_NONE, MOD_SHIFT,
    MOUSE_BUTTON_LEFT, MOUSE_BUTTON_NONE,
    MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .geometry import Point, Rect
from .painter import Painter
from .posix import (
    alloc_zero_buffer, getenv_value, monotonic_ms, poll_stdin, read_into,
)
from .pty import PtyProcess
from .terminal_view import GridSelection, encode_key, paint_grid
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

comptime _DONE_DEBOUNCE_MS = 1000
"""Debounce window for the attention ("done") event. A done-worthy
state (``waiting`` / ``clean`` / ``none``) must persist for this long
before an armed pane fires its attention event. The Claude-state
detector is a tail-scan that can momentarily mis-read a spinner frame
as ``waiting`` even past the tracker's working-stickiness window; without
the debounce that transient dropout fires a spurious "done", and a
working→waiting→working→waiting wobble fires several. Requiring the
state to hold for a second collapses each turn to exactly one event."""


struct TerminalPane(Copyable, Movable):
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
    var sel: GridSelection
    """Mouse selection over the ``vt`` grid (cell / word / line drag),
    plus the last-painted body rect for screen→grid mapping. The shared
    ``GridSelection`` machinery is reused by the test pane."""

    # --- spawn config --------------------------------------------------
    var cwd: String
    """Working directory the shell starts in. Set by the host
    (``Desktop._open_terminal_pane``) to the open project's root so
    new terminals land where the user is editing; empty string means
    "inherit the parent's cwd" (which is usually the directory the
    editor was launched from). Honored on every ``ensure_started`` —
    Restart also lands you back in the project dir."""
    var startup_command: String
    """Optional command typed into the shell right after spawn. Empty
    means "just drop the user at a prompt" (the plain New-terminal
    path). Set to ``claude`` by the Cmd+Alt+C "New Claude pane" path so
    the pane boots straight into a Claude session. We feed it through
    the shell's stdin (rather than ``exec``-ing it directly) so the
    user's full interactive environment — PATH, rc files, shell
    functions — is in place before it runs, and so the prompt returns
    when the command exits instead of the pane dying."""

    # --- paint-time hit-test bookkeeping -------------------------------
    var _last_panel_top: Int
    var _claude_tracker: ClaudeStateTracker
    """Smooths the Claude-state classification across paints so that a
    single unrecognized spinner-glyph frame doesn't flip the title bar
    from ``working`` to ``waiting``. See ``ClaudeStateTracker`` for
    the smoothing contract."""
    var _claude_title_state: UInt8
    """Last Claude state computed by ``tick``'s attention pass. ``paint``
    reads this for the title instead of re-scanning the grid tail and
    re-classifying — ``tick`` already does that work each frame (the loop
    runs ``tick`` before ``paint``). Seeded to ``CLAUDE_NONE`` so the
    title is the plain shell default until the first classification."""
    var _attn_armed: Bool
    """True once a ``CLAUDE_WORKING`` state has been seen by ``tick``.
    When an armed pane settles into ``waiting`` / ``clean`` / ``none``
    (turn finished, permission prompt, or Claude exited), an attention
    event fires and the flag disarms. ``CLAUDE_ACTIVE`` (indeterminate
    mid-conversation) neither fires nor disarms, so a brief
    working→active→waiting wobble still produces exactly one event."""
    var _done_pending: Bool
    """True while a done-worthy state is being debounced — we've seen
    ``waiting`` / ``clean`` / ``none`` on an armed pane but haven't yet
    held it for ``_DONE_DEBOUNCE_MS``. A ``working`` flare clears it
    (Claude resumed; the dropout was transient)."""
    var _done_candidate_ms: Int
    """Monotonic-ms reading when ``_done_pending`` was raised. The
    attention event fires once ``now_ms`` is at least
    ``_DONE_DEBOUNCE_MS`` past this. Meaningless when
    ``_done_pending`` is False."""
    var attention_events: Int
    """Count of attention-worthy Claude transitions since the host
    last drained via ``take_attention``. The macOS host turns these
    into a Dock bounce + badge when the app isn't frontmost; the
    terminal frontend currently ignores them."""

    def __init__(out self):
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
        self.sel = GridSelection()
        self.cwd = String("")
        self.startup_command = String("")
        self._last_panel_top = 0
        self._claude_tracker = ClaudeStateTracker()
        self._claude_title_state = CLAUDE_NONE
        self._attn_armed = False
        self._done_pending = False
        self._done_candidate_ms = 0
        self.attention_events = 0

    def __copyinit__(mut self, copy: Self):
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
        self.sel = copy.sel
        self.cwd = copy.cwd
        self.startup_command = copy.startup_command
        self._last_panel_top = copy._last_panel_top
        self._claude_tracker = copy._claude_tracker
        self._claude_title_state = copy._claude_title_state
        self._attn_armed = copy._attn_armed
        self._done_pending = copy._done_pending
        self._done_candidate_ms = copy._done_candidate_ms
        self.attention_events = copy.attention_events

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

    # --- lifecycle -----------------------------------------------------

    def open(mut self):
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

    def close(mut self):
        """Hide the pane and terminate the shell. The grid content is
        preserved (Vt state is intact) so re-opening shows what was on
        screen."""
        self.visible = False
        self.focused = False
        self.pty.terminate()

    def ensure_started(mut self) raises:
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
        if len(self.startup_command.as_bytes()) > 0:
            # Queue the command on the shell's stdin. The bytes sit in
            # the pty input buffer until the shell finishes sourcing its
            # rc files and starts reading, so this runs after the
            # environment is fully set up. ``\r`` is what Enter sends on
            # a real terminal; the pty's cooked mode maps it to newline.
            self._write_to_pty(self.startup_command + String("\r"))

    def restart(mut self):
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

    def clear(mut self):
        """Wipe the visible grid. Doesn't kill the shell — equivalent
        to pressing Ctrl+L in most shells (and what the user expects
        from a Clear button)."""
        self.vt.feed_string(String("\x1b[H\x1b[2J"))

    # --- per-tick drain ------------------------------------------------

    def tick(mut self):
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
                    # EOF from the slave side closing — the child is gone
                    # (the user typed ``exit``, or the shell died). Tear it
                    # down here rather than just latching ``alive`` False:
                    # nothing else will. ``close`` runs only when the user
                    # closes the pane, and the next ``ensure_started``
                    # overwrites this ``PtyProcess`` wholesale — either way
                    # the master fd and the unreaped child would be
                    # unreachable. ``terminate`` skips the SIGTERM now that
                    # ``alive`` is False and does the reap + close.
                    self.pty.alive = False
                    self.pty.terminate()
                break
            var span = Span[UInt8, origin_of(scratch)](
                unsafe_ptr=scratch.unsafe_ptr(), length=n,
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
        # Attention detection lives here (not in ``paint``) so it keeps
        # running while the pane is minimized or the window is occluded —
        # the whole point is alerting a user who is looking elsewhere.
        # Classification is skipped when nothing arrived and we're not
        # armed: entering ``working`` requires new output, so an idle
        # shell costs nothing; while armed we must keep polling because
        # the tracker's working-stickiness can expire with no new bytes.
        if total > 0 or self._attn_armed:
            var now = monotonic_ms()
            var state = self._claude_tracker.classify(self.vt.tail_rows(20), now)
            # Cache for ``paint`` to read as the title — same scan/classify
            # it would otherwise redo each frame. When this branch is
            # skipped (idle shell, not armed) the tail is unchanged so the
            # previously-cached state is still current.
            self._claude_title_state = state
            self._note_claude_state(state, now)

    def _note_claude_state(mut self, state: UInt8, now_ms: Int):
        """Arm on ``working``; fire one attention event when an armed
        pane reaches ``waiting`` (turn finished / permission prompt),
        ``clean`` (cleared), or ``none`` (Claude exited — done).

        The done-worthy state is debounced by ``_DONE_DEBOUNCE_MS``:
        the first such state on an armed pane only starts the timer;
        the event fires only once the state has held for the whole
        window. A ``working`` flare inside the window cancels the
        pending done (Claude resumed — the dropout was a transient
        spinner-frame mis-read), so a working↔waiting wobble produces
        exactly one event per real turn instead of several. ``active``
        (indeterminate mid-conversation) neither fires, arms, nor
        cancels."""
        if state == CLAUDE_WORKING:
            self._attn_armed = True
            self._done_pending = False
            return
        if not self._attn_armed:
            return
        if state == CLAUDE_WAITING or state == CLAUDE_CLEAN \
                or state == CLAUDE_NONE:
            if not self._done_pending:
                self._done_pending = True
                self._done_candidate_ms = now_ms
                return
            if now_ms - self._done_candidate_ms >= _DONE_DEBOUNCE_MS:
                self.attention_events += 1
                self._attn_armed = False
                self._done_pending = False

    def take_attention(mut self) -> Int:
        """Drain and return the pending attention-event count."""
        var n = self.attention_events
        self.attention_events = 0
        return n

    def notify_focus_change(mut self, focused: Bool):
        """Forward the host's focus-in / focus-out to the child when
        the child has enabled focus reporting (``?1004h``). Called by
        ``Desktop`` on ``EVENT_FOCUS_IN/OUT``. The reply is queued in
        the Vt and flushed on the next ``tick``."""
        self.vt.notify_focus_change(focused)

    # --- title strip + chrome commands ---------------------------------

    def build_commands(self) -> List[TitleCommand]:
        """Title-row strip — Clear and Restart. Close lives in the
        dock's own ``[■]`` button at the top-LEFT (see
        ``BottomDockedPanel.close_button_id``); both routes dispatch
        through the host on ``TERMINAL_PANE_CLOSE``."""
        var out = List[TitleCommand]()
        out.append(TitleCommand(String("[Clear]"), _TERMINAL_CLEAR))
        out.append(TitleCommand(String("[Restart]"), _TERMINAL_RESTART))
        return out^

    def handle_command(mut self, id: String) -> Bool:
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

    def paint(mut self, mut canvas: Canvas, panel: Rect):
        if not self.visible or panel.is_empty():
            return
        var bg = Attr(WHITE, PANE_BG)
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
        # Claude state is classified once per frame by ``tick`` (which the
        # loop runs before ``paint``) and cached in ``_claude_title_state``;
        # reuse it here rather than rescanning the grid tail and
        # re-classifying.
        var claude_state = self._claude_title_state
        if claude_state != CLAUDE_NONE:
            displayed_title = String("Claude · ") \
                + claude_state_label(claude_state)
        var body = paint_bottom_dock_chrome(
            canvas, painter, panel, displayed_title,
            self.focused, self.dock, String("T"),
        )
        if body.is_empty():
            self.sel._last_body = Rect.empty()
            return
        # Sync the emulator's grid size to the body. Anything other
        # than a no-op here ALSO needs to push the new winsize to the
        # child via TIOCSWINSZ so ``claude`` / ``vim`` / ``less``
        # redraw at the new size — without that they'd keep writing
        # at the old dimensions and the layout falls apart.
        var bw = body.width()
        var bh = body.height()
        if bw <= 0 or bh <= 0:
            self.sel._last_body = Rect.empty()
            return
        if bw != self.vt.cols or bh != self.vt.rows:
            self.vt.resize(bw, bh)
            if self.pty.alive:
                _ = self.pty.set_winsize(bw, bh)
        self.sel._last_body = body
        # Grid + selection overlay + cursor caret — shared with the test
        # pane via ``paint_grid``.
        paint_grid(canvas, painter, self.vt, self.sel, body, self.focused)

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
        # Chrome wins first — close button, resize edge, etc.
        var cr = handle_bottom_dock_chrome_mouse(
            event, panel, self.dock, allow_resize,
        )
        if cr.consumed:
            if cr.focus_request:
                self.focused = True
            return True
        # In-flight drag selection keeps consuming events even past
        # the body edge so the user can drag-select fast without the
        # selection cutting off when they overshoot.
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
                self.sel.select_line_at(self.vt, event.pos)
                return True
            if event.click_count == 2:
                self.sel.select_word_at(self.vt, event.pos)
                return True
            self.sel.begin_drag(self.vt, event.pos)
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

    def _forward_mouse_to_pty(
        self, event: Event, motion: Bool, released: Bool,
    ):
        """Encode a panel-relative mouse ``Event`` to xterm bytes via the
        shared view and write them to the pty master. No-op outside the
        body or when the encoder can't represent the coordinates."""
        var encoded = self.sel.encode_mouse_forward(
            self.vt, event, motion, released,
        )
        if len(encoded.as_bytes()) > 0:
            self._write_to_pty(encoded^)

    # --- keys ----------------------------------------------------------

    def handle_key(mut self, event: Event) -> Bool:
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
        # Decline Cmd+W so it isn't encoded to the shell — it falls
        # through to the global window:close binding, which closes the
        # focused pane (see Desktop's WINDOW_CLOSE handler).
        if event.key == UInt32(ord("w")) and event.mods == MOD_META:
            return False
        # ESC routes through the chrome ladder first (collapses any
        # in-flight resize / focus state); only if the chrome doesn't
        # consume it do we forward to the child. Exception: when a
        # Claude Code session is detected in the pane, ESC goes
        # straight to the child — it's a vital key there (interrupt
        # the agent, clear the input, close menus) and stepping the
        # pane down the max → normal → min ladder instead would be
        # hostile. The chrome remains reachable via mouse and the
        # pane hotkey.
        if event.key == KEY_ESC and event.mods == MOD_NONE:
            var tail = self.vt.tail_rows(20)
            var claude = self._claude_tracker.classify(tail, monotonic_ms())
            if claude == CLAUDE_NONE and handle_bottom_dock_esc(self.dock):
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
                and self.sel.sel_active:
            _ = self.copy_selection_to_clipboard()
            self.sel.clear()
            return True
        # Any keystroke clears a finished selection — same as every
        # terminal app.
        if self.sel.sel_active:
            self.sel.sel_active = False
        # Snap back to the live tail. Typing into the shell almost
        # always means the user wants to interact with the live prompt
        # rather than scroll history; making them manually scroll back
        # to live every time would be annoying. iTerm / GNOME terminal
        # / kitty all do this.
        if self.vt.view_offset != 0:
            self.vt.reset_view()
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
        # Tiny retry loop. The pty master accepts kilobytes at a time
        # normally; a partial write only happens if the kernel's pty
        # buffer is full (a stuck child not draining). For typical
        # keystroke payloads (1..10 bytes) this loop runs once.
        while sent < n:
            var rc = self.pty.write_bytes(bytes.unsafe_ptr().unsafe_offset(sent), n - sent)
            if rc < 0:
                return  # EPIPE / EBADF — child gone. Next tick reaps.
            if rc == 0:
                # EAGAIN. We could spin; instead drop the rest and
                # let the user re-press. Holding the loop here risks
                # locking the UI on a misbehaving child.
                return
            sent += rc

