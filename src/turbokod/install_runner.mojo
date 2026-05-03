"""Run an LSP install command in the background, with a non-modal popup.

The user is prompted "Install <lang> LSP? '<hint>' (y/N)" when they open
a file in a language whose server isn't on ``$PATH``. Saying yes used to
just copy the hint to the clipboard — useful, but friction. This module
runs the hint as ``sh -c <hint>`` directly: stdout + stderr are captured,
a small bottom-right window shows a spinner and the last 5 lines of
output, and on exit the runner emits an ``InstallResult`` the host can
react to (status-bar success message, or open a new editor window with
the full output on failure).

The runner spawns through ``LspProcess.spawn`` so the env allowlist (PATH,
PIXI / CONDA roots, etc.) matches everything else we exec — ``brew`` or
``pip install`` finds its toolchain the same way the LSP would.

Sudo / interactive prompts genuinely don't work from a non-TTY child;
those still need the user to paste-and-run in a real shell. The clipboard
copy is preserved as a fallback path for that case.
"""

from std.collections.list import List
from std.collections.optional import Optional

from .canvas import Canvas
from .colors import Attr, BLACK, BLUE, LIGHT_GRAY, WHITE, YELLOW
from .geometry import Point, Rect
from .lsp import LspProcess
from .window import paint_drop_shadow
from .posix import (
    alloc_zero_buffer, close_fd, monotonic_ms, poll_stdin, read_into,
    untrack_child, waitpid_nohang,
)


# Spinner frames. Cycled at ~10 Hz off ``monotonic_ms`` — slow enough to
# read each frame, fast enough to feel alive while a long ``brew install``
# grinds away.
comptime _SPINNER_FRAMES = String("|/-\\")
comptime _SPINNER_PERIOD_MS: Int = 100

# Hard cap on the captured combined output. brew / pip install can emit
# multi-megabyte logs (tarball extraction, post-install hooks); we keep
# the last ``_OUTPUT_CAP`` bytes so the failure-window editor doesn't
# choke on a huge buffer. Last bytes, not first — the failure message is
# at the bottom of the log.
comptime _OUTPUT_CAP: Int = 256 * 1024

comptime _LAST_LINES: Int = 5


@fieldwise_init
struct InstallResult(ImplicitlyCopyable, Movable):
    """Outcome of one install run, surfaced to the host on completion.

    ``status`` is the raw ``waitpid`` value — exit code is
    ``(status >> 8) & 0xFF`` on POSIX. ``output`` is the combined
    stdout+stderr capture (last ``_OUTPUT_CAP`` bytes if the child
    was chatty)."""
    var label: String
    var command: String
    var status: Int32
    var output: String

    fn exit_code(self) -> Int:
        return (Int(self.status) >> 8) & 0xFF

    fn ok(self) -> Bool:
        return self.exit_code() == 0


