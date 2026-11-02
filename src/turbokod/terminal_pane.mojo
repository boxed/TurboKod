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

from .canvas import Canvas
from .cell import Cell
from .claude_detect import (
    CLAUDE_CLEAN, CLAUDE_NONE, CLAUDE_WAITING, CLAUDE_WORKING,
    ClaudeStateTracker, claude_state_label,
)
from .colors import Attr, PANE_BG, PANE_FG, WHITE
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE, EVENT_PASTE, KEY_ESC, KEY_PAGEDOWN,
    KEY_PAGEUP, MOD_META, MOD_NONE,
    MOD_SHIFT, MOUSE_BUTTON_LEFT, MOUSE_BUTTON_NONE, MOUSE_WHEEL_DOWN,
    MOUSE_WHEEL_UP,
)
from .geometry import Point, Rect
from .painter import Painter
from .posix import (
    alloc_zero_buffer, getenv_value, monotonic_ms, poll_stdin, read_into,
)
from .pty import PtyProcess
from .scrollbar import ScrollBarArea
from .tmux_session import (
    prepare_tmux_socket_dir, run_exit_line, tmux_attach_argv, tmux_binary,
    tmux_history, tmux_kill_session, tmux_pane_state, tmux_respawn,
    tmux_socket_path, tmux_stop,
)
from .terminal_view import (
    flush_vt_side_effects, forward_key_to_grid, GridSelection, paint_grid,
    paste_to_pty,
)
from .vt import MOUSE_MOTION, MOUSE_PRESS, MOUSE_RELEASE, SCROLLBACK_LINES, Vt
from .window import (
    BottomDockedPanel, TitleCommand,
    handle_bottom_dock_chrome_mouse, handle_bottom_dock_esc,
    paint_bottom_dock_chrome,
)


comptime _TERMINAL_CLEAR = String("terminal:clear")
comptime _TERMINAL_RESTART = String("terminal:restart")
comptime _TERMINAL_STOP = String("terminal:stop")

