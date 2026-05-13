"""Bottom-docked terminal pane: a long-lived shell with command input.

Layout (when active, docked at the bottom above the status bar)::

    ─ Terminal ─────────────────────────────── - [Clear] [Restart]  T
    $ ls
    foo.txt   bar.txt
    $ git status
    On branch main
    nothing to commit, working tree clean
    > █

The pane reuses the same chrome (title bar, min/max state, resize drag,
ESC ladder, title-command strip, hotkey hint) as the debug pane via the
shared ``BottomDockedPanel`` helpers in ``window.mojo``. The body is
two stacked widgets: a ``TextLog`` showing history above a one-line
``TextField`` for the next command.

A single persistent shell subprocess (``$SHELL``, default ``/bin/bash``)
backs the pane. Commands are sent via the child's stdin; stdout / stderr
are drained per frame and appended to the log. No PTY: simple commands
that don't depend on a controlling terminal (``ls``, ``git``, ``make``,
…) work fine; interactive curses programs (``vim``, ``htop``) won't —
the shell will note "not a tty" and the program will exit immediately.
For an editor-grade docked terminal that's the right trade-off; a real
PTY emulator is several orders of magnitude more work for the cases the
user has open in another window anyway.

UI intents flow back to ``Desktop`` through the same pattern as the
debug pane: a ``pending_command_id`` latched by chrome clicks, polled
and cleared by the host each tick.
"""

from std.collections.list import List
from std.ffi import external_call

from .canvas import Canvas
from .claude_detect import (
    CLAUDE_NONE, claude_state_label, detect_claude_state,
)
from .clipboard import clipboard_copy
from .colors import (
    Attr, BLACK, LIGHT_BLUE, LIGHT_GRAY, LIGHT_GREEN, LIGHT_RED,
    LIGHT_YELLOW, WHITE,
)
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_DOWN, KEY_END, KEY_ENTER, KEY_ESC, KEY_HOME, KEY_PAGEDOWN, KEY_PAGEUP,
    KEY_UP,
    MOUSE_BUTTON_LEFT, MOUSE_BUTTON_NONE, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .geometry import Point, Rect
from .lsp import LspProcess
from .painter import Painter
from .posix import (
    SIGTERM, alloc_zero_buffer, close_fd, kill_pid,
    poll_stdin, read_into, untrack_child, waitpid_nohang,
)
from .text_field import TextField
from .text_view import TextLog
from .window import (
    BottomDockedPanel, TitleCommand,
    handle_bottom_dock_chrome_mouse, handle_bottom_dock_esc,
    paint_bottom_dock_chrome,
)


# --- output category -----------------------------------------------------
# Same idiom as the debug pane: a UInt8 tag per stream so the renderer
# can color stderr / echoes differently without a string compare on every
# row.
comptime TERM_OUT_STDOUT  = UInt8(0)
comptime TERM_OUT_STDERR  = UInt8(1)
comptime TERM_OUT_ECHO    = UInt8(2)
"""Echoed user input — painted in a hint color so the user can tell
their command from the shell's output."""


comptime _MAX_OUTPUT_LINES = 1000
"""Backlog cap. Larger than the debug pane (500) because a terminal
session typically runs more commands than a debug session and the
output is the only place the user can scroll back through it."""

comptime _TERMINAL_CLEAR = String("terminal:clear")
comptime _TERMINAL_RESTART = String("terminal:restart")
comptime TERMINAL_PANE_CLOSE = String("terminal:close")
"""Title-command id for the pane's ``[X]`` button. Public so the host
(``Desktop.terminal_tick``) can recognize the click and remove the
pane from its list — the pane can't pop itself off a container it
doesn't know about."""


