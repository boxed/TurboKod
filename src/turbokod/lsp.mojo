"""Phase-2 LSP client: spawn a server, frame JSON-RPC, expose a poll loop.

This module is layered:

* ``LspProcess`` owns the subprocess pipes and the JSON-RPC wire framing.
  It knows nothing about LSP messages — just ``Content-Length: N\\r\\n\\r\\n``
  framed payloads.
* ``LspClient`` builds on top: autoincrementing ids, request/notification
  serializers, and a ``poll`` that classifies each incoming framed payload
  into a tagged ``LspIncoming``.

Phase 2 doesn't yet wire the responses into the editor — Phase 3 maps
``textDocument/semanticTokens/full`` results onto ``Highlight`` lists and
``textDocument/definition`` responses onto ``Window.from_file`` calls.
"""

from std.collections.list import List
from std.collections.optional import Optional

from std.io.file_descriptor import FileDescriptor
from std.ffi import external_call

from .json import (
    JsonValue, encode_json, json_int, json_object, json_str, parse_json,
)
from .posix import (
    POSIX_SPAWN_FILE_ACTIONS_SIZE, SIGTERM,
    alloc_zero_buffer, append_string_bytes, close_fd, getenv_value,
    kill_pid, monotonic_ms, pipe_pair, poll_stdin,
    posix_spawn_file_actions_addclose, posix_spawn_file_actions_adddup2,
    posix_spawn_file_actions_destroy, posix_spawn_file_actions_init,
    posix_spawnp_call, read_into, set_nonblocking, waitpid_blocking,
    waitpid_nohang, write_buffer,
)


# --- argv / envp marshalling ---------------------------------------------


@fieldwise_init
struct ArgvBuffer(Movable):
    """Contiguous NUL-terminated string blob + the corresponding ``char**``
    pointer array that ``posix_spawnp`` expects. Both are kept alive for
    the lifetime of the spawn call by holding them on this struct."""
    var blob: List[UInt8]
    var pointers: List[UInt8]


fn _build_envp_from_parent() -> ArgvBuffer:
    """Build an envp by reading specific variables from the parent.

    These are the ones ``mojo-lsp-server`` cares about (some directly —
    ``MODULAR_HOME`` to locate ``std`` — others as collateral so paths,
    locale, and home cache directories work). We don't forward *every*
    parent var because a NULL-terminated envp inherited via posix_spawn
    requires a real pointer (Mojo's ``external_call`` doesn't model that
    cleanly), so an explicit allowlist is the simpler reliable path.
    """
    var names = List[String]()
    names.append(String("PATH"))
    names.append(String("HOME"))
    names.append(String("USER"))
    names.append(String("SHELL"))
    names.append(String("TMPDIR"))
    names.append(String("LANG"))
    names.append(String("LC_ALL"))
    names.append(String("LC_CTYPE"))
    names.append(String("TERM"))
    names.append(String("MODULAR_HOME"))
    names.append(String("MAX_PATH"))
    names.append(String("MOJO_PYTHON"))
    names.append(String("CONDA_PREFIX"))
    names.append(String("CONDA_DEFAULT_ENV"))
    names.append(String("CONDA_PYTHON_EXE"))
    names.append(String("VIRTUAL_ENV"))
    names.append(String("PIXI_PROJECT_ROOT"))
    names.append(String("PIXI_PROJECT_NAME"))
    names.append(String("PIXI_PROJECT_MANIFEST"))
    names.append(String("LD_LIBRARY_PATH"))
    names.append(String("DYLD_LIBRARY_PATH"))
    names.append(String("DYLD_FALLBACK_LIBRARY_PATH"))
    # Python-flavored vars: debugpy + pyright both consult these to
    # find their own packages. Without PYTHONPATH a system ``python``
    # invoked as ``python -m debugpy.adapter`` may locate ``python`` but
    # not ``debugpy`` and silently stall on import resolution.
    names.append(String("PYTHONPATH"))
    names.append(String("PYTHONHOME"))
    names.append(String("PYTHONUSERBASE"))
    names.append(String("PYTHONUNBUFFERED"))
    var pairs = List[String]()
    for i in range(len(names)):
        var v = getenv_value(names[i])
        if len(v.as_bytes()) > 0:
            pairs.append(names[i] + String("=") + v)
    # Force unbuffered Python I/O for any spawned child. Without this,
    # ``python -m debugpy.adapter`` (and other Python-based servers)
    # default to *full* stdout buffering when stdout is a pipe — they
    # write a response, it sits in their internal buffer until the
    # buffer fills or they explicitly flush, and our ``poll`` sees
    # nothing. The handshake then hangs at INITIALIZING with no error.
    # Setting PYTHONUNBUFFERED=1 makes Python flush on every write.
    pairs.append(String("PYTHONUNBUFFERED=1"))
    return _build_argv_buffer(pairs^)