comptime _MODES_TTL_MS = 300
"""How long a tmux pane trusts its last ``tmux_pane_state`` answer on a
press or a wheel step, so a burst of wheel events spawns one tmux."""
comptime _HISTORY_POLL_MS = 1000
"""After output, how soon a tmux pane asks again how much history tmux
holds — the scroll bar's size while the pane shows the live screen."""
comptime _RUN_EXIT_GRACE_MS = 300
"""After a run pane (re)starts, how long its grid may still show the
previous run's exit line before tmux redraws — not read as this run's."""
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

    var scroll_bar: ScrollBarArea
    """Shown while the view is scrolled back into history."""
    var history: Vt
    """A tmux pane's scrollback, while it is scrolled back (``_history_on``;
    released otherwise). tmux draws on the alternate screen, so ``vt`` has
    no history of its own: the first step back captures tmux's
    (``tmux_history``) into this emulator, whose bottom rows are then the
    screen, and the pane shows, selects in and scrolls it like any other
    scrollback. Back at the bottom it is dropped and ``vt`` is live again.
    This keeps tmux's copy mode — its own selection that copies on release
    and its ``[0/123]`` position indicator — out of the pane."""
    var _history_on: Bool
    var _modes_ms: Int
    var _child_mouse: Bool
    var _child_alt: Bool
    var _tmux_history_rows: Int
    """What tmux says about a tmux pane (``tmux_pane_state``), as of
    ``_modes_ms``. ``vt`` can't say: tmux itself always tracks the mouse,
    and keeps the history."""
    var _state_stale: Bool
    """Output arrived since ``_modes_ms``: ``tick`` asks again."""

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

    var tmux_session: String
    """Name of the tmux session this pane is a client of, or "" for a
    plain shell. Set by the host before ``open`` — see
    ``tmux_session.mojo``. The shell then lives in the tmux server, so
    ``close`` (and an app quit) only detach; ``kill_session`` ends it."""
    var tmux_project: String
    """Project root recorded on the session when it is created, which is
    how a restart finds the pane again."""
    var tmux_create: Bool
    """Create ``tmux_session`` on the next ``ensure_started`` rather than
    attach to it. True for a new pane and after Restart; False for a pane
    re-attached to a session that survived a restart."""
    var run_target: String
    """The project target this pane runs (Cmd+R with tmux), "" for a
    terminal. ``startup_command`` is then the session's process, not
    something typed into a shell, and the pane outlives its exit."""
    var run_env: List[String]
    """The target's ``K=V`` environment, for creating the session."""
    var run_exited: Bool
    var run_exit_status: String
    """The exit status the run printed (``128+n`` for a signal)."""
    var _run_exit_event: Bool
    var _run_scan_after_ms: Int
    var _run_rescan: Bool

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
        self.scroll_bar = ScrollBarArea()
        self.history = Vt(1, 1)
        self.history.release()
        self._history_on = False
        self._modes_ms = -_MODES_TTL_MS
        self._child_mouse = False
        self._child_alt = False
        self._tmux_history_rows = 0
        self._state_stale = True
        self.cwd = String("")
        self.startup_command = String("")
        self.tmux_session = String("")
        self.tmux_project = String("")
        self.tmux_create = True
        self.run_target = String("")
        self.run_env = List[String]()
        self.run_exited = False
        self.run_exit_status = String("")
        self._run_exit_event = False
        self._run_scan_after_ms = 0
        self._run_rescan = True
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
        # The copy shares the emulator (``Vt`` is a handle); the original
        # pane owns it and is the one that releases it.
        self.vt = copy.vt
        self.sel = copy.sel
        self.scroll_bar = copy.scroll_bar.copy()
        self.history = copy.history
        self._history_on = copy._history_on
        self._modes_ms = copy._modes_ms
        self._child_mouse = copy._child_mouse
        self._child_alt = copy._child_alt
        self._tmux_history_rows = copy._tmux_history_rows
        self._state_stale = copy._state_stale
        self.cwd = copy.cwd
        self.startup_command = copy.startup_command
        self.tmux_session = copy.tmux_session
        self.tmux_project = copy.tmux_project
        self.tmux_create = copy.tmux_create
        self.run_target = copy.run_target
        self.run_env = copy.run_env.copy()
        self.run_exited = copy.run_exited
        self.run_exit_status = copy.run_exit_status
        self._run_exit_event = copy._run_exit_event
        self._run_scan_after_ms = copy._run_scan_after_ms
        self._run_rescan = copy._run_rescan
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
        """Hide the pane and terminate the shell — or, for a tmux pane,
        detach from its session, which keeps running. The grid content is
        preserved (Vt state is intact) so re-opening shows what was on
        screen."""
        self.visible = False
        self.focused = False
        self._leave_history()
        self.pty.terminate()

    def is_tmux(self) -> Bool:
        return len(self.tmux_session.as_bytes()) > 0

    def kill_session(mut self):
        """End the tmux session behind the pane — the user closed the pane,
        as opposed to the app detaching on quit. No-op for a plain shell."""
        if self.is_tmux():
            tmux_kill_session(self.tmux_session)

    def release(mut self):
        """Free the emulator. ``close`` keeps it so a re-open shows the old
        screen; this is for when the pane itself goes away (its close
        button, or ``Desktop.shutdown``). Call ``close`` first."""
        self._leave_history()
        self.vt.release()

    def ensure_started(mut self) raises:
        """Spawn the shell if not already running.

        Honors ``$SHELL`` when set (most users want their login
        shell's environment), falling back to ``/bin/sh`` if not.
        With a real pty the child sees ``isatty(0) == True`` so rc
        files run normally — we can pass the shell to itself without
        worrying about shell-specific flags."""
        if self.pty.alive and self.pty.pid > 0:
            return
        if self.is_tmux():
            var tmux = tmux_binary()
            var socket = tmux_socket_path()
            if len(tmux.as_bytes()) > 0 and len(socket.as_bytes()) > 0:
                prepare_tmux_socket_dir(socket)
                self.pty = PtyProcess.spawn(
                    tmux_attach_argv(
                        tmux, socket, self.tmux_session, self.tmux_create,
                        self.cwd, self.tmux_project, self.startup_command,
                        self.vt.cols(), self.vt.rows(),
                        self.run_target, self.run_env,
                    ),
                    cwd=self.cwd, cols=self.vt.cols(), rows=self.vt.rows(),
                )
                self.tmux_create = False
                return
            # tmux went away (uninstalled, $HOME unset): a plain shell.
            self.tmux_session = String("")
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
            cols=self.vt.cols(), rows=self.vt.rows(),
        )
        if len(self.startup_command.as_bytes()) > 0:
            # Queue the command on the shell's stdin. The bytes sit in
            # the pty input buffer until the shell finishes sourcing its
            # rc files and starts reading, so this runs after the
            # environment is fully set up. ``\r`` is what Enter sends on
            # a real terminal; the pty's cooked mode maps it to newline.
            self.pty.write_all(self.startup_command + String("\r"))

    def is_run(self) -> Bool:
        return len(self.run_target.as_bytes()) > 0

    def is_running(self) -> Bool:
        """A run pane whose process hasn't exited."""
        return self.is_run() and not self.run_exited

    def take_run_exit(mut self) -> Bool:
        """True once per exit of the run pane's process."""
        var fired = self._run_exit_event
        self._run_exit_event = False
        return fired

    def _note_run_start(mut self):
        self.run_exited = False
        self.run_exit_status = String("")
        self._run_exit_event = False
        self._run_scan_after_ms = monotonic_ms() + _RUN_EXIT_GRACE_MS
        self._run_rescan = True

    def respawn(mut self):
        """A run pane's Restart: the same command again, in the same
        session (``respawn-pane -k``), with the environment it was created
        with — which also holds after a re-attach, when ``run_env`` is
        empty."""
        tmux_respawn(self.tmux_session)
        self._note_run_start()

    def stop(mut self):
        """Ctrl-C a run pane's process. The pane stays, showing the
        output and the exit line."""
        if self.is_running():
            tmux_stop(self.tmux_session)

    def restart(mut self):
        """Kill the current shell and spawn a fresh one. Useful when
        the shell ends up in a wedged state. A tmux pane gets a fresh
        session under the same name."""
        self._note_run_start()
        self._leave_history()
        self.pty.terminate()
        if self.is_tmux():
            tmux_kill_session(self.tmux_session)
            self.tmux_create = True
        # Wipe the grid, scrollback and modes so the new session starts
        # clean (a full reset, as ``ESC c`` would do).
        self.vt.reset()
        try:
            self.ensure_started()
        except e:
            self.vt.feed_string(
                String("[terminal] failed to restart shell: ") + String(e)
                + String("\r\n"),
            )

    # --- scrollback ----------------------------------------------------

    def _view(self) -> Vt:
        """The emulator on screen: ``history`` while a tmux pane is
        scrolled back, else ``vt``. A handle, so scrolling the result
        scrolls the pane."""
        if self._history_on:
            return self.history
        return self.vt

    def _refresh_modes(mut self, ttl_ms: Int = _MODES_TTL_MS):
        var now = monotonic_ms()
        if now - self._modes_ms < ttl_ms:
            return
        self._modes_ms = now
        self._state_stale = False
        var m = tmux_pane_state(self.tmux_session)
        self._child_mouse = m.wants_mouse
        self._child_alt = m.alternate
        self._tmux_history_rows = 0 if m.alternate else m.history_rows

    def _scrollback(self) -> Int:
        """Rows above the screen, for the scroll bar: tmux's count while a
        tmux pane is live (its own ``vt`` has none)."""
        if self.is_tmux() and not self._history_on:
            return self._tmux_history_rows
        return self._view().scrollback_rows()

    def _child_tracks_mouse(mut self, refresh: Bool) -> Bool:
        """Whether mouse events go to the program rather than to selection
        and scrolling. ``refresh`` asks tmux again (a press or a wheel
        step — not every hover)."""
        if not self.is_tmux():
            return self.vt.tracks_mouse()
        if self._history_on:
            return False
        if refresh:
            self._refresh_modes()
        return self._child_mouse

    def scroll_view_by(mut self, delta: Int):
        """Scroll ``delta`` rows into history (negative: toward the live
        screen). A full-screen program's alternate screen has none."""
        if self.is_tmux() and not self._history_on:
            if delta <= 0:
                return
            self._refresh_modes()
            if self._child_alt:
                return
            self._enter_history()
            if not self._history_on:
                return
        var v = self._view()
        v.scroll_view_by(delta)
        self._settle_history()

    def _enter_history(mut self):
        var h = Vt(self.vt.cols(), self.vt.rows())
        h.feed_string(tmux_history(self.tmux_session, SCROLLBACK_LINES))
        if h.scrollback_rows() == 0:
            h.release()
            return
        self.history = h
        self._history_on = True
        self.sel.clear()

    def _settle_history(mut self):
        """Back at the bottom (and not mid-drag on the bar): live again."""
        if self._history_on and self.history.view_offset() == 0 \
                and not self.scroll_bar.dragging:
            self._leave_history()

    def _leave_history(mut self):
        if not self._history_on:
            return
        self.history.release()
        self._history_on = False
        self.sel.clear()

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
        flush_vt_side_effects(self.pty, self.vt)
        if self.is_running() and (total > 0 or self._run_rescan):
            self._scan_run_exit()
        if self.is_tmux():
            if total > 0:
                self._state_stale = True
            if self._state_stale and self.visible:
                self._refresh_modes(_HISTORY_POLL_MS)
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

    def _scan_run_exit(mut self):
        """Look for the ``[<target> exited with …]`` line (see
        ``run_exit_line``). Runs on new output, and once more after the
        grace window — a run that exits before then may print nothing
        afterwards."""
        var now = monotonic_ms()
        if now < self._run_scan_after_ms:
            return
        self._run_rescan = False
        var prefix = run_exit_line(self.run_target)
        var rows = self.vt.tail_rows(self.vt.rows())
        for i in range(len(rows) - 1, -1, -1):
            var row = String(rows[i].strip())
            if not row.startswith(prefix) or not row.endswith("]"):
                continue
            var rb = row.as_bytes()
            var pb = len(prefix.as_bytes())
            self.run_exit_status = String(
                StringSpan(unsafe_from_utf8=rb[pb:len(rb) - 1])
            )
            self.run_exited = True
            self._run_exit_event = True
            return

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
        if self.is_run():
            out.append(TitleCommand(String("[■ Stop]"), _TERMINAL_STOP))
            out.append(TitleCommand(String("[↻ Restart]"), _TERMINAL_RESTART))
            return out^
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
            if self.is_run():
                self.respawn()
            else:
                self.restart()
            return True
        if id == _TERMINAL_STOP:
            self.stop()
            return True
        return False

    # --- paint ---------------------------------------------------------

    def header_title(self) -> String:
        """The header's title: Claude's state, else the OSC title the child
        set, else "Terminal". A run pane says which target, and whether it
        exited."""
        if self.is_run():
            var t = String("Run - ") + self.run_target
            if self.run_exited:
                t = t + String(" (exited: ") + self.run_exit_status + String(")")
            return t^
        var displayed_title = String("Terminal")
        var osc_title = self.vt.title()
        if len(osc_title.as_bytes()) > 0:
            displayed_title = osc_title
        # Claude state is classified once per frame by ``tick`` (which the
        # loop runs before ``paint``) and cached in ``_claude_title_state``;
        # reuse it here rather than rescanning the grid tail and
        # re-classifying.
        var claude_state = self._claude_title_state
        if claude_state != CLAUDE_NONE:
            displayed_title = String("Claude · ") \
                + claude_state_label(claude_state)
        return displayed_title^

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
        var displayed_title = self.header_title()
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
        # The right column is the scroll bar's, so it never covers output.
        var bar_area = body
        body = Rect(body.a.x, body.a.y, body.b.x - 1, body.b.y)
        var bw = body.width()
        var bh = body.height()
        if bw <= 0 or bh <= 0:
            self.sel._last_body = Rect.empty()
            return
        if bw != self.vt.cols() or bh != self.vt.rows():
            # The captured history is laid out for the old width.
            self._leave_history()
            self.vt.resize(bw, bh)
            if self.pty.alive:
                _ = self.pty.set_winsize(bw, bh)
        self.sel._last_body = body
        # Grid + selection overlay + cursor caret — shared with the test
        # pane via ``paint_grid``.
        var v = self._view()
        paint_grid(canvas, painter, v, self.sel, body, self.focused)
        var sb = self._scrollback()
        var attr = Attr(PANE_FG, PANE_BG)
        var col = Rect(bar_area.b.x - 1, bar_area.a.y, bar_area.b.x, bar_area.b.y)
        for y in range(col.a.y, col.b.y):
            painter.set(canvas, col.a.x, y, Cell(String(" "), attr, 1))
        if sb > 0:
            self.scroll_bar.paint(
                canvas, bar_area, sb + v.rows(), sb - v.view_offset(), attr,
            )
        else:
            self.scroll_bar.hide()

    # --- copy / selection delegates ------------------------------------

    def has_selection(self) -> Bool:
        return self.sel.has_selection()

    def selected_text(self) -> String:
        return self.sel.selected_text(self._view())

    def copy_selection_to_clipboard(self) -> Bool:
        return self.sel.copy_to_clipboard(self._view())

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
        var bar = self.scroll_bar.handle_mouse(event)
        if bar >= 0:
            self.focused = True
            var v = self._view()
            self.scroll_view_by(self._scrollback() - bar - v.view_offset())
            return True
        if self.sel.continue_drag(self._view(), event):
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
            if (event.mods & MOD_SHIFT) == 0 \
                    and self._child_tracks_mouse(True):
                self._forward_mouse_to_pty(event, MOUSE_PRESS)
                return True
            var dir = 3 if event.button == MOUSE_WHEEL_UP else -3
            self.scroll_view_by(dir)
            return True
        # Press / release / motion. With tracking on and Shift not
        # held, route the event to the child instead of selection —
        # that's what every modern terminal does. Shift-drag is the
        # universal "I want to select, ignore the child's tracking"
        # override.
        var shift_held = (event.mods & MOD_SHIFT) != 0
        var is_press = event.button != MOUSE_BUTTON_NONE and event.pressed \
            and not event.motion
        var routes_to_child = not shift_held \
            and self._child_tracks_mouse(is_press)
        if event.button == MOUSE_BUTTON_LEFT and event.pressed \
                and not event.motion:
            self.focused = True
            if routes_to_child:
                self._forward_mouse_to_pty(event, MOUSE_PRESS)
                return True
            self.sel.click(self._view(), event)
            return True
        if routes_to_child:
            # Release / motion / non-left presses. The encoder drops what
            # the child didn't ask for (plain hover when only 1000 is on).
            var action = MOUSE_PRESS
            if event.motion:
                action = MOUSE_MOTION
            elif event.button != MOUSE_BUTTON_NONE and not event.pressed:
                action = MOUSE_RELEASE
            self._forward_mouse_to_pty(event, action)
            return True
        return True

    def _forward_mouse_to_pty(self, event: Event, action: Int):
        """Encode a panel-relative mouse ``Event`` (``action`` a
        ``MOUSE_*``) via the shared view and write it to the pty master.
        No-op outside the body or when the child asked for no report."""
        var encoded = self.sel.encode_mouse_forward(self.vt, event, action)
        if len(encoded.as_bytes()) > 0:
            self.pty.write_all(encoded)

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
            self._leave_history()
            paste_to_pty(self.pty, self.vt, event.text)
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
            self.pty.write_all(String("\x1b"))
            return True
        if (event.key == KEY_PAGEUP or event.key == KEY_PAGEDOWN) \
                and (event.mods & MOD_SHIFT) != 0:
            var page = self.vt.rows() - 2
            self.scroll_view_by(page if event.key == KEY_PAGEUP else -page)
            return True
        if self._history_on:
            if event.key == UInt32(ord("c")) and event.mods == MOD_META \
                    and self.sel.sel_active:
                _ = self.sel.copy_to_clipboard(self.history)
                self.sel.clear()
                return True
            # Typing is for the live screen.
            self._leave_history()
        return forward_key_to_grid(self.pty, self.vt, self.sel, event)