struct TerminalPane(ImplicitlyCopyable, Movable):
    """Single bottom-docked terminal. Owns one shell subprocess, a
    ``TextLog`` for output history, and a ``TextField`` for the next
    command. The shared chrome lives in ``dock``."""
    var visible: Bool
    var dock: BottomDockedPanel
    var focused: Bool

    var process: LspProcess
    """The shell subprocess. Spawned lazily on first ``ensure_started``;
    a closed process re-spawns on the next command."""
    var output: TextLog
    var input: TextField

    var _stderr_pending: String
    """Tail-end of a stderr drain that didn't end on a newline — held
    so we can prepend it to the next drain and split on newlines
    cleanly. (Each ``TextLog.append`` interpreted with a trailing
    fragment would create a stray un-terminated line.)"""
    var _stdout_pending: String

    var title: String
    """Title painted in the pane's chrome — defaults to ``"Terminal"``
    and is updated whenever a child writes an OSC 0/1/2 escape on
    stdout (``ESC ] 0 ; <title> BEL``). Common shells emit this via
    ``PS1``/``precmd`` to keep tab-titles in sync with the cwd or last
    command; we honor the same convention so the pane reads like a
    real tab title."""
    var _osc_partial: String
    """Buffer for an OSC escape that spanned a drain boundary. Holds
    everything from the ``ESC ]`` up to (but not including) the
    terminator; flushed back into ``self.title`` once the terminator
    arrives in a later drain. Without this, a slow shell that wrote
    the escape across two reads would emit the raw bytes into the
    output log instead of updating the title."""

    # --- bookkeeping for paint-time hit-tests --------------------------
    var _last_input_y: Int       # screen y of the input strip
    var _last_input_x0: Int      # screen x where the prompt ends
    var _last_input_x1: Int      # screen x where the input strip ends
    var _last_panel_top: Int

    fn __init__(out self):
        self.visible = False
        self.dock = BottomDockedPanel(preferred_height=14)
        self.focused = False
        self.process = LspProcess()
        self.output = TextLog(
            default_attr=Attr(WHITE, BLACK), max_lines=_MAX_OUTPUT_LINES,
        )
        self.input = TextField()
        self._stderr_pending = String("")
        self._stdout_pending = String("")
        self.title = String("Terminal")
        self._osc_partial = String("")
        self._last_input_y = 0
        self._last_input_x0 = 0
        self._last_input_x1 = 0
        self._last_panel_top = 0

    fn __copyinit__(out self, copy: Self):
        self.visible = copy.visible
        self.dock = copy.dock
        self.focused = copy.focused
        # ``LspProcess`` isn't copyable; we reset to a fresh process in
        # the copy because copying live pipe fds would alias them and
        # the destructor of either copy would close them out from under
        # the other. Copies are only used by Mojo's value semantics in
        # tests and internal moves; in production the pane is owned
        # singleton-style by ``Desktop``.
        self.process = LspProcess()
        self.output = copy.output
        self.input = copy.input.copy()
        self._stderr_pending = copy._stderr_pending
        self._stdout_pending = copy._stdout_pending
        self.title = copy.title
        self._osc_partial = copy._osc_partial
        self._last_input_y = copy._last_input_y
        self._last_input_x0 = copy._last_input_x0
        self._last_input_x1 = copy._last_input_x1
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
            self.output.append(
                String("[terminal] failed to start shell: ") + String(e),
                Attr(LIGHT_RED, BLACK),
            )

    fn close(mut self):
        """Hide the pane and terminate the shell. The output log is
        preserved so the user can re-open and scroll back through it."""
        self.visible = False
        self.focused = False
        self._terminate_shell()

    fn ensure_started(mut self) raises:
        """Spawn the shell if not already running.

        Uses ``/bin/sh`` unconditionally, reading commands from stdin.
        We don't honor ``$SHELL`` here because shell startup-flag
        conventions diverge (``--norc`` for bash, ``-f`` for zsh,
        nothing for fish) and a flag we pass to the wrong shell
        triggers an immediate exit; the pane would then be unusable
        on whichever user's machine happened to default to that
        shell. ``sh`` is universally available, reads stdin, and has
        no rc files to interpolate, so ``echo foo | sh`` Just Works
        on every POSIX system. Power users that want their full shell
        environment can ``exec $SHELL`` inside the pane.
        """
        if self.process.alive and self.process.pid > 0:
            return
        var shell = String("/bin/sh")
        var argv = List[String]()
        argv.append(shell)
        argv.append(String("-s"))
        self.process = LspProcess.spawn(argv)
        self.output.append(
            String("[") + shell + String(" -s]"),
            Attr(LIGHT_GREEN, BLACK),
        )

    fn _terminate_shell(mut self):
        if not self.process.alive:
            return
        if self.process.pid > 0:
            _ = kill_pid(self.process.pid, SIGTERM)
            var _pair = waitpid_nohang(self.process.pid)
            untrack_child(self.process.pid)
        self.process.alive = False
        if self.process.stdin_fd >= 0:
            _ = close_fd(self.process.stdin_fd)
            self.process.stdin_fd = -1
        if self.process.stdout_fd >= 0:
            _ = close_fd(self.process.stdout_fd)
            self.process.stdout_fd = -1
        if self.process.stderr_fd >= 0:
            _ = close_fd(self.process.stderr_fd)
            self.process.stderr_fd = -1

    fn restart(mut self):
        """Kill the current shell and spawn a fresh one. Useful when
        the shell ends up in a wedged state (long-running command
        stuck waiting on a tty, runaway loop, etc.)."""
        self._terminate_shell()
        try:
            self.ensure_started()
        except e:
            self.output.append(
                String("[terminal] failed to restart shell: ") + String(e),
                Attr(LIGHT_RED, BLACK),
            )

    fn clear(mut self):
        """Wipe the output history. Doesn't touch the shell or its
        scrollback in the kernel pipe — purely a UI clear."""
        self.output.clear()

    # --- per-tick drain ------------------------------------------------

    fn tick(mut self):
        """Drain whatever's available on the shell's pipes right now
        and append it to the log. Called by ``Desktop`` each frame so
        output appears live without the user pressing a key."""
        if not self.process.alive or self.process.pid <= 0:
            return
        # Detect shell exit; surface it once.
        var pair = waitpid_nohang(self.process.pid)
        if Int(pair[0]) == Int(self.process.pid):
            untrack_child(self.process.pid)
            self.process.alive = False
            var code = (Int(pair[1]) >> 8) & 0xFF
            self.output.append(
                String("[shell exited code=") + String(code) + String("]"),
                Attr(LIGHT_GRAY, BLACK),
            )
            return
        var out = _drain_fd(self.process.stdout_fd)
        if len(out.as_bytes()) > 0:
            # OSC title escapes (``ESC ] 0/1/2 ; <text> BEL`` or ``... ST``)
            # only travel on stdout — strip + apply them before the
            # chunk hits the log, otherwise the user sees raw escape
            # bytes scroll past every time their PS1 fires.
            var cleaned = self._consume_osc_titles(out^)
            if len(cleaned.as_bytes()) > 0:
                self._append_stream(cleaned^, Attr(WHITE, BLACK), True)
        var err = _drain_fd(self.process.stderr_fd)
        if len(err.as_bytes()) > 0:
            self._append_stream(err^, Attr(LIGHT_RED, BLACK), False)

    fn _consume_osc_titles(mut self, var chunk: String) -> String:
        """Pull ``ESC ] 0/1/2 ; <title> (BEL | ESC \\)`` sequences out of
        ``chunk`` and apply each to ``self.title``. Returns the chunk
        with the matched escapes removed.

        Buffers a partial escape across drain boundaries via
        ``_osc_partial`` — the title sequence is small (well under a
        pipe atomic write), but a busy shell can interleave it with a
        large stdout flush such that the closing terminator lands in
        the next read."""
        var buf = self._osc_partial + chunk^
        var bytes = buf.as_bytes()
        var n = len(bytes)
        var out = String("")
        var i = 0
        while i < n:
            var b = Int(bytes[i])
            # Looking for ESC (0x1B) followed by ']'.
            if b != 0x1B or i + 1 >= n:
                # Plain byte (or trailing ESC) — copy and advance.
                if b == 0x1B and i + 1 >= n:
                    # Trailing ESC at end of buffer — hold it; the ']' /
                    # title / terminator might arrive on the next drain.
                    self._osc_partial = String(StringSlice(
                        ptr=bytes.unsafe_ptr() + i, length=n - i,
                    ))
                    return out^
                out = out + String(StringSlice(
                    ptr=bytes.unsafe_ptr() + i, length=1,
                ))
                i += 1
                continue
            if Int(bytes[i + 1]) != 0x5D:  # ']'
                # ESC followed by something else — not OSC. Pass both
                # bytes through; consumers downstream don't render
                # escapes so they'll just show as garbage, but that's
                # already true for any non-OSC escape from the shell.
                out = out + String(StringSlice(
                    ptr=bytes.unsafe_ptr() + i, length=1,
                ))
                i += 1
                continue
            # Walk forward to a terminator: BEL (0x07) or ST (ESC \).
            # The number+ ';' prefix is permissive — we accept any
            # OSC parameter and only honor titles when it's 0/1/2.
            var term_end = -1   # exclusive end of the OSC including terminator
            var title_term = -1 # exclusive end of just the body (before terminator)
            var j = i + 2
            while j < n:
                var c = Int(bytes[j])
                if c == 0x07:
                    title_term = j
                    term_end = j + 1
                    break
                if c == 0x1B and j + 1 < n and Int(bytes[j + 1]) == 0x5C:
                    title_term = j
                    term_end = j + 2
                    break
                j += 1
            if term_end < 0:
                # Unterminated — buffer everything from ESC onward and
                # try again next drain.
                self._osc_partial = String(StringSlice(
                    ptr=bytes.unsafe_ptr() + i, length=n - i,
                ))
                return out^
            # Parse the body: ``<param>;<title>``.
            var body_start = i + 2
            var sep = -1
            var k = body_start
            while k < title_term:
                if Int(bytes[k]) == 0x3B:  # ';'
                    sep = k
                    break
                k += 1
            if sep >= 0:
                var param_len = sep - body_start
                # Accept 0, 1, 2 (single-byte params).
                if param_len == 1:
                    var p = Int(bytes[body_start])
                    if p == 0x30 or p == 0x31 or p == 0x32:
                        var t_start = sep + 1
                        var t_len = title_term - t_start
                        if t_len < 0:
                            t_len = 0
                        # Empty title means "reset to default" — honor
                        # by restoring the static label so the chrome
                        # doesn't blank out.
                        if t_len == 0:
                            self.title = String("Terminal")
                        else:
                            self.title = String(StringSlice(
                                ptr=bytes.unsafe_ptr() + t_start,
                                length=t_len,
                            ))
            # Skip the consumed OSC.
            i = term_end
        self._osc_partial = String("")
        return out^

    fn _append_stream(
        mut self, var chunk: String, attr: Attr, is_stdout: Bool,
    ):
        """Append a drain chunk to the log, holding any trailing
        non-newline fragment for the next drain. Without that buffering
        a slow stdout write that lands mid-line would produce two short
        log entries instead of one."""
        var pending = self._stdout_pending if is_stdout \
            else self._stderr_pending
        var combined = pending + chunk^
        var bytes = combined.as_bytes()
        var n = len(bytes)
        var split = n
        var i = n - 1
        while i >= 0:
            if bytes[i] == 0x0A:
                split = i + 1
                break
            i -= 1
        if split == 0:
            # No newline anywhere in the combined buffer — hold it all.
            if is_stdout:
                self._stdout_pending = combined^
            else:
                self._stderr_pending = combined^
            return
        var complete = String(StringSlice(
            ptr=bytes.unsafe_ptr(), length=split,
        ))
        var leftover = String(StringSlice(
            ptr=bytes.unsafe_ptr() + split, length=n - split,
        ))
        # ``TextLog.append`` trims a single trailing empty entry on the
        # final newline; that's exactly what we want here so a chunk
        # ending in ``\n`` doesn't append a phantom blank line.
        self.output.append(complete^, attr)
        if is_stdout:
            self._stdout_pending = leftover^
        else:
            self._stderr_pending = leftover^

    # --- command submission --------------------------------------------

    fn _submit_input(mut self):
        """Send the current input line to the shell and echo it into
        the log. No-op when the input is empty so an accidental Enter
        doesn't push a blank command to the shell."""
        var cmd = self.input.text
        var trimmed_len = _strip_trailing_ws_len(cmd)
        if trimmed_len == 0:
            return
        var cmd_bytes = cmd.as_bytes()
        var cmd_str = String(StringSlice(
            ptr=cmd_bytes.unsafe_ptr(), length=trimmed_len,
        ))
        # Echo the command into the log so the user can see what they
        # ran above its output — same affordance every real terminal
        # provides.
        self.output.append(
            String("$ ") + cmd_str, Attr(LIGHT_YELLOW, BLACK),
        )
        # Make sure the shell is up; spawn lazily if not.
        if not self.process.alive or self.process.pid <= 0:
            try:
                self.ensure_started()
            except e:
                self.output.append(
                    String("[terminal] cannot run: shell not running (")
                        + String(e) + String(")"),
                    Attr(LIGHT_RED, BLACK),
                )
                self.input.clear()
                return
        # Write the command + newline. The shell reads from its stdin
        # line-buffered and runs each line as a separate command. If
        # the write fails (closed pipe), surface a hint and try to
        # restart on the next submission.
        var payload = cmd_str + String("\n")
        var sent = _write_all_nb(self.process.stdin_fd, payload)
        if not sent:
            self.output.append(
                String("[terminal] write failed; restarting shell"),
                Attr(LIGHT_RED, BLACK),
            )
            self._terminate_shell()
        self.input.clear()

    # --- paint ---------------------------------------------------------

    fn build_commands(self) -> List[TitleCommand]:
        """Standard title-row strip — Clear, Restart, and Close.
        Returned as a list so Desktop can copy it onto ``dock.commands``
        each tick without poking the pane's internals. ``Close`` is
        dispatched by the host (see ``TERMINAL_PANE_CLOSE``) because
        only the host can remove the pane from its list."""
        var out = List[TitleCommand]()
        out.append(TitleCommand(String("[Clear]"), _TERMINAL_CLEAR))
        out.append(TitleCommand(String("[Restart]"), _TERMINAL_RESTART))
        out.append(TitleCommand(String("[X]"), TERMINAL_PANE_CLOSE))
        return out^

    fn handle_command(mut self, id: String) -> Bool:
        """Dispatch a title-command id that the host pulled off
        ``consume_command_id``. Returns True if handled. Centralized
        here so the same id strings drive paint and dispatch."""
        if id == _TERMINAL_CLEAR:
            self.clear()
            return True
        if id == _TERMINAL_RESTART:
            self.restart()
            return True
        return False

    fn paint(mut self, mut canvas: Canvas, panel: Rect):
        if not self.visible or panel.is_empty():
            return
        var bg = Attr(WHITE, BLACK)
        var painter = Painter(panel)
        painter.fill(canvas, panel, String(" "), bg)
        self._last_panel_top = panel.a.y
        # Refresh the command strip in case Desktop hasn't pushed one
        # this tick — the strip is static for this pane so we own it
        # outright (unlike the debug pane whose buttons track DAP state).
        if len(self.dock.commands) == 0:
            self.dock.commands = self.build_commands()
        # When Claude Code's UI is visible in the tail of the output,
        # surface its state in the title bar — handier than scanning
        # the output to know whether the spinner is still spinning.
        # When nothing is detected we keep whatever title the shell
        # last pushed via OSC.
        var displayed_title = self.title
        var claude_state = detect_claude_state(self.output.lines)
        if claude_state != CLAUDE_NONE:
            displayed_title = String("Claude · ") \
                + claude_state_label(claude_state)
        var body = paint_bottom_dock_chrome(
            canvas, painter, panel, displayed_title,
            self.focused, self.dock, String("T"),
        )
        if body.is_empty():
            # MINIMIZED: title row only.
            self.output.last_y0 = panel.a.y + 1
            self._last_input_y = panel.a.y + 1
            return
        # Body split: one-row input strip at the bottom, output above.
        var body_h = body.height()
        if body_h < 1:
            return
        var input_y = body.b.y - 1
        var log_bottom = input_y
        if log_bottom <= body.a.y:
            log_bottom = body.a.y
        var log_rect = Rect(
            body.a.x + 1, body.a.y, body.b.x - 1, log_bottom,
        )
        if log_rect.height() > 0:
            self.output.paint(canvas, log_rect)
        # Input strip — paint a prompt then hand the rest to the
        # TextField so editing / selection / scrolling behave the
        # same as any other input in the app.
        var prompt_attr = Attr(LIGHT_BLUE, BLACK)
        _ = painter.put_text(
            canvas, Point(body.a.x + 1, input_y), String("> "),
            prompt_attr,
        )
        var field_rect = Rect(
            body.a.x + 3, input_y, body.b.x - 1, input_y + 1,
        )
        self.input.paint(canvas, field_rect, self.focused)
        self._last_input_y = input_y
        self._last_input_x0 = field_rect.a.x
        self._last_input_x1 = field_rect.b.x

    # --- mouse ---------------------------------------------------------

    fn handle_mouse(mut self, event: Event, panel: Rect) -> Bool:
        if event.kind != EVENT_MOUSE:
            return False
        # Chrome gets first dibs — same rationale as the debug pane.
        var cr = handle_bottom_dock_chrome_mouse(event, panel, self.dock)
        if cr.consumed:
            if cr.focus_request:
                self.focused = True
            return True
        # Selection drag in flight in the output log — let it consume
        # every event until release, even outside the panel rect.
        if self.output.selection.dragging:
            return self.output.handle_mouse(event)
        if not panel.contains(event.pos):
            if event.button != MOUSE_BUTTON_NONE and event.pressed and not event.motion:
                self.focused = False
            return False
        # Wheel routes to the log regardless of where the wheel ticked
        # in the body — the input strip is a single line and doesn't
        # scroll.
        if event.button == MOUSE_WHEEL_UP or event.button == MOUSE_WHEEL_DOWN:
            if event.pressed:
                _ = self.output.handle_mouse(event)
            return True
        if event.button == MOUSE_BUTTON_LEFT and event.pressed and not event.motion:
            self.focused = True
            # Click on the input strip parks the caret in the field.
            if event.pos.y == self._last_input_y:
                var field_rect = Rect(
                    self._last_input_x0, self._last_input_y,
                    self._last_input_x1, self._last_input_y + 1,
                )
                _ = self.input.handle_mouse(event, field_rect)
                return True
            # Anything else in the body is forwarded to the log so the
            # user can start a selection there.
            return self.output.handle_mouse(event)
        # Click release / motion outside an in-flight drag is a no-op.
        return True

    # --- keys ----------------------------------------------------------

    fn handle_key(mut self, event: Event) -> Bool:
        if not self.focused:
            return False
        if event.kind != EVENT_KEY:
            return False
        if event.key == KEY_ESC:
            return handle_bottom_dock_esc(self.dock)
        # PageUp / PageDown / Home / End scroll the log so the user
        # can review history without taking their hands off the
        # keyboard. The plain arrow / Home / End / Backspace still
        # belong to the input field (caret motion + editing).
        if event.key == KEY_PAGEUP:
            self.output.scroll_by(-8)
            return True
        if event.key == KEY_PAGEDOWN:
            self.output.scroll_by(8)
            return True
        if event.key == KEY_ENTER:
            self._submit_input()
            return True
        # TextField handles printable insert, arrows-as-caret,
        # backspace, clipboard, undo/redo, …
        var r = self.input.handle_key(event)
        if r.consumed:
            return True
        # Up / Down without a binding are reserved for command-history
        # navigation in a future iteration; for now they just consume
        # so the underlying editor doesn't see them when this pane has
        # focus.
        if event.key == KEY_UP or event.key == KEY_DOWN:
            return True
        return False

    # --- selection / copy delegations ----------------------------------
    # Same surface as DebugPane so the host's Cmd+C path can ask the
    # pane to copy without caring which one is focused.

    fn has_selection(self) -> Bool:
        return self.output.has_selection()

    fn selected_text(self) -> String:
        return self.output.selected_text()

    fn copy_selection_to_clipboard(self) -> Bool:
        return self.output.copy_to_clipboard()