fn _build_argv_buffer(args: List[String]) -> ArgvBuffer:
    var blob = List[UInt8]()
    var offsets = List[Int]()
    for i in range(len(args)):
        offsets.append(len(blob))
        var b = args[i].as_bytes()
        for k in range(len(b)):
            blob.append(b[k])
        blob.append(0)
    # ``pointers`` is a packed array of ``char *`` (8 bytes each), with a
    # NULL terminator at the end. We resolve offsets to absolute pointers
    # via blob.unsafe_ptr() + offset.
    var nptrs = len(args) + 1
    var pointers = alloc_zero_buffer(nptrs * 8)
    var pp = pointers.unsafe_ptr().bitcast[Int]()
    for i in range(len(args)):
        pp[i] = Int(blob.unsafe_ptr()) + offsets[i]
    pp[len(args)] = 0
    return ArgvBuffer(blob^, pointers^)


# --- capture_command ------------------------------------------------------


@fieldwise_init
struct CaptureResult(Movable):
    """Output of a synchronous child run. ``status`` is the raw waitpid
    value; the exit code is ``(status >> 8) & 0xFF`` on POSIX. ``stderr``
    is captured separately so callers that care about distinguishing
    progress text from the actual result (``git push`` is the canonical
    example — pushes the result summary to stderr) can see it."""
    var stdout: String
    var stderr: String
    var status: Int32


fn capture_command(
    argv: List[String], stdin_text: String = String(""),
) raises -> CaptureResult:
    """Run ``argv`` to completion, return ``(stdout, exit_status)``.

    Stderr is read but discarded. The child inherits an allowlisted
    parent environment (see ``_build_envp_from_parent``). Reads are
    blocking and the call returns only after the child exits, so this
    is unsuitable for long-running servers — use ``LspProcess`` for
    those — but ideal for one-shot tools like ``rg`` or ``git``.

    Raises if argv is empty or posix_spawnp fails. A non-zero
    exit_status is **not** an error: command-line tools commonly use
    exit 1 to mean "no results" (e.g., grep / rg with no matches), and
    callers want to distinguish that from a spawn failure.
    """
    if len(argv) == 0:
        raise Error("argv must not be empty")
    var stdin_pair = pipe_pair()
    var stdin_r = stdin_pair[0]
    var stdin_w = stdin_pair[1]
    var stdout_pair = pipe_pair()
    var stdout_r = stdout_pair[0]
    var stdout_w = stdout_pair[1]
    var stderr_pair = pipe_pair()
    var stderr_r = stderr_pair[0]
    var stderr_w = stderr_pair[1]

    var fa = alloc_zero_buffer(POSIX_SPAWN_FILE_ACTIONS_SIZE)
    var rc_init = posix_spawn_file_actions_init(fa)
    if Int(rc_init) != 0:
        _ = close_fd(stdin_r); _ = close_fd(stdin_w)
        _ = close_fd(stdout_r); _ = close_fd(stdout_w)
        _ = close_fd(stderr_r); _ = close_fd(stderr_w)
        raise Error("posix_spawn_file_actions_init failed")
    _ = posix_spawn_file_actions_adddup2(fa, stdin_r,  Int32(0))
    _ = posix_spawn_file_actions_adddup2(fa, stdout_w, Int32(1))
    _ = posix_spawn_file_actions_adddup2(fa, stderr_w, Int32(2))
    _ = posix_spawn_file_actions_addclose(fa, stdin_w)
    _ = posix_spawn_file_actions_addclose(fa, stdout_r)
    _ = posix_spawn_file_actions_addclose(fa, stderr_r)
    _ = posix_spawn_file_actions_addclose(fa, stdin_r)
    _ = posix_spawn_file_actions_addclose(fa, stdout_w)
    _ = posix_spawn_file_actions_addclose(fa, stderr_w)

    var argv_buf = _build_argv_buffer(argv)
    var envp_buf = _build_envp_from_parent()
    var pid: Int32
    try:
        pid = posix_spawnp_call(
            argv_buf.pointers, envp_buf.pointers, fa, argv[0],
        )
    except:
        _ = posix_spawn_file_actions_destroy(fa)
        _ = close_fd(stdin_r); _ = close_fd(stdin_w)
        _ = close_fd(stdout_r); _ = close_fd(stdout_w)
        _ = close_fd(stderr_r); _ = close_fd(stderr_w)
        raise Error("posix_spawnp failed")
    _ = posix_spawn_file_actions_destroy(fa)
    _ = close_fd(stdin_r)
    _ = close_fd(stdout_w)
    _ = close_fd(stderr_w)

    # Send stdin (if any), then close to signal EOF — without this many
    # tools that read stdin (e.g. ``rg`` reading from stdin) would hang.
    if len(stdin_text.as_bytes()) > 0:
        var sb = List[UInt8]()
        append_string_bytes(sb, stdin_text)
        write_buffer(stdin_w, sb)
    _ = close_fd(stdin_w)

    # Drain stdout + stderr to EOF (blocking reads). Capturing both —
    # rather than discarding stderr — costs nothing since the drain has
    # to happen anyway to keep the child from blocking on a full pipe,
    # and lets git callers surface useful failure messages.
    var out = _drain_to_eof(stdout_r)
    var err = _drain_to_eof(stderr_r)
    _ = close_fd(stdout_r)
    _ = close_fd(stderr_r)

    var status = waitpid_blocking(pid)
    return CaptureResult(out^, err^, status)


