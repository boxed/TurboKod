"""A child process whose stdout is consumed as newline-terminated lines,
incrementally and without blocking the UI thread.

Shared by the two streaming ``rg`` runners — Find in Project
(``project_find._RgRunner``) and the Find Symbol fallback
(``find_symbol._FindSymbolRunner``). Each supplies its own argv and its
own line parser; this owns the spawn, the per-frame capped read, the
line split that carries a partial tail across frames, and the teardown
on EOF / cancel.
"""

from std.collections.list import List
from std.collections.optional import Optional

from .lsp import LspProcess
from .posix import DRAIN_EOF, drain_fd


comptime _READ_CAP_PER_TICK = 65536
"""Bytes read per ``tick`` at most, so a runaway query can't hijack a
frame; the rest stays in the kernel pipe buffer for the next tick."""


struct LineStream(Movable):
    var proc: LspProcess
    var active: Bool
    var _buf: List[UInt8]
    """Bytes read but not yet split into a complete line."""
    var _scan_pos: Int
    """How far ``_buf`` has already been scanned for a newline. Persists
    across ticks so a huge unterminated line isn't rescanned from the
    start every frame (that made line-finding O(N²) over a search)."""

    def __init__(out self):
        self.proc = LspProcess()
        self.active = False
        self._buf = List[UInt8]()
        self._scan_pos = 0

    def is_active(self) -> Bool:
        return self.active

    def start(mut self, argv: List[String]) -> Bool:
        """Cancel any running child, then spawn ``argv``. False when the
        spawn failed (e.g. the program isn't on PATH)."""
        self.cancel()
        try:
            self.proc = LspProcess.spawn(argv)
        except:
            return False
        self.active = True
        return True

    def cancel(mut self):
        """Stop the child (if any) and drop buffered output. Idempotent.
        ``terminate`` SIGTERMs and reaps; ``rg`` exits on SIGTERM at once."""
        if self.active:
            self.proc.terminate()
        self.active = False
        self._buf = List[UInt8]()
        self._scan_pos = 0

    def tick(mut self) -> Tuple[List[String], Bool]:
        """Read what's available (capped) and return ``(lines, finished)``:
        every newly completed line, without its ``\\n``, and whether the
        child reached EOF this tick — in which case it has been reaped, a
        trailing partial line dropped (``rg`` always terminates lines),
        and the stream is idle again."""
        var lines = List[String]()
        if not self.active:
            return (lines^, False)
        var got_eof = drain_fd(
            self.proc.stdout_fd, self._buf, _READ_CAP_PER_TICK, 8192,
        )[1] == DRAIN_EOF
        var consumed = 0
        var i = self._scan_pos
        while i < len(self._buf):
            if self._buf[i] == 0x0A:
                if i > consumed:
                    lines.append(String(StringSpan(
                        unsafe_from_utf8=Span(self._buf)[consumed:i],
                    )))
                consumed = i + 1
            i += 1
        if consumed > 0:
            var tail = List[UInt8]()
            tail.extend(Span(self._buf)[consumed:len(self._buf)])
            self._buf = tail^
            self._scan_pos = 0
        else:
            self._scan_pos = len(self._buf)
        if got_eof:
            self.cancel()
        return (lines^, got_eof)


struct OutputStream(Movable):
    """A child process whose whole stdout is wanted, read across frames
    without blocking the UI thread: for output that isn't lines, such as
    ``git status -z``."""
    var proc: LspProcess
    var active: Bool
    var _buf: List[UInt8]

    def __init__(out self):
        self.proc = LspProcess()
        self.active = False
        self._buf = List[UInt8]()

    def is_active(self) -> Bool:
        return self.active

    def start(mut self, argv: List[String]) -> Bool:
        """Cancel any running child, then spawn ``argv``. False when the
        spawn failed."""
        self.cancel()
        try:
            self.proc = LspProcess.spawn(argv)
        except:
            return False
        self.active = True
        return True

    def cancel(mut self):
        """Stop the child (if any) and drop what it wrote. Idempotent."""
        if self.active:
            self.proc.terminate()
        self.active = False
        self._buf = List[UInt8]()

    def tick(mut self) -> Optional[String]:
        """Read what's available (capped); the whole output once the child
        reached EOF, when it has been reaped and the stream is idle again."""
        if not self.active:
            return None
        var got_eof = drain_fd(
            self.proc.stdout_fd, self._buf, _READ_CAP_PER_TICK, 8192,
        )[1] == DRAIN_EOF
        if not got_eof:
            return None
        var out = String(StringSpan(unsafe_from_utf8=Span(self._buf)))
        self.cancel()
        return out^