# --- helpers --------------------------------------------------------------


fn _drain_fd(fd: Int32) -> String:
    """Pull whatever's on ``fd`` right now without blocking. Bounded by
    a 64 KB per-call cap so a flooding child can't lock up the loop."""
    if fd < 0:
        return String("")
    var out = String("")
    var scratch = alloc_zero_buffer(4096)
    var total = 0
    while poll_stdin(fd, Int32(0)) and total < 65536:
        var n = read_into(fd, scratch, 4096)
        if n <= 0:
            break
        out = out + String(StringSlice(
            ptr=scratch.unsafe_ptr(), length=n,
        ))
        total += n
    return out^


fn _write_all_nb(fd: Int32, payload: String) -> Bool:
    """Best-effort non-blocking write of every byte of ``payload``.

    Returns False on EPIPE / other I/O failure (caller should treat
    the process as dead). A short write (EAGAIN) loops back; for the
    sub-kilobyte command payloads we send here, the pipe is never
    full enough for EAGAIN to actually fire in practice.

    Used instead of ``LspProcess.write_message`` (which adds JSON-RPC
    framing) because the shell expects raw bytes on its stdin.
    """
    if fd < 0:
        return False
    var bytes = payload.as_bytes()
    var n = len(bytes)
    var sent = 0
    while sent < n:
        var rc = external_call["tk_write_nb", Int](
            fd, bytes.unsafe_ptr() + sent, UInt(n - sent),
        )
        if rc < 0:
            return False
        if rc == 0:
            # Pipe full — give the kernel a moment by yielding the
            # write loop and trying again. For our payload sizes this
            # almost never fires; spin-loop is fine.
            continue
        sent += Int(rc)
    return True


fn _strip_trailing_ws_len(s: String) -> Int:
    """Return the byte length of ``s`` with trailing ASCII whitespace
    stripped. The caller slices ``s[:len]`` if it wants the trimmed
    string — but the only caller currently just needs the length to
    check for empty-after-trim. ``\\n`` / ``\\t`` / `` `` count.
    """
    var b = s.as_bytes()
    var n = len(b)
    while n > 0:
        var c = Int(b[n - 1])
        if c == 0x20 or c == 0x09 or c == 0x0A or c == 0x0D:
            n -= 1
        else:
            break
    return n