struct InstallRunner(Movable):
    var active: Bool
    var label: String           # short label shown in the popup ("rust LSP")
    var command: String         # the shell command we're running
    var process: LspProcess     # owns pid + stdin/stdout/stderr fds
    var output: String          # rolling capture (capped at _OUTPUT_CAP)
    var _spinner_anchor_ms: Int

    fn __init__(out self):
        self.active = False
        self.label = String("")
        self.command = String("")
        self.process = LspProcess()
        self.output = String("")
        self._spinner_anchor_ms = 0

    fn is_active(self) -> Bool:
        return self.active

    fn start(mut self, var label: String, var command: String) raises:
        """Spawn ``sh -c command`` and start tracking it. Raises if a run
        is already in flight (single-slot — host should check first)."""
        if self.active:
            raise Error("install runner already active")
        var argv = List[String]()
        argv.append(String("sh"))
        argv.append(String("-c"))
        argv.append(command)
        self.process = LspProcess.spawn(argv)
        self.label = label^
        self.command = command^
        self.output = String("")
        self._spinner_anchor_ms = monotonic_ms()
        self.active = True

    fn tick(mut self) -> Optional[InstallResult]:
        """Drain whatever's available on the child's stdout / stderr and
        check whether it has exited. Returns the ``InstallResult`` once
        on the tick where the child reaps; ``None`` on every other tick.

        We call ``waitpid_nohang`` directly (rather than going through
        ``LspProcess.try_reap``) so we can capture the raw status and
        derive an exit code — ``try_reap`` discards the status word.
        """
        if not self.active:
            return Optional[InstallResult]()
        # Drain both pipes opportunistically — a chatty child shouldn't
        # backpressure us into a deadlock on its stderr write.
        self._drain_fd(self.process.stdout_fd)
        self._drain_fd(self.process.stderr_fd)
        var pair = waitpid_nohang(self.process.pid)
        if Int(pair[0]) != Int(self.process.pid):
            return Optional[InstallResult]()
        untrack_child(self.process.pid)
        # Child reaped. Drain once more so we don't miss the last write
        # that landed between the previous drain and the EOF.
        self._drain_fd(self.process.stdout_fd)
        self._drain_fd(self.process.stderr_fd)
        var status = pair[1]
        var result = InstallResult(
            self.label, self.command, status, self.output,
        )
        self._reset()
        return Optional[InstallResult](result^)

    fn _drain_fd(mut self, fd: Int32):
        """Read everything currently available on ``fd`` into ``output``.
        Both pipes are non-blocking (``LspProcess.spawn`` set that up),
        so we loop until ``poll`` says no more data or ``read`` returns
        ≤ 0 (EOF / EAGAIN)."""
        if fd < 0:
            return
        var scratch = alloc_zero_buffer(4096)
        var total = 0
        while poll_stdin(fd, Int32(0)) and total < 65536:
            var n = read_into(fd, scratch, 4096)
            if n <= 0:
                break
            self.output = self.output + String(StringSlice(
                ptr=scratch.unsafe_ptr(), length=n,
            ))
            total += n
        if len(self.output.as_bytes()) > _OUTPUT_CAP:
            # Keep the *tail*: install failures put the diagnostic at the
            # bottom of the log, and silently dropping the head is much
            # less misleading than dropping a multi-megabyte tail.
            var ob = self.output.as_bytes()
            self.output = String(StringSlice(
                unsafe_from_utf8=ob[len(ob) - _OUTPUT_CAP:],
            ))

    fn _reset(mut self):
        # Close the parent ends of the pipes that we still own; the child
        # was reaped by ``waitpid_nohang`` so its side is already gone.
        if self.process.stdin_fd  >= 0: _ = close_fd(self.process.stdin_fd)
        if self.process.stdout_fd >= 0: _ = close_fd(self.process.stdout_fd)
        if self.process.stderr_fd >= 0: _ = close_fd(self.process.stderr_fd)
        self.active = False
        self.label = String("")
        self.command = String("")
        self.output = String("")
        self._spinner_anchor_ms = 0
        self.process = LspProcess()

    # --- paint ------------------------------------------------------------

    fn paint(self, mut canvas: Canvas, screen: Rect):
        """Render the bottom-right progress popup. No-op when inactive.

        The popup is non-modal: it overlays whatever's underneath, and
        events pass through to the windows below. It paints *after* the
        status bar but *above* the workspace, so it sits between the
        workspace and the modal dialogs.
        """
        if not self.active:
            return
        var width = 60
        # Top border row (also carries the title), one row per output line,
        # bottom border row.
        var height = _LAST_LINES + 2
        if width > screen.b.x - 2: width = screen.b.x - 2
        if height > screen.b.y - 2: height = screen.b.y - 2
        if width < 20 or height < 4:
            return
        # Bottom-right, one row above the status bar, two cols off the edge.
        var x = screen.b.x - width - 2
        var y = screen.b.y - height - 1
        if x < 1: x = 1
        if y < 1: y = 1
        var rect = Rect(x, y, x + width, y + height)
        var bg = Attr(BLACK, LIGHT_GRAY)
        var title_attr = Attr(WHITE, BLUE)
        var spin_attr = Attr(YELLOW, LIGHT_GRAY)
        paint_drop_shadow(canvas, rect)
        canvas.fill(rect, String(" "), bg)
        canvas.draw_box(rect, bg, False)
        # Title row: `Installing <label>… [spinner]`.
        var spin = self._spinner_glyph()
        var title = String(" Installing ") + self.label + String(" ")
        var tx = rect.a.x + 1
        _ = canvas.put_text(Point(tx, rect.a.y), title, title_attr)
        var sx = rect.b.x - 3
        if sx > tx + len(title.as_bytes()):
            _ = canvas.put_text(Point(sx, rect.a.y), spin, spin_attr)
        # Last N lines of output, top-down. Truncated to the popup width
        # by ``put_text``'s ``max_x`` clamp.
        var tail = _last_lines(self.output, _LAST_LINES)
        var inner_top = rect.a.y + 1
        var inner_left = rect.a.x + 2
        var max_x = rect.b.x - 1
        for i in range(len(tail)):
            _ = canvas.put_text(
                Point(inner_left, inner_top + i), tail[i], bg, max_x,
            )

    fn _spinner_glyph(self) -> String:
        var elapsed = monotonic_ms() - self._spinner_anchor_ms
        if elapsed < 0:
            elapsed = 0
        var fb = _SPINNER_FRAMES.as_bytes()
        var n = len(fb)
        if n == 0:
            return String(" ")
        var idx = (elapsed // _SPINNER_PERIOD_MS) % n
        return String(StringSlice(unsafe_from_utf8=fb[idx:idx + 1]))


# --- helpers ----------------------------------------------------------------


fn _last_lines(text: String, n: Int) -> List[String]:
    """Return the last ``n`` non-empty lines of ``text``, oldest first.

    Trailing whitespace is stripped per line so a stray ``\\r`` (CRLF
    output from a Windows-style installer) doesn't blow up the rightmost
    column with a control char.
    """
    var lines = List[String]()
    var b = text.as_bytes()
    var i = 0
    var line_start = 0
    while i < len(b):
        if b[i] == 0x0A:
            var end = i
            # Strip trailing CR / spaces.
            while end > line_start \
                    and (b[end - 1] == 0x0D or b[end - 1] == 0x20
                         or b[end - 1] == 0x09):
                end -= 1
            if end > line_start:
                lines.append(String(StringSlice(
                    unsafe_from_utf8=b[line_start:end],
                )))
            line_start = i + 1
        i += 1
    if line_start < len(b):
        var end = len(b)
        while end > line_start \
                and (b[end - 1] == 0x0D or b[end - 1] == 0x20
                     or b[end - 1] == 0x09):
            end -= 1
        if end > line_start:
            lines.append(String(StringSlice(
                unsafe_from_utf8=b[line_start:end],
            )))
    if len(lines) <= n:
        return lines^
    var tail = List[String]()
    for k in range(len(lines) - n, len(lines)):
        tail.append(lines[k])
    return tail^