fn _drain_to_eof(fd: Int32) -> String:
    var out = String("")
    var scratch = alloc_zero_buffer(8192)
    while True:
        var n = read_into(fd, scratch, 8192)
        if n <= 0:
            break
        out = out + String(StringSlice(
            ptr=scratch.unsafe_ptr(), length=n,
        ))
    return out^


# --- LspProcess -----------------------------------------------------------


comptime _BUF_CAP_GUARD: Int = 16 * 1024 * 1024
"""Bytes-on-the-floor protection: if the read buffer ever grows past this
without yielding a complete message, we treat the server as misbehaving
and reset. 16 MB is far above any plausible LSP payload."""


struct LspProcess(Movable):
    """A spawned child plus its stdin/stdout/stderr pipes and a
    Content-Length-aware read framer."""
    var pid: Int32
    var stdin_fd: Int32
    var stdout_fd: Int32
    var stderr_fd: Int32
    var alive: Bool
    var _read_buffer: List[UInt8]
    # Optional trace log. When ``trace_fd >= 0`` every wire-level event
    # (writes, reads, message extractions) is appended to that fd as a
    # single line. The whole point of streaming the log is so that a
    # hung session still leaves a complete-up-to-the-hang trail on
    # disk — no need for the host loop to be alive to flush. We
    # ``write()`` directly via ``FileDescriptor`` (no userspace
    # buffering) so each call is durable on return.
    var trace_fd: Int32

    fn __init__(out self):
        self.pid = -1
        self.stdin_fd = -1
        self.stdout_fd = -1
        self.stderr_fd = -1
        self.alive = False
        self._read_buffer = List[UInt8]()
        self.trace_fd = -1

    @staticmethod
    fn spawn(argv: List[String]) raises -> Self:
        """Run ``argv`` with three pipes wired onto stdin/stdout/stderr.

        Returns a process with the parent-side ends owned by ``self``;
        the child-side ends are closed in the parent immediately after
        spawn so EOF propagates correctly when one side hangs up.
        """
        if len(argv) == 0:
            raise Error("argv must not be empty")
        # Parent's view: ``stdin_w`` writes to child stdin, ``stdout_r``
        # reads child stdout, ``stderr_r`` reads child stderr.
        var stdin_pair = pipe_pair()    # (read, write)
        var stdin_r = stdin_pair[0]
        var stdin_w = stdin_pair[1]
        var stdout_pair = pipe_pair()
        var stdout_r = stdout_pair[0]
        var stdout_w = stdout_pair[1]
        var stderr_pair = pipe_pair()
        var stderr_r = stderr_pair[0]
        var stderr_w = stderr_pair[1]

        var fa = alloc_zero_buffer(POSIX_SPAWN_FILE_ACTIONS_SIZE)
        var rc_init = posix_spawn_file_actions_init(fa)
        if Int(rc_init) != 0:
            _ = close_fd(stdin_r); _ = close_fd(stdin_w)
            _ = close_fd(stdout_r); _ = close_fd(stdout_w)
            _ = close_fd(stderr_r); _ = close_fd(stderr_w)
            raise Error("posix_spawn_file_actions_init failed")
        # Child side: dup pipe ends onto stdin/stdout/stderr, then close
        # the parent ends in the child.
        _ = posix_spawn_file_actions_adddup2(fa, stdin_r,  Int32(0))
        _ = posix_spawn_file_actions_adddup2(fa, stdout_w, Int32(1))
        _ = posix_spawn_file_actions_adddup2(fa, stderr_w, Int32(2))
        _ = posix_spawn_file_actions_addclose(fa, stdin_w)
        _ = posix_spawn_file_actions_addclose(fa, stdout_r)
        _ = posix_spawn_file_actions_addclose(fa, stderr_r)
        _ = posix_spawn_file_actions_addclose(fa, stdin_r)
        _ = posix_spawn_file_actions_addclose(fa, stdout_w)
        _ = posix_spawn_file_actions_addclose(fa, stderr_w)

        var argv_buf = _build_argv_buffer(argv)
        # Forward the parent's environ. Critical for ``mojo-lsp-server``,
        # which uses ``MODULAR_HOME`` (and friends) to locate its own
        # ``std`` package; with an empty env it falls back to ``/opt/modular``,
        # fails to read it, and rejects every document with "unable to
        # locate module 'std'" — turning every definition request into ``[]``.
        var envp_buf = _build_envp_from_parent()
        var pid: Int32
        try:
            pid = posix_spawnp_call(
                argv_buf.pointers, envp_buf.pointers, fa, argv[0],
            )
        except:
            _ = posix_spawn_file_actions_destroy(fa)
            _ = close_fd(stdin_r); _ = close_fd(stdin_w)
            _ = close_fd(stdout_r); _ = close_fd(stdout_w)
            _ = close_fd(stderr_r); _ = close_fd(stderr_w)
            raise Error("posix_spawnp failed")
        _ = posix_spawn_file_actions_destroy(fa)
        # Close the child sides in the parent — the kernel keeps the pipe
        # alive as long as either end is open, so leaving them open here
        # would prevent EOF when the child closes its descriptor.
        _ = close_fd(stdin_r)
        _ = close_fd(stdout_w)
        _ = close_fd(stderr_w)

        var proc = LspProcess()
        proc.pid = pid
        proc.stdin_fd = stdin_w
        proc.stdout_fd = stdout_r
        proc.stderr_fd = stderr_r
        proc.alive = True
        # Reading the stdout/stderr pipes non-blocking lets ``poll_message``
        # drain whatever's available in one shot without risking a hang.
        _ = set_nonblocking(proc.stdout_fd)
        _ = set_nonblocking(proc.stderr_fd)
        return proc^

    fn trace(self, var line: String):
        """Append ``line`` (plus a newline) to the trace fd, if open.

        Uses the raw ``write`` syscall — no userspace buffering — so
        each call is durable on return. Errors are swallowed; this is
        diagnostics, never load-bearing for correctness."""
        if self.trace_fd < 0:
            return
        var stamped = String("[") + String(monotonic_ms()) + String("] ") \
            + line + String("\n")
        var bytes = stamped.as_bytes()
        if len(bytes) == 0:
            return
        var f = FileDescriptor(Int(self.trace_fd))
        f.write_bytes(bytes)

    fn write_message(mut self, payload: String) raises:
        """Frame ``payload`` with ``Content-Length: N\\r\\n\\r\\n`` and write
        the whole thing to the child's stdin in one syscall."""
        var n = len(payload.as_bytes())
        var hdr = String("Content-Length: ") + String(n) + String("\r\n\r\n")
        var buf = List[UInt8]()
        append_string_bytes(buf, hdr)
        append_string_bytes(buf, payload)
        if self.trace_fd >= 0:
            # Truncate huge payloads in the trace — full breakpoint
            # lists, big stack traces etc. can run to several KB and
            # the log is meant to be human-readable.
            var preview = payload
            var pb = payload.as_bytes()
            if len(pb) > 400:
                preview = String(StringSlice(
                    ptr=pb.unsafe_ptr(), length=400,
                )) + String("…")
            self.trace(String("> ") + String(n) + String("B ") + preview)
        write_buffer(self.stdin_fd, buf)

    fn poll_message(mut self, timeout_ms: Int32) -> Optional[String]:
        """Try to return one complete framed payload.

        ``timeout_ms`` is the budget for waiting on stdout when the buffer
        is empty. Already-buffered data is checked first regardless. None
        return means no full message is framed yet — call again later.
        """
        # Drain anything already in the buffer first.
        var prefab = self._extract_one_message()
        if prefab:
            if self.trace_fd >= 0:
                var pb = prefab.value().as_bytes()
                var preview = prefab.value()
                if len(pb) > 400:
                    preview = String(StringSlice(
                        ptr=pb.unsafe_ptr(), length=400,
                    )) + String("…")
                self.trace(
                    String("< ") + String(len(pb)) + String("B ") + preview,
                )
            return prefab
        if not poll_stdin(self.stdout_fd, timeout_ms):
            return Optional[String]()
        var scratch = alloc_zero_buffer(4096)
        var n = read_into(self.stdout_fd, scratch, 4096)
        if n <= 0:
            if self.trace_fd >= 0 and n == 0:
                self.trace(String("< EOF on stdout"))
            return Optional[String]()
        for i in range(n):
            self._read_buffer.append(scratch[i])
        if self.trace_fd >= 0:
            self.trace(
                String("< raw ") + String(n) + String("B (buffer now ")
                + String(len(self._read_buffer)) + String("B)"),
            )
        if len(self._read_buffer) > _BUF_CAP_GUARD:
            self._read_buffer = List[UInt8]()
            return Optional[String]()
        var extracted = self._extract_one_message()
        if extracted and self.trace_fd >= 0:
            var eb = extracted.value().as_bytes()
            var preview = extracted.value()
            if len(eb) > 400:
                preview = String(StringSlice(
                    ptr=eb.unsafe_ptr(), length=400,
                )) + String("…")
            self.trace(
                String("< extracted ") + String(len(eb)) + String("B ")
                + preview,
            )
        return extracted

    fn _extract_one_message(mut self) -> Optional[String]:
        """Scan ``_read_buffer`` for a complete framed payload; if one is
        present, slice it out, shrink the buffer, and return it."""
        var hdr_end = _find_double_crlf(self._read_buffer)
        if hdr_end < 0:
            return Optional[String]()
        var content_length = _parse_content_length(self._read_buffer, hdr_end)
        if content_length < 0:
            # Malformed header block — drop the framed prefix so we don't
            # spin forever; the next bytes are probably garbage anyway.
            self._read_buffer = _drop_prefix(
                self._read_buffer^, hdr_end + 4,
            )
            return Optional[String]()
        var body_start = hdr_end + 4
        if len(self._read_buffer) - body_start < content_length:
            return Optional[String]()
        var body = String(StringSlice(
            ptr=self._read_buffer.unsafe_ptr() + body_start,
            length=content_length,
        ))
        self._read_buffer = _drop_prefix(
            self._read_buffer^, body_start + content_length,
        )
        return Optional[String](body^)

    fn drain_stderr(mut self) -> String:
        """Drain whatever's available on the server's stderr.
        Non-blocking; loops until ``poll`` says no more data so a
        chatty adapter (debugpy logs many lines per second) can't
        fill the pipe and deadlock on a blocking write. Capped at
        64 KB per call to bound the cost of a single tick.

        Without the loop we'd read at most 4 KB per frame; debugpy's
        startup banner alone is ~1 KB, so a frame-aligned drain
        could fall behind on slow paint cycles and the adapter's
        write-end would back up against the pipe buffer (~64 KB on
        macOS). Once that backs up, the adapter's main thread blocks
        on ``write(stderr, …)`` and never reaches the code that
        replies to our ``initialize`` — appearing as a total hang.
        """
        var out = String("")
        if self.stderr_fd < 0:
            return out
        var total = 0
        var scratch = alloc_zero_buffer(4096)
        while poll_stdin(self.stderr_fd, Int32(0)) and total < 65536:
            var m = read_into(self.stderr_fd, scratch, 4096)
            if m <= 0:
                break
            out = out + String(StringSlice(
                ptr=scratch.unsafe_ptr(), length=m,
            ))
            total += m
        return out

    fn terminate(mut self):
        """Send SIGTERM and reap the child. Idempotent."""
        if not self.alive or self.pid <= 0:
            return
        _ = kill_pid(self.pid, SIGTERM)
        _ = waitpid_blocking(self.pid)
        self.alive = False
        if self.stdin_fd >= 0:  _ = close_fd(self.stdin_fd);  self.stdin_fd = -1
        if self.stdout_fd >= 0: _ = close_fd(self.stdout_fd); self.stdout_fd = -1
        if self.stderr_fd >= 0: _ = close_fd(self.stderr_fd); self.stderr_fd = -1

    fn try_reap(mut self) -> Bool:
        """Non-blocking ``waitpid``. Returns True if the child exited.
        Use after ``shutdown``+``exit`` to see if the server cleaned up
        on its own before resorting to ``terminate``."""
        if not self.alive or self.pid <= 0:
            return True
        var pair = waitpid_nohang(self.pid)
        if Int(pair[0]) == Int(self.pid):
            self.alive = False
            return True
        return False


