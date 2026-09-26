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

from .lsp import LspProcess
from .posix import alloc_zero_buffer, poll_stdin, read_into


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
        var scratch = alloc_zero_buffer(8192)
        var total = 0
        var got_eof = False
        while total < _READ_CAP_PER_TICK:
            if not poll_stdin(self.proc.stdout_fd, Int32(0)):
                break
            var n = read_into(self.proc.stdout_fd, scratch, 8192)
            if n < 0:
                break
            if n == 0:
                got_eof = True
                break
            self._buf.extend(Span(scratch)[0:n])
            total += n
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