# --- framer helpers (top-level for testability) ---------------------------


fn _find_double_crlf(buf: List[UInt8]) -> Int:
    """Return the index of the first ``\\r\\n\\r\\n`` in ``buf``, or -1."""
    if len(buf) < 4:
        return -1
    for i in range(len(buf) - 3):
        if buf[i] == 0x0D and buf[i + 1] == 0x0A \
                and buf[i + 2] == 0x0D and buf[i + 3] == 0x0A:
            return i
    return -1


fn _parse_content_length(buf: List[UInt8], hdr_end: Int) -> Int:
    """Find ``Content-Length: N`` in the header block (case-insensitive on
    the field name) and return ``N``. Returns -1 if not found / malformed."""
    var name = String("content-length")
    var nb = name.as_bytes()
    var i = 0
    while i + len(nb) <= hdr_end:
        # Match the header name case-insensitively against the prefix
        # starting at position ``i``.
        var ok = True
        for k in range(len(nb)):
            var bc = Int(buf[i + k])
            if 0x41 <= bc and bc <= 0x5A:
                bc = bc + 0x20
            if bc != Int(nb[k]):
                ok = False
                break
        if ok:
            var p = i + len(nb)
            # Skip optional ``: `` and any whitespace.
            if p < hdr_end and buf[p] == 0x3A:
                p += 1
            while p < hdr_end and (buf[p] == 0x20 or buf[p] == 0x09):
                p += 1
            var n = 0
            var saw_digit = False
            while p < hdr_end and Int(buf[p]) >= 0x30 and Int(buf[p]) <= 0x39:
                n = n * 10 + Int(buf[p]) - 0x30
                saw_digit = True
                p += 1
            if saw_digit:
                return n
            return -1
        # Skip to the next line (header lines are separated by ``\r\n``).
        while i < hdr_end and buf[i] != 0x0A:
            i += 1
        i += 1
    return -1


fn _drop_prefix(var buf: List[UInt8], n: Int) -> List[UInt8]:
    """Shrink ``buf`` by removing the first ``n`` bytes."""
    if n <= 0:
        return buf^
    if n >= len(buf):
        return List[UInt8]()
    var out = List[UInt8]()
    for i in range(n, len(buf)):
        out.append(buf[i])
    return out^


# --- LspClient ------------------------------------------------------------


comptime LSP_RESPONSE     = UInt8(0)
comptime LSP_NOTIFICATION = UInt8(1)
comptime LSP_REQUEST      = UInt8(2)


@fieldwise_init
struct LspIncoming(ImplicitlyCopyable, Movable):
    """A classified message from the server.

    * ``kind == LSP_RESPONSE``:     ``id`` is set; one of ``result``/``error``.
    * ``kind == LSP_NOTIFICATION``: ``method`` + ``params`` are set.
    * ``kind == LSP_REQUEST``:      ``id`` + ``method`` + ``params`` set.
    """
    var kind: UInt8
    var id: Optional[Int]
    var method: Optional[String]
    var params: Optional[JsonValue]
    var result: Optional[JsonValue]
    var error: Optional[JsonValue]


struct LspClient(Movable):
    """Adds JSON-RPC envelope handling on top of ``LspProcess``."""
    var process: LspProcess
    var _next_id: Int

    fn __init__(out self, var process: LspProcess):
        self.process = process^
        self._next_id = 1

    @staticmethod
    fn spawn(argv: List[String]) raises -> Self:
        var p = LspProcess.spawn(argv)
        return LspClient(p^)

    fn send_request(
        mut self, method: String, params: JsonValue,
    ) raises -> Int:
        """Send a JSON-RPC request and return the issued id (so callers
        can correlate with the eventual response)."""
        var id = self._next_id
        self._next_id += 1
        var envelope = json_object()
        envelope.put(String("jsonrpc"), json_str(String("2.0")))
        envelope.put(String("id"), json_int(id))
        envelope.put(String("method"), json_str(method))
        envelope.put(String("params"), params)
        self.process.write_message(encode_json(envelope))
        return id

    fn send_notification(
        mut self, method: String, params: JsonValue,
    ) raises:
        var envelope = json_object()
        envelope.put(String("jsonrpc"), json_str(String("2.0")))
        envelope.put(String("method"), json_str(method))
        envelope.put(String("params"), params)
        self.process.write_message(encode_json(envelope))

    fn poll(mut self, timeout_ms: Int32) raises -> Optional[LspIncoming]:
        var maybe = self.process.poll_message(timeout_ms)
        if not maybe:
            return Optional[LspIncoming]()
        var v = parse_json(maybe.value())
        return Optional[LspIncoming](classify_message(v))

    fn terminate(mut self):
        self.process.terminate()


fn classify_message(v: JsonValue) -> LspIncoming:
    """Examine a parsed JSON-RPC envelope and tag it as response /
    notification / request. Top-level utility for tests + clients."""
    var id_opt = Optional[Int]()
    var method_opt = Optional[String]()
    var params_opt = Optional[JsonValue]()
    var result_opt = Optional[JsonValue]()
    var error_opt = Optional[JsonValue]()
    if v.is_object():
        var maybe_id = v.object_get(String("id"))
        if maybe_id and maybe_id.value().is_int():
            id_opt = Optional[Int](maybe_id.value().as_int())
        var maybe_method = v.object_get(String("method"))
        if maybe_method and maybe_method.value().is_string():
            method_opt = Optional[String](maybe_method.value().as_str())
        var maybe_params = v.object_get(String("params"))
        if maybe_params:
            params_opt = Optional[JsonValue](maybe_params.value())
        var maybe_result = v.object_get(String("result"))
        if maybe_result:
            result_opt = Optional[JsonValue](maybe_result.value())
        var maybe_error = v.object_get(String("error"))
        if maybe_error:
            error_opt = Optional[JsonValue](maybe_error.value())
    var kind: UInt8
    if Bool(method_opt) and Bool(id_opt):
        kind = LSP_REQUEST
    elif Bool(method_opt):
        kind = LSP_NOTIFICATION
    else:
        kind = LSP_RESPONSE
    return LspIncoming(
        kind, id_opt, method_opt, params_opt, result_opt, error_opt,
    )


# --- High-level helpers used by tests + Phase 3 wiring --------------------


fn lsp_initialize_params(root_uri: String) -> JsonValue:
    """Build the bare-minimum ``initialize`` payload that ``mojo-lsp-server``
    accepts. Phase 3 will expand ``capabilities``."""
    var params = json_object()
    # ``processId`` is informational; ``null`` is allowed.
    params.put(String("processId"), json_int(0))
    params.put(String("rootUri"),
        json_str(root_uri) if len(root_uri.as_bytes()) > 0 else json_null_v(),
    )
    params.put(String("capabilities"), json_object())
    return params^


fn json_null_v() -> JsonValue:
    """Local alias to keep the import list shorter at call sites."""
    var v = JsonValue()
    return v^
